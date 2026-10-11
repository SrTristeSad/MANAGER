# Automation v2 — núcleo local

A Automation v2 é a interface oficial para integrações novas do MANAGER. A primeira etapa, introduzida na série 0.7.x, cria uma fronteira local estruturada antes de qualquer transporte remoto.

## Objetivo desta etapa

O núcleo local fornece:

- daemon `managerd` executado como root;
- cliente `managerctl`;
- socket Unix local `/run/manager-automation-v2/manager.sock`;
- socket e runtime restritos a root;
- envelope JSON versionado;
- `request_id` e `action_id`;
- idempotência persistente;
- auditoria estruturada;
- dispatcher allowlisted reutilizando os contratos estabilizados na série 0.6.

Esta etapa **não abre porta TCP** e não cria API web.

## Transporte local

O serviço systemd é:

```text
manager-automation-v2.service
```

O socket é:

```text
/run/manager-automation-v2/manager.sock
```

Permissões esperadas:

```text
runtime: 0700
socket:  0600
```

O daemon valida a identidade Unix do peer com `SO_PEERCRED`; nesta etapa somente UID 0 é aceito.

```bash
managerctl describe
```

O status técnico pode ser visto com:

```bash
/opt/manager/modules/automation_v2.sh --status
```

O contrato atual declara explicitamente:

```text
contract=manager-automation-v2-local-v1
transport=unix
remote_transport=0
arbitrary_shell=0
rbac=0
cryptographic_auth=0
anti_replay=0
rate_limit=0
idempotency=1
audit=1
secret_replay=0
```

Os zeros são intencionais: RBAC, autenticação criptográfica, anti-replay, rate limiting e transporte remoto pertencem às próximas etapas da série 0.7 e não são apresentados como recursos concluídos aqui.

## Envelope

Requisição conceitual:

```json
{
  "version": 1,
  "request_id": "exemplo-0001",
  "action_id": "connection.status",
  "params": {
    "id": "maria"
  }
}
```

Resposta conceitual:

```json
{
  "contract": "manager-automation-v2-local-v1",
  "version": 1,
  "request_id": "exemplo-0001",
  "action_id": "connection.status",
  "ok": true,
  "code": 0,
  "cached": false,
  "result": {
    "data": {}
  }
}
```

O `request_id` deve ser único para uma operação lógica. Reutilizar o mesmo ID com o mesmo payload devolve o resultado cacheado; reutilizá-lo com payload diferente é conflito e não executa uma segunda operação.

## Ações permitidas

A allowlist inicial é pequena de propósito:

```text
system.describe
node.usage
connection.preflight
connection.create
connection.status
connection.revoke
```

Exemplos:

```bash
managerctl describe
managerctl node.usage
managerctl connection.status id=maria
managerctl connection.preflight id=maria plan=premium protocols=wireguard,openvpn
managerctl connection.create id=maria plan=premium protocols=wireguard,openvpn
managerctl connection.revoke id=maria
```

Também é possível definir o `request_id` explicitamente:

```bash
managerctl connection.status id=maria --request-id consulta-maria-0001
```

Não existe ação para executar shell, comando arbitrário ou caminho informado pelo chamador. O daemon monta `argv` fixos para `manager-connection-actions-v1` e `manager-node-usage-v1` e usa subprocesso com `shell=False`.

## Idempotência e segredos

Estado de idempotência:

```text
/var/lib/manager/automation-v2/idempotency/
```

Diretório e arquivos são root-only. Entradas antigas podem ser removidas automaticamente após a janela de retenção.

Um ponto importante: idempotência **não transforma segredo em armazenamento persistente**.

Se `connection.create` gerar uma senha SSH, ela aparece somente na primeira resposta bem-sucedida. Antes de persistir a resposta no cache, campos sensíveis e linhas sensíveis são removidos.

Portanto:

```text
primeira chamada  -> operação executada + segredo one-shot
retry idempotente -> sucesso cacheado, sem recuperar o segredo
```

O cache marca essa condição com:

```text
secret_replay_available=false
secret_returned_once=true
```

Se o consumidor perder a primeira resposta que continha o segredo, deve usar uma operação futura específica de rotação/reemissão quando ela existir; o MANAGER não guarda a senha em texto claro para recuperá-la depois.

## Auditoria

Arquivo:

```text
/var/log/manager/automation-v2-audit.jsonl
```

Cada evento registra apenas metadados operacionais, como:

- timestamp;
- `request_id`;
- `action_id`;
- UID local do peer;
- sucesso/erro;
- código de saída;
- se a resposta veio do cache.

Stdout, senha gerada, chave privada e conteúdo de credenciais não são gravados no audit log.

## Lifecycle

Instalação normal:

- instala `python3` quando necessário;
- instala o módulo;
- cria `managerd`/`managerctl`;
- instala e inicia `manager-automation-v2.service`;
- só considera a instalação concluída depois que o socket existir em modo `0600`.

Uninstall normal:

- para o daemon;
- fecha/remove o socket;
- remove unit e aliases executáveis;
- preserva o estado de idempotência e auditoria para reinstalação.

`--purge` remove também o estado persistente da Automation v2.

Rollback desanexa o daemon antes da troca de `/opt/manager` e só reinstala a v2 se a versão restaurada possuir o módulo correspondente.

## Relação com o Legacy

Automation Legacy v1 e Automation v2 têm objetivos diferentes:

```text
Legacy v1
  compatibilidade syncpainel / painéis antigos
  transporte SSH dedicado
  desligado por padrão

Automation v2
  integrações novas
  contrato estruturado e versionado
  núcleo inicial somente por Unix socket local
```

A v2 não usa o transporte Legacy como sua arquitetura principal.

## Próximas etapas da série 0.7

Ainda faltam antes da Colmeia:

- principals e RBAC para admin, revendedor, subrevendedor e usuário;
- autenticação criptográfica e rotação de chaves para integrações remotas;
- timestamp/nonce e anti-replay;
- rate limiting;
- transporte remoto estruturado e seguro, quando introduzido;
- expansão cuidadosa da allowlist sem permitir shell arbitrário.

Heartbeat distribuído, scheduler, drain/failover e autoridade global de leases pertencem à fase 0.8 Colmeia.
