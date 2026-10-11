# MANAGER

Gerenciador moderno de VPS inspirado na experiência clássica do **SSHPlus Manager**, reconstruído para Debian/Ubuntu atuais.

> O objetivo não é executar cegamente binários antigos do SSHPlus. O MANAGER preserva capacidades úteis, substitui implementações inseguras/obsoletas e prepara uma arquitetura própria para Automation v2, Telegram e Modo Colmeia.

Versão atual: **0.6.8**.

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
- WireGuard com servidor, clientes, revogação, QR Code e dual-stack IPv4/IPv6 quando a VPS possui saída IPv6 real;
- OpenVPN com Easy-RSA, perfis `.ovpn`, CRL, UDP/TCP e `server-ipv6` opcional;
- IPv6 Guard ligado ao Policy/Session Engine para impedir bypass de limites pelo tráfego IPv6;
- UFW configurado para administrar IPv4 e IPv6 quando usado pelo MANAGER;
- DNS Ad Block com dnsmasq, whitelist/blacklist e atualização diária;
- Squid privado, proxy TCP, WebSocket e TLS opcionais;
- hosts de proxy gerenciados;
- TLS/Let's Encrypt;
- firewall, Fail2ban e hardening SSH.

### Contas e revenda

- revendedor e subrevendedor;
- hierarquia, bloqueio/reativação e cota total por cliente lógico;
- identidades VPN-only podem pertencer à revenda sem usuário Linux;
- uma identidade ocupa uma vaga mesmo usando vários protocolos;
- uso de subrevendedor entra no limite agregado do revendedor pai;
- cotas opcionais por produto/plano;
- propriedade SSH legada preservada e deduplicada ao adotar uma identidade;
- criação de usuário diretamente vinculada ao proprietário;
- reserva de cota sob lock antes da criação da identidade;
- exportação/restauração segura de usuários;
- detector de estruturas conhecidas do SSHPlus antigo;
- monitor de sessões SSH com encerramento seletivo por TTY.

Estado de revenda:

```text
/etc/manager/access/
```

Documentação: [`docs/RESELLER_QUOTAS.md`](docs/RESELLER_QUOTAS.md).

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

O Session Engine possui aquisição atômica local, `max_sessions` sob lock, retry idempotente, TTL, heartbeat, release, troca de sessão, `session_epoch`, fencing e revogação automática quando política/recurso deixa de ser válido.

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

### SSH → lease

O MANAGER adiciona um bloco próprio de sessão em `/etc/pam.d/sshd` e usa `/usr/local/libexec/manager-ssh-lease-hook`. No `open_session`, uma conta vinculada precisa adquirir uma lease. No `close_session`, a reserva é liberada.

### OpenVPN → lease

O OpenVPN não recebe shell root nem `sudo` amplo. O hook `/usr/local/libexec/manager-openvpn-lease-hook` usa uma fila runtime processada por uma superfície privilegiada allowlisted.

### WireGuard → lease

WireGuard não tem evento de login. O bridge usa o handshake recente como sinal de atividade. Um peer gerenciado só mantém tráfego encaminhado quando possui lease válida; não existe flush global do firewall.

Reconciliação automática:

```text
manager-protocol-leases.timer
manager-protocol-leases.service
manager-openvpn-lease-queue.path
manager-openvpn-lease-queue.service
```

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

WireGuard e OpenVPN alimentam bytes reais reportados pelos protocolos. A primeira observação vira baseline e somente deltas posteriores entram no acumulado. Reset de contador do daemon não zera o histórico.

SSH participa de sessão, heartbeat e última atividade, mas o MANAGER não inventa byte accounting SSH usando todo o tráfego do UID Linux. Quando SSH está vinculado:

```text
traffic_complete=0
ssh_bytes_supported=0
```

Documentação: [`docs/IDENTITY_USAGE.md`](docs/IDENTITY_USAGE.md).

## Produtos, planos, ACL e franquias — 0.6.5

```bash
manager --products
manager --product premium
manager --product-assignment maria
```

Produtos podem restringir protocolos, `max_sessions`, duração/expiração, franquia de bytes e ACL de região/pool/nó. O produto restringe a política base e não amplia privilégios silenciosamente.

Franquias usam `monthly` ou `lifetime`, com ação `warn` ou `block`. Em `block`, accounting completo pode levar a `quota-exceeded`; identidades com SSH não são bloqueadas com números parciais.

Documentação: [`docs/PRODUCTS.md`](docs/PRODUCTS.md).

