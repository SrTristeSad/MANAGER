#!/usr/bin/env bash
set -Eeuo pipefail

MANAGER_HOME="${MANAGER_HOME:-/opt/manager}"
MANAGER_ETC="${MANAGER_ETC:-/etc/manager}"
# shellcheck source=/dev/null
source "$MANAGER_HOME/lib/common.sh"
require_root

LIMITS_FILE="/etc/security/limits.d/99-manager-ssh.conf"
TEST_DIR="$MANAGER_ETC/ssh-tests"
TEST_SERVICE="/etc/systemd/system/manager-test-users.service"
TEST_TIMER="/etc/systemd/system/manager-test-users.timer"

is_regular_login_user() {
  local uid="$1" shell="$2"
  (( uid >= 1000 && uid < 65534 )) || return 1
  [[ ! "$shell" =~ (nologin|false)$ ]]
}

remove_limit_entry() {
  local user="$1" tmp
  [[ -f "$LIMITS_FILE" ]] || return 0
  tmp="$(mktemp)"
  awk -v u="$user" '$1 != u {print}' "$LIMITS_FILE" > "$tmp"
  install -m 0644 "$tmp" "$LIMITS_FILE"
  rm -f "$tmp"
}

safe_delete_user() {
  local user="$1"
  [[ "$user" != root ]] || return 1
  id "$user" >/dev/null 2>&1 || {
    rm -f "$TEST_DIR/$user" 2>/dev/null || true
    remove_limit_entry "$user"
    return 0
  }
  pkill -TERM -u "$user" 2>/dev/null || true
  sleep 0.2
  pkill -KILL -u "$user" 2>/dev/null || true
  userdel -r "$user" 2>/dev/null || userdel "$user"
  remove_limit_entry "$user"
  rm -f "$TEST_DIR/$user" 2>/dev/null || true
}

ensure_test_timer() {
  mkdir -p "$TEST_DIR"
  chmod 0700 "$TEST_DIR"

  cat > "$TEST_SERVICE" <<EOF
[Unit]
Description=MANAGER - remove expired SSH test accounts
After=local-fs.target

[Service]
Type=oneshot
ExecStart=$MANAGER_HOME/modules/ssh_users.sh --cleanup-tests
EOF

  cat > "$TEST_TIMER" <<'EOF'
[Unit]
Description=MANAGER - check SSH test account expiry

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
AccuracySec=15s
Persistent=true
Unit=manager-test-users.service

[Install]
WantedBy=timers.target
EOF

  chmod 0644 "$TEST_SERVICE" "$TEST_TIMER"
  systemctl daemon-reload
  systemctl enable --now manager-test-users.timer >/dev/null
}

cleanup_test_users() {
  local now meta user expiry removed=0
  now="$(date +%s)"
  mkdir -p "$TEST_DIR"
  chmod 0700 "$TEST_DIR"

  for meta in "$TEST_DIR"/*; do
    [[ -f "$meta" ]] || continue
    user="${meta##*/}"
    is_valid_username "$user" || continue
    expiry="$(awk -F= '$1=="expires_epoch" {print $2; exit}' "$meta" 2>/dev/null || true)"
    [[ "$expiry" =~ ^[0-9]+$ ]] || continue
    if (( now >= expiry )); then
      safe_delete_user "$user" || true
      removed=$((removed + 1))
      printf '[MANAGER] Conta teste expirada removida: %s\n' "$user"
    fi
  done

  return 0
}

account_expiry_days() {
  getent shadow "$1" 2>/dev/null | awk -F: '{print $8}'
}

is_account_expired() {
  local user="$1" expiry today
  expiry="$(account_expiry_days "$user")"
  [[ "$expiry" =~ ^[0-9]+$ ]] || return 1
  today=$(( $(date +%s) / 86400 ))
  (( expiry <= today ))
}

