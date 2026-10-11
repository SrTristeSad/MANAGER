#!/usr/bin/env bash
set -Eeuo pipefail

MANAGER_HOME="${MANAGER_HOME:-/opt/manager}"
MANAGER_ETC="${MANAGER_ETC:-/etc/manager}"
# shellcheck source=/dev/null
source "$MANAGER_HOME/lib/common.sh"
# shellcheck source=/dev/null
source "$MANAGER_HOME/lib/identity.sh"
require_root

SESSION_RUNTIME="${MANAGER_SESSION_RUNTIME:-/run/manager-session-leases}"
LEASE_DIR="$SESSION_RUNTIME/active"
SESSION_LOCK="$SESSION_RUNTIME/.lock"
EPOCH_DIR="$IDENTITY_ROOT/session-epochs"
EVENT_LOG="/var/log/manager/session-events.log"
CLEANUP_SERVICE="/etc/systemd/system/manager-session-cleanup.service"
CLEANUP_TIMER="/etc/systemd/system/manager-session-cleanup.timer"
RECONCILE_PATH="/etc/systemd/system/manager-session-reconcile.path"
DEFAULT_TTL="${MANAGER_SESSION_TTL:-90}"
NODE_METADATA_MODULE="$MANAGER_HOME/modules/node_metadata.sh"

session_init() {
  identity_init
  install -d -m 0700 "$SESSION_RUNTIME" "$LEASE_DIR" "$EPOCH_DIR"
  install -d -m 0750 "$(dirname "$EVENT_LOG")"
  touch "$SESSION_LOCK" "$EVENT_LOG"
  chmod 0600 "$SESSION_LOCK" "$EVENT_LOG"
}

valid_protocol() {
  case "${1:-}" in
    ssh|wireguard|openvpn) return 0 ;;
    *) return 1 ;;
  esac
}

valid_resource() { [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9_.:@-]{0,63}$ ]]; }
valid_device() { [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9_.:@-]{0,95}$ ]]; }
valid_reason() { [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9_.:-]{0,63}$ ]]; }
valid_ttl() { [[ "${1:-}" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 86400 )); }
valid_session_id() { [[ "${1:-}" =~ ^[a-f0-9]{32}$ ]]; }

lease_file() { printf '%s/%s.lease\n' "$LEASE_DIR" "$1"; }
epoch_file() { printf '%s/%s.epoch\n' "$EPOCH_DIR" "$1"; }

lease_read() {
  local session_id="$1" key="$2"
  awk -F= -v k="$key" '$1==k {sub(/^[^=]*=/,""); print; exit}' "$(lease_file "$session_id")" 2>/dev/null || true
}

binding_for() {
  case "$1" in
    ssh) identity_read "$2" ssh_user ;;
    wireguard) identity_read "$2" wireguard_client ;;
    openvpn) identity_read "$2" openvpn_client ;;
    *) return 1 ;;
  esac
}

node_context_value() {
  local context="$1" key="$2"
  awk -F= -v k="$key" '$1==k {sub(/^[^=]*=/,""); print; exit}' <<< "$context"
}

authorize_node_context() {
  local identity="$1" protocol="$2" quiet="${3:-0}" context="" region="" pool="" node=""
  declare -F product_context_authorized >/dev/null 2>&1 || return 0
  if [[ -x "$NODE_METADATA_MODULE" ]]; then
    context="$($NODE_METADATA_MODULE --context 2>/dev/null || true)"
    region="$(node_context_value "$context" region)"
    pool="$(node_context_value "$context" pool)"
    node="$(node_context_value "$context" node)"
  fi
  if product_context_authorized "$identity" "$protocol" "$region" "$pool" "$node"; then
    return 0
  fi
  if [[ "$quiet" != 1 ]]; then
    err "Produto/ACL não autoriza $protocol para $identity neste nó (region=${region:--}, pool=${pool:--}, node=${node:--})"
  fi
  return 73
}

event_log() {
  local action="$1" identity="$2" session_id="${3:--}" epoch="${4:--}" protocol="${5:--}" resource="${6:--}" device="${7:--}" reason="${8:--}"
  printf '%s\t%s\tidentity=%s\tsession=%s\tepoch=%s\tprotocol=%s\tresource=%s\tdevice=%s\treason=%s\n' \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$action" "$identity" "$session_id" "$epoch" "$protocol" "$resource" "$device" "$reason" >> "$EVENT_LOG"
}