## Provisionamento Unificado — 0.6.6

```bash
manager --provision maria brasil-premium
manager --provision maria brasil-premium '' wireguard,openvpn
manager --provision cliente01 plano-ssh revenda01 ssh
```

O provisionador faz preflight, cria a identidade, aplica o produto, materializa somente os protocolos selecionados, cria bindings e reconcilia política. Se uma etapa falhar, desfaz os recursos criados naquela tentativa.

No SSH, a senha aleatória fica bloqueada durante a transação e é mostrada uma única vez após o commit. Ela não entra no log de eventos. WireGuard cria somente o peer/perfil correspondente e OpenVPN reutiliza a PKI Easy-RSA existente.

Revogação completa:

```bash
manager --revoke-identity maria
```

A revogação desativa primeiro a identidade, invalida leases, remove/revoga recursos técnicos e limpa bindings. A identidade lógica permanece `disabled` para histórico/auditoria.

Documentação: [`docs/PROVISIONING.md`](docs/PROVISIONING.md).

## Cotas de revenda por identidade/produto — 0.6.7

A cota de revenda deixa de depender da existência de usuário Linux.

```text
revenda01
├── cota total = 100 clientes
├── premium = 20 clientes
└── basic = ilimitado
```

Uma identidade conta uma vez, independentemente de usar SSH, WireGuard, OpenVPN ou uma combinação deles. Identidades VPN-only podem ser provisionadas diretamente para revendedores e subrevendedores.

Slots de capacidade ficam em:

```text
/etc/manager/access/identity-slots/
```

Cotas específicas de produto ficam em:

```text
/etc/manager/access/product-quotas/
```

Bloqueio temporário mantém a vaga. Revogação completa libera a vaga somente depois de finalizar a remoção dos acessos. Para reativar uma identidade cujo slot foi liberado, a capacidade precisa ser reservada novamente.

Contas SSH antigas continuam contando até serem adotadas por uma identidade; a adoção é deduplicada para não cobrar duas vagas pelo mesmo cliente. Identidades revogadas preservadas pela 0.6.6 são migradas com slot inativo.

Consultas:

```bash
manager --reseller-usage revenda01
manager --reseller-product-quota revenda01 premium
```

O `products.sh --assign` também verifica a cota por produto, portanto o limite não depende somente do menu/provisionador. O preflight do provisionamento verifica cota total e cota do produto antes de criar recursos técnicos.

Documentação: [`docs/RESELLER_QUOTAS.md`](docs/RESELLER_QUOTAS.md).

## IPv6 / dual-stack — 0.6.8

O MANAGER só habilita IPv6 em uma VPN quando a VPS possui rota IPv6 padrão e endereço global utilizável. Sem isso, WireGuard/OpenVPN continuam IPv4-only e não anunciam `::/0` sem conectividade real.

WireGuard usa:

```text
fd66:66:66::/64
```

OpenVPN usa:

```text
fd66:8::/64
```

O modo portátil atual usa ULA + NAT66. Instalações WireGuard/OpenVPN já gerenciadas podem ser reconciliadas para dual-stack sem recriar identidades e, no caso do WireGuard, sem trocar chaves dos clientes.

O `IPv6 Guard` não substitui o Session Engine. Ele espelha a decisão de lease/política no forwarding IPv6 e cria somente regras específicas por identidade, removendo-as quando a lease volta a ser válida.

```bash
manager --ipv6-status
```

O provisionamento unificado herda o estado dual-stack do servidor. WireGuard retorna `wireguard_ipv4` e `wireguard_ipv6`, mantendo `wireguard_ip` como alias compatível do IPv4.

Documentação: [`docs/IPV6.md`](docs/IPV6.md).

## O limite que prepara a Colmeia

Hoje autoridade de lease, produto, accounting e cota de revenda ainda é local na VPS. O modelo já representa o comportamento planejado para a Colmeia:

```text
Maria
product = global-premium
allowed_regions = BR, US, DE, FR, ...
max_sessions = 1
```

No futuro, o Hub substituirá locks locais por autoridade global sem mudar os conceitos de produto, ACL, identidade, cota, `session_id`, TTL, heartbeat e `session_epoch`.

## Backup e migração

Backups de configuração ficam em `/var/backups/manager/` e incluem, quando presentes:

```text
/etc/manager/access
/etc/manager/connection
/etc/manager/proxy
/var/lib/manager/identity-usage/identities
estado WireGuard/OpenVPN
DNS/TLS/banner/performance
```

