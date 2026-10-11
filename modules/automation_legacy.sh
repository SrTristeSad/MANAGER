#!/usr/bin/env bash
set -Eeuo pipefail

MANAGER_HOME="${MANAGER_HOME:-/opt/manager}"
MANAGER_ETC="${MANAGER_ETC:-/etc/manager}"
# shellcheck source=/dev/null
source "$MANAGER_HOME/lib/common.sh"
# shellcheck source=/dev/null
source "$MANAGER_HOME/lib/identity.sh"
require_root

STATE_DIR="$MANAGER_ETC/automation/legacy"
CONFIG_FILE="$STATE_DIR/config"
SSHD_CONFIG="$STATE_DIR/sshd_config"
SERVICE_FILE="/etc/systemd/system/manager-automation-legacy.service"
MAIN_SSH_GUARD="/etc/ssh/sshd_config.d/64-manager-automation-legacy.conf"
SUDOERS_FILE="/etc/sudoers.d/manager-automation-legacy"
AUDIT_DIR="/var/log/manager"
AUDIT_FILE="$AUDIT_DIR/legacy-events.log"
LEGACY_USER="manager-legacy"
LEGACY_HOME="/var/lib/manager-legacy"
DEFAULT_PORT=22022
LIMITS_FILE="/etc/security/limits.d/99-manager-ssh.conf"
CONNECTION_MODULE="$MANAGER_HOME/modules/connection_engine.sh"
POLICY_MODULE="$MANAGER_HOME/modules/policy_engine.sh"
SESSION_MODULE="$MANAGER_HOME/modules/session_engine.sh"

ensure_dirs() {
  install -d -m 0700 "$STATE_DIR" "$AUDIT_DIR"
  touch "$AUDIT_FILE"
  chmod 0600 "$AUDIT_FILE"
}

config_get() {
  local key="$1"
  awk -F= -v k="$key" '$1==k {sub(/^[^=]*=/,""); print; exit}' "$CONFIG_FILE" 2>/dev/null || true
}

config_write() {
  local enabled="$1" port="$2" created="$3" updated tmp
  updated="$(date +%s)"
  tmp="$(mktemp)"
  {
    printf 'enabled=%s\n' "$enabled"
    printf 'port=%s\n' "$port"
    printf 'username=%s\n' "$LEGACY_USER"
    printf 'created_epoch=%s\n' "$created"
    printf 'updated_epoch=%s\n' "$updated"
  } > "$tmp"
  install -m 0600 "$tmp" "$CONFIG_FILE"
  rm -f "$tmp"
}

ensure_config() {
  local created
  ensure_dirs
  if [[ ! -f "$CONFIG_FILE" ]]; then
    created="$(date +%s)"
    config_write 0 "$DEFAULT_PORT" "$created"
  fi
}

validate_port() {
  [[ "${1:-}" =~ ^[0-9]+$ ]] || return 1
  (( 1 <= $1 && $1 <= 65535 ))
}

log_event() {
  local action="$1" subject="${2:-}" result="${3:-ok}"
  ensure_dirs
  printf '%s action=%s subject=%s result=%s\n' "$(date -Is)" "$action" "$subject" "$result" >> "$AUDIT_FILE"
}

ensure_dependencies() {
  local need=0
  command -v sshd >/dev/null 2>&1 || need=1
  command -v sudo >/dev/null 2>&1 || need=1
  command -v visudo >/dev/null 2>&1 || need=1
  if (( need == 1 )); then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y openssh-server sudo
  fi
  command -v sshd >/dev/null 2>&1 && command -v sudo >/dev/null 2>&1 && command -v visudo >/dev/null 2>&1
}

ensure_legacy_user() {
  if ! id "$LEGACY_USER" >/dev/null 2>&1; then
    useradd --system --create-home --home-dir "$LEGACY_HOME" --shell /bin/bash "$LEGACY_USER"
  fi
  install -d -o "$LEGACY_USER" -g "$LEGACY_USER" -m 0700 "$LEGACY_HOME"
}

