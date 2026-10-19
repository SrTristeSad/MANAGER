# MANAGER Telegram Bot + Mini App — identidade e confiança

A série 0.9 integra Telegram Bot e Telegram Mini App ao MANAGER sem criar uma segunda autoridade de usuários e sem expor shell arbitrário.

## Fundação 0.9.0

O identificador autoritativo de uma pessoa no Telegram é o `user.id` numérico recebido de uma requisição Telegram autenticada. `username`, nome, sobrenome, `chat.id`, texto da mensagem ou qualquer campo visual não concedem autoridade.

A fundação liga um `telegram_user_id` a exatamente um principal da Automation v2:

```text
Telegram user.id
      │
      ▼
manager-telegram-identity-v1
      │
      ▼
Automation v2 principal
      │
      ├── role
      ├── subject
      ├── products
      ├── node_scope
      ├── pool_scope
      └── action_scope
```

A role continua sendo `admin`, `reseller`, `subreseller` ou `user` conforme o principal já persistido pela Automation v2. O Telegram não pode escolher ou elevar a própria role.

## Estado

```text
/etc/manager/telegram/
├── bindings/
│   └── <telegram_user_id>.conf
├── auth/
│   └── config.conf
└── secrets/
    └── bot-token
```

Diretórios são `0700`; bindings, configuração e bot token são `0600`.

Audits locais:

```text
/var/log/manager/telegram-identity-audit.jsonl
/var/log/manager/telegram-auth-audit.jsonl
```

Os audits registram operações e recusas sem bot token, `initData`, hash, signature, query_id, nomes, username, credencial Ed25519 ou segredo de sessão.

## Contrato de identidade

```text
manager-telegram-identity-v1
```

Um resolve local autorizado expõe apenas o contexto necessário para a camada Bot/Mini App:

```json
{
  "contract": "manager-telegram-identity-v1",
  "telegram_user_id": "123456789",
  "principal_id": "telegram-admin",
  "role": "admin",
  "subject": "*",
  "products": "*",
  "node_scope": "*",
  "pool_scope": "*",
  "action_scope": "*",
  "enabled": 1,
  "authority": "automation-v2-principal",
  "username_is_authority": 0
}
```

O contexto não contém private key, bot token, senha ou credencial recuperável.

## Administração local da identidade

A primeira vinculação é administrativa e explícita. Antes dela, o principal da Automation v2 deve existir.

```bash
manager automation v2 principal create telegram-admin admin '*'
manager telegram identity bind 123456789 telegram-admin
manager telegram identity show 123456789
manager telegram identity resolve 123456789
manager telegram identity disable 123456789
manager telegram identity enable 123456789
manager telegram identity list
manager telegram identity status
```

Por segurança:

- um `user.id` só pode apontar para um principal;
- um principal só pode estar ligado a um `user.id` nesta fundação;
- principal desabilitado faz o resolve falhar fechado;
- binding desabilitado faz o resolve falhar fechado;
- trocar `@username` não muda autoridade;
- username não é persistido como identidade;
- nenhuma ação Telegram recebe shell, comando ou caminho arbitrário.

## Autenticação criptográfica do Mini App

O backend não confia em `Telegram.WebApp.initDataUnsafe`. O Mini App deve enviar o valor bruto de `Telegram.WebApp.initData`, e o MANAGER valida esse valor antes de aceitar qualquer `user.id`.

A validação segue o contrato do Telegram Mini Apps:

1. parseia o query string bruto e rejeita campos duplicados ou malformados;
2. remove somente `hash` do data-check-string e ordena os demais pares `key=value`;
3. deriva a chave com `HMAC-SHA-256(key=WebAppData, message=bot_token)`;
4. calcula `HMAC-SHA-256` do data-check-string e compara o `hash` em tempo constante;
5. valida `auth_date` com freshness obrigatória;
6. somente depois lê `user.id`;
7. somente depois resolve esse ID no binding `manager-telegram-identity-v1` e no RBAC da Automation v2.