Slots de identidade e cotas por produto estão sob `/etc/manager/access`, portanto participam do backup existente. Estado dual-stack fica nos diretórios WireGuard/OpenVPN dentro de `/etc/manager`; leases e regras runtime não entram no backup.

A exportação de usuários Linux é separada e não guarda senha em texto claro nem substitui `/etc/passwd`/`etc/shadow` inteiros durante restauração.

O detector de legado reconhece estruturas como `/root/usuarios.db`, `/etc/SSHPlus/senha/` e `/root/backup.vps`.

## Segurança

- hardening OpenSSH por drop-in;
- Fail2ban;
- UFW com proteção da porta SSH detectada e cobertura IPv6 habilitada;
- atualizações automáticas de segurança;
- TLS/Let's Encrypt;
- fingerprints de chaves públicas;
- Squid sem `http_access allow all`;
- nada de flush global de firewall IPv4 ou IPv6;
- credenciais VPN com permissões restritas;
- estado de identidade, produto, revenda e accounting restritos a root;
- OpenVPN não recebe acesso root ao Lease Engine;
- IPv6 Guard cria/remova somente regras específicas da identidade;
- hooks externos são removidos antes de uninstall/rollback;
- franquia SSH não é bloqueada com dados incompletos;
- provisionamento não registra senha/chaves privadas no audit log;
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
manager --reseller-usage OWNER    uso/cota total por identidade
manager --reseller-product-quota OWNER PRODUCT
                                  uso/cota do produto na revenda
manager --provision ID PLAN [OWNER] [PROTOCOLS]
                                  provisiona identidade + plano + acessos
manager --revoke-identity ID      revoga acessos e preserva identidade desativada
manager --identity-sessions [ID]  sessões reais observadas
manager --leases [ID]             leases autorizadas
manager --usage [ID]              tráfego/atividade consolidada
manager --ipv6-status             estado dual-stack e IPv6 Guard
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

Alias clássico: `menu`.

## Atualização, rollback e remoção

Atualização: opção `90` no menu.

Rollback:

```bash
manager-rollback
```

Desinstalar preservando estado:

```bash
manager-uninstall
```

Identidades, produtos, cotas/slots de revenda, ACL, baseline de franquia, `session_epoch`, estado dual-stack e histórico consolidado de uso ficam preservados no uninstall normal. Regras runtime do IPv6 Guard são removidas e recriadas na reinstalação.

Purge explícito:

```bash
manager-uninstall --purge
```

O purge remove também o estado em `/etc/manager` e o histórico em `/var/lib/manager/identity-usage`, restaurando o forwarding IPv4/IPv6 anterior quando conhecido. Pacotes do sistema, certificados Let's Encrypt, backups, grupos potencialmente pré-existentes e regras UFW alheias ao MANAGER continuam sendo tratados conservadoramente.

## Roadmap

Plano detalhado: [`docs/ROADMAP.md`](docs/ROADMAP.md).

```text
0.5.x  paridade SSHPlus útil
0.6.x  Connection Engine, políticas, leases, accounting, produtos, provisionamento, revenda e dual-stack
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

Planejado: identidade criptográfica por nó, regiões/pools, capacidade/health, drain/failover, sticky sessions, sessão global por identidade/plano, cota global de revenda, lease/fencing global, agregação de uso e comunicação autenticada/criptografada.

### Telegram

Administração futura por Bot + Mini App, sem painel web administrativo convencional obrigatório.

## Testes

O CI cobre:

- `bash -n` e ShellCheck;
- padrões destrutivos de firewall/permissão;
- regressão contra Squid aberto;
- política segura de fonte do instalador;
- instalação/update/rollback/uninstall;
- Connection/Policy/Session Engine;
- Protocol Lease Bridge e lifecycle;
- Identity Usage e persistência;
- Product Policy, ACL e franquias;
- Unified Provisioning e revogação;
- cotas de revenda por identidade, hierarquia pai/subrevendedor, produtos, adoção de SSH legado, migração e persistência;
- IPv6 dual-stack, endpoint literal IPv6, guard por lease e persistência no lifecycle.

## Origem

O SSHPlus Manager original foi desenvolvido por **@crazy_vpn** e deu origem a vários forks comunitários. O MANAGER preserva a ideia de administração simples por terminal, mas evolui para uma arquitetura própria de identidade, automação, leases, accounting, produtos e operação multi-servidor.
