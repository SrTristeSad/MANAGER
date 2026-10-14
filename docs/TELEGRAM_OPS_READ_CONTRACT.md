# Contrato operacional de leitura do Telegram

`manager-automation-ops-read-v1` é o contrato estruturado compartilhado pelo Telegram Bot e pelo Telegram Mini App para consultas operacionais somente leitura.

A autoridade permanece na Automation v2. O cliente Telegram envia apenas um `action_id` fixo `ops.*` com `params={}`. Depois da autenticação, o `managerd` carrega o principal e injeta internamente `role`, `subject` e escopo de produtos no helper. Esses campos não são aceitos da requisição Telegram.

Views disponíveis:

- `ops.clients`: identidades visíveis pelo owner e escopo de produto do principal;
- `ops.sessions`: leases/sessões das mesmas identidades, preferindo a autoridade global da Colmeia quando ativa;
- `ops.products`: catálogo limitado ao escopo de produto do principal;
- `ops.quotas`: uso/franquia apenas das identidades e produtos visíveis;
- `ops.nodes`: visão sanitizada dos nós, somente para admin;
- `ops.diagnostics`: sinais operacionais sanitizados, somente para admin.

Cada resposta inclui `contract`, `version`, `view`, `generated_at` e dados limitados. Listas incluem `count` e `truncated`. O contrato não expõe token, senha, chave privada, credencial, resource/device de sessão, shell, script ou caminho controlado pelo Telegram.

A API é deliberadamente read-only. Operações de criação, revogação, exclusão, alteração de produto, drain, restart ou qualquer outra escrita ficam fora deste contrato e exigirão uma camada posterior de confirmação explícita de UX.