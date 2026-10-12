# Automation v2 — contrato estruturado, RBAC, Ed25519 e transporte remoto

A Automation v2 é a interface oficial para integrações novas do MANAGER.

A série 0.7 foi construída em camadas:

- **0.7.1:** núcleo local estruturado, `managerd`/`managerctl`, idempotência e auditoria;
- **0.7.2:** principals e RBAC;
- **0.7.3:** autenticação Ed25519, enrollment, rotação e revogação;
- **0.7.4:** timestamp/nonce, anti-replay, rate limiting e transporte remoto TLS 1.3.

A 0.7.4 encerra a fundação da Automation. A próxima fase é a 0.8 Colmeia.

## Arquitetura

O desenho mantém uma única autoridade lógica:

```text
cliente local root
      │ Unix socket / SO_PEERCRED
      ▼
   managerd
      │
      ├── autenticação
      ├── freshness / anti-replay
      ├── rate limit
      ├── RBAC
      ├── idempotência
      ├── auditoria
      └── dispatcher allowlisted

cliente remoto
      │ TLS 1.3 + pin SHA-256
      ▼
remote gateway
      │ encaminha o envelope original
      ▼
Unix socket local
      ▼
   managerd
```

O gateway remoto **não executa ações privilegiadas por conta própria** e não cria um segundo motor de autorização.

## Serviços e estado

Local:

```text
manager-automation-v2.service
/run/manager-automation-v2/manager.sock
/usr/local/sbin/managerd
/usr/local/sbin/managerctl
```

Remoto:

```text
manager-automation-v2-remote.service
```

Estado durável:

```text
/etc/manager/automation/v2/
├── principals/
├── credentials/
├── remote.conf
└── tls/
    ├── server.crt
    └── server.key
```

Estado de runtime/dados:

```text
/var/lib/manager/automation-v2/
├── idempotency/
└── replay/
```

Auditoria:

```text
/var/log/manager/automation-v2-audit.jsonl
```

Permissões sensíveis são root-only.

## Status do contrato

```bash
manager automation v2 status
```

A 0.7.4 declara:

```text
contract=manager-automation-v2-local-v1
version=1
transport=unix,tls1.3
remote_transport=1
arbitrary_shell=0
rbac=1
principal_assertion=local-root-peercred-or-ed25519
cryptographic_auth=1
credential_algorithm=ed25519
auth_scheme=ed25519-v2
nonlocal_signature_required=1
enrollment=local-admin
key_rotation=1
key_revocation=1
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
remote_scoped_rbac=1
remote_node_scope=1
remote_pool_scope=1
remote_action_scope=1
```

`remote_transport=1` representa capacidade implementada. Use `manager automation v2 remote status` para saber se o listener está efetivamente habilitado.

## Principal local-root

`local-root` é reservado.

- role `admin`;
- subject `*`;
- autenticado exclusivamente pelo UID 0 observado em `SO_PEERCRED` no socket Unix;
- não recebe credencial Ed25519;
- não é aceito no transporte remoto.

Isso impede transformar um arquivo de credencial em equivalente remoto de root local.

## Principals e RBAC

Registry:

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

A matriz principal é:

| Ação | admin | reseller | subreseller | user |
|---|---:|---:|---:|---:|
| `system.describe` | sim | sim | sim | sim |
| `node.usage` | sim | não | não | não |
| `connection.preflight/create` | sim | escopo | próprio owner | não |
| `connection.status` | sim | escopo | próprio owner | própria identidade |
| `connection.revoke` | sim | escopo | próprio owner | não |

Revendedor atua na própria árvore e em subrevendedores filhos diretos. Subrevendedor não sobe para o pai. Usuário só consulta a identidade vinculada.

### Escopo remoto por nó, pool e ação — fundação 0.8.8

Principals não-locais também podem ser restringidos ao contexto do nó que recebe a chamada. Os campos persistidos são `node_scope`, `pool_scope` e `action_scope`; arquivos antigos sem esses campos mantêm `*` por compatibilidade.

```bash
manager automation v2 principal scope loja01 'node-a,node-b' 'BR-SP,BR-RJ' 'system.describe,connection.status'
```

A validação acontece **antes da idempotência e antes do dispatcher**. Assim, um `request_id` anteriormente autorizado não pode servir resultado em cache depois que o principal perde acesso à ação, ao nó ou ao pool. `local-root` continua reservado ao socket Unix local e não recebe escopo remoto configurável.

## Credenciais Ed25519

Registry público:

```text
/etc/manager/automation/v2/credentials/<principal>/
```

Para cada chave:

```text
<key_id>.conf
<key_id>.pub
```

O servidor não guarda a chave privada nesse registry.

### Enrollment

```bash
manager automation v2 credential enroll loja01 /root/loja01.credential
```

O arquivo privado é criado em modo `0600` no caminho explícito fornecido pelo administrador.

### Listar / mostrar

```bash
manager automation v2 credentials loja01
manager automation v2 credential show loja01 ed25519-0123456789abcdef
```

### Rotação

```bash
manager automation v2 credential rotate loja01 /root/loja01-v2.credential
```

A nova credencial é registrada antes da revogação das anteriores.

### Revogação

```bash
manager automation v2 credential revoke loja01 ed25519-0123456789abcdef
```

A revogação é reavaliada antes de servir replay idempotente.

## Ed25519 v2: timestamp e nonce assinados

O envelope não-local inclui:

```json
{
  "version": 1,
  "request_id": "exemplo-0001",
  "principal_id": "loja01",
  "action_id": "connection.status",
  "params": {"id": "maria"},
  "issued_at": 1791740000,
  "nonce": "nonce-aleatorio-com-entropia-suficiente",
  "auth": {
    "scheme": "ed25519-v2",
    "key_id": "ed25519-0123456789abcdef",
    "signature": "BASE64..."
  }
}
```

A assinatura cobre a forma canônica de:

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

Alterar qualquer um desses campos invalida a assinatura.

## Freshness

`issued_at` é obrigatório para principal não-local.

Janela aceita:

```text
±120 segundos
```

Timestamp muito antigo ou excessivamente no futuro é recusado antes de RBAC/dispatcher.

Esse mecanismo pressupõe relógios razoavelmente sincronizados. Em produção, mantenha NTP/systemd-timesyncd/chrony funcionando nos participantes.

## Anti-replay

O nonce é obrigatório e possui formato restrito.

Depois de uma assinatura válida, o daemon registra o nonce consumido em:

```text
/var/lib/manager/automation-v2/replay/<principal>/<key_id>/<sha256-do-nonce>
```

A criação usa semântica exclusiva: o mesmo nonce não pode ser consumido duas vezes.

O cache anti-replay é persistente no filesystem e usa retenção de aproximadamente **10 minutos**, superior à janela de freshness de 120 s.

Consequência:

```text
mesmo envelope assinado enviado duas vezes
→ segunda chamada = replay negado
```

### Replay de rede x retry idempotente

Esses conceitos são diferentes.

Para repetir uma operação com segurança:

```text
mesmo request_id
mesmo principal
mesma ação
mesmo payload lógico
NOVO issued_at
NOVO nonce
NOVA assinatura
```

O novo envelope passa freshness/anti-replay e depois pode receber o resultado idempotente já cacheado.

## Rate limiting

Principals não-locais possuem token bucket por `(principal_id, action_id)`.

Ações de leitura:

```text
system.describe
node.usage
connection.status
```

Limite:

```text
120 requisições/minuto
burst 20
```

Ações de escrita:

```text
connection.preflight
connection.create
connection.revoke
```

Limite:

```text
30 requisições/minuto
burst 8
```

Ao exceder, a resposta usa código temporário `75` e pode incluir `retry_after_seconds`.

`local-root` não passa por esse bucket remoto/non-local.

O gateway TLS possui ainda proteção própria por IP de origem:

```text
burst inicial: 30 conexões
refill: 2 por segundo
```

Essa camada é uma proteção de borda; a autoridade principal continua sendo o daemon.

## Transporte remoto TLS 1.3

### Estado

```bash
manager automation v2 remote status
```

Exemplo conceitual:

```text
remote_transport=1
remote_enabled=0|1
remote_service=inactive|active
remote_bind=203.0.113.10
remote_port=9443
remote_tls=TLSv1.3
server_fingerprint=SHA256:<64 hex>
```

### Habilitar

```bash
manager automation v2 remote enable 203.0.113.10 9443
```

`BIND_IP` precisa ser endereço IPv4/IPv6 literal. Porta permitida: `1024..65535`.

A implementação:

- gera chave/certificado Ed25519 se não existirem;
- grava `remote.conf` root-only;
- sobe `manager-automation-v2-remote.service`;
- exige o daemon Unix local ativo;
- **não abre firewall automaticamente**.

### Desabilitar

```bash
manager automation v2 remote disable
```

A configuração é preservada, mas o listener remoto é desligado.

### Rotacionar certificado

