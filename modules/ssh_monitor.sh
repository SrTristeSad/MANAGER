#!/usr/bin/env bash
set -Eeuo pipefail

MANAGER_HOME="${MANAGER_HOME:-/opt/manager}"
# shellcheck source=/dev/null
source "$MANAGER_HOME/lib/common.sh"
require_root

LIMITS_FILE="/etc/security/limits.d/99-manager-ssh.conf"

limit_for_user() {
  awk -v u="$1" '$1==u && $3=="maxlogins" {print $4}' "$LIMITS_FILE" 2>/dev/null | tail -n1
}

summary() {
  header
  say "${C_WHITE}MONITOR SSH${C_RESET}\n"
  printf '%-18s %-10s %-10s %-16s %-18s\n' "USUÁRIO" "SESSÕES" "LIMITE" "TEMPO" "ORIGEM"
  printf '%-18s %-10s %-10s %-16s %-18s\n' "------------------" "----------" "----------" "----------------" "------------------"

  local user count limit first_pid elapsed origin found=0
  while read -r user; do
    [[ -n "$user" ]] || continue
    found=1
    count="$(who | awk -v u="$user" '$1==u {c++} END {print c+0}')"
    limit="$(limit_for_user "$user")"; [[ -n "$limit" ]] || limit="-"
    first_pid="$(who -u 2>/dev/null | awk -v u="$user" '$1==u && $6 ~ /^[0-9]+$/ {print $6; exit}')"
    if [[ "$first_pid" =~ ^[0-9]+$ ]]; then
      elapsed="$(ps -o etime= -p "$first_pid" 2>/dev/null | xargs || true)"
    else
      elapsed="-"
    fi
    origin="$(who 2>/dev/null | awk -v u="$user" '$1==u {print $5; exit}' | tr -d '()')"
    [[ -n "$origin" ]] || origin="-"
    printf '%-18s %-10s %-10s %-16s %-18s\n' "$user" "$count" "$limit" "${elapsed:--}" "$origin"
  done < <(who | awk '{print $1}' | sort -u)

  (( found == 1 )) || info "Nenhuma sessão de login ativa"
  say ""
  say "Conexões TCP envolvendo portas SSH detectadas:"
  ssh_ports="$(sshd -T 2>/dev/null | awk '$1=="port" {print $2}' | sort -un | paste -sd, - || true)"
  [[ -n "$ssh_ports" ]] || ssh_ports="22"
  printf '  portas: %s\n' "$ssh_ports"
  pause
}

detailed_sessions() {
  header
  say "${C_WHITE}SESSÕES SSH DETALHADAS${C_RESET}\n"
  if command_exists who; then
    who -uH --ips 2>/dev/null || who -uH || true
  fi
  say "\n${C_WHITE}Processos sshd de sessão:${C_RESET}"
  ps -eo pid=,user=,etime=,tty=,args= 2>/dev/null | awk '/[s]shd: / && $0 !~ /listener/ {print}' | sed -n '1,100p'
  pause
}

network_sessions() {
  header
  say "${C_WHITE}SOCKETS SSH ESTABELECIDOS${C_RESET}\n"
  local ports expr="" p
  ports="$(sshd -T 2>/dev/null | awk '$1=="port" {print $2}' | sort -un || true)"
  [[ -n "$ports" ]] || ports="22"
  while IFS= read -r p; do
    [[ "$p" =~ ^[0-9]+$ ]] || continue
    if [[ -n "$expr" ]]; then expr+=" or "; fi
    expr+="sport = :$p"
  done <<< "$ports"
  if [[ -n "$expr" ]]; then
    ss -Htnp state established "( $expr )" 2>/dev/null | sed -n '1,150p' || true
  fi
  pause
}

disconnect_tty() {
  header
  say "${C_WHITE}ENCERRAR UMA SESSÃO SSH${C_RESET}\n"
  who -uH --ips 2>/dev/null || who -uH || true
  say ""
  local tty user
  read -r -p "TTY da sessão (ex.: pts/2): " tty
  [[ "$tty" =~ ^(pts|tty)/[0-9]+$ ]] || { err "TTY inválido"; pause; return; }
  user="$(who | awk -v t="$tty" '$2==t {print $1; exit}')"
  [[ -n "$user" ]] || { err "Sessão não encontrada"; pause; return; }
  [[ "$user" != root ]] || { err "O MANAGER não encerra sessão root por este menu"; pause; return; }
  confirm "Encerrar a sessão $tty de $user?" || return
  pkill -TERM -t "$tty" 2>/dev/null || true
  sleep 1
  if who | awk -v t="$tty" '$2==t {found=1} END {exit !found}'; then
    pkill -KILL -t "$tty" 2>/dev/null || true
  fi
  ok "Solicitação de encerramento enviada para $tty"
  pause
}

history() {
  header
  say "${C_WHITE}HISTÓRICO DE LOGIN${C_RESET}\n"
  if command_exists last; then
    last -F -i -n 40 2>/dev/null || last -n 40 || true
  else
    warn "Comando last não disponível"
  fi
  pause
}

case "${1:-}" in
  --summary)
    who -u --ips 2>/dev/null || who -u || true
    exit 0
    ;;
esac

while true; do
  header
  say "${C_WHITE}MONITOR DE SESSÕES SSH${C_RESET}\n"
  say " 1) Resumo por usuário"
  say " 2) Sessões/processos detalhados"
  say " 3) Sockets SSH estabelecidos"
  say " 4) Encerrar uma sessão específica"
  say " 5) Histórico de login"
  say " 0) Voltar"
  say ""
  read -r -p "Opção: " opt
  case "$opt" in
    1) summary ;;
    2) detailed_sessions ;;
    3) network_sessions ;;
    4) disconnect_tty ;;
    5) history ;;
    0) exit 0 ;;
    *) warn "Opção inválida"; sleep 1 ;;
  esac
done
