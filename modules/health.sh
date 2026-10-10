#!/usr/bin/env bash
set -Eeuo pipefail

MANAGER_HOME="${MANAGER_HOME:-/opt/manager}"
# shellcheck source=/dev/null
source "$MANAGER_HOME/lib/common.sh"
require_root

WARNINGS=0
CRITICAL=0
INTERACTIVE=yes
[[ "${1:-}" == "--check" ]] && INTERACTIVE=no

pass() { printf '%b\n' "${C_GREEN}[OK]${C_RESET} $*"; }
warning() { WARNINGS=$((WARNINGS + 1)); printf '%b\n' "${C_YELLOW}[AVISO]${C_RESET} $*"; }
critical() { CRITICAL=$((CRITICAL + 1)); printf '%b\n' "${C_RED}[CRÍTICO]${C_RESET} $*"; }

check_disk() {
  local pct avail
  pct="$(df -P / | awk 'NR==2 {gsub(/%/,"",$5); print $5}')"
  avail="$(df -hP / | awk 'NR==2 {print $4}')"
  if (( pct >= 95 )); then critical "Disco raiz em ${pct}% (livre: $avail)"
  elif (( pct >= 85 )); then warning "Disco raiz em ${pct}% (livre: $avail)"
  else pass "Disco raiz: ${pct}% usado (livre: $avail)"; fi
}

check_memory() {
  local total available used_pct
  total="$(awk '/MemTotal:/ {print $2}' /proc/meminfo)"
  available="$(awk '/MemAvailable:/ {print $2}' /proc/meminfo)"
  if [[ -z "$total" || -z "$available" || "$total" -eq 0 ]]; then
    warning "Não foi possível calcular memória disponível"
    return
  fi
  used_pct=$(( (total - available) * 100 / total ))
  if (( used_pct >= 95 )); then critical "Memória em ${used_pct}%"
  elif (( used_pct >= 85 )); then warning "Memória em ${used_pct}%"
  else pass "Memória: ${used_pct}% usada"; fi
}

check_load() {
  local load cpus threshold_warn threshold_crit scaled
  load="$(awk '{print $1}' /proc/loadavg)"
  cpus="$(nproc 2>/dev/null || echo 1)"
  scaled="$(awk -v l="$load" 'BEGIN {printf "%d", l*100}')"
  threshold_warn=$((cpus * 150))
  threshold_crit=$((cpus * 250))
  if (( scaled >= threshold_crit )); then critical "Carga 1m $load para $cpus CPU(s)"
  elif (( scaled >= threshold_warn )); then warning "Carga 1m $load para $cpus CPU(s)"
  else pass "Carga 1m: $load / $cpus CPU(s)"; fi
}

check_inodes() {
  local pct
  pct="$(df -Pi / | awk 'NR==2 {gsub(/%/,"",$5); print $5}')"
  if (( pct >= 95 )); then critical "Inodes do / em ${pct}%"
  elif (( pct >= 85 )); then warning "Inodes do / em ${pct}%"
  else pass "Inodes: ${pct}% usados"; fi
}

check_failed_units() {
  local count
  count="$(systemctl --failed --no-legend --plain 2>/dev/null | grep -c . || true)"
  if (( count > 0 )); then
    warning "$count unidade(s) systemd em estado failed"
    systemctl --failed --no-legend --plain 2>/dev/null | sed -n '1,8p' | sed 's/^/        /'
  else pass "Nenhuma unidade systemd falhou"; fi
}

check_ssh() {
  local unit
  if systemctl list-unit-files ssh.service >/dev/null 2>&1; then unit=ssh; else unit=sshd; fi
  if systemctl is-active --quiet "$unit" 2>/dev/null; then
    pass "OpenSSH ativo"
    if command_exists sshd && sshd -t 2>/dev/null; then pass "Configuração sshd válida"; else warning "sshd -t falhou ou não está disponível"; fi
  else
    critical "OpenSSH não está ativo"
  fi
}

check_network() {
  local gateway
  gateway="$(ip route show default 2>/dev/null | awk 'NR==1 {print $3}')"
  if [[ -n "$gateway" ]]; then pass "Rota padrão via $gateway"; else critical "Sem rota IPv4 padrão"; fi

  if getent ahostsv4 github.com >/dev/null 2>&1; then pass "Resolução DNS funcional"; else warning "Falha ao resolver github.com"; fi
}

check_updates() {
  local updates
  if [[ -f /var/run/reboot-required ]]; then
    warning "Reinicialização do sistema pendente"
  else
    pass "Sem reboot pendente"
  fi

  if command_exists apt-get; then
    updates="$(apt list --upgradable 2>/dev/null | tail -n +2 | grep -c . || true)"
    if (( updates > 25 )); then warning "$updates pacote(s) com atualização disponível"
    elif (( updates > 0 )); then printf '%b\n' "${C_CYAN}[INFO]${C_RESET} $updates atualização(ões) de pacote disponível(is)"
    else pass "Nenhuma atualização detectada no cache APT"; fi
  fi
}

check_security() {
  if command_exists ufw; then
    if ufw status 2>/dev/null | grep -q '^Status: active'; then pass "UFW ativo"; else warning "UFW instalado, porém inativo"; fi
  else warning "UFW não instalado"; fi

  if command_exists fail2ban-client; then
    if systemctl is-active --quiet fail2ban; then pass "Fail2ban ativo"; else warning "Fail2ban instalado, porém inativo"; fi
  else warning "Fail2ban não instalado"; fi
}

run_health() {
  [[ "$INTERACTIVE" == yes ]] && header
  say "${C_WHITE}SAÚDE DO SERVIDOR${C_RESET}\n"
  printf ' Host: %s\n Kernel: %s\n Uptime: %s\n\n' "$(hostname)" "$(uname -r)" "$(uptime -p 2>/dev/null || true)"
  check_disk
  check_inodes
  check_memory
  check_load
  check_failed_units
  check_ssh
  check_network
  check_updates
  check_security

  say ""
  if (( CRITICAL > 0 )); then
    say "${C_RED}Resumo: $CRITICAL crítico(s), $WARNINGS aviso(s).${C_RESET}"
  elif (( WARNINGS > 0 )); then
    say "${C_YELLOW}Resumo: saudável com $WARNINGS aviso(s).${C_RESET}"
  else
    say "${C_GREEN}Resumo: todos os checks principais estão OK.${C_RESET}"
  fi

  [[ "$INTERACTIVE" == yes ]] && pause
  (( CRITICAL == 0 )) || return 2
  (( WARNINGS == 0 )) || return 1
  return 0
}

run_health
