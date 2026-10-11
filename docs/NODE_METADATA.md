# Identidade e metadados do nó

A série 0.6.x prepara o MANAGER para operar vários servidores sem confundir identidade de cliente com identidade de VPS. O módulo `node_metadata.sh` cria um identificador estável para cada instalação e mantém os metadados que serão consumidos pelo futuro modo Colmeia.

## Conceitos

Os objetos têm funções diferentes:

- **Colmeia**: domínio de cooperação entre vários servidores MANAGER.
- **Região**: agrupamento lógico/geográfico, por exemplo `BR`, `BR-SP` ou `EU`.
- **Pool**: grupo operacional/comercial, por exemplo `BRASIL-PREMIUM` ou `SAO-PAULO-1`.
- **Nó**: uma VPS concreta, identificada por um `node_id` estável.

Uma Colmeia pode conter vários nós no mesmo país, cidade ou provedor. País é somente metadado do nó; não define sozinho uma Colmeia.

## Estado persistente

O estado fica em:

```text
/etc/manager/connection/node/node.conf
```

O diretório faz parte do estado persistente do Connection Engine. Por isso ele entra no backup existente e é preservado em uma desinstalação normal. `manager-uninstall --purge` continua sendo a operação explícita para remover o estado do MANAGER.

O `node_id` é criado uma única vez no primeiro `--init` e não pode ser alterado por `--node-set`. Reinstalar o MANAGER sem purge não gera outro ID.

Exemplo:

```text
node_id=node-91a7c5c90ec42c4b
```

O ID não é uma chave criptográfica nem um segredo. A identidade criptográfica usada no futuro enrollment da Colmeia será separada.

## Campos

O registro atual contém:

| Campo | Função |
| --- | --- |
| `node_id` | identificador técnico estável e somente leitura |
| `name` | nome amigável do servidor |
| `country` | código de país de duas letras, como `BR` |
| `region` | região lógica, como `BR-SP` |
| `pool` | grupo de capacidade/serviço, como `BRASIL-PREMIUM` |
| `provider` | identificador administrativo do provedor |
| `city` | cidade/metro administrativa |
| `capacity` | capacidade lógica declarada do nó |
| `weight` | peso relativo que poderá ser usado pelo scheduler |
| `max_sessions` | teto local declarado; `0` significa que nenhum teto foi declarado neste campo |
| `enabled` | elegibilidade administrativa futura do nó |
| `created_epoch` | criação do registro |
| `updated_epoch` | última mudança de metadados |

`capacity`, `weight` e `max_sessions` ainda não fazem balanceamento sozinhos. Eles são o contrato persistente que o scheduler da Colmeia consumirá posteriormente.

## CLI

Mostrar o registro completo e capacidades detectadas:

```bash
manager --node
```

Mostrar somente o contexto que será usado por ACL/Colmeia:

```bash
manager --node-context
```

Exemplo:

```text
node=node-91a7c5c90ec42c4b
country=BR
region=BR-SP
pool=BRASIL-PREMIUM
```

Alterar campos allowlisted:

```bash
manager --node-set country BR
manager --node-set region BR-SP
manager --node-set pool BRASIL-PREMIUM
manager --node-set provider provider-01
manager --node-set city sao-paulo
manager --node-set capacity 8
manager --node-set weight 3
manager --node-set max_sessions 500
```

O país é normalizado para maiúsculas. Campos imutáveis, como `node_id`, são recusados.

## Capacidades detectadas

O módulo também consegue publicar uma visão local das capacidades:

```bash
/opt/manager/modules/node_metadata.sh --capabilities
```

A saída inclui os protocolos encontrados, disponibilidade IPv6, capacidade, peso, limite declarado e estado administrativo.

Protocolos são detectados a partir dos serviços/configurações realmente instalados. Essa informação descreve o nó; ela não concede acesso a clientes e não substitui Product Policy, ACL ou Session Engine.

## IPv4 e IPv6

`manager --node` mostra, quando disponíveis:

- interface IPv4 padrão;
- interface IPv6 padrão;
- endereço IPv4 global local;
- endereço IPv6 global local;
- endpoint configurado de WireGuard;
- endpoint configurado de OpenVPN;
- capacidade dual-stack detectada.

O módulo não altera rota, firewall, endereço público ou configuração de VPN. Ele somente descreve o estado.

## Segurança

- O `node_id` é gerado localmente usando fonte criptograficamente aleatória disponível no sistema.
- O arquivo é restrito a root (`0600`) e seu diretório usa `0700`.
- Campos mutáveis passam por validação e allowlist.
- Não existe campo para executar comando, shell ou payload arbitrário.
- Geografia não é inferida automaticamente nem consultada em serviço externo; o administrador declara `country`, `region`, `pool`, `provider` e `city`.
- O futuro enrollment da Colmeia utilizará identidade criptográfica própria; `node_id` continuará sendo o identificador lógico.

## Próximas integrações

Este contrato permite implementar sem reconstruir o modelo:

1. passagem automática de `region`, `pool` e `node` para a autorização dos produtos;
2. heartbeat do nó com CPU, RAM, banda, sessões, latência e saúde dos serviços;
3. estados `HEALTHY`, `DEGRADED`, `DRAINING`, `MAINTENANCE` e `OFFLINE`;
4. scheduler weighted least-loaded com capacidade e afinidade;
5. enrollment autenticado no Hub e rotação de credenciais;
6. leases globais de sessão entre nós.

Até essas etapas chegarem, o módulo é deliberadamente local e não anuncia que a Colmeia multi-VPS já está ativa.
