#!/usr/bin/env bash
set -Eeuo pipefail

MANAGER_HOME="${MANAGER_HOME:-/opt/manager}"
# shellcheck source=/dev/null
source "$MANAGER_HOME/lib/common.sh"
require_root

JAIL_FILE="/etc/fail2ban/jail.d/99-manager-sshd.local"

install_f2b() {
  header
  say "${C_WHITE}INSTALAR FAIL2BAN${C_RESET}\n"
  confirm "Instalar e proteger o SSH contra força bruta?" || return
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y fail2ban
  mkdir -p /etc/fail2ban/jail.d
  cat > "$JAIL_FILE" <<'EOF'
[sshd]
enabled = true
backend = systemd
mode = normal
maxretry = 5
findtime = 10m
bantime = 1h
EOF
  chmod 0644 "$JAIL_FILE"
  fail2ban-client -t
  systemctl enable --now fail2ban
  ok "Fail2ban instalado e jail SSH habilitada"
  pause
}

status_f2b() {
  header
  say "${C_WHITE}STATUS FAIL2BAN${C_RESET}\n"
  if ! command_exists fail2ban-client; then
    warn "Fail2ban não instalado"
    pause
    return
  fi
  systemctl --no-pager --full status fail2ban 2>/dev/null | sed -n '1,12p' || true
  say ""
  fail2ban-client status sshd 2>/dev/null || warn "Jail sshd ainda não está ativa"
  pause
}

configure_f2b() {
  header
  command_exists fail2ban-client || { err "Instale o Fail2ban primeiro"; pause; return; }
  local maxretry findtime bantime
  read -r -p "Tentativas antes do ban [5]: " maxretry
  read -r -p "Janela de tentativas [10m]: " findtime
  read -r -p "Tempo de ban [1h]: " bantime
  maxretry="${maxretry:-5}"
  findtime="${findtime:-10m}"
  bantime="${bantime:-1h}"
  [[ "$maxretry" =~ ^[1-9][0-9]?$ ]] || { err "maxretry inválido"; pause; return; }
  [[ "$findtime" =~ ^[0-9]+[smhdw]?$ ]] || { err "findtime inválido"; pause; return; }
  [[ "$bantime" =~ ^[0-9]+[smhdw]?$ ]] || { err "bantime inválido"; pause; return; }
  cat > "$JAIL_FILE" <<EOF
[sshd]
enabled = true
backend = systemd
mode = normal
maxretry = $maxretry
findtime = $findtime
bantime = $bantime
EOF
  fail2ban-client -t || { err "Configuração recusada pelo Fail2ban"; pause; return; }
  systemctl restart fail2ban
  ok "Configuração aplicada"
  pause
}

unban_ip() {
  header
  command_exists fail2ban-client || { err "Fail2ban não instalado"; pause; return; }
  local ip
  read -r -p "IP para desbloquear: " ip
  is_valid_ipv4 "$ip" || { err "IPv4 inválido"; pause; return; }
  fail2ban-client set sshd unbanip "$ip" >/dev/null
  ok "$ip desbloqueado"
  pause
}

show_log() {
  header
  journalctl -u fail2ban --no-pager -n 80 2>/dev/null || true
  pause
}

remove_config() {
  header
  confirm "Remover apenas a configuração SSH criada pelo MANAGER?" || return
  rm -f "$JAIL_FILE"
  if command_exists fail2ban-client; then
    fail2ban-client -t >/dev/null 2>&1 || true
    systemctl restart fail2ban 2>/dev/null || true
  fi
  ok "Configuração do MANAGER removida; o pacote Fail2ban foi mantido"
  pause
}

while true; do
  header
  say "${C_WHITE}FAIL2BAN / PROTEÇÃO SSH${C_RESET}\n"
  say " 1) Instalar/ativar proteção SSH"
  say " 2) Status e IPs banidos"
  say " 3) Ajustar tentativas e tempos"
  say " 4) Desbloquear IP"
  say " 5) Ver logs"
  say " 6) Remover configuração do MANAGER"
  say " 0) Voltar"
  say ""
  read -r -p "Opção: " opt
  case "$opt" in
    1) install_f2b ;;
    2) status_f2b ;;
    3) configure_f2b ;;
    4) unban_ip ;;
    5) show_log ;;
    6) remove_config ;;
    0) exit 0 ;;
    *) warn "Opção inválida"; sleep 1 ;;
  esac
done
