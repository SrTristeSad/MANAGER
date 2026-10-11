#!/usr/bin/env bash
set -Eeuo pipefail

MANAGER_HOME="${MANAGER_HOME:-/opt/manager}"
MANAGER_ETC="${MANAGER_ETC:-/etc/manager}"
# shellcheck source=/dev/null
source "$MANAGER_HOME/lib/common.sh"
# shellcheck source=/dev/null
source "$MANAGER_HOME/lib/identity.sh"
require_root

SESSION_ENGINE="$MANAGER_HOME/modules/session_engine.sh"
POLICY_ENGINE="$MANAGER_HOME/modules/policy_engine.sh"
BRIDGE_RUNTIME="${MANAGER_PROTOCOL_LEASE_RUNTIME:-/run/manager-protocol-leases}"
MAP_DIR="$BRIDGE_RUNTIME/maps"
BRIDGE_LOCK="$BRIDGE_RUNTIME/.lock"
BRIDGE_SERVICE="/etc/systemd/system/manager-protocol-leases.service"
BRIDGE_TIMER="/etc/systemd/system/manager-protocol-leases.timer"
PAM_SSHD="/etc/pam.d/sshd"
PAM_BEGIN="# MANAGER-PROTOCOL-LEASE-BEGIN"
PAM_END="# MANAGER-PROTOCOL-LEASE-END"
WG_CLIENT_DIR="$MANAGER_ETC/wireguard/clients"
OVPN_STATUS="/run/openvpn/manager-status.log"
LEASE_TTL="${MANAGER_PROTOCOL_LEASE_TTL:-75}"
WG_ACTIVE_WINDOW="${MANAGER_WG_ACTIVE_WINDOW:-180}"

bridge_init() {
  identity_init
  install -d -m 0700 "$BRIDGE_RUNTIME" "$MAP_DIR"
  touch "$BRIDGE_LOCK"
  chmod 0600 "$BRIDGE_LOCK"
}

valid_protocol() {
  case "${1:-}" in
    ssh|wireguard|openvpn) return 0 ;;
    *) return 1 ;;
  esac
}

valid_resource() { [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9_.:@-]{0,63}$ ]]; }
valid_device() { [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9_.:@-]{0,95}$ ]]; }
valid_pid() { [[ "${1:-}" =~ ^[1-9][0-9]*$ ]]; }

binding_for() {
  case "$1" in
    ssh) identity_read "$2" ssh_user ;;
    wireguard) identity_read "$2" wireguard_client ;;
    openvpn) identity_read "$2" openvpn_client ;;
    *) return 1 ;;
  esac
}

find_identity_by_binding() {
  local protocol="$1" resource="$2" file id bound
  identity_init
  for file in "$IDENTITY_DIR"/*.conf; do
    [[ -f "$file" ]] || continue
    id="${file##*/}"
    id="${id%.conf}"
    bound="$(binding_for "$protocol" "$id")"
    if [[ -n "$bound" && "$bound" == "$resource" ]]; then
      printf '%s\n' "$id"
      return 0
    fi
  done
  return 1
}

safe_fragment() {
  printf '%s' "${1:-unknown}" | tr -c 'A-Za-z0-9_.:@-' '_'
}

short_hash() {
  printf '%s' "$1" | sha256sum | awk '{print substr($1,1,20)}'
}

make_device() {
  local protocol="$1" resource="$2" fingerprint="$3" prefix digest
  prefix="$(safe_fragment "$resource")"
  prefix="${prefix:0:32}"
  digest="$(short_hash "$protocol|$resource|$fingerprint")"
  case "$protocol" in
    ssh) printf 'ssh-%s-%s\n' "$prefix" "$digest" ;;
    openvpn) printf 'ovpn-%s-%s\n' "$prefix" "$digest" ;;
    wireguard) printf 'wg-%s-%s\n' "$prefix" "$digest" ;;
  esac
}

map_path() {
  local protocol="$1" device="$2"
  printf '%s/%s-%s.map\n' "$MAP_DIR" "$protocol" "$(short_hash "$device")"
}

map_read_file() {
  local file="$1" key="$2"
  awk -F= -v k="$key" '$1==k {sub(/^[^=]*=/,""); print; exit}' "$file" 2>/dev/null || true
}

token_value() {
  local token="$1" key="$2"
  printf '%s\n' "$token" | tr '\t' '\n' | awk -F= -v k="$key" '$1==k {print $2; exit}'
}

