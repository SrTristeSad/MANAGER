#!/usr/bin/env bash
set -Eeuo pipefail

MANAGER_HOME="${MANAGER_HOME:-/opt/manager}"
# shellcheck source=/dev/null
source "$MANAGER_HOME/lib/common.sh"
require_root

interfaces() {
  ip -o link show | awk -F': ' '$2!="lo" {sub(/@.*/,"",$2); print $2}'
}

live_stats() {
  header
  say "${C_WHITE}TRÁFEGO POR INTERFACE${C_RESET}\n"
  printf '%-16s %16s %16s\n' "INTERFACE" "RX" "TX"
  local dev rx tx
  while read -r dev; do
    [[ -r "/sys/class/net/$dev/statistics/rx_bytes" ]] || continue
    rx="$(numfmt --to=iec-i --suffix=B "$(cat "/sys/class/net/$dev/statistics/rx_bytes")")"
    tx="$(numfmt --to=iec-i --suffix=B "$(cat "/sys/class/net/$dev/statistics/tx_bytes")")"
    printf '%-16s %16s %16s\n' "$dev" "$rx" "$tx"
  done < <(interfaces)
  say "\nConexões estabelecidas: $(ss -Htan state established 2>/dev/null | wc -l)"
  pause
}

install_vnstat() {
  header
  confirm "Instalar vnStat para histórico diário/mensal de banda?" || return
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y vnstat
  systemctl enable --now vnstat
  ok "vnStat instalado. As estatísticas históricas começam a ser coletadas agora."
  pause
}

vnstat_report() {
  header
  command_exists vnstat || { err "vnStat não instalado"; pause; return; }
  local dev
  dev="$(ip -4 route show default | awk 'NR==1 {print $5}')"
  say "${C_WHITE}VNSTAT - ${dev:-interface padrão}${C_RESET}\n"
  if [[ -n "$dev" ]]; then vnstat -i "$dev" 2>/dev/null || vnstat; else vnstat; fi
  pause
}

connections() {
  header
  say "${C_WHITE}CONEXÕES ATIVAS${C_RESET}\n"
  ss -Htunap state established 2>/dev/null | sed -n '1,100p' || true
  pause
}

top_processes() {
  header
  say "${C_WHITE}PROCESSOS COM SOCKETS DE REDE${C_RESET}\n"
  ss -lntup 2>/dev/null | sed -n '1,100p' || true
  pause
}

identity_usage() {
  if [[ -x "$MANAGER_HOME/modules/identity_usage.sh" ]]; then
    "$MANAGER_HOME/modules/identity_usage.sh"
  else
    err "Módulo de uso por identidade não está instalado"
    pause
  fi
}

while true; do
  header
  say "${C_WHITE}TRÁFEGO E CONEXÕES${C_RESET}\n"
  say " 1) Contadores por interface"
  say " 2) Conexões estabelecidas"
  say " 3) Processos/portas em escuta"
  say " 4) Instalar vnStat"
  say " 5) Relatório vnStat"
  say " 6) Uso e atividade por identidade"
  say " 0) Voltar"
  say ""
  read -r -p "Opção: " opt
  case "$opt" in
    1) live_stats ;;
    2) connections ;;
    3) top_processes ;;
    4) install_vnstat ;;
    5) vnstat_report ;;
    6) identity_usage ;;
    0) exit 0 ;;
    *) warn "Opção inválida"; sleep 1 ;;
  esac
done
