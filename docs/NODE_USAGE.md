# Node Usage — agregado local por nó

`modules/node_usage.sh` fecha a lacuna entre o accounting por identidade e a futura operação multi-servidor.

Ele produz um snapshot derivado do nó atual usando três fontes locais já existentes:

- identidade/metadados do nó;
- estados persistentes do Identity Usage Accounting;
- leases ativas do Session Engine.

O módulo não cria um segundo banco de accounting e não cria um novo timer. Os números são calculados a partir das fontes locais no momento da consulta.

## Consulta

```bash
/opt/manager/modules/node_usage.sh --show
```

Saída em `key=value` com contrato:

```text
contract=manager-node-usage-v1
usage_scope=node-local
aggregation_kind=cumulative-local-metered
billing_authoritative=0
global_usage_supported=0
```

Também há uma visão humana:

```bash
/opt/manager/modules/node_usage.sh --human
```

## Dados agregados

O snapshot inclui:

- `node_id`;
- país, região e pool;
- capacidade, peso e limite declarado de sessões do nó;
- estado `enabled` do nó;
- capacidade IPv6;
- total de identidades locais;
- identidades ativas;
- identidades com accounting persistente;
- leases locais ativas;
- quantidade de identidades com lease;
- protocolos atualmente ativos;
- download/upload medidos;
- total medido;
- decomposição WireGuard/OpenVPN;
- última atividade conhecida.

## Semântica de tráfego

Os bytes são a soma dos acumulados locais por identidade mantidos pelo Identity Usage Accounting.

Atualmente:

```text
metered_protocols=wireguard,openvpn
ssh_bytes_supported=0
```

Se houver identidade SSH vinculada, `traffic_complete=0` deixa explícito que o total de bytes do nó é parcial.

## Não é billing global

O módulo declara obrigatoriamente:

```text
billing_authoritative=0
global_usage_supported=0
billing_note=local_telemetry_not_global_billing
```

Isso impede que uma integração trate a soma local como franquia global quando uma identidade puder circular por vários servidores.

A futura Colmeia poderá coletar snapshots de vários nós, mas a autoridade global de uso precisará de regras próprias de deduplicação, ordenação, idempotência e consistência. O `node_usage.sh` deliberadamente não finge resolver esse problema na série 0.6.

## Relação com a Automation v2

A Automation v2 pode usar esse contrato como fonte local de telemetria do nó. Ela não precisa ler diretamente arquivos de `/var/lib/manager/identity-usage` nem entender o formato interno das leases.

Essa separação mantém o estado local do Connection Engine desacoplado do futuro transporte/API.
