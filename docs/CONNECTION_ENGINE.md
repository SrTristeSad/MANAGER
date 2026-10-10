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

## Campos iniciais

- `id`: identificador estável da identidade;
- `owner`: revendedor/subrevendedor opcional;
- `enabled`: política administrativa da identidade;
- `expires_epoch`: expiração global da identidade, `0` para sem expiração;
- `max_sessions`: limite simultâneo que será aplicado de forma unificada em etapas posteriores;
- `protocols`: protocolos autorizados pela política;
- `ssh_user`: usuário Linux vinculado;
- `wireguard_client`: peer/config WireGuard vinculado;
- `openvpn_client`: cliente/certificado OpenVPN vinculado;
- `created_epoch` e `updated_epoch`.

Protocolos reconhecidos nesta primeira versão:

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

Nesta primeira etapa, esse estado é o **estado de política do Connection Engine**. O enforcement automático nos protocolos vinculados será adicionado nas próximas iterações 0.6.x.

## CLI pública

```bash
manager --identities
manager --identity maria
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

Esses contratos são intencionalmente simples para poderem ser reutilizados mais tarde pela Automation v2/`managerd`, sem fazer a integração remota manipular arquivos diretamente.

## Compatibilidade com revenda

Quando um usuário SSH é vinculado a uma identidade que possui `owner`, o Connection Engine reutiliza o módulo de revendedores para validar e registrar a propriedade desse usuário.

A estrutura de cotas da série 0.5 ainda conta usuários SSH. Isso será migrado para um modelo de produto/identidade antes da Colmeia, porque uma identidade WireGuard-only ou OpenVPN-only também precisará consumir cota corretamente.

## Próximas etapas 0.6.x

1. Enforcement de `enabled` e `expires_epoch` nos protocolos vinculados.
2. Sessões consolidadas por identidade.
3. Aplicação real de `max_sessions` no nível da identidade.
4. Registro comum de tráfego/estado.
5. Políticas/ACL independentes do protocolo.
6. Provisionamento e revogação dos recursos de SSH/WireGuard/OpenVPN pelo próprio Connection Engine.
7. Cotas de revenda baseadas em identidades/produtos, não apenas usuários Linux.
8. IPv6 e metadados necessários para Colmeia.

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
