# MANAGER Colmeia — confiança, rede privada, saúde, scheduler e leases globais

A série 0.8 transforma o MANAGER de uma autoridade local por VPS em uma arquitetura coordenada entre múltiplos nós, mantendo o controlador fora do caminho de dados VPN dos usuários.

Evolução atual:

```text
0.8.0  identidade Ed25519 + enrollment + node_epoch
0.8.1  rede privada WireGuard mgh0 + config_epoch
0.8.2  heartbeat assinado + saúde verificável dos nós
0.8.3  scheduler weighted least-loaded + placement + sticky + drain + failover de seleção
0.8.4  autoridade global de leases + max_sessions_global + fencing + grace controlado
```

A 0.8.4 adiciona autoridade global de sessão e grants vinculados ao scheduler. Accounting global e login/provisionamento VPN global continuam fora desta etapa e permanecem planejados separadamente.

## Arquitetura atual

Cada nó possui duas identidades criptográficas com funções diferentes:

1. **Ed25519 de controle** — enrollment, network requests e heartbeat;
2. **WireGuard da malha** — tráfego privado VPS↔VPS na interface `mgh0`.

O controlador possui sua própria identidade Ed25519 e um certificado TLS separado para o listener de heartbeat. O certificado TLS é pinado por SHA-256 no nó; a autoridade lógica continua sendo a identidade Ed25519 already enrolled.

```text
                           CONTROLADOR
      enrollment / topologia / health / scheduler
                    │             ▲
                    │             │ heartbeat assinado
                    │             │ TLS 1.3 + pin SHA-256
          ┌─────────┼─────────────┼─────────┐
          │         │             │         │
         nó A      nó B          nó C      ...
         mgh0 ───── mgh0 ──────── mgh0
          └────────── mesh direto ──────────┘

scheduler decide onde uma NOVA alocação pode entrar
tráfego VPN do usuário NÃO atravessa o controlador
```

`mgh0` é separada do `wg0` usado pelos clientes do MANAGER.

## Estado persistente e runtime

Identidade/enrollment do nó:

```text
/etc/manager/hive/node/
├── node.key
├── node.pub
├── identity.conf
├── controller.conf
├── controller.pub
└── enrollment.conf
```

Rede privada do nó:

```text
/etc/manager/hive/network/
├── node.key
├── node.pub
├── network.conf
├── topology.json
└── mgh0.owner
```

Heartbeat do nó:

```text
/etc/manager/hive/health/
└── node.conf
```

Runtime/local state de health:

```text
/var/lib/manager/hive-health/
├── node.state
├── nodes/
└── replay/
```

Controlador:

```text
/etc/manager/hive/controller/
├── controller.key
├── controller.pub
├── controller.conf
├── nodes/
│   ├── node-....conf
│   └── node-....pub
├── network/
│   ├── network.conf
│   └── nodes/
│       └── node-....conf
├── health/
│   ├── controller.conf
│   └── tls/
│       ├── server.key
│       └── server.crt
├── scheduler/
│   └── nodes/
│       └── node-....conf
└── leases/
    ├── controller.conf
    ├── limits/
    └── tls/
        ├── server.key
        └── server.crt
```

Configuração de lease no nó:

```text
/etc/manager/hive/leases/node.conf
```

Sticky state do scheduler:

```text
/var/lib/manager/hive-scheduler/sticky/
```

Estado da autoridade global:

```text
/var/lib/manager/hive-leases/
├── active/
├── epochs/
├── replay/
└── node-authority.state
```

Auditoria do scheduler:

```text
/var/log/manager/hive-scheduler-audit.jsonl
/var/log/manager/hive-lease-audit.jsonl
```

Runtime WireGuard:

```text
/etc/wireguard/mgh0.conf
```

Audit de health:

```text
/var/log/manager/hive-health-audit.jsonl
```

Chaves privadas e arquivos de autoridade usam permissões root-only.

## Contratos

Enrollment 0.8.0:

```text
manager-hive-node-identity-v1
manager-hive-controller-identity-v1
manager-hive-enrollment-request-v1
manager-hive-enrollment-bundle-v1
```

