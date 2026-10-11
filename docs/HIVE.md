# MANAGER Colmeia — identidade, enrollment e rede privada

A série 0.8 transforma o MANAGER de uma autoridade local por VPS em uma arquitetura coordenada entre múltiplos nós. A 0.8.0 criou a raiz de confiança da Colmeia; a 0.8.1 adiciona a rede privada WireGuard que interliga nós enrolled sem colocar o controlador no caminho do tráfego VPN dos usuários.

A versão 0.8.1 **não** implementa heartbeat, scheduler, leases globais ou accounting global. Esses componentes entram nas próximas etapas.

## Arquitetura atual

A Colmeia possui duas identidades criptográficas distintas em cada nó:

1. **identidade de controle Ed25519** — assina enrollment e network requests;
2. **identidade WireGuard da malha** — cifra o tráfego entre VPS na interface `mgh0`.

A chave WireGuard privada é gerada localmente e nunca sai do nó. O controlador conhece somente a chave pública, endpoint, porta, endereços internos e estado da topologia.

```text
                    CONTROLADOR
                 autoridade/topologia
                        │
           bundles assinados / requests
                        │
        ┌───────────────┼───────────────┐
        │               │               │
      nó A            nó B            nó C
      mgh0 ────────── mgh0 ────────── mgh0
        └──────────── mesh direto ──────┘

tráfego VPN do usuário NÃO atravessa o controlador
```

`mgh0` é separada do `wg0` usado por clientes do MANAGER.

## Estado persistente

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
├── node.key          # chave WireGuard privada, root-only
├── node.pub
├── network.conf
├── topology.json     # último bundle assinado aceito
└── mgh0.owner        # ownership do runtime MANAGER
```

Runtime WireGuard:

```text
/etc/wireguard/mgh0.conf
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
└── network/
    ├── network.conf
    └── nodes/
        └── node-....conf
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

As assinaturas de controle usam Ed25519 via OpenSSL. O WireGuard usa sua própria criptografia padrão; o MANAGER não inventa primitivas criptográficas.

## 1. Enrollment do nó

No nó que deseja entrar na Colmeia:

```bash
manager hive status
manager hive request /root/node-request.json
```

O request contém `node_id`, key ID/fingerprint, chave pública Ed25519, snapshot de metadados, `issued_at`, nonce e assinatura do próprio nó. Não contém chave privada.

No controlador:

```bash
manager hive controller init
manager hive controller fingerprint
manager hive controller approve /root/node-request.json /root/node-bundle.json
```

O primeiro enrollment usa:

```text
node_epoch=1
```

No nó, o administrador aceita o bundle com o fingerprint do controlador obtido por canal confiável:

```bash
manager hive accept \
  /root/node-bundle.json \
  SHA256:<fingerprint-do-controlador>
```

O nó valida estrutura, `node_id`, identidade local, fingerprint pinado do controlador, assinatura e `node_epoch` antes de persistir a confiança.

## 2. Revogação e fencing por node_epoch

No controlador:

```bash
manager hive controller revoke node-0123456789abcdef compromised
```

A revogação desabilita o nó e incrementa `node_epoch`. O retorno exige re-enrollment explícito:

```bash
manager hive controller reenroll \
  /root/node-request.json \
  /root/node-bundle-new.json
```

Exemplo:

```text
primeiro enrollment  → node_epoch=1
revogação             → node_epoch=2
re-enrollment         → node_epoch=3
```

Depois que o nó aceita epoch 3, autoridade antiga de epoch 1 não volta a ser aceita.

## 3. Inicialização da rede privada

Depois do enrollment, cada nó inicializa sua identidade WireGuard local:

```bash
manager hive network init
manager hive network status
```

O status expõe a chave **pública** e seu `wireguard_key_id`; a chave privada permanece somente em:

```text
/etc/manager/hive/network/node.key
```

Não copie essa chave para o controlador.

## 4. Network request assinado

Cada VPS precisa informar um endpoint público alcançável pelos outros nós. Exemplo:

```bash
manager hive network request \
  vpn-br-01.example.com \
  /root/node-network-request.json \
  51870
```

Também pode ser usado IPv4 ou IPv6 literal.

O request inclui:

- `node_id` e `node_epoch`;
- `controller_id`;
- chave pública WireGuard + key ID;
- endpoint e porta;
- `issued_at` e nonce;
- assinatura Ed25519 da identidade enrolled do nó.

O arquivo não contém chave WireGuard privada.

## 5. Aprovação no controlador

Inicialize a autoridade de rede uma vez:

```bash
manager hive network controller init
manager hive network controller status
```

Aprove o request de cada nó:

```bash
manager hive network controller approve \
  /root/node-network-request.json
```

O controlador valida:

- enrollment atual do nó;
- `node_epoch`;
- assinatura Ed25519;
- validade temporal do request;
- nonce/formato;
- chave pública WireGuard;
- endpoint e porta.

Após aprovação, o nó recebe endereços privados únicos da Colmeia. A faixa inicial é administrada pelo controlador e não vira rota default do servidor.

Listagem:

```bash
manager hive network controller list
manager hive network controller show NODE_ID
```

Um nó pode ser retirado temporariamente da topologia:

```bash
manager hive network controller disable NODE_ID
manager hive network controller enable NODE_ID
```

`disable` impede que ele apareça em novos bundles; não apaga sua identidade nem sua chave WireGuard local.

## 6. Bundles de topologia

Bundle individual:

```bash
manager hive network controller bundle \
  NODE_ID \
  /root/NODE_ID.network.json
```

Bundles de todos os nós ativos:

```bash
mkdir -m 700 /root/hive-bundles
manager hive network controller bundle-all /root/hive-bundles
```

Cada bundle contém somente os peers que aquele nó precisa conhecer e é assinado pelo controlador.

O controlador incrementa `config_epoch` quando a topologia efetiva muda. O nó recusa:

- bundle com `config_epoch` menor que o já aceito;
- bundle divergente reutilizando o mesmo `config_epoch`;
- bundle destinado a outro `node_id`/`node_epoch`;
- bundle cuja chave pública WireGuard do target não corresponde à chave local;
- assinatura inválida ou bundle expirado.

## 7. Aplicação no nó

No nó de destino:

```bash
manager hive network accept /root/NODE_ID.network.json
```

Depois:

```bash
manager hive network status
manager hive network reconcile
```

`reconcile` reaplica a última topologia assinada durável.

Para desligar somente o runtime:

```bash
manager hive network down
```

A configuração gerenciada possui marker:

```text
# MANAGER-HIVE-NETWORK v1
```

Antes de aplicação, o MANAGER valida a configuração através de `wg-quick strip` com basename exato `mgh0.conf`.

Se `mgh0` já estiver ativa, uma mudança de topologia usa `restart` para garantir que peers removidos desapareçam do runtime. Se a aplicação falhar, o MANAGER restaura configuração, ownership e estado anteriores.

## Proteção de configuração externa

O MANAGER não assume ownership de qualquer `/etc/wireguard/mgh0.conf` arbitrário.

Se o arquivo já existir e não possuir ownership/marker válidos do MANAGER, a operação falha fechada. Symlink ou arquivo não regular também é recusado.

Isso impede update/reconcile/uninstall de sobrescrever ou remover uma interface `mgh0` criada manualmente por outro administrador.

## Rotas e caminho de dados

A topologia 0.8.1 usa somente endereços host internos de peers:

```text
AllowedIPs = <ipv4-do-peer>/32, <ipv6-do-peer>/128
```

O MANAGER não gera:

```text
0.0.0.0/0
::/0
```

Logo a malha não sequestra a rota default da VPS e não transforma o controlador em gateway do tráfego VPN dos usuários.

A porta WireGuard da Colmeia **não é aberta automaticamente** no firewall. A política de exposição continua sendo decisão operacional do administrador/provedor.

## Lifecycle de install, uninstall e rollback

A rede usa `modules/hive_lifecycle.sh` para se vincular ao lifecycle já existente da Automation v2 sem alterar a autoridade do daemon.

O módulo instala um drop-in MANAGER-owned em:

```text
/etc/systemd/system/manager-automation-v2.service.d/90-manager-hive-network.conf
```

E um helper em:

```text
/usr/local/libexec/manager-hive-lifecycle
```

No start do Automation v2, a topologia durável pode ser reconciliada. No stop causado por uninstall/rollback, `mgh0` é destacada enquanto o código atual ainda existe.

Quando a unidade é desabilitada por uninstall/rollback, o helper/drop-in se auto-remove para não deixar referência órfã caso a versão de destino não tenha Hive Network.

Uninstall/rollback normal removem somente runtime/ownership da malha. Permanecem duráveis:

- chave WireGuard local;
- chave pública;
- `network.conf`;
- último bundle/topologia aceita;
- identidade/enrollment Ed25519.

`manager-uninstall --purge` continua sendo a operação destinada a remover estado server-side persistente.

## Backup

`/etc/manager/hive` entra no backup protegido do MANAGER. Como ele pode conter chaves privadas de nó/controlador e da malha WireGuard, o backup deve ser tratado como segredo operacional.

A telemetria de uso local continua separada da futura autoridade global; a existência da rede privada não torna billing global autoritativo.

## Estado da 0.8.1

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
controller_user_traffic_transit=0
heartbeat=0
node_health=0
scheduler=0
drain_runtime=0
failover=0
global_lease_authority=0
global_max_sessions=0
global_accounting=0
```

A Colmeia já possui confiança e canal privado entre nós, mas ainda não é uma autoridade distribuída completa de sessões.

## Próxima etapa — 0.8.2

A 0.8.2 adicionará **heartbeat assinado e saúde dos nós** sobre a identidade e a rede já estabelecidas:

- payload de heartbeat assinado;
- freshness e anti-replay;
- preferência pela rede privada `mgh0` quando disponível;
- CPU, RAM, rede, sessões e capacidade;
- latência;
- protocolos e serviços disponíveis;
- estados `HEALTHY`, `DEGRADED`, `DRAINING` e `OFFLINE`;
- tolerância configurável para heartbeat perdido;
- último heartbeat e motivo de estado auditáveis;
- controlador continua fora do caminho do tráfego VPN.

Scheduler, drain real e autoridade de leases globais permanecem para milestones posteriores.
