# Telegram Operational Reads

Esta fatia da série 0.9 adiciona um gateway **somente leitura** para o futuro Mini App e outras interfaces Telegram locais, sem ampliar a superfície de escrita do Bot.

## Contratos

- gateway operacional: `manager-telegram-operations-v1`
- request: `manager-telegram-operations-request-v1`
- backend sanitizado: `manager-automation-read-ops-v1`
- capability de autorização: `node.usage`
- campo público correspondente: `authorization_capability=node.usage`

O request contém exatamente:

```json
{"contract":"manager-telegram-operations-request-v1","request_id":"miniapp-ops-00000001","operation":"identities","params":{}}
```

Operações allowlisted nesta etapa:

- `identities`: identidades, estado, owner, protocolos, produto e resumo de quota;
- `products`: produtos, limites, quota e ACLs;
- `sessions`: leases/sessões locais ativas;
- `nodes`: último health sanitizado por nó a partir do export de observabilidade da Colmeia;
- `diagnostics`: carga, memória, disco, reboot pendente e estado de serviços conhecidos.

Nenhuma dessas operações aceita parâmetros nesta primeira versão. Cada resposta é limitada a no máximo 100 itens por coleção.

## Autorização

O gateway operacional **não implementa RBAC paralelo**. Antes de executar qualquer leitura ele envia uma chamada real `node.usage` pelo `manager-telegram-gateway-v1`. Essa chamada passa por Telegram identity/auth e depois pela Automation v2.

Portanto a leitura somente ocorre quando o `managerd` aceita simultaneamente:

- principal autenticado;
- role `admin` exigida por `node.usage`;
- `action_scope` contendo `node.usage` (ou `*`);
- `node_scope` compatível com o nó local;
- `pool_scope` compatível com o pool local;
- rate limit por principal/ação;
- assinatura Ed25519/freshness/anti-replay quando aplicáveis.

Nesta fatia, `node.usage` funciona como uma capability agrupada de leitura administrativa. Não são criados cinco novos action IDs globais na Automation v2 antes de existir filtragem/paginação segura para reseller e subreseller.

## Idempotência e freshness

A autorização usa um `request_id` determinístico derivado da operação e do request externo, então retries passam pela idempotência da Automation v2. O snapshot operacional, porém, é sempre lido novamente depois da autorização: `snapshot_cached=false`.

Isso é deliberado porque as operações são read-only e o Mini App deve receber estado atual de sessões, quotas e nós.

## Segurança

- nenhuma shell arbitrária;
- nenhum texto Telegram vira comando;
- o mapa operação -> comando interno é fixo;
- `initData` nunca entra em argv nem em audit;
- bot token, private keys, credential files, assinaturas e nonces não fazem parte do contrato público;
- arquivos de estado/audit são root-only;
- subprocessos usam argv fixo e `shell=False` no backend Python;
- o export da Colmeia continua sanitizado e sem material criptográfico;
- operações de escrita continuam fora desta fatia.

## Interface local

Status:

```bash
sudo /opt/manager/modules/telegram_operations.sh --status
```

Mini App/backend, passando `initData` por stdin:

```bash
cat initdata.txt | sudo /opt/manager/modules/telegram_operations.sh --call-stdin request.json
```

O Bot utiliza o modo interno `--call-bot-user` para os comandos públicos `/clients`, `/products`, `/sessions`, `/nodes` e `/diagnostics`.
Cada comando corresponde a uma operação allowlisted sem parâmetros, exige a autorização administrativa `node.usage` pelo gateway existente e devolve um resumo textual sem chaves ou credenciais.
Erros de autorização e limites são devolvidos como mensagens genéricas. Falhas temporárias não avançam o offset de processamento até que a operação possa ser repetida.
Revendedores e subrevendedores permanecem sem acesso às listagens globais até a implementação de filtros por escopo no lado servidor.

## Próximas etapas

Antes de expor listagens para `reseller`/`subreseller`, o contrato deve ganhar paginação e filtros derivados do owner/node/pool scopes. Escritas pelo Telegram continuam condicionadas a um fluxo separado com confirmação explícita e token de intenção de curta duração.

## Consultas paginadas com escopo (Automation v2)

O novo contrato `manager-automation-scoped-reads-v1` usa a ação tipada `ops.read` para admin, reseller, subreseller e user.
O Telegram envia somente `view`, `page` e `limit`; não pode escolher owner, role, subject ou products.
A autoridade fica no `managerd`, que carrega e verifica o principal autenticado, suas permissões e seus escopos de ação, nó, pool e produto.

As views são `clients`, `products`, `sessions` e `quotas`. `page` começa em 0 (0..100000), `limit` varia de 1 a 25 (padrão 8). Os filtros de autorização são aplicados **antes** da paginação.
O contrato retorna `items`, `count` (somente quantidade na página), `page`, `limit`, `has_more` e `next_page`; o total global nunca é exposto. Páginas separadas consultam snapshots novos, podendo ocorrer mudanças na ordem entre chamadas.

- admin: leitura dos registros locais, sob escopos de ação/nó/pool;
- reseller: suas identidades e de subrevendedores ativos que lhe pertencem, apenas para produtos permitidos;
- subreseller: somente identidades próprias dentro do escopo de produtos;
- user: somente sua identidade e respectivo plano, sessões e quota.

Ação `ops.read` não faz replay de snapshots no cache de idempotência: ao revogar owner, produto ou scope, até a repetição do mesmo request_id recebe a visão atual autorizada.
Rate limit, autenticação Ed25519, anti-replay e logs permanecem sob o controle da Automation v2.

```json
{"contract":"manager-telegram-gateway-request-v1","request_id":"miniapp-page-00000001","action_id":"ops.read","params":{"view":"clients","page":"0","limit":"8"}}
```

O Bot expõe `/clients [PÁGINA]`, `/products [PÁGINA]`, `/sessions [PÁGINA]` e `/quotas [PÁGINA]`, com página começando em 1. `/nodes` e `/diagnostics` continuam somente administrativos pelo gateway anterior usando `node.usage`.
