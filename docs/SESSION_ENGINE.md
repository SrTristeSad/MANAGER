# Session / Lease Engine

A série 0.6 separa três conceitos que antes ficavam misturados:

1. **identidade** — quem é a conta lógica (`Connection Engine`);
2. **sessão observada** — uma conexão que o sistema consegue enxergar em SSH/WireGuard/OpenVPN (`Policy Engine`);
3. **lease** — autorização temporária para ocupar uma vaga da identidade (`Session Engine`).

A 0.6.2 introduz o terceiro conceito como fundação local para a futura Colmeia.

## Objetivo

Uma identidade pode ter vários recursos técnicos e, no futuro, vários servidores disponíveis. Isso não deve multiplicar automaticamente seu limite de sessões.

Exemplo:

```text
maria
├── max_sessions = 1
├── BR-01
├── US-01
└── DE-01
```

Maria pode ter direito aos três destinos, mas uma lease válida representa a vaga efetivamente ocupada.

## Estado

### Leases ativas

Ficam somente em runtime:

```text
/run/manager/session-leases/active/
```

Cada lease é um arquivo `0600` contendo somente metadados de sessão, nunca senha, chave privada ou certificado.

`/run` não é usado como estado durável. Reiniciar a VPS descarta as leases locais, evitando ressuscitar sessões antigas a partir de backup ou disco.

### Session epoch

O fencing token persistente fica em:

```text
/etc/manager/connection/session-epochs/<identity>.epoch
```

O epoch começa em `1`.

Ele **não aumenta em cada aquisição normal**, porque identidades com `max_sessions > 1` podem possuir várias leases legítimas na mesma geração.

O epoch aumenta quando é necessário invalidar a geração anterior inteira, por exemplo:

- `--revoke-all`;
- `--switch`.

Depois disso, uma operação com token antigo não pode renovar uma lease da geração nova.

## Campos de uma lease

```text
session_id
identity_id
protocol
resource
device_id
session_epoch
created_epoch
heartbeat_epoch
expires_epoch
```

`session_id` é gerado a partir de 128 bits do RNG do sistema e codificado em hexadecimal.

## TTL e heartbeat

TTL padrão:

```text
90 segundos
```

Faixa aceita:

```text
1 a 86400 segundos
```

Uma lease precisa receber heartbeat antes de `expires_epoch`. O timer:

```text
manager-session-cleanup.timer
```

faz limpeza periódica, e as próprias operações do Session Engine também removem leases vencidas antes de calcular cotas.

O TTL curto é deliberado: uma aplicação que morrer sem executar `release` não deve manter uma vaga presa indefinidamente.

## Idempotência local de aquisição

Uma repetição de `acquire` com a mesma combinação:

```text
identity + protocol + resource + device_id + session_epoch
```

não consome uma segunda vaga.

O MANAGER encontra a lease já existente, renova seu prazo e devolve o mesmo `session_id`.

Isso protege contra retries simples de clientes e prepara o contrato para Automation v2.

## Fencing

Exemplo:

```text
epoch 7
session A -> epoch 7
```

Ao executar uma troca:

```text
--switch
```

o MANAGER:

1. avança o epoch para `8`;
2. revoga as leases antigas da identidade;
3. cria a nova lease já com epoch `8`.

Um processo atrasado que ainda tenha:

```text
session A + epoch 7
```

não consegue renovar a autoridade antiga.

Esse é o mecanismo local que depois será transportado para a Colmeia. No modo multi-VPS, o hub será a autoridade responsável por emitir a geração e garantir atomicidade global.

## Operações internas

Inicializar:

```bash
/opt/manager/modules/session_engine.sh --init
```

Listar leases:

```bash
/opt/manager/modules/session_engine.sh --list
/opt/manager/modules/session_engine.sh --list maria
```

Aquisição normal:

```bash
/opt/manager/modules/session_engine.sh \
  --acquire maria wireguard maria celular-maria 90
```

Retorno:

```text
session_id=<hex-128-bit>  epoch=<n>  expires_epoch=<unix>
```

Heartbeat:

```bash
/opt/manager/modules/session_engine.sh \
  --heartbeat <session_id> <epoch> 90
```

Release:

```bash
/opt/manager/modules/session_engine.sh \
  --release <session_id> <epoch>
```

Revogar toda a geração atual:

```bash
/opt/manager/modules/session_engine.sh --revoke-all maria admin
```

Troca atômica local para uma nova sessão:

```bash
/opt/manager/modules/session_engine.sh \
  --switch maria wireguard maria celular-maria 90
```

Consultar epoch atual:

```bash
/opt/manager/modules/session_engine.sh --epoch maria
```

## CLI pública

```bash
manager --leases
manager --leases maria
```

O menu principal também possui `Session / Lease Engine` para consulta, limpeza e revogação administrativa.

## Eventos

Eventos locais são registrados em:

```text
/var/log/manager/session-events.log
```

Tipos iniciais:

```text
ACQUIRE
RENEW
HEARTBEAT
RELEASE
EXPIRE
REVOKE
FENCE
```

O log registra IDs e metadados operacionais, não segredos de autenticação.

## Códigos de erro usados pelo contrato

Os contratos não interativos usam códigos distintos para permitir que Automation v2 diferencie falhas:

```text
64  argumento/política inválida
66  identidade/recurso/lease inexistente
67  protocolo/recurso não autorizado
68  identidade desabilitada ou expirada
69  max_sessions atingido
70  fencing token/session_epoch rejeitado
```

## Limite da 0.6.2

Nesta versão, o Lease Engine é a **autoridade local de reservas**, mas os três protocolos legados ainda não dependem obrigatoriamente de uma lease para toda conexão.

Isso é intencional para não quebrar usuários existentes durante a migração.

A integração seguinte ligará eventos reais de conexão aos contratos de lease de forma incremental. A Colmeia substituirá a autoridade local por uma autoridade distribuída/hub sem mudar a ideia de `session_id`, TTL, heartbeat e fencing.

## Caminho para a Colmeia

A interface futura será conceitualmente:

```text
Cliente / Telegram / Automation
            ↓
       session.acquire
            ↓
         Hive Hub
      (lock atômico)
            ↓
    lease + session_epoch
            ↓
       nó MANAGER
            ↓
 SSH / WireGuard / OpenVPN
```

A diferença principal entre 0.6.2 e Colmeia é **onde vive a autoridade**. O contrato de sessão já nasce com os elementos necessários para essa migração.