O contrato da validação criptográfica é:

```text
manager-telegram-initdata-v1
```

O contexto autenticado e já autorizado usa:

```text
manager-telegram-authenticated-principal-v1
```

Por padrão, `initData` pode ter no máximo 300 segundos de idade e até 30 segundos de tolerância para relógio futuro. O operador pode ajustar esses limites dentro dos intervalos seguros definidos pelo módulo.

### Bot token

O token nunca é aceito diretamente em argv. Ele deve vir de um arquivo local legível por root:

```bash
manager telegram auth token install /root/telegram-bot-token
manager telegram auth status
```

O MANAGER copia o token para:

```text
/etc/manager/telegram/secrets/bot-token
```

O diretório é `0700` e o token é `0600`. O status mostra apenas se o token está configurado/válido e o `bot_id`; a parte secreta não aparece. Instalar novamente a partir de outro arquivo faz uma substituição atômica do token.

### Freshness

```bash
manager telegram auth freshness set 300 30
```

O primeiro valor é a idade máxima em segundos (`30..86400`). O segundo é a tolerância máxima de relógio futuro (`0..300`). Dados vencidos ou muito adiantados são recusados antes do RBAC.

### Verificação e resolve

Para operação manual:

```bash
manager telegram auth verify /root/initdata.txt
manager telegram auth resolve /root/initdata.txt
```

Para o gateway, prefira stdin para não colocar material de autenticação em argv:

```bash
printf '%s' "$TELEGRAM_INIT_DATA" | manager telegram auth verify-stdin
printf '%s' "$TELEGRAM_INIT_DATA" | manager telegram auth resolve-stdin
```

O módulo limita o payload a 16 KiB e 64 campos, usa arquivo temporário root-only apenas durante a chamada stdin e o remove ao terminar. `initData`, `hash`, `signature`, `query_id`, nomes e username não entram no audit nem nos contratos de saída.

Uma falha de HMAC, freshness, parsing, binding ou principal resulta em fail-closed. Um `user.id` só chega ao `telegram_identity.sh --resolve` depois de HMAC e freshness terem sido aceitos.

## Gateway tipado para Mini App

O gateway 0.9.0 transforma uma requisição autenticada do Mini App em uma chamada normal da Automation v2, sem executar shell e sem duplicar RBAC. O contrato de entrada é:

```text
manager-telegram-gateway-request-v1
```

Formato:

```json
{
  "contract": "manager-telegram-gateway-request-v1",
  "request_id": "miniapp-00000001",
  "action_id": "connection.status",
  "params": {"id": "maria"}
}
```

Ações inicialmente allowlisted:

- `system.describe`;
- `node.usage`;
- `connection.preflight`;
- `connection.create`;
- `connection.status`;
- `connection.revoke`.

Cada ação possui schema fechado de parâmetros. Campo desconhecido, ação fora da allowlist ou parâmetro de tipo incorreto é recusado antes da Automation v2. Não existe campo `command`, `shell`, `script` ou caminho executável controlado pelo Telegram.

Fluxo de confiança:

```text
Telegram.WebApp.initData
  -> HMAC + freshness
  -> telegram_user_id
  -> binding Telegram -> principal
  -> gateway tipado
  -> Ed25519 v2 do principal
  -> managerd
  -> RBAC + node/pool/action scope
  -> rate limit
  -> idempotência
  -> dispatcher allowlisted
```

O gateway mantém uma credencial Ed25519 de cliente por principal em `/etc/manager/telegram/gateway/credentials/`, `0600`, enquanto a Automation v2 mantém somente a parte pública em seu registry normal. Essa credencial não concede autoridade nova: principal desabilitado, escopo removido ou ação recusada continuam falhando dentro do `managerd`. Se a credencial do gateway for revogada, a ponte prepara uma nova credencial local antes da próxima chamada; o RBAC continua sendo reavaliado.