current_epoch_locked() {
  local identity="$1" file epoch
  file="$(epoch_file "$identity")"
  if [[ ! -f "$file" ]]; then
    printf '1\n' > "$file"
    chmod 0600 "$file"
  fi
  epoch="$(tr -d '[:space:]' < "$file")"
  if [[ ! "$epoch" =~ ^[1-9][0-9]*$ ]]; then
    epoch=1
    printf '1\n' > "$file"
    chmod 0600 "$file"
  fi
  printf '%s\n' "$epoch"
}

bump_epoch_locked() {
  local identity="$1" current next file tmp
  current="$(current_epoch_locked "$identity")"
  next=$((current + 1))
  file="$(epoch_file "$identity")"
  tmp="$(mktemp)"
  printf '%s\n' "$next" > "$tmp"
  install -m 0600 "$tmp" "$file"
  rm -f "$tmp"
  printf '%s\n' "$next"
}

write_lease_locked() {
  local session_id="$1" identity="$2" protocol="$3" resource="$4" device="$5" epoch="$6" created="$7" heartbeat="$8" expires="$9" tmp
  tmp="$(mktemp)"
  {
    printf 'session_id=%s\n' "$session_id"
    printf 'identity_id=%s\n' "$identity"
    printf 'protocol=%s\n' "$protocol"
    printf 'resource=%s\n' "$resource"
    printf 'device_id=%s\n' "$device"
    printf 'session_epoch=%s\n' "$epoch"
    printf 'created_epoch=%s\n' "$created"
    printf 'heartbeat_epoch=%s\n' "$heartbeat"
    printf 'expires_epoch=%s\n' "$expires"
  } > "$tmp"
  install -m 0600 "$tmp" "$(lease_file "$session_id")"
  rm -f "$tmp"
}

cleanup_expired_locked() {
  local now file session_id identity epoch protocol resource device expires
  now="$(date +%s)"
  for file in "$LEASE_DIR"/*.lease; do
    [[ -f "$file" ]] || continue
    session_id="${file##*/}"; session_id="${session_id%.lease}"
    expires="$(lease_read "$session_id" expires_epoch)"
    [[ "$expires" =~ ^[0-9]+$ ]] || { rm -f "$file"; continue; }
    (( now >= expires )) || continue
    identity="$(lease_read "$session_id" identity_id)"
    epoch="$(lease_read "$session_id" session_epoch)"
    protocol="$(lease_read "$session_id" protocol)"
    resource="$(lease_read "$session_id" resource)"
    device="$(lease_read "$session_id" device_id)"
    event_log EXPIRE "$identity" "$session_id" "$epoch" "$protocol" "$resource" "$device" ttl
    rm -f "$file"
  done
}

revoke_identity_leases_locked() {
  local identity="$1" reason="$2" file session_id lease_identity epoch protocol resource device
  for file in "$LEASE_DIR"/*.lease; do
    [[ -f "$file" ]] || continue
    session_id="${file##*/}"; session_id="${session_id%.lease}"
    lease_identity="$(lease_read "$session_id" identity_id)"
    [[ "$lease_identity" == "$identity" ]] || continue
    epoch="$(lease_read "$session_id" session_epoch)"
    protocol="$(lease_read "$session_id" protocol)"
    resource="$(lease_read "$session_id" resource)"
    device="$(lease_read "$session_id" device_id)"
    event_log REVOKE "$identity" "$session_id" "$epoch" "$protocol" "$resource" "$device" "$reason"
    rm -f "$file"
  done
}

