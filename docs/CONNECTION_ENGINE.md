# Connection Engine

O Connection Engine separa a **identidade MANAGER** do recurso técnico usado para conectar.

Antes da série 0.6, um usuário Linux, peer WireGuard e certificado OpenVPN eram tratados quase como contas independentes. Agora eles podem pertencer a uma única identidade lógica.

## Modelo

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

Estado persistente:

```text
/etc/manager/connection/identities/<id>.conf
```

Os arquivos são `0600` e acessíveis somente por root.

## Campos

- `id`: identificador estável;
- `owner`: revendedor/subrevendedor opcional;
- `enabled`: habilitação administrativa;
- `expires_epoch`: expiração global, `0` para sem expiração;
- `max_sessions`: limite simultâneo da identidade;
- `protocols`: protocolos permitidos;
- `ssh_user`: usuário Linux vinculado;
- `wireguard_client`: cliente/peer WireGuard vinculado;
- `openvpn_client`: cliente/certificado OpenVPN vinculado;
- `created_epoch` e `updated_epoch`.

Protocolos atuais:

```text
ssh
wireguard
openvpn
```

## Estado efetivo

```text
active
disabled
expired
```

A partir da 0.6.1 o estado é aplicado pelo `policy_engine.sh`. Na 0.6.2, leases incompatíveis também passam a ser revogadas/fenced pelo `session_engine.sh`. Na 0.6.3, conexões reais passam a consumir essas leases pelo `protocol_leases.sh`.

## Quatro camadas

```text
Connection Engine       quem é a identidade e quais recursos pertencem a ela
Policy Engine           aplica estado/expiração e observa daemons reais
Session Engine          autoridade local de vagas, TTL, heartbeat e fencing
Protocol Lease Bridge   converte conexões reais em acquire/heartbeat/release
```

Essa separação é a base para uma pessoa possuir vários endpoints sem ganhar uma sessão independente em cada um.

## Enforcement por protocolo

### SSH

O Policy Engine mantém:

```text
/etc/ssh/sshd_config.d/65-manager-identity-policy.conf
/etc/security/limits.d/98-manager-identity.conf
```

Identidades inativas entram em `DenyUsers`; alterações são validadas com `sshd -t` antes do reload.

A partir da 0.6.3, o Protocol Lease Bridge também usa um hook de sessão PAM. Uma conexão SSH gerenciada precisa obter uma lease durante `open_session`; `close_session` libera a reserva.

O wrapper externo foi projetado para não criar lockout se o código do MANAGER desaparecer durante rollback/recuperação.

### WireGuard

Desativar/expirar uma identidade não apaga credenciais do cliente. O Policy Engine pode retirar somente o peer do runtime.

O bridge considera handshake recente como atividade. Um peer gerenciado fica sem tráfego encaminhado até possuir lease válida; o bloqueio é específico ao IP do peer e nunca usa flush global do firewall. Se a regra específica não puder ser aplicada, somente o peer correspondente é removido do runtime.

### OpenVPN

O OpenVPN usa `client-connect`/`client-disconnect`, mas o processo não recebe acesso root ao Session Engine.

O hook não privilegiado coloca pedidos em uma fila runtime; um `systemd.path` chama um processador root que decide `ALLOW`/`DENY` usando o Session Engine.

Isso mantém a fronteira de privilégio:

```text
OpenVPN sem root
      ↓
fila validada
      ↓
serviço root allowlisted
      ↓
Session Engine
```

Sessões existentes durante upgrade também são observadas e adotadas pelo reconciliador. Uma sessão gerenciada que não consiga lease tem seu tráfego bloqueado especificamente, sem revogar o certificado.

## Sessões observadas x leases

Sessões observadas:

```bash
manager --identity-sessions
manager --identity-sessions maria
```

Exemplo:

```text
maria  active  ssh=0  wg=1  ovpn=0  total=1  max=1
```

Leases autorizadas:

```bash
manager --leases
manager --leases maria
```

As duas visões têm propósitos diferentes:

```text
observado = o daemon mostra uma conexão
lease     = o Connection/Session Engine autorizou ocupar uma vaga
```

Na 0.6.3 o bridge trabalha para manter as duas visões convergentes.

## Estado de lease

Leases temporárias:

```text
/run/manager-session-leases/active/
```

Mapeamento protocolo ↔ lease:

```text
/run/manager-protocol-leases/
```

Fencing persistente:

```text
/etc/manager/connection/session-epochs/<id>.epoch
```

Cada lease possui `session_id`, protocolo, recurso, dispositivo, `session_epoch`, heartbeat e TTL.

Aquisição normal respeita `max_sessions` sob lock local. Retry do mesmo dispositivo é idempotente. Troca/revogação avança `session_epoch`, impedindo uma sessão antiga de recuperar autoridade.

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

Protocol Lease Bridge:

```text
manager-protocol-leases.timer
manager-protocol-leases.service
manager-openvpn-lease-queue.path
manager-openvpn-lease-queue.service
```

Reconciliação manual:

```bash
/opt/manager/modules/policy_engine.sh --reconcile
/opt/manager/modules/session_engine.sh --reconcile
/opt/manager/modules/protocol_leases.sh --reconcile
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

## Contratos internos

Connection Engine:

```bash
/opt/manager/modules/connection_engine.sh --init
/opt/manager/modules/connection_engine.sh --create maria revenda01 0 1 ssh,wireguard,openvpn
/opt/manager/modules/connection_engine.sh --bind maria ssh maria
/opt/manager/modules/connection_engine.sh --bind maria wireguard maria
/opt/manager/modules/connection_engine.sh --bind maria openvpn maria
/opt/manager/modules/connection_engine.sh --disable maria
/opt/manager/modules/connection_engine.sh --enable maria
```

Session Engine:

```bash
/opt/manager/modules/session_engine.sh --acquire maria wireguard maria celular-maria 90
/opt/manager/modules/session_engine.sh --heartbeat <session_id> <epoch> 90
/opt/manager/modules/session_engine.sh --release <session_id> <epoch>
/opt/manager/modules/session_engine.sh --switch maria wireguard maria celular-maria 90
/opt/manager/modules/session_engine.sh --revoke-all maria admin
```

Protocol Bridge:

```bash
/opt/manager/modules/protocol_leases.sh --reconcile
```

Esses contratos existem para que Automation v2/`managerd` trabalhe com operações estruturadas e nunca precise receber shell remoto arbitrário.

## Compatibilidade com revenda

Quando um usuário SSH é vinculado a uma identidade com `owner`, o Connection Engine reutiliza o módulo de revendedores para validar e registrar propriedade.

A cota comercial ainda é fortemente baseada em contas SSH. Uma próxima etapa da série 0.6 deverá migrá-la para **produto/identidade**, porque uma identidade somente WireGuard/OpenVPN também precisa consumir cota corretamente.

## Próximas etapas 0.6.x

1. Registro comum de tráfego/estado por identidade e protocolo.
2. Políticas/ACL independentes do protocolo.
3. Provisionamento/revogação de SSH, WireGuard e OpenVPN pelo próprio Connection Engine.
4. Cotas de revenda baseadas em identidades/produtos.
5. IPv6 e metadados de nó/região necessários para Colmeia.

A etapa de ligar eventos reais de conexão às leases foi concluída na 0.6.3.

## Relação com Automation e Colmeia

Hoje:

```text
SSH / WireGuard / OpenVPN
            ↓
   Protocol Lease Bridge
            ↓
     Session Engine local
            ↓
    identidade MANAGER
```

Futuro:

```text
Telegram / Legacy / projeto novo
               ↓
        Automation Engine
               ↓
          Connection Engine
               ↓
     Protocol Lease Bridge no nó
               ↓
          Hive Hub global
               ↓
        lease + session_epoch
```

Na Colmeia, `max_sessions` deixa de ser uma decisão por VPS e passa a ser global para identidade/plano. Assim uma conta pode ter dez países disponíveis e continuar com apenas uma sessão simultânea se esse for o plano.
