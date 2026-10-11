# Connection Engine

O Connection Engine é a camada que separa a **identidade MANAGER** do recurso técnico usado para conectar.

Antes da 0.6, a identidade prática era quase sempre um usuário Linux, um peer WireGuard ou um certificado OpenVPN isolado. A partir da 0.6, esses recursos podem pertencer a uma única identidade lógica.

## Modelo

Exemplo conceitual:

```text
maria
├── owner = revenda01
├── enabled = 1
├── expires_epoch = 0
├── max_sessions = 1
├── protocols = ssh,wireguard,openvpn
├── ssh_user = maria
├── wireguard_client = maria
└── openvpn_client = maria
```

O estado fica em:

```text
/etc/manager/connection/identities/<id>.conf
```

Arquivos de identidade são `0600` e o diretório é acessível somente por root.

## Campos

- `id`: identificador estável da identidade;
- `owner`: revendedor/subrevendedor opcional;
- `enabled`: política administrativa da identidade;
- `expires_epoch`: expiração global da identidade, `0` para sem expiração;
- `max_sessions`: limite simultâneo local da identidade e, futuramente, limite global do plano na Colmeia;
- `protocols`: protocolos autorizados pela política;
- `ssh_user`: usuário Linux vinculado;
- `wireguard_client`: peer/config WireGuard vinculado;
- `openvpn_client`: cliente/certificado OpenVPN vinculado;
- `created_epoch` e `updated_epoch`.

Protocolos reconhecidos:

```text
ssh
wireguard
openvpn
```

## Estado efetivo

A identidade pode aparecer como:

- `active`: habilitada e dentro da validade;
- `disabled`: desabilitada administrativamente;
- `expired`: validade global encerrada.

A partir da 0.6.1 esse estado é aplicado pelo `policy_engine.sh`. A partir da 0.6.2 mudanças que tornam uma lease incompatível também invalidam a geração de sessão pelo `session_engine.sh`.

## Três camadas distintas

Na série 0.6 o MANAGER separa:

```text
Connection Engine  -> quem é a identidade e o que ela pode usar
Policy Engine      -> o que está realmente conectado/permitido no protocolo
Session Engine     -> quem possui uma vaga de sessão reservada
```

Essa separação é importante para a Colmeia: uma pessoa pode possuir vários endpoints disponíveis sem possuir uma sessão simultânea independente em cada VPS.

Documentação do Lease Engine:

```text
docs/SESSION_ENGINE.md
```

## Enforcement local

### SSH

O MANAGER gera somente o drop-in:

```text
/etc/ssh/sshd_config.d/65-manager-identity-policy.conf
```

Identidades inativas são adicionadas a `DenyUsers`, bloqueando autenticação por senha e chave sem substituir o `sshd_config` principal. A configuração é validada com `sshd -t` antes do reload.

O limite de logins calculado pelo Connection Engine fica separado em:

```text
/etc/security/limits.d/98-manager-identity.conf
```

O valor disponível para SSH desconta sessões observadas nos outros protocolos da identidade.

### WireGuard

Desativar/expirar uma identidade não apaga chaves nem configuração do cliente. O peer é removido somente do runtime da interface `wg0`. Quando a identidade volta a ficar elegível, o peer é reconstruído no runtime usando o estado já existente.

Uma sessão WireGuard é considerada ativa quando o peer teve handshake recente. Nesta etapa local, cada peer vinculado representa no máximo uma sessão observada.

### OpenVPN

O servidor MANAGER recebe um `client-connect` gerenciado que consulta a política antes de aceitar um cliente vinculado. Clientes que não pertencem a nenhuma identidade continuam sendo tratados como recursos não gerenciados pelo Connection Engine.

Quando uma identidade OpenVPN é desativada enquanto está conectada, o MANAGER aplica bloqueio de tráfego específico ao IP virtual observado. O certificado não é revogado, permitindo reativação posterior sem gerar credenciais novas.

Se o hook ainda precisa ser ativado mas existem clientes conectados, o MANAGER adia o restart do OpenVPN e tenta novamente quando não houver clientes, evitando interromper sessões válidas apenas para instalar o hook.

## Sessões observadas

Consulta geral:

```bash
manager --identity-sessions
```

Uma identidade específica:

```bash
manager --identity-sessions maria
```

A saída reúne:

```text
SSH + WireGuard + OpenVPN = total observado
```

junto ao `max_sessions` da identidade.

Isso descreve o que os daemons estão vendo; não é o mesmo que uma lease autorizada.

## Leases locais — 0.6.2

Consulta geral:

```bash
manager --leases
```

Uma identidade:

```bash
manager --leases maria
```

Leases ativas ficam somente em runtime:

```text
/run/manager-session-leases/active/
```

O fencing token persistente fica em:

```text
/etc/manager/connection/session-epochs/<id>.epoch
```

Cada lease possui `session_id`, protocolo, recurso, dispositivo, `session_epoch`, heartbeat e TTL.

Aquisição normal respeita `max_sessions` sob lock local. Repetir o mesmo pedido para o mesmo dispositivo na mesma geração é idempotente e renova a lease existente em vez de consumir outra vaga.