Rede 0.8.1:

```text
manager-hive-network-request-v1
manager-hive-network-bundle-v1
manager-hive-network-v1
manager-hive-network-controller-v1
manager-hive-lifecycle-v1
```

Health 0.8.2:

```text
manager-hive-heartbeat-v1
manager-hive-heartbeat-ack-v1
manager-hive-health-node-v1
manager-hive-health-controller-v1
```

Scheduler 0.8.3:

```text
manager-hive-scheduler-v1
manager-hive-scheduler-node-v1
manager-hive-scheduler-selection-v1
```

Leases globais 0.8.4:

```text
manager-hive-global-lease-v1
manager-hive-global-lease-controller-v1
manager-hive-global-lease-node-v1
manager-hive-global-lease-request-v1
manager-hive-global-lease-response-v1
manager-hive-global-grant-v1
```

As assinaturas de controle usam Ed25519 via OpenSSL. A malha usa WireGuard. O heartbeat usa TLS 1.3 como transporte e Ed25519 como autenticação/autorização lógica. O scheduler consome estado já autenticado/registrado; ele não cria uma nova primitiva criptográfica nem uma segunda autoridade de identidade.

## 1. Enrollment do nó

No nó:

```bash
manager hive status
manager hive request /root/node-request.json
```

No controlador:

```bash
manager hive controller init
manager hive controller fingerprint
manager hive controller approve \
  /root/node-request.json \
  /root/node-bundle.json
```

No primeiro enrollment:

```text
node_epoch=1
```

O nó aceita o bundle usando o fingerprint do controlador obtido por canal confiável:

```bash
manager hive accept \
  /root/node-bundle.json \
  SHA256:<fingerprint-do-controlador>
```

O request leva chave pública, metadados, `issued_at`, nonce e assinatura. Chave privada nunca entra no request.

## 2. Revogação e node_epoch

```bash
manager hive controller revoke NODE_ID compromised
```

Revogar:

- desabilita a autoridade daquele nó;
- registra motivo/timestamp;
- incrementa `node_epoch`;
- invalida heartbeat/network request com geração antiga.

O retorno exige re-enrollment explícito:

```bash
manager hive controller reenroll REQUEST OUT
```

Exemplo:

```text
enrollment inicial  → node_epoch=1
revogação           → node_epoch=2
re-enrollment       → node_epoch=3
```

O `node_epoch` é um fencing token de autoridade, não um contador decorativo.

## 3. Rede privada WireGuard

Depois do enrollment:

```bash
manager hive network init
manager hive network status
```

A chave privada da malha permanece exclusivamente em:

```text
/etc/manager/hive/network/node.key
```

O nó envia request assinado contendo chave pública WireGuard, endpoint, porta, `node_id`, `node_epoch`, `issued_at` e nonce:

```bash
manager hive network request \
  vpn-br-01.example.com \
  /root/node-network-request.json \
  51870
```

No controlador:

```bash
manager hive network controller init
manager hive network controller approve /root/node-network-request.json
manager hive network controller list
```

O controlador atribui IPv4/IPv6 privado único e mantém somente informação pública/operacional da malha.

## 4. Bundles e config_epoch

```bash
manager hive network controller bundle NODE_ID /root/NODE_ID.network.json
manager hive network controller bundle-all /root/hive-bundles
```

`config_epoch` avança quando a topologia efetiva muda. O nó recusa:

- epoch menor que o último aceito;
- conteúdo divergente no mesmo epoch;
- bundle destinado a outro `node_id`/`node_epoch`;
- chave WireGuard target diferente da chave local;
- assinatura inválida;
- bundle expirado.

Aplicação:

```bash
manager hive network accept /root/NODE_ID.network.json
manager hive network reconcile
manager hive network down
```

O runtime gerenciado possui marker:

```text
# MANAGER-HIVE-NETWORK v1
```

Configuração externa/symlink/não regular não é assumida pelo MANAGER. Uma nova configuração passa por `wg-quick strip`; mudança em interface ativa usa restart; falha restaura configuração/ownership/estado anteriores.

