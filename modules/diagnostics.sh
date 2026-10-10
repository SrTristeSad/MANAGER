#!/usr/bin/env bash
set -Eeuo pipefail

MANAGER_HOME="${MANAGER_HOME:-/opt/manager}"
# shellcheck source=/dev/null
source "$MANAGER_HOME/lib/common.sh"
require_root

pass() { say "${C_GREEN}[OK]${C_RESET} $*"; }
fail() { say "${C_RED}[FALHA]${C_RESET} $*"; }
notice() { say "${C_YELLOW}[AVISO]${C_RESET} $*"; }

run_checks() {
  header
  say "${C_WHITE}DIAGNÓSTICO GERAL${C_RESET}\n"

  if ip -4 route show default | grep -q '^default'; then
    pass "Rota IPv4 padrão: $(ip -4 route show default | head -n1)"
  else
    fail "Sem rota IPv4 padrão"
  fi

  if ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1; then pass "Conectividade IPv4 externa"; else fail "Sem resposta IPv4 para 1.1.1.1"; fi
  if getent ahostsv4 debian.org >/dev/null 2>&1; then pass "Resolução DNS"; else fail "DNS não está resolvendo nomes"; fi

  if systemctl is-active --quiet ssh 2>/dev/null || systemctl is-active --quiet sshd 2>/dev/null; then pass "OpenSSH ativo"; else fail "OpenSSH inativo"; fi
  command_exists sshd && sshd -t >/dev/null 2>&1 && pass "Configuração SSH válida" || notice "Não foi possível validar sshd -t"

  if timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -qx yes; then pass "Relógio sincronizado por NTP"; else notice "NTP não aparece como sincronizado"; fi

  local root_use
  root_use="$(df -P / | awk 'NR==2 {gsub(/%/,"",$5); print $5}')"
  if [[ "$root_use" =~ ^[0-9]+$ ]] && (( root_use < 85 )); then pass "Disco / em ${root_use}%"; else notice "Uso de disco / em ${root_use:-?}%"; fi

  local mem_avail mem_total pct
  mem_total="$(awk '/MemTotal/ {print $2}' /proc/meminfo)"
  mem_avail="$(awk '/MemAvailable/ {print $2}' /proc/meminfo)"
  pct=$(( (mem_total - mem_avail) * 100 / mem_total ))
  if (( pct < 90 )); then pass "Memória em uso: ${pct}%"; else notice "Memória em uso: ${pct}%"; fi

  if [[ -f /proc/sys/net/ipv4/ip_forward ]] && [[ "$(cat /proc/sys/net/ipv4/ip_forward)" == 1 ]]; then
    pass "IPv4 forwarding ativo"
  else
    notice "IPv4 forwarding desativado (normal se não usar VPN roteada)"
  fi

  say "\n${C_WHITE}Serviços opcionais:${C_RESET}"
  for unit in wg-quick@wg0 fail2ban dnsmasq; do
    if systemctl is-active --quiet "$unit" 2>/dev/null; then pass "$unit ativo"; else notice "$unit não ativo"; fi
  done

  say "\n${C_WHITE}Porta 53:${C_RESET}"
  ss -lnup 2>/dev/null | awk 'NR==1 || /:53[[:space:]]/' || true
  say "\n${C_WHITE}Portas TCP públicas em escuta:${C_RESET}"
  ss -lntp 2>/dev/null | awk 'NR==1 || /0\.0\.0\.0:|\[::\]:/' | sed -n '1,30p' || true

  say "\n${C_WHITE}Atualizações pendentes:${C_RESET}"
  local updates
  updates="$(apt list --upgradable 2>/dev/null | tail -n +2 | wc -l)"
  say "  Pacotes atualizáveis: $updates"
  if [[ -f /var/run/reboot-required ]]; then notice "O sistema solicita reinicialização"; else pass "Sem reboot-required"; fi
  pause
}

network_details() {
  header
  say "${C_WHITE}REDE${C_RESET}\n"
  ip -br addr || true
  say "\nRotas:"
  ip route || true
  say "\nDNS do sistema:"
  if command_exists resolvectl; then resolvectl status 2>/dev/null | sed -n '1,80p'; else cat /etc/resolv.conf; fi
  say "\nSockets em escuta:"
  ss -lntup 2>/dev/null | sed -n '1,80p' || true
  pause
}

while true; do
  header
  say "${C_WHITE}DIAGNÓSTICO${C_RESET}\n"
  say " 1) Executar diagnóstico geral"
  say " 2) Detalhes de rede"
  say " 0) Voltar"
  say ""
  read -r -p "Opção: " opt
  case "$opt" in
    1) run_checks ;;
    2) network_details ;;
    0) exit 0 ;;
    *) warn "Opção inválida"; sleep 1 ;;
  esac
done
