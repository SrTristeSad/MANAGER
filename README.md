# MANAGER

Gerenciador moderno de VPS inspirado na experiência clássica do **SSHPlus Manager**, refeito para Debian/Ubuntu atuais.

> O objetivo não é executar cegamente binários antigos do SSHPlus. O MANAGER preserva a ideia do menu simples e reconstrói as funções com código auditável, systemd e pacotes oficiais da distribuição.

## Princípios

- Não substituir o `sshd_config` inteiro.
- Não executar `iptables -F`/`nft flush ruleset`.
- Não baixar executáveis opacos como root.
- Validar configurações antes de recarregar serviços.
- Manter módulos opcionais realmente opcionais.
- Criar backups/rollback antes de mudanças críticas.
- Preservar configurações que não pertencem ao MANAGER sempre que possível.
- Compatibilidade com o legado não significa reproduzir práticas inseguras do legado.

## Recursos

### Servidor, SSH e VPN

- **Informações do sistema**: SO, kernel, uptime, memória, disco, carga, IPs e serviços.
- **Usuários SSH**: criar/remover contas, senha, expiração, limite simultâneo, sessões online, bloquear/desbloquear e desconectar usuário.
- **Chaves SSH**: listar, adicionar e remover chaves públicas, fingerprints e correção segura de permissões.
- **WireGuard**: servidor `wg0`, clientes, revogação, QR Code e NAT específico da VPN.
- **OpenVPN**: servidor moderno em `/etc/openvpn/server`, PKI Easy-RSA, clientes `.ovpn`, CRL e UDP/TCP.
- **DNS Ad Block**: dnsmasq, fontes externas, whitelist/blacklist manuais e atualização diária.
- **DNS multi-VPN**: listeners privados simultâneos para loopback, WireGuard e OpenVPN sem bind na interface pública.
- **Estatísticas DNS opcionais**: desligadas por padrão por privacidade.

### Segurança

- **Hardening OpenSSH** por drop-in em `sshd_config.d`, validado com `sshd -t` antes do reload.
- **Fail2ban** para proteção contra brute force SSH.
- **Firewall UFW** com proteção para não bloquear uma porta SSH detectada.
- **Atualizações automáticas de segurança** com `unattended-upgrades`.
- **TLS/Let's Encrypt** via Certbot isolado, com emissão standalone/webroot e renovação automática.
- **Política de download do instalador**: HTTPS em uso normal; `file://` apenas para CI/teste local explicitamente autorizado.

### Monitoramento e manutenção

- **Saúde do servidor**: disco, inodes, memória, carga, systemd, SSH, rota, DNS, atualizações, UFW e Fail2ban.
- **Health não interativo**: `manager --health` retorna `0` saudável, `1` avisos e `2` crítico.
- **Diagnóstico** de internet, DNS, SSH, NTP, disco, memória, VPNs, forwarding e serviços.
- **Tráfego** por interface, conexões ativas e histórico opcional com vnStat.
- **Logs** centralizados de SSH, Fail2ban, WireGuard, OpenVPN, dnsmasq, Certbot e kernel/rede.
- **Manutenção**: atualização APT, unattended-upgrades, limpeza segura, journal, NTP e reboot explícito.
- **Backup e rollback** das configurações gerenciadas pelo projeto.
- **BBR + fq reversível**: guarda congestion control/qdisc anteriores e restaura quando solicitado.
- **Self-update** com download temporário e validação de sintaxe antes de executar o instalador.
- **Rollback de código** para a versão anterior instalada.
- **Desinstalação conservadora**, com `--purge` separado para configurações.
- **Assistente de perfis**: servidor seguro, WireGuard, OpenVPN, DNS e configuração completa.

## Sistemas suportados

- Ubuntu 22.04 ou superior.
- Debian 12 ou superior.
- `systemd` e `apt` são obrigatórios nesta implementação.