reconcile_leases_locked() {
  local file session_id identity lease_epoch current_epoch protocol resource device state bound reason new_epoch
  local -A invalidate=()

  cleanup_expired_locked
  for file in "$LEASE_DIR"/*.lease; do
    [[ -f "$file" ]] || continue
    session_id="${file##*/}"; session_id="${session_id%.lease}"
    identity="$(lease_read "$session_id" identity_id)"
    lease_epoch="$(lease_read "$session_id" session_epoch)"
    protocol="$(lease_read "$session_id" protocol)"
    resource="$(lease_read "$session_id" resource)"
    device="$(lease_read "$session_id" device_id)"

    if ! identity_valid_id "$identity" || ! identity_exists "$identity"; then
      event_log REVOKE "$identity" "$session_id" "$lease_epoch" "$protocol" "$resource" "$device" identity-missing
      rm -f "$file"
      continue
    fi

    current_epoch="$(current_epoch_locked "$identity")"
    if [[ "$lease_epoch" != "$current_epoch" ]]; then
      event_log REVOKE "$identity" "$session_id" "$lease_epoch" "$protocol" "$resource" "$device" stale-epoch
      rm -f "$file"
      continue
    fi

    state="$(identity_effective_state "$identity")"
    if [[ "$state" != active ]]; then
      invalidate["$identity"]="policy-$state"
      continue
    fi
    if ! identity_has_protocol "$identity" "$protocol"; then
      invalidate["$identity"]="protocol-denied"
      continue
    fi
    if ! authorize_node_context "$identity" "$protocol" 1; then
      invalidate["$identity"]="acl-context"
      continue
    fi
    bound="$(binding_for "$protocol" "$identity")"
    if [[ -z "$bound" || "$bound" != "$resource" ]]; then
      invalidate["$identity"]="binding-changed"
    fi
  done

  for identity in "${!invalidate[@]}"; do
    reason="${invalidate[$identity]}"
    new_epoch="$(bump_epoch_locked "$identity")"
    revoke_identity_leases_locked "$identity" "$reason"
    event_log FENCE "$identity" - "$new_epoch" - - - "$reason"
  done
}

validate_identity_resource() {
  local identity="$1" protocol="$2" resource="$3" state bound
  identity_valid_id "$identity" || { err "ID de identidade inválido"; return 64; }
  identity_exists "$identity" || { err "Identidade não existe: $identity"; return 66; }
  valid_protocol "$protocol" || { err "Protocolo inválido: $protocol"; return 64; }
  valid_resource "$resource" || { err "Recurso inválido: $resource"; return 64; }
  state="$(identity_effective_state "$identity")"
  [[ "$state" == active ]] || { err "Identidade $identity está $state"; return 68; }
  identity_has_protocol "$identity" "$protocol" || { err "$protocol não é permitido para $identity"; return 67; }
  authorize_node_context "$identity" "$protocol" || return $?
  bound="$(binding_for "$protocol" "$identity")"
  [[ -n "$bound" ]] || { err "Identidade $identity não possui recurso $protocol vinculado"; return 66; }
  [[ "$bound" == "$resource" ]] || { err "Recurso $resource não pertence a $identity em $protocol"; return 67; }
}

active_count_locked() {
  local identity="$1" current_epoch="$2" now file session_id lease_identity lease_epoch expires count=0
  now="$(date +%s)"
  for file in "$LEASE_DIR"/*.lease; do
    [[ -f "$file" ]] || continue
    session_id="${file##*/}"; session_id="${session_id%.lease}"
    lease_identity="$(lease_read "$session_id" identity_id)"
    [[ "$lease_identity" == "$identity" ]] || continue
    lease_epoch="$(lease_read "$session_id" session_epoch)"
    expires="$(lease_read "$session_id" expires_epoch)"
    [[ "$lease_epoch" == "$current_epoch" ]] || continue
    [[ "$expires" =~ ^[0-9]+$ ]] || continue
    (( expires > now )) || continue
    count=$((count + 1))
  done
  printf '%s\n' "$count"
}

find_same_lease_locked() {
  local identity="$1" protocol="$2" resource="$3" device="$4" current_epoch="$5" now file session_id expires
  now="$(date +%s)"
  for file in "$LEASE_DIR"/*.lease; do
    [[ -f "$file" ]] || continue
    session_id="${file##*/}"; session_id="${session_id%.lease}"
    [[ "$(lease_read "$session_id" identity_id)" == "$identity" ]] || continue
    [[ "$(lease_read "$session_id" protocol)" == "$protocol" ]] || continue
    [[ "$(lease_read "$session_id" resource)" == "$resource" ]] || continue
    [[ "$(lease_read "$session_id" device_id)" == "$device" ]] || continue
    [[ "$(lease_read "$session_id" session_epoch)" == "$current_epoch" ]] || continue
    expires="$(lease_read "$session_id" expires_epoch)"
    [[ "$expires" =~ ^[0-9]+$ ]] || continue
    (( expires > now )) || continue
    printf '%s\n' "$session_id"
    return 0
  done
  return 1
}

generate_session_id() { od -An -N16 -tx1 /dev/urandom | tr -d ' \n'; }

