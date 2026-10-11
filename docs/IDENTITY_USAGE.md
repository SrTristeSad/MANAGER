# Identity Usage Accounting

A partir da 0.6.4, o MANAGER possui uma camada comum de **uso e atividade por identidade**.

Ela complementa as três camadas já existentes:

```text
Connection Engine  -> quem é a identidade
Policy Engine      -> o que está permitido/observado
Session Engine     -> quem possui uma vaga de sessão
Protocol Bridge    -> liga sessões reais às leases
Identity Usage     -> consolida tráfego e última atividade
```

## Objetivo

Uma identidade pode usar SSH, WireGuard e OpenVPN sem que cada protocolo mantenha uma visão isolada de consumo.

Exemplo conceitual:

```text
maria
├── sessões: 1/1
├── protocolo ativo: wireguard
├── download medido: 18.4 GiB
├── upload medido: 3.2 GiB
├── total medido: 21.6 GiB
├── última atividade: 2026-10-10 21:10:00
└── último recurso: maria
```

Esse estado será reutilizado posteriormente por planos, franquias, relatórios de revenda, Automation v2 e Colmeia.

## O que é medido na 0.6.4

### WireGuard

O MANAGER lê os contadores nativos de transferência do peer em `wg0`.

Do ponto de vista da identidade:

- bytes recebidos pelo servidor a partir do peer = **upload do usuário**;
- bytes enviados pelo servidor para o peer = **download do usuário**.

O módulo armazena somente o delta entre observações consecutivas.

### OpenVPN

O MANAGER lê os campos `Bytes Received` e `Bytes Sent` do status do servidor OpenVPN, aceitando o formato legado e o formato `CLIENT_LIST` moderno.

A mesma convenção é usada:

- `Bytes Received` pelo servidor = upload da identidade;
- `Bytes Sent` pelo servidor = download da identidade.

Conexões simultâneas com o mesmo Common Name são acompanhadas por fontes separadas enquanto estiverem ativas.

### SSH

Na 0.6.4, SSH participa de:

- sessão ativa;
- `max_sessions`;
- heartbeat;
- última atividade;
- último protocolo/recurso.

Porém, **bytes SSH não são contabilizados**.

O MANAGER não usa tráfego genérico do UID como substituto, porque isso poderia contar processos que não pertencem à sessão SSH e produzir números incorretos.

Por esse motivo, uma identidade com SSH vinculado apresenta:

```text
traffic_complete=0
ssh_bytes_supported=0
```

Essa distinção impede que relatórios futuros tratem um total parcial como se fosse consumo completo.

## Persistência

Totais consolidados:

```text
/var/lib/manager/identity-usage/identities/<id>.state
```

Snapshots de contadores de protocolo:

```text
/var/lib/manager/identity-usage/sources/
```

Permissões do estado são restritas a root.

Os snapshots existem somente para calcular deltas e não são considerados histórico de negócio.

## Baseline inicial

Ao observar uma fonte pela primeira vez, o MANAGER registra o valor atual como **baseline** e não o adiciona retroativamente ao consumo.

Exemplo:

```text
primeira leitura WireGuard:
received=10 GB
sent=20 GB
```

O acumulado continua em zero nessa primeira leitura.

Na leitura seguinte:

```text
received=10.5 GB
sent=21 GB
```

Somente a diferença é registrada:

```text
upload += 0.5 GB
download += 1 GB
```

Isso evita que a instalação da 0.6.4 transforme tráfego antigo do peer em consumo novo da identidade.

## Reset de contador do protocolo

Interfaces, peers e daemons podem reiniciar e voltar seus contadores absolutos para zero.

Se o valor atual for menor que o snapshot anterior, o MANAGER trata o valor atual como um novo delta a partir do reset.

Os acumulados da identidade não são zerados por restart de WireGuard/OpenVPN, reboot ou update do código.

## Campos persistidos

Cada identidade mantém:

```text
version
id
download_bytes
upload_bytes
wireguard_download_bytes
wireguard_upload_bytes
openvpn_download_bytes
openvpn_upload_bytes
last_activity_epoch
last_protocol
last_resource
tracking_started_epoch
updated_epoch
```

Não são armazenadas senhas, chaves privadas, certificados ou conteúdo do tráfego.

## CLI

Resumo de todas as identidades:

```bash
manager --usage
```

Detalhes em formato estável `key=value`:

```bash
manager --usage maria
```

Exemplo:

```text
id=maria
state=active
sessions=1
max_sessions=1
active_protocols=wireguard
download_bytes=19756849561
upload_bytes=3435973836
total_bytes=23192823397
traffic_complete=1
metered_protocols=wireguard,openvpn
ssh_bytes_supported=0
last_activity_epoch=1791681000
last_protocol=wireguard
last_resource=maria
```

O menu principal também possui:

```text
Uso e atividade por identidade
```

A mesma tela pode ser aberta a partir de `Tráfego e conexões`.

## Coleta automática

Unidades:

```text
manager-identity-usage.service
manager-identity-usage.timer
```

O timer executa coleta periódica a cada 30 segundos.

Coleta manual:

```bash
/opt/manager/modules/identity_usage.sh --collect
```

## Contrato interno de contador

Adaptadores locais confiáveis podem entregar um contador absoluto ao motor:

```bash
/opt/manager/modules/identity_usage.sh \
  --ingest-counter <identity> <protocol> <resource> <source> <received> <sent>
```

O contrato:

- aceita somente `wireguard` ou `openvpn` nesta versão;
- exige identidade existente;
- exige protocolo permitido;
- exige que o recurso pertença à identidade;
- aceita somente contadores inteiros não negativos;
- usa a primeira observação como baseline;
- transforma as observações seguintes em deltas.

Esse contrato permite trocar o coletor local por adaptadores futuros sem manipular diretamente os arquivos consolidados.

## Backup, rollback e uninstall

O backup principal inclui somente:

```text
/var/lib/manager/identity-usage/identities/
```

Os snapshots de origem não são transportados para outra VPS. Depois de uma restauração, o nó cria baselines novos para seus contadores locais.

`manager-uninstall` sem `--purge`:

- remove as unidades do coletor;
- preserva o histórico consolidado.

`manager-uninstall --purge`:

- remove também `/var/lib/manager/identity-usage`.

Rollback preserva o histórico e somente reativa o coletor se a versão restaurada possuir o módulo.

## Limite desta etapa

A 0.6.4 é uma camada de **accounting local**, não um sistema de cobrança e não uma franquia global multi-VPS.

Ainda faltam, entre outros pontos:

- períodos de faturamento/franquia;
- cotas de bytes e ações ao atingir a cota;
- agregação de vários nós da Colmeia;
- bytes SSH com uma fonte de medição confiável;
- relatórios históricos por dia/mês/produto;
- consolidação central no Hub.

A próxima evolução pode adicionar políticas/ACL e produto/plano sobre essa base sem misturar novamente identidade, sessão e contador de protocolo.