## 5. Rotas e caminho de dados

Peers usam somente hosts privados:

```text
AllowedIPs = <ipv4-peer>/32, <ipv6-peer>/128
```

A malha não gera:

```text
0.0.0.0/0
::/0
```

O controlador não é gateway do tráfego VPN dos usuários. A porta WireGuard da Colmeia não é aberta automaticamente no firewall.

## 6. Heartbeat assinado — 0.8.2

O heartbeat reutiliza a identidade Ed25519 enrolled do nó.

Payload lógico:

```text
contract
version
controller_id
node_id
node_epoch
issued_at
nonce
metrics
signature
```

A assinatura cobre todo o envelope, exceto o próprio campo `signature`.

O controlador valida, nesta ordem lógica:

1. contrato/estrutura;
2. `controller_id`;
3. nó registrado e habilitado;
4. `node_epoch` exato;
5. `issued_at` dentro da janela de 120 s;
6. formato do nonce;
7. schema/faixa das métricas;
8. assinatura Ed25519 com a chave pública registrada;
9. consumo atômico do nonce para impedir replay.

Replay usa criação exclusiva de arquivo. O nome persistido é `SHA256(nonce)`, não o nonce original. A retenção atual é maior que a janela de freshness.

## 7. Transporte TLS do heartbeat

O listener do controlador é **opt-in** e usa TLS 1.3 somente.

```bash
manager hive health controller init
manager hive health controller status
manager hive health controller enable 203.0.113.10 9444
```

No nó:

```bash
manager hive health configure \
  controller.example.com \
  9444 \
  SHA256:<fingerprint-tls> \
  30
```

O nó valida o certificado DER pelo pin SHA-256 **antes de enviar o heartbeat**. Fingerprint incorreto falha fechado. O MANAGER não abre automaticamente a porta 9444 ou outra porta escolhida no firewall.

Rotação:

```bash
manager hive health controller rotate-tls
```

Após a rotação, os nós precisam receber o novo fingerprint de forma confiável.

## 8. Métricas e saúde

Cada heartbeat reporta:

- uptime;
- uso de CPU e quantidade de CPUs;
- load 1/5/15;
- RAM total/disponível/percentual usado;
- interface de saída e contadores RX/TX;
- sessões e número de identidades com sessão;
- `max_sessions`, capacidade e peso;
- estado administrativo local do nó;
- protocolos disponíveis;
- estado dos serviços SSH, WireGuard e OpenVPN;
- configuração/estado/peer count de `mgh0`;
- RTT observado na troca anterior com o controlador.

Estados:

```text
HEALTHY
DEGRADED
DRAINING
OFFLINE
```

`HEALTHY` é o único estado aceito pelo scheduler 0.8.3 para novas alocações. `DEGRADED` e `OFFLINE` são automaticamente inelegíveis. O drain runtime do scheduler é uma decisão administrativa separada do sinal local `enabled=0` que também pode derivar `DRAINING` na telemetria.

Defaults de health:

```text
degraded_after_seconds=75
offline_after_seconds=180
```

```bash
manager hive health controller thresholds 75 180
```

O heartbeat não transforma `manager-node-usage-v1` em billing global autoritativo. Accounting global continua fora da 0.8.4.

## 9. Scheduler — 0.8.3

O scheduler opera no controlador e escolhe o destino de **novas alocações**. Ele não encaminha o tráfego VPN e não representa uma lease global.

Status:

```bash
manager hive node status
```

Saída de contrato inclui:

```text
contract=manager-hive-scheduler-v1
scheduler=weighted-least-loaded
sticky_session=1
drain_runtime=1
selection_failover=1
placement_authority=controller-admin
global_lease_authority=1
global_lease_controller_enabled=0|1
global_max_sessions=1
controller_in_user_vpn_path=0
```

## 10. Placement controller-authoritative

Cada nó enrolled pode receber um alias e localização operacional controlados pelo administrador do controlador:

