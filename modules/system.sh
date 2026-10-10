#!/usr/bin/env bash
set -Eeuo pipefail

MANAGER_HOME="${MANAGER_HOME:-/opt/manager}"
# shellcheck source=/dev/null
source "$MANAGER_HOME/lib/common.sh"
require_root

SERVICE_LABELS=(
  "OpenSSH"
  "dnsmasq"
  "WireGuard wg0"
  "OpenVPN MANAGER"
  "Fail2ban"
  "vnStat"
  "Adblock updater"
  "Certbot renewal"
  "SSH test cleanup"
  "APT security timer"
)

SERVICE_UNITS=(
  "ssh"
  "dnsmasq"
  "wg-quick@wg0"
  "openvpn-server@manager"
  "fail2ban"
  "vnstat"
  "manager-adblock-update.timer"
  "manager-certbot-renew.timer"
  "manager-test-users.timer"
  "apt-daily-upgrade.timer"
)

resolve_ssh_unit() {
  if systemctl list-unit-files ssh.service >/dev/null 2>&1; then
    printf 'ssh'
  else
    printf 'sshd'
  fi
}

normalized_unit() {
  local unit="$1"
  if [[ "$unit" == ssh ]]; then
    resolve_ssh_unit
  else
    printf '%s' "$unit"
  fi
}

unit_exists() {
  local unit
  unit="$(normalized_unit "$1")"
  systemctl show -p LoadState --value "$unit" 2>/dev/null | grep -qx 'loaded'
}

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
  say "\n${C_WHITE}SSH:${C_RESET} $(service_state "$(resolve_ssh_unit)")"
  pause
}

print_services() {
  local i unit
  for i in "${!SERVICE_UNITS[@]}"; do
    unit="$(normalized_unit "${SERVICE_UNITS[$i]}")"
    printf '%-30s %b\n' "${SERVICE_LABELS[$i]}" "$(service_state "$unit")"
  done
  if command_exists ufw; then
    printf '%-30s %s\n' "UFW" "$(ufw status 2>/dev/null | head -n1)"
  else
    printf '%-30s %s\n' "UFW" "não instalado"
  fi
}

show_services() {
  local interactive="${1:-yes}"
  [[ "$interactive" == yes ]] && header
  say "${C_WHITE}STATUS DE SERVIÇOS${C_RESET}\n"
  print_services
  say ""
  [[ "$interactive" == yes ]] && pause
}

service_action() {
  local action="$1" index="$2" unit label
  [[ "$index" =~ ^[0-9]+$ ]] || { err "Seleção inválida"; return 1; }
  (( index >= 1 && index <= ${#SERVICE_UNITS[@]} )) || { err "Seleção inválida"; return 1; }
  unit="$(normalized_unit "${SERVICE_UNITS[$((index - 1))]}")"
  label="${SERVICE_LABELS[$((index - 1))]}"
  unit_exists "$unit" || { err "$label não está instalado/carregado"; return 1; }

  case "$action" in
    restart)
      systemctl restart "$unit"
      ok "$label reiniciado"
      ;;
    start)
      systemctl start "$unit"
      ok "$label iniciado"
      ;;
    stop)
      if [[ "$unit" == "$(resolve_ssh_unit)" ]]; then
        err "O MANAGER não para o OpenSSH remotamente. Use restart/reload para evitar perder acesso."
        return 1
      fi
      systemctl stop "$unit"
      ok "$label parado"
      ;;
    *)
      err "Ação desconhecida"
      return 1
      ;;
  esac
}

service_menu() {
  local i opt action index
  while true; do
    header
    say "${C_WHITE}SERVIÇOS${C_RESET}\n"
    print_services
    say ""
    say " 1) Reiniciar serviço"
    say " 2) Iniciar serviço"
    say " 3) Parar serviço"
    say " 0) Voltar"
    say ""
    read -r -p "Opção: " opt
    case "$opt" in
      0) return ;;
      1) action=restart ;;
      2) action=start ;;
      3) action=stop ;;
      *) warn "Opção inválida"; sleep 1; continue ;;
    esac

    say ""
    for i in "${!SERVICE_UNITS[@]}"; do
      printf ' %2d) %s\n' "$((i + 1))" "${SERVICE_LABELS[$i]}"
    done
    say ""
    read -r -p "Serviço: " index
    if service_action "$action" "$index"; then
      sleep 1
    else
      pause
    fi
  done
}

case "${1:-info}" in
  info) show_info ;;
  services) show_services no ;;
  services-interactive) show_services yes ;;
  service-menu) service_menu ;;
  *) err "Ação inválida"; exit 2 ;;
esac