A matriz de testes será ampliada conforme o roadmap para cobrir as versões modernas suportadas pelo projeto.

## Instalação

Baixe o instalador por HTTPS, valide que ele existe e execute localmente:

```bash
curl -fL --proto '=https' --tlsv1.2 \
  https://raw.githubusercontent.com/SrTristeSad/MANAGER/main/install.sh \
  -o /tmp/manager-install.sh
sudo bash /tmp/manager-install.sh
rm -f /tmp/manager-install.sh
```

Depois execute:

```bash
manager
```

O alias clássico também funciona:

```bash
menu
```

## CLI

```text
manager                 abre o menu interativo
manager --health        health check não interativo
manager --status        status resumido dos serviços
manager --diagnostics   abre o diagnóstico
manager --version       mostra a versão
manager --help          mostra a ajuda
```

## Comandos de recuperação

Voltar o **código** para a versão anterior preservada pelo updater:

```bash
manager-rollback
```

Remover apenas o código do MANAGER, preservando configurações e serviços:

```bash
manager-uninstall
```

Remover também as configurações criadas pelo MANAGER:

```bash
manager-uninstall --purge
```

O `--purge` exige confirmação explícita. Pacotes do sistema, certificados Let's Encrypt, backups e regras UFW são preservados para reduzir o risco de perda de acesso ou de serviço.

## Menu principal

```text
SERVIDOR E VPN
 1) Informações do sistema
 2) Usuários SSH
 3) WireGuard VPN
 4) OpenVPN
 5) Bloqueio de anúncios DNS

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
20) Status dos serviços

90) Atualizar MANAGER
 0) Sair
```

## WireGuard

O módulo usa `wireguard`/`wireguard-tools` e `wg-quick@wg0`. A rede padrão criada pelo MANAGER é `10.66.66.0/24`.

As regras de encaminhamento/NAT são específicas para a interface/sub-rede WireGuard, inseridas sem limpar regras existentes e removidas individualmente quando a VPN para. O MANAGER não limpa o firewall da VPS.

Perfis de clientes ficam em:

```text
/etc/manager/wireguard/clients/
```

## OpenVPN

O OpenVPN usa uma instância própria chamada `manager` e não sobrescreve uma configuração existente em `/etc/openvpn/server/manager.conf`.

A rede padrão é `10.8.0.0/24`. A PKI fica em `/etc/manager/openvpn/easy-rsa` e os perfis de cliente em:

```text
/etc/manager/openvpn/clients/
```

O módulo gera certificados individuais, mantém CRL e permite revogar clientes. Quando o Ad Block estiver escutando em `10.8.0.1`, a VPN pode ser configurada para entregá-lo como DNS aos clientes.

## DNS Ad Block

O bloqueador utiliza `dnsmasq`. Inicialmente ele escuta apenas em `127.0.0.1`.

Depois, o menu de listeners permite adicionar simultaneamente endereços privados/VPN atribuídos ao servidor. Para as VPNs do MANAGER, os endereços padrão são:

```text
127.0.0.1    loopback obrigatório
10.66.66.1   WireGuard
10.8.0.1     OpenVPN
```

O módulo usa `bind-dynamic` para acompanhar interfaces VPN que podem subir/descer e se recusa a adicionar um IPv4 público como listener. Assim, WireGuard e OpenVPN podem usar o mesmo bloqueador sem transformar a VPS em resolver DNS público.

Arquivos principais:

```text
/etc/manager/adblock/sources.list
/etc/manager/adblock/whitelist.txt
/etc/manager/adblock/blacklist.txt
/etc/manager/adblock/listen-addresses.txt
```

O log de consultas usado para estatísticas é opcional. Ao ativá-lo, o MANAGER avisa que nomes consultados pelos clientes passarão a aparecer no journal.

## TLS / Let's Encrypt

O Certbot é instalado em `/opt/certbot` usando um virtualenv isolado. O MANAGER oferece:

