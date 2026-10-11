# MANAGER

Gerenciador moderno de VPS inspirado na experiência clássica do **SSHPlus Manager**, reconstruído para Debian/Ubuntu atuais.

> O objetivo não é executar cegamente binários antigos do SSHPlus. O MANAGER preserva capacidades úteis, substitui implementações inseguras/obsoletas e prepara uma arquitetura própria para Automation v2, Telegram e Modo Colmeia.

Versão atual: **0.6.5**.

## Princípios

- não substituir o `sshd_config` inteiro;
- não executar `iptables -F`, `ip6tables -F` ou `nft flush ruleset`;
- não baixar executáveis opacos como root;
- validar configurações antes de recarregar serviços;
- manter módulos opcionais realmente opcionais;
- criar backup/rollback antes de mudanças críticas;
- preservar configurações que não pertencem ao MANAGER sempre que possível;
- compatibilidade com legado não significa copiar fragilidades do legado;
- integrações futuras usam operações estruturadas, nunca shell remoto arbitrário.

## Recursos atuais

### Servidor, SSH e VPN

- informações do sistema, kernel, uptime, memória, disco, carga, IPs e serviços;
- usuários SSH: criar/remover, senha, validade, limite simultâneo, bloqueio e sessões;
- contas teste com duração em minutos e remoção automática;
- limpeza confirmada de expirados;
- banner SSH por `sshd_config.d`;
- WireGuard com servidor, clientes, revogação, QR Code e NAT específico;
- OpenVPN com Easy-RSA, perfis `.ovpn`, CRL e UDP/TCP;
- DNS Ad Block com dnsmasq, whitelist/blacklist e atualização diária;
- Squid privado, proxy TCP, WebSocket e TLS opcionais;
- hosts de proxy gerenciados;
- TLS/Let's Encrypt;
- firewall, Fail2ban e hardening SSH.

### Contas e revenda

- revendedor e subrevendedor;
- hierarquia, bloqueio/reativação e cotas;
- propriedade de contas SSH;
- criação de usuário diretamente vinculada ao proprietário;
- validação de cota antes e durante a criação;
- exportação/restauração segura de usuários;
- detector de estruturas conhecidas do SSHPlus antigo;
- monitor de sessões SSH com encerramento seletivo por TTY.

Estado de revenda:

```text
/etc/manager/access/
```

## Connection Engine

A partir da série 0.6, a identidade lógica deixa de depender do `/etc/passwd`.

```text
maria
├── owner = revenda01
├── enabled = 1
├── expires_epoch = 0
├── max_sessions = 1
├── protocols = ssh,wireguard,openvpn
├── ssh_user = maria
├── wireguard_client = maria
└── openvpn_client = maria
```

Estado:

```text
/etc/manager/connection/identities/
```

As identidades não duplicam senhas, chaves privadas WireGuard nem certificados OpenVPN. Elas vinculam política e recursos técnicos a uma única conta lógica.

Documentação: [`docs/CONNECTION_ENGINE.md`](docs/CONNECTION_ENGINE.md).

## Policy Engine

O estado efetivo de uma identidade pode incluir:

```text
active
disabled
expired
product-disabled
product-missing
quota-exceeded
```

O Policy Engine aplica esse estado aos recursos reais.

### SSH

O MANAGER gera somente:

```text
/etc/ssh/sshd_config.d/65-manager-identity-policy.conf
/etc/security/limits.d/98-manager-identity.conf
```

Identidades inativas são bloqueadas com `DenyUsers`. Antes de reload, `sshd -t` valida a configuração.

### WireGuard

Identidade inativa pode ter somente seu peer retirado do runtime de `wg0`, preservando chaves e arquivos de configuração.

### OpenVPN

Uma identidade inativa não precisa ter o certificado revogado. O MANAGER consegue bloquear o recurso de forma reversível e preservar credenciais para futura reativação.

## Sessões observadas

