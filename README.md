# MANAGER

Gerenciador moderno de VPS inspirado na experiência clássica do **SSHPlus Manager**, reconstruído para Debian/Ubuntu atuais.

> O objetivo não é executar cegamente binários antigos do SSHPlus. O MANAGER preserva capacidades úteis, substitui implementações inseguras/obsoletas e evolui para uma arquitetura própria de identidade, automação, VPN, revenda e operação multi-servidor.

Versão atual: **0.7.4**.

## Princípios

- não substituir o `sshd_config` inteiro;
- não executar flush global de firewall;
- não baixar executáveis opacos como root;
- validar configurações antes de recarregar serviços;
- preservar configurações alheias ao MANAGER sempre que possível;
- compatibilidade com legado não significa copiar fragilidades do legado;
- integrações novas usam operações estruturadas e nunca shell remoto arbitrário;
- senhas/chaves privadas não são persistidas pelo servidor para replay posterior;
- autenticação, freshness, anti-replay, rate limit e autorização são reavaliados antes do replay idempotente.

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

Compatibilidade controlada com o antigo ecossistema `syncpainel`.

Fica **desligada por padrão**.

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

O socket Unix continua privilegiado, `0600`, com runtime `0700` e autenticação de `local-root` por `SO_PEERCRED`.

O gateway remoto não cria uma segunda autoridade: ele termina TLS e encaminha o envelope estruturado ao `managerd` pelo socket Unix. Autenticação, anti-replay, RBAC, idempotência e dispatcher continuam no daemon local.

### Status de segurança da 0.7.4

```text
transport=unix,tls1.3
remote_transport=1
rbac=1
principal_assertion=local-root-peercred-or-ed25519
cryptographic_auth=1
credential_algorithm=ed25519
auth_scheme=ed25519-v2
nonlocal_signature_required=1
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

`remote_transport=1` indica que a capacidade existe. O listener remoto **não precisa estar habilitado**. Consulte:

```bash
manager automation v2 remote status
```

### Principals e credenciais

Papéis:

```text
admin
reseller
subreseller
user
```

Principals:

```text
/etc/manager/automation/v2/principals/
```

Credenciais públicas:

```text
/etc/manager/automation/v2/credentials/<principal>/
```

O servidor mantém somente a chave pública, `key_id`, fingerprint e estado. A chave privada fica no arquivo `.credential` externo criado pelo administrador.

```bash
manager automation v2 principal create loja01 reseller loja01 premium,basic
manager automation v2 credential enroll loja01 /root/loja01.credential
manager automation v2 credential rotate loja01 /root/loja01-v2.credential
manager automation v2 credential revoke loja01 ed25519-0123456789abcdef
```

`local-root` não usa credencial Ed25519 e não é permitido no transporte remoto.

### Envelope Ed25519 v2

Para principals não-locais, a assinatura cobre:

```text
contract
version
request_id
principal_id
action_id
params
issued_at
nonce
```

O `issued_at` precisa estar dentro de uma janela de **120 segundos**. O `nonce` é consumido uma única vez. Reenviar exatamente o mesmo envelope assinado é recusado como replay.

Retry idempotente continua possível: o cliente gera **novo timestamp + novo nonce + nova assinatura**, mas pode reutilizar o mesmo `request_id`. Se principal, ação e payload lógico forem os mesmos, o daemon pode devolver a resposta idempotente cacheada.

### Rate limiting

O daemon aplica token bucket por principal/ação:

```text
leituras: 120 req/min, burst 20
escritas:  30 req/min, burst 8
```

O gateway TLS também possui proteção de burst por origem remota antes de encaminhar ao socket local.

### Transporte remoto TLS 1.3

Habilitar:

```bash
manager automation v2 remote enable 203.0.113.10 9443
```

Desabilitar:

```bash
manager automation v2 remote disable
```

Rotacionar certificado:

```bash
manager automation v2 remote rotate-certificate
```

A saída/status fornece:

```text
server_fingerprint=SHA256:<64 hex>
```

O certificado é Ed25519, armazenado root-only sob:

```text
/etc/manager/automation/v2/tls/
```

A conexão cliente aceita **somente TLS 1.3** e exige pin SHA-256 explícito do certificado. Exemplo:

```bash
managerctl \
  --credential /root/loja01.credential \
  --remote 203.0.113.10:9443 \
  --server-fingerprint SHA256:<64-hex> \
  connection.status id=maria
```

IPv6 usa:

```text
[2001:db8::10]:9443
```

O MANAGER **não abre regra de firewall automaticamente** ao habilitar o gateway. Restrinja a porta às redes/clientes necessários.

### Ações allowlisted

```text
system.describe
node.usage
connection.preflight
connection.create
connection.status
connection.revoke
```

Não existe ação de shell, comando arbitrário, script ou caminho executável informado pelo cliente.

### Ordem de segurança

Para principal não-local:

```text
principal ativo
      ↓
Ed25519 v2 válida
      ↓
timestamp dentro da janela
      ↓
rate limit
      ↓
nonce / anti-replay
      ↓
RBAC / ownership / produto
      ↓
idempotência
      ↓
