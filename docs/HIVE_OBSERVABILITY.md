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

A segunda fatia fecha a retenção/rotação coordenada dos audits de scheduler e leases sem mudar quem escreve ou decide no control plane. A 0.8.10 ainda não está fechada: permanecem export estruturado para integração externa, séries temporais/métricas adicionais e o gate final multi-nó da release.