legacy_shadow_hash() {
  getent shadow "$LEGACY_USER" 2>/dev/null | awk -F: '{print $2}'
}

legacy_has_password() {
  local hash
  hash="$(legacy_shadow_hash)"
  hash="${hash#!}"
  [[ -n "$hash" && "$hash" != '!' && "$hash" != '*' && "$hash" != '!!' ]]
}

generate_password() {
  od -An -N18 -tx1 /dev/urandom | tr -d ' \n'
}

set_random_password() {
  local pass
  pass="$(generate_password)"
  printf '%s:%s\n' "$LEGACY_USER" "$pass" | chpasswd
  printf '%s\n' "$pass"
}

write_main_ssh_guard() {
  local tmp
  install -d -m 0755 /etc/ssh/sshd_config.d
  tmp="$(mktemp)"
  cat > "$tmp" <<EOF
# Managed by MANAGER. The Legacy credential is never a normal SSH shell.
Match User $LEGACY_USER
    ForceCommand /usr/bin/false
    DisableForwarding yes
    PermitTTY no
    X11Forwarding no
Match all
EOF
  install -m 0644 "$tmp" "$MAIN_SSH_GUARD"
  rm -f "$tmp"

  if command -v sshd >/dev/null 2>&1; then
    install -d -m 0755 /run/sshd
    if ! sshd -t; then
      rm -f "$MAIN_SSH_GUARD"
      err "O guard do SSH principal não passou em sshd -t; alteração revertida."
      return 1
    fi
    systemctl reload ssh >/dev/null 2>&1 || systemctl reload sshd >/dev/null 2>&1 || true
  fi
}

write_sudoers() {
  local tmp
  tmp="$(mktemp)"
  cat > "$tmp" <<EOF
# Managed by MANAGER. This is the only privileged command exposed to the Legacy account.
Defaults:$LEGACY_USER env_keep += "SSH_ORIGINAL_COMMAND"
$LEGACY_USER ALL=(root) NOPASSWD: $MANAGER_HOME/modules/automation_legacy.sh --forced-command
EOF
  chmod 0440 "$tmp"
  if ! visudo -cf "$tmp" >/dev/null; then
    rm -f "$tmp"
    err "A regra sudoers do Legacy foi recusada por visudo."
    return 1
  fi
  install -m 0440 "$tmp" "$SUDOERS_FILE"
  rm -f "$tmp"
}

write_legacy_sshd_config() {
  local port="$1" tmp hostkey_count=0 key
  install -d -m 0755 /run/sshd
  ssh-keygen -A >/dev/null 2>&1 || true
  tmp="$(mktemp)"
  {
    printf 'Port %s\n' "$port"
    printf 'PidFile /run/manager-automation-legacy.pid\n'
    for key in /etc/ssh/ssh_host_ed25519_key /etc/ssh/ssh_host_rsa_key /etc/ssh/ssh_host_ecdsa_key; do
      if [[ -f "$key" ]]; then
        printf 'HostKey %s\n' "$key"
        hostkey_count=$((hostkey_count + 1))
      fi
    done
    printf 'UsePAM yes\n'
    printf 'PasswordAuthentication yes\n'
    printf 'PubkeyAuthentication no\n'
    printf 'KbdInteractiveAuthentication no\n'
    printf 'PermitRootLogin no\n'
    printf 'PermitEmptyPasswords no\n'
    printf 'AllowUsers %s\n' "$LEGACY_USER"
    printf 'AllowTcpForwarding no\n'
    printf 'AllowAgentForwarding no\n'
    printf 'X11Forwarding no\n'
    printf 'PermitTunnel no\n'
    printf 'GatewayPorts no\n'
    printf 'PermitTTY no\n'
    printf 'PermitUserEnvironment no\n'
    printf 'ForceCommand /usr/bin/sudo -n %s/modules/automation_legacy.sh --forced-command\n' "$MANAGER_HOME"
    printf 'LogLevel VERBOSE\n'
  } > "$tmp"

  if (( hostkey_count == 0 )); then
    rm -f "$tmp"
    err "Nenhuma HostKey SSH disponível para o listener Legacy."
    return 1
  fi
  install -m 0600 "$tmp" "$SSHD_CONFIG"
  rm -f "$tmp"
  sshd -t -f "$SSHD_CONFIG"
}

