#!/usr/bin/env bash
set -Eeuo pipefail

MANAGER_HOME="${MANAGER_HOME:-/opt/manager}"
# shellcheck source=/dev/null
source "$MANAGER_HOME/lib/common.sh"
require_root

LIMITS_FILE="/etc/security/limits.d/99-manager-ssh.conf"

is_regular_login_user() {
  local uid="$1" shell="$2"
  (( uid >= 1000 && uid < 65534 )) || return 1
  [[ ! "$shell" =~ (nologin|false)$ ]]
}

list_users() {
  header
  say "${C_WHITE}USUÁRIOS SSH${C_RESET}\n"
  printf '%-18s %-12s %-10s %-8s %-8s\n' "USUÁRIO" "EXPIRA" "ESTADO" "LOGINS" "LIMITE"
  printf '%-18s %-12s %-10s %-8s %-8s\n' "------------------" "------------" "----------" "--------" "--------"

  while IFS=: read -r user _ uid _ _ _ shell; do
    is_regular_login_user "$uid" "$shell" || continue
    local expiry logins limit state
    expiry="$(LANG=C chage -l "$user" 2>/dev/null | awk -F': ' '/Account expires/ {print $2}')"
    [[ "$expiry" == "never" ]] && expiry="nunca"
    [[ -z "$expiry" ]] && expiry="-"
    logins="$(who | awk -v u="$user" '$1==u {c++} END{print c+0}')"
    limit="$(awk -v u="$user" '$1==u && $3=="maxlogins" {print $4}' "$LIMITS_FILE" 2>/dev/null | tail -n1)"
    [[ -z "$limit" ]] && limit="-"
    state="$(passwd -S "$user" 2>/dev/null | awk '{print $2}')"
    case "$state" in L|LK) state="bloqueado" ;; P|PS) state="ativo" ;; NP) state="sem-senha" ;; *) state="-" ;; esac
    printf '%-18s %-12s %-10s %-8s %-8s\n' "$user" "$expiry" "$state" "$logins" "$limit"
  done < /etc/passwd
  say ""
  pause
}

online_sessions() {
  header
  say "${C_WHITE}SESSÕES ONLINE${C_RESET}\n"
  if ! who -u | sed -n '1,100p'; then
    warn "Não foi possível consultar sessões"
  fi
  say "\nConexões SSH estabelecidas:"
  ss -Htnp state established '( sport = :ssh or dport = :ssh )' 2>/dev/null | sed -n '1,100p' || true
  pause
}

create_user() {
  header
  say "${C_WHITE}CRIAR USUÁRIO SSH${C_RESET}\n"
  local user pass expiry limit
  read -r -p "Usuário: " user
  if ! is_valid_username "$user"; then err "Nome de usuário inválido"; pause; return; fi
  if id "$user" >/dev/null 2>&1; then err "Usuário já existe"; pause; return; fi

  read -r -s -p "Senha: " pass; echo
  [[ -n "$pass" ]] || { err "Senha vazia"; pause; return; }
  if (( ${#pass} < 8 )); then warn "Senha curta; prefira 8+ caracteres."; fi
  read -r -p "Data de expiração YYYY-MM-DD (vazio = sem expiração): " expiry
  if [[ -n "$expiry" ]] && ! date -d "$expiry" '+%F' >/dev/null 2>&1; then
    err "Data inválida"; pause; return
  fi
  read -r -p "Limite simultâneo [1] (0 = sem limite): " limit
  limit="${limit:-1}"
  [[ "$limit" =~ ^[0-9]+$ ]] && (( limit <= 50 )) || { err "Limite inválido"; pause; return; }

  useradd -m -s /bin/bash "$user"
  if ! printf '%s:%s\n' "$user" "$pass" | chpasswd; then
    userdel -r "$user" 2>/dev/null || true
    err "Falha ao definir senha; usuário revertido"
    pause
    return
  fi
  if [[ -n "$expiry" ]]; then chage -E "$expiry" "$user"; fi
  if (( limit > 0 )); then
    mkdir -p "$(dirname "$LIMITS_FILE")"
    printf '%s hard maxlogins %s\n' "$user" "$limit" >> "$LIMITS_FILE"
    chmod 0644 "$LIMITS_FILE"
  fi
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
  if ! grep -Rqs '^[[:space:]]*session.*pam_limits\.so' /etc/pam.d/sshd /etc/pam.d/common-session 2>/dev/null; then
    warn "Não detectei pam_limits.so no stack SSH. O limite foi salvo, mas a sua distro pode não aplicá-lo."
  fi
  ok "Limite atualizado"
  pause
}

lock_toggle() {
  header
  local user state
  read -r -p "Usuário: " user
  id "$user" >/dev/null 2>&1 || { err "Usuário não existe"; pause; return; }
  [[ "$user" != root ]] || { err "O MANAGER não bloqueia root"; pause; return; }
  state="$(passwd -S "$user" 2>/dev/null | awk '{print $2}')"
  if [[ "$state" == L || "$state" == LK ]]; then
    passwd -u "$user" >/dev/null
    ok "$user desbloqueado"
  else
    passwd -l "$user" >/dev/null
    pkill -KILL -u "$user" 2>/dev/null || true
    ok "$user bloqueado e sessões encerradas"
  fi
  pause
}

disconnect_user() {
  header
  local user
  read -r -p "Usuário para desconectar: " user
  id "$user" >/dev/null 2>&1 || { err "Usuário não existe"; pause; return; }
  [[ "$user" != root ]] || { err "O MANAGER não encerra processos de root"; pause; return; }
  if pgrep -u "$user" >/dev/null 2>&1; then
    pkill -TERM -u "$user" 2>/dev/null || true
    sleep 1
    pkill -KILL -u "$user" 2>/dev/null || true
    ok "Sessões/processos de $user encerrados"
  else
    info "$user não possui processos ativos"
  fi
  pause
}

while true; do
  header
  say "${C_WHITE}GERENCIAMENTO DE USUÁRIOS SSH${C_RESET}\n"
  say " 1) Listar usuários"
  say " 2) Sessões online"
  say " 3) Criar usuário"
  say " 4) Remover usuário"
  say " 5) Alterar senha"
  say " 6) Alterar expiração"
  say " 7) Limite de logins simultâneos"
  say " 8) Bloquear/desbloquear conta"
  say " 9) Desconectar usuário"
  say " 0) Voltar"
  say ""
  read -r -p "Opção: " opt
  case "$opt" in
    1) list_users ;;
    2) online_sessions ;;
    3) create_user ;;
    4) delete_user ;;
    5) change_password ;;
    6) change_expiry ;;
    7) set_login_limit ;;
    8) lock_toggle ;;
    9) disconnect_user ;;
    0) exit 0 ;;
    *) warn "Opção inválida"; sleep 1 ;;
  esac
done
