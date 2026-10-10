#!/usr/bin/env bash
set -Eeuo pipefail

MANAGER_HOME="${MANAGER_HOME:-/opt/manager}"
MANAGER_ETC="${MANAGER_ETC:-/etc/manager}"
# shellcheck source=/dev/null
source "$MANAGER_HOME/lib/common.sh"
require_root

LOG_DIR="/var/log/manager"
LOG_FILE="$LOG_DIR/speedtest.log"

find_client() {
  if command_exists speedtest; then
    printf 'speedtest'
  elif command_exists speedtest-cli; then
    printf 'speedtest-cli'
  else
    return 1
  fi
}

install_client() {
  header
  say "${C_WHITE}INSTALAR SPEEDTEST${C_RESET}\n"
  info "O MANAGER instalará o cliente speedtest-cli fornecido pela distribuição."
  confirm "Instalar speedtest-cli via APT?" || { pause; return; }
  apt-get update -y
  apt-get install -y speedtest-cli
  ok "Cliente instalado"
  pause
}

run_test() {
  header
  say "${C_WHITE}TESTE DE VELOCIDADE${C_RESET}\n"
  local client tmp stamp rc=0
  client="$(find_client)" || {
    err "Nenhum cliente Speedtest instalado. Use a opção de instalação primeiro."
    pause
    return
  }

  mkdir -p "$LOG_DIR"
  chmod 0750 "$LOG_DIR"
  touch "$LOG_FILE"
  chmod 0640 "$LOG_FILE"
  tmp="$(mktemp)"
  stamp="$(date --iso-8601=seconds)"

  info "Executando teste. Isso gera tráfego de download e upload na VPS."
  if [[ "$client" == "speedtest-cli" ]]; then
    timeout 180 speedtest-cli --secure --simple > "$tmp" 2>&1 || rc=$?
  else
    timeout 180 speedtest --accept-license --accept-gdpr > "$tmp" 2>&1 || rc=$?
  fi

  if (( rc != 0 )); then
    cat "$tmp"
    rm -f "$tmp"
    err "Speedtest terminou com código $rc"
    pause
    return
  fi

  cat "$tmp"
  {
    printf '[%s] client=%s\n' "$stamp" "$client"
    sed 's/^/  /' "$tmp"
    printf '\n'
  } >> "$LOG_FILE"
  rm -f "$tmp"
  ok "Resultado registrado em $LOG_FILE"
  pause
}

show_history() {
  header
  say "${C_WHITE}HISTÓRICO DE SPEEDTEST${C_RESET}\n"
  if [[ -s "$LOG_FILE" ]]; then
    tail -n 120 "$LOG_FILE"
  else
    info "Ainda não há testes registrados."
  fi
  pause
}

basic_latency() {
  header
  say "${C_WHITE}LATÊNCIA BÁSICA${C_RESET}\n"
  local target
  read -r -p "Host/IP para ping [1.1.1.1]: " target
  target="${target:-1.1.1.1}"
  if [[ ! "$target" =~ ^[A-Za-z0-9._:-]+$ ]]; then
    err "Destino inválido"
    pause
    return
  fi
  ping -c 5 -W 2 "$target" || true
  pause
}

while true; do
  header
  say "${C_WHITE}SPEEDTEST / REDE${C_RESET}\n"
  if client="$(find_client 2>/dev/null)"; then
    printf ' Cliente: %s\n\n' "$client"
  else
    printf ' Cliente: não instalado\n\n'
  fi
  say " 1) Executar speedtest"
  say " 2) Latência básica (ping)"
  say " 3) Ver histórico"
  say " 4) Instalar cliente via APT"
  say " 0) Voltar"
  say ""
  read -r -p "Opção: " opt
  case "$opt" in
    1) run_test ;;
    2) basic_latency ;;
    3) show_history ;;
    4) install_client ;;
    0) exit 0 ;;
    *) warn "Opção inválida"; sleep 1 ;;
  esac
done