write_service() {
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=MANAGER Automation Legacy v1 compatibility SSH bridge
After=network.target
ConditionPathExists=$SSHD_CONFIG
ConditionPathExists=$SUDOERS_FILE

[Service]
Type=simple
ExecStart=/usr/sbin/sshd -D -e -f $SSHD_CONFIG
Restart=on-failure
RestartSec=2s

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "$SERVICE_FILE"
  systemctl daemon-reload
}

port_in_use_by_other() {
  local port="$1" current
  current="$(config_get port)"
  if systemctl is-active --quiet manager-automation-legacy.service 2>/dev/null && [[ "$port" == "$current" ]]; then
    return 1
  fi
  ss -H -ltn 2>/dev/null | awk -v p=":$port" '$4 ~ (p "$") {found=1} END {exit !found}'
}

update_limit_file() {
  local user="$1" limit="$2" tmp
  install -d -m 0755 "$(dirname "$LIMITS_FILE")"
  touch "$LIMITS_FILE"
  chmod 0644 "$LIMITS_FILE"
  tmp="$(mktemp)"
  awk -v u="$user" '$1 != u {print}' "$LIMITS_FILE" > "$tmp"
  if (( limit > 0 )); then
    printf '%s hard maxlogins %s\n' "$user" "$limit" >> "$tmp"
  fi
  install -m 0644 "$tmp" "$LIMITS_FILE"
  rm -f "$tmp"
}

identity_update_policy() {
  local id="$1" expires="$2" max="$3"
  local owner enabled protocols created ssh_user wg ovpn now
  identity_exists "$id" || return 0
  owner="$(identity_read "$id" owner)"
  enabled="$(identity_read "$id" enabled)"
  protocols="$(identity_read "$id" protocols)"
  created="$(identity_read "$id" created_epoch)"
  ssh_user="$(identity_read "$id" ssh_user)"
  wg="$(identity_read "$id" wireguard_client)"
  ovpn="$(identity_read "$id" openvpn_client)"
  now="$(date +%s)"
  ( flock -x 9; identity_write "$id" "$owner" "$enabled" "$expires" "$max" "$protocols" "$created" "$now" "$ssh_user" "$wg" "$ovpn" ) 9>"$IDENTITY_LOCK"
}

identity_clear_ssh_binding() {
  local id="$1" owner enabled expires max protocols created wg ovpn now
  identity_exists "$id" || return 0
  owner="$(identity_read "$id" owner)"
  enabled="$(identity_read "$id" enabled)"
  expires="$(identity_read "$id" expires_epoch)"
  max="$(identity_read "$id" max_sessions)"
  protocols="$(identity_read "$id" protocols)"
  created="$(identity_read "$id" created_epoch)"
  wg="$(identity_read "$id" wireguard_client)"
  ovpn="$(identity_read "$id" openvpn_client)"
  now="$(date +%s)"
  ( flock -x 9; identity_write "$id" "$owner" "$enabled" "$expires" "$max" "$protocols" "$created" "$now" '' "$wg" "$ovpn" ) 9>"$IDENTITY_LOCK"
}

legacy_managed_target() {
  local user="$1" bound
  [[ -n "$user" && "$user" != root && "$user" != "$LEGACY_USER" ]] || return 1
  id "$user" >/dev/null 2>&1 || return 1
  identity_exists "$user" || return 1
  bound="$(identity_read "$user" ssh_user)"
  [[ "$bound" == "$user" ]]
}

