#!/usr/bin/env bash
set -Eeuo pipefail

MANAGER_HOME="${MANAGER_HOME:-/opt/manager}"
MANAGER_ETC="${MANAGER_ETC:-/etc/manager}"
# shellcheck source=/dev/null
source "$MANAGER_HOME/lib/common.sh"
require_root

SYSCTL_FILE="/etc/sysctl.d/99-manager-performance.conf"
STATE_DIR="$MANAGER_ETC/performance"
PREV_CC="$STATE_DIR/previous-congestion-control"
PREV_QDISC="$STATE_DIR/previous-qdisc"

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
  if [[ -f "$PREV_CC" && -f "$PREV_QDISC" ]]; then
    say "\nValores salvos para rollback:"
    printf '  %-24s %s\n' "Congestion control:" "$(cat "$PREV_CC")"
    printf '  %-24s %s\n' "Qdisc:" "$(cat "$PREV_QDISC")"
  fi
  pause
}

save_previous_values() {
  mkdir -p "$STATE_DIR"
  chmod 0700 "$STATE_DIR"
  if [[ ! -f "$PREV_CC" ]]; then
    sysctl -n net.ipv4.tcp_congestion_control > "$PREV_CC"
  fi
  if [[ ! -f "$PREV_QDISC" ]]; then
    sysctl -n net.core.default_qdisc > "$PREV_QDISC"
  fi
  chmod 0600 "$PREV_CC" "$PREV_QDISC"
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
  say "Os valores atuais serão guardados para rollback imediato."
  confirm "Ativar?" || return

  save_previous_values
  backup_file "$SYSCTL_FILE"
  cat > "$SYSCTL_FILE" <<'EOF'
# Managed by MANAGER. Deliberately minimal.
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
  chmod 0644 "$SYSCTL_FILE"
  sysctl -p "$SYSCTL_FILE" >/dev/null
  if [[ "$(sysctl -n net.ipv4.tcp_congestion_control)" == bbr ]]; then
    ok "BBR + fq ativos"
  else
    err "O kernel não aplicou BBR"
  fi
  pause
}

restore_previous() {
  header
  [[ -f "$SYSCTL_FILE" ]] || { warn "Nenhum tuning do MANAGER está aplicado"; pause; return; }
  confirm "Remover BBR/fq do MANAGER e restaurar os valores anteriores?" || return

  local previous_cc="" previous_qdisc=""
  [[ -f "$PREV_CC" ]] && previous_cc="$(tr -d '[:space:]' < "$PREV_CC")"
  [[ -f "$PREV_QDISC" ]] && previous_qdisc="$(tr -d '[:space:]' < "$PREV_QDISC")"
  rm -f "$SYSCTL_FILE"

  if [[ "$previous_qdisc" =~ ^[A-Za-z0-9_-]+$ ]]; then
    sysctl -w "net.core.default_qdisc=$previous_qdisc" >/dev/null || true
  fi
  if [[ "$previous_cc" =~ ^[A-Za-z0-9_-]+$ ]]; then
    sysctl -w "net.ipv4.tcp_congestion_control=$previous_cc" >/dev/null || true
  fi

  rm -rf "$STATE_DIR"
  ok "Tuning do MANAGER removido"
  printf '%-28s %s\n' "Congestion control atual:" "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '-')"
  printf '%-28s %s\n' "Qdisc atual:" "$(sysctl -n net.core.default_qdisc 2>/dev/null || echo '-')"
  pause
}

while true; do
  header
  say "${C_WHITE}DESEMPENHO${C_RESET}\n"
  say " 1) Ver estado TCP atual"
  say " 2) Ativar BBR + fq"
  say " 3) Restaurar valores anteriores"
  say " 0) Voltar"
  say ""
  read -r -p "Opção: " opt
  case "$opt" in
    1) show_status ;;
    2) enable_bbr ;;
    3) restore_previous ;;
    0) exit 0 ;;
    *) warn "Opção inválida"; sleep 1 ;;
  esac
done
