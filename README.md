# MANAGER

Gerenciador moderno de VPS inspirado na experiência clássica do **SSHPlus Manager**, reconstruído para Debian/Ubuntu atuais.

> O objetivo não é executar cegamente binários antigos do SSHPlus. O MANAGER preserva capacidades úteis, substitui implementações inseguras/obsoletas e evolui para uma arquitetura própria de identidade, automação, VPN, revenda e operação multi-servidor.

Versão atual: **0.8.0**.

## Princípios

- não substituir o `sshd_config` inteiro;
- não executar flush global de firewall;
- não baixar executáveis opacos como root;
- validar configurações antes de recarregar serviços;
- preservar configurações alheias ao MANAGER sempre que possível;
- compatibilidade com legado não significa copiar fragilidades do legado;
- integrações novas usam operações estruturadas e nunca shell remoto arbitrário;
- senhas/chaves privadas não são persistidas pelo servidor para replay posterior;
- autenticação, freshness, anti-replay, rate limit e autorização são reavaliados antes do replay idempotente;
- a Colmeia estabelece confiança criptográfica antes de introduzir scheduler ou autoridade global de sessões.

## Recursos atuais

### Servidor, SSH e VPN

- informações do sistema, kernel, uptime, memória, disco, carga, IPs e serviços;
- usuários SSH, validade, limite simultâneo, bloqueio e sessões;
- contas teste e limpeza de expirados;
- WireGuard e OpenVPN com dual-stack quando a VPS possui IPv6 real;
- IPv6 Guard ligado ao Policy/Session Engine;
- UFW, Fail2ban, hardening SSH, DNS Ad Block, TLS e diagnósticos;
- Squid privado, proxy TCP, WebSocket e TLS opcionais.

### Revenda, produtos e provisionamento

- revendedor e subrevendedor;
- cota total por identidade lógica e cota opcional por produto;
- identidades VPN-only sem usuário Linux;
- hierarquia de cotas pai/subrevendedor;
- catálogo de produtos com protocolos, `max_sessions`, validade, franquia e ACL de região/pool/nó;
- provisionamento transacional de SSH/WireGuard/OpenVPN;
- revogação centralizada preservando identidade histórica.

## Connection / Policy / Session Engine

A série 0.6 separou identidade lógica dos recursos técnicos.

```text
maria
├── owner = revenda01
├── enabled = 1
├── max_sessions = 1
├── protocols = ssh,wireguard,openvpn
├── ssh_user = maria
├── wireguard_client = maria
└── openvpn_client = maria
```

Estado principal:

```text
/etc/manager/connection/
```

O Session Engine mantém leases locais com `session_id`, TTL, heartbeat, `session_epoch`, fencing e limite atômico de sessões. O Protocol Lease Bridge liga SSH, WireGuard e OpenVPN ao mesmo motor.

Comandos úteis:

```bash
manager --identities
manager --identity maria
manager --identity-sessions maria
manager --leases maria
manager --usage maria
manager --products
manager --product premium
manager --product-assignment maria
manager --provision maria premium
manager --revoke-identity maria
```

Documentação principal:

- [`docs/CONNECTION_ENGINE.md`](docs/CONNECTION_ENGINE.md)
- [`docs/SESSION_ENGINE.md`](docs/SESSION_ENGINE.md)
- [`docs/IDENTITY_USAGE.md`](docs/IDENTITY_USAGE.md)
- [`docs/PRODUCTS.md`](docs/PRODUCTS.md)
- [`docs/PROVISIONING.md`](docs/PROVISIONING.md)
- [`docs/RESELLER_QUOTAS.md`](docs/RESELLER_QUOTAS.md)

## Identidade do nó

Cada VPS possui `node_id` persistente e metadados administrativos como país, região, pool, provedor, cidade, capacidade e peso.

```bash
manager --node
manager --node-context
manager --node-set region BR-SP
manager --node-set pool BRASIL-PREMIUM
```

A telemetria local continua explicitamente não autoritativa para billing global:

```text
usage_scope=node-local
billing_authoritative=0
global_usage_supported=0
```

## Automation Legacy v1 — 0.7.0

Compatibilidade controlada com o antigo ecossistema `syncpainel`. Fica **desligada por padrão**.

```bash
manager automation legacy status
manager automation legacy enable [PORT]
manager automation legacy disable
manager automation legacy restart
manager automation legacy rotate-password
```

O Legacy usa conta não-root, listener OpenSSH dedicado, `ForceCommand`, sudoers exato e allowlist. Não há `eval`, shell root remoto, `chmod 777`, banco de senha em texto claro ou flush global de firewall.

Documentação: [`docs/AUTOMATION_LEGACY.md`](docs/AUTOMATION_LEGACY.md).

## Automation v2 — 0.7.1 a 0.7.4