write_map() {
  local protocol="$1" resource="$2" device="$3" identity="$4" session_id="$5" epoch="$6" source_pid="${7:-0}" remote="${8:--}" tty="${9:--}" file tmp
  file="$(map_path "$protocol" "$device")"
  tmp="$(mktemp)"
  {
    printf 'protocol=%s\n' "$protocol"
    printf 'resource=%s\n' "$resource"
    printf 'device=%s\n' "$device"
    printf 'identity_id=%s\n' "$identity"
    printf 'session_id=%s\n' "$session_id"
    printf 'session_epoch=%s\n' "$epoch"
    printf 'source_pid=%s\n' "$source_pid"
    printf 'remote=%s\n' "$remote"
    printf 'tty=%s\n' "$tty"
  } > "$tmp"
  install -m 0600 "$tmp" "$file"
  rm -f "$tmp"
}

release_map_file() {
  local file="$1" session_id epoch
  [[ -f "$file" ]] || return 0
  session_id="$(map_read_file "$file" session_id)"
  epoch="$(map_read_file "$file" session_epoch)"
  if [[ "$session_id" =~ ^[a-f0-9]{32}$ && "$epoch" =~ ^[1-9][0-9]*$ ]]; then
    "$SESSION_ENGINE" --release "$session_id" "$epoch" >/dev/null 2>&1 || true
  fi
  rm -f "$file"
}

release_device() {
  local protocol="$1" device="$2"
  release_map_file "$(map_path "$protocol" "$device")"
}

release_matching() {
  local protocol="$1" resource="$2" remote="${3:-}" tty="${4:-}" file
  for file in "$MAP_DIR"/*.map; do
    [[ -f "$file" ]] || continue
    [[ "$(map_read_file "$file" protocol)" == "$protocol" ]] || continue
    [[ "$(map_read_file "$file" resource)" == "$resource" ]] || continue
    if [[ -n "$remote" && "$(map_read_file "$file" remote)" != "$remote" ]]; then
      continue
    fi
    if [[ -n "$tty" && "$(map_read_file "$file" tty)" != "$tty" ]]; then
      continue
    fi
    release_map_file "$file"
  done
}

acquire_managed() {
  local protocol="$1" resource="$2" device="$3" source_pid="${4:-0}" remote="${5:--}" tty="${6:--}" identity token session_id epoch
  valid_protocol "$protocol" || return 64
  valid_resource "$resource" || return 64
  valid_device "$device" || return 64

  identity="$(find_identity_by_binding "$protocol" "$resource" 2>/dev/null || true)"
  [[ -n "$identity" ]] || return 0

  "$POLICY_ENGINE" --authorize "$protocol" "$resource" >/dev/null 2>&1 || return $?
  token="$("$SESSION_ENGINE" --acquire "$identity" "$protocol" "$resource" "$device" "$LEASE_TTL")" || return $?
  session_id="$(token_value "$token" session_id)"
  epoch="$(token_value "$token" epoch)"
  [[ "$session_id" =~ ^[a-f0-9]{32}$ && "$epoch" =~ ^[1-9][0-9]*$ ]] || return 70
  write_map "$protocol" "$resource" "$device" "$identity" "$session_id" "$epoch" "$source_pid" "$remote" "$tty"
}

heartbeat_map() {
  local file="$1" session_id epoch token new_epoch
  session_id="$(map_read_file "$file" session_id)"
  epoch="$(map_read_file "$file" session_epoch)"
  [[ "$session_id" =~ ^[a-f0-9]{32}$ && "$epoch" =~ ^[1-9][0-9]*$ ]] || { rm -f "$file"; return 1; }
  if token="$("$SESSION_ENGINE" --heartbeat "$session_id" "$epoch" "$LEASE_TTL" 2>/dev/null)"; then
    new_epoch="$(token_value "$token" epoch)"
    [[ "$new_epoch" =~ ^[1-9][0-9]*$ ]] && sed -i "s/^session_epoch=.*/session_epoch=$new_epoch/" "$file"
    return 0
  fi
  rm -f "$file"
  return 1
}

