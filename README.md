# MANAGER

Gerenciador moderno de VPS inspirado na experiência clássica do **SSHPlus Manager**, reconstruído para Debian/Ubuntu atuais.

> O objetivo não é executar cegamente binários antigos do SSHPlus. O MANAGER preserva as capacidades úteis, reimplementa o que envelheceu com código auditável e prepara uma arquitetura nova para Automation v2, Telegram e Modo Colmeia.

Versão atual: **0.5.0**.

## Princípios

- não substituir o `sshd_config` inteiro;
- não executar `iptables -F` ou `nft flush ruleset`;
- não baixar executáveis opacos como root;
- validar configurações antes de recarregar serviços;
- manter módulos opcionais realmente opcionais;
- criar backups/rollback antes de mudanças críticas;
- preservar configurações que não pertencem ao MANAGER sempre que possível;
- compatibilidade com o legado não significa copiar fragilidades do legado.

## Recursos atuais

### Servidor, SSH e VPN

- informações do sistema: SO, kernel, uptime, memória, disco, carga, IPs e serviços;
- usuários SSH: criar/remover, alterar senha, expiração, limite simultâneo, sessões online, bloqueio/desbloqueio e desconexão;
- **usuários teste** com duração em minutos e remoção automática por timer systemd;
- listagem e limpeza confirmada de usuários expirados;
- **banner SSH** por drop-in do OpenSSH, validado com `sshd -t`;
- WireGuard com servidor `wg0`, clientes, revogação, QR Code e NAT específico;
- OpenVPN moderno com PKI Easy-RSA, clientes `.ovpn`, CRL e UDP/TCP;
- DNS Ad Block com dnsmasq, whitelist/blacklist e atualização diária.

### Segurança

- hardening OpenSSH por `sshd_config.d`;
- Fail2ban;
- firewall UFW com proteção da porta SSH detectada;
- atualizações automáticas de segurança;
- TLS/Let's Encrypt via Certbot isolado;
- chaves públicas SSH com fingerprints e correção de permissões.

### Monitoramento e manutenção

- health check do servidor;
- diagnóstico de rede, DNS, SSH, NTP, recursos e serviços;
- tráfego/conexões e suporte opcional a vnStat;
- logs centralizados;
- backup e rollback de configurações gerenciadas;
- BBR + fq reversível;
- manutenção APT/NTP/journal;
- gerenciamento central de serviços;
- **Speedtest e ping**, com histórico local do Speedtest;
- self-update com validação de sintaxe;
- rollback da versão anterior do código;
- desinstalação conservadora e `--purge` separado.

## Usuários teste

A conta teste é uma conta SSH real com expiração em minutos.

O MANAGER:

1. gera ou aceita um nome de usuário;
2. gera uma senha aleatória;
3. mostra a senha uma única vez;
4. não salva essa senha em texto claro;
5. registra apenas os metadados de expiração em `/etc/manager/ssh-tests`;
6. usa `manager-test-users.timer` para remover a conta quando o prazo termina;
7. mantém uma expiração adicional no próprio sistema como proteção de retaguarda.

O timer continua funcionando após reboot.

## Expirados

Pelo menu de usuários é possível listar e remover contas expiradas. A limpeza destrutiva exige confirmação.

Consulta não interativa:

```bash
manager --expired
```

## Banner SSH

O MANAGER mantém seu banner em:

```text
/etc/manager/banner/banner.txt
```

Quando ativado, cria apenas:

```text
/etc/ssh/sshd_config.d/70-manager-banner.conf
```

Antes do reload, a configuração é validada com `sshd -t`. O MANAGER não substitui `/etc/issue.net` nem o `sshd_config` inteiro.

## Serviços

O menu **Serviços** mostra e permite iniciar/reiniciar/parar serviços conhecidos pelo MANAGER, como WireGuard, OpenVPN, dnsmasq e Fail2ban.

Por segurança, o MANAGER não oferece a ação de parar o OpenSSH pelo menu remoto.

O status não interativo continua disponível:

```bash
manager --status
```

## Speedtest

O cliente é opcional. O MANAGER pode instalar `speedtest-cli` pelos repositórios APT da distribuição.

Resultados executados pelo menu são registrados em:

```text
/var/log/manager/speedtest.log
```

O menu avisa antes do teste porque ele gera tráfego real de download/upload na VPS.

## Sistemas suportados

- Ubuntu 22.04 ou superior;
- Debian 12 ou superior;
- `systemd` e `apt` são obrigatórios nesta implementação.