```bash
manager automation v2 remote rotate-certificate
```

A rotação produz novo fingerprint. Clientes precisam receber o novo pin por canal confiável.

### TLS

O gateway aceita somente:

```text
TLS 1.3
```

TLS 1.2 e inferiores são rejeitados.

O cliente não usa confiança genérica de CA para essa conexão. Ele exige pin explícito do certificado apresentado:

```text
SHA256:<64 hex do certificado DER>
```

Se o fingerprint não conferir, a conexão falha.

### Chamada remota

```bash
managerctl \
  --credential /root/loja01.credential \
  --remote 203.0.113.10:9443 \
  --server-fingerprint SHA256:<64-hex> \
  connection.status id=maria
```

IPv6:

```bash
managerctl \
  --credential /root/loja01.credential \
  --remote '[2001:db8::10]:9443' \
  --server-fingerprint SHA256:<64-hex> \
  connection.status id=maria
```

Transporte remoto exige:

- principal diferente de `local-root`;
- `--credential` válido;
- `--server-fingerprint` válido;
- TLS 1.3;
- assinatura Ed25519 v2;
- freshness/nonce válidos;
- rate limit;
- RBAC.

## Ações allowlisted

```text
system.describe
node.usage
connection.preflight
connection.create
connection.status
connection.revoke
```

O dispatcher monta `argv` conhecido e usa execução sem shell. O cliente não fornece comando, script ou caminho arbitrário.

## Idempotência

Estado:

```text
/var/lib/manager/automation-v2/idempotency/
```

Hash lógico:

```text
version
principal_id
action_id
params normalizados
```

`issued_at`, nonce e assinatura **não** fazem parte da identidade lógica da operação. Isso é intencional para permitir retry seguro com novo envelope criptográfico.

- mesmo principal + ação + payload: replay idempotente;
- mesmo `request_id` com payload/principal diferente: conflito `65`;
- autenticação/freshness/anti-replay/RBAC continuam sendo avaliados antes do cache.

Segredos gerados permanecem one-shot. Senha SSH/chaves privadas não são recuperadas por replay.

## Ordem de validação

Para principal não-local:

```text
peer local do gateway/Unix
       ↓
principal ativo
       ↓
credencial pública válida
       ↓
assinatura Ed25519 v2
       ↓
issued_at dentro da janela
       ↓
rate limit
       ↓
nonce único
       ↓
RBAC / ownership / produto
       ↓
idempotência
       ↓
dispatcher allowlisted
```

No transporte remoto, `local-root` é recusado explicitamente antes de qualquer ação.

## Auditoria

Campos relevantes incluem:

```text
principal_id
principal_role
principal_subject
transport
auth_scheme
auth_key_id
auth_fingerprint
auth_decision
freshness_decision
replay_decision
rate_limit_decision
rbac_decision
rbac_reason
request_issued_at
ok
code
cached
```

O audit não guarda assinatura, chave privada, senha ou stdout sensível.

## Lifecycle

### Instalação / update

- instala/reconcilia o daemon local;
- preserva principals e credenciais públicas;
- preserva configuração remota;
- se `remote_enabled=1`, recria/inicia o serviço remoto;
- readiness local exige socket real em modo `0600`.

### Uninstall normal

- desliga serviço remoto e daemon local;
- remove units/runtime;
- preserva estado durável sob `/etc/manager/automation/v2`;
- preserva dados necessários ao lifecycle normal.

### Purge

`manager-uninstall --purge` remove o estado server-side do MANAGER. Arquivos privados de credencial criados fora de `/etc/manager` continuam responsabilidade do administrador.

## Relação com Legacy

```text
Legacy v1
  compatibilidade syncpainel
  transporte SSH dedicado
  desligado por padrão

Automation v2
  integrações novas
  contrato estruturado
  principals + RBAC
  Ed25519 v2
  freshness + anti-replay
  rate limiting
  Unix local + gateway TLS 1.3 opcional
```

A Automation v2 não usa o transporte Legacy como arquitetura principal.

## Próxima etapa — 0.8 Colmeia

Com a fronteira remota fechada, a próxima fase passa a ser distribuída:

- identidade/enrollment de nós;
- heartbeat e saúde;
- estados `HEALTHY`, `DEGRADED`, `DRAINING`, `OFFLINE`;
- scheduler por região/pool/capacidade/peso/protocolo;
- sticky session;
- drain/failover;
- autoridade de leases globais;
- `max_sessions` global atômico;
- fencing distribuído por `session_epoch`;
- accounting global idempotente.
