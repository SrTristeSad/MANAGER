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

## Retenção

O histórico de health usa retenção temporal. O padrão inicial é 7 dias e pode ser ajustado por `MANAGER_HIVE_OBSERVABILITY_RETENTION_SECONDS`, limitado a 90 dias nesta fase.

O scheduler e a autoridade de leases continuam donos dos próprios audits. A observabilidade apenas sanitiza e consulta esses arquivos; não os copia.

## Comandos

```bash
manager hive observe status
manager hive observe summary [WINDOW_SECONDS]
manager hive observe health [NODE_ID|*] [LIMIT]
manager hive observe scheduler [LIMIT]
manager hive observe leases [IDENTITY_ID|*] [LIMIT]
manager hive observe prune [RETENTION_SECONDS]
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

Esta fundação não fecha a 0.8.10 inteira. Ainda ficam para as próximas fatias: retenção/rotação coordenada dos audits existentes, export estruturado para integração externa, métricas temporais mais completas e gate final multi-nó da release.
