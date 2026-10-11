# Produtos, planos, ACL e franquias

A série 0.6.5 adiciona uma camada de produto/plano sobre as identidades do Connection Engine. O objetivo é separar o que uma identidade técnica **pode fazer** do produto comercial/operacional que limita essa identidade.

## Modelo

Um produto pode definir:

```text
id
name
enabled
duration_days
max_sessions
protocols
traffic_quota_bytes
quota_period
quota_action
acl_regions
acl_pools
acl_nodes
```

Exemplo conceitual:

```text
Brasil Premium
├── protocolos = wireguard,openvpn
├── max_sessions = 1
├── duração = 30 dias
├── franquia = 500 GiB/mês
├── ação = block
├── regiões = BR
├── pools = BR-PREMIUM
└── nós = *
```

O produto **restringe** a política base da identidade. Ele não aumenta silenciosamente privilégios.

## Política base e política efetiva

Antes de aplicar um produto, o MANAGER salva os valores base da identidade:

```text
base_max_sessions
base_protocols
base_expires_epoch
```

A política efetiva é calculada assim:

- protocolos: interseção entre protocolos base e protocolos permitidos pelo produto;
- sessões: o menor limite entre a identidade e o produto quando o produto define um limite;
- expiração: a menor data entre a validade já existente e `assigned_epoch + duration_days`;
- produto com `max_sessions=0` herda o limite base;
- produto com `duration_days=0` herda a expiração base.

Ao desvincular o produto, os valores base salvos são restaurados.

Isso evita que a troca de plano destrua a configuração original da identidade.

## Protocolos

Os protocolos reconhecidos continuam sendo:

```text
ssh
wireguard
openvpn
```

Um produto pode usar `*` para herdar todos os protocolos base da identidade ou uma lista explícita.

O MANAGER rejeita uma atualização de produto que deixaria uma identidade já vinculada sem nenhum protocolo compatível.

## Limite de sessões

O produto alimenta o mesmo `max_sessions` efetivo usado pelo Session / Lease Engine. Portanto o limite não é uma segunda implementação paralela.

Exemplo:

```text
identidade base: max_sessions=5
produto:         max_sessions=1
política efetiva: max_sessions=1
```

O Session Engine continua sendo a autoridade local de aquisição, heartbeat, release e fencing.

Na Colmeia essa mesma política será usada pelo Hub para `max_sessions_global`.

## Franquia de tráfego

`traffic_quota_bytes=0` significa tráfego ilimitado.

Quando existe franquia finita, os períodos disponíveis são:

```text
monthly
lifetime
```

A franquia começa a partir de um baseline do acumulado da identidade. Tráfego ocorrido antes da atribuição do produto não é cobrado retroativamente.

### monthly

O ciclo é identificado em UTC no formato `YYYY-MM`. Na primeira reconciliação após a mudança de mês, o acumulado atual vira o novo baseline do ciclo.

### lifetime

O ciclo acompanha a atribuição atual do produto. Ele não reinicia automaticamente por calendário.

### Reset administrativo

```bash
/opt/manager/modules/products.sh --reset-quota ID
```

O acumulado histórico do Identity Usage não é apagado. Apenas o baseline do produto avança para o total atual.

## `warn` e `block`

Um produto pode definir:

```text
quota_action=warn
```

ou:

```text
quota_action=block
```

Em `warn`, a franquia aparece como excedida, mas a identidade continua ativa.

Em `block`, uma identidade com accounting completo entra em:

```text
quota-exceeded
```

Como `identity_effective_state` é consumido pelo Policy Engine e Session Engine, novas sessões deixam de ser autorizadas e a política local é reconciliada pelos mecanismos já existentes.

## Segurança da franquia e SSH

A 0.6.4 mede bytes reais de WireGuard e OpenVPN. SSH ainda não possui byte accounting confiável por sessão.

Por isso, se uma identidade possui SSH efetivamente vinculado, o MANAGER informa:

```text
quota_exceeded=1
quota_enforceable=0
```

quando o total medido ultrapassa a franquia, mas **não transforma o estado em `quota-exceeded`**.

