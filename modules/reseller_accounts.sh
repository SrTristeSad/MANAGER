#!/usr/bin/env bash
set -Eeuo pipefail

MANAGER_HOME="${MANAGER_HOME:-/opt/manager}"
MANAGER_ETC="${MANAGER_ETC:-/etc/manager}"
# shellcheck source=/dev/null
source "$MANAGER_HOME/lib/common.sh"
require_root

RESELLERS="$MANAGER_HOME/modules/resellers.sh"
LIMITS_FILE="/etc/security/limits.d/99-manager-ssh.conf"

require_reseller_engine() {
  [[ -x "$RESELLERS" ]] || { err "Módulo de revendedores ausente"; return 1; }
  "$RESELLERS" --init >/dev/null
}

set_limit() {
  local user="$1" limit="$2" tmp
  (( limit > 0 )) || return 0
  mkdir -p "$(dirname "$LIMITS_FILE")"
  touch "$LIMITS_FILE"
  tmp="$(mktemp)"
  awk -v u="$user" '$1 != u {print}' "$LIMITS_FILE" > "$tmp"
  printf '%s hard maxlogins %s\n' "$user" "$limit" >> "$tmp"
  install -m 0644 "$tmp" "$LIMITS_FILE"
  rm -f "$tmp"
}

remove_limit() {
  local user="$1" tmp
  [[ -f "$LIMITS_FILE" ]] || return 0
  tmp="$(mktemp)"
  awk -v u="$user" '$1 != u {print}' "$LIMITS_FILE" > "$tmp"
  install -m 0644 "$tmp" "$LIMITS_FILE"
  rm -f "$tmp"
}

rollback_user() {
  local user="$1"
  pkill -TERM -u "$user" 2>/dev/null || true
  userdel -r "$user" 2>/dev/null || userdel "$user" 2>/dev/null || true
  remove_limit "$user"
  rm -f "$MANAGER_ETC/access/owners/$user" 2>/dev/null || true
}

create_owned_account() {
  header
  say "${C_WHITE}CRIAR CONTA PARA REVENDEDOR${C_RESET}\n"
  require_reseller_engine || { pause; return; }

  local owner user pass expiry limit
  read -r -p "Revendedor/subrevendedor: " owner
  [[ -n "$owner" ]] || { err "Informe o proprietário"; pause; return; }
  if ! "$RESELLERS" --can-create "$owner" >/dev/null 2>&1; then
    err "Revendedor inexistente, bloqueado ou sem cota disponível"
    pause
    return
  fi

  read -r -p "Usuário SSH: " user
  is_valid_username "$user" || { err "Nome de usuário inválido"; pause; return; }
  id "$user" >/dev/null 2>&1 && { err "Usuário já existe"; pause; return; }

  read -r -s -p "Senha: " pass; echo
  [[ -n "$pass" ]] || { err "Senha vazia"; pause; return; }
  (( ${#pass} >= 8 )) || warn "Senha curta; prefira 8+ caracteres."

  read -r -p "Data de expiração YYYY-MM-DD (vazio = sem expiração): " expiry
  if [[ -n "$expiry" ]] && ! date -d "$expiry" '+%F' >/dev/null 2>&1; then
    err "Data inválida"
    pause
    return
  fi

  read -r -p "Limite simultâneo [1] (0 = sem limite): " limit
  limit="${limit:-1}"
  if [[ ! "$limit" =~ ^[0-9]+$ ]] || (( limit > 50 )); then
    err "Limite inválido"
    pause
    return
  fi

  useradd -m -s /bin/bash "$user"
  if ! printf '%s:%s\n' "$user" "$pass" | chpasswd; then
    rollback_user "$user"
    err "Falha ao definir senha; criação revertida"
    pause
    return
  fi

  if [[ -n "$expiry" ]] && ! chage -E "$expiry" "$user"; then
    rollback_user "$user"
    err "Falha ao definir expiração; criação revertida"
    pause
    return
  fi
  set_limit "$user" "$limit"

  # --assign repete a validação de cota sob lock. Se outra criação consumir
  # a última vaga entre a pré-checagem e este ponto, a conta é revertida.
  if ! "$RESELLERS" --assign "$user" "$owner"; then
    rollback_user "$user"
    err "A cota mudou durante a criação; usuário revertido para não ficar sem proprietário."
    pause
    return
  fi

  ok "Usuário $user criado e vinculado a $owner"
  printf '\n Usuário:      %s\n Proprietário: %s\n Expiração:    %s\n Limite:       %s\n' \
    "$user" "$owner" "${expiry:-nunca}" "$limit"
  say "\n${C_YELLOW}A senha não é armazenada pelo MANAGER.${C_RESET}"
  pause
}

show_owner() {
  header
  local user owner
  read -r -p "Usuário SSH: " user
  is_valid_username "$user" || { err "Usuário inválido"; pause; return; }
  owner="$($RESELLERS --owner "$user" 2>/dev/null || true)"
  if [[ -n "$owner" ]]; then
    printf 'Proprietário: %s\n' "$owner"
  else
    info "$user não possui revendedor registrado"
  fi
  pause
}

require_reseller_engine || exit 1
case "${1:-}" in
  --owner)
    is_valid_username "${2:-}" || exit 64
    exec "$RESELLERS" --owner "$2"
    ;;
  "") ;;
  *) err "Ação inválida: $1"; exit 64 ;;
esac

while true; do
  header
  say "${C_WHITE}CONTAS DE REVENDA${C_RESET}\n"
  say " 1) Criar usuário com cota/proprietário"
  say " 2) Consultar proprietário de usuário"
  say " 0) Voltar"
  say ""
  read -r -p "Opção: " opt
  case "$opt" in
    1) create_owned_account ;;
    2) show_owner ;;
    0) exit 0 ;;
    *) warn "Opção inválida"; sleep 1 ;;
  esac
done
