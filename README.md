# MANAGER

Gerenciador moderno de VPS inspirado na experiência clássica do **SSHPlus Manager**, reconstruído para Debian/Ubuntu atuais.

> O objetivo não é executar cegamente binários antigos do SSHPlus. O MANAGER preserva capacidades úteis, substitui implementações inseguras/obsoletas e evolui para uma arquitetura própria de identidade, automação, VPN, revenda e operação multi-servidor.

Versão atual: **0.8.3**.

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
- o controlador da Colmeia permanece fora do caminho de dados VPN dos usuários;
- scheduler distribuído e autoridade global de sessões são responsabilidades separadas.

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

## Colmeia — 0.8.0 a 0.8.3

A Colmeia coordena múltiplas VPS sem transformar o controlador em relay do tráfego dos usuários:

- **0.8.0** — identidade Ed25519, enrollment e `node_epoch`;
- **0.8.1** — rede privada WireGuard `mgh0` e `config_epoch`;
- **0.8.2** — heartbeat assinado e saúde verificável;
- **0.8.3** — scheduler weighted least-loaded, placement, sticky, drain e failover de seleção.

Cada VPS possui uma identidade Ed25519 de controle ligada ao `node_id` e uma chave WireGuard própria para a malha. A chave WireGuard privada nasce e permanece no próprio nó; o controlador recebe somente chave pública, endpoint e metadados de rede.

```text
/etc/manager/hive/node/                        identidade Ed25519 do nó
/etc/manager/hive/network/                     chave/topologia privada do nó
/etc/manager/hive/health/                      configuração durável de heartbeat do nó
/etc/manager/hive/controller/                  autoridade, registry, health e scheduler
/etc/manager/hive/controller/scheduler/nodes/  placement/drain por nó
/var/lib/manager/hive-health/                  observações/replay/runtime de saúde
/var/lib/manager/hive-scheduler/sticky/        afinidade sticky
/var/log/manager/hive-scheduler-audit.jsonl    decisões do scheduler
/etc/wireguard/mgh0.conf                       runtime WireGuard gerenciado
```

A interface da Colmeia é `mgh0`, separada do `wg0` usado por clientes. A topologia atual é mesh direto VPS↔VPS: o controlador distribui autoridade/topologia e recebe telemetria de controle, mas **não carrega o tráfego VPN dos usuários**.

### Rede privada 0.8.1

```text
nó enrolled gera chave WireGuard local
        ↓
nó envia network request assinado
        ↓
controlador valida node_epoch e assinatura
        ↓
controlador atribui IPv4/IPv6 interno e config_epoch
        ↓
controlador emite bundle de topologia assinado por nó
        ↓
nó valida assinatura/fencing e reconcilia mgh0
```

```bash
manager hive network status
manager hive network init
manager hive network request vpn-br-01.example.com /root/node-network.json 51870
manager hive network controller init
manager hive network controller approve /root/node-network.json
manager hive network controller list
manager hive network controller bundle NODE_ID /root/NODE_ID.network.json
manager hive network accept /root/NODE_ID.network.json
manager hive network reconcile
manager hive network down
```

Fronteiras da malha:

- `config_epoch` monotônico impede rollback de topologia;
- bundle divergente reutilizando o mesmo `config_epoch` é recusado;
- `node_epoch` continua cercando nó revogado/re-enrolled;
- nenhuma chave WireGuard privada é enviada ao controlador ou a outro nó;
- `mgh0` nunca instala `0.0.0.0/0` ou `::/0`;
- o MANAGER não abre automaticamente a porta WireGuard no firewall;
- `mgh0.conf` externo/symlink/não pertencente ao MANAGER não é sobrescrito nem removido;
- configuração nova passa por `wg-quick strip` antes de ativação;
- mudança de topologia reinicia uma `mgh0` já ativa;
- falha ao aplicar restaura configuração/ownership/estado anteriores;
- uninstall/rollback removem somente o runtime MANAGER da malha, preservando chave local e topologia durável.

### Heartbeat e saúde 0.8.2

