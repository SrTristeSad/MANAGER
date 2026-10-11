# Automation v2 — núcleo local, principals e RBAC

A Automation v2 é a interface oficial para integrações novas do MANAGER. A série 0.7 constrói essa superfície em camadas antes de abrir qualquer transporte remoto.

- **0.7.1:** núcleo local estruturado, `managerd`/`managerctl`, idempotência e auditoria;
- **0.7.2:** principals e RBAC;
- **0.7.3:** autenticação criptográfica e enrollment;
- **0.7.4:** anti-replay, rate limiting e transporte remoto estruturado.

A Colmeia só começa depois dessas fronteiras estarem estabilizadas.

## Transporte local

O serviço é:

```text
manager-automation-v2.service
```

O socket privilegiado é:

```text
/run/manager-automation-v2/manager.sock
```

Permissões esperadas:

```text
runtime: 0700
socket:  0600
```

O daemon valida o peer Unix com `SO_PEERCRED`. Nesta versão o socket continua acessível somente a root. Portanto, `principal_id` ainda é uma **asserção confiável do chamador local root**, e não uma autenticação remota.

Status:

```bash
manager automation v2 status
```

Contrato atual:

```text
contract=manager-automation-v2-local-v1
transport=unix
remote_transport=0
arbitrary_shell=0
rbac=1
principal_assertion=root-local
cryptographic_auth=0
anti_replay=0
rate_limit=0
idempotency=1
audit=1
secret_replay=0
```

Os zeros são intencionais. A 0.7.2 implementa autorização, mas ainda não pretende provar a identidade de um cliente remoto.

## Principals

Estado persistente:

```text
/etc/manager/automation/v2/principals/
```

Cada principal é um registro root-only `0600`. O diretório é `0700`.

Papéis suportados:

```text
admin
reseller
subreseller
user
```

O MANAGER não cria uma segunda árvore de propriedade. Os principals são vinculados aos objetos já existentes:

- `reseller` e `subreseller` apontam para `/etc/manager/access/resellers/`;
- `user` aponta para uma identidade do Connection Engine;
- `admin` usa escopo global.

O principal reservado:

```text
local-root
```

é criado automaticamente, possui `role=admin`, `subject=*` e não pode ser desabilitado pela interface normal. Ele mantém compatibilidade com chamadas locais antigas de `managerctl` que não informam `--principal`.

### Administração local

```bash
manager automation v2 principals
manager automation v2 principal show ID
manager automation v2 principal create ID ROLE SUBJECT [PRODUCTS]
manager automation v2 principal enable ID
manager automation v2 principal disable ID
manager automation v2 principal products ID SCOPE
```

Exemplos:

```bash
manager automation v2 principal create loja01 reseller loja01 premium,basic
manager automation v2 principal create sub01 subreseller sub01 premium
manager automation v2 principal create cliente01 user maria
manager automation v2 principal create operador admin
```

Para revendedor/subrevendedor, `PRODUCTS` pode ser `*` ou uma lista CSV explícita.

## Envelope

Requisição conceitual:

```json
{
  "version": 1,
  "request_id": "exemplo-0001",
  "principal_id": "loja01",
  "action_id": "connection.status",
  "params": {
    "id": "maria"
  }
}
```

Resposta conceitual:

```json
{
  "contract": "manager-automation-v2-local-v1",
  "version": 1,
  "request_id": "exemplo-0001",
  "principal_id": "loja01",
  "principal_role": "reseller",
  "action_id": "connection.status",
  "ok": true,
  "code": 0,
  "cached": false,
  "result": {
    "data": {}
  }
}
```

Cliente local:

```bash
managerctl --principal loja01 connection.status id=maria
```

Sem `--principal`, o cliente usa `local-root`.

## Matriz RBAC

### `system.describe`

Permitido para:

```text
admin
reseller
subreseller
user
```

A operação expõe somente o contrato/capacidades estruturadas do Connection Engine.

### `node.usage`

Permitido somente para:

```text
admin
```

A telemetria agregada do nó não é exposta a uma revenda inteira por padrão.

### `connection.preflight` e `connection.create`

Permitido para:

```text
admin
reseller
subreseller
```

`user` não pode provisionar.

Para `reseller`/`subreseller`:

- o produto precisa estar no escopo `products` do principal;
- se `owner` for omitido, o MANAGER força o owner do principal;
- um revendedor pode atuar em sua própria revenda e em subrevendedores filhos diretos;
- um subrevendedor só pode atuar em seu próprio owner;
- não é possível apontar `owner` para outra árvore de revenda.

Exemplo:

```bash
managerctl --principal loja01 \
  connection.create \
  id=maria \
  plan=premium \
  protocols=ssh,wireguard
```

Mesmo sem `owner=loja01`, o daemon injeta o owner permitido antes de executar o provisionador.

### `connection.status`

- `admin`: qualquer identidade;
- `reseller`: identidades próprias e de subrevendedores filhos diretos;
- `subreseller`: somente identidades do próprio owner;
- `user`: somente a identidade vinculada ao principal.

