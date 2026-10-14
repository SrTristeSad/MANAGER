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
└── bindings/
    └── <telegram_user_id>.conf
```

Diretórios são `0700` e bindings são `0600`.

Audit local:

```text
/var/log/manager/telegram-identity-audit.jsonl
```

O audit registra vínculo, enable/disable, resolve e recusas sem bot token, credencial Ed25519 ou segredo de sessão.

## Contrato

```text
manager-telegram-identity-v1
```

Um resolve autorizado expõe apenas o contexto necessário para a camada Bot/Mini App:

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

## Administração local

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
- nenhuma ação Telegram recebe shell/comando/caminho arbitrário.
\n## Autenticação criptográfica do Mini App\n\nO backend não confia em `Telegram.WebApp.initDataUnsafe`. O Mini App deve enviar o valor bruto de `Telegram.WebApp.initData`, e o MANAGER valida esse valor antes de aceitar qualquer `user.id`.\n\nA validação segue o contrato do Telegram Mini Apps:\n\n1. parseia o query string bruto e rejeita campos duplicados ou malformados;\n2. remove somente `hash` do data-check-string e ordena os demais pares `key=value`;\n3. deriva a chave `HMAC-SHA-256(key=WebAppData, message=bot_token)`;\n4. calcula `HMAC-SHA-256` do data-check-string e compara o `hash` em tempo constante;\n5. valida `auth_date` com freshness obrigatória;\n6. somente depois lê `user.id`;\n7. somente depois resolve esse ID no binding `manager-telegram-identity-v1` e no RBAC da Automation v2.\n\nO contrato criptográfico é:\n\n```text\nmanager-telegram-initdata-v1\n```\n\nE o contexto já autenticado + autorizado usa:\n\n```text\nmanager-telegram-authenticated-principal-v1\n```\n\nPor padrão, `initData` pode ter no máximo 300 segundos de idade e até 30 segundos de tolerância para relógio futuro. O operador pode ajustar esses limites dentro dos intervalos seguros definidos pelo módulo.\n\n### Bot token\n\nO token nunca é aceito diretamente em argv. Ele deve vir de um arquivo local legível por root:\n\n```bash\nmanager telegram auth token install /root/telegram-bot-token\nmanager telegram auth status\n```\n\nO MANAGER copia o token para:\n\n```text\n/etc/manager/telegram/secrets/bot-token\n```\n\nO diretório é `0700` e o token é `0600`. O status mostra apenas se o token está configurado/válido e o `bot_id`; a parte secreta não aparece. Instalar novamente a partir de outro arquivo faz uma substituição atômica do token.\n\n### Freshness\n\n```bash\nmanager telegram auth freshness set 300 30\n```\n\nO primeiro valor é a idade máxima em segundos (`30..86400`). O segundo é a tolerância máxima de relógio futuro (`0..300`). Dados vencidos ou muito adiantados são recusados antes do RBAC.\n\n### Verificação e resolve\n\nPara operação manual:\n\n```bash\nmanager telegram auth verify /root/initdata.txt\nmanager telegram auth resolve /root/initdata.txt\n```\n\nPara o futuro gateway, prefira stdin para não colocar material de autenticação em argv:\n\n```bash\nprintf '%s' "$TELEGRAM_INIT_DATA" | manager telegram auth verify-stdin\nprintf '%s' "$TELEGRAM_INIT_DATA" | manager telegram auth resolve-stdin\n```\n\nO módulo limita o payload, usa arquivo temporário root-only apenas durante a chamada stdin e o remove ao terminar. `initData`, `hash`, `signature`, `query_id`, nomes e username não entram no audit.\n\nAudit:\n\n```text\n/var/log/manager/telegram-auth-audit.jsonl\n```\n\nUma falha de HMAC, freshness, parsing, binding ou principal resulta em fail-closed. Um `user.id` só chega ao `telegram_identity.sh --resolve` depois de a assinatura HMAC e a freshness terem sido aceitas.\n\n## Próximas fatias da 0.9

A camada Bot/Mini App ainda precisa:

1. criar o gateway Bot/Mini App consumindo somente ações tipadas e allowlisted da Automation v2;
2. aplicar rate limit e idempotência por requisição no gateway;
3. implementar telas/fluxos de sessões, clientes, produtos, cotas, nós e diagnósticos;
4. adicionar gate end-to-end do gateway real, mantendo o bot token fora de argv, logs e respostas públicas.

O Telegram será uma interface do control plane já existente, não uma nova autoridade paralela.
