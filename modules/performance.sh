#!/usr/bin/env bash
set -Eeuo pipefail

MANAGER_HOME="${MANAGER_HOME:-/opt/manager}"
# shellcheck source=/dev/null
source "$MANAGER_HOME/lib/common.sh"
require_root

SYSCTL_FILE="/etc/sysctl.d/99-manager-performance.conf"

show_status() {
  header
  say "${C_WHITE}DESEMPENHO DE REDE${C_RESET}\n"
  printf '%-28s %s\n' "Congestion control:" "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '-')"
  printf '%-28s %s\n' "Qdisc padrão:" "$(sysctl -n net.core.default_qdisc 2>/dev/null || echo '-')"
  printf '%-28s %s\n' "Disponíveis:" "$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo '-')"
  if [[ -f "$SYSCTL_FILE" ]]; then
    say "\nConfiguração do MANAGER:"
    cat "$SYSCTL_FILE"
  fi
  pause
}

enable_bbr() {
  header
  local available
  available="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
  if ! grep -qw bbr <<< "$available"; then
    modprobe tcp_bbr 2>/dev/null || true
    available="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
  fi
  if ! grep -qw bbr <<< "$available"; then
    err "Este kernel não anuncia suporte a BBR. Nada foi alterado."
    pause
    return
  fi
  say "O MANAGER fará apenas dois ajustes conservadores: fq + BBR."
  confirm "Ativar?" || return
  cat > "$SYSCTL_FILE" <<'EOF'
# Managed by MANAGER. Deliberately minimal.
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
  sysctl --system >/dev/null
  if [[ "$(sysctl -n net.ipv4.tcp_congestion_control)" == bbr ]]; then
    ok "BBR ativo"
  else
    err "O kernel não aplicou BBR"
  fi
  pause
}

restore_defaults() {
  header
  [[ -f "$SYSCTL_FILE" ]] || { warn "Nenhum tuning do MANAGER está aplicado"; pause; return; }
  confirm "Remover o arquivo de tuning do MANAGER?" || return
  rm -f "$SYSCTL_FILE"
  warn "Arquivo removido. Valores atuais do kernel só voltarão ao padrão após reboot ou ajuste manual."
  pause
}

while true; do
  header
  say "${C_WHITE}DESEMPENHO${C_RESET}\n"
  say " 1) Ver estado TCP atual"
  say " 2) Ativar BBR + fq"
  say " 3) Remover tuning do MANAGER"
  say " 0) Voltar"
  say ""
  read -r -p "Opção: " opt
  case "$opt" in
    1) show_status ;;
    2) enable_bbr ;;
    3) restore_defaults ;;
    0) exit 0 ;;
    *) warn "Opção inválida"; sleep 1 ;;
  esac
done
