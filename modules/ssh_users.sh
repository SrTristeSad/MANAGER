#!/usr/bin/env bash
set -Eeuo pipefail

MANAGER_HOME="${MANAGER_HOME:-/opt/manager}"
# shellcheck source=/dev/null
source "$MANAGER_HOME/lib/common.sh"
require_root

LIMITS_FILE="/etc/security/limits.d/99-manager-ssh.conf"

list_users() {
  header
  say "${C_WHITE}USUÁRIOS SSH${C_RESET}\n"
  printf '%-20s %-14s %-12s %-12s\n' "USUÁRIO" "EXPIRA" "LOGINS" "LIMITE"
  printf '%-20s %-14s %-12s %-12s\n' "--------------------" "--------------" "------------" "------------"

  while IFS=: read -r user _ uid _ _ _ shell; do
    (( uid >= 1000 )) || continue
    [[ "$shell" =~ (nologin|false)$ ]] && continue
    local expiry logins limit
    expiry="$(LANG=C chage -l "$user" 2>/dev/null | awk -F': ' '/Account expires/ {print $2}')"
    [[ "$expiry" == "never" ]] && expiry="nunca"
    [[ -z "$expiry" ]] && expiry="-"
    logins="$(who | awk -v u="$user" '$1==u {c++} END{print c+0}')"
    limit="$(awk -v u="$user" '$1==u && $3=="maxlogins" {print $4}' "$LIMITS_FILE" 2>/dev/null | tail -n1)"
    [[ -z "$limit" ]] && limit="-"
    printf '%-20s %-14s %-12s %-12s\n' "$user" "$expiry" "$logins" "$limit"
  done < /etc/passwd
  say ""
  pause
}

create_user() {
  header
  say "${C_WHITE}CRIAR USUÁRIO SSH${C_RESET}\n"
  local user pass expiry
  read -r -p "Usuário: " user
  if ! is_valid_username "$user"; then err "Nome de usuário inválido"; pause; return; fi
  if id "$user" >/dev/null 2>&1; then err "Usuário já existe"; pause; return; fi

  read -r -s -p "Senha: " pass; echo
  [[ -n "$pass" ]] || { err "Senha vazia"; pause; return; }
  read -r -p "Data de expiração YYYY-MM-DD (vazio = sem expiração): " expiry
  if [[ -n "$expiry" ]] && ! date -d "$expiry" '+%F' >/dev/null 2>&1; then
    err "Data inválida"; pause; return
  fi

  useradd -m -s /bin/bash "$user"
  printf '%s:%s\n' "$user" "$pass" | chpasswd
  if [[ -n "$expiry" ]]; then chage -E "$expiry" "$user"; fi
  ok "Usuário $user criado"
  pause
}

delete_user() {
  header
  local user
  read -r -p "Usuário para remover: " user
  id "$user" >/dev/null 2>&1 || { err "Usuário não existe"; pause; return; }
  if [[ "$user" == "root" ]]; then err "root não pode ser removido"; pause; return; fi
  if confirm "Remover $user e o diretório pessoal?"; then
    pkill -KILL -u "$user" 2>/dev/null || true
    userdel -r "$user" 2>/dev/null || userdel "$user"
    if [[ -f "$LIMITS_FILE" ]]; then sed -i "/^${user}[[:space:]]/d" "$LIMITS_FILE"; fi
    ok "Usuário removido"
  fi
  pause
}

change_password() {
  header
  local user pass
  read -r -p "Usuário: " user
  id "$user" >/dev/null 2>&1 || { err "Usuário não existe"; pause; return; }
  read -r -s -p "Nova senha: " pass; echo
  [[ -n "$pass" ]] || { err "Senha vazia"; pause; return; }
  printf '%s:%s\n' "$user" "$pass" | chpasswd
  ok "Senha alterada"
  pause
}

change_expiry() {
  header
  local user expiry
  read -r -p "Usuário: " user
  id "$user" >/dev/null 2>&1 || { err "Usuário não existe"; pause; return; }
  read -r -p "Nova expiração YYYY-MM-DD (vazio = nunca): " expiry
  if [[ -z "$expiry" ]]; then
    chage -E -1 "$user"
  elif date -d "$expiry" '+%F' >/dev/null 2>&1; then
    chage -E "$expiry" "$user"
  else
    err "Data inválida"; pause; return
  fi
  ok "Expiração atualizada"
  pause
}

set_login_limit() {
  header
  local user limit tmp
  read -r -p "Usuário: " user
  id "$user" >/dev/null 2>&1 || { err "Usuário não existe"; pause; return; }
  read -r -p "Máximo de logins simultâneos (1-50, 0 remove limite): " limit
  [[ "$limit" =~ ^[0-9]+$ ]] || { err "Valor inválido"; pause; return; }
  (( limit >= 0 && limit <= 50 )) || { err "Use um valor de 0 a 50"; pause; return; }

  mkdir -p "$(dirname "$LIMITS_FILE")"
  touch "$LIMITS_FILE"
  tmp="$(mktemp)"
  awk -v u="$user" '$1 != u {print}' "$LIMITS_FILE" > "$tmp"
  if (( limit > 0 )); then
    printf '%s hard maxlogins %s\n' "$user" "$limit" >> "$tmp"
  fi
  install -m 0644 "$tmp" "$LIMITS_FILE"
  rm -f "$tmp"
  ok "Limite atualizado"
  pause
}

while true; do
  header
  say "${C_WHITE}GERENCIAMENTO DE USUÁRIOS SSH${C_RESET}\n"
  say " 1) Listar usuários"
  say " 2) Criar usuário"
  say " 3) Remover usuário"
  say " 4) Alterar senha"
  say " 5) Alterar expiração"
  say " 6) Limite de logins simultâneos"
  say " 0) Voltar"
  say ""
  read -r -p "Opção: " opt
  case "$opt" in
    1) list_users ;;
    2) create_user ;;
    3) delete_user ;;
    4) change_password ;;
    5) change_expiry ;;
    6) set_login_limit ;;
    0) exit 0 ;;
    *) warn "Opção inválida"; sleep 1 ;;
  esac
done
