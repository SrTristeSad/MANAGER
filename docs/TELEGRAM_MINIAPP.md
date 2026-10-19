# MANAGER Mini App 0.9 — configuração

A interface visual permite consultar Clientes, Sessões, Produtos e Cotas pelo Telegram, além de Nós e Diagnósticos para administradores autorizados. Usa a ação tipada `ops.read` e preserva o controle de acesso da Automation v2.

## Segurança

O serviço HTTP é opt-in e aceita conexões apenas em `127.0.0.1`. É necessário usar um subdomínio HTTPS com reverse proxy externo para torná-lo acessível ao Telegram. O MANAGER não altera DNS, firewall ou certificados TLS e não habilita automaticamente serviços públicos.

A requisição de leitura contém o `Telegram.WebApp.initData` bruto em POST. O backend revalida a assinatura HMAC e o prazo de validade antes de resolver a identidade Telegram e pedir autorização à Automation v2. As quatro consultas de clientes, sessões, produtos e cotas usam `ops.read`, limitadas a 25 registros por página. As consultas administrativas de `nodes` e `diagnostics` reutilizam o gateway operacional `manager-telegram-operations-v1`, que exige role admin e capability `node.usage` no `managerd`. O Mini App não concede permissões adicionais. O usuário não pode escolher o owner nem alterar permissões enviando parâmetros.

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


## Telas administrativas: Nós e Diagnósticos

- **Nós:** lista o último estado de saúde disponibilizado pelo export sanitizado de observabilidade da Colmeia, com sessões, capacidade, CPU, memória, latência e condição da rede quando esses campos estiverem disponíveis. A ausência de telemetria aparece como lista vazia, não como nós fictícios.
- **Diagnósticos:** exibe carga média do host em 1, 5 e 15 minutos, uso de RAM e disco, reinicialização pendente, rota IPv4 padrão e estado dos serviços SSH, WireGuard, OpenVPN, Automation v2 e Telegram Bot.

A interface usa os endpoints existentes somente de leitura e o `initData` enviado via stdin. A checagem de `node.usage` é obrigatória até para administradores, e a role reseller, subreseller ou user não é suficiente mesmo que se tente configurar um escopo de ação equivalente. Falhas retornam HTTP 403 sem divulgar dados administrativos.

O backend operacional limita a consulta de nós a **até 100 registros** e a Mini App pagina *esse snapshot já limitado* em grupos de até 25. Isso não é paginação global da Colmeia: uma indicação visual aparece quando o limite do backend é atingido. Cada atualização consulta novamente a autoridade. Diagnósticos exibem um único snapshot sem paginação.

A busca atua somente sobre o grupo de registros carregados no cliente, não sobre todos os nós. Os indicadores usam apenas dados disponíveis; nenhum percentual ou status é inventado.