```bash
manager hive node placement \
  node-1111111111111111 \
  BR-SP-01 \
  BR \
  BR-SP \
  PREMIUM
```

Campos:

```text
node_id
name
country
region
pool
draining
drain_reason
```

O alias precisa ser único entre os placements do controlador.

Listagem/inspeção:

```bash
manager hive node list
manager hive node show BR-SP-01
manager hive node show node-1111111111111111
```

## 11. Elegibilidade e weighted least-loaded

Um nó só entra no conjunto candidato quando:

- está enrolled neste controlador;
- autoridade está habilitada e não revogada;
- `node_epoch` do heartbeat coincide;
- heartbeat existe e ainda é elegível;
- estado derivado é `HEALTHY`;
- não está em drain;
- satisfaz região/pool/node scope solicitados;
- anuncia o protocolo solicitado;
- o serviço correspondente está ativo;
- não atingiu `max_sessions` local.

Protocolos aceitos:

```text
ssh
wireguard
openvpn
```

A pontuação principal usa carga ponderada:

```text
load_score = (sessions + 1) / (effective_capacity * weight)
```

RTT entra apenas como componente secundário pequeno. Empates terminam por ordenação determinística de RTT/`node_id`, evitando seleção aleatória não auditável.

Exemplo:

```bash
manager hive node select wireguard BR-SP PREMIUM maria '*'
```

Também é possível limitar explicitamente os nós elegíveis:

```bash
manager hive node select \
  wireguard \
  BR-SP \
  PREMIUM \
  maria \
  node-1111111111111111,node-2222222222222222
```

## 12. Sticky affinity e failover

Quando uma `STICKY` é informada, o scheduler guarda apenas o `node_id` correspondente em estado root-only. A chave sticky é transformada em SHA-256 para formar o nome do arquivo.

Se o nó anterior continuar elegível:

```text
selection_reason=sticky-eligible
sticky_hit=1
```

Se ele deixar de ser elegível por drain, health, protocolo, capacidade ou filtros:

```text
selection_reason=sticky-failover
sticky_hit=0
```

O failover escolhe um novo nó pelo mesmo algoritmo weighted least-loaded e atualiza a afinidade. Isso é **failover de seleção** para nova alocação; não migra uma sessão VPN já estabelecida.

## 13. Drain

Ativar:

```bash
manager hive node drain BR-SP-02 maintenance
```

Semântica:

```text
draining=1
new_allocations_allowed=0
existing_sessions_terminated=0
```

O drain não derruba sessões existentes. Elas terminam normalmente; novas seleções deixam de usar o nó.

Remover drain:

```bash
manager hive node undrain BR-SP-02
```

O motivo de drain é auditado com o `node_id` e o `node_epoch` conhecido.

## 14. Audit

Decisões do scheduler entram em:

```text
/var/log/manager/hive-scheduler-audit.jsonl
```

Eventos atuais incluem:

- `placement`;
- `select`;
- `select-denied`;
- `drain`;
- `undrain`.

O audit registra metadados operacionais e a razão da seleção. Não persiste chaves privadas ou credenciais.

Health mantém audit separado em:

```text
/var/log/manager/hive-health-audit.jsonl
```

## 15. Autoridade global de leases — 0.8.4

A autoridade global controla quantas sessões uma identidade pode manter **somando todos os nós enrolled**. O scheduler continua escolhendo elegibilidade/capacidade; o grant do controlador reserva um slot global no mesmo plano de controle antes de a sessão ser reclamada pelo nó selecionado.

Exemplo:

```text
Maria possui acesso a 10 países/nós
max_sessions_global=1
→ uma conexão em qualquer nó ocupa o único slot global
→ tentativa simultânea em outro nó é recusada
```

Política:

```bash
manager hive lease limit set maria 1 PREMIUM
manager hive lease limit show maria
manager hive lease limit list
```

O import opcional reutiliza `max_sessions` e o produto já atribuídos localmente:

```bash
manager hive lease limit import-local maria
manager hive lease limit sync-local
```

### Transporte e autenticação

