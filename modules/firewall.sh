#!/usr/bin/env bash
set -Eeuo pipefail

MANAGER_HOME="${MANAGER_HOME:-/opt/manager}"
# shellcheck source=/dev/null
source "$MANAGER_HOME/lib/common.sh"
require_root

UFW_DEFAULTS="/etc/default/ufw"

ssh_ports() {
  if command_exists sshd; then
    sshd -T 2>/dev/null | awk '$1=="port" {print $2}' | sort -un
  else
    echo 22
  fi
}

ufw_ipv6_enabled() {
  [[ -f "$UFW_DEFAULTS" ]] && grep -Eq '^IPV6=(yes|YES|true|TRUE)$' "$UFW_DEFAULTS"
}

ensure_ufw_ipv6() {
  [[ -f "$UFW_DEFAULTS" ]] || return 0
  if ufw_ipv6_enabled; then return 0; fi
  backup_file "$UFW_DEFAULTS"
  if grep -q '^IPV6=' "$UFW_DEFAULTS"; then
    sed -i -E 's/^IPV6=.*/IPV6=yes/' "$UFW_DEFAULTS"
  else
    printf '\nIPV6=yes\n' >> "$UFW_DEFAULTS"
  fi
  ufw_ipv6_enabled || { err "Não foi possível habilitar cobertura IPv6 do UFW"; return 1; }
}

show_status() {
  header
  say "${C_WHITE}FIREWALL E PORTAS${C_RESET}\n"
  if command_exists ufw; then
    ufw status verbose || true
    if ufw_ipv6_enabled; then
      say "\nCobertura UFW IPv6: ${C_GREEN}ativa${C_RESET}"
    else
      say "\nCobertura UFW IPv6: ${C_RED}desativada${C_RESET}"
    fi
  else
    warn "UFW não instalado"
  fi
  if ipv6_egress_available; then
    say "IPv6 da VPS: ${C_GREEN}rota global disponível em $(ipv6_default_interface)${C_RESET}"
  else
    say "IPv6 da VPS: ${C_YELLOW}sem saída global detectada${C_RESET}"
  fi
  say "\n${C_WHITE}Portas TCP/UDP escutando:${C_RESET}"
  ss -lntup 2>/dev/null | sed -n '1,80p' || true
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
  say "IPv4 e IPv6 serão administrados pelo mesmo conjunto de regras UFW."
  confirm "Continuar?" || return
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y ufw
  ensure_ufw_ipv6 || { pause; return; }
  local port
  while read -r port; do
    [[ -n "$port" ]] && ufw allow "$port/tcp" comment 'MANAGER SSH' >/dev/null
  done < <(ssh_ports)
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  if confirm "Ativar UFW agora?"; then
    ufw --force enable
    ok "UFW ativo com cobertura IPv4 + IPv6"
  else
    info "UFW configurado para IPv4 + IPv6, mas ainda desativado"
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
  ensure_ufw_ipv6 || { pause; return; }
  local port proto
  read -r -p "Porta: " port
  read -r -p "Protocolo [tcp/udp] (tcp): " proto
  proto="${proto:-tcp}"
  validate_port_proto "$port" "$proto" || { err "Porta/protocolo inválido"; pause; return; }
  ufw allow "$port/$proto" comment 'MANAGER' >/dev/null
  ok "$port/$proto liberada em IPv4 e IPv6"
  pause
}

close_port() {
  header
  command_exists ufw || { err "UFW não instalado"; pause; return; }
  ensure_ufw_ipv6 || { pause; return; }
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
  ok "$port/$proto bloqueada em IPv4 e IPv6"
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

machine_network_status() {
  printf 'ufw_ipv6=%s\n' "$(ufw_ipv6_enabled && echo 1 || echo 0)"
  printf 'host_ipv6_egress=%s\n' "$(ipv6_egress_available && echo 1 || echo 0)"
  printf 'host_ipv6_interface=%s\n' "$(ipv6_default_interface)"
}

case "${1:-}" in
  --network-status) machine_network_status; exit 0 ;;
  *) ;;
esac

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