O `request_id` externo é namespaced por principal antes de entrar na Automation v2. Repetir o mesmo request com a mesma ação/payload recebe o replay idempotente do cache existente; reutilizar o mesmo ID com payload diferente é conflito. O rate limit também é o token bucket já existente da Automation v2 por `(principal_id, action_id)`, portanto não existe uma segunda política paralela.

CLI:

```bash
manager telegram gateway status
manager telegram gateway call /root/initdata.txt /root/request.json
printf '%s' "$TELEGRAM_INIT_DATA" | manager telegram gateway call-stdin /root/request.json
```

O contrato de saída é `manager-telegram-gateway-v1`. O audit `/var/log/manager/telegram-gateway-audit.jsonl` registra somente IDs, ação, decisão, código e estado de cache; não recebe bot token, initData, hash, assinatura, query_id, credencial privada ou conteúdo da resposta.

## Ingresso do Telegram Bot por long polling

O Bot também pode expor as **consultas operacionais somente leitura já existentes** por comandos fixos:
`/clients` (identidades), `/products`, `/sessions`, `/nodes` e `/diagnostics`.
`/clients`, `/products` e `/sessions`, além de `/quotas`, usam a ação tipada `ops.read`, com páginas de até oito registros e escopos do principal autenticado. Exemplo: `/clients 2` apresenta a segunda página **já filtrada**.
Revendedores veem clientes próprios e de subrevendedores ativos dentro dos produtos permitidos; subrevendedores veem somente seus clientes; usuários veem a própria identidade. `/nodes` e `/diagnostics` permanecem exclusivamente administrativos, usando o gateway `manager-telegram-operations-v1` com `node.usage`.
O Mini App pode consumir `ops.read` pelo gateway já existente, mas ainda não dispõe das telas visuais. Nenhum dos comandos executa shell ou cria/revoga acessos.

O Bot usa `getUpdates` por HTTPS contra `https://api.telegram.org`, portanto não abre porta pública, não exige webhook e não altera firewall. O bot token é lido do mesmo arquivo root-only usado pela autenticação do Mini App e nunca aparece em argv, audit ou mensagens de erro.

Somente mensagens privadas com `message.from.id == message.chat.id` entram no parser. O `user.id` vem da resposta autenticada da Bot API e é resolvido no mesmo binding `telegram_user_id -> principal_id`; username, nome, texto livre e `chat.id` não concedem autoridade. O ingresso inicial expõe somente comandos fixos de leitura:

- `/describe` -> `system.describe`;
- `/node` -> `node.usage`;
- `/status ID` -> `connection.status`;
- `/help` e `/start` retornam a ajuda local.

Texto desconhecido nunca vira `action_id`, shell ou comando do sistema. Cada `update_id` vira um `request_id` estável do gateway. O Bot responde pelo método `sendMessage`; se a entrega falhar, o offset não avança e o mesmo update é tentado novamente com o mesmo `request_id`. A Automation v2 revalida RBAC e devolve o resultado idempotente em cache em vez de executar a ação novamente. O offset só avança depois que a resposta é aceita pela Bot API.

CLI:

```bash
manager telegram bot status
manager telegram bot enable
manager telegram bot disable
manager telegram bot poll-once
```

A unidade `manager-telegram-bot.service` é opcional e usa long polling. Estado e offset ficam root-only em `/etc/manager/telegram/bot` e `/var/lib/manager/telegram-bot`; o audit sanitizado fica em `/var/log/manager/telegram-bot-audit.jsonl`. O uninstall normal para a unidade e preserva estado; reinstalação/rollback reanexam somente quando aplicável.

## Próximas fatias da 0.9

A fundação de ingresso Bot + Mini App da 0.9.0 fica funcionalmente completa com o long polling. As fases seguintes expandem telas e fluxos de sessões, clientes, produtos, cotas, nós e diagnósticos. Operações de escrita no Bot serão expostas apenas com confirmação explícita na UX. Webhook pode ser adicionado como transporte alternativo futuro sem mudar a autoridade do gateway.

O Telegram permanece apenas uma interface do control plane existente, não uma nova autoridade paralela.