O listener é opt-in, usa TLS 1.3 e não abre firewall automaticamente:

```bash
manager hive lease controller init
manager hive lease controller enable 203.0.113.10 9445
manager hive lease controller status
```

No nó enrolled:

```bash
manager hive lease node configure controller.example.com 9445 SHA256:<fingerprint> 30
```

Cada requisição `acquire`/`heartbeat`/`release` é assinada com a identidade Ed25519 do nó. O controlador exige `node_epoch` exato, timestamp fresco, nonce single-use e chave pública registrada. O TLS é pinado pelo SHA-256 do certificado do controlador.

### Grant atômico scheduler + lease

```bash
manager hive lease controller grant \
  maria wireguard BR-SP PREMIUM maria '*' device-01 60
```

O grant chama o scheduler, escolhe um nó elegível e cria uma reserva `lease_state=reserved` dentro do mesmo lock da autoridade global. A reserva já conta para `max_sessions_global`; somente o nó/protocolo/device do grant pode reclamá-la. Isso fecha a janela em que duas novas alocações poderiam observar capacidade global livre ao mesmo tempo.

### Fencing e revogação

A autoridade mantém dois fences distintos:

- `node_epoch`: impede nó revogado/re-enrolled antigo de adquirir lease;
- `authority_epoch`: cresce quando a autoridade do controlador é reabilitada; o nó guarda o maior epoch visto e recusa uma autoridade mais antiga que reapareça.

Revogação por identidade remove grants/leasings ativos e incrementa `global_epoch`:

```bash
manager hive lease controller revoke maria compromised
```

### Protocol Lease Bridge e grace

SSH e OpenVPN continuam entrando pelo `modules/protocol_leases.sh` com admissão síncrona: o PAM `open_session` e o `client-connect` do OpenVPN só concluem a nova sessão depois do acquire global. Negativa ou indisponibilidade da autoridade em uma nova sessão falha fechado e a lease local é revertida.

WireGuard não possui um hook de login equivalente na 0.8.4. O bridge observa handshakes recentes e aplica a autoridade global no ciclo de reconciliação. Se o acquire global for recusado ou não puder ser obtido, a lease local é revertida e o tráfego do cliente é bloqueado por regra DROP gerenciada em `wg0`; se a regra não puder ser aplicada, o peer runtime é removido. Portanto, o enforcement WireGuard da 0.8.4 é fail-closed por reconciliação, não uma admissão pré-handshake. Grant/login antes da primeira sessão WireGuard pertence à 0.8.5.

Sessões já aceitas podem receber um grace curto (`0..120 s`, default `30`) somente quando o transporte da autoridade fica indisponível. Uma resposta autoritativa de deny, revogação, epoch antigo ou lease ausente encerra o mapa no próximo heartbeat e **não** recebe grace.

O controlador continua fora do caminho de dados do usuário: ele autoriza/renova a sessão, mas os pacotes VPN não atravessam o listener de lease.

## 16. Allocation / login global — fundação 0.8.5

A 0.8.5 introduz um ticket de allocation assinado pelo controlador. Ele vincula `identity_id`, `product_id`, protocolo, região/pool, nó e `node_epoch`, `global_lease_id`, `global_epoch` e `session_epoch`. O nó só aceita tickets destinados ao enrollment atual.

O modo é opt-in para preservar a compatibilidade da 0.8.4:

```bash
manager hive allocation enable
```

No controlador, uma allocation cria primeiro um grant global reservado e então emite o bundle Ed25519:

```bash
manager hive allocation controller create \
  maria wireguard /root/maria.alloc.json BR-SP PREMIUM maria '*' 60
```

A criação também coloca o bundle assinado em um outbox durável do controlador para o `selected_node`. Com `manager hive allocation enable`, o nó instala um timer de sync que consulta o **mesmo canal TLS 1.3 pinado da autoridade global de leases**. O pull é assinado pela identidade Ed25519 enrolled do nó, inclui freshness/nonce/`node_epoch` e só recebe bundles destinados ao próprio nó/epoch.

Entrega normal:

```bash
manager hive allocation enable
manager hive allocation sync        # diagnóstico/forçar sync; o timer faz isso automaticamente
```

O nó valida novamente assinatura Ed25519, destino, expiração e `session_epoch` antes de persistir o ticket. Só depois do aceite durável envia ACK ao controlador. Se o ACK se perder, o mesmo bundle pode ser puxado novamente e o aceite local é idempotente; o outbox só é removido após ACK válido do nó destinatário. Não é aberta uma nova porta: a distribuição reutiliza o control plane de leases já configurado.

O aceite manual continua disponível como recuperação/diagnóstico:

```bash
manager hive allocation accept /root/maria.alloc.json
```

Quando o enforcement de allocation está ativo, o Protocol Lease Bridge exige um ticket local atual e reclama **exatamente** o `global_lease_id` vinculado. Não existe fallback para acquire global genérico apenas porque ainda há capacidade. SSH/OpenVPN continuam com admissão síncrona; WireGuard passa a poder receber autorização antes do primeiro uso quando a allocation é entregue ao nó.

Revogação avança o `session_epoch` da allocation, remove allocations ainda não entregues do outbox e também revoga grants/leases globais:

```bash
manager hive allocation controller revoke maria compromised
```

O controlador continua fora do caminho de dados VPN.

## 17. Audit global

```text
/var/log/manager/hive-lease-audit.jsonl
```

O audit registra limite, acquire, heartbeat, release, grant/claim, deny, expiry, fencing e revogação, sem persistir chave privada ou segredo de VPN.

## 18. Limites desta etapa

A 0.8.4 **não** implementa accounting/billing global (`global_accounting=0`) e não transforma o login/provisionamento VPN em uma API global completa. Essas responsabilidades continuam nas próximas etapas.

## 19. Lifecycle

A rede/health continuam ligados a `modules/hive_lifecycle.sh` e ao lifecycle da `manager-automation-v2.service`.

Drop-in:

```text
/etc/systemd/system/manager-automation-v2.service.d/90-manager-hive-network.conf
```

Helper:

```text
/usr/local/libexec/manager-hive-lifecycle
```

O scheduler não possui daemon próprio. Seu lifecycle é de estado:

- uninstall normal chama `--detach`, que preserva placement/sticky/audit;
- reinstalação pode reutilizar o estado durável;
- `manager-uninstall --purge` chama `--purge` e remove scheduler config/runtime/audit.

A malha/health continuam destacando seus units/runtime antes da remoção do código.

## 20. Backup

`/etc/manager/hive` entra no backup protegido do MANAGER. Pode conter:

- chave privada Ed25519 do nó;
- chave privada Ed25519 do controlador;
- chave privada WireGuard da malha;
- chave privada do certificado TLS de health;
- placement do scheduler;
- chave TLS/políticas/epochs da autoridade global de lease.

Portanto, o backup deve ser tratado como segredo operacional.

Uninstall normal preserva estado durável. `manager-uninstall --purge` é a operação destinada a remover o estado server-side persistente.

## Estado da 0.8.4

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
health_audit=1
scheduler=weighted-least-loaded
scheduler_audit=1
sticky_session=1
drain_runtime=1
selection_failover=1
controller_in_user_vpn_path=0
firewall_auto_open=0
global_lease_authority=1
global_max_sessions=1
global_grant_capability=1
authority_epoch_fencing=1
bounded_existing_session_grace=1
global_accounting=0
```

A Colmeia agora possui confiança, canal privado, saúde verificável, scheduler e autoridade global de sessão com limite atômico entre nós. O accounting continua local/não autoritativo para billing global.

## Próxima etapa — 0.8.5

A 0.8.5 leva o grant global para o fluxo de login/provisionamento VPN:

- login/provisionamento escolhe nó elegível e obtém grant atual;
- produto, região/pool, protocolo e lease global ficam vinculados na alocação;
- sessão só nasce no nó autorizado pelo grant;
- fencing impede nó stale de aceitar retorno antigo;
- SSH, WireGuard e OpenVPN seguem as capacidades do nó.
