# Automation Legacy v1

O **Automation Legacy v1** é a camada de compatibilidade do MANAGER com o ecossistema antigo baseado em `syncpainel`.

Ela existe para permitir que painéis/projetos antigos continuem chamando o servidor de conexões sem obrigar o MANAGER moderno a restaurar práticas inseguras do SSHPlus antigo.

## Estado padrão

O Legacy fica **desligado por padrão**.

```bash
manager automation legacy status
```

Uma instalação nova deve mostrar, entre outros campos:

```text
contract=manager-automation-legacy-v1
enabled=0
service=inactive
port_listening=0
root_login=0
arbitrary_shell=0
plaintext_password_storage=0
```

Enquanto estiver desligado:

- o listener dedicado não fica ativo;
- a porta exclusiva não fica aberta pelo MANAGER;
- a conta de integração fica bloqueada;
- a configuração é preservada para futura reativação.

## Ativação

```bash
manager automation legacy enable
```

Porta específica:

```bash
manager automation legacy enable 22022
```

Na primeira ativação o MANAGER cria uma conta de integração dedicada e devolve algo equivalente a:

```text
enabled=1
login_server=manager-legacy
porta=22022
senha=<mostrada uma única vez>
password_delivery=stdout-once
```

Essa senha deve ser cadastrada no painel antigo no campo de senha do servidor. O MANAGER não grava a senha em texto claro em `/etc/manager`, no log de auditoria nem em arquivos equivalentes ao antigo `/etc/SSHPlus/senha`.

A credencial pode ser girada explicitamente:

```bash
manager automation legacy rotate-password
```

## Transporte

O Legacy usa uma instância SSH dedicada e restrita. Ela não reutiliza acesso `root` do SSH principal.

O usuário remoto é sempre:

```text
manager-legacy
```

A instância dedicada possui:

- `PermitRootLogin no`;
- sem TCP forwarding;
- sem agent forwarding;
- sem X11 forwarding;
- sem túnel SSH;
- sem TTY;
- `ForceCommand` fixo;
- uma única regra `sudoers` que permite elevar somente o dispatcher Legacy.

O SSH principal também recebe um guard específico para impedir que a credencial `manager-legacy` seja usada como shell normal.

A elevação privilegiada aceita somente:

```text
/opt/manager/modules/automation_legacy.sh --forced-command
```

O comando original enviado pelo painel é tratado como dado e passa por uma allowlist. Não existe `eval`, shell arbitrário, caminho arbitrário ou comando administrativo genérico.

## Contrato compatível

A primeira versão cobre os comandos históricos usados pelo `syncpainel` preservado:

```text
criarusuario.sh USER PASSWORD DAYS LIMIT
remover.sh USER
AlterarSenha.sh USER PASSWORD
AlterarData.sh USER DAYS
alterarlimite.sh USER LIMIT
KillUser.sh USER
sshmonitor.sh
```

O basename é usado para compatibilidade com chamadas antigas que incluam caminho, mas somente esses nomes são reconhecidos.

Uma chamada como:

```text
id
```

ou qualquer outro comando fora da allowlist é recusada.

## Integração com o MANAGER moderno

`criarusuario.sh` não cria uma conta paralela fora do modelo moderno. A operação:

1. valida usuário, validade e limite;
2. cria a conta Linux;
3. aplica `maxlogins`;
4. importa/vincula a conta à identidade do Connection Engine;
5. registra somente metadados de auditoria.

Alterações de validade e limite atualizam também a política da identidade.

`remover.sh`:

1. desabilita a identidade;
2. revoga leases ativas;
3. encerra processos daquele usuário;
4. remove a conta Linux;
5. limpa o binding SSH;
6. preserva a identidade lógica desabilitada para histórico.

Os comandos de alteração/remoção só operam sobre uma conta vinculada ao Connection Engine. `root`, `manager-legacy` e usuários locais alheios ao MANAGER não podem ser manipulados por essa superfície.

## Códigos históricos

Onde o painel antigo depende de códigos simples, o adapter preserva os retornos importantes. Exemplos:

```text
criarusuario.sh
13 = criado
0  = usuário já existe
14 = falha de criação

alterarlimite.sh
4 = limite alterado
5 = usuário não gerenciado/inexistente

remover.sh
1 = removido
2 = usuário não gerenciado/inexistente
```

A implementação moderna não reproduz arquivos de senha em texto claro nem bancos auxiliares inseguros apenas para imitar os efeitos colaterais do script antigo.

## Desativação

```bash
manager automation legacy disable
```

A desativação:

- para e desabilita o serviço;
- remove a regra privilegiada `sudoers`;
- bloqueia a conta `manager-legacy`;
- fecha a porta dedicada;
- preserva configuração e hash da credencial para reativação controlada.

Reiniciar quando ativo:

```bash
manager automation legacy restart
```

## Firewall

O Legacy não abre automaticamente uma porta no UFW. O operador decide explicitamente se a porta dedicada deve ser alcançável pela rede e, idealmente, restringe a origem ao servidor do painel.

Isso evita transformar a ativação da compatibilidade em uma alteração silenciosa de política de firewall.

## Backup, rollback e uninstall

O estado fica em:

```text
/etc/manager/automation/legacy/
```

Esse diretório participa do backup do MANAGER.

No uninstall normal:

- o listener é fechado antes da remoção do código;
- a regra `sudoers` e o guard externo são removidos;
- a conta de integração fica bloqueada;
- a configuração é preservada.

Em uma reinstalação, um Legacy que estava habilitado pode ser reanexado com a credencial já existente. Se a credencial tiver desaparecido, o MANAGER falha fechado e mantém o listener desligado até uma nova ativação.

`manager-uninstall --purge` remove também o estado Legacy e a conta de integração.

## Limite desta etapa

Legacy v1 é apenas compatibilidade controlada com projetos antigos. Ele **não é** a Automation v2.

A Automation v2 terá contrato versionado próprio, request IDs, idempotência, RBAC, auditoria estruturada, autenticação criptográfica, anti-replay, rate limiting e uma interface local privilegiada própria. Nenhuma integração nova deve depender do protocolo Legacy.