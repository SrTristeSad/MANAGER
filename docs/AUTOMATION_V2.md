# Automation v2 — núcleo estruturado, RBAC e autenticação Ed25519

A Automation v2 é a interface oficial para integrações novas do MANAGER. A série 0.7 constrói a fronteira de segurança em camadas antes de abrir transporte remoto.

- **0.7.1:** núcleo local estruturado, `managerd`/`managerctl`, idempotência e auditoria;
- **0.7.2:** principals e RBAC;
- **0.7.3:** autenticação Ed25519, enrollment, rotação e revogação;
- **0.7.4:** anti-replay, rate limiting e transporte remoto estruturado.

A Colmeia só começa depois dessas fronteiras estarem estabilizadas.

## Transporte atual

Serviço e socket:

```text
manager-automation-v2.service
/run/manager-automation-v2/manager.sock
```

Permissões esperadas:

```text
runtime: 0700
socket:  0600
```

O socket continua local e root-only. O daemon valida o peer Unix com `SO_PEERCRED`. A 0.7.3 adiciona autenticação criptográfica dos principals, mas **não abre porta TCP nem listener remoto**.

Status:

```bash
manager automation v2 status
```

Contrato atual:

```text
contract=manager-automation-v2-local-v1
transport=unix
remote_transport=0
arbitrary_shell=0
rbac=1
principal_assertion=local-root-peercred-or-ed25519
cryptographic_auth=1
credential_algorithm=ed25519
nonlocal_signature_required=1
enrollment=local-admin
key_rotation=1
key_revocation=1
anti_replay=0
rate_limit=0
idempotency=1
audit=1
secret_replay=0
```

`anti_replay=0` é intencional: timestamp/nonce, janela de validade e cache anti-replay pertencem à 0.7.4.

## Principals

Estado persistente:

```text
/etc/manager/automation/v2/principals/
```

Cada principal é root-only `0600`; o diretório é `0700`.

Papéis:

```text
admin
reseller
subreseller
user
```

O MANAGER reaproveita a autoridade existente:

- `reseller` e `subreseller` apontam para `/etc/manager/access/resellers/`;
- `user` aponta para uma identidade do Connection Engine;
- `admin` possui escopo global.

O principal reservado `local-root` é criado automaticamente, possui `role=admin`, `subject=*` e é autenticado exclusivamente pelo UID 0 observado em `SO_PEERCRED`. Ele não recebe credencial Ed25519.

Administração:

```bash
manager automation v2 principals
manager automation v2 principal show ID
manager automation v2 principal create ID ROLE SUBJECT [PRODUCTS]
manager automation v2 principal enable ID
manager automation v2 principal disable ID
manager automation v2 principal products ID SCOPE
```

Exemplo:

```bash
manager automation v2 principal create loja01 reseller loja01 premium,basic
```

## Credenciais Ed25519

O registry público fica em:

```text
/etc/manager/automation/v2/credentials/<principal>/
```

Para cada chave existem:

```text
<key_id>.conf   metadados, fingerprint, enabled/revoked
<key_id>.pub    chave pública PEM
```

Arquivos e diretórios são root-only. O servidor **não guarda a chave privada** nesse registry.

### Enrollment

```bash
manager automation v2 credential enroll loja01 /root/loja01.credential
```

O caminho precisa ser absoluto e o arquivo não pode existir previamente. O MANAGER gera um par Ed25519 com OpenSSL, registra somente a parte pública no servidor e cria o arquivo privado de credencial em modo `0600` no caminho informado.

Saída inclui:

```text
principal_id=loja01
key_id=ed25519-...
algorithm=ed25519
fingerprint=SHA256:...
credential_file=/root/loja01.credential
private_key_stored_server=0
```

O arquivo `.credential` é segredo operacional. Guarde/transfira por canal seguro. Ele não é copiado automaticamente para backup do servidor MANAGER.

### Listar e inspecionar

```bash
manager automation v2 credentials loja01
manager automation v2 credential show loja01 ed25519-0123456789abcdef
```

### Rotação

```bash
manager automation v2 credential rotate loja01 /root/loja01-v2.credential
```

A sequência é:

```text
gera nova chave
  ↓
cria arquivo privado externo
  ↓
registra nova chave pública ativa
  ↓
revoga credenciais anteriores ativas
```

A chave antiga deixa de autenticar novas requisições imediatamente.

### Revogação

```bash
manager automation v2 credential revoke loja01 ed25519-0123456789abcdef
```

Revogação de credencial é independente de RBAC. Um principal pode continuar habilitado e ainda assim uma chave específica ser recusada.

## Identidade da chave

`key_id` deriva do SHA-256 da representação DER da chave pública:

```text
ed25519-<16 primeiros hex do SHA-256>
```

O fingerprint usa SHA-256 da mesma chave pública:

```text
SHA256:<base64 do digest>
```

O daemon não confia cegamente no `.conf`: ele relê a chave pública, recalcula `key_id` e fingerprint e exige correspondência com os metadados antes de verificar a assinatura.

## Envelope assinado

Requisição conceitual para principal não-local:

```json
{
  "version": 1,
  "request_id": "exemplo-0001",
  "principal_id": "loja01",
  "action_id": "connection.status",
  "params": {
    "id": "maria"
  },
  "auth": {
    "scheme": "ed25519-v1",
    "key_id": "ed25519-0123456789abcdef",
    "signature": "BASE64..."
  }
}
```

