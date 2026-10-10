#!/usr/bin/env bash
set -Eeuo pipefail

MANAGER_HOME="${MANAGER_HOME:-/opt/manager}"
# shellcheck source=/dev/null
source "$MANAGER_HOME/lib/common.sh"
require_root

show_unit() {
  local unit="$1" title="$2"
  header
  say "${C_WHITE}$title${C_RESET}\n"
  journalctl -u "$unit" --no-pager -n 120 2>/dev/null || warn "Sem registros para $unit"
  pause
}

ssh_failures() {
  header
  say "${C_WHITE}FALHAS RECENTES DE LOGIN SSH${C_RESET}\n"
  journalctl -u ssh -u sshd --since '24 hours ago' --no-pager 2>/dev/null \
    | grep -Ei 'failed password|invalid user|authentication failure|maximum authentication attempts' \
    | tail -n 120 || warn "Nenhuma falha encontrada nas últimas 24h"
  pause
}

kernel_network() {
  header
  say "${C_WHITE}KERNEL / REDE${C_RESET}\n"
  journalctl -k --since '24 hours ago' --no-pager 2>/dev/null \
    | grep -Ei 'wireguard|openvpn|tun|netfilter|nft|iptables|network|tcp|udp|drop|reject' \
    | tail -n 120 || true
  pause
}

certbot_logs() {
  header
  say "${C_WHITE}CERTBOT / LET'S ENCRYPT${C_RESET}\n"
  journalctl -u manager-certbot-renew --no-pager -n 100 2>/dev/null || true
  if [[ -f /var/log/letsencrypt/letsencrypt.log ]]; then
    say "\nÚltimas linhas do log do Certbot:"
    tail -n 80 /var/log/letsencrypt/letsencrypt.log || true
  fi
  pause
}

while true; do
  header
  say "${C_WHITE}LOGS${C_RESET}\n"
  say " 1) OpenSSH"
  say " 2) Falhas de login SSH (24h)"
  say " 3) Fail2ban"
  say " 4) WireGuard"
  say " 5) OpenVPN"
  say " 6) dnsmasq/adblock"
  say " 7) Certbot / TLS"
  say " 8) Kernel/rede"
  say " 0) Voltar"
  say ""
  read -r -p "Opção: " opt
  case "$opt" in
    1) show_unit ssh "OPENSSH" ;;
    2) ssh_failures ;;
    3) show_unit fail2ban "FAIL2BAN" ;;
    4) show_unit wg-quick@wg0 "WIREGUARD" ;;
    5) show_unit openvpn-server@manager "OPENVPN" ;;
    6) show_unit dnsmasq "DNSMASQ" ;;
    7) certbot_logs ;;
    8) kernel_network ;;
    0) exit 0 ;;
    *) warn "Opção inválida"; sleep 1 ;;
  esac
done
