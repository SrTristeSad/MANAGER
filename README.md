# MANAGER

Gerenciador moderno de VPS inspirado na experiência clássica do **SSHPlus Manager**, reconstruído para Debian/Ubuntu atuais.

> O objetivo não é executar cegamente binários antigos do SSHPlus. O MANAGER preserva capacidades úteis, substitui implementações inseguras/obsoletas e evolui para uma arquitetura própria de identidade, automação, VPN, revenda e operação multi-servidor.

Versão atual: **0.7.2**.

## Princípios

- não substituir o `sshd_config` inteiro;
- não executar flush global de firewall;
- não baixar executáveis opacos como root;
- validar configurações antes de recarregar serviços;
- preservar configurações alheias ao MANAGER sempre que possível;
- compatibilidade com legado não significa copiar fragilidades do legado;
- integrações novas usam operações estruturadas e nunca shell remoto arbitrário;
- senhas/chaves privadas não são guardadas em texto claro para permitir replay posterior;
- autorização e autenticação são camadas separadas: a 0.7.2 conclui RBAC, mas ainda não anuncia autenticação remota criptográfica.

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

## Automation v2 — 0.7.1 + 0.7.2

A Automation v2 é a interface oficial para integrações novas. Ela ainda é **local-only**: primeiro estabilizamos contrato, idempotência e autorização; autenticação/transportes remotos vêm depois.

### managerd / managerctl

O instalador cria:

```text
manager-automation-v2.service
/run/manager-automation-v2/manager.sock
/usr/local/sbin/managerd
/usr/local/sbin/managerctl
```

O runtime é `0700` e o socket Unix é `0600`. O daemon valida o peer com `SO_PEERCRED`; somente root local entra na fronteira privilegiada nesta etapa.

Contrato:

```text
manager-automation-v2-local-v1
```

Status atual:

```text
remote_transport=0
rbac=1
principal_assertion=root-local
cryptographic_auth=0
anti_replay=0
rate_limit=0
idempotency=1
audit=1
secret_replay=0
```

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

### Principals e RBAC — 0.7.2

Principals persistentes ficam em:

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

O principal reservado `local-root` é admin e mantém compatibilidade com chamadas locais que não informam principal.

Administração:

```bash
manager automation v2 status
manager automation v2 principals
manager automation v2 principal show ID
manager automation v2 principal create ID ROLE SUBJECT [PRODUCTS]
manager automation v2 principal enable ID
manager automation v2 principal disable ID
manager automation v2 principal products ID SCOPE
```

Exemplo:

```bash
manager automation v2 principal create loja01 reseller loja01 premium,basic
managerctl --principal loja01 connection.status id=maria
```

A matriz é conservadora:

| Ação | admin | reseller | subreseller | user |
|---|---:|---:|---:|---:|
| `system.describe` | sim | sim | sim | sim |
| `node.usage` | sim | não | não | não |
| `connection.preflight/create` | sim | escopo | escopo próprio | não |
| `connection.status` | sim | escopo | escopo próprio | própria identidade |
| `connection.revoke` | sim | escopo | escopo próprio | não |

`reseller` pode atuar em suas identidades e nas de subrevendedores filhos diretos. `subreseller` não sobe para o pai e não cruza para outra árvore. `user` só consulta sua identidade vinculada.

Para criação por revenda:

- produto precisa estar no escopo do principal;
- `owner` omitido é preenchido pelo MANAGER com o owner autorizado;
- `owner` apontando para outra revenda é recusado;
- a autorização acontece antes do dispatcher privilegiado.

### Request ID e idempotência

Cada requisição usa `request_id`, `principal_id` e `action_id`.

- mesmo principal + mesma ação + mesmo payload normalizado: replay idempotente;
- mesmo `request_id` com principal/payload diferente: conflito `65`;
- principal desabilitado é negado **antes** da consulta ao cache;
- cache root-only em `/var/lib/manager/automation-v2/idempotency/`.