print_lease_token() {
  local session_id="$1"
  printf 'session_id=%s\tepoch=%s\texpires_epoch=%s\n' \
    "$session_id" "$(lease_read "$session_id" session_epoch)" "$(lease_read "$session_id" expires_epoch)"
}

acquire_locked() {
  local identity="$1" protocol="$2" resource="$3" device="$4" ttl="$5" current_epoch max active existing now expires session_id created
  validate_identity_resource "$identity" "$protocol" "$resource" || return $?
  valid_device "$device" || { err "device_id inválido"; return 64; }
  valid_ttl "$ttl" || { err "TTL inválido; use 1-86400 segundos"; return 64; }
  reconcile_leases_locked
  current_epoch="$(current_epoch_locked "$identity")"

  existing="$(find_same_lease_locked "$identity" "$protocol" "$resource" "$device" "$current_epoch" 2>/dev/null || true)"
  if [[ -n "$existing" ]]; then
    now="$(date +%s)"
    expires=$((now + ttl))
    created="$(lease_read "$existing" created_epoch)"
    [[ "$created" =~ ^[0-9]+$ ]] || created="$now"
    write_lease_locked "$existing" "$identity" "$protocol" "$resource" "$device" "$current_epoch" "$created" "$now" "$expires"
    event_log RENEW "$identity" "$existing" "$current_epoch" "$protocol" "$resource" "$device" acquire-retry
    print_lease_token "$existing"
    return 0
  fi

  max="$(identity_read "$identity" max_sessions)"
  [[ "$max" =~ ^[1-9][0-9]*$ ]] || { err "max_sessions inválido em $identity"; return 64; }
  active="$(active_count_locked "$identity" "$current_epoch")"
  if (( active >= max )); then
    err "Limite de sessões atingido para $identity ($active/$max)"
    return 69
  fi

  session_id="$(generate_session_id)"
  now="$(date +%s)"
  expires=$((now + ttl))
  write_lease_locked "$session_id" "$identity" "$protocol" "$resource" "$device" "$current_epoch" "$now" "$now" "$expires"
  event_log ACQUIRE "$identity" "$session_id" "$current_epoch" "$protocol" "$resource" "$device" node-acl
  print_lease_token "$session_id"
}

heartbeat_locked() {
  local session_id="$1" supplied_epoch="$2" ttl="$3" identity stored_epoch current_epoch protocol resource device created now expires state
  valid_session_id "$session_id" || { err "session_id inválido"; return 64; }
  [[ "$supplied_epoch" =~ ^[1-9][0-9]*$ ]] || { err "session_epoch inválido"; return 64; }
  valid_ttl "$ttl" || { err "TTL inválido; use 1-86400 segundos"; return 64; }
  reconcile_leases_locked
  [[ -f "$(lease_file "$session_id")" ]] || { err "Lease inexistente ou expirada"; return 66; }
  identity="$(lease_read "$session_id" identity_id)"
  stored_epoch="$(lease_read "$session_id" session_epoch)"
  current_epoch="$(current_epoch_locked "$identity")"
  [[ "$stored_epoch" == "$supplied_epoch" && "$current_epoch" == "$supplied_epoch" ]] || { err "Fence rejeitado: epoch antigo"; return 70; }
  state="$(identity_effective_state "$identity")"
  [[ "$state" == active ]] || { err "Identidade $identity está $state"; return 68; }
  protocol="$(lease_read "$session_id" protocol)"
  resource="$(lease_read "$session_id" resource)"
  device="$(lease_read "$session_id" device_id)"
  validate_identity_resource "$identity" "$protocol" "$resource" || return $?
  created="$(lease_read "$session_id" created_epoch)"
  now="$(date +%s)"
  expires=$((now + ttl))
  write_lease_locked "$session_id" "$identity" "$protocol" "$resource" "$device" "$stored_epoch" "$created" "$now" "$expires"
  event_log HEARTBEAT "$identity" "$session_id" "$stored_epoch" "$protocol" "$resource" "$device" node-acl
  print_lease_token "$session_id"
}