pam_ssh() {
  local pam_type="${PAM_TYPE:-}" user="${PAM_USER:-}" rhost tty fingerprint device source_pid
  user="$(safe_fragment "$user")"
  [[ -n "$user" ]] || return 0
  rhost="$(safe_fragment "${PAM_RHOST:-local}")"
  tty="$(safe_fragment "${PAM_TTY:-notty}")"
  source_pid="${PPID:-0}"
  fingerprint="$rhost|$tty|$source_pid"
  device="$(make_device ssh "$user" "$fingerprint")"

  case "$pam_type" in
    open_session)
      acquire_managed ssh "$user" "$device" "$source_pid" "$rhost" "$tty"
      ;;
    close_session)
      release_device ssh "$device"
      release_matching ssh "$user" "$rhost" "$tty"
      ;;
    *) return 0 ;;
  esac
}

openvpn_hook() {
  local event="${script_type:-}" client remote port fingerprint device
  client="$(safe_fragment "${common_name:-}")"
  [[ -n "$client" ]] || return 1
  remote="$(safe_fragment "${trusted_ip:-unknown}")"
  port="$(safe_fragment "${trusted_port:-0}")"
  fingerprint="$remote|$port"
  device="$(make_device openvpn "$client" "$fingerprint")"

  case "$event" in
    client-connect)
      acquire_managed openvpn "$client" "$device" 0 "$remote:$port" -
      ;;
    client-disconnect)
      release_device openvpn "$device"
      release_matching openvpn "$client" "$remote:$port"
      ;;
    *) return 0 ;;
  esac
}

openvpn_client_present() {
  local client="$1"
  [[ -f "$OVPN_STATUS" ]] || return 1
  awk -F, -v n="$client" '
    $1=="CLIENT_LIST" && $2==n {found=1}
    $0=="ROUTING TABLE" {legacy=0}
    $0=="Common Name,Real Address,Bytes Received,Bytes Sent,Connected Since" {legacy=1; next}
    legacy && $1==n {found=1}
    END {exit found ? 0 : 1}
  ' "$OVPN_STATUS" 2>/dev/null
}

reconcile_ssh_maps() {
  local file protocol pid
  for file in "$MAP_DIR"/*.map; do
    [[ -f "$file" ]] || continue
    protocol="$(map_read_file "$file" protocol)"
    [[ "$protocol" == ssh ]] || continue
    pid="$(map_read_file "$file" source_pid)"
    if valid_pid "$pid" && kill -0 "$pid" 2>/dev/null; then
      heartbeat_map "$file" || true
    else
      release_map_file "$file"
    fi
  done
}

reconcile_openvpn_maps() {
  local file protocol client
  for file in "$MAP_DIR"/*.map; do
    [[ -f "$file" ]] || continue
    protocol="$(map_read_file "$file" protocol)"
    [[ "$protocol" == openvpn ]] || continue
    client="$(map_read_file "$file" resource)"
    if openvpn_client_present "$client"; then
      heartbeat_map "$file" || true
    else
      release_map_file "$file"
    fi
  done
}

wg_recent_handshake() {
  local client="$1" meta pub last now
  meta="$WG_CLIENT_DIR/$client.meta"
  [[ -f "$meta" ]] || return 1
  command_exists wg || return 1
  wg show wg0 >/dev/null 2>&1 || return 1
  pub="$(awk -F= '$1=="public_key"{print $2; exit}' "$meta" 2>/dev/null || true)"
  [[ -n "$pub" ]] || return 1
  last="$(wg show wg0 latest-handshakes 2>/dev/null | awk -v p="$pub" '$1==p {print $2; exit}')"
  [[ "$last" =~ ^[0-9]+$ ]] || return 1
  (( last > 0 )) || return 1
  now="$(date +%s)"
  (( now - last <= WG_ACTIVE_WINDOW ))
}

wg_remove_runtime_peer() {
  local client="$1" meta pub
  meta="$WG_CLIENT_DIR/$client.meta"
  [[ -f "$meta" ]] || return 0
  command_exists wg || return 0
  pub="$(awk -F= '$1=="public_key"{print $2; exit}' "$meta" 2>/dev/null || true)"
  [[ -n "$pub" ]] || return 0
  wg set wg0 peer "$pub" remove 2>/dev/null || true
}

reconcile_wireguard() {
  local file id client device map
  for file in "$IDENTITY_DIR"/*.conf; do
    [[ -f "$file" ]] || continue
    id="${file##*/}"
    id="${id%.conf}"
    client="$(identity_read "$id" wireguard_client)"
    [[ -n "$client" ]] || continue
    device="$(make_device wireguard "$client" "$client")"
    map="$(map_path wireguard "$device")"
    if wg_recent_handshake "$client"; then
      if [[ -f "$map" ]]; then
        heartbeat_map "$map" || true
      elif ! acquire_managed wireguard "$client" "$device" 0 - -; then
        wg_remove_runtime_peer "$client"
      fi
    else
      release_map_file "$map"
    fi
  done
}

