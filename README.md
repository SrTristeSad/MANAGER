# MANAGER

Gerenciador moderno de VPS inspirado na experiência clássica do **SSHPlus Manager**, refeito para sistemas Debian/Ubuntu atuais.

> O objetivo não é executar cegamente binários antigos do SSHPlus. O MANAGER reaproveita a ideia do menu simples e reconstrói as funções com código auditável, systemd e pacotes oficiais da distribuição.

## Princípios

- Não substituir o `sshd_config` inteiro.
- Não executar `iptables -F`/`nft flush ruleset`.
- Não baixar executáveis opacos como root.
- Validar configurações antes de recarregar serviços.
- Manter módulos opcionais realmente opcionais.
- Criar backups/rollback antes de mudanças críticas.
- Preservar configurações que não pertencem ao MANAGER sempre que possível.

## Recursos

### Servidor

- **Informações do sistema**: SO, kernel, uptime, memória, disco, carga, IPs e serviços.
- **Usuários SSH**: criar/remover contas, senha, expiração e limite de logins simultâneos.
- **WireGuard**: instala `wg0`, cria/revoga clientes, gera configuração e QR Code.
- **DNS Ad Block**: dnsmasq + listas de bloqueio, whitelist via fontes personalizadas e atualização diária.

### Segurança

- **Hardening OpenSSH** por drop-in em `sshd_config.d`, validado com `sshd -t` antes do reload.
- **Fail2ban** para proteção contra brute force SSH.
- **Firewall UFW** com proteção para não bloquear uma porta SSH detectada.
- **Atualizações automáticas de segurança** com `unattended-upgrades`.

### Monitoramento e manutenção

- **Diagnóstico** de internet, DNS, SSH, NTP, disco, memória, forwarding e serviços.
- **Tráfego** por interface, conexões ativas e histórico opcional com vnStat.
- **Logs** centralizados de SSH, Fail2ban, WireGuard, dnsmasq e kernel/rede.
- **Backup e rollback** das configurações gerenciadas pelo projeto.
- **BBR + fq** como tuning de rede conservador, somente quando o kernel suportar.
- **Self-update** com validação de sintaxe antes de substituir o código instalado.

## Sistemas suportados

- Ubuntu 22.04 ou superior.
- Debian 12 ou superior.
- `systemd` e `apt` são obrigatórios nesta implementação.

## Instalação

```bash
sudo -i
curl -fsSL https://raw.githubusercontent.com/SrTristeSad/MANAGER/main/install.sh | bash
```

Depois execute:

```bash
manager
```

O alias clássico também funciona:

```bash
menu
```

## Menu principal

```text
SERVIDOR
 1) Informações do sistema
 2) Usuários SSH
 3) WireGuard VPN
 4) Bloqueio de anúncios DNS

SEGURANÇA
 5) Segurança / hardening SSH
 6) Firewall
 7) Fail2ban

MONITORAMENTO E MANUTENÇÃO
 8) Tráfego e conexões
 9) Diagnóstico
10) Backup e rollback
11) Desempenho / BBR
12) Logs
20) Status dos serviços
90) Atualizar MANAGER
```

## WireGuard

O módulo usa pacotes oficiais `wireguard`/`wireguard-tools` e o serviço `wg-quick@wg0`. A rede padrão criada pelo MANAGER é `10.66.66.0/24`.

As regras de encaminhamento/NAT são adicionadas especificamente para a interface WireGuard e removidas individualmente no `PostDown`. O MANAGER não limpa o firewall da VPS.

Configurações de clientes ficam em:

```text
/etc/manager/wireguard/clients/
```

Esses arquivos contêm chaves privadas e têm permissão `0600`.

## DNS Ad Block

O bloqueador utiliza `dnsmasq`. Inicialmente ele escuta apenas em `127.0.0.1`; depois você pode selecionar um IP privado/VPN atribuído ao servidor.

O módulo se recusa a configurar um endereço público como listener, reduzindo o risco de criar um resolver DNS aberto.

Fontes de bloqueio:

```text
/etc/manager/adblock/sources.list
```

## Backup

Backups locais são armazenados em:

```text
/var/backups/manager/
```

Eles incluem apenas configurações relacionadas ao MANAGER, como WireGuard, adblock, limites SSH e drop-ins de segurança. Antes de restaurar um backup, um snapshot adicional da configuração atual é criado.

## Atualização e rollback de código

O instalador baixa todos os arquivos para uma área temporária e executa `bash -n` antes de alterar a instalação ativa.

Durante uma atualização, a versão anterior do código é preservada em:

```text
/opt/manager.rollback
```

O estado e as configurações permanentes ficam em `/etc/manager` e não são apagados pelo updater.

## Estrutura

```text
manager                         menu principal
install.sh                      instalador/updater
lib/common.sh                   helpers compartilhados
modules/system.sh               informações e serviços
modules/ssh_users.sh            usuários SSH
modules/wireguard.sh            WireGuard
modules/adblock.sh              bloqueio DNS
modules/security.sh             hardening SSH / updates
modules/firewall.sh             UFW
modules/fail2ban.sh             Fail2ban
modules/diagnostics.sh          diagnóstico
modules/backup.sh               backup/restore
modules/traffic.sh              tráfego/vnStat
modules/performance.sh          BBR/fq
modules/logs.sh                 logs
VERSION                         versão atual
```

## Segurança operacional

O MANAGER roda como root porque administra serviços do sistema. Por isso, cada módulo deve ser pequeno, legível e limitado ao recurso que gerencia.

Recomenda-se testar versões novas primeiro em uma VPS descartável ou snapshot da VPS. Firewalls de provedores/cloud continuam sendo independentes do firewall local.

## Origem

O SSHPlus Manager original foi desenvolvido por **@crazy_vpn** e deu origem a muitos forks comunitários. Este projeto preserva a ideia de uma administração simples por terminal, mas substitui implementações obsoletas e práticas arriscadas por uma base moderna.
