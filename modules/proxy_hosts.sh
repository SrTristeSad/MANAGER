#!/usr/bin/env bash
set -Eeuo pipefail

MANAGER_HOME="${MANAGER_HOME:-/opt/manager}"
MANAGER_ETC="${MANAGER_ETC:-/etc/manager}"
# shellcheck source=/dev/null
source "$MANAGER_HOME/lib/common.sh"
require_root

PROXY_DIR="$MANAGER_ETC/proxy"
HOSTS_FILE="$PROXY_DIR/hosts.txt"

init_hosts() {
  mkdir -p "$PROXY_DIR"
  chmod 0700 "$PROXY_DIR"
  touch "$HOSTS_FILE"
  chmod 0600 "$HOSTS_FILE"
}

normalize_domain() {
  local value="$1"
  value="${value,,}"
  value="${value#http://}"
  value="${value#https://}"
  value="${value%%/*}"
  value="${value%%:*}"
  value="${value%.}"
  [[ "$value" == .* ]] || value=".$value"
  [[ "$value" =~ ^\.([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || return 1
  printf '%s\n' "$value"
}

reload_squid_if_managed() {
  if [[ -x "$MANAGER_HOME/modules/proxies.sh" ]]; then
    "$MANAGER_HOME/modules/proxies.sh" --reload-squid >/dev/null 2>&1 || true
  fi
}

list_hosts_machine() {
  init_hosts
  sed '/^[[:space:]]*$/d' "$HOSTS_FILE"
}

list_hosts() {
  header
  say "${C_WHITE}HOSTS PERMITIDOS NO PROXY${C_RESET}\n"
  init_hosts
  if [[ ! -s "$HOSTS_FILE" ]]; then
    info "Nenhum domínio cadastrado"
  else
    nl -ba "$HOSTS_FILE"
  fi
  say ""
  info "A lista é usada somente quando o modo de restrição por host do Squid está ativo."
  pause
}

add_host_impl() {
  local input="$1" host tmp
  init_hosts
  host="$(normalize_domain "$input")" || { err "Domínio inválido: $input"; return 1; }
  if grep -Fxq -- "$host" "$HOSTS_FILE"; then
    return 0
  fi
  tmp="$(mktemp)"
  { cat "$HOSTS_FILE"; printf '%s\n' "$host"; } | sed '/^[[:space:]]*$/d' | sort -u > "$tmp"
  install -m 0600 "$tmp" "$HOSTS_FILE"
  rm -f "$tmp"
  reload_squid_if_managed
}

add_host() {
  header
  local input host
  read -r -p "Domínio (ex.: example.com): " input
  host="$(normalize_domain "$input")" || { err "Domínio inválido"; pause; return; }
  if grep -Fxq -- "$host" "$HOSTS_FILE" 2>/dev/null; then
    info "$host já está cadastrado"
  elif add_host_impl "$host"; then
    ok "$host adicionado"
  fi
  pause
}

remove_host_impl() {
  local input="$1" host tmp
  init_hosts
  host="$(normalize_domain "$input")" || { err "Domínio inválido: $input"; return 1; }
  grep -Fxq -- "$host" "$HOSTS_FILE" || return 0
  tmp="$(mktemp)"
  grep -Fvx -- "$host" "$HOSTS_FILE" > "$tmp" || true
  install -m 0600 "$tmp" "$HOSTS_FILE"
  rm -f "$tmp"
  reload_squid_if_managed
}

remove_host() {
  header
  local input host
  read -r -p "Domínio para remover: " input
  host="$(normalize_domain "$input")" || { err "Domínio inválido"; pause; return; }
  if ! grep -Fxq -- "$host" "$HOSTS_FILE" 2>/dev/null; then
    info "$host não está cadastrado"
  elif remove_host_impl "$host"; then
    ok "$host removido"
  fi
  pause
}

import_legacy() {
  header
  say "${C_WHITE}IMPORTAR HOSTS DO SSHPLUS${C_RESET}\n"
  init_hosts
  local legacy="" line host imported=0
  if [[ -f /etc/squid/payload.txt ]]; then
    legacy="/etc/squid/payload.txt"
  elif [[ -f /etc/squid3/payload.txt ]]; then
    legacy="/etc/squid3/payload.txt"
  fi
  [[ -n "$legacy" ]] || { info "Nenhum payload.txt legado encontrado"; pause; return; }
  info "Origem detectada: $legacy"
  confirm "Importar somente domínios válidos para a lista moderna?" || { pause; return; }
  while IFS= read -r line; do
    line="${line%%#*}"
    line="${line//[[:space:]]/}"
    [[ -n "$line" ]] || continue
    if host="$(normalize_domain "$line" 2>/dev/null)"; then
      if ! grep -Fxq -- "$host" "$HOSTS_FILE"; then
        add_host_impl "$host"
        imported=$((imported + 1))
      fi
    fi
  done < "$legacy"
  ok "$imported domínio(s) importado(s)"
  pause
}

init_hosts
case "${1:-}" in
  --init) exit 0 ;;
  --list) list_hosts_machine; exit 0 ;;
  --add) add_host_impl "${2:-}"; exit $? ;;
  --remove) remove_host_impl "${2:-}"; exit $? ;;
  --count) sed '/^[[:space:]]*$/d' "$HOSTS_FILE" | wc -l; exit 0 ;;
  "") ;;
  *) err "Ação inválida: $1"; exit 64 ;;
esac

while true; do
  header
  say "${C_WHITE}HOSTS DO PROXY${C_RESET}\n"
  say " 1) Listar hosts"
  say " 2) Adicionar host"
  say " 3) Remover host"
  say " 4) Importar payload.txt legado"
  say " 0) Voltar"
  say ""
  read -r -p "Opção: " opt
  case "$opt" in
    1) list_hosts ;;
    2) add_host ;;
    3) remove_host ;;
    4) import_legacy ;;
    0) exit 0 ;;
    *) warn "Opção inválida"; sleep 1 ;;
  esac
done