```bash
manager --identity-sessions
manager --identity-sessions maria
```

Exemplo:

```text
maria  active  ssh=0  wg=1  ovpn=0  total=1  max=1
```

Essa visão responde: **o que os protocolos realmente estão vendo?**

## Session / Lease Engine

A 0.6.2 introduziu a autoridade local de vagas.

```bash
manager --leases
manager --leases maria
```

Uma lease contém:

```text
session_id
identity_id
protocol
resource
device_id
session_epoch
created_epoch
heartbeat_epoch
expires_epoch
```

Leases ativas ficam somente em:

```text
/run/manager-session-leases/active/
```

O fencing persistente fica em:

```text
/etc/manager/connection/session-epochs/<id>.epoch
```

O Session Engine possui:

- aquisição atômica local;
- `max_sessions` sob lock;
- retry idempotente;
- TTL;
- heartbeat;
- release;
- troca de sessão;
- `session_epoch`;
- fencing de geração antiga;
- revogação automática quando política/recurso deixa de ser válido.

Documentação: [`docs/SESSION_ENGINE.md`](docs/SESSION_ENGINE.md).

## Protocol Lease Bridge — 0.6.3

Na 0.6.3 as leases passam a representar conexões reais, não apenas chamadas internas.

```text
SSH / WireGuard / OpenVPN
            ↓
   Protocol Lease Bridge
            ↓
       Session Engine
```

Módulo:

```text
/opt/manager/modules/protocol_leases.sh
```

### SSH → lease

O MANAGER adiciona um bloco próprio de sessão em `/etc/pam.d/sshd` e usa:

```text
/usr/local/libexec/manager-ssh-lease-hook
```

No `open_session`, uma conta vinculada precisa adquirir uma lease. No `close_session`, a reserva é liberada.

O wrapper é fail-safe para não converter um rollback/recuperação incompleto em lockout do SSH administrativo.

O reconciliador também adota sessões já abertas observadas por `who`.

### OpenVPN → lease

O OpenVPN não recebe shell root nem `sudo` amplo.

O hook:

```text
/usr/local/libexec/manager-openvpn-lease-hook
```

trabalha com uma fila runtime:

```text
/run/manager-protocol-leases/openvpn-requests/
/run/manager-protocol-leases/openvpn-responses/
```

Um processador privilegiado e allowlisted é acionado por:

```text
manager-openvpn-lease-queue.path
manager-openvpn-lease-queue.service
```

Fluxo:

```text
client-connect
      ↓
hook sem root
      ↓
pedido validado
      ↓
Session Engine
      ↓
ALLOW / DENY
```

`client-disconnect` libera a reserva.

### WireGuard → lease

WireGuard não tem evento de login. O bridge usa o handshake recente como sinal de atividade.

Um peer gerenciado só mantém tráfego encaminhado quando possui lease válida. Sem autorização, o MANAGER aplica bloqueio específico ao IP daquele peer; nunca há flush global do firewall. Se a regra específica não puder ser aplicada, o fallback remove somente aquele peer do runtime.

### Heartbeat

```text
manager-protocol-leases.timer
manager-protocol-leases.service
```

O reconciliador compara continuamente conexões reais e leases, renova as que continuam vivas e libera as que desapareceram.

## Identity Usage Accounting — 0.6.4

A 0.6.4 adiciona uma visão comum de **tráfego medido + atividade** por identidade.

```bash
manager --usage
manager --usage maria
```

Estado persistente:

```text
/var/lib/manager/identity-usage/identities/
```

Snapshots locais usados somente para calcular deltas:

```text
/var/lib/manager/identity-usage/sources/
```

### WireGuard e OpenVPN

O MANAGER consolida bytes reais reportados pelos próprios protocolos:

- WireGuard: contadores `transfer` do peer;
- OpenVPN: `Bytes Received` / `Bytes Sent` do status do servidor.

