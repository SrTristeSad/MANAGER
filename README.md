# MANAGER

Gerenciador moderno de VPS inspirado na experiência clássica do **SSHPlus Manager**, reconstruído para Debian/Ubuntu atuais.

> O objetivo não é executar cegamente binários antigos do SSHPlus. O MANAGER preserva capacidades úteis, substitui implementações inseguras/obsoletas e prepara uma arquitetura própria para Automation v2, Telegram e Modo Colmeia.

Versão atual: **0.6.1**.

## Princípios

- não substituir o `sshd_config` inteiro;
- não executar `iptables -F`, `ip6tables -F` ou `nft flush ruleset`;
- não baixar executáveis opacos como root;
- validar configurações antes de recarregar serviços;
- manter módulos opcionais realmente opcionais;
- criar backup/rollback antes de mudanças críticas;
- preservar configurações que não pertencem ao MANAGER sempre que possível;
- compatibilidade com o legado não significa copiar fragilidades do legado;
- integrações futuras devem usar operações estruturadas, nunca shell remoto arbitrário.

## Recursos atuais

### Servidor, SSH e VPN

- informações do sistema: SO, kernel, uptime, memória, disco, carga, IPs e serviços;
- usuários SSH: criar/remover, senha, validade, limite simultâneo, bloqueio, sessões e desconexão;
- usuários teste com duração em minutos e remoção automática por `systemd timer`;
- listagem e limpeza confirmada de expirados;
- banner SSH por `sshd_config.d`, validado com `sshd -t`;
- WireGuard com servidor `wg0`, clientes, revogação, QR Code e NAT específico;
- OpenVPN com PKI Easy-RSA, clientes `.ovpn`, CRL e UDP/TCP;
- DNS Ad Block com dnsmasq, whitelist/blacklist e atualização diária;
- hosts de proxy gerenciados;
- Squid privado, proxy TCP, WebSocket e TLS opcionais.

### Contas e revenda

- revendedor e subrevendedor;
- hierarquia e bloqueio/reativação;
- cotas;
- propriedade de contas SSH;
- cota do revendedor incluindo contas dos seus subrevendedores;
- criação de usuário SSH diretamente vinculada ao proprietário;
- validação de cota antes e durante a criação para evitar corrida;
- exportação/restauração segura de usuários SSH;
- detector de estruturas conhecidas do SSHPlus antigo;
- monitor moderno de sessões SSH com encerramento seletivo por TTY.

O estado de revenda fica em:

```text
/etc/manager/access/
```

## Connection Engine

A partir da série 0.6, a identidade lógica deixa de depender do `/etc/passwd`.

Exemplo:

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

Uma identidade pode existir sem ser necessariamente um usuário Linux e pode agrupar diferentes recursos de conexão.

Estado:

```text
/etc/manager/connection/identities/
```

As identidades não duplicam senhas, chaves privadas WireGuard ou certificados OpenVPN. Elas apenas vinculam a política aos recursos técnicos existentes.

Documentação detalhada: [`docs/CONNECTION_ENGINE.md`](docs/CONNECTION_ENGINE.md).

## Policy Enforcement — 0.6.1

A política da identidade agora é aplicada aos protocolos vinculados.

### Estado e expiração

O estado efetivo pode ser:

```text
active
disabled
expired
```

Uma identidade `disabled` ou `expired` deixa de ter seus recursos vinculados disponíveis conforme o protocolo.

### SSH

O MANAGER gera somente:

```text
/etc/ssh/sshd_config.d/65-manager-identity-policy.conf
/etc/security/limits.d/98-manager-identity.conf
```

O primeiro usa `DenyUsers` para identidades inativas, cobrindo autenticação por senha e chave pública. O segundo aplica o limite local disponível para SSH.

Antes de recarregar o OpenSSH, o MANAGER executa `sshd -t` e reverte a alteração se a configuração for recusada.

Sessões SSH existentes de uma identidade que se torna inativa são encerradas seletivamente por TTY. `root` não é alvo dessa política.

### WireGuard

Uma identidade inativa tem o peer removido da interface `wg0` em runtime.

O MANAGER **não apaga**:

```text
chave privada do cliente
chave pública
PSK
arquivo de configuração
registro do peer no estado persistente
```

Ao reativar a identidade, o peer pode ser reconstruído no runtime usando as credenciais existentes.

### OpenVPN

O OpenVPN recebe um `client-connect` gerenciado pelo MANAGER para consultar a política antes de aceitar uma nova conexão de um cliente vinculado.

Uma identidade desativada não tem o certificado revogado apenas por causa do bloqueio temporário. Se já estiver conectada, o MANAGER pode bloquear especificamente o tráfego daquele IP virtual até a política voltar a permitir acesso.

