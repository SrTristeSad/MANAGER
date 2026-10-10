#!/usr/bin/env bash
set -Eeuo pipefail

MANAGER_HOME="${MANAGER_HOME:-/opt/manager}"
# shellcheck source=/dev/null
source "$MANAGER_HOME/lib/common.sh"
require_root

show_info() {
  header
  say "${C_WHITE}INFORMAÇÕES DO SISTEMA${C_RESET}\n"

  local pretty="Linux"
  if [[ -r /etc/os-release ]]; then
    # shellcheck source=/dev/null
    source /etc/os-release
    pretty="${PRETTY_NAME:-$ID}"
  fi

  local mem disk load uptime_s public_ip cpu cores
  mem="$(free -h | awk '/^Mem:/ {print $3 " / " $2}')"
  disk="$(df -h / | awk 'NR==2 {print $3 " / " $2 " (" $5 ")"}')"
  load="$(awk '{print $1", "$2", "$3}' /proc/loadavg)"
  uptime_s="$(uptime -p 2>/dev/null || true)"
  public_ip="$(curl -4fsS --max-time 3 https://api.ipify.org 2>/dev/null || echo 'indisponível')"
  cpu="$(lscpu 2>/dev/null | awk -F: '/Model name/ {gsub(/^[ \t]+/,"",$2); print $2; exit}')"
  cores="$(nproc 2>/dev/null || echo '?')"

  printf '%-18s %s\n' "Sistema:" "$pretty"
  printf '%-18s %s\n' "Kernel:" "$(uname -r)"
  printf '%-18s %s\n' "Arquitetura:" "$(uname -m)"
  printf '%-18s %s\n' "CPU:" "${cpu:-indisponível} ($cores vCPU)"
  printf '%-18s %s\n' "Hostname:" "$(hostname)"
  printf '%-18s %s\n' "Uptime:" "$uptime_s"
  printf '%-18s %s\n' "Carga:" "$load"
  printf '%-18s %s\n' "Memória:" "$mem"
  printf '%-18s %s\n' "Disco /:" "$disk"
  printf '%-18s %s\n' "IP público:" "$public_ip"
  say "\n${C_WHITE}Endereços locais:${C_RESET}"
  ip -o -4 addr show scope global | awk '{print "  " $2 ": " $4}' || true
  say "\n${C_WHITE}Rota padrão:${C_RESET}"
  ip -4 route show default | sed 's/^/  /' || true
  say "\n${C_WHITE}SSH:${C_RESET} $(service_state ssh)"
  pause
}

show_services() {
  header
  say "${C_WHITE}STATUS DE SERVIÇOS${C_RESET}\n"
  printf '%-28s %b\n' "OpenSSH" "$(service_state ssh)"
  printf '%-28s %b\n' "dnsmasq" "$(service_state dnsmasq)"
  printf '%-28s %b\n' "WireGuard wg0" "$(service_state wg-quick@wg0)"
  printf '%-28s %b\n' "Fail2ban" "$(service_state fail2ban)"
  printf '%-28s %b\n' "vnStat" "$(service_state vnstat)"
  printf '%-28s %b\n' "OpenVPN" "$(service_state openvpn)"
  printf '%-28s %b\n' "Adblock updater" "$(service_state manager-adblock-update.timer)"
  printf '%-28s %b\n' "APT security timer" "$(service_state apt-daily-upgrade.timer)"
  say ""
  if command_exists ufw; then
    printf '%-28s %s\n' "UFW" "$(ufw status 2>/dev/null | head -n1)"
  else
    printf '%-28s %s\n' "UFW" "não instalado"
  fi
  say ""
  pause
}

case "${1:-info}" in
  info) show_info ;;
  services) show_services ;;
  *) err "Ação inválida"; exit 2 ;;
esac
