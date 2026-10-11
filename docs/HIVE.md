# MANAGER Colmeia — confiança, rede privada e saúde dos nós

A série 0.8 transforma o MANAGER de uma autoridade local por VPS em uma arquitetura coordenada entre múltiplos nós, mantendo o controlador fora do caminho de dados VPN dos usuários.

A evolução atual é:

```text
0.8.0  identidade Ed25519 + enrollment + node_epoch
0.8.1  rede privada WireGuard mgh0 + config_epoch
0.8.2  heartbeat assinado + saúde verificável dos nós
```

A 0.8.2 **não** implementa scheduler, drain runtime, failover, leases globais ou accounting global. `DRAINING` já existe como estado de saúde, mas ainda não representa uma decisão de scheduler.

## Arquitetura atual

Cada nó possui duas identidades criptográficas com funções diferentes:

1. **Ed25519 de controle** — enrollment, network requests e heartbeat;
2. **WireGuard da malha** — tráfego privado VPS↔VPS na interface `mgh0`.

O controlador possui sua própria identidade Ed25519 e um certificado TLS separado para o listener de heartbeat. O certificado TLS é pinado por SHA-256 no nó; a autoridade lógica continua sendo a identidade Ed25519 já enrolled.

```text
                         CONTROLADOR
        enrollment / topologia / health authority
                  │          ▲
                  │          │ heartbeat assinado
                  │          │ TLS 1.3 + pin SHA-256
        ┌─────────┼──────────┼─────────┐
        │         │          │         │
       nó A      nó B       nó C      ...
       mgh0 ───── mgh0 ───── mgh0
        └──────── mesh direto ─────────┘

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
└── health/
    ├── controller.conf
    └── tls/
        ├── server.key
        └── server.crt
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

As assinaturas de controle usam Ed25519 via OpenSSL. A malha usa WireGuard. O heartbeat usa TLS 1.3 como transporte e Ed25519 como autenticação/autorização lógica. O MANAGER não inventa primitivas criptográficas.

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

Inicialização/status:

```bash
manager hive health controller init
manager hive health controller status
```

Habilitação:

```bash
manager hive health controller enable 203.0.113.10 9444
```

O status fornece o fingerprint do certificado TLS. Esse fingerprint deve ser transportado por um canal confiável para o nó.

No nó:

```bash
manager hive health configure \
  controller.example.com \
  9444 \
  SHA256:<fingerprint-tls> \
  30
```

O nó valida o certificado DER pelo pin SHA-256 **antes de enviar o heartbeat**. Fingerprint incorreto falha fechado.

A chave/certificado TLS do listener ficam em:

```text
/etc/manager/hive/controller/health/tls/
```

Rotação:

```bash
manager hive health controller rotate-tls
```

Após a rotação, os nós precisam receber o novo fingerprint de forma confiável.

O MANAGER não abre automaticamente a porta 9444 ou outra porta escolhida no firewall.

## 8. Métricas

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

O heartbeat não transforma `manager-node-usage-v1` em billing global autoritativo. Accounting global continua fora da 0.8.2.

## 9. Estados de saúde

Estados:

```text
HEALTHY
DEGRADED
DRAINING
OFFLINE
```

### HEALTHY

Heartbeat atual e nenhum problema operacional coberto pelas regras locais.

### DEGRADED

Pode ocorrer por:

- heartbeat atrasado;
- protocolo declarado disponível com serviço inativo;
- `mgh0` configurada porém inativa;
- CPU >= 95%;
- RAM usada >= 95%;
- sessões alcançando `max_sessions` local.

### DRAINING

Na 0.8.2, `DRAINING` é derivado quando o nó reporta `enabled=0` no Node Metadata.

Isso **não** significa que o scheduler/drain runtime já exista. O próximo milestone usará esse sinal para impedir novas alocações mantendo sessões existentes.

### OFFLINE

Pode ocorrer por:

- nenhum heartbeat recebido;
- timeout de heartbeat;
- autoridade do nó desabilitada/revogada;
- `node_epoch` incompatível.

Defaults:

```text
degraded_after_seconds=75
offline_after_seconds=180
```

Configuração:

```bash
manager hive health controller thresholds 75 180
```

O threshold de offline deve ser pelo menos 30 segundos maior que o degraded.

## 10. Operação do heartbeat

Status do nó:

```bash
manager hive health status
```

Envio manual:

```bash
manager hive health send
```

Desabilitar envio periódico:

```bash
manager hive health disable
```

Visão do controlador:

```bash
manager hive health controller status
manager hive health controller list
manager hive health controller show NODE_ID
```

O envio periódico usa:

```text
manager-hive-heartbeat.timer
manager-hive-heartbeat.service
```

O listener usa:

```text
manager-hive-health-controller.service
```

O ACK devolvido pelo controlador é assinado pela identidade Ed25519 do controlador e validado pelo `controller.pub` já enrolled do nó.

## 11. Audit e rate limit

Aceites e recusas relevantes entram em:

```text
/var/log/manager/hive-health-audit.jsonl
```

O audit registra metadados operacionais como evento, nó, epoch, estado/motivo e origem. Não registra chaves privadas.

O listener mantém proteção de burst por IP de origem antes da validação criptográfica completa.

## 12. Lifecycle

A Colmeia usa `modules/hive_lifecycle.sh` ligado ao lifecycle da `manager-automation-v2.service`.

Drop-in:

```text
/etc/systemd/system/manager-automation-v2.service.d/90-manager-hive-network.conf
```

Helper:

```text
/usr/local/libexec/manager-hive-lifecycle
```

Start:

1. reconcilia a rede privada quando aplicável;
2. reanexa heartbeat/listener se estiverem configurados/habilitados.

Stop em uninstall/rollback:

1. destaca heartbeat timer/listener;
2. destaca a rede `mgh0`;
3. remove somente hooks/runtime MANAGER-owned quando necessário.

Configuração durável permanece para reinstalação. O fallback só remove units com marker explícito:

```text
# MANAGER-HIVE-HEALTH v1
```

## 13. Backup

`/etc/manager/hive` entra no backup protegido do MANAGER. Pode conter:

- chave privada Ed25519 do nó;
- chave privada Ed25519 do controlador;
- chave privada WireGuard da malha;
- chave privada do certificado TLS de health.

Portanto, o backup deve ser tratado como segredo operacional.

Uninstall normal preserva estado durável. `manager-uninstall --purge` é a operação destinada a remover o estado server-side persistente.

## Estado da 0.8.2

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
controller_in_user_vpn_path=0
firewall_auto_open=0
scheduler=0
drain_runtime=0
failover=0
global_lease_authority=0
global_max_sessions=0
global_accounting=0
```

A Colmeia agora possui confiança, canal privado e estado de saúde verificável, mas ainda não escolhe automaticamente servidor nem concede autoridade global de sessão.

## Próxima etapa — 0.8.3

A 0.8.3 deve implementar **scheduler, drain e seleção de nó** usando os sinais já disponíveis:

- `HEALTHY/DEGRADED/DRAINING/OFFLINE`;
- capacidade/peso;
- sessões/capacidade;
- protocolo disponível;
- região/pool/ACL;
- latência;
- sticky session;
- decisões auditáveis.

O comando planejado continua:

```bash
manager hive node drain BR-SP-02
```

Drain deverá impedir novas alocações sem expulsar sessões existentes. Failover e autoridade global de leases continuam separados conforme o roadmap.