Operações de troca/revogação avançam o `session_epoch`, impedindo uma lease antiga de recuperar autoridade depois de uma mudança.

Mudanças de política também reconciliam leases. Se a identidade for desabilitada/expirar, perder o protocolo ou trocar o recurso vinculado, as leases incompatíveis são revogadas e a geração anterior é cercada por fencing.

## Como `max_sessions` funciona hoje

Existem duas proteções complementares:

1. o Policy Engine continua aplicando limites conservadores nos protocolos reais;
2. o Session Engine aplica a cota de leases atomicamente dentro da VPS.

Ainda existe compatibilidade com caminhos antigos que não exigem lease obrigatoriamente. Isso evita quebrar clientes existentes durante a migração.

A garantia definitiva para várias VPS será o **lease atômico da Colmeia**, onde o hub será a autoridade da reserva global.

## Reconciliação

Policy Engine:

```text
manager-policy-reconcile.path
manager-policy-reconcile.timer
manager-policy-reconcile.service
```

Session Engine:

```text
manager-session-reconcile.path
manager-session-cleanup.timer
manager-session-cleanup.service
```

Os watchers reagem ao marcador de mudança da identidade. Os timers cobrem expiração, heartbeat e mudanças de estado que não dependem apenas de eventos de arquivo.

Reconciliação manual:

```bash
/opt/manager/modules/policy_engine.sh --reconcile
/opt/manager/modules/session_engine.sh --reconcile
```

## CLI pública

```bash
manager --identities
manager --identity maria
manager --identity-sessions
manager --identity-sessions maria
manager --leases
manager --leases maria
```

## Contratos internos do Connection Engine

Inicializar:

```bash
/opt/manager/modules/connection_engine.sh --init
```

Criar identidade:

```bash
/opt/manager/modules/connection_engine.sh \
  --create maria revenda01 0 1 ssh,wireguard,openvpn
```

Vincular um recurso existente:

```bash
/opt/manager/modules/connection_engine.sh --bind maria ssh maria
/opt/manager/modules/connection_engine.sh --bind maria wireguard maria
/opt/manager/modules/connection_engine.sh --bind maria openvpn maria
```

Importar automaticamente recursos existentes com o mesmo nome:

```bash
/opt/manager/modules/connection_engine.sh --import-name maria revenda01 0 1
```

Ativar/desativar:

```bash
/opt/manager/modules/connection_engine.sh --disable maria
/opt/manager/modules/connection_engine.sh --enable maria
```

Autorização interna de um recurso:

```bash
/opt/manager/modules/policy_engine.sh --authorize openvpn maria
```

## Contratos internos do Session Engine

Reservar uma vaga:

```bash
/opt/manager/modules/session_engine.sh \
  --acquire maria wireguard maria celular-maria 90
```

Heartbeat:

```bash
/opt/manager/modules/session_engine.sh \
  --heartbeat <session_id> <epoch> 90
```

Liberar:

```bash
/opt/manager/modules/session_engine.sh \
  --release <session_id> <epoch>
```

Trocar e invalidar a geração anterior:

```bash
/opt/manager/modules/session_engine.sh \
  --switch maria wireguard maria celular-maria 90
```

Revogar todas as leases:

```bash
/opt/manager/modules/session_engine.sh --revoke-all maria admin
```

Esses contratos são estruturados para que Automation v2/`managerd` não precise manipular arquivos diretamente nem receber shell arbitrário.

## Compatibilidade com revenda

Quando um usuário SSH é vinculado a uma identidade que possui `owner`, o Connection Engine reutiliza o módulo de revendedores para validar e registrar a propriedade desse usuário.

A estrutura de cotas da série 0.5/0.6 ainda conta principalmente usuários SSH. Isso será migrado para um modelo de produto/identidade antes da Colmeia, porque uma identidade WireGuard-only ou OpenVPN-only também precisará consumir cota corretamente.

## Próximas etapas 0.6.x

1. Ligar eventos reais de conexão ao acquire/heartbeat/release de leases de forma compatível com clientes existentes.
2. Registro comum de tráfego/estado.
3. Políticas/ACL independentes do protocolo.
4. Provisionamento e revogação de SSH/WireGuard/OpenVPN pelo próprio Connection Engine.
5. Cotas de revenda baseadas em identidades/produtos, não apenas usuários Linux.
6. IPv6 e metadados necessários para Colmeia.

Depois disso a Automation v2 poderá consumir a mesma superfície estruturada e a Colmeia poderá mover a autoridade de lease da VPS local para o hub.

## Relação com Automation e Colmeia

O objetivo é:

```text
Telegram / projeto antigo / projeto novo
                 ↓
           Automation Engine
                 ↓
          Connection Engine
                 ↓
          Session Engine
                 ↓
      identidade MANAGER (Maria)
        ┌────────┼─────────┐
        ↓        ↓         ↓
       SSH   WireGuard   OpenVPN
```

Na Colmeia, `max_sessions` passará a ser global para a identidade/plano. Assim, ter acesso a vários servidores não significará ganhar uma sessão simultânea independente em cada VPS.