list_expired_usernames() {
  local user uid shell
  while IFS=: read -r user _ uid _ _ _ shell; do
    is_regular_login_user "$uid" "$shell" || continue
    is_account_expired "$user" && printf '%s\n' "$user"
  done < /etc/passwd
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
  if [[ ! "$limit" =~ ^[0-9]+$ ]] || (( limit > 50 )); then
    err "Limite inválido"
    pause
    return
  fi

  mkdir -p "$TEST_DIR"
  rm -f "$TEST_DIR/$user"
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

create_test_user() {
  header
  say "${C_WHITE}CRIAR USUÁRIO TESTE${C_RESET}\n"
  local user minutes limit pass now expires_epoch backstop stamp
  read -r -p "Duração em minutos [60]: " minutes
  minutes="${minutes:-60}"
  [[ "$minutes" =~ ^[0-9]+$ ]] && (( minutes >= 1 && minutes <= 10080 )) || {
    err "Use de 1 a 10080 minutos (até 7 dias)."
    pause
    return
  }

  read -r -p "Usuário (vazio = gerar automaticamente): " user
  if [[ -z "$user" ]]; then
    stamp="$(date +%s)"
    user="teste${stamp: -6}"
  fi
  is_valid_username "$user" || { err "Nome de usuário inválido"; pause; return; }
  id "$user" >/dev/null 2>&1 && { err "Usuário já existe"; pause; return; }

  read -r -p "Limite simultâneo [1]: " limit
  limit="${limit:-1}"
  [[ "$limit" =~ ^[1-9][0-9]*$ ]] && (( limit <= 50 )) || {
    err "Limite inválido (1-50)."
    pause
    return
  }

  pass="$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"
  now="$(date +%s)"
  expires_epoch=$((now + minutes * 60))
  backstop="$(date -d "@$((expires_epoch + 86400))" '+%F')"

  useradd -m -s /bin/bash "$user"
  if ! printf '%s:%s\n' "$user" "$pass" | chpasswd; then
    userdel -r "$user" 2>/dev/null || true
    err "Falha ao definir senha; usuário revertido"
    pause
    return
  fi
  chage -E "$backstop" "$user"

  mkdir -p "$(dirname "$LIMITS_FILE")" "$TEST_DIR"
  chmod 0700 "$TEST_DIR"
  printf '%s hard maxlogins %s\n' "$user" "$limit" >> "$LIMITS_FILE"
  chmod 0644 "$LIMITS_FILE"
  printf 'expires_epoch=%s\ncreated_epoch=%s\n' "$expires_epoch" "$now" > "$TEST_DIR/$user"
  chmod 0600 "$TEST_DIR/$user"
  ensure_test_timer

  ok "Conta teste criada"
  printf '\n Usuário: %s\n Senha:   %s\n Expira:  %s\n Limite:  %s\n' \
    "$user" "$pass" "$(date -d "@$expires_epoch" '+%F %T %Z')" "$limit"
  say "\n${C_YELLOW}A senha é exibida somente agora e não é armazenada pelo MANAGER.${C_RESET}"
  pause
}

list_test_users() {
  header
  say "${C_WHITE}USUÁRIOS TESTE${C_RESET}\n"
  local meta user expiry now remaining found=0
  now="$(date +%s)"
  printf '%-20s %-22s %-12s\n' "USUÁRIO" "EXPIRA" "RESTANTE"
  printf '%-20s %-22s %-12s\n' "--------------------" "----------------------" "------------"
  for meta in "$TEST_DIR"/*; do
    [[ -f "$meta" ]] || continue
    user="${meta##*/}"
    expiry="$(awk -F= '$1=="expires_epoch" {print $2; exit}' "$meta" 2>/dev/null || true)"
    [[ "$expiry" =~ ^[0-9]+$ ]] || continue
    found=1
    if (( expiry <= now )); then
      remaining="expirado"
    else
      remaining="$(( (expiry - now + 59) / 60 )) min"
    fi
    printf '%-20s %-22s %-12s\n' "$user" "$(date -d "@$expiry" '+%F %T')" "$remaining"
  done
  (( found == 1 )) || info "Nenhuma conta teste registrada"
  pause
}

delete_user() {
  header
  local user
  read -r -p "Usuário para remover: " user
  id "$user" >/dev/null 2>&1 || { err "Usuário não existe"; pause; return; }
  if [[ "$user" == "root" ]]; then err "root não pode ser removido"; pause; return; fi
  if confirm "Remover $user e o diretório pessoal?"; then
    safe_delete_user "$user"
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
  if [[ -f "$TEST_DIR/$user" ]]; then
    warn "$user é uma conta teste. O temporizador em minutos continuará valendo."
  fi
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

show_expired_users() {
  header
  say "${C_WHITE}USUÁRIOS EXPIRADOS${C_RESET}\n"
  local users=()
  mapfile -t users < <(list_expired_usernames)
  if (( ${#users[@]} == 0 )); then
    info "Nenhuma conta SSH expirada"
  else
    printf '%s\n' "${users[@]}"
    say "\nTotal: ${#users[@]}"
  fi
  pause
}

cleanup_expired_users_interactive() {
  header
  say "${C_WHITE}LIMPEZA DE EXPIRADOS${C_RESET}\n"
  local users=() user
  mapfile -t users < <(list_expired_usernames)
  if (( ${#users[@]} == 0 )); then
    info "Nenhuma conta SSH expirada"
    pause
    return
  fi
  printf '%s\n' "${users[@]}"
  say "\n${C_YELLOW}Isso remove as contas acima e seus diretórios pessoais.${C_RESET}"
  confirm "Remover ${#users[@]} conta(s) expirada(s)?" || { pause; return; }
  for user in "${users[@]}"; do
    safe_delete_user "$user" || warn "Falha ao remover $user"
  done
  ok "Limpeza concluída"
  pause
}

case "${1:-}" in
  --cleanup-tests)
    cleanup_test_users
    exit 0
    ;;
  --list-expired)
    list_expired_usernames
    exit 0
    ;;
  "") ;;
  *)
    err "Ação inválida: $1"
    exit 2
    ;;
esac

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
  say "10) Criar usuário teste"
  say "11) Listar usuários teste"
  say "12) Listar expirados"
  say "13) Limpar expirados"
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
    10) create_test_user ;;
    11) list_test_users ;;
    12) show_expired_users ;;
    13) cleanup_expired_users_interactive ;;
    0) exit 0 ;;
    *) warn "Opção inválida"; sleep 1 ;;
  esac
done
