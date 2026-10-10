#!/usr/bin/env bash

set -o pipefail

MANAGER_HOME="${MANAGER_HOME:-/opt/manager}"
MANAGER_ETC="${MANAGER_ETC:-/etc/manager}"

if [[ -t 1 ]]; then
  C_RESET='\033[0m'
  C_RED='\033[1;31m'
  C_GREEN='\033[1;32m'
  C_YELLOW='\033[1;33m'
  C_BLUE='\033[1;34m'
  C_CYAN='\033[1;36m'
  C_WHITE='\033[1;37m'
else
  C_RESET='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_CYAN='' C_WHITE=''
fi

say() { printf '%b\n' "$*"; }
info() { say "${C_CYAN}[i]${C_RESET} $*"; }
ok() { say "${C_GREEN}[OK]${C_RESET} $*"; }
warn() { say "${C_YELLOW}[!]${C_RESET} $*"; }
err() { say "${C_RED}[ERRO]${C_RESET} $*" >&2; }

require_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    err "Execute como root: sudo -i"
    exit 1
  fi
}

pause() {
  printf '\nPressione ENTER para continuar...'
  read -r _
}

confirm() {
  local prompt="${1:-Continuar?}"
  local answer
  read -r -p "$prompt [s/N]: " answer
  [[ "$answer" =~ ^([sS]|[sS][iI][mM]|[yY]|[yY][eE][sS])$ ]]
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

service_state() {
  local service="$1"
  if systemctl is-active --quiet "$service" 2>/dev/null; then
    printf '%b' "${C_GREEN}ativo${C_RESET}"
  elif systemctl list-unit-files "$service.service" >/dev/null 2>&1; then
    printf '%b' "${C_RED}inativo${C_RESET}"
  else
    printf '%b' "${C_YELLOW}não instalado${C_RESET}"
  fi
}

header() {
  clear 2>/dev/null || true
  say "${C_BLUE}============================================================${C_RESET}"
  say "${C_WHITE}                         MANAGER${C_RESET}"
  say "${C_BLUE}============================================================${C_RESET}"
}

is_valid_username() {
  [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]]
}

is_valid_ipv4() {
  local ip="$1" IFS=. octets
  read -r -a octets <<< "$ip"
  [[ ${#octets[@]} -eq 4 ]] || return 1
  local o
  for o in "${octets[@]}"; do
    [[ "$o" =~ ^[0-9]{1,3}$ ]] || return 1
    (( o >= 0 && o <= 255 )) || return 1
  done
}
