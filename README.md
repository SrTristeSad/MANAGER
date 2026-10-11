# MANAGER

Gerenciador moderno de VPS inspirado na experiência clássica do **SSHPlus Manager**, reconstruído para Debian/Ubuntu atuais.

> O objetivo não é executar cegamente binários antigos do SSHPlus. O MANAGER preserva capacidades úteis, substitui implementações inseguras/obsoletas e evolui para uma arquitetura própria de identidade, automação, VPN, revenda e operação multi-servidor.

Versão atual: **0.7.3**.

## Princípios

- não substituir o `sshd_config` inteiro;
- não executar flush global de firewall;
- não baixar executáveis opacos como root;
- validar configurações antes de recarregar serviços;
- preservar configurações alheias ao MANAGER sempre que possível;
- compatibilidade com legado não significa copiar fragilidades do legado;
- integrações novas usam operações estruturadas e nunca shell remoto arbitrário;
- senhas/chaves privadas não são persistidas pelo servidor para replay posterior;
- autenticação e autorização são camadas separadas e ambas são reavaliadas antes do replay idempotente.

## Recursos atuais

### Servidor, SSH e VPN

- informações do sistema, kernel, uptime, memória, disco, carga, IPs e serviços;
- usuários SSH, validade, limite simultâneo, bloqueio e sessões;
- contas teste e limpeza de expirados;
- WireGuard e OpenVPN com dual-stack quando a VPS possui IPv6 real;
- IPv6 Guard ligado ao Policy/Session Engine;
- UFW, Fail2ban, hardening SSH, DNS Ad Block, TLS e diagnósticos;
- Squid privado, proxy TCP, WebSocket e TLS opcionais.

### Revenda e produtos

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
```

Documentação:

- [`docs/CONNECTION_ENGINE.md`](docs/CONNECTION_ENGINE.md)
- [`docs/SESSION_ENGINE.md`](docs/SESSION_ENGINE.md)
- [`docs/IDENTITY_USAGE.md`](docs/IDENTITY_USAGE.md)

## Produtos, ACL e provisionamento

```bash
manager --products
manager --product premium
manager --product-assignment maria
manager --provision maria premium
manager --revoke-identity maria
```

Produtos podem restringir protocolo, sessões, validade, franquia e ACL de região/pool/nó. ACL local usa automaticamente os metadados do nó quando o chamador não fornece contexto explícito.

Documentação:

- [`docs/PRODUCTS.md`](docs/PRODUCTS.md)
- [`docs/PROVISIONING.md`](docs/PROVISIONING.md)
- [`docs/RESELLER_QUOTAS.md`](docs/RESELLER_QUOTAS.md)
- [`docs/NODE_PRODUCT_ACL.md`](docs/NODE_PRODUCT_ACL.md)

## Identidade do nó e telemetria local

Cada VPS possui `node_id` persistente e metadados administrativos como país, região, pool, provedor, cidade, capacidade e peso.

```bash
manager --node
manager --node-context
manager --node-set region BR-SP
manager --node-set pool BRASIL-PREMIUM
```

O contrato local de telemetria é:

```bash
/opt/manager/modules/node_usage.sh --show
```

Ele declara explicitamente:

```text
usage_scope=node-local
billing_authoritative=0
global_usage_supported=0
```

Documentação:

- [`docs/NODE_METADATA.md`](docs/NODE_METADATA.md)
- [`docs/NODE_USAGE.md`](docs/NODE_USAGE.md)

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

O Legacy usa conta não-root, listener OpenSSH dedicado, `ForceCommand`, sudoers exato e allowlist dos comandos históricos suportados. Não há `eval`, shell root remoto, `chmod 777`, banco de senha em texto claro ou flush global de firewall.

Documentação: [`docs/AUTOMATION_LEGACY.md`](docs/AUTOMATION_LEGACY.md).

## Automation v2 — 0.7.1 a 0.7.3

A Automation v2 é a interface oficial para integrações novas. O transporte ainda é **local-only**, mas a fronteira agora possui contrato estruturado, idempotência, RBAC e autenticação Ed25519 para principals não-locais.

### managerd / managerctl

O instalador cria:

```text
manager-automation-v2.service
/run/manager-automation-v2/manager.sock
/usr/local/sbin/managerd
/usr/local/sbin/managerctl
```

Runtime `0700`, socket Unix `0600` e validação de peer por `SO_PEERCRED`.

Contrato:

```text
manager-automation-v2-local-v1
```

Status atual:

```text
remote_transport=0
rbac=1
principal_assertion=local-root-peercred-or-ed25519
cryptographic_auth=1
credential_algorithm=ed25519
nonlocal_signature_required=1
anti_replay=0
rate_limit=0
idempotency=1
audit=1
secret_replay=0
```

`local-root` continua autenticado pelo UID 0 do socket. Qualquer outro principal precisa de uma assinatura Ed25519 válida.

### Ações allowlisted

```text
system.describe
node.usage
connection.preflight
connection.create
connection.status
connection.revoke
```

Não existe ação de shell, comando arbitrário ou caminho executável informado pelo cliente.

### Principals e RBAC

Principals persistentes:

```text
/etc/manager/automation/v2/principals/
```

Papéis:

```text
admin
reseller
subreseller
user
```

Administração:

```bash
manager automation v2 principals
manager automation v2 principal show ID
manager automation v2 principal create ID ROLE SUBJECT [PRODUCTS]
manager automation v2 principal enable ID
manager automation v2 principal disable ID
manager automation v2 principal products ID SCOPE
```

A matriz é conservadora:

| Ação | admin | reseller | subreseller | user |
|---|---:|---:|---:|---:|
| `system.describe` | sim | sim | sim | sim |
| `node.usage` | sim | não | não | não |
| `connection.preflight/create` | sim | escopo | escopo próprio | não |
| `connection.status` | sim | escopo | escopo próprio | própria identidade |
| `connection.revoke` | sim | escopo | escopo próprio | não |

Revendedor atua na própria árvore e em subrevendedores filhos diretos; subrevendedor não sobe para o pai; usuário só consulta a identidade vinculada. Em criação por revenda, o produto é validado e `owner` omitido é forçado pelo daemon.

### Enrollment Ed25519 — 0.7.3

O servidor mantém somente a parte pública em:

```text
/etc/manager/automation/v2/credentials/<principal>/
```

Criar credencial:

```bash
manager automation v2 principal create loja01 reseller loja01 premium,basic
manager automation v2 credential enroll loja01 /root/loja01.credential
```

Usar:

```bash
managerctl --credential /root/loja01.credential \
  connection.status id=maria