Isso é deliberado: bloquear um cliente com base em bytes parciais seria um falso enforcement. Quando houver accounting SSH confiável, essa restrição poderá ser removida sem alterar o modelo de produto.

## ACL de região, pool e nó

Cada produto possui:

```text
acl_regions
acl_pools
acl_nodes
```

`*` significa sem restrição nessa dimensão.

Exemplo:

```text
acl_regions=BR
acl_pools=BR-PREMIUM
acl_nodes=*
```

Contrato não interativo:

```bash
/opt/manager/modules/products.sh --authorize ID PROTOCOL REGION POOL NODE
```

A autorização verifica:

1. estado efetivo da identidade;
2. protocolo permitido;
3. região permitida;
4. pool permitido;
5. nó permitido.

Na 0.6.5, a restrição de protocolo já é aplicada automaticamente porque o produto reduz a lista efetiva de protocolos da identidade. Região/pool/nó já possuem contrato e armazenamento, mas serão injetados automaticamente no caminho de conexão quando os metadados de nó/região forem adicionados antes da Colmeia.

## Produto desabilitado

Se um produto atribuído recebe:

```text
enabled=0
```

a identidade passa a apresentar:

```text
product-disabled
```

O produto pode ser reativado sem destruir a identidade nem suas credenciais técnicas.

## Estado persistente

Catálogo:

```text
/etc/manager/connection/products/catalog/
```

Vínculos:

```text
/etc/manager/connection/products/assignments/
```

Estado/baseline de franquia:

```text
/etc/manager/connection/product-usage/identities/
```

Os contadores acumulados continuam pertencendo ao Identity Usage:

```text
/var/lib/manager/identity-usage/identities/
```

Essa separação significa que o produto guarda a regra e o baseline, enquanto o accounting guarda os fatos acumulados de tráfego.

## CLI

Listar produtos:

```bash
manager --products
```

Detalhar produto:

```bash
manager --product premium
```

Ver produto e consumo de uma identidade:

```bash
manager --product-assignment maria
```

O módulo também possui menu interativo em:

```text
32) Produtos, planos, ACL e franquias
```

## Contrato não interativo

Criar produto:

```text
products.sh --create ID NAME ENABLED DURATION_DAYS MAX_SESSIONS PROTOCOLS QUOTA_BYTES QUOTA_PERIOD QUOTA_ACTION REGIONS POOLS NODES
```

Atualizar produto:

```text
products.sh --update ...
```

Vincular:

```bash
products.sh --assign ID PRODUCT
```

Desvincular e restaurar política base:

```bash
products.sh --unassign ID
```

Autorizar contexto:

```bash
products.sh --authorize ID PROTOCOL REGION POOL NODE
```

Reconciliar:

```bash
products.sh --reconcile
```

## Reconciliação

A unidade periódica é:

```text
manager-product-policy.timer
manager-product-policy.service
```

Ela atualiza ciclos de franquia, estado de excesso e política derivada a cada poucos segundos, sem criar um daemon adicional obrigatório.

## Backup, uninstall e rollback

Produto, vínculo, ACL e baseline ficam dentro de `/etc/manager/connection`, portanto usam o mesmo backup persistente do Connection Engine.

- uninstall normal remove o reconciliador, mas preserva o estado;
- reinstalação reaplica a política persistida;
- `--purge` remove o estado junto com `/etc/manager`;
- rollback desanexa a unidade antes da troca de código;
- ao voltar para uma versão que conhece produtos, a reconciliação é reinstalada.

## Limites da 0.6.5

- franquia e autoridade ainda são locais a uma VPS;
- não há faturamento global nem agregação multi-nó nesta etapa;
- cotas de revendedor ainda são baseadas no modelo atual e não foram migradas para quantidade de produtos/identidades;
- ACL de região/pool/nó já existe como contrato, mas a descoberta automática do contexto depende dos metadados de endpoint/nó ainda planejados;
- byte accounting de SSH permanece não suportado para enforcement de franquia.

Esses limites são intencionais para que Automation v2 e Colmeia reutilizem a mesma identidade, produto, lease e accounting sem reescrever a base local.