reconcile_all() {
  bridge_init
  "$SESSION_ENGINE" --reconcile >/dev/null 2>&1 || true
  reconcile_ssh_maps
  reconcile_openvpn_maps
  reconcile_wireguard
}

remove_pam_block() {
  local tmp
  [[ -f "$PAM_SSHD" ]] || return 0
  grep -Fqx "$PAM_BEGIN" "$PAM_SSHD" 2>/dev/null || return 0
  tmp="$(mktemp)"
  awk -v begin="$PAM_BEGIN" -v end="$PAM_END" '
    $0==begin {skip=1; next}
    $0==end {skip=0; next}
    !skip {print}
  ' "$PAM_SSHD" > "$tmp"
  install -m 0644 "$tmp" "$PAM_SSHD"
  rm -f "$tmp"
}

install_pam_hook() {
  local pam_exec
  [[ -f "$PAM_SSHD" ]] || { warn "$PAM_SSHD não existe; integração SSH por PAM não foi instalada."; return 0; }
  pam_exec="$(find /lib /usr/lib -type f -name pam_exec.so -print -quit 2>/dev/null || true)"
  [[ -n "$pam_exec" ]] || { warn "pam_exec.so não encontrado; integração SSH por lease ficou desativada."; return 0; }
  remove_pam_block
  cat >> "$PAM_SSHD" <<EOF

$PAM_BEGIN
session required pam_exec.so quiet $MANAGER_HOME/modules/protocol_leases.sh --pam-ssh
$PAM_END
EOF
}

install_units() {
  bridge_init
  install_pam_hook
  cat > "$BRIDGE_SERVICE" <<EOF
[Unit]
Description=MANAGER real protocol to session lease bridge
After=network-online.target manager-session-cleanup.service

[Service]
Type=oneshot
ExecStart=$MANAGER_HOME/modules/protocol_leases.sh --reconcile
EOF

  cat > "$BRIDGE_TIMER" <<'EOF'
[Unit]
Description=MANAGER protocol session lease heartbeat

[Timer]
OnBootSec=10s
OnUnitActiveSec=20s
AccuracySec=3s
Persistent=true
Unit=manager-protocol-leases.service

[Install]
WantedBy=timers.target
EOF
  chmod 0644 "$BRIDGE_SERVICE" "$BRIDGE_TIMER"
  systemctl daemon-reload
  systemctl enable --now manager-protocol-leases.timer >/dev/null 2>&1 || true
}

detach_bridge() {
  local file
  bridge_init
  systemctl disable --now manager-protocol-leases.timer >/dev/null 2>&1 || true
  rm -f "$BRIDGE_SERVICE" "$BRIDGE_TIMER"
  remove_pam_block
  for file in "$MAP_DIR"/*.map; do
    [[ -f "$file" ]] || continue
    release_map_file "$file"
  done
  rm -rf "$BRIDGE_RUNTIME"
  systemctl daemon-reload || true
}

bridge_init
case "${1:-}" in
  --install) ( flock -x 9; install_units ) 9>"$BRIDGE_LOCK" ;;
  --detach) ( flock -x 9; detach_bridge ) 9>"$BRIDGE_LOCK" ;;
  --reconcile) ( flock -x 9; reconcile_all ) 9>"$BRIDGE_LOCK" ;;
  --pam-ssh) ( flock -x 9; pam_ssh ) 9>"$BRIDGE_LOCK" ;;
  --openvpn-hook) ( flock -x 9; openvpn_hook ) 9>"$BRIDGE_LOCK" ;;
  --observe-connect)
    [[ -n "${2:-}" && -n "${3:-}" && -n "${4:-}" ]] || exit 64
    ( flock -x 9; acquire_managed "$2" "$3" "$4" "${5:-0}" "${6:--}" "${7:--}" ) 9>"$BRIDGE_LOCK"
    ;;
  --observe-disconnect)
    [[ -n "${2:-}" && -n "${3:-}" ]] || exit 64
    ( flock -x 9; release_device "$2" "$3" ) 9>"$BRIDGE_LOCK"
    ;;
  --runtime) printf '%s\n' "$BRIDGE_RUNTIME" ;;
  *)
    err "Uso: protocol_leases.sh --install|--detach|--reconcile|--pam-ssh|--openvpn-hook"
    exit 64
    ;;
esac
