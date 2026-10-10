# Teste de fumaça em VPS

Este roteiro valida o MANAGER em uma máquina real sem começar pelas funções mais destrutivas.

## Ambiente recomendado

Use uma VPS descartável ou um snapshot recente com:

- Ubuntu 24.04 LTS, ou
- Debian 12/13.

Mantenha o console web/serial do provedor disponível e, ao testar SSH/firewall, deixe uma segunda sessão SSH aberta.

## 1. Instalação

```bash
sudo -i
curl -fsSL https://raw.githubusercontent.com/SrTristeSad/MANAGER/main/install.sh | bash
manager
```

Confirme:

```bash
command -v manager
command -v menu
command -v manager-rollback
command -v manager-uninstall
cat /opt/manager/VERSION
```

## 2. Diagnóstico inicial

No menu, abra **Diagnóstico** e execute o diagnóstico geral.

Antes de continuar, confirme que:

- a rota padrão existe;
- DNS resolve nomes;
- OpenSSH está ativo;
- `sshd -t` é válido;
- há espaço em disco suficiente.

## 3. Backup inicial

Abra **Backup e rollback** e crie um backup. Depois verifique a integridade.

O arquivo deve existir em:

```text
/var/backups/manager/
```

Não copie esse arquivo para locais públicos: depois que VPNs forem configuradas ele poderá conter chaves privadas.

## 4. Usuário SSH de teste

Crie um usuário temporário com limite 1 e confirme login em uma segunda sessão.

Teste:

- alteração de senha;
- expiração;
- limite simultâneo;
- sessões online;
- bloquear/desbloquear;
- desconectar usuário.

Não faça esses testes com `root`.

## 5. Hardening e Fail2ban

Aplique o hardening do SSH. O módulo deve executar `sshd -t` antes do reload.

Em seguida, instale Fail2ban e confira:

```bash
fail2ban-client status sshd
```

## 6. Firewall

Antes de ativar UFW:

1. deixe uma segunda sessão SSH aberta;
2. confirme a porta SSH efetiva;
3. tenha acesso ao console do provedor.

Depois de ativar:

```bash
ufw status verbose
ss -lntup
```

## 7. WireGuard

Instale o WireGuard, crie um cliente e teste o QR Code/configuração.

No servidor:

```bash
systemctl status wg-quick@wg0 --no-pager
wg show
ip addr show wg0
sysctl net.ipv4.ip_forward
```

No cliente, confirme:

- handshake;
- acesso à internet;
- IP público da VPS quando `AllowedIPs = 0.0.0.0/0`.

## 8. OpenVPN

Instale o OpenVPN primeiro em UDP. Crie um perfil `.ovpn` e importe em um cliente compatível.

No servidor:

```bash
systemctl status openvpn-server@manager --no-pager
ip addr show tun0
cat /run/openvpn/manager-status.log
```

Depois teste também TCP em uma VPS descartável ou após remover a instância anterior.

## 9. DNS Ad Block

Instale o Ad Block. Ele deve começar apenas em `127.0.0.1`.

Com as VPNs ativas, use **Gerenciar listeners privados/VPN** e adicione automaticamente:

```text
10.66.66.1   WireGuard
10.8.0.1     OpenVPN
```

Confirme:

```bash
dnsmasq --test
ss -lnutp | grep ':53 '
```

Nunca deve aparecer o IP público da VPS como listener configurado pelo MANAGER.

Teste a resolução a partir de cada VPN e depois whitelist/blacklist manual.

As estatísticas de consultas DNS devem permanecer desligadas, a menos que você as ative conscientemente.

## 10. BBR

Anote os valores anteriores:

```bash
sysctl net.ipv4.tcp_congestion_control
sysctl net.core.default_qdisc
```

Ative BBR/fq pelo menu e depois use a opção de restauração. Os valores anteriores devem voltar imediatamente.

## 11. TLS / Let's Encrypt

Use um domínio real apontando para a VPS.

Para `standalone`, a porta 80 precisa estar livre e acessível da internet. Se já houver Nginx/Apache, prefira `webroot`.

Após emissão:

```bash
certbot certificates
systemctl status manager-certbot-renew.timer --no-pager
certbot renew --dry-run
```

## 12. Atualização e rollback

Depois que houver duas versões instaladas/testadas:

```bash
manager-rollback
```

Confirme que `/opt/manager/VERSION` mudou e que o menu ainda abre.

## 13. Desinstalação

Primeiro teste a remoção conservadora:

```bash
manager-uninstall
```

Ela deve remover o código sem apagar configurações dos serviços.

Em uma VPS descartável, reinstale e teste:

```bash
manager-uninstall --purge
```

O purge deve exigir a palavra `PURGAR`, remover somente configurações pertencentes ao MANAGER e preservar pacotes do sistema, certificados Let's Encrypt, backups e regras UFW.

## Critérios para marcar uma versão como estável

Uma versão só deve ser marcada como estável depois de passar, em pelo menos Ubuntu 24.04 e Debian 12/13:

- GitHub Actions verde;
- instalação limpa;
- reexecução do instalador/update;
- criação e login de usuário SSH;
- hardening sem perder acesso;
- Fail2ban;
- UFW sem lockout;
- WireGuard cliente real;
- OpenVPN cliente real;
- DNS em WireGuard e OpenVPN simultaneamente;
- backup + restore;
- BBR + rollback;
- `manager-rollback`;
- `manager-uninstall` e `--purge`.