A primeira observação de uma fonte vira **baseline** e não é contabilizada retroativamente. Depois, somente a diferença entre leituras é somada ao histórico da identidade. Se o daemon/interface reiniciar e o contador absoluto voltar para um valor menor, o coletor trata esse valor como novo delta sem zerar o acumulado histórico.

Do ponto de vista da identidade:

```text
servidor recebeu do cliente = upload
servidor enviou ao cliente   = download
```

### SSH

SSH participa de sessão, heartbeat e última atividade, mas o MANAGER **não inventa byte accounting SSH** usando todo o tráfego do UID Linux. Esse método poderia misturar processos fora da sessão e produzir números errados.

Quando uma identidade possui SSH vinculado, a saída informa explicitamente:

```text
traffic_complete=0
ssh_bytes_supported=0
```

Assim relatórios e produtos distinguem total medido parcial de um total realmente coberto pelos protocolos metrificados.

### Exemplo

```text
id=maria
state=active
sessions=1
max_sessions=1
active_protocols=wireguard
download_bytes=19756849561
upload_bytes=3435973836
total_bytes=23192823397
traffic_complete=1
metered_protocols=wireguard,openvpn
ssh_bytes_supported=0
last_protocol=wireguard
last_resource=maria
```

Coleta automática:

```text
manager-identity-usage.timer
manager-identity-usage.service
```

O acumulado é persistente; uninstall normal preserva o histórico e `--purge` o remove. O backup transporta somente os totais consolidados, não snapshots/baselines pertencentes ao nó de origem.

Documentação: [`docs/IDENTITY_USAGE.md`](docs/IDENTITY_USAGE.md).

## Produtos, planos, ACL e franquias — 0.6.5

A 0.6.5 transforma limites soltos da identidade em produtos/planos reutilizáveis.

```bash
manager --products
manager --product premium
manager --product-assignment maria
```

Exemplo conceitual:

```text
Brasil Premium
├── protocolos = wireguard,openvpn
├── max_sessions = 1
├── duração = 30 dias
├── franquia = 500 GiB/mês
├── quota_action = block
├── acl_regions = BR
├── acl_pools = BR-PREMIUM
└── acl_nodes = *
```

O produto restringe a identidade, nunca amplia automaticamente sua política base. Antes de aplicar o plano, o MANAGER preserva os limites originais de sessões, protocolos e expiração; ao desvincular o produto, eles são restaurados.

### Franquia

Produtos podem usar:

```text
traffic_quota_bytes=0       # ilimitado
quota_period=monthly        # ou lifetime
quota_action=warn           # ou block
```

A franquia começa no acumulado atual da identidade. Tráfego anterior à atribuição não é cobrado retroativamente.

Em `warn`, o excesso é reportado sem bloquear a identidade. Em `block`, uma identidade com accounting completo passa para:

```text
quota-exceeded
```

Esse estado usa o mesmo Policy/Session Engine existente, em vez de criar um segundo mecanismo de sessão.

Quando SSH está vinculado, uma franquia pode aparecer excedida, porém:

```text
quota_enforceable=0
```

O MANAGER não bloqueia o usuário por bytes parciais enquanto o accounting SSH confiável não existir.

### ACL

Produtos possuem ACL de:

```text
protocol
region
pool
node
```

Contrato:

```bash
/opt/manager/modules/products.sh --authorize ID PROTOCOL REGION POOL NODE
```

Protocolos já restringem automaticamente a identidade local. `region/pool/node` estão prontos para o contexto de endpoint que será passado pela futura camada de nós/Colmeia.

Estado persistente:

```text
/etc/manager/connection/products/
/etc/manager/connection/product-usage/
```

Reconciliação:

```text
manager-product-policy.timer
manager-product-policy.service
```

Documentação: [`docs/PRODUCTS.md`](docs/PRODUCTS.md).

## O limite que prepara a Colmeia

