#!/usr/bin/env bash
set -Eeuo pipefail

MANAGER_HOME="${MANAGER_HOME:-/opt/manager}"
# shellcheck source=/dev/null
source "$MANAGER_HOME/lib/common.sh"
require_root

select_user() {
  local user
  read -r -p "Usuário: " user
  id "$user" >/dev/null 2>&1 || { err "Usuário não existe"; return 1; }
  [[ "$user" != root ]] || warn "Você está alterando chaves do root. Revise com cuidado."
  printf '%s' "$user"
}

home_of() { getent passwd "$1" | cut -d: -f6; }

ensure_ssh_dir() {
  local user="$1" home group
  home="$(home_of "$user")"
  group="$(id -gn "$user")"
  [[ -n "$home" && -d "$home" ]] || { err "Diretório home inválido para $user"; return 1; }
  install -d -m 0700 -o "$user" -g "$group" "$home/.ssh"
  touch "$home/.ssh/authorized_keys"
  chown "$user:$group" "$home/.ssh/authorized_keys"
  chmod 0600 "$home/.ssh/authorized_keys"
}

valid_pubkey() {
  local key="$1"
  [[ "$key" =~ ^(ssh-(rsa|ed25519)|ecdsa-sha2-nistp(256|384|521))[[:space:]]+[A-Za-z0-9+/=]+([[:space:]].*)?$ ]]
}

list_keys() {
  header
  local user home file
  user="$(select_user)" || { pause; return; }
  home="$(home_of "$user")"
  file="$home/.ssh/authorized_keys"
  say "\n${C_WHITE}CHAVES AUTORIZADAS: $user${C_RESET}\n"
  if [[ ! -s "$file" ]]; then
    info "Nenhuma chave cadastrada"
  else
    awk 'NF && $1 !~ /^#/ {comment=(NF>=3?$3:"sem-comentario"); printf "%3d) %-22s %s\n", ++n, $1, comment}' "$file"
    say "\nFingerprints:"
    ssh-keygen -lf "$file" 2>/dev/null || true
  fi
  pause
}

add_key() {
  header
  local user home file key tmp
  user="$(select_user)" || { pause; return; }
  ensure_ssh_dir "$user" || { pause; return; }
  home="$(home_of "$user")"
  file="$home/.ssh/authorized_keys"
  say "Cole UMA chave pública OpenSSH completa (ssh-ed25519/ssh-rsa/ecdsa):"
  IFS= read -r key
  valid_pubkey "$key" || { err "Formato de chave pública não reconhecido"; pause; return; }

  tmp="$(mktemp)"
  printf '%s\n' "$key" > "$tmp"
  if ! ssh-keygen -lf "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    err "ssh-keygen rejeitou a chave"
    pause
    return
  fi
  rm -f "$tmp"

  if grep -Fqx "$key" "$file" 2>/dev/null; then
    info "Essa chave já está cadastrada"
  else
    printf '%s\n' "$key" >> "$file"
    chown "$user:$(id -gn "$user")" "$file"
    chmod 0600 "$file"
    ok "Chave adicionada para $user"
  fi
  pause
}

remove_key() {
  header
  local user home file n tmp count
  user="$(select_user)" || { pause; return; }
  home="$(home_of "$user")"
  file="$home/.ssh/authorized_keys"
  [[ -s "$file" ]] || { info "Nenhuma chave cadastrada"; pause; return; }

  nl -ba "$file" | sed -n '1,100p'
  read -r -p "Número da linha para remover: " n
  [[ "$n" =~ ^[1-9][0-9]*$ ]] || { err "Número inválido"; pause; return; }
  count="$(wc -l < "$file")"
  (( n <= count )) || { err "Linha inexistente"; pause; return; }
  confirm "Remover a linha $n de authorized_keys?" || return

  tmp="$(mktemp)"
  awk -v n="$n" 'NR != n {print}' "$file" > "$tmp"
  install -m 0600 -o "$user" -g "$(id -gn "$user")" "$tmp" "$file"
  rm -f "$tmp"
  ok "Chave removida"
  pause
}

permissions_fix() {
  header
  local user home file
  user="$(select_user)" || { pause; return; }
  ensure_ssh_dir "$user" || { pause; return; }
  home="$(home_of "$user")"
  file="$home/.ssh/authorized_keys"
  chown -R "$user:$(id -gn "$user")" "$home/.ssh"
  chmod 0700 "$home/.ssh"
  chmod 0600 "$file"
  ok "Permissões corrigidas para $user"
  pause
}

while true; do
  header
  say "${C_WHITE}CHAVES SSH${C_RESET}\n"
  say " 1) Listar chaves de um usuário"
  say " 2) Adicionar chave pública"
  say " 3) Remover chave"
  say " 4) Corrigir permissões ~/.ssh"
  say " 0) Voltar"
  say ""
  read -r -p "Opção: " opt
  case "$opt" in
    1) list_keys ;;
    2) add_key ;;
    3) remove_key ;;
    4) permissions_fix ;;
    0) exit 0 ;;
    *) warn "Opção inválida"; sleep 1 ;;
  esac
done