### `connection.revoke`

- `admin`: qualquer identidade;
- `reseller`: identidades no próprio escopo de ownership;
- `subreseller`: identidades do próprio owner;
- `user`: proibido.

Negação RBAC usa código estável:

```text
67
```

## Validação do principal

A cada requisição o daemon relê e valida o principal antes do dispatcher privilegiado.

Ele verifica, entre outros:

- arquivo regular;
- proprietário root;
- ausência de permissões de grupo/mundo;
- `enabled=1`;
- role conhecida;
- reseller/subreseller de backing existente, com role correspondente e ativo;
- identidade de backing existente para principal `user`.

Isso evita que um principal continue válido apenas porque foi carregado no início do processo.

Desabilitar uma revenda no estado de revenda também invalida seu principal na próxima chamada.

## RBAC e idempotência

A autorização é executada **antes** da consulta ao cache de idempotência.

Consequência:

```text
request executado
        ↓
principal desabilitado
        ↓
retry do mesmo request_id
        ↓
NEGADO
```

Se o principal for reabilitado e o payload continuar igual, o replay idempotente pode voltar a fornecer o resultado sanitizado.

O hash de idempotência inclui:

```text
version
principal_id
action_id
params normalizados
```

Portanto, outro principal não pode reutilizar o mesmo `request_id` para herdar uma operação. A tentativa produz conflito `65`.

## Ações allowlisted

A lista permanece pequena:

```text
system.describe
node.usage
connection.preflight
connection.create
connection.status
connection.revoke
```

Não existe ação para executar shell, comando arbitrário, script ou caminho fornecido pelo chamador. O daemon constrói `argv` fixos e usa subprocesso com `shell=False`.

## Idempotência e segredos

Estado:

```text
/var/lib/manager/automation-v2/idempotency/
```

O `request_id` representa uma operação lógica.

- mesmo principal + mesma ação + mesmo payload normalizado: replay idempotente;
- mesmo `request_id` com principal/payload diferente: conflito `65`;
- respostas persistidas são sanitizadas.

Se `connection.create` gerar uma senha SSH, ela aparece somente na primeira resposta. O cache remove campos e linhas sensíveis antes da persistência.

```text
primeira chamada  -> operação executada + segredo one-shot
retry idempotente -> sucesso cacheado, sem recuperar o segredo
```

Quando aplicável:

```text
secret_replay_available=false
secret_returned_once=true
```

## Auditoria RBAC

Arquivo:

```text
/var/log/manager/automation-v2-audit.jsonl
```

Além dos metadados da 0.7.1, cada evento pode registrar:

```text
principal_id
principal_role
principal_subject
rbac_decision=allow|deny
rbac_reason
```

O audit continua sem senha, chave privada ou stdout sensível.

Uma negação de escopo também é auditada; não é necessário que a ação chegue ao provisionador para gerar evidência operacional.

## Lifecycle

Instalação:

- instala o registry de principals;
- garante `local-root`;
- instala/inicia `manager-automation-v2.service`;
- só retorna sucesso quando o socket existir em `0600`.

Uninstall normal:

- para o daemon;
- remove socket/unit/aliases;
- preserva `/etc/manager/automation/v2/principals`;
- preserva cache de idempotência e audit.

Reinstall reaplica o código e reutiliza os principals existentes.

`manager-uninstall --purge` remove o estado persistente do MANAGER, incluindo principals.

## Limite de confiança da 0.7.2

É importante distinguir **autorização** de **autenticação**.

Nesta versão:

```text
RBAC:                     pronto
principal lógico:         pronto
isolamento de ownership:  pronto
escopo de produto:        pronto
transporte remoto:        ausente
autenticação criptográfica: ausente
anti-replay remoto:       ausente
rate limiting:            ausente
```

Como o socket é `0600`, somente root local pode afirmar `--principal`. Isso é adequado para construir/testar a política sem abrir uma superfície remota prematuramente.

A 0.7.3 trocará a confiança implícita da asserção local por identidade criptográfica/enrollment para integrações que precisem autenticar-se.

## Relação com o Legacy

```text
Legacy v1
  compatibilidade syncpainel
  transporte SSH dedicado
  desligado por padrão

Automation v2
  integrações novas
  contrato estruturado
  principals/RBAC
  socket privilegiado local como fronteira
```

A v2 não usa o transporte Legacy como arquitetura principal.

## Próxima etapa — 0.7.3

A próxima etapa é **autenticação criptográfica + enrollment**:

- chave por integração/principal;
- enrollment explícito;
- fingerprint;
- revogação;
- rotação de chave;
- armazenamento root-only;
- associação inequívoca entre chave autenticada e `principal_id`;
- nenhuma senha compartilhada em texto claro.

Timestamp/nonce, anti-replay, rate limiting e transporte remoto estruturado permanecem para a 0.7.4.

Heartbeat distribuído, scheduler, drain/failover e leases globais continuam pertencendo à 0.8 Colmeia.
