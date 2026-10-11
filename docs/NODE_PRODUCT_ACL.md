# ACL automática por nó

A série 0.6.10 liga os metadados persistentes do nó às ACLs de produtos do MANAGER.

## Contexto local

O contexto autoritativo local é lido de:

```text
/etc/manager/connection/node/node.conf
```

Para autorização de produto, os campos usados são:

```text
region
pool
node_id
```

`country` continua sendo metadado administrativo. O MANAGER não converte país em região automaticamente, porque região e pool são agrupamentos lógicos definidos pelo operador e não uma consequência obrigatória da geolocalização do IP.

## Autorização automática

A forma local recomendada é:

```bash
/opt/manager/modules/products.sh --authorize IDENTIDADE PROTOCOLO
```

Quando `REGION`, `POOL` e `NODE` não são informados, o Product Policy resolve os valores usando o `node.conf` da própria VPS.

Exemplo:

```text
node_id=node-a1b2c3d4
region=BR-SP
pool=BRASIL-PREMIUM
```

Produto:

```text
acl_regions=BR-SP
acl_pools=BRASIL-PREMIUM
acl_nodes=node-a1b2c3d4
```

Nesse caso a autorização local é aceita. Se qualquer dimensão restrita não corresponder, a autorização é recusada.

## Compatibilidade

A forma explícita continua disponível:

```bash
/opt/manager/modules/products.sh --authorize IDENTIDADE PROTOCOLO REGION POOL NODE
```

Valores explícitos têm precedência sobre o contexto local. Isso preserva o contrato existente para testes, migração e futuros componentes que precisem avaliar um destino diferente do nó em que a chamada está sendo executada.

## Fail closed

Uma ACL `*` não exige metadado correspondente.

Uma ACL restrita exige valor válido. Portanto, se o produto exige `BR-SP` e o nó está com `region` vazio, a autorização falha. O MANAGER não interpreta ausência de metadado como permissão ampla.

## Session Engine

A admissão de leases usa o mesmo contrato de Product Policy. Uma identidade cujo produto não autoriza a região, pool ou `node_id` do servidor não recebe uma nova lease naquele nó.

Isso permite que os protocolos continuem usando a autoridade local atual enquanto prepara o mesmo modelo para a Colmeia:

```text
identidade
    ↓
produto / ACL
    ↓
region + pool + node_id
    ↓
Session Engine
    ↓
lease permitida ou recusada
```

## Colmeia

Na futura Colmeia, o Hub poderá avaliar vários nós candidatos usando as mesmas dimensões antes do scheduler escolher um destino. A etapa 0.6.10 não implementa scheduler global, heartbeat distribuído ou lease global; ela fecha o contrato local que esses componentes reutilizarão.

O modelo permanece:

```text
Região = agrupamento lógico/geográfico apresentado ao produto
Pool   = agrupamento de capacidade/plano/protocolo
Nó     = VPS concreta identificada por node_id
```

Um nó pode mudar de região ou pool administrativamente sem trocar seu `node_id`.