O nó envia uma amostra assinada com sua identidade Ed25519 já enrolled. A assinatura cobre `controller_id`, `node_id`, `node_epoch`, `issued_at`, nonce e todas as métricas. O controlador valida a chave pública registrada, exige `node_epoch` exato, aceita somente timestamp dentro de 120 segundos e consome o nonce uma única vez.

O transporte do heartbeat usa **TLS 1.3 somente**. O nó exige pin SHA-256 explícito do certificado do controlador antes de enviar o payload. O listener é opt-in, usa porta padrão `9444` quando não informada e o MANAGER **não abre o firewall automaticamente**.

```bash
# controlador
manager hive health controller init
manager hive health controller enable 203.0.113.10 9444
manager hive health controller status
manager hive health controller list
manager hive health controller show NODE_ID
manager hive health controller thresholds 75 180
manager hive health controller rotate-tls

# nó
manager hive health configure controller.example.com 9444 SHA256:<fingerprint> 30
manager hive health status
manager hive health send
manager hive health disable
```

Cada heartbeat inclui CPU, RAM, load, contadores de rede, sessões, capacidade/peso, protocolos disponíveis, estado dos serviços SSH/WireGuard/OpenVPN, estado/peers de `mgh0` e RTT anterior. O controlador deriva estados `HEALTHY`, `DEGRADED`, `DRAINING` e `OFFLINE`.

Os thresholds padrão são 75 s para heartbeat atrasado e 180 s para offline, podendo ser alterados no controlador. Aceites/recusas entram em audit JSONL sem persistir chaves privadas.

### Scheduler, drain e failover — 0.8.3

O scheduler usa os heartbeats do controlador e o placement administrativo para escolher **novas alocações**. Ele não move nem derruba sessões existentes.

A seleção considera:

- nó enrolled e autoridade habilitada;
- estado `HEALTHY`;
- drain desligado;
- protocolo solicitado realmente disponível e serviço ativo;
- região, pool e escopo explícito de nós;
- `max_sessions` local;
- capacidade e peso;
- RTT como componente secundário;
- afinidade sticky, desde que o nó anterior continue elegível.

A pontuação principal é weighted least-loaded. Empates possuem desempate determinístico. Se o nó sticky ficar drenado, sem saúde, sem capacidade ou fora dos filtros, o scheduler escolhe outro nó elegível e registra `sticky-failover`.

Placement e operação:

```bash
manager hive node status
manager hive node list
manager hive node placement node-1111111111111111 BR-SP-01 BR BR-SP PREMIUM
manager hive node show BR-SP-01
manager hive node drain BR-SP-01 maintenance
manager hive node undrain BR-SP-01
manager hive node select wireguard BR-SP PREMIUM maria '*'
```

Drain possui a seguinte semântica:

```text
new_allocations_allowed=0
existing_sessions_terminated=0
```

Ou seja: novas seleções deixam de apontar para o nó, mas sessões que já estavam nele continuam até seu término normal.

Contratos públicos do scheduler:

```text
manager-hive-scheduler-v1
manager-hive-scheduler-node-v1
manager-hive-scheduler-selection-v1
```

Estado da 0.8.3:

```text
cryptographic_node_identity=1
controller_identity=1
signed_enrollment=1
controller_fingerprint_pinning=1
node_epoch_fencing=1
private_hive_network=1
wireguard_mesh=1
signed_network_requests=1
signed_topology_bundles=1
config_epoch_fencing=1
heartbeat=1
node_health=1
signed_heartbeat=1
freshness=1
anti_replay=1
tls_transport=TLS1.3
tls_server_pinning=sha256
scheduler=weighted-least-loaded
sticky_session=1
drain_runtime=1
selection_failover=1
controller_in_user_vpn_path=0
global_lease_authority=0
global_max_sessions=0
global_accounting=0
```

**Importante:** 0.8.3 escolhe nó para nova alocação, mas ainda não concede lease global. Limite global de sessões, `session_epoch` distribuído e autoridade global entram na 0.8.4.

O estado durável da Colmeia entra no backup protegido do MANAGER e pode conter chaves privadas de nó/controlador; trate o backup como segredo operacional. Uninstall normal preserva confiança, topologia, configuração de saúde e estado de placement/sticky; runtime e listeners MANAGER-owned são destacados. `--purge` remove também scheduler state/audit server-side.