Hoje a autoridade de lease, produto e accounting ainda é local na VPS. O modelo, porém, já representa o comportamento planejado para a Colmeia:

```text
Maria
product = global-premium
allowed_regions = BR, US, DE, FR, ...
max_sessions = 1
```

Ela pode ter vários destinos disponíveis, mas apenas uma sessão autorizada se o plano permitir uma só.

No futuro, o Hub substituirá a decisão local por um lock global sem mudar os conceitos de produto, ACL, `session_id`, TTL, heartbeat e `session_epoch`. O uso de cada nó poderá ser agregado sem exigir que os protocolos sejam reescritos.

## Reconciliação automática

Product Policy:

```text
manager-product-policy.timer
manager-product-policy.service
```

Policy Engine:

```text
manager-policy-reconcile.path
manager-policy-reconcile.timer
manager-policy-reconcile.service
```

Session Engine:

```text
manager-session-reconcile.path
manager-session-cleanup.timer
manager-session-cleanup.service
```

Protocol Lease Bridge:

```text
manager-protocol-leases.timer
manager-protocol-leases.service
manager-openvpn-lease-queue.path
manager-openvpn-lease-queue.service
```

Identity Usage:

```text
manager-identity-usage.timer
manager-identity-usage.service
```

## Backup e migração

Backups de configuração ficam em:

```text
/var/backups/manager/
```

Incluem, quando presentes:

```text
/etc/manager/access
/etc/manager/connection
/etc/manager/proxy
/var/lib/manager/identity-usage/identities
estado WireGuard/OpenVPN
DNS/TLS/banner/performance
configurações próprias do MANAGER
```

Como produtos, vínculos, ACL e baseline de franquia ficam dentro de `/etc/manager/connection`, eles usam o lifecycle e backup do Connection Engine.

Leases runtime e snapshots de contadores **não** entram no backup. `session_epoch`, identidades, produtos e acumulados consolidados persistem.

A exportação de usuários Linux é separada e não guarda senha em texto claro nem substitui `/etc/passwd`/`/etc/shadow` inteiros durante restauração.

O detector de legado reconhece estruturas como:

```text
/root/usuarios.db
/etc/SSHPlus/senha/
/root/backup.vps
```

## Segurança

- hardening OpenSSH por drop-in;
- Fail2ban;
- UFW com proteção da porta SSH detectada;
- atualizações automáticas de segurança;
- TLS/Let's Encrypt;
- fingerprints de chaves públicas;
- Squid sem `http_access allow all`;
- nada de flush global de firewall;
- credenciais VPN com permissões restritas;
- estado de identidade, produto e accounting restritos a root;
- OpenVPN não recebe acesso root ao Lease Engine;
- hooks externos são removidos antes de uninstall/rollback;
- franquia SSH não é bloqueada com dados incompletos;
- self-update baixa e valida o instalador antes da execução.

## CLI

```text
manager --health                  health check
manager --status                  status dos serviços
manager --expired                 contas SSH expiradas
manager --ssh-sessions            sessões SSH
manager --proxy-status            proxies/túneis
manager --proxy-hosts             hosts do proxy
manager --identities              identidades
manager --identity ID             detalhes da identidade
manager --products                produtos/planos
manager --product ID              detalhes do produto
manager --product-assignment ID   produto/franquia da identidade
manager --identity-sessions [ID]  sessões reais observadas
manager --leases [ID]             leases autorizadas
manager --usage [ID]              tráfego/atividade consolidada
manager --diagnostics             diagnóstico
manager --version                 versão
manager --help                    ajuda
```

## Sistemas suportados

- Ubuntu 22.04 ou superior;
- Debian 12 ou superior;
- `systemd` e `apt`.

A matriz de CI será ampliada no roadmap para cobrir diretamente mais versões modernas.

## Instalação

Evite executar instalador remoto por pipe:

```bash
sudo -i
curl -fL --proto '=https' --tlsv1.2 \
  https://raw.githubusercontent.com/SrTristeSad/MANAGER/main/install.sh \
  -o /tmp/manager-install.sh
bash -n /tmp/manager-install.sh
bash /tmp/manager-install.sh
rm -f /tmp/manager-install.sh
```

Depois:

```bash
manager
```

Alias clássico:

```bash
menu
```

## Atualização, rollback e remoção

Atualização:

```text
90) Atualizar MANAGER
```

Rollback:

```bash
manager-rollback
```

O rollback desmonta Product Policy, coletor de uso, hooks do Protocol Lease Bridge e enforcement antes da troca de código e reaplica somente os componentes disponíveis na versão restaurada. Estado persistente continua disponível para uma versão que conheça aquele componente.

Desinstalar preservando estado:

```bash
manager-uninstall
```

Os reconciliadores e o bridge são desanexados antes da remoção do código. Hooks PAM/OpenVPN, unidades runtime e leases temporárias são retirados; identidades, produtos, ACL, baseline de franquia, `session_epoch` e histórico consolidado de uso ficam preservados.

Purge explícito:

```bash
manager-uninstall --purge
```

O purge remove também produtos/ACL em `/etc/manager` e o histórico em `/var/lib/manager/identity-usage`. Pacotes do sistema, certificados Let's Encrypt, backups, grupos potencialmente pré-existentes e regras UFW alheias ao MANAGER continuam sendo tratados conservadoramente.

## Roadmap

Plano detalhado: [`docs/ROADMAP.md`](docs/ROADMAP.md).

```text
0.5.x  paridade SSHPlus útil
0.6.x  Connection Engine, políticas, leases, accounting, produtos e ACL
0.7.0  Legacy v1 + Automation v2
0.8.0  Modo Colmeia
0.9.0  Telegram Bot + Mini App
0.9.5  migração e escala
1.0.0  release de produção
```

### Legacy v1

Uma única camada de compatibilidade com o ecossistema `syncpainel`, desligada por padrão em instalações novas. Compatibilidade de protocolo não significa restaurar senha em texto claro, `chmod 777` ou flush destrutivo de firewall.

### Automation v2

Ações estruturadas, RBAC, auditoria, idempotência, autenticação criptográfica, anti-replay e interface privilegiada controlada. Sem shell arbitrário para integrações.

### Colmeia

Planejado:

- identidade criptográfica por nó;
- regiões/pools;
- capacidade e health por nó;
- drain/failover;
- sticky sessions;
- sessão global por identidade/plano;
- lease atômico e fencing global;
- agregação de uso por nó;
- comunicação autenticada/criptografada;
- nós iniciando conexão de controle para fora, sem abrir shell administrativo público.

### Telegram

Administração futura por Bot + Mini App, sem painel web administrativo convencional obrigatório.

## Testes

O CI cobre:

- `bash -n`;
- ShellCheck;
- padrões destrutivos de firewall/permissão;
- regressão contra Squid aberto;
- política segura de fonte do instalador;
- instalação/update/rollback/uninstall;
- Connection Engine e Policy Engine;
- Session Engine: acquire, retry, heartbeat, TTL, switch e fencing;
- Protocol Lease Bridge: instalação de hooks/unidades, admissão de sessão, limite `1/1`, release e cleanup de lifecycle;
- Identity Usage: baseline inicial, deltas, reset de contador, vínculo obrigatório, persistência em uninstall/reinstall e remoção por purge;
- Product Policy: ACL, `max_sessions`, franquia, `warn/block`, SSH parcial, restauração da política base, persistência e purge.

## Origem

O SSHPlus Manager original foi desenvolvido por **@crazy_vpn** e deu origem a vários forks comunitários. O MANAGER preserva a ideia de administração simples por terminal, mas evolui para uma arquitetura própria de identidade, automação, leases, accounting, produtos e operação multi-servidor.