A assinatura cobre a forma canônica de:

```text
contract
version
request_id
principal_id
action_id
params
```

Assim, mudar principal, ação, request ID ou parâmetros invalida a assinatura.

Uso normal:

```bash
managerctl --credential /root/loja01.credential \
  connection.status id=maria
```

O `principal_id` é lido da própria credencial. Também é possível informar `--principal`, mas ele precisa corresponder ao principal da credencial.

Para `local-root`:

```bash
managerctl describe
```

Sem `--credential`, uma chamada com principal diferente de `local-root` é recusada com código `67`.

## Ordem de validação

A fronteira executa, em essência:

```text
peer Unix / UID 0
       ↓
principal existe e está ativo
       ↓
autenticação peercred ou Ed25519
       ↓
RBAC / ownership / produto
       ↓
idempotência
       ↓
dispatcher allowlisted
```

Autenticação e autorização são reavaliadas **antes do cache idempotente**. Portanto:

```text
requisição executada
       ↓
chave revogada ou principal desabilitado
       ↓
retry do mesmo request_id
       ↓
NEGADO
```

A existência de resultado em cache não contorna revogação.

## Matriz RBAC

| Ação | admin | reseller | subreseller | user |
|---|---:|---:|---:|---:|
| `system.describe` | sim | sim | sim | sim |
| `node.usage` | sim | não | não | não |
| `connection.preflight/create` | sim | escopo | próprio owner | não |
| `connection.status` | sim | escopo | próprio owner | própria identidade |
| `connection.revoke` | sim | escopo | próprio owner | não |

Para revenda:

- produto precisa estar no `products` do principal;
- `owner` omitido é preenchido pelo MANAGER com owner autorizado;
- revendedor pode atuar em sua árvore e subrevendedores filhos diretos;
- subrevendedor não sobe para o pai nem cruza para outra revenda;
- `user` só consulta sua identidade vinculada.

Negação de autenticação ou autorização usa código estável `67`.

## Ações allowlisted

```text
system.describe
node.usage
connection.preflight
connection.create
connection.status
connection.revoke
```

Não existe ação para shell, comando arbitrário, script ou caminho executável fornecido pelo cliente. O daemon constrói `argv` fixos e executa com `shell=False`.

## Idempotência e segredos

Estado:

```text
/var/lib/manager/automation-v2/idempotency/
```

O hash inclui:

```text
version
principal_id
action_id
params normalizados
```

- mesmo principal + ação + payload normalizado: replay idempotente;
- mesmo `request_id` com principal/payload diferente: conflito `65`;
- credencial/assinatura não vira parte da identidade lógica da operação, permitindo rotação sem duplicar semanticamente a mesma operação;
- autenticação atual é revalidada antes de servir o resultado cacheado.

Senhas/chaves geradas pelas operações continuam one-shot. O cache persistente remove conteúdo sensível antes de gravar.

## Auditoria

Arquivo:

```text
/var/log/manager/automation-v2-audit.jsonl
```

Campos relevantes incluem:

```text
principal_id
principal_role
principal_subject
auth_scheme
auth_key_id
auth_fingerprint
auth_decision=allow|deny
rbac_decision=allow|deny
rbac_reason
```

O audit não armazena assinatura, chave privada, senha ou stdout sensível.

## Lifecycle

Instalação:

- instala principals e registry de credenciais;
- garante `local-root`;
- instala OpenSSL/Python 3 quando necessário;
- inicia `manager-automation-v2.service`;
- só considera pronto quando o socket existe em `0600`.

Uninstall normal:

- para daemon e remove runtime/aliases;
- preserva principals;
- preserva chave pública/metadados de credenciais;
- preserva idempotência/audit conforme lifecycle atual.

Reinstall reutiliza os registros públicos existentes.

`manager-uninstall --purge` remove o estado persistente server-side, inclusive principals e credenciais públicas. Arquivos privados de credencial criados fora de `/etc/manager` são responsabilidade do administrador e não são apagados pelo purge.

## Limite de confiança da 0.7.3

Pronto:

```text
RBAC:                       sim
autenticação Ed25519:       sim
enrollment:                  sim
fingerprint:                 sim
rotação:                     sim
revogação:                   sim
secret-free server registry: sim
```

Ainda ausente:

```text
remote_transport: 0
anti_replay:      0
rate_limit:       0
```

Como o transporte ainda é o socket local root-only, a 0.7.3 estabiliza a identidade criptográfica antes de expor rede. Uma assinatura válida sozinha **não deve ser tratada como autorização para abrir o socket na Internet**.

## Relação com o Legacy

```text
Legacy v1
  compatibilidade syncpainel
  transporte SSH dedicado
  desligado por padrão

Automation v2
  integrações novas
  contrato estruturado
  principals + RBAC
  autenticação Ed25519
  socket privilegiado local
```

A v2 não usa o transporte Legacy como arquitetura principal.

## Próxima etapa — 0.7.4

A próxima etapa fecha a série 0.7 com proteção própria para transporte remoto:

- timestamp assinado;
- nonce;
- janela de validade;
- cache anti-replay;
- rate limiting por principal/ação;
- limites de burst;
- transporte remoto autenticado e criptografado;
- Unix socket preservado como fronteira privilegiada local;
- nenhuma execução arbitrária de shell.

Depois disso começa a 0.8 Colmeia: enrollment de nós, heartbeat, scheduler, drain/failover, autoridade de leases globais e accounting distribuído.