Segredos são **one-shot**. Uma senha SSH gerada aparece somente na primeira resposta; o cache persistente é sanitizado e não permite recuperá-la depois.

### Auditoria RBAC

```text
/var/log/manager/automation-v2-audit.jsonl
```

O audit registra metadados, principal efetivo e decisão:

```text
principal_id
principal_role
principal_subject
rbac_decision=allow|deny
rbac_reason
```

Senha, chave privada e stdout sensível não entram no audit.

### Importante: `--principal` ainda não é autenticação remota

Na 0.7.2:

```bash
managerctl --principal loja01 ...
```

é uma asserção aceita apenas porque o chamador já é root local em um socket `0600`. Nenhuma integração remota deve ser considerada autenticada apenas por fornecer esse texto.

A **0.7.3** adicionará identidade criptográfica/enrollment e vinculará a chave autenticada ao `principal_id`.

Documentação: [`docs/AUTOMATION_V2.md`](docs/AUTOMATION_V2.md).

## Backup, rollback e remoção

Backups preservam estado relevante em `/etc/manager` e histórico de uso consolidado. Update/rollback desanexam hooks/daemons antes de trocar o código.

```bash
manager-rollback
manager-uninstall
manager-uninstall --purge
```

Uninstall normal fecha listeners/sockets e remove código, mas preserva estado durável — incluindo principals da Automation v2 — para reinstalação. O purge remove também o estado do MANAGER.

## Segurança

- nenhum flush global de firewall IPv4/IPv6;
- Squid sem `http_access allow all`;
- credenciais VPN com permissões restritas;
- provisionamento não registra senha/chaves privadas no audit log;
- cache de idempotência nunca persiste senha gerada;
- ACL restrita de região/pool/nó falha fechada;
- `manager-connection-actions-v1` não aceita shell, comando ou caminho arbitrário;
- Legacy v1 usa conta não-root, SSH dedicado, `ForceCommand` e allowlist;
- Automation v2 não abre porta TCP na 0.7.2;
- principal file precisa ser regular, root-owned e sem permissões de grupo/mundo;
- RBAC é reavaliado antes do replay idempotente;
- revenda desabilitada invalida o principal vinculado na próxima requisição.

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
managerctl [--principal ID] ACTION [key=value ...] [--request-id ID]
manager --diagnostics
manager --version
```

Contratos/módulos internos principais:

```text
/opt/manager/modules/connection_actions.sh
/opt/manager/modules/node_usage.sh
/opt/manager/modules/automation_legacy.sh
/opt/manager/modules/automation_principals.sh
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
0.7.3  autenticação criptográfica + enrollment                        próximo
0.7.4  anti-replay + rate limit + transporte remoto
0.8.x  Modo Colmeia
0.9.x  Telegram Bot + Mini App
0.9.5  migração e escala
1.0.0  release de produção
```

A próxima etapa é **0.7.3: autenticação criptográfica + enrollment**. Somente depois vêm anti-replay/rate limiting/transporte remoto e, então, a fase 0.8 Colmeia com heartbeat, scheduler, drain/failover e autoridade global.

## Testes

O CI cobre, entre outros:

- syntax/ShellCheck e regressões de segurança;
- install/update/rollback/uninstall;
- Connection/Policy/Session Engine e Protocol Lease Bridge;
- accounting, produtos/ACL, revenda e IPv6;
- Legacy v1;
- Automation v2 Core;
- principals root-only;
- isolamento reseller/subreseller/user;
- owner forçado no provisionamento de revenda;
- escopo de produto;
- `node.usage` admin-only;
- disable/re-enable antes de replay idempotente;
- conflito de `request_id` entre principals;
- auditoria RBAC sem segredos;
- persistência de principals após uninstall/reinstall.

## Origem

O SSHPlus Manager original foi desenvolvido por **@crazy_vpn** e deu origem a vários forks comunitários. O MANAGER preserva a ideia de administração simples por terminal, mas evolui para uma arquitetura própria de identidade, automação, leases, accounting, produtos e operação multi-servidor.