Quando a instalação do hook exigiria reiniciar um OpenVPN com clientes ativos, o restart é adiado para não derrubar sessões válidas somente para instalar a integração.

## Sessões por identidade

Visão consolidada:

```bash
manager --identity-sessions
```

Uma identidade:

```bash
manager --identity-sessions maria
```

Exemplo conceitual:

```text
maria  active  ssh=0  wg=1  ovpn=0  total=1  max=1
```

O Connection Engine observa SSH, WireGuard e OpenVPN sob a mesma identidade.

### `max_sessions`

Na 0.6.1 o limite já começa a valer **localmente**:

- SSH recebe o número de vagas restante via `maxlogins`;
- OpenVPN consulta o total antes de uma nova conexão;
- WireGuard não é reativado para uma nova sessão quando as vagas já estão ocupadas por outro protocolo;
- desativação/expiração continua tendo precedência sobre o limite.

Isso ainda não é o futuro limite global multi-VPS. Protocolos independentes podem ter pequenas janelas de corrida local. A garantia forte entre servidores será feita pela Colmeia com lease atômico/fencing.

## Reconciliação automática

O enforcement é mantido por:

```text
manager-policy-reconcile.path
manager-policy-reconcile.timer
manager-policy-reconcile.service
```

O watcher reage a mudanças de identidade e o timer periódico cobre expiração, handshakes e mudanças de sessão.

Também é possível reconciliar manualmente pelo menu ou por:

```bash
/opt/manager/modules/policy_engine.sh --reconcile
```

## Hosts de proxy

Lista moderna:

```text
/etc/manager/proxy/hosts.txt
```

O módulo permite listar, adicionar, remover e importar domínios válidos de um `payload.txt` antigo sem copiar cegamente configurações legadas.

```bash
manager --proxy-hosts
```

## Proxies e túneis

Estado:

```text
/etc/manager/proxy/
```

Disponíveis:

- Squid privado em configuração própria do MANAGER;
- TCP por `socat` para backend local;
- WebSocket por `websockify` para backend local;
- TLS por `stunnel4` para backend local.

O Squid do MANAGER não nasce como proxy aberto. TCP/WebSocket/TLS encaminham somente para `127.0.0.1:<porta>` e não liberam UFW automaticamente.

Reconciliação:

```bash
/opt/manager/modules/proxies.sh --reconcile
```

Status:

```bash
manager --proxy-status
```

## Backup e migração

Backups de configuração ficam em:

```text
/var/backups/manager/
```

O backup inclui, quando presentes:

```text
/etc/manager/access
/etc/manager/connection
/etc/manager/proxy
estado WireGuard/OpenVPN
DNS/TLS/banner/performance
configurações próprias do MANAGER
```

Os arquivos são restritos a root e acompanhados de SHA-256.

A exportação de usuários Linux fica separada em:

```text
/var/backups/manager/users/
```

Ela preserva hash de autenticação existente, validade, shell, limite e proprietário, sem guardar senha em texto claro e sem substituir `/etc/passwd`, `/etc/shadow`, `/etc/group` ou `/etc/gshadow` inteiros durante restauração.

O detector de legado reconhece estruturas como:

```text
/root/usuarios.db
/etc/SSHPlus/senha/
/root/backup.vps
```

A conversão específica do SSHPlus continuará sendo assistida/controlada; o MANAGER não restaura cegamente arquivos de sistema antigos.

## Segurança

- hardening OpenSSH por `sshd_config.d`;
- Fail2ban;
- UFW com proteção da porta SSH detectada;
- atualizações automáticas de segurança;
- TLS/Let's Encrypt via Certbot isolado;
- chaves públicas SSH com fingerprints;
- Squid sem `http_access allow all`;
- nada de flush global de firewall;
- credenciais VPN com permissões restritas;
- Connection Engine root-only;
- alterações SSH validadas antes de reload;
- atualização baixada para arquivo temporário e validada com `bash -n`.

## Monitoramento e manutenção

- health check;
- diagnóstico de rede/DNS/SSH/NTP/recursos;
- tráfego/conexões e vnStat opcional;
- monitor SSH;
- logs;
- backup/restore;
- BBR + fq reversível;
- manutenção APT/NTP/journal;
- serviços;
- Speedtest/ping com histórico;
- self-update;
- rollback;
- uninstall conservador e `--purge` separado.

## CLI

```text
manager --health                 health check (0=OK, 1=aviso, 2=crítico)
manager --status                 status dos serviços
manager --expired                contas SSH expiradas
manager --ssh-sessions           sessões SSH
manager --proxy-status           proxies/túneis
manager --proxy-hosts            hosts permitidos no proxy
manager --identities             identidades do Connection Engine
manager --identity ID            detalhes de uma identidade
manager --identity-sessions [ID] sessões agregadas por identidade
manager --diagnostics            diagnóstico
manager --version                versão
manager --help                   ajuda
```

