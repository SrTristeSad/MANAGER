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

  local mem disk load uptime_s public_ip
  mem="$(free -h | awk '/^Mem:/ {print $3 " / " $2}')"
  disk="$(df -h / | awk 'NR==2 {print $3 " / " $2 " (" $5 ")"}')"
  load="$(awk '{print $1", "$2", "$3}' /proc/loadavg)"
  uptime_s="$(uptime -p 2>/dev/null || true)"
  public_ip="$(curl -4fsS --max-time 3 https://api.ipify.org 2>/dev/null || echo 'indisponível')"

  printf '%-18s %s\n' "Sistema:" "$pretty"
  printf '%-18s %s\n' "Kernel:" "$(uname -r)"
  printf '%-18s %s\n' "Arquitetura:" "$(uname -m)"
  printf '%-18s %s\n' "Hostname:" "$(hostname)"
  printf '%-18s %s\n' "Uptime:" "$uptime_s"
  printf '%-18s %s\n' "Carga:" "$load"
  printf '%-18s %s\n' "Memória:" "$mem"
  printf '%-18s %s\n' "Disco /:" "$disk"
  printf '%-18s %s\n' "IP público:" "$public_ip"
  say "\n${C_WHITE}Endereços locais:${C_RESET}"
  ip -o -4 addr show scope global | awk '{print "  " $2 ": " $4}' || true
  say "\n${C_WHITE}SSH:${C_RESET} $(service_state ssh)"
  pause
}

show_services() {
  header
  say "${C_WHITE}STATUS DE SERVIÇOS${C_RESET}\n"
  printf '%-22s %b\n' "OpenSSH" "$(service_state ssh)"
  printf '%-22s %b\n' "dnsmasq" "$(service_state dnsmasq)"
  printf '%-22s %b\n' "OpenVPN" "$(service_state openvpn)"
  printf '%-22s %b\n' "WireGuard" "$(service_state wg-quick@wg0)"
  printf '%-22s %b\n' "Fail2ban" "$(service_state fail2ban)"
  say ""
  pause
}

case "${1:-info}" in
  info) show_info ;;
  services) show_services ;;
  *) err "Ação inválida"; exit 2 ;;
esac