A Automation v2 é a interface oficial para integrações novas. A 0.7.4 fecha a série 0.7 com transporte remoto próprio sobre TLS 1.3, timestamp/nonce assinados, anti-replay e rate limiting.

### Serviços e fronteiras

Local:

```text
manager-automation-v2.service
/run/manager-automation-v2/manager.sock
/usr/local/sbin/managerd
/usr/local/sbin/managerctl
```

Remoto, somente quando habilitado:

```text
manager-automation-v2-remote.service
```

O socket Unix continua privilegiado, `0600`, com runtime `0700` e autenticação de `local-root` por `SO_PEERCRED`. O gateway remoto apenas termina TLS e encaminha o envelope estruturado ao `managerd`; autenticação, anti-replay, RBAC, idempotência e dispatcher continuam no daemon local.

### Status de segurança

```text
transport=unix,tls1.3
remote_transport=1
rbac=1
cryptographic_auth=1
credential_algorithm=ed25519
auth_scheme=ed25519-v2
timestamp_signed=1
timestamp_window_seconds=120
nonce_signed=1
anti_replay=1
rate_limit=1
principal_action_rate_limit=1
remote_source_burst_limit=1
tls_server_pinning=sha256
remote_local_root=0
idempotency=1
audit=1
secret_replay=0
```

`remote_transport=1` indica capacidade disponível; o listener remoto continua opt-in.

### Principals e credenciais

Papéis: `admin`, `reseller`, `subreseller` e `user`.

```text
/etc/manager/automation/v2/principals/
/etc/manager/automation/v2/credentials/<principal>/
```

O servidor mantém apenas chave pública, `key_id`, fingerprint e estado. A chave privada fica no arquivo `.credential` externo.

```bash
manager automation v2 principal create loja01 reseller loja01 premium,basic
manager automation v2 credential enroll loja01 /root/loja01.credential
manager automation v2 credential rotate loja01 /root/loja01-v2.credential
manager automation v2 credential revoke loja01 ed25519-0123456789abcdef
```

Para principals não-locais, a assinatura cobre contrato, versão, `request_id`, `principal_id`, ação, parâmetros, `issued_at` e nonce. O timestamp precisa estar dentro de 120 segundos e o nonce só pode ser consumido uma vez.

Retry idempotente usa novo timestamp/nonce/assinatura, mas pode reutilizar o mesmo `request_id` lógico.

### Rate limiting e transporte TLS 1.3

```text
leituras: 120 req/min, burst 20
escritas:  30 req/min, burst 8
```

O gateway também limita burst por IP remoto.

```bash
manager automation v2 remote enable 203.0.113.10 9443
manager automation v2 remote status
manager automation v2 remote rotate-certificate
manager automation v2 remote disable
```

O cliente remoto exige pin SHA-256 explícito:

```bash
managerctl \
  --credential /root/loja01.credential \
  --remote 203.0.113.10:9443 \
  --server-fingerprint SHA256:<64-hex> \
  connection.status id=maria
```

IPv6 usa `[2001:db8::10]:9443`. O MANAGER não abre a porta no firewall automaticamente.

### Ações allowlisted

```text
system.describe
node.usage
connection.preflight
connection.create
connection.status
connection.revoke
```

Não existe shell/comando/caminho arbitrário.

Documentação: [`docs/AUTOMATION_V2.md`](docs/AUTOMATION_V2.md).

## Colmeia — 0.8.0

A 0.8.0 inicia o modo multi-servidor criando a raiz de confiança entre nós e controlador, sem ainda ativar heartbeat, scheduler ou leases globais.

Cada VPS recebe uma identidade Ed25519 ligada ao `node_id`:

```text
/etc/manager/hive/node/
```

O controlador mantém sua identidade e o registry público dos nós aprovados:

```text
/etc/manager/hive/controller/
```

Fluxo:

```text
nó cria request assinado
        ↓
controlador valida e aprova
        ↓
controlador emite bundle assinado
        ↓
nó aceita somente com fingerprint pinado do controlador
```

Comandos principais:

```bash
manager hive status
manager hive request /root/node-request.json
manager hive controller init
manager hive controller fingerprint
manager hive controller approve /root/node-request.json /root/node-bundle.json
manager hive accept /root/node-bundle.json SHA256:<fingerprint-controlador>
manager hive controller list
manager hive controller show NODE_ID
manager hive controller revoke NODE_ID [REASON]
manager hive controller reenroll REQUEST OUT
```

Revogação incrementa `node_epoch`. Re-enrollment explícito gera uma geração nova; bundles antigos ficam cercados por fencing e não podem rebaixar o nó para uma autoridade anterior.

Estado da 0.8.0:

```text
cryptographic_node_identity=1
controller_identity=1
signed_enrollment=1
controller_fingerprint_pinning=1
node_epoch_fencing=1
heartbeat=0
node_health=0
scheduler=0
global_lease_authority=0
global_accounting=0
```

O estado da Colmeia entra no backup protegido do MANAGER e pode conter chaves privadas de nó/controlador; trate o backup como segredo operacional. Uninstall normal preserva a confiança, purge remove o estado server-side.

Documentação: [`docs/HIVE.md`](docs/HIVE.md).

## Backup, rollback e remoção

```bash
manager-rollback
manager-uninstall
manager-uninstall --purge
```

Uninstall normal fecha listeners/socket e remove código, mas preserva estado durável necessário para reinstalação, incluindo Automation v2 e confiança da Colmeia. O purge remove estado server-side. Arquivos privados externos de credencial da Automation não são apagados automaticamente.

## Segurança

- nenhum flush global de firewall IPv4/IPv6;
- Squid sem `http_access allow all`;
- credenciais VPN com permissões restritas;
- provisionamento não registra senha/chaves privadas no audit;
- cache de idempotência não persiste senha gerada;
- ACL restrita de região/pool/nó falha fechada;
- Legacy v1 usa conta não-root, SSH dedicado, `ForceCommand` e allowlist;
- Automation v2 usa TLS 1.3 + pin SHA-256 no remoto;
- principals não-locais usam Ed25519 v2 com timestamp/nonce;
- nonce repetido falha fechado;
- rate limit existe no daemon e gateway remoto;
- Colmeia usa Ed25519 e pin do controlador no trust bootstrap;
- `node_epoch` impede aceitar bundle antigo após revogação/re-enrollment;
- nenhuma ação estruturada aceita shell/comando/caminho arbitrário.

## CLI principal

```text
manager --health
manager --status
manager --identities
manager --identity ID
manager --products
manager --product ID
manager --provision ID PLAN [OWNER] [PROTOCOLS]
manager --revoke-identity ID
manager --leases [ID]
manager --usage [ID]
manager --ipv6-status
manager --node
manager --node-context
manager --node-set FIELD VALUE
manager hive status
manager hive request OUT
manager hive accept BUNDLE CONTROLLER_FP
manager hive controller init|status|fingerprint|list
manager hive controller show NODE_ID
manager hive controller approve REQUEST OUT
manager hive controller reenroll REQUEST OUT
manager hive controller revoke NODE_ID [REASON]
manager automation legacy status
manager automation v2 status
manager automation v2 principals
manager automation v2 credentials ID
manager automation v2 remote status
managerctl [--credential FILE] [--remote IP:PORT] [--server-fingerprint SHA256:HEX] ACTION [key=value ...]
manager --diagnostics
manager --version
```

## Sistemas suportados

- Ubuntu 22.04 ou superior;
- Debian 12 ou superior;
- `systemd` e `apt`.

## Instalação

```bash
sudo -i
curl -fL --proto '=https' --tlsv1.2 \
  https://raw.githubusercontent.com/SrTristeSad/MANAGER/main/install.sh \
  -o /tmp/manager-install.sh
bash -n /tmp/manager-install.sh
bash /tmp/manager-install.sh
rm -f /tmp/manager-install.sh
```

Depois: `manager`. Alias clássico: `menu`.

## Roadmap

Plano detalhado: [`docs/ROADMAP.md`](docs/ROADMAP.md).

```text
0.5.x  paridade SSHPlus útil                                         ✅
0.6.x  Connection/Policy/Session Engine completo                     ✅
0.7.x  Automation Engine segura/remota                               ✅
0.8.0  Colmeia — identidade e enrollment de nós                      ✅
0.8.1  heartbeat + saúde de nós                                      próximo
0.8.2  scheduler / drain / failover
0.8.3  autoridade de leases globais
0.8.4  accounting global
0.8.5  resiliência operacional
0.9.x  Telegram Bot + Mini App
1.0.0  release de produção
```

## Testes

O CI cobre syntax/ShellCheck, lifecycle, Connection/Session Engine, products/quotas, IPv6, Automation v2 e, a partir da 0.8.0:

- geração da identidade Ed25519 do nó;
- identidade do controlador;
- request de enrollment assinado;
- alteração do request detectada;
- fingerprint incorreto do controlador recusado;
- primeiro enrollment em `node_epoch=1`;
- revogação com incremento de epoch;
- re-enrollment explícito;
- bundle antigo recusado por fencing;
- persistência das chaves após uninstall/reinstall;
- purge do estado da Colmeia.

## Origem

O SSHPlus Manager original foi desenvolvido por **@crazy_vpn** e deu origem a vários forks comunitários. O MANAGER preserva a administração simples por terminal, evoluindo para identidade, automação, leases, accounting, produtos e operação multi-servidor.