dispatcher allowlisted
```

Chave revogada, principal desabilitado, timestamp velho/futuro, nonce repetido, excesso de requisições ou escopo RBAC inválido falham antes do dispatcher.

### Auditoria

```text
/var/log/manager/automation-v2-audit.jsonl
```

Além de principal/autenticação/RBAC, a 0.7.4 registra decisões de:

```text
transport
freshness_decision
replay_decision
rate_limit_decision
request_issued_at
```

Assinatura, chave privada, senha e stdout sensível não entram no audit.

Documentação: [`docs/AUTOMATION_V2.md`](docs/AUTOMATION_V2.md).

## Backup, rollback e remoção

```bash
manager-rollback
manager-uninstall
manager-uninstall --purge
```

Uninstall normal fecha os listeners/socket e remove código, mas preserva estado durável necessário para reinstalação, incluindo principals, credenciais públicas e configuração remota. O purge remove estado server-side do MANAGER. Arquivos privados de credencial externos não são apagados automaticamente.

## Segurança

- nenhum flush global de firewall IPv4/IPv6;
- Squid sem `http_access allow all`;
- credenciais VPN com permissões restritas;
- provisionamento não registra senha/chaves privadas no audit;
- cache de idempotência não persiste senha gerada;
- ACL restrita de região/pool/nó falha fechada;
- Legacy v1 usa conta não-root, SSH dedicado, `ForceCommand` e allowlist;
- Automation v2 usa TLS 1.3 + pin SHA-256 no transporte remoto;
- principals não-locais usam Ed25519 v2 com timestamp/nonce;
- nonce repetido falha fechado;
- rate limit existe no daemon e no gateway remoto;
- chave revogada e principal/revenda desabilitados falham fechado na próxima requisição;
- nenhuma ação estruturada aceita shell/comando/caminho arbitrário.

## CLI principal

```text
manager --health
manager --status
manager --expired
manager --ssh-sessions
manager --proxy-status
manager --identities
manager --identity ID
manager --products
manager --product ID
manager --reseller-usage OWNER
manager --provision ID PLAN [OWNER] [PROTOCOLS]
manager --revoke-identity ID
manager --identity-sessions [ID]
manager --leases [ID]
manager --usage [ID]
manager --ipv6-status
manager --node
manager --node-context
manager --node-set FIELD VALUE
manager automation legacy status
manager automation legacy enable [PORT]
manager automation legacy disable
manager automation v2 status
manager automation v2 principals
manager automation v2 principal create ID ROLE SUBJECT [PRODUCTS]
manager automation v2 credentials ID
manager automation v2 credential enroll ID /CAMINHO/ARQUIVO
manager automation v2 credential rotate ID /CAMINHO/ARQUIVO
manager automation v2 credential revoke ID KEY_ID
manager automation v2 remote status
manager automation v2 remote enable BIND_IP [PORT]
manager automation v2 remote disable
manager automation v2 remote rotate-certificate
managerctl [--principal ID] [--credential FILE] [--remote IP:PORT] [--server-fingerprint SHA256:HEX] ACTION [key=value ...] [--request-id ID]
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

Depois:

```bash
manager
```

Alias clássico: `menu`.

## Roadmap

Plano detalhado: [`docs/ROADMAP.md`](docs/ROADMAP.md).

```text
0.5.x  paridade SSHPlus útil                                         ✅
0.6.x  Connection/Policy/Session Engine completo                     ✅
0.7.0  Automation Legacy v1                                          ✅
0.7.1  Automation v2 — núcleo local estruturado                       ✅
0.7.2  Principals + RBAC                                              ✅
0.7.3  autenticação Ed25519 + enrollment/rotação/revogação            ✅
0.7.4  anti-replay + rate limit + transporte remoto TLS 1.3           ✅
0.8.x  Modo Colmeia                                                   próximo
0.9.x  Telegram Bot + Mini App
0.9.5  migração e escala
1.0.0  release de produção
```

A próxima etapa é **0.8.x: Modo Colmeia**, começando por identidade/enrollment de nós, heartbeat e saúde, antes de scheduler, drain/failover e leases globais.

## Testes

O CI cobre, entre outros:

- syntax/ShellCheck e regressões de segurança;
- install/update/rollback/uninstall;
- Connection/Policy/Session Engine e Protocol Lease Bridge;
- accounting, produtos/ACL, revenda e IPv6;
- Legacy v1;
- Automation v2 Core, Authentication e RBAC;
- assinatura Ed25519 v2;
- timestamp velho/futuro recusado;
- replay do mesmo envelope recusado;
- retry idempotente com nonce novo;
- rate limiting por principal/ação;
- TLS 1.3 e rejeição de TLS 1.2;
- pin SHA-256 incorreto recusado;
- rotação do certificado;
- lifecycle do gateway remoto;
- persistência após uninstall/reinstall e purge explícito.

## Origem

O SSHPlus Manager original foi desenvolvido por **@crazy_vpn** e deu origem a vários forks comunitários. O MANAGER preserva a ideia de administração simples por terminal, mas evolui para uma arquitetura própria de identidade, automação, leases, accounting, produtos e operação multi-servidor.
