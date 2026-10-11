# Session / Lease Engine

A série 0.6 separa quatro conceitos:

1. **identidade** — quem é a conta lógica (`Connection Engine`);
2. **sessão observada** — conexão que SSH/WireGuard/OpenVPN realmente apresentam;
3. **lease** — autorização temporária para ocupar uma vaga (`Session Engine`);
4. **Protocol Lease Bridge** — tradução de eventos reais dos protocolos em `acquire`, `heartbeat` e `release`.

A 0.6.2 criou a autoridade local de leases. A 0.6.3 liga essa autoridade às conexões reais.

## Objetivo

Uma identidade pode ter vários recursos técnicos e, futuramente, vários servidores disponíveis sem ganhar uma vaga independente em cada recurso.

```text
maria
├── max_sessions = 1
├── BR-01
├── US-01
└── DE-01
```

Maria pode ter direito aos três destinos, mas somente uma lease válida ocupa a vaga simultânea.

## Estado

Leases ativas ficam somente em runtime:

```text
/run/manager-session-leases/active/
```

O estado temporário usado para relacionar uma conexão real à lease fica em:

```text
/run/manager-protocol-leases/
```

Nenhum desses diretórios é backup durável. Reiniciar a VPS descarta reservas locais antigas.

O fencing token persistente fica em:

```text
/etc/manager/connection/session-epochs/<identity>.epoch
```

O epoch começa em `1` e não aumenta a cada aquisição normal. Identidades com `max_sessions > 1` podem ter várias leases legítimas na mesma geração.

Ele avança quando toda a geração anterior precisa perder autoridade, por exemplo:

- `--revoke-all`;
- `--switch`;
- mudança de política que invalida leases existentes.

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

`session_id` usa 128 bits do RNG do sistema e é representado em hexadecimal.

## TTL, heartbeat e idempotência

O Session Engine aceita TTL de `1` a `86400` segundos. O Protocol Lease Bridge usa leases curtas e renova conexões observadas periodicamente.

Uma repetição de `acquire` com a mesma combinação:

```text
identity + protocol + resource + device_id + session_epoch
```

renova a lease existente em vez de consumir outra vaga.

O timer do Session Engine remove leases vencidas. O timer do bridge mantém vivas somente as reservas que ainda correspondem a conexões reais.

## Protocol Lease Bridge — 0.6.3

Módulo:

```text
/opt/manager/modules/protocol_leases.sh
```

Heartbeat/reconciliação:

```text
manager-protocol-leases.timer
manager-protocol-leases.service
```

### SSH

O SSH usa um hook de sessão PAM gerenciado pelo MANAGER.

```text
/etc/pam.d/sshd
/usr/local/libexec/manager-ssh-lease-hook
```

No `open_session`, uma identidade SSH vinculada precisa conseguir uma lease. No `close_session`, a lease correspondente é liberada.

O wrapper é deliberadamente fail-safe para o próprio acesso administrativo: se o código do MANAGER não estiver presente ou o contexto privilegiado esperado não existir, o wrapper não transforma uma atualização/rollback incompleto em lockout global do SSH.

O reconciliador também observa `who`, permitindo adotar sessões que já estavam abertas antes de o bridge entrar em funcionamento. Se uma sessão gerenciada exceder a cota e não conseguir lease, somente o TTY correspondente é encerrado; `root` não é alvo dessa rotina.

### OpenVPN

O OpenVPN não recebe acesso root ao Session Engine.

A integração usa um hook não privilegiado que escreve um pedido validado em runtime:

```text
/usr/local/libexec/manager-openvpn-lease-hook
/run/manager-protocol-leases/openvpn-requests/
/run/manager-protocol-leases/openvpn-responses/
```

Um `systemd.path` acorda o processador root:

```text
manager-openvpn-lease-queue.path
manager-openvpn-lease-queue.service
```

Fluxo de admissão:

```text
client-connect
     ↓
hook sem root
     ↓
fila runtime
     ↓
processador root
     ↓
session_engine --acquire
     ↓
ALLOW / DENY
```

O hook também registra `client-disconnect` para liberar a reserva. Clientes que não pertencem a nenhuma identidade MANAGER continuam fora do controle de quota do Connection Engine.

Quando uma versão anterior do OpenVPN já está em uso, a mudança de hook pode ser adiada até não haver clientes ativos para evitar derrubar conexões apenas para instalar a integração. Enquanto isso, o reconciliador observa o status e pode adotar sessões existentes.

