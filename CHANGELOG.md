# Changelog

Todas as mudanças relevantes do MANAGER serão registradas aqui.

O projeto usa versionamento semântico (`MAJOR.MINOR.PATCH`) enquanto a API/estrutura ainda está evoluindo.

## [0.5.0] - 2026-10-10

### Paridade SSHPlus

- Gestão SSH ganhou contas de teste com duração em minutos, senha aleatória exibida apenas uma vez e remoção automática por timer systemd.
- O MANAGER não armazena a senha das contas teste em texto claro; registra apenas metadados de expiração.
- Listagem de contas expiradas e limpeza manual confirmada de usuários expirados.
- Novo modo CLI `manager --expired` para consultar expirados sem abrir o menu.
- Banner SSH próprio em `/etc/manager/banner/banner.txt`, habilitado por drop-in do OpenSSH e validado com `sshd -t` antes de reload.
- Speedtest/latência com instalação opcional via APT e histórico local em `/var/log/manager/speedtest.log`.
- Status de serviços evoluiu para gerenciamento central de start/stop/restart dos serviços conhecidos pelo MANAGER.
- Por segurança, o gerenciador não permite parar o OpenSSH pelo menu.

### Base para as próximas etapas

- Timer `manager-test-users.timer` remove contas de teste expiradas mesmo após reboot.
- Contas teste recebem também uma expiração de segurança no sistema, além do temporizador em minutos.
- A primeira leva de paridade mantém o comportamento útil do SSHPlus sem reproduzir armazenamento de senha em texto claro nem alterações destrutivas de sistema.

## [0.4.1] - 2026-10-10

### Corrigido

- Seleção do usuário no módulo de chaves SSH não é mais contaminada por mensagens de aviso ao administrar `root`.
- Health check interativo agora retorna ao menu normalmente mesmo quando há avisos ou checks críticos, evitando uma segunda pausa e falso erro de módulo.

### Segurança e confiabilidade

- O instalador agora aceita somente fontes `https://` em uso normal.
- `file://` permanece disponível apenas para CI ou testes locais com `MANAGER_ALLOW_FILE_SOURCE=1` explícito.
- Fontes `http://` e outros esquemas são recusadas antes de qualquer download.
- CI ganhou testes de regressão para garantir que a política de fontes do instalador continue sendo aplicada.

## [0.4.0] - 2026-10-10

### Adicionado

- Painel de saúde do servidor com checks de disco, inodes, memória, carga, systemd, SSH, rota, DNS, atualizações, UFW e Fail2ban.
- Modo não interativo `manager --health` com códigos de saída úteis para monitoramento: `0` saudável, `1` avisos e `2` crítico.
- CLI com `--version`, `--help`, `--status` e `--diagnostics`.
- Módulo de manutenção do sistema com APT, atualizações, unattended-upgrades, limpeza segura, journal, NTP e reboot explícito.
- Gerenciador de chaves públicas SSH com validação, fingerprints e correção de permissões.
- Resumo principal com consumo de RAM, disco, carga e aviso de reboot pendente.

### Segurança e confiabilidade

- Self-update deixou de executar diretamente `curl | bash`: o instalador é baixado para arquivo temporário, restrito e validado com `bash -n` antes da execução.
- Downloads do self-update exigem HTTPS/TLS moderno por padrão.
- Falha de um módulo não derruba mais o menu principal e agora preserva o código de saída para diagnóstico.
- Health check é somente leitura e pode ser integrado a cron, systemd ou monitoramento externo.

## [0.3.0] - 2026-10-10

### Adicionado

- OpenVPN moderno em `/etc/openvpn/server` com unidade `openvpn-server@manager`.
- PKI própria via Easy-RSA, certificados individuais de clientes e revogação por CRL.
- Perfis `.ovpn` completos com certificados/chaves embutidos.
- Integração opcional do OpenVPN com o DNS Ad Block.
- TLS/Let's Encrypt via Certbot em virtualenv isolado, com modos standalone e webroot.
- Timer systemd próprio para verificação de renovação de certificados.
- Whitelist e blacklist manuais no bloqueador DNS.
- Estatísticas DNS opcionais, desligadas por padrão por privacidade.
- Múltiplos listeners privados simultâneos no DNS para WireGuard e OpenVPN.
- Assistente de perfis guiados: servidor seguro, WireGuard, OpenVPN, DNS e completo.
- Diagnóstico, logs, backup e desinstalador expandidos para OpenVPN/TLS.
- Backup mais preciso: evita copiar configurações WireGuard alheias ao MANAGER.
- Roteiro de smoke test real em `docs/TESTING.md`.
- Dependabot para manter GitHub Actions atualizadas.

### Melhorado

- BBR/fq agora guarda e restaura imediatamente o congestion control e qdisc anteriores.
- Gestão de usuários SSH ganhou sessões online, bloqueio/desbloqueio e desconexão de usuário.
- OpenVPN diferencia corretamente `tcp-server` e `tcp-client` quando TCP é escolhido.
- WireGuard valida conflito de porta e insere apenas suas regras específicas no topo de `FORWARD`.
- O estado original de `net.ipv4.ip_forward` é salvo uma vez e restaurado pelo purge.
- Restauração de backup aceita somente arquivos do diretório protegido `/var/backups/manager`.
- DNS usa `bind-dynamic` e pode atender `127.0.0.1`, `10.66.66.1` e `10.8.0.1` simultaneamente sem bind público.
- Alterações dos listeners DNS possuem rollback se o dnsmasq rejeitar a nova configuração.
- Purge preserva certificados Let's Encrypt, regras UFW, backups e pacotes do sistema para reduzir risco de perda de serviço.

## [0.2.0] - 2026-10-10

### Adicionado

- Menu principal reorganizado por Servidor, Segurança e Manutenção.
- WireGuard com instalação de servidor, geração/revogação de clientes e QR Code.
- Bloqueio de anúncios por DNS com dnsmasq, listas personalizadas e atualização automática.
- Fail2ban para proteção contra brute force SSH.
- Firewall UFW com proteção para não bloquear uma porta SSH detectada.
- Hardening conservador de OpenSSH usando `sshd_config.d`.
- Atualizações automáticas de segurança com `unattended-upgrades`.
- Diagnóstico de rede, DNS, SSH, NTP, recursos e serviços.
- Monitoramento de tráfego, conexões e suporte opcional ao vnStat.
- Visualizador central de logs.
- Backup de configurações gerenciadas, SHA-256 e snapshot antes de restauração.
- Rollback de versão do código com `manager-rollback`.
- Desinstalador conservador com `manager-uninstall` e modo explícito `--purge`.
- BBR + fq com armazenamento e restauração dos valores anteriores.
- Gestão SSH ampliada: sessões online, bloqueio/desbloqueio, desconexão de usuário e limite simultâneo.
- GitHub Actions com Bash syntax, ShellCheck, validação de versão e regressões de segurança.

### Segurança

- O projeto não usa `iptables -F`, `ip6tables -F` ou `nft flush ruleset`.
- O instalador não substitui o `sshd_config` inteiro.
- Alterações SSH são validadas com `sshd -t` antes de reload.
- DNS adblock recusa listener em endereço IPv4 público.
- Configurações WireGuard e chaves são armazenadas com permissões restritas.
- O instalador valida os scripts antes de substituir a versão ativa.
- A versão anterior do código é preservada localmente para rollback.

## [0.1.0] - 2026-10-10

### Adicionado

- Base inicial do MANAGER.
- Informações do sistema.
- Gestão básica de usuários SSH.
- Primeira versão do bloqueador DNS.
- Self-update.
