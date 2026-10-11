# Connection Actions — contrato interno allowlisted

A série 0.6.x fecha a fronteira privilegiada de criação e revogação de acessos com um contrato único em `modules/connection_actions.sh`.

O objetivo é permitir que a futura Automation v2 invoque ações conhecidas sem conhecer a implementação interna de SSH, WireGuard ou OpenVPN e sem receber uma primitiva de shell arbitrário.

## Contrato

Versão atual:

```text
manager-connection-actions-v1
```

Ações permitidas:

```bash
/opt/manager/modules/connection_actions.sh --describe
/opt/manager/modules/connection_actions.sh --status ID
/opt/manager/modules/connection_actions.sh --preflight ID PLAN [OWNER] [PROTOCOLS]
/opt/manager/modules/connection_actions.sh --create ID PLAN [OWNER] [PROTOCOLS]
/opt/manager/modules/connection_actions.sh --revoke ID
```

Nenhuma outra ação é aceita.

O contrato declara explicitamente:

```text
arbitrary_shell=0
arbitrary_command=0
arbitrary_path=0
```

Portanto, integrações futuras não devem passar comandos do sistema, nomes de binário, caminhos de scripts ou fragmentos de shell por esse canal.

## Protocolos

`PROTOCOLS` é uma lista allowlisted contendo somente:

- `ssh`
- `wireguard`
- `openvpn`

O produto/plano continua sendo a autoridade que pode restringir quais protocolos a identidade pode receber. A lista solicitada nunca amplia o que o produto permite.

## Preflight

`--preflight` valida antes de alterar o servidor:

- formato da identidade;
- existência/estado do produto;
- protocolos solicitados;
- conflito com recursos existentes;
- dependências técnicas de cada protocolo;
- cota do revendedor;
- cota do produto.

## Create

`--create` reutiliza o provisionamento transacional da série 0.6:

1. cria a identidade;
2. aplica o produto;
3. cria os recursos técnicos allowlisted;
4. cria os bindings;
5. reconcilia política;
6. libera o SSH somente após sucesso;
7. executa rollback do que foi criado naquela tentativa se uma etapa falhar.

Quando SSH é criado, a senha aleatória é entregue uma única vez pela saída da operação. Ela não é gravada no log de provisionamento.

## Status

`--status ID` fornece um formato `key=value` previsível com:

- estado efetivo da identidade;
- proprietário;
- produto;
- protocolos permitidos;
- expiração;
- limite de sessões;
- recurso vinculado por protocolo;
- estado do recurso (`present`, `missing`, `revoked` ou `unbound`).

## Revoke

`--revoke ID` reutiliza a revogação transacional existente:

- desativa a identidade;
- revoga leases;
- remove usuário SSH vinculado;
- remove peer WireGuard vinculado;
- revoga certificado OpenVPN vinculado;
- remove o produto;
- limpa bindings;
- libera a vaga de revenda após revogação completa;
- preserva a identidade lógica desativada para histórico/auditoria.

## Códigos de saída

```text
0  sucesso
64 entrada inválida / ação não permitida
65 conflito
66 não encontrado
67 política/protocolo negado
68 produto/estado desativado
69 dependência indisponível
70 operação transacional falhou
73 cota/autoridade negou a operação
```

Esses códigos formam a base que a Automation v2 poderá transformar em respostas de API versionadas sem depender de texto de terminal.