## Menu principal

```text
SERVIDOR E VPN
 1) Informações do sistema
 2) Usuários SSH
 3) WireGuard VPN
 4) OpenVPN
 5) Bloqueio de anúncios DNS
19) Banner SSH
25) Hosts do proxy
26) Proxies e túneis

SEGURANÇA
 6) Segurança / hardening SSH
 7) Firewall
 8) Fail2ban
 9) TLS / Let's Encrypt
18) Chaves públicas SSH

CONTAS E REVENDA
22) Monitor de sessões SSH
23) Backup / migração de usuários
24) Revendedores, subrevendedores e cotas
27) Criar conta vinculada a revendedor
28) Connection Engine / identidades
29) Sessões / reconciliar políticas de identidade

MONITORAMENTO E MANUTENÇÃO
10) Tráfego e conexões
11) Diagnóstico
12) Backup e rollback
13) Desempenho / BBR
14) Logs
15) Assistente / perfis
16) Saúde do servidor
17) Manutenção do sistema
20) Serviços
21) Speedtest / latência

90) Atualizar MANAGER
 0) Sair
```

## Sistemas suportados

Nesta implementação:

- Ubuntu 22.04 ou superior;
- Debian 12 ou superior;
- `systemd` e `apt` são necessários.

A matriz de testes será ampliada para as distribuições modernas previstas no roadmap.

## Instalação

Evite executar instalador remoto diretamente por pipe. Baixe, valide e execute:

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

Atualização pelo menu:

```text
90) Atualizar MANAGER
```

Rollback:

```bash
manager-rollback
```

Desinstalar o código preservando estado/configuração:

```bash
manager-uninstall
```

O enforcement de identidades é desanexado antes de remover o código, evitando deixar hooks dependentes de `/opt/manager` quebrados. O estado em `/etc/manager` é preservado e pode voltar a ser aplicado em uma reinstalação.

Remover também o estado próprio do MANAGER:

```bash
manager-uninstall --purge
```

O purge continua preservando pacotes do sistema, certificados Let's Encrypt, backups e regras UFW que não devem ser apagados implicitamente.

## Roadmap

Plano detalhado: [`docs/ROADMAP.md`](docs/ROADMAP.md).

```text
0.5.x  paridade SSHPlus útil
0.6.x  Connection Engine, políticas, sessões e produtos
0.7.0  Legacy v1 + Automation v2
0.8.0  Modo Colmeia
0.9.0  Telegram Bot + Mini App
0.9.5  migração e escala
1.0.0  release de produção
```

### Legacy v1

Será **uma única conexão de compatibilidade** com o ecossistema `syncpainel`, não um adaptador diferente para cada versão de painel.

Em instalação nova ficará desligado por padrão e poderá ser ativado/desativado completamente.

### Automation v2

Será o protocolo novo, com ações estruturadas, RBAC, auditoria, idempotência, autenticação criptográfica, anti-replay e interface privilegiada controlada. Integrações não receberão shell arbitrário.

### Colmeia

A Colmeia poderá reunir VPS no mesmo datacenter, mesma cidade, mesmo país ou em vários países.

Planejado:

- identidade criptográfica por nó;
- regiões/pools;
- weighted load balancing;
- capacidade por nó;
- sticky sessions;
- drain;
- health/heartbeat;
- failover;
- sessão global por identidade/plano;
- lease atômico e fencing;
- comunicação autenticada/criptografada.

Assim uma identidade poderá, por exemplo, ter acesso a dez servidores mas continuar com `max_sessions_global=1`.

### Telegram

Administração remota futura por Telegram Bot + Telegram Mini App, sem painel web administrativo convencional. Identidade e autorização serão verificadas no backend.

## Testes

O CI executa:

- `bash -n`;
- ShellCheck;
- regressões contra padrões destrutivos;
- regressão contra Squid aberto;
- política segura de fontes do instalador;
- instalação/update/rollback/uninstall;
- smoke tests das CLIs;
- Connection Engine CRUD básico;
- sessões agregadas por identidade;
- bloqueio e reativação de identidade SSH vinculada;
- instalação e remoção das unidades de enforcement.

Roteiro adicional para VPS real:

```text
docs/TESTING.md
```

## Origem

O SSHPlus Manager original foi desenvolvido por **@crazy_vpn** e deu origem a vários forks comunitários. O MANAGER preserva a ideia de administração simples por terminal, mas evolui para uma arquitetura própria de identidade, automação e operação multi-servidor.
