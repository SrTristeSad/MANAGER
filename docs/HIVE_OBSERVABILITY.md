# Observabilidade distribuída da Colmeia

A série 0.8.10 adiciona observabilidade ao control plane existente sem colocar o controlador no caminho de dados VPN e sem criar uma segunda autoridade de decisão.

## Fundação

A primeira fatia usa três fontes já existentes:

- heartbeat/health: passa a manter histórico sanitizado de saúde e capacidade por nó;
- scheduler: reutiliza o audit JSONL de placement, seleção, drain e failover;
- leases: reutiliza o audit JSONL da autoridade global de sessões.

O módulo `hive_observability.sh` é somente leitura para scheduler/leases. Ele não altera placement, lease, sessão, chave ou política. A única escrita funcional é o histórico sanitizado de health.

## Dados de health preservados

Cada heartbeat aceito pode gerar um registro `manager-hive-health-history-v1` contendo somente:

- `node_id` e `node_epoch`;
- estado e motivo de saúde;
- sessões, capacidade, peso e limite local;
- CPU e memória em percentual;
- RTT da malha e quantidade de peers;
- timestamp recebido pelo controlador.

Não são persistidos nesse histórico endereço de origem, chave, assinatura, nonce, credencial, perfil VPN, token ou segredo de usuário.

## Retenção e rotação dos audits

O histórico de health usa retenção temporal. O padrão inicial é 7 dias e pode ser ajustado por `MANAGER_HIVE_OBSERVABILITY_RETENTION_SECONDS`, limitado a 90 dias nesta fase.

Scheduler e autoridade de leases continuam sendo os escritores dos próprios audits. A observabilidade agora coordena apenas a **rotação operacional** desses dois JSONL:

- o arquivo ativo é movido por `rename` atômico para um segmento root-only;
- a rotação nunca trunca o audit em lugar;
- um writer que já abriu o descritor antigo termina de escrever no segmento renomeado;
- writers seguintes continuam no arquivo ativo recriado;
- segmentos não são comprimidos nesta fase, evitando corrida entre compressão e writer ainda aberto;
- consultas `scheduler`, `leases` e `summary` leem segmentos arquivados + arquivo ativo como uma única linha do tempo;
- retenção remove somente segmentos arquivados fora da janela, nunca o arquivo ativo.

O padrão de retenção dos audits é 14 dias (`MANAGER_HIVE_OBSERVABILITY_AUDIT_RETENTION_SECONDS`) e o limiar padrão de rotação é 4 MiB (`MANAGER_HIVE_OBSERVABILITY_AUDIT_MAX_BYTES`). A janela continua limitada a 90 dias e o limiar a 512 MiB.

## Comandos

```bash
manager hive observe status
manager hive observe summary [WINDOW_SECONDS]
manager hive observe metrics [WINDOW_SECONDS]
manager hive observe series [NODE_ID|*] [WINDOW_SECONDS] [BUCKET_SECONDS]
manager hive observe export [WINDOW_SECONDS] [LIMIT]
manager hive observe health [NODE_ID|*] [LIMIT]
manager hive observe scheduler [LIMIT]
manager hive observe leases [IDENTITY_ID|*] [LIMIT]
manager hive observe prune [RETENTION_SECONDS]
manager hive observe audit-status
manager hive observe audit-maintain [RETENTION_SECONDS] [MAX_BYTES] [force]
```

`summary` agrega, dentro da janela solicitada:

- quantidade de nós observados e estado mais recente;
- média e p95 de RTT;
- seleções do scheduler e failovers sticky;
- drain/undrain;
- grants, denies e releases globais;
- outage, recovery e fencing da autoridade.

## Séries temporais e métricas operacionais

`manager hive observe metrics [WINDOW_SECONDS]` agrega toda a janela observada, sem o limite de tail usado pelas consultas humanas. O contrato `manager-hive-observability-metrics-v1` inclui CPU/RAM/RTT, load normalizado por CPU, sessões e pico, utilização do limite local, deltas/rates observados de RX/TX, amostras com serviço degradado, saúde mais recente dos nós e taxas de failover/deny do control plane.

`manager hive observe series [NODE_ID|*] [WINDOW_SECONDS] [BUCKET_SECONDS]` produz o contrato `manager-hive-observability-series-v1`. Cada bucket contém média/p95/máximo de CPU, RAM, RTT, load por CPU, sessões e utilização, além de estados de health e deltas observados de rede. O padrão é janela de 1 hora com buckets de 5 minutos; buckets aceitam 60 segundos a 24 horas e a saída é limitada a 1.000 buckets.

Os contadores de rede continuam vindo do heartbeat assinado. O primeiro ponto observado de cada nó é baseline; redução de contador ou mudança de `node_epoch` também cria nova baseline, portanto reset/reboot nunca vira delta negativo ou tráfego artificial. Registros antigos de health que não possuem as métricas novas continuam legíveis.

O histórico passa a preservar apenas os campos operacionais adicionais necessários: load, `cpu_count`, contadores RX/TX, número de identidades em sessão, protocolos e estados allowlisted de serviço. Interface de rede, endereço de origem, assinatura, nonce, token, chave e credencial continuam excluídos.

## Export estruturado

`manager hive observe export [WINDOW_SECONDS] [LIMIT]` produz um único objeto JSON canônico com contrato `manager-hive-observability-export-v1`. Ele foi desenhado para consumidores externos controlados, como Automation v2, Bot/Mini App ou ferramentas administrativas.

O envelope contém `summary` e três streams limitados (`health`, `scheduler`, `leases`). Scheduler e leases continuam passando pelas mesmas allowlists das consultas locais; o export adiciona limite de 160 caracteres por string e aceita no máximo 100 registros por stream. Não são exportados caminhos internos, audit bruto, chave privada, assinatura, nonce, token, senha ou credencial VPN.

O comando continua exigindo root no host. Esta fatia não abre porta HTTP, socket público ou novo listener: autorização remota permanece responsabilidade do canal de automação autenticado.

## Isolamento de falhas

Observabilidade é diagnóstica. Se a gravação do histórico falhar, o heartbeat aceito continua válido. O módulo não pode transformar falha de disco de observabilidade em indisponibilidade da Colmeia.

## Segurança

- arquivos novos são root-only (`0600`) em diretório `0700`;
- consultas possuem limites máximos para evitar leitura ilimitada pela CLI;
- saídas de scheduler e leases usam allowlist de campos;
- campos desconhecidos nos audits não são ecoados automaticamente;
- chaves privadas nunca entram no histórico;
- o controlador continua fora do caminho de dados VPN.

## Escopo desta fatia

A quarta fatia adiciona séries temporais e métricas operacionais derivadas das mesmas fontes autenticadas e sanitizadas. A 0.8.10 ainda não está fechada: permanece o gate final multi-nó com regressão completa e o bump formal da release.