- `standalone`, somente quando a porta 80 está livre;
- `webroot`, quando já existe um servidor HTTP;
- teste de renovação;
- renovação manual;
- timer systemd duas vezes ao dia.

O MANAGER não edita automaticamente configurações de Nginx/Apache.

## Backup

Backups locais são armazenados em:

```text
/var/backups/manager/
```

Eles têm permissão restrita e podem conter chaves privadas das VPNs. A restauração aceita somente arquivos dentro desse diretório e, antes de restaurar, cria um snapshot adicional da configuração atual.

## Atualização e rollback de código

O instalador baixa todos os arquivos para uma área temporária e executa `bash -n` antes de alterar a instalação ativa.

Em uso normal, a origem do instalador deve ser HTTPS. `file://` só é permitido para CI ou quando um teste local ativa explicitamente `MANAGER_ALLOW_FILE_SOURCE=1`.

Durante uma atualização, a versão anterior do código é preservada em:

```text
/opt/manager.rollback
```

O estado permanente fica em `/etc/manager` e não é apagado pelo updater.

## Roadmap

A evolução planejada até 1.0 está documentada em:

```text
docs/ROADMAP.md
```

O plano inclui paridade útil com SSHPlus, Connection Engine, Automation Legacy desligável, Automation v2, Modo Colmeia com balanceamento e sessões globais, além de Telegram Bot + Mini App.

## Teste antes de chamar de estável

O roteiro de validação em VPS real está em:

```text
docs/TESTING.md
```

Ele cobre instalação, SSH, Fail2ban, UFW, WireGuard, OpenVPN, DNS simultâneo, BBR, TLS, backup/restore, rollback e desinstalação.

## Estrutura

```text
manager                         menu principal
install.sh                      instalador/updater
rollback.sh                     rollback da versão do código
uninstall.sh                    desinstalador
lib/common.sh                   helpers compartilhados
modules/system.sh               informações e serviços
modules/ssh_users.sh            usuários e sessões SSH
modules/ssh_keys.sh             chaves públicas SSH
modules/wireguard.sh            WireGuard
modules/openvpn.sh              OpenVPN / Easy-RSA
modules/adblock.sh              bloqueio DNS / listas / stats
modules/security.sh             hardening SSH / updates
modules/firewall.sh             UFW
modules/fail2ban.sh             Fail2ban
modules/tls.sh                  Certbot / Let's Encrypt
modules/diagnostics.sh          diagnóstico
modules/health.sh               saúde do servidor
modules/maintenance.sh          manutenção do sistema
modules/backup.sh               backup/restore
modules/traffic.sh              tráfego/vnStat
modules/performance.sh          BBR/fq reversível
modules/logs.sh                 logs
modules/profiles.sh             assistente guiado
VERSION                         versão atual
CHANGELOG.md                    histórico de versões
SECURITY.md                     política de segurança
docs/TESTING.md                 roteiro de teste real
docs/ROADMAP.md                 plano de evolução até 1.0
```

## Segurança operacional

O MANAGER roda como root porque administra serviços do sistema. Cada módulo deve ser pequeno, legível, limitado ao recurso que gerencia e reversível sempre que possível.

Recomenda-se testar versões novas primeiro em uma VPS descartável ou snapshot da VPS. Firewalls de provedores/cloud continuam sendo independentes do firewall local.

O CI verifica sintaxe Bash, ShellCheck, formato da versão, política de origem do instalador e padrões destrutivos conhecidos. Testes estáticos não substituem um teste real de systemd, PAM, netfilter, WireGuard, OpenVPN e ACME.

## Origem

O SSHPlus Manager original foi desenvolvido por **@crazy_vpn** e deu origem a muitos forks comunitários. Este projeto preserva a ideia de administração simples por terminal, mas substitui implementações obsoletas e práticas arriscadas por uma base moderna.