release_locked() {
  local session_id="$1" supplied_epoch="$2" identity stored_epoch protocol resource device
  valid_session_id "$session_id" || { err "session_id inválido"; return 64; }
  [[ "$supplied_epoch" =~ ^[1-9][0-9]*$ ]] || { err "session_epoch inválido"; return 64; }
  [[ -f "$(lease_file "$session_id")" ]] || return 0
  identity="$(lease_read "$session_id" identity_id)"
  stored_epoch="$(lease_read "$session_id" session_epoch)"
  [[ "$stored_epoch" == "$supplied_epoch" ]] || { err "Fence rejeitado: epoch não corresponde à lease"; return 70; }
  protocol="$(lease_read "$session_id" protocol)"
  resource="$(lease_read "$session_id" resource)"
  device="$(lease_read "$session_id" device_id)"
  event_log RELEASE "$identity" "$session_id" "$stored_epoch" "$protocol" "$resource" "$device" client
  rm -f "$(lease_file "$session_id")"
}

revoke_all_locked() {
  local identity="$1" reason="$2" new_epoch
  identity_valid_id "$identity" || { err "ID de identidade inválido"; return 64; }
  identity_exists "$identity" || { err "Identidade não existe: $identity"; return 66; }
  valid_reason "$reason" || { err "Motivo inválido"; return 64; }
  cleanup_expired_locked
  new_epoch="$(bump_epoch_locked "$identity")"
  revoke_identity_leases_locked "$identity" "$reason"
  event_log FENCE "$identity" - "$new_epoch" - - - "$reason"
  printf 'epoch=%s\n' "$new_epoch"
}

switch_locked() {
  local identity="$1" protocol="$2" resource="$3" device="$4" ttl="$5" new_epoch
  validate_identity_resource "$identity" "$protocol" "$resource" || return $?
  valid_device "$device" || { err "device_id inválido"; return 64; }
  valid_ttl "$ttl" || { err "TTL inválido; use 1-86400 segundos"; return 64; }
  cleanup_expired_locked
  new_epoch="$(bump_epoch_locked "$identity")"
  revoke_identity_leases_locked "$identity" switch
  event_log FENCE "$identity" - "$new_epoch" "$protocol" "$resource" "$device" switch
  acquire_locked "$identity" "$protocol" "$resource" "$device" "$ttl"
}

list_locked() {
  local wanted="${1:-}" now file session_id identity epoch protocol resource device heartbeat expires remaining
  reconcile_leases_locked
  now="$(date +%s)"
  for file in "$LEASE_DIR"/*.lease; do
    [[ -f "$file" ]] || continue
    session_id="${file##*/}"; session_id="${session_id%.lease}"
    identity="$(lease_read "$session_id" identity_id)"
    [[ -z "$wanted" || "$identity" == "$wanted" ]] || continue
    epoch="$(lease_read "$session_id" session_epoch)"
    protocol="$(lease_read "$session_id" protocol)"
    resource="$(lease_read "$session_id" resource)"
    device="$(lease_read "$session_id" device_id)"
    heartbeat="$(lease_read "$session_id" heartbeat_epoch)"
    expires="$(lease_read "$session_id" expires_epoch)"
    remaining=0
    [[ "$expires" =~ ^[0-9]+$ ]] && (( expires > now )) && remaining=$((expires - now))
    printf '%s\t%s\tepoch=%s\tprotocol=%s\tresource=%s\tdevice=%s\theartbeat=%s\texpires=%s\tremaining=%ss\n' \
      "$identity" "$session_id" "$epoch" "$protocol" "$resource" "$device" "$heartbeat" "$expires" "$remaining"
  done
}

show_epoch_locked() {
  local identity="$1"
  identity_valid_id "$identity" || return 64
  identity_exists "$identity" || return 66
  current_epoch_locked "$identity"
}

install_units() {
  session_init
  cat > "$CLEANUP_SERVICE" <<EOF
[Unit]
Description=MANAGER local session lease reconciliation
After=local-fs.target

[Service]
Type=oneshot
ExecStart=$MANAGER_HOME/modules/session_engine.sh --reconcile
EOF

  cat > "$CLEANUP_TIMER" <<'EOF'
[Unit]
Description=MANAGER local session lease expiry/reconciliation

[Timer]
OnBootSec=15s
OnUnitActiveSec=30s
AccuracySec=5s
Persistent=true
Unit=manager-session-cleanup.service

[Install]
WantedBy=timers.target
EOF

  cat > "$RECONCILE_PATH" <<EOF
[Unit]
Description=MANAGER session lease policy change watcher

[Path]
PathChanged=$IDENTITY_CHANGED
Unit=manager-session-cleanup.service

[Install]
WantedBy=multi-user.target
EOF

  chmod 0644 "$CLEANUP_SERVICE" "$CLEANUP_TIMER" "$RECONCILE_PATH"
  systemctl daemon-reload
  systemctl enable --now manager-session-cleanup.timer manager-session-reconcile.path >/dev/null 2>&1 || true
}

detach_units() {
  systemctl disable --now manager-session-cleanup.timer manager-session-reconcile.path >/dev/null 2>&1 || true
  rm -f "$CLEANUP_SERVICE" "$CLEANUP_TIMER" "$RECONCILE_PATH"
  rm -rf "$SESSION_RUNTIME"
  systemctl daemon-reload || true
}

interactive_menu() {
  local opt identity
  while true; do
    header
    say "${C_WHITE}SESSION / LEASE ENGINE${C_RESET}\n"
    say " 1) Listar leases ativas"
    say " 2) Listar leases de uma identidade"
    say " 3) Revogar todas as leases de uma identidade (novo epoch)"
    say " 4) Reconciliar / limpar leases"
    say " 0) Voltar"
    say ""
    read -r -p "Opção: " opt
    case "$opt" in
      1) header; ( flock -x 9; list_locked ) 9>"$SESSION_LOCK"; pause ;;
      2) read -r -p "Identidade: " identity; header; ( flock -x 9; list_locked "$identity" ) 9>"$SESSION_LOCK"; pause ;;
      3)
        read -r -p "Identidade: " identity
        if confirm "Revogar todas as leases de $identity e avançar o session_epoch?"; then
          ( flock -x 8; flock -x 9; revoke_all_locked "$identity" admin-menu ) 8>"$IDENTITY_LOCK" 9>"$SESSION_LOCK"
        fi
        pause
        ;;
      4) ( flock -x 8; flock -x 9; reconcile_leases_locked ) 8>"$IDENTITY_LOCK" 9>"$SESSION_LOCK"; ok "Reconciliação concluída"; pause ;;
      0) return 0 ;;
      *) warn "Opção inválida"; sleep 1 ;;
    esac
  done
}

session_init
case "${1:-}" in
  --init) printf '%s\n' "$SESSION_RUNTIME" ;;
  --install) install_units ;;
  --detach) detach_units ;;
  --cleanup) ( flock -x 9; cleanup_expired_locked ) 9>"$SESSION_LOCK" ;;
  --reconcile) ( flock -x 8; flock -x 9; reconcile_leases_locked ) 8>"$IDENTITY_LOCK" 9>"$SESSION_LOCK" ;;
  --list) ( flock -x 8; flock -x 9; list_locked "${2:-}" ) 8>"$IDENTITY_LOCK" 9>"$SESSION_LOCK" ;;
  --epoch) ( flock -x 8; flock -x 9; show_epoch_locked "${2:-}" ) 8>"$IDENTITY_LOCK" 9>"$SESSION_LOCK" ;;
  --acquire) ( flock -x 8; flock -x 9; acquire_locked "${2:-}" "${3:-}" "${4:-}" "${5:-local}" "${6:-$DEFAULT_TTL}" ) 8>"$IDENTITY_LOCK" 9>"$SESSION_LOCK" ;;
  --heartbeat) ( flock -x 8; flock -x 9; heartbeat_locked "${2:-}" "${3:-}" "${4:-$DEFAULT_TTL}" ) 8>"$IDENTITY_LOCK" 9>"$SESSION_LOCK" ;;
  --release) ( flock -x 9; release_locked "${2:-}" "${3:-}" ) 9>"$SESSION_LOCK" ;;
  --revoke-all) ( flock -x 8; flock -x 9; revoke_all_locked "${2:-}" "${3:-admin}" ) 8>"$IDENTITY_LOCK" 9>"$SESSION_LOCK" ;;
  --switch) ( flock -x 8; flock -x 9; switch_locked "${2:-}" "${3:-}" "${4:-}" "${5:-local}" "${6:-$DEFAULT_TTL}" ) 8>"$IDENTITY_LOCK" 9>"$SESSION_LOCK" ;;
  "") interactive_menu ;;
  *)
    err "Uso: session_engine.sh --list [ID]|--acquire ID PROTOCOLO RECURSO [DEVICE] [TTL]|--heartbeat SESSION_ID EPOCH [TTL]|--release SESSION_ID EPOCH|--revoke-all ID [MOTIVO]|--switch ID PROTOCOLO RECURSO [DEVICE] [TTL]|--epoch ID|--cleanup|--reconcile"
    exit 64
    ;;
esac