### WireGuard

WireGuard não possui evento de login equivalente ao PAM/OpenVPN. O bridge usa o handshake recente como sinal de atividade.

Para um peer gerenciado:

```text
handshake recente
      ↓
acquire/heartbeat
      ↓
lease válida
      ↓
tráfego liberado
```

Sem lease válida, o MANAGER aplica uma regra específica ao IP daquele peer no `FORWARD`. Não há flush global de firewall. Se a regra específica não puder ser aplicada, o fallback é retirar somente aquele peer do runtime do WireGuard.

Quando o peer deixa de apresentar handshake recente, sua lease é liberada.

## Fencing

Exemplo:

```text
epoch 7
session A -> epoch 7
```

Ao executar `--switch`, o MANAGER:

1. avança o epoch;
2. revoga as leases antigas;
3. cria a nova lease na geração nova.

Um processo atrasado com `session A + epoch 7` não consegue renovar autoridade depois que a identidade já está no epoch `8`.

## Reconciliação de política

Se uma identidade com lease ativa:

- for desabilitada;
- expirar;
- perder o protocolo;
- trocar/perder o recurso vinculado;

as leases incompatíveis são revogadas e a geração anterior é cercada por fencing.

Isso impede que uma sessão antiga volte a valer apenas porque a conta foi reativada depois.

## Operações internas

```bash
/opt/manager/modules/session_engine.sh --init
/opt/manager/modules/session_engine.sh --list [ID]
/opt/manager/modules/session_engine.sh --acquire ID PROTOCOLO RECURSO DEVICE TTL
/opt/manager/modules/session_engine.sh --heartbeat SESSION_ID EPOCH TTL
/opt/manager/modules/session_engine.sh --release SESSION_ID EPOCH
/opt/manager/modules/session_engine.sh --revoke-all ID MOTIVO
/opt/manager/modules/session_engine.sh --switch ID PROTOCOLO RECURSO DEVICE TTL
/opt/manager/modules/session_engine.sh --epoch ID
/opt/manager/modules/session_engine.sh --reconcile
```

Bridge:

```bash
/opt/manager/modules/protocol_leases.sh --reconcile
```

Os comandos `--observe-connect`/`--observe-disconnect` do bridge existem como contrato interno/testável; integrações externas futuras não devem receber shell arbitrário.

## CLI pública

```bash
manager --leases
manager --leases maria
```

Para comparar a autoridade com o que os daemons observam:

```bash
manager --identity-sessions maria
manager --leases maria
```

A primeira saída mostra conexões observadas. A segunda mostra vagas autorizadas.

## Eventos

Eventos de lease são registrados em:

```text
/var/log/manager/session-events.log
```

Tipos atuais:

```text
ACQUIRE
RENEW
HEARTBEAT
RELEASE
EXPIRE
REVOKE
FENCE
```

O log registra metadados operacionais, nunca senha, chave privada ou certificado.

## Códigos de erro

```text
64  argumento/política inválida
66  identidade/recurso/lease inexistente
67  protocolo/recurso não autorizado
68  identidade desabilitada ou expirada
69  max_sessions atingido
70  fencing token/session_epoch rejeitado
```

## Lifecycle seguro

O instalador aplica os componentes nesta ordem:

```text
Connection Engine
Session Engine
Policy Engine
Protocol Lease Bridge
```

No uninstall, o bridge é desmontado antes do Session Engine para liberar leases e retirar hooks externos ao `/opt/manager`.

O rollback desmonta bridge/política antes da troca de código e reaplica somente os componentes existentes na versão restaurada. Assim voltar para uma versão anterior que não conheça o bridge não deixa PAM/OpenVPN apontando para scripts ausentes.

## Caminho para a Colmeia

Na 0.6.3 a autoridade ainda está na VPS local:

```text
SSH / WireGuard / OpenVPN
            ↓
 Protocol Lease Bridge
            ↓
     Session Engine local
```

Na Colmeia, o contrato conceitual permanece, mas a decisão de `acquire` será global:

```text
protocolo no nó
      ↓
Protocol Lease Bridge
      ↓
Hive Hub / lock atômico
      ↓
lease + session_epoch
      ↓
nó libera a sessão
```

Assim a identidade poderá ter acesso a dez países e continuar com `max_sessions_global=1`, sem uma vaga independente em cada VPS.