legacy_create() {
  local user="${1:-}" pass="${2:-}" days="${3:-}" limit="${4:-}" expiry_date expires_epoch
  if [[ -z "$user" ]]; then printf '4\n'; return 1; fi
  if id "$user" >/dev/null 2>&1; then printf '0\n'; return 1; fi
  if ! is_valid_username "$user"; then printf '1\n'; return 1; fi
  if (( ${#user} < 2 )); then printf '2\n'; return 1; fi
  if (( ${#user} > 32 )); then printf '3\n'; return 1; fi
  if [[ -z "$pass" ]]; then printf '5\n'; return 1; fi
  if (( ${#pass} > 128 )); then printf '6\n'; return 1; fi
  if [[ ! "$days" =~ ^[0-9]+$ ]]; then printf '7\n'; return 1; fi
  if (( days < 1 || days > 3650 )); then printf '9\n'; return 1; fi
  if [[ ! "$limit" =~ ^[0-9]+$ ]]; then printf '10\n'; return 1; fi
  if (( limit < 1 || limit > 50 )); then printf '12\n'; return 1; fi

  expiry_date="$(date -d "+$days days" '+%F')"
  expires_epoch="$(date -d "$expiry_date 23:59:59" '+%s')"

  if ! useradd -m -s /bin/bash -e "$expiry_date" "$user"; then
    printf '14\n'
    log_event create "$user" useradd-failed
    return 1
  fi
  if ! printf '%s:%s\n' "$user" "$pass" | chpasswd; then
    userdel -r "$user" >/dev/null 2>&1 || true
    printf '14\n'
    log_event create "$user" password-failed
    return 1
  fi
  update_limit_file "$user" "$limit"

  if [[ -x "$CONNECTION_MODULE" ]]; then
    if ! "$CONNECTION_MODULE" --import-name "$user" '' "$expires_epoch" "$limit" >/dev/null 2>&1; then
      userdel -r "$user" >/dev/null 2>&1 || userdel "$user" >/dev/null 2>&1 || true
      update_limit_file "$user" 0
      log_event create "$user" identity-import-failed
      printf '14\n'
      return 1
    fi
  fi
  log_event create "$user" ok
  printf '13\n'
}

legacy_remove() {
  local user="${1:-}"
  if ! legacy_managed_target "$user"; then
    printf '2\n'
    return 2
  fi
  "$CONNECTION_MODULE" --disable "$user" >/dev/null 2>&1 || true
  [[ -x "$SESSION_MODULE" ]] && "$SESSION_MODULE" --revoke-all "$user" >/dev/null 2>&1 || true
  pkill -TERM -u "$user" >/dev/null 2>&1 || true
  sleep 0.2
  pkill -KILL -u "$user" >/dev/null 2>&1 || true
  userdel -r "$user" >/dev/null 2>&1 || userdel "$user" >/dev/null 2>&1 || true
  update_limit_file "$user" 0
  identity_clear_ssh_binding "$user"
  log_event remove "$user" ok
  printf '1\n'
}

legacy_password() {
  local user="${1:-}" pass="${2:-}"
  legacy_managed_target "$user" || return 1
  [[ -n "$pass" ]] || return 1
  (( ${#pass} <= 128 )) || return 1
  printf '%s:%s\n' "$user" "$pass" | chpasswd
  pkill -TERM -u "$user" >/dev/null 2>&1 || true
  log_event password "$user" ok
  printf '1\n'
}

legacy_expiry() {
  local user="${1:-}" days="${2:-}" expiry_date expires_epoch max
  legacy_managed_target "$user" || return 1
  [[ "$days" =~ ^[0-9]+$ ]] || return 1
  (( days >= 1 && days <= 3650 )) || return 1
  expiry_date="$(date -d "+$days days" '+%F')"
  expires_epoch="$(date -d "$expiry_date 23:59:59" '+%s')"
  chage -E "$expiry_date" "$user"
  max="$(identity_read "$user" max_sessions)"
  [[ "$max" =~ ^[0-9]+$ ]] || max=1
  identity_update_policy "$user" "$expires_epoch" "$max"
  log_event expiry "$user" ok
  printf '1\n'
}

legacy_limit() {
  local user="${1:-}" limit="${2:-}" expires
  [[ "$limit" =~ ^[0-9]+$ ]] || { printf '2\n'; return 1; }
  (( limit >= 1 && limit <= 50 )) || { printf '3\n'; return 1; }
  legacy_managed_target "$user" || { printf '5\n'; return 1; }
  update_limit_file "$user" "$limit"
  expires="$(identity_read "$user" expires_epoch)"
  [[ "$expires" =~ ^[0-9]+$ ]] || expires=0
  identity_update_policy "$user" "$expires" "$limit"
  log_event limit "$user" ok
  printf '4\n'
}

legacy_kill() {
  local user="${1:-}"
  legacy_managed_target "$user" || { printf 'nao existe\n'; return 2; }
  pkill -TERM -u "$user" >/dev/null 2>&1 || true
  sleep 0.2
  pkill -KILL -u "$user" >/dev/null 2>&1 || true
  log_event disconnect "$user" ok
  printf '1\n'
}

legacy_monitor() {
  local file id user line total found=0
  identity_init
  for file in "$IDENTITY_DIR"/*.conf; do
    [[ -f "$file" ]] || continue
    id="$(awk -F= '$1=="id"{print $2; exit}' "$file")"
    user="$(awk -F= '$1=="ssh_user"{print $2; exit}' "$file")"
    [[ -n "$id" && -n "$user" ]] || continue
    total=0
    if [[ -x "$POLICY_MODULE" ]]; then
      line="$("$POLICY_MODULE" --sessions "$id" 2>/dev/null | tail -n1 || true)"
      if [[ "$line" =~ total=([0-9]+) ]]; then total="${BASH_REMATCH[1]}"; fi
    fi
    printf '%s,%s,\n' "$user" "$total"
    found=1
  done
  (( found == 1 )) || true
}

dispatch_command() {
  local raw="$1" cmd
  local -a argv=()
  raw="${raw//$'\r'/}"
  [[ -n "$raw" ]] || { printf '0\n'; return 64; }
  read -r -a argv <<< "$raw"
  (( ${#argv[@]} > 0 )) || { printf '0\n'; return 64; }
  cmd="${argv[0]##*/}"
  case "$cmd" in
    criarusuario.sh) [[ ${#argv[@]} -eq 5 ]] || { printf '14\n'; return 64; }; legacy_create "${argv[1]}" "${argv[2]}" "${argv[3]}" "${argv[4]}" ;;
    remover.sh) [[ ${#argv[@]} -eq 2 ]] || { printf '2\n'; return 64; }; legacy_remove "${argv[1]}" ;;
    AlterarSenha.sh) [[ ${#argv[@]} -eq 3 ]] || return 64; legacy_password "${argv[1]}" "${argv[2]}" ;;
    AlterarData.sh) [[ ${#argv[@]} -eq 3 ]] || return 64; legacy_expiry "${argv[1]}" "${argv[2]}" ;;
    alterarlimite.sh) [[ ${#argv[@]} -eq 3 ]] || { printf '2\n'; return 64; }; legacy_limit "${argv[1]}" "${argv[2]}" ;;
    KillUser.sh) [[ ${#argv[@]} -eq 2 ]] || return 64; legacy_kill "${argv[1]}" ;;
    sshmonitor.sh) [[ ${#argv[@]} -eq 1 ]] || return 64; legacy_monitor ;;
    *)
      log_event denied "$cmd" not-allowlisted
      printf '0\n'
      return 64
      ;;
  esac
}

legacy_enable() {
  local requested_port="${1:-}" port created password=""
  ensure_config
  port="$(config_get port)"
  [[ -n "$requested_port" ]] && port="$requested_port"
  validate_port "$port" || { err "Porta inválida: $port"; return 64; }
  if port_in_use_by_other "$port"; then
    err "A porta $port já está em uso."
    return 65
  fi
  ensure_dependencies || { err "openssh-server/sudo não puderam ser instalados ou localizados."; return 69; }
  ensure_legacy_user
  write_main_ssh_guard
  write_sudoers
  write_legacy_sshd_config "$port"
  write_service

  if legacy_has_password; then
    passwd -u "$LEGACY_USER" >/dev/null 2>&1 || true
  else
    password="$(set_random_password)"
  fi

  systemctl enable manager-automation-legacy.service >/dev/null
  systemctl restart manager-automation-legacy.service
  if ! systemctl is-active --quiet manager-automation-legacy.service; then
    passwd -l "$LEGACY_USER" >/dev/null 2>&1 || true
    rm -f "$SUDOERS_FILE"
    err "O listener Legacy não ficou ativo."
    return 70
  fi
  created="$(config_get created_epoch)"
  [[ "$created" =~ ^[0-9]+$ ]] || created="$(date +%s)"
  config_write 1 "$port" "$created"
  log_event enable "$port" ok

  printf 'enabled=1\n'
  printf 'login_server=%s\n' "$LEGACY_USER"
  printf 'porta=%s\n' "$port"
  if [[ -n "$password" ]]; then
    printf 'senha=%s\n' "$password"
    printf 'password_delivery=stdout-once\n'
  else
    printf 'senha=unchanged\n'
    printf 'password_delivery=preserved\n'
  fi
}

legacy_disable() {
  local port created
  ensure_config
  port="$(config_get port)"
  created="$(config_get created_epoch)"
  systemctl disable --now manager-automation-legacy.service >/dev/null 2>&1 || true
  rm -f "$SUDOERS_FILE"
  if id "$LEGACY_USER" >/dev/null 2>&1; then
    passwd -l "$LEGACY_USER" >/dev/null 2>&1 || true
  fi
  [[ "$created" =~ ^[0-9]+$ ]] || created="$(date +%s)"
  config_write 0 "${port:-$DEFAULT_PORT}" "$created"
  log_event disable "${port:-$DEFAULT_PORT}" ok
  printf 'enabled=0\n'
}

legacy_restart() {
  ensure_config
  [[ "$(config_get enabled)" == 1 ]] || { err "Legacy v1 está desativado."; return 68; }
  ensure_dependencies || return 69
  ensure_legacy_user
  write_main_ssh_guard
  write_sudoers
  write_legacy_sshd_config "$(config_get port)"
  write_service
  systemctl restart manager-automation-legacy.service
  systemctl is-active --quiet manager-automation-legacy.service
  log_event restart "$(config_get port)" ok
}

rotate_password() {
  local pass
  ensure_config
  [[ "$(config_get enabled)" == 1 ]] || { err "Ative o Legacy antes de trocar a senha."; return 68; }
  ensure_legacy_user
  pass="$(set_random_password)"
  log_event rotate-password "$LEGACY_USER" ok
  printf 'login_server=%s\n' "$LEGACY_USER"
  printf 'senha=%s\n' "$pass"
  printf 'password_delivery=stdout-once\n'
}

legacy_status() {
  local enabled port service locked="unknown" listening=0
  ensure_config
  enabled="$(config_get enabled)"
  port="$(config_get port)"
  if systemctl is-active --quiet manager-automation-legacy.service 2>/dev/null; then service=active; else service=inactive; fi
  if id "$LEGACY_USER" >/dev/null 2>&1; then
    case "$(passwd -S "$LEGACY_USER" 2>/dev/null | awk '{print $2}')" in
      L|LK) locked=1 ;;
      *) locked=0 ;;
    esac
  fi
  if validate_port "${port:-}" && ss -H -ltn 2>/dev/null | awk -v p=":$port" '$4 ~ (p "$") {found=1} END {exit !found}'; then
    listening=1
  fi
  printf 'contract=manager-automation-legacy-v1\n'
  printf 'enabled=%s\n' "${enabled:-0}"
  printf 'service=%s\n' "$service"
  printf 'login_server=%s\n' "$LEGACY_USER"
  printf 'porta=%s\n' "${port:-$DEFAULT_PORT}"
  printf 'port_listening=%s\n' "$listening"
  printf 'account_locked=%s\n' "$locked"
  printf 'transport=ssh-force-command\n'
  printf 'root_login=0\n'
  printf 'arbitrary_shell=0\n'
  printf 'plaintext_password_storage=0\n'
  printf 'commands=criarusuario.sh,remover.sh,AlterarSenha.sh,AlterarData.sh,alterarlimite.sh,KillUser.sh,sshmonitor.sh\n'
}

legacy_install() {
  local port created
  ensure_config
  [[ "$(config_get enabled)" == 1 ]] || return 0
  port="$(config_get port)"
  created="$(config_get created_epoch)"
  ensure_dependencies || return 69
  ensure_legacy_user
  if ! legacy_has_password; then
    [[ "$created" =~ ^[0-9]+$ ]] || created="$(date +%s)"
    config_write 0 "${port:-$DEFAULT_PORT}" "$created"
    passwd -l "$LEGACY_USER" >/dev/null 2>&1 || true
    err "A credencial Legacy não existe mais; o listener permaneceu desligado. Execute enable para gerar uma nova."
    return 68
  fi
  write_main_ssh_guard
  write_sudoers
  write_legacy_sshd_config "$port"
  write_service
  passwd -u "$LEGACY_USER" >/dev/null 2>&1 || true
  systemctl enable --now manager-automation-legacy.service >/dev/null 2>&1 || return 70
}

legacy_detach() {
  ensure_config
  systemctl disable --now manager-automation-legacy.service >/dev/null 2>&1 || true
  rm -f "$SERVICE_FILE" "$SUDOERS_FILE"
  if id "$LEGACY_USER" >/dev/null 2>&1; then
    passwd -l "$LEGACY_USER" >/dev/null 2>&1 || true
  fi
  rm -f "$MAIN_SSH_GUARD"
  systemctl daemon-reload >/dev/null 2>&1 || true
  if command -v sshd >/dev/null 2>&1; then
    install -d -m 0755 /run/sshd
    if sshd -t; then
      systemctl reload ssh >/dev/null 2>&1 || systemctl reload sshd >/dev/null 2>&1 || true
    fi
  fi
}

interactive_menu() {
  local opt port
  while true; do
    header
    say "${C_WHITE}AUTOMATION LEGACY v1${C_RESET}\n"
    legacy_status
    say "\n 1) Ativar"
    say " 2) Desativar"
    say " 3) Reiniciar"
    say " 4) Girar senha de integração"
    say " 0) Voltar"
    say ""
    read -r -p "Opção: " opt
    case "$opt" in
      1)
        read -r -p "Porta dedicada [$(config_get port)]: " port
        legacy_enable "${port:-$(config_get port)}" || true
        pause
        ;;
      2) legacy_disable || true; pause ;;
      3) legacy_restart || true; pause ;;
      4) rotate_password || true; pause ;;
      0) return 0 ;;
      *) warn "Opção inválida"; sleep 1 ;;
    esac
  done
}

ensure_config
case "${1:-}" in
  --init) printf '%s\n' "$STATE_DIR" ;;
  --install) legacy_install ;;
  --detach) legacy_detach ;;
  --status) legacy_status ;;
  --enable) legacy_enable "${2:-}" ;;
  --disable) legacy_disable ;;
  --restart) legacy_restart ;;
  --rotate-password) rotate_password ;;
  --forced-command)
    [[ "$(config_get enabled)" == 1 ]] || exit 68
    dispatch_command "${SSH_ORIGINAL_COMMAND:-}"
    ;;
  --dispatch)
    [[ $# -eq 2 ]] || { err "Uso interno: --dispatch 'comando args'"; exit 64; }
    dispatch_command "$2"
    ;;
  "") interactive_menu ;;
  *) err "Ação inválida: $1"; exit 64 ;;
esac
