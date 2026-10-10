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

A partir da 0.6.1 esse estado deixa de ser somente informativo e passa a ser aplicado pelo `policy_engine.sh`.

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

Uma sessão WireGuard é considerada ativa quando o peer teve handshake recente. Nesta etapa local, o Connection Engine trata cada peer vinculado como no máximo uma sessão observada.

### OpenVPN

O servidor MANAGER recebe um `client-connect` gerenciado que consulta a política antes de aceitar um cliente vinculado. Clientes que não pertencem a nenhuma identidade continuam sendo tratados como recursos não gerenciados pelo Connection Engine.

Quando uma identidade OpenVPN é desativada enquanto está conectada, o MANAGER aplica bloqueio de tráfego específico ao IP virtual observado. O certificado não é revogado, permitindo reativação posterior sem gerar credenciais novas.

Se o hook ainda precisa ser ativado mas existem clientes conectados, o MANAGER adia o restart do OpenVPN e tenta novamente quando não houver clientes, evitando interromper sessões válidas apenas para instalar o hook.

## Sessões consolidadas

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

## Como `max_sessions` funciona na 0.6.1

A aplicação local é conservadora:

- SSH recebe um `maxlogins` calculado conforme as vagas restantes;
- OpenVPN recusa nova conexão vinculada quando o total local já atingiu o limite;
- WireGuard não é restaurado para iniciar uma nova sessão quando outras sessões já ocupam todas as vagas;
- sessões já estabelecidas não são arbitrariamente derrubadas apenas por uma corrida de limite, exceto quando a identidade fica `disabled`/`expired`.

Ainda existe uma pequena janela de corrida entre protocolos porque SSH, WireGuard e OpenVPN são daemons independentes. A solução definitiva para múltiplos servidores será o **lease atômico da Colmeia**, não polling local.

## Reconciliação

O enforcement usa:

```text
manager-policy-reconcile.path
manager-policy-reconcile.timer
manager-policy-reconcile.service
```

O path reage a mudanças de estado e o timer de 30 segundos cobre expiração, handshakes e mudanças de sessão que não alteram arquivos de identidade.

Reconciliação manual:

```bash
/opt/manager/modules/policy_engine.sh --reconcile
```

## CLI pública

```bash
manager --identities
manager --identity maria
manager --identity-sessions
manager --identity-sessions maria
```

## Contratos internos

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

Esses contratos são intencionalmente simples para poderem ser reutilizados mais tarde pela Automation v2/`managerd`, sem fazer a integração remota manipular arquivos diretamente.

## Compatibilidade com revenda

Quando um usuário SSH é vinculado a uma identidade que possui `owner`, o Connection Engine reutiliza o módulo de revendedores para validar e registrar a propriedade desse usuário.

A estrutura de cotas da série 0.5/0.6 ainda conta principalmente usuários SSH. Isso será migrado para um modelo de produto/identidade antes da Colmeia, porque uma identidade WireGuard-only ou OpenVPN-only também precisará consumir cota corretamente.

## Próximas etapas 0.6.x

1. Registro comum de sessão/lease local com IDs estáveis.
2. Registro comum de tráfego/estado.
3. Políticas/ACL independentes do protocolo.
4. Provisionamento e revogação dos recursos de SSH/WireGuard/OpenVPN pelo próprio Connection Engine.
5. Cotas de revenda baseadas em identidades/produtos, não apenas usuários Linux.
6. IPv6 e metadados necessários para Colmeia.

## Relação com Automation e Colmeia

O objetivo final é:

```text
Telegram / projeto antigo / projeto novo
                 ↓
           Automation Engine
                 ↓
          Connection Engine
                 ↓
      identidade MANAGER (Maria)
        ┌────────┼─────────┐
        ↓        ↓         ↓
       SSH   WireGuard   OpenVPN
```

Na Colmeia, `max_sessions` passará a ser global para a identidade/plano. Assim, ter acesso a vários servidores não significará ganhar uma sessão simultânea independente em cada VPS.
