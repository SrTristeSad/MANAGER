# Política de Segurança

O MANAGER executa tarefas administrativas como `root`. Uma falha pode afetar acesso SSH, firewall, DNS ou VPN; por isso segurança operacional é parte central do projeto.

## Versões suportadas

Enquanto o projeto estiver em `0.x`, somente a versão mais recente da branch `main` recebe correções.

## Reportando vulnerabilidades

Não publique credenciais, chaves privadas, IPs privados sensíveis, tokens ou dumps completos de configuração em issues públicas.

Ao relatar um problema de segurança, informe apenas o necessário para reproduzi-lo e remova segredos dos logs.

## Regras para código do projeto

Mudanças não devem:

- limpar todas as regras do firewall (`iptables -F`, `nft flush ruleset` etc.);
- usar permissões globais como `chmod 777` para arquivos administrativos;
- baixar e executar binários opacos como root;
- substituir o `/etc/ssh/sshd_config` inteiro;
- abrir um resolver DNS recursivo para a internet por padrão;
- imprimir chaves privadas ou senhas em logs automáticos;
- desabilitar mecanismos de segurança da distribuição sem ação explícita do administrador.

Mudanças em SSH devem passar por `sshd -t` antes de recarregar o serviço. Mudanças de rede devem ser específicas ao recurso configurado e, quando possível, reversíveis.

## Operação recomendada

- Use uma VPS descartável ou snapshot antes de testar uma versão nova.
- Mantenha uma segunda sessão SSH aberta ao alterar firewall/SSH.
- Verifique também firewalls externos do provedor/cloud.
- Proteja `/etc/manager`, `/etc/wireguard` e `/var/backups/manager`; eles podem conter material sensível.
- Nunca publique arquivos de cliente WireGuard: eles contêm chaves privadas.
- Use `manager-rollback` para voltar o código à versão anterior quando disponível.
- Use o módulo de backup antes de alterar serviços críticos.

## CI

O GitHub Actions verifica sintaxe Bash, ShellCheck, formato da versão e alguns padrões destrutivos conhecidos antes de considerar o código saudável. CI estático não substitui testes reais de systemd, netfilter, PAM e WireGuard em uma VPS.