```

O arquivo `.credential` contém a chave privada, é criado em `0600` e fica fora do registry do servidor. Ele não é incluído automaticamente no backup do MANAGER.

Listar/rotacionar/revogar:

```bash
manager automation v2 credentials loja01
manager automation v2 credential rotate loja01 /root/loja01-v2.credential
manager automation v2 credential revoke loja01 ed25519-0123456789abcdef
```

A rotação registra a nova chave antes de revogar as anteriores. Uma chave revogada deixa de autenticar imediatamente, inclusive ao repetir um `request_id` já cacheado.

A assinatura cobre:

```text
contract
version
request_id
principal_id
action_id
params
```

O daemon recalcula `key_id` e fingerprint a partir da chave pública antes de verificar a assinatura.

### Ordem de segurança

```text
peer Unix / UID 0
       ↓
principal ativo
       ↓
autenticação peercred ou Ed25519
       ↓
RBAC / ownership / produto
       ↓
idempotência
       ↓
dispatcher allowlisted
```

Autenticação e RBAC vêm antes do replay. Cache não reativa principal desabilitado nem chave revogada.

### Request ID e idempotência

- mesmo principal + mesma ação + mesmo payload normalizado: replay idempotente;
- mesmo `request_id` com principal/payload diferente: conflito `65`;
- cache root-only em `/var/lib/manager/automation-v2/idempotency/`;
- credencial pode ser rotacionada sem mudar a identidade lógica da operação;
- autenticação atual ainda precisa ser válida para receber resposta cacheada.

Segredos continuam **one-shot**: senha SSH gerada não é guardada para replay.

### Auditoria

```text
/var/log/manager/automation-v2-audit.jsonl
```

Campos incluem principal, RBAC e autenticação:

```text
principal_id
principal_role
principal_subject
auth_scheme
auth_key_id
auth_fingerprint
auth_decision
rbac_decision
rbac_reason
```

Assinatura, chave privada, senha e stdout sensível não entram no audit.

### Limite da 0.7.3

A autenticação criptográfica está pronta, porém:

```text
remote_transport=0
anti_replay=0
rate_limit=0
```

A assinatura Ed25519 **não é justificativa para expor o socket local diretamente à Internet**. A 0.7.4 adicionará timestamp/nonce, janela de validade, cache anti-replay, rate limiting e um transporte remoto próprio autenticado/criptografado.

Documentação: [`docs/AUTOMATION_V2.md`](docs/AUTOMATION_V2.md).

## Backup, rollback e remoção

Backups preservam estado relevante em `/etc/manager` e histórico de uso consolidado. Update/rollback desanexam hooks/daemons antes de trocar o código.

```bash
manager-rollback
manager-uninstall
manager-uninstall --purge
```

Uninstall normal fecha listeners/sockets e remove código, mas preserva estado durável — incluindo principals e credenciais públicas da Automation v2 — para reinstalação. O purge remove o estado server-side do MANAGER. Arquivos privados de credencial criados fora de `/etc/manager` não são apagados automaticamente.

## Segurança

- nenhum flush global de firewall IPv4/IPv6;
- Squid sem `http_access allow all`;
- credenciais VPN com permissões restritas;
- provisionamento não registra senha/chaves privadas no audit log;
- cache de idempotência nunca persiste senha gerada;
- ACL restrita de região/pool/nó falha fechada;
- `manager-connection-actions-v1` não aceita shell, comando ou caminho arbitrário;
- Legacy v1 usa conta não-root, SSH dedicado, `ForceCommand` e allowlist;
- Automation v2 ainda não abre porta TCP;
- principals e credenciais públicas precisam ser arquivos regulares root-owned sem permissões de grupo/mundo;
- chave privada Ed25519 fica no arquivo externo de credencial, não no registry server-side;
- autenticação e RBAC são reavaliados antes do replay idempotente;
- chave revogada e revenda/principal desabilitados falham fechado na próxima requisição.

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
managerctl [--principal ID] [--credential FILE] ACTION [key=value ...] [--request-id ID]
manager --diagnostics
manager --version
```

Contratos/módulos internos principais:

```text
/opt/manager/modules/connection_actions.sh
/opt/manager/modules/node_usage.sh
/opt/manager/modules/automation_legacy.sh
/opt/manager/modules/automation_principals.sh
/opt/manager/modules/automation_credentials.sh
/opt/manager/modules/automation_v2.sh
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
0.7.4  anti-replay + rate limit + transporte remoto                   próximo
0.8.x  Modo Colmeia
0.9.x  Telegram Bot + Mini App
0.9.5  migração e escala
1.0.0  release de produção
```

A próxima etapa é **0.7.4: anti-replay + rate limiting + transporte remoto estruturado**. Depois começa a fase 0.8 Colmeia com heartbeat, scheduler, drain/failover e autoridade global.

## Testes

O CI cobre, entre outros:

- syntax/ShellCheck e regressões de segurança;
- install/update/rollback/uninstall;
- Connection/Policy/Session Engine e Protocol Lease Bridge;
- accounting, produtos/ACL, revenda e IPv6;
- Legacy v1;
- Automation v2 Core;
- isolamento RBAC entre reseller/subreseller/user/admin;
- owner forçado e escopo de produto;
- principals não-locais sem assinatura recusados;
- assinatura Ed25519 válida;
- credencial com chave privada incorreta recusada;
- rotação e fencing da chave antiga;
- revogação imediata antes de replay;
- audit de autenticação/RBAC sem segredos;
- persistência de principals/credenciais públicas após uninstall/reinstall;
- purge do estado server-side sem apagar arquivo privado externo.

## Origem

O SSHPlus Manager original foi desenvolvido por **@crazy_vpn** e deu origem a vários forks comunitários. O MANAGER preserva a ideia de administração simples por terminal, mas evolui para uma arquitetura própria de identidade, automação, leases, accounting, produtos e operação multi-servidor.