Documentação: [`docs/HIVE.md`](docs/HIVE.md).

## Backup, rollback e remoção

```bash
manager-rollback
manager-uninstall
manager-uninstall --purge
```

Uninstall normal fecha listeners/socket e remove código, mas preserva estado durável necessário para reinstalação, incluindo Automation v2 e a Colmeia. O runtime `mgh0` e os units de heartbeat/health gerenciados são destacados antes da remoção. O scheduler não possui daemon próprio; seu placement/sticky é estado persistente. O purge remove estado server-side. Arquivos privados externos de credencial da Automation não são apagados automaticamente.

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
- `node_epoch` impede aceitar autoridade antiga após revogação/re-enrollment;
- topologia WireGuard da Colmeia usa bundle assinado + `config_epoch`;
- chave WireGuard privada da Colmeia nunca sai do nó;
- config externa `mgh0.conf` é preservada;
- heartbeat é assinado, freshness/nonce são verificados e replay falha fechado;
- heartbeat usa TLS 1.3 com pin SHA-256 e listener opt-in;
- scheduler somente seleciona nós `HEALTHY` e elegíveis;
- drain não encerra sessões existentes;
- controlador não fica no caminho do tráfego VPN dos usuários;
- autoridade global de leases ainda não existe na 0.8.3;
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
manager hive network status|init|up|down|reconcile
manager hive network request ENDPOINT OUT [PORT]
manager hive network accept BUNDLE
manager hive network controller init|status|list
manager hive network controller show NODE_ID
manager hive network controller approve REQUEST
manager hive network controller enable|disable NODE_ID
manager hive network controller bundle NODE_ID OUT
manager hive network controller bundle-all DIR
manager hive health status
manager hive health configure HOST PORT TLS_FP [INTERVAL]
manager hive health disable|send
manager hive health controller init|status|list
manager hive health controller show NODE_ID
manager hive health controller enable BIND_IP [PORT]
manager hive health controller disable
manager hive health controller thresholds DEGRADED OFFLINE
manager hive health controller rotate-tls
manager hive node status|list
manager hive node show NODE
manager hive node placement NODE NAME COUNTRY REGION POOL
manager hive node drain NODE [REASON]
manager hive node undrain NODE
manager hive node select PROTOCOL [REGION] [POOL] [STICKY] [NODE_SCOPE]
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
0.8.1  rede privada WireGuard da Colmeia                             ✅
0.8.2  heartbeat + saúde de nós                                      ✅
0.8.3  scheduler / drain / seleção de nó                             ✅
0.8.4  autoridade de leases globais                                  próximo
0.8.5  VPN allocation / login global
0.8.6  quotas/accounting globais
0.8.7  failover e resiliência operacional
0.8.8  comandos remotos controlados
0.8.9  rotação de chaves / anti-replay distribuído
0.8.10 observabilidade distribuída
0.9.x  Telegram Bot + Mini App
1.0.0  release de produção
```

## Testes

O CI cobre syntax/ShellCheck, lifecycle, Connection/Session Engine, products/quotas, IPv6, Automation v2 e Colmeia. A 0.8.3 possui workflow dedicado `Hive Scheduler and Drain`, cobrindo:

- contrato público `manager hive node ...`;
- placement controller-authoritative e aliases de nó;
- weighted least-loaded com capacidade/peso;
- sticky affinity;
- drain por nome amigável sem alterar sessões existentes;
- failover quando o sticky deixa de ser elegível;
- filtro por health, protocolo, região, pool e node scope;
- audit de seleção/drain/undrain;
- `global_lease_authority=0` como fronteira explícita;
- detach preservando placement/sticky;
- purge removendo estado/auditoria do scheduler.

## Origem

O SSHPlus Manager original foi desenvolvido por **@crazy_vpn** e deu origem a vários forks comunitários. O MANAGER preserva a administração simples por terminal, evoluindo para identidade, automação, leases, accounting, produtos e operação multi-servidor.