O roadmap inclui ampliação explícita dos testes para as distribuições modernas de 2026.

## Instalação

Para evitar executar conteúdo remoto diretamente por pipe, baixe o instalador e execute-o:

```bash
sudo -i
curl -fL --proto '=https' --tlsv1.2 \
  https://raw.githubusercontent.com/SrTristeSad/MANAGER/main/install.sh \
  -o /tmp/manager-install.sh
bash -n /tmp/manager-install.sh
bash /tmp/manager-install.sh
rm -f /tmp/manager-install.sh
```

Depois:

```bash
manager
```

O alias clássico também funciona:

```bash
menu
```

## CLI

```text
manager --health        health check (0=OK, 1=aviso, 2=crítico)
manager --status        status dos serviços sem abrir menu
manager --expired       lista contas SSH expiradas
manager --diagnostics   diagnóstico
manager --version       versão
manager --help          ajuda
```

## Menu principal

```text
SERVIDOR E VPN
 1) Informações do sistema
 2) Usuários SSH
 3) WireGuard VPN
 4) OpenVPN
 5) Bloqueio de anúncios DNS
19) Banner SSH

SEGURANÇA
 6) Segurança / hardening SSH
 7) Firewall
 8) Fail2ban
 9) TLS / Let's Encrypt
18) Chaves públicas SSH

MONITORAMENTO E MANUTENÇÃO
10) Tráfego e conexões
11) Diagnóstico
12) Backup e rollback
13) Desempenho / BBR
14) Logs
15) Assistente / perfis
16) Saúde do servidor
17) Manutenção do sistema
20) Serviços
21) Speedtest / latência

90) Atualizar MANAGER
 0) Sair
```

## Backup

Backups ficam em:

```text
/var/backups/manager/
```

Eles têm permissão restrita e podem conter chaves privadas de VPN. A versão 0.5 também inclui no backup o estado do banner e os metadados/timers de contas teste.

A restauração valida escopo e SHA-256 antes de extrair o arquivo e cria um snapshot adicional do estado atual.

## Atualização e rollback

O instalador baixa todos os arquivos para uma área temporária e executa `bash -n` antes de alterar a instalação ativa.

A versão anterior do código é preservada em:

```text
/opt/manager.rollback
```

Rollback:

```bash
manager-rollback
```

Desinstalar código preservando configuração:

```bash
manager-uninstall
```

Remover também o estado gerenciado:

```bash
manager-uninstall --purge
```

O purge remove timers/drop-ins criados pelo MANAGER e contas **teste** ainda registradas, mas não apaga usuários SSH comuns apenas porque foram administrados pelo MANAGER.

## Próximas etapas

O plano completo está em [`docs/ROADMAP.md`](docs/ROADMAP.md).

Resumo:

```text
0.5.x  paridade SSHPlus útil
0.6.0  Connection Engine
0.7.0  Legacy v1 + Automation v2
0.8.0  Modo Colmeia
0.9.0  Telegram Bot + Mini App
0.9.5  migração e escala
1.0.0  release de produção
```

### Legacy

O futuro **Legacy v1** será uma única conexão compatível com o antigo ecossistema `syncpainel`; não haverá uma implementação separada por versão de painel.

Ele será opcional e **desligado por padrão** em instalações novas.

### Modo Colmeia

A Colmeia poderá reunir servidores no mesmo país, cidade/datacenter ou em vários países. O scheduler planejado distribuirá novas sessões conforme capacidade, CPU, RAM, rede, número de sessões, saúde, protocolo e peso do nó.

Também estão planejados sticky sessions, drain para manutenção, failover, sessão global por identidade e comunicação autenticada/criptografada entre os componentes.

### Telegram

A administração remota futura será baseada em **Telegram Bot + Telegram Mini App**, sem painel web administrativo convencional. Identidade e permissões serão verificadas no backend.

## Testes

O CI executa:

- `bash -n`;
- ShellCheck;
- regressões contra padrões destrutivos conhecidos;
- política de fonte segura do instalador;
- instalação/update/rollback/uninstall em smoke test;
- checks não interativos do MANAGER.

O roteiro para VPS real está em:

```text
docs/TESTING.md
```

## Origem

O SSHPlus Manager original foi desenvolvido por **@crazy_vpn** e deu origem a vários forks comunitários. Este projeto preserva a ideia de administração simples por terminal enquanto substitui implementações obsoletas e prepara uma arquitetura moderna para automação e operação multi-servidor.
