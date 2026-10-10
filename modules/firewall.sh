#!/usr/bin/env bash
set -Eeuo pipefail

MANAGER_HOME="${MANAGER_HOME:-/opt/manager}"
# shellcheck source=/dev/null
source "$MANAGER_HOME/lib/common.sh"
require_root

ssh_ports() {
  if command_exists sshd; then
    sshd -T 2>/dev/null | awk '$1=="port" {print $2}' | sort -un
  else
    echo 22
  fi
}

show_status() {
  header
  say "${C_WHITE}FIREWALL E PORTAS${C_RESET}\n"
  if command_exists ufw; then
    ufw status verbose || true
  else
    warn "UFW não instalado"
  fi
  say "\n${C_WHITE}Portas TCP/UDP escutando:${C_RESET}"
  ss -lntup 2>/dev/null | sed -n '1,60p' || true
  pause
}

install_ufw() {
  header
  say "${C_WHITE}INSTALAR/ATIVAR UFW${C_RESET}\n"
  if systemctl is-active --quiet firewalld 2>/dev/null; then
    err "firewalld está ativo. O MANAGER não mistura dois front-ends de firewall."
    pause
    return
  fi
  warn "Se você usa Docker/containers, revise as regras de rede antes de ativar UFW."
  say "O MANAGER libera as portas SSH detectadas antes de habilitar o firewall."
  confirm "Continuar?" || return
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y ufw
  local port
  while read -r port; do
    [[ -n "$port" ]] && ufw allow "$port/tcp" comment 'MANAGER SSH' >/dev/null
  done < <(ssh_ports)
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  if confirm "Ativar UFW agora?"; then
    ufw --force enable
    ok "UFW ativo"
  else
    info "UFW configurado, mas ainda desativado"
  fi
  pause
}

validate_port_proto() {
  local port="$1" proto="$2"
  [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )) || return 1
  [[ "$proto" == tcp || "$proto" == udp ]]
}

open_port() {
  header
  command_exists ufw || { err "UFW não instalado"; pause; return; }
  local port proto
  read -r -p "Porta: " port
  read -r -p "Protocolo [tcp/udp] (tcp): " proto
  proto="${proto:-tcp}"
  validate_port_proto "$port" "$proto" || { err "Porta/protocolo inválido"; pause; return; }
  ufw allow "$port/$proto" comment 'MANAGER' >/dev/null
  ok "$port/$proto liberada"
  pause
}

close_port() {
  header
  command_exists ufw || { err "UFW não instalado"; pause; return; }
  local port proto sshp
  read -r -p "Porta: " port
  read -r -p "Protocolo [tcp/udp] (tcp): " proto
  proto="${proto:-tcp}"
  validate_port_proto "$port" "$proto" || { err "Porta/protocolo inválido"; pause; return; }
  if [[ "$proto" == tcp ]]; then
    while read -r sshp; do
      if [[ "$port" == "$sshp" ]]; then
        err "Recusado: $port é uma porta SSH ativa. Altere o SSH de forma planejada primeiro."
        pause
        return
      fi
    done < <(ssh_ports)
  fi
  ufw --force delete allow "$port/$proto" >/dev/null 2>&1 || true
  ufw deny "$port/$proto" comment 'MANAGER' >/dev/null
  ok "$port/$proto bloqueada"
  pause
}

remove_rule() {
  header
  command_exists ufw || { err "UFW não instalado"; pause; return; }
  ufw status numbered
  local n
  read -r -p "Número da regra para excluir: " n
  [[ "$n" =~ ^[1-9][0-9]*$ ]] || { err "Número inválido"; pause; return; }
  confirm "Excluir regra $n?" || return
  ufw --force delete "$n"
  pause
}

while true; do
  header
  say "${C_WHITE}FIREWALL${C_RESET}\n"
  say " 1) Status + portas em uso"
  say " 2) Instalar/configurar UFW"
  say " 3) Liberar porta"
  say " 4) Bloquear porta"
  say " 5) Excluir regra por número"
  say " 0) Voltar"
  say ""
  read -r -p "Opção: " opt
  case "$opt" in
    1) show_status ;;
    2) install_ufw ;;
    3) open_port ;;
    4) close_port ;;
    5) remove_rule ;;
    0) exit 0 ;;
    *) warn "Opção inválida"; sleep 1 ;;
  esac
done
