# MANAGER Colmeia — identidade e enrollment de nós

A série 0.8 transforma o MANAGER de uma autoridade local por VPS em uma arquitetura coordenada entre múltiplos nós. A 0.8.0 cria somente a raiz de confiança da Colmeia: identidade criptográfica de nó, identidade de controlador, enrollment explícito, revogação e fencing por geração.

Esta versão **não** implementa heartbeat, scheduler, leases globais ou accounting global.

## Objetivos da 0.8.0

- reutilizar o `node_id` persistente já criado pelo Node Metadata;
- dar a cada nó um par Ed25519 próprio;
- dar ao controlador uma identidade Ed25519 própria;
- eliminar segredo compartilhado permanente no bootstrap;
- exigir aprovação explícita do controlador;
- exigir pin SHA-256 do controlador no primeiro aceite do nó;
- registrar `node_epoch` monotônico para fencing de enrollment antigo;
- permitir revogação e re-enrollment explícito;
- preservar o estado de confiança em uninstall/reinstall normal;
- incluir o estado da Colmeia em backups protegidos do MANAGER.

## Estado persistente

Nó:

```text
/etc/manager/hive/node/
├── node.key
├── node.pub
├── identity.conf
├── controller.conf
├── controller.pub
└── enrollment.conf
```

Controlador:

```text
/etc/manager/hive/controller/
├── controller.key
├── controller.pub
├── controller.conf
└── nodes/
    ├── node-....conf
    └── node-....pub
```

Chaves privadas e arquivos de autoridade usam permissões root-only. O MANAGER nunca envia a chave privada do nó dentro do enrollment request.

## Contratos

```text
manager-hive-node-identity-v1
manager-hive-controller-identity-v1
manager-hive-enrollment-request-v1
manager-hive-enrollment-bundle-v1
```

As identidades usam Ed25519 via OpenSSL. O fingerprint é SHA-256 da chave pública DER.

## Fluxo de enrollment

No nó que deseja entrar na Colmeia:

```bash
manager hive status
manager hive request /root/node-request.json
```

O request contém:

- `node_id`;
- `node_key_id`;
- fingerprint da chave pública;
- chave pública;
- snapshot de metadados do nó;
- `issued_at`;
- nonce;
- assinatura Ed25519 do próprio nó.

Ele não contém chave privada.

No controlador:

```bash
manager hive controller init
manager hive controller fingerprint
manager hive controller approve /root/node-request.json /root/node-bundle.json
```

O controlador valida a assinatura do request, registra a chave pública do nó e emite um bundle assinado. O primeiro enrollment usa:

```text
node_epoch=1
```

De volta ao nó, o administrador aceita o bundle informando explicitamente o fingerprint do controlador obtido por canal confiável:

```bash
manager hive accept \
  /root/node-bundle.json \
  SHA256:<fingerprint-do-controlador>
```

O nó verifica:

1. contrato e estrutura do bundle;
2. `node_id` local;
3. fingerprint/key ID da própria identidade;
4. fingerprint pinado do controlador;
5. identidade derivada da chave pública do controlador;
6. assinatura Ed25519 do bundle;
7. `node_epoch` contra o estado já aceito.

Só então grava `controller.pub`, `controller.conf` e `enrollment.conf`.

## Revogação

No controlador:

```bash
manager hive controller revoke node-0123456789abcdef compromised
```

A revogação:

- marca o nó como `enabled=0`;
- grava `revoked_epoch`;
- incrementa `node_epoch`;
- impede um `approve` normal de reativar silenciosamente a identidade.

Depois de uma revogação, o retorno precisa ser explícito:

```bash
manager hive controller reenroll \
  /root/node-request.json \
  /root/node-bundle-new.json
```

Isso produz uma geração nova e incrementa `node_epoch` novamente.

## Fencing por node_epoch

`node_epoch` representa a geração de autoridade do enrollment de um nó.

Exemplo:

```text
primeiro enrollment  → node_epoch=1
revogação             → node_epoch=2
re-enrollment         → node_epoch=3
```

Depois que o nó aceita epoch 3, um bundle antigo de epoch 1 é recusado. Esse mecanismo será reutilizado nas fases posteriores da Colmeia para impedir que uma autoridade antiga volte a ser aceita depois de failover/revogação.

## Administração do controlador

```bash
manager hive controller status
manager hive controller fingerprint
manager hive controller list
manager hive controller show NODE_ID
manager hive controller revoke NODE_ID [REASON]
```

O controlador da 0.8.0 é somente uma autoridade local de enrollment. Ele ainda não recebe heartbeat nem escolhe servidores para sessões.

## Backup e lifecycle

`/etc/manager/hive` entra no backup protegido do MANAGER. Portanto o arquivo de backup pode conter chaves privadas de nó/controlador e deve ser tratado como segredo operacional.

Uninstall normal preserva `/etc/manager/hive`, permitindo reinstalação sem trocar as identidades criptográficas.

`manager-uninstall --purge` remove o estado server-side da Colmeia.

## Limites explícitos da 0.8.0

```text
heartbeat=0
node_health=0
scheduler=0
drain_runtime=0
failover=0
global_lease_authority=0
global_max_sessions=0
global_accounting=0
```

A existência de enrollment **não** deve ser interpretada como Colmeia operacional completa.

## Próxima etapa — 0.8.1

A 0.8.1 adicionará heartbeat e saúde dos nós sobre essa identidade já estabelecida:

- payload de heartbeat assinado;
- freshness/anti-replay;
- CPU, RAM, rede, sessões e capacidade;
- protocolos e serviços disponíveis;
- estados `HEALTHY`, `DEGRADED`, `DRAINING` e `OFFLINE`;
- tolerância configurada para heartbeat perdido;
- controlador sem ficar no caminho do tráfego VPN.

Scheduler e autoridade de leases globais permanecem para milestones posteriores.