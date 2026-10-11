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
BRIDGE_RUNTIME="${MANAGER_PROTOCOL_LEASE_RUNTIME:-/run/manager-protocol-leases}"
MAP_DIR="$BRIDGE_RUNTIME/maps"
OVPN_REQ_DIR="$BRIDGE_RUNTIME/openvpn-requests"
OVPN_RESP_DIR="$BRIDGE_RUNTIME/openvpn-responses"
FIREWALL_DIR="$BRIDGE_RUNTIME/firewall"
BRIDGE_LOCK="$BRIDGE_RUNTIME/.lock"
BRIDGE_SERVICE="/etc/systemd/system/manager-protocol-leases.service"
BRIDGE_TIMER="/etc/systemd/system/manager-protocol-leases.timer"
OVPN_QUEUE_SERVICE="/etc/systemd/system/manager-openvpn-lease-queue.service"
OVPN_QUEUE_PATH="/etc/systemd/system/manager-openvpn-lease-queue.path"
SSH_PAM_HOOK="/usr/local/libexec/manager-ssh-lease-hook"
OVPN_CLIENT_HOOK="/usr/local/libexec/manager-openvpn-lease-hook"
PAM_SSHD="/etc/pam.d/sshd"
PAM_BEGIN="# MANAGER-PROTOCOL-LEASE-BEGIN"
PAM_END="# MANAGER-PROTOCOL-LEASE-END"
WG_CLIENT_DIR="$MANAGER_ETC/wireguard/clients"
OVPN_CONF="/etc/openvpn/server/manager.conf"
OVPN_STATUS="/run/openvpn/manager-status.log"
OVPN_POLICY_BEGIN="# MANAGER-IDENTITY-POLICY-BEGIN"
OVPN_POLICY_END="# MANAGER-IDENTITY-POLICY-END"
OVPN_RESTART_PENDING="$BRIDGE_RUNTIME/openvpn-lease-hook-pending-restart"
OVPN_GROUP="manager-openvpn"
LEASE_TTL="${MANAGER_PROTOCOL_LEASE_TTL:-60}"
WG_ACTIVE_WINDOW="${MANAGER_WG_ACTIVE_WINDOW:-180}"
ADOPTION_GRACE="${MANAGER_PROTOCOL_ADOPTION_GRACE:-10}"

bridge_init() {
  identity_init
  install -d -m 0700 "$BRIDGE_RUNTIME" "$MAP_DIR" "$FIREWALL_DIR"
  if ! getent group "$OVPN_GROUP" >/dev/null 2>&1; then
    groupadd --system "$OVPN_GROUP" >/dev/null 2>&1 || true
  fi
  if getent group "$OVPN_GROUP" >/dev/null 2>&1; then
    install -d -o root -g "$OVPN_GROUP" -m 0730 "$OVPN_REQ_DIR"
    install -d -o root -g "$OVPN_GROUP" -m 0710 "$OVPN_RESP_DIR"
  else
    install -d -m 0700 "$OVPN_REQ_DIR" "$OVPN_RESP_DIR"
  fi
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
valid_remote() { [[ "${1:-}" =~ ^[A-Za-z0-9_.:@-]{1,128}$ ]]; }

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

normalize_tty() {
  local tty="${1:-notty}"
  tty="${tty#/dev/}"
  safe_fragment "$tty"
}

normalize_remote() {
  local remote="${1:-local}"
  remote="${remote#(}"
  remote="${remote%)}"
  safe_fragment "$remote"
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

map_in_adoption_grace() {
  local file="$1" created now
  created="$(map_read_file "$file" created_epoch)"
  [[ "$created" =~ ^[0-9]+$ && "$ADOPTION_GRACE" =~ ^[0-9]+$ ]] || return 1
  now="$(date +%s)"
  (( now >= created && now - created <= ADOPTION_GRACE ))
}

token_value() {
  local token="$1" key="$2"
  printf '%s\n' "$token" | tr '\t' '\n' | awk -F= -v k="$key" '$1==k {print $2; exit}'
}

write_map() {
  local protocol="$1" resource="$2" device="$3" identity="$4" session_id="$5" epoch="$6" source_pid="${7:-0}" remote="${8:--}" tty="${9:--}" file tmp now
  file="$(map_path "$protocol" "$device")"
  tmp="$(mktemp)"
  now="$(date +%s)"
  {
    printf 'protocol=%s\n' "$protocol"
    printf 'resource=%s\n' "$resource"
    printf 'device=%s\n' "$device"
    printf 'identity_id=%s\n' "$identity"
    printf 'session_id=%s\n' "$session_id"
    printf 'session_epoch=%s\n' "$epoch"
    printf 'created_epoch=%s\n' "$now"
    printf 'source_pid=%s\n' "$source_pid"
    printf 'remote=%s\n' "$remote"
    printf 'tty=%s\n' "$tty"
  } > "$tmp"
  install -m 0600 "$tmp" "$file"
  rm -f "$tmp"
}

has_map_for_resource() {
  local protocol="$1" resource="$2" file
  for file in "$MAP_DIR"/*.map; do
    [[ -f "$file" ]] || continue
    [[ "$(map_read_file "$file" protocol)" == "$protocol" ]] || continue
    [[ "$(map_read_file "$file" resource)" == "$resource" ]] || continue
    return 0
  done
  return 1
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
    if [[ "$new_epoch" =~ ^[1-9][0-9]*$ ]]; then
      sed -i "s/^session_epoch=.*/session_epoch=$new_epoch/" "$file"
    fi
    return 0
  fi
  rm -f "$file"
  return 1
}

pam_ssh() {
  local pam_type="${PAM_TYPE:-}" user rhost tty fingerprint device source_pid
  user="$(safe_fragment "${PAM_USER:-}")"
  [[ -n "$user" ]] || return 0
  rhost="$(normalize_remote "${PAM_RHOST:-local}")"
  tty="$(normalize_tty "${PAM_TTY:-notty}")"
  source_pid="${PPID:-0}"
  if [[ "$tty" == notty || "$tty" == ssh ]]; then
    fingerprint="$rhost|$tty|$source_pid"
  else
    fingerprint="$rhost|$tty"
  fi
  device="$(make_device ssh "$user" "$fingerprint")"

  case "$pam_type" in
    open_session) acquire_managed ssh "$user" "$device" "$source_pid" "$rhost" "$tty" ;;
    close_session)
      release_device ssh "$device"
      release_matching ssh "$user" "$rhost" "$tty"
      ;;
    *) return 0 ;;
  esac
}

ssh_observed_rows() {
  who 2>/dev/null | awk '
    {
      origin=$NF
      if (origin !~ /^\(/) origin="local"
      gsub(/^\(/,"",origin); gsub(/\)$/,"",origin)
      printf "%s\t%s\t%s\n", $1, $2, origin
    }
  '
}

ssh_observed_present() {
  local resource="$1" wanted_tty="$2" wanted_remote="$3" user tty remote
  while IFS=$'\t' read -r user tty remote; do
    [[ "$user" == "$resource" ]] || continue
    tty="$(normalize_tty "$tty")"
    remote="$(normalize_remote "$remote")"
    [[ "$tty" == "$wanted_tty" && "$remote" == "$wanted_remote" ]] && return 0
  done < <(ssh_observed_rows)
  return 1
}

disconnect_ssh_tty() {
  local user="$1" tty="$2"
  [[ "$user" != root && -n "$tty" ]] || return 0
  pkill -TERM -t "$tty" 2>/dev/null || true
  sleep 0.1
  pkill -KILL -t "$tty" 2>/dev/null || true
}

reconcile_ssh() {
  local file protocol resource pid tty remote user raw_tty raw_remote device
  for file in "$MAP_DIR"/*.map; do
    [[ -f "$file" ]] || continue
    protocol="$(map_read_file "$file" protocol)"
    [[ "$protocol" == ssh ]] || continue
    resource="$(map_read_file "$file" resource)"
    pid="$(map_read_file "$file" source_pid)"
    tty="$(map_read_file "$file" tty)"
    remote="$(map_read_file "$file" remote)"
    if { valid_pid "$pid" && kill -0 "$pid" 2>/dev/null; } || ssh_observed_present "$resource" "$tty" "$remote" || map_in_adoption_grace "$file"; then
      heartbeat_map "$file" || true
    else
      release_map_file "$file"
    fi
  done

  while IFS=$'\t' read -r user raw_tty raw_remote; do
    [[ -n "$user" && -n "$raw_tty" ]] || continue
    tty="$(normalize_tty "$raw_tty")"
    remote="$(normalize_remote "$raw_remote")"
    device="$(make_device ssh "$user" "$remote|$tty")"
    [[ -f "$(map_path ssh "$device")" ]] && continue
    if ! acquire_managed ssh "$user" "$device" 0 "$remote" "$tty"; then
      disconnect_ssh_tty "$user" "$raw_tty"
    fi
  done < <(ssh_observed_rows)
}

openvpn_observed_rows() {
  [[ -f "$OVPN_STATUS" ]] || return 0
  awk -F, '
    $1=="CLIENT_LIST" && $2!="Common Name" {printf "%s\t%s\n", $2, $3; next}
    $0=="ROUTING TABLE" {legacy=0}
    $0=="Common Name,Real Address,Bytes Received,Bytes Sent,Connected Since" {legacy=1; next}
    legacy && NF>=2 {printf "%s\t%s\n", $1, $2}
  ' "$OVPN_STATUS" 2>/dev/null | sort -u
}

openvpn_client_present() {
  local client="$1" name remote
  while IFS=$'\t' read -r name remote; do
    [[ "$name" == "$client" ]] && return 0
  done < <(openvpn_observed_rows)
  return 1
}

openvpn_virtual_ips() {
  local client="$1"
  [[ -f "$OVPN_STATUS" ]] || return 0
  awk -F, -v n="$client" '
    $1=="CLIENT_LIST" && $2==n && $4 ~ /^[0-9]+\./ {print $4}
    $2==n && $1 ~ /^[0-9]+\./ {print $1}
  ' "$OVPN_STATUS" 2>/dev/null | sort -u
}

firewall_state_file() {
  local protocol="$1" identity="$2"
  printf '%s/%s-%s.ips\n' "$FIREWALL_DIR" "$protocol" "$identity"
}

clear_drop_rules() {
  local protocol="$1" identity="$2" iface="$3" file ip comment
  file="$(firewall_state_file "$protocol" "$identity")"
  [[ -f "$file" ]] || return 0
  command_exists iptables || { rm -f "$file"; return 0; }
  comment="MANAGER lease-$protocol:$identity"
  while IFS= read -r ip; do
    [[ "$ip" =~ ^[0-9]+(\.[0-9]+){3}(/32)?$ ]] || continue
    while iptables -C FORWARD -i "$iface" -s "$ip" -m comment --comment "$comment" -j DROP 2>/dev/null; do
      iptables -D FORWARD -i "$iface" -s "$ip" -m comment --comment "$comment" -j DROP 2>/dev/null || break
    done
  done < "$file"
  rm -f "$file"
}

ensure_drop_rule() {
  local protocol="$1" identity="$2" iface="$3" ip="$4" file comment
  command_exists iptables || return 1
  [[ "$ip" =~ ^[0-9]+(\.[0-9]+){3}(/32)?$ ]] || return 1
  file="$(firewall_state_file "$protocol" "$identity")"
  comment="MANAGER lease-$protocol:$identity"
  if ! iptables -C FORWARD -i "$iface" -s "$ip" -m comment --comment "$comment" -j DROP 2>/dev/null; then
    iptables -I FORWARD 1 -i "$iface" -s "$ip" -m comment --comment "$comment" -j DROP 2>/dev/null || return 1
  fi
  printf '%s\n' "$ip" > "$file"
  chmod 0600 "$file"
}

block_openvpn_identity() {
  local identity="$1" client="$2" ip found=0
  clear_drop_rules openvpn "$identity" tun0
  while IFS= read -r ip; do
    [[ -n "$ip" ]] || continue
    if ensure_drop_rule openvpn "$identity" tun0 "$ip"; then
      found=1
    fi
  done < <(openvpn_virtual_ips "$client")
  (( found == 1 )) || return 0
}

reconcile_openvpn() {
  local file protocol client identity name real device remote
  for file in "$MAP_DIR"/*.map; do
    [[ -f "$file" ]] || continue
    protocol="$(map_read_file "$file" protocol)"
    [[ "$protocol" == openvpn ]] || continue
    client="$(map_read_file "$file" resource)"
    identity="$(map_read_file "$file" identity_id)"
    if openvpn_client_present "$client"; then
      if heartbeat_map "$file"; then
        clear_drop_rules openvpn "$identity" tun0
      fi
    elif map_in_adoption_grace "$file"; then
      heartbeat_map "$file" || true
    else
      release_map_file "$file"
    fi
  done

  while IFS=$'\t' read -r name real; do
    [[ -n "$name" ]] || continue
    client="$(safe_fragment "$name")"
    valid_resource "$client" || continue
    has_map_for_resource openvpn "$client" && continue
    remote="$(normalize_remote "$real")"
    device="$(make_device openvpn "$client" "$remote")"
    identity="$(find_identity_by_binding openvpn "$client" 2>/dev/null || true)"
    [[ -n "$identity" ]] || continue
    if acquire_managed openvpn "$client" "$device" 0 "$remote" -; then
      clear_drop_rules openvpn "$identity" tun0
    else
      block_openvpn_identity "$identity" "$client"
    fi
  done < <(openvpn_observed_rows)
}

wg_client_ip() {
  local client="$1" meta ip
  meta="$WG_CLIENT_DIR/$client.meta"
  [[ -f "$meta" ]] || return 1
  ip="$(awk -F= '$1=="ip"{print $2; exit}' "$meta" 2>/dev/null || true)"
  [[ "$ip" =~ ^[0-9]+(\.[0-9]+){3}$ ]] || return 1
  printf '%s/32\n' "$ip"
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

block_wireguard_identity() {
  local identity="$1" client="$2" ip
  ip="$(wg_client_ip "$client" 2>/dev/null || true)"
  if [[ -n "$ip" ]] && ensure_drop_rule wireguard "$identity" wg0 "$ip"; then
    return 0
  fi
  wg_remove_runtime_peer "$client"
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
      if [[ -f "$map" ]] && heartbeat_map "$map"; then
        clear_drop_rules wireguard "$id" wg0
      else
        rm -f "$map"
        if acquire_managed wireguard "$client" "$device" 0 - -; then
          clear_drop_rules wireguard "$id" wg0
        else
          block_wireguard_identity "$id" "$client"
        fi
      fi
    else
      release_map_file "$map"
      block_wireguard_identity "$id" "$client"
    fi
  done
}

request_value() {
  local file="$1" key="$2"
  awk -F= -v k="$key" '$1==k {sub(/^[^=]*=/,""); print; exit}' "$file" 2>/dev/null || true
}

write_openvpn_response() {
  local request="$1" result="$2" base response tmp
  base="${request##*/}"
  base="${base%.req}"
  response="$OVPN_RESP_DIR/$base.resp"
  tmp="$(mktemp)"
  printf '%s\n' "$result" > "$tmp"
  if getent group "$OVPN_GROUP" >/dev/null 2>&1; then
    install -o root -g "$OVPN_GROUP" -m 0640 "$tmp" "$response"
  else
    install -m 0644 "$tmp" "$response"
  fi
  rm -f "$tmp"
}

process_openvpn_requests() {
  local request base event client remote port device result processed=0 size
  bridge_init
  for request in "$OVPN_REQ_DIR"/request.*.req; do
    [[ -e "$request" || -L "$request" ]] || continue
    processed=$((processed + 1))
    (( processed <= 200 )) || break
    base="${request##*/}"
    if [[ ! "$base" =~ ^request\.[A-Za-z0-9]+\.req$ ]] || [[ -L "$request" ]] || [[ ! -f "$request" ]]; then
      rm -f -- "$request"
      continue
    fi
    size="$(stat -c '%s' "$request" 2>/dev/null || echo 999999)"
    if [[ ! "$size" =~ ^[0-9]+$ ]] || (( size > 4096 )); then
      rm -f -- "$request"
      continue
    fi
    event="$(request_value "$request" event)"
    client="$(request_value "$request" client)"
    remote="$(request_value "$request" remote)"
    port="$(request_value "$request" port)"
    result=DENY
    if valid_resource "$client" && valid_remote "$remote" && [[ "$port" =~ ^[0-9]{1,5}$ ]] && (( port <= 65535 )); then
      device="$(make_device openvpn "$client" "$remote|$port")"
      case "$event" in
        client-connect)
          if acquire_managed openvpn "$client" "$device" 0 "$remote:$port" -; then
            result=ALLOW
          fi
          write_openvpn_response "$request" "$result"
          ;;
        client-disconnect)
          release_device openvpn "$device"
          release_matching openvpn "$client"
          ;;
        *) write_openvpn_response "$request" DENY ;;
      esac
    elif [[ "$event" == client-connect ]]; then
      write_openvpn_response "$request" DENY
    fi
    rm -f -- "$request"
  done
}

install_client_hooks() {
  install -d -m 0755 /usr/local/libexec
  cat > "$SSH_PAM_HOOK" <<EOF
#!/bin/sh
ENGINE="$MANAGER_HOME/modules/protocol_leases.sh"
[ -x "\$ENGINE" ] || exit 0
[ "\$(id -u)" -eq 0 ] || exit 0
exec "\$ENGINE" --pam-ssh
EOF
  chmod 0755 "$SSH_PAM_HOOK"

  cat > "$OVPN_CLIENT_HOOK" <<EOF
#!/bin/sh
set -u
REQ_DIR="$OVPN_REQ_DIR"
RESP_DIR="$OVPN_RESP_DIR"
event="\${script_type:-}"
client="\${common_name:-}"
remote="\${trusted_ip:-\${trusted_ip6:-unknown}}"
port="\${trusted_port:-0}"

case "\$event" in client-connect|client-disconnect) ;; *) exit 0 ;; esac
printf '%s' "\$client" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9_.:@-]{0,63}$' || exit 1
printf '%s' "\$remote" | grep -Eq '^[A-Fa-f0-9:.]+$' || remote=unknown
printf '%s' "\$port" | grep -Eq '^[0-9]{1,5}$' || port=0
[ -d "\$REQ_DIR" ] && [ -d "\$RESP_DIR" ] || exit 1
umask 077
tmp="\$(mktemp "\$REQ_DIR/.request.XXXXXX")" || exit 1
id="\${tmp##*/.request.}"
request="\$REQ_DIR/request.\$id.req"
response="\$RESP_DIR/request.\$id.resp"
{
  printf 'event=%s\n' "\$event"
  printf 'client=%s\n' "\$client"
  printf 'remote=%s\n' "\$remote"
  printf 'port=%s\n' "\$port"
} > "\$tmp"
mv "\$tmp" "\$request" || exit 1

if [ "\$event" = client-disconnect ]; then exit 0; fi

i=0
while [ "\$i" -lt 60 ]; do
  if [ -r "\$response" ]; then
    result="\$(cat "\$response" 2>/dev/null || true)"
    rm -f "\$response" 2>/dev/null || true
    [ "\$result" = ALLOW ] && exit 0
    exit 1
  fi
  i=\$((i + 1))
  sleep 0.05
done
exit 1
EOF
  chmod 0755 "$OVPN_CLIENT_HOOK"
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
session required pam_exec.so quiet $SSH_PAM_HOOK
$PAM_END
EOF
}

active_openvpn_clients() {
  local count
  count="$(openvpn_observed_rows | awk 'NF{c++} END{print c+0}')"
  printf '%s\n' "$count"
}

refresh_openvpn_hook() {
  local tmp changed=0 active
  [[ -f "$OVPN_CONF" ]] || return 0
  grep -Fqx "$OVPN_POLICY_BEGIN" "$OVPN_CONF" 2>/dev/null || return 0
  tmp="$(mktemp)"
  awk -v begin="$OVPN_POLICY_BEGIN" -v end="$OVPN_POLICY_END" -v hook="$OVPN_CLIENT_HOOK" '
    $0==begin {inside=1; cc=0; cd=0; print; next}
    $0==end {
      if (!cc) print "client-connect " hook
      if (!cd) print "client-disconnect " hook
      inside=0; print; next
    }
    inside && $1=="client-connect" {print "client-connect " hook; cc=1; next}
    inside && $1=="client-disconnect" {print "client-disconnect " hook; cd=1; next}
    {print}
  ' "$OVPN_CONF" > "$tmp"
  if ! cmp -s "$tmp" "$OVPN_CONF"; then
    install -m 0644 "$tmp" "$OVPN_CONF"
    changed=1
  fi
  rm -f "$tmp"

  if grep -q '^group nogroup$' "$OVPN_CONF" 2>/dev/null && getent group "$OVPN_GROUP" >/dev/null 2>&1; then
    sed -i "s/^group nogroup$/group $OVPN_GROUP/" "$OVPN_CONF"
    changed=1
  fi

  if (( changed == 1 )) && systemctl is-active --quiet openvpn-server@manager 2>/dev/null; then
    active="$(active_openvpn_clients)"
    if [[ "$active" =~ ^[0-9]+$ ]] && (( active == 0 )); then
      systemctl restart openvpn-server@manager >/dev/null 2>&1 || true
      rm -f "$OVPN_RESTART_PENDING"
    else
      touch "$OVPN_RESTART_PENDING"
      chmod 0600 "$OVPN_RESTART_PENDING"
    fi
  fi
}

activate_pending_openvpn_hook() {
  local active
  [[ -f "$OVPN_RESTART_PENDING" ]] || return 0
  systemctl is-active --quiet openvpn-server@manager 2>/dev/null || { rm -f "$OVPN_RESTART_PENDING"; return 0; }
  active="$(active_openvpn_clients)"
  if [[ "$active" =~ ^[0-9]+$ ]] && (( active == 0 )); then
    systemctl restart openvpn-server@manager >/dev/null 2>&1 || true
    rm -f "$OVPN_RESTART_PENDING"
  fi
}

restore_openvpn_group() {
  [[ -f "$OVPN_CONF" ]] || return 0
  if grep -q "^group $OVPN_GROUP$" "$OVPN_CONF" 2>/dev/null; then
    sed -i "s/^group $OVPN_GROUP$/group nogroup/" "$OVPN_CONF"
  fi
}

cleanup_stale_queue_files() {
  find "$OVPN_REQ_DIR" -maxdepth 1 -type f -mmin +2 -delete 2>/dev/null || true
  find "$OVPN_RESP_DIR" -maxdepth 1 -type f -mmin +2 -delete 2>/dev/null || true
}

reconcile_all() {
  bridge_init
  refresh_openvpn_hook
  activate_pending_openvpn_hook
  "$SESSION_ENGINE" --reconcile >/dev/null 2>&1 || true
  reconcile_ssh
  reconcile_openvpn
  reconcile_wireguard
  cleanup_stale_queue_files
}

install_units() {
  bridge_init
  install_client_hooks
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
OnBootSec=2s
OnUnitActiveSec=5s
AccuracySec=1s
Unit=manager-protocol-leases.service

[Install]
WantedBy=timers.target
EOF

  cat > "$OVPN_QUEUE_SERVICE" <<EOF
[Unit]
Description=MANAGER OpenVPN lease admission queue
After=local-fs.target

[Service]
Type=oneshot
ExecStart=$MANAGER_HOME/modules/protocol_leases.sh --process-openvpn-requests
EOF

  cat > "$OVPN_QUEUE_PATH" <<EOF
[Unit]
Description=MANAGER OpenVPN lease request watcher

[Path]
PathChanged=$OVPN_REQ_DIR
DirectoryNotEmpty=$OVPN_REQ_DIR
Unit=manager-openvpn-lease-queue.service

[Install]
WantedBy=multi-user.target
EOF

  chmod 0644 "$BRIDGE_SERVICE" "$BRIDGE_TIMER" "$OVPN_QUEUE_SERVICE" "$OVPN_QUEUE_PATH"
  systemctl daemon-reload
  systemctl enable --now manager-protocol-leases.timer manager-openvpn-lease-queue.path >/dev/null 2>&1 || true
  reconcile_all
}

clear_all_bridge_firewall() {
  local file id
  for file in "$IDENTITY_DIR"/*.conf; do
    [[ -f "$file" ]] || continue
    id="${file##*/}"
    id="${id%.conf}"
    clear_drop_rules wireguard "$id" wg0
    clear_drop_rules openvpn "$id" tun0
  done
}

detach_bridge() {
  local file
  bridge_init
  systemctl disable --now manager-protocol-leases.timer manager-openvpn-lease-queue.path >/dev/null 2>&1 || true
  # Um timer/path já disparado pode ter deixado um oneshot ativo. Espere esses
  # workers terminarem antes de remover o runtime, senão eles podem recriá-lo
  # depois do rm -rf durante uninstall/rollback.
  systemctl stop manager-protocol-leases.service manager-openvpn-lease-queue.service >/dev/null 2>&1 || true
  rm -f "$BRIDGE_SERVICE" "$BRIDGE_TIMER" "$OVPN_QUEUE_SERVICE" "$OVPN_QUEUE_PATH"
  remove_pam_block
  clear_all_bridge_firewall
  for file in "$MAP_DIR"/*.map; do
    [[ -f "$file" ]] || continue
    release_map_file "$file"
  done
  restore_openvpn_group
  rm -f "$SSH_PAM_HOOK" "$OVPN_CLIENT_HOOK"
  systemctl daemon-reload || true
  rm -rf "$BRIDGE_RUNTIME"
}

bridge_init
case "${1:-}" in
  --install) ( flock -x 9; install_units ) 9>"$BRIDGE_LOCK" ;;
  --detach) ( flock -x 9; detach_bridge ) 9>"$BRIDGE_LOCK" ;;
  --reconcile) ( flock -x 9; reconcile_all ) 9>"$BRIDGE_LOCK" ;;
  --process-openvpn-requests) ( flock -x 9; process_openvpn_requests ) 9>"$BRIDGE_LOCK" ;;
  --refresh-openvpn-hook) ( flock -x 9; refresh_openvpn_hook; activate_pending_openvpn_hook ) 9>"$BRIDGE_LOCK" ;;
  --pam-ssh) ( flock -x 9; pam_ssh ) 9>"$BRIDGE_LOCK" ;;
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
    err "Uso: protocol_leases.sh --install|--detach|--reconcile|--process-openvpn-requests|--pam-ssh|--refresh-openvpn-hook"
    exit 64
    ;;
esac
