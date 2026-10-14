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

## Próximas fatias da 0.9

A camada Bot/Mini App ainda precisa:

1. validar criptograficamente Telegram Bot/WebApp `initData` antes de confiar no `user.id`;
2. transformar interações em ações tipadas e allowlisted da Automation v2;
3. implementar telas/fluxos de sessões, clientes, produtos, cotas, nós e diagnósticos;
4. aplicar rate limit, freshness, idempotência e audit no gateway Telegram;
5. manter bot token fora de argv, logs e respostas públicas.

O Telegram será uma interface do control plane já existente, não uma nova autoridade paralela.
