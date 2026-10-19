# MANAGER Mini App 0.9 — configuração

A nova interface visual permite consultar Clientes, Sessões, Produtos e Cotas pelo Telegram. Usa a ação tipada `ops.read` e preserva o controle de acesso da Automation v2.

## Segurança

O serviço HTTP é opt-in e aceita conexões apenas em `127.0.0.1`. É necessário usar um subdomínio HTTPS com reverse proxy externo para torná-lo acessível ao Telegram. O MANAGER não altera DNS, firewall ou certificados TLS e não habilita automaticamente serviços públicos.

A requisição de leitura contém o `Telegram.WebApp.initData` bruto em POST. O backend revalida a assinatura HMAC e o prazo de validade antes de resolver a identidade Telegram e pedir autorização à Automation v2. São aceitos apenas quatro tipos de consulta, limitados a 25 registros por página. O usuário não pode escolher o owner nem alterar permissões enviando parâmetros.

A interface mostra estados reais de carregamento, autorização e erro. A busca filtra somente a página atual. O frontend não utiliza o conteúdo de `initDataUnsafe` como prova de identidade, não guarda tokens em armazenamento local e não dispõe de comandos de escrita.

## Como habilitar

Configure um subdomínio HTTPS e seu reverse proxy apontando para o serviço local. Não abra a porta 18768 diretamente na internet.

```bash
sudo manager telegram miniapp configure https://mini.exemplo.com 18768
sudo manager telegram miniapp enable
sudo manager telegram miniapp status
```

Configure o Host do proxy como `mini.exemplo.com` e preserve a origem HTTPS da requisição. O TLS público deve ser válido e gerenciado pelo operador.

No @BotFather, use `/setmenubutton` e informe a URL pública HTTPS da Mini App. A interface deve ser iniciada pelo botão do Bot para receber `initData`. Veja https://core.telegram.org/bots/webapps.

Para interromper: `sudo manager telegram miniapp disable`.

## Ciclo de vida

O Mini App é reanexado após update apenas se já estava habilitado. O uninstall normal e o rollback desativam sua unidade antes de substituir ou remover arquivos. O purge exclui a configuração.

O teste `.github/scripts/telegram-miniapp-ui-e2e.sh` verifica arquivos, autenticação Telegram, escopo de admin e revenda, paginação, payloads inválidos, restrições de Origin e Host e lifecycle. A instalação em uma VPS real ainda exige verificar DNS, TLS e a renderização na WebView do Telegram.
