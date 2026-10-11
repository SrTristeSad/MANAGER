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
RUNTIME="${MANAGER_IPV6_GUARD_RUNTIME:-/run/manager-ipv6-guard}"
STATE_DIR="$RUNTIME/rules"
LOCK_FILE="$RUNTIME/.lock"
SERVICE_FILE="/etc/systemd/system/manager-ipv6-guard.service"
TIMER_FILE="/etc/systemd/system/manager-ipv6-guard.timer"
WG_CLIENT_DIR="$MANAGER_ETC/wireguard/clients"
OVPN_STATUS="/run/openvpn/manager-status.log"

init_guard() {
  identity_init
  install -d -m 0700 "$RUNTIME" "$STATE_DIR"
  touch "$LOCK_FILE"
  chmod 0600 "$LOCK_FILE"
}

rule_file() {
  local protocol="$1" identity="$2"
  printf '%s/%s-%s.rules\n' "$STATE_DIR" "$protocol" "$identity"
}

valid_ipv6_host() {
  local value="${1:-}"
  [[ "$value" == *:* && "$value" =~ ^[0-9A-Fa-f:]+$ ]]
}

lease_exists() {
  local identity="$1" protocol="$2" resource="$3"
  [[ -x "$SESSION_ENGINE" ]] || return 1
  "$SESSION_ENGINE" --list "$identity" 2>/dev/null | awk -F'\t' -v p="$protocol" -v r="$resource" '
    {
      found_p=0; found_r=0
      for (i=3; i<=NF; i++) {
        if ($i == "protocol=" p) found_p=1
        if ($i == "resource=" r) found_r=1
      }
      if (found_p && found_r) found=1
    }
    END {exit(found ? 0 : 1)}
  '
}

clear_rules() {
  local protocol="$1" identity="$2" file iface ip comment
  file="$(rule_file "$protocol" "$identity")"
  [[ -f "$file" ]] || return 0
  if ! command_exists ip6tables; then rm -f "$file"; return 0; fi
  comment="MANAGER ipv6-$protocol:$identity"
  while IFS=$'\t' read -r iface ip; do
    [[ -n "$iface" ]] || continue
    valid_ipv6_host "$ip" || continue
    while ip6tables -C FORWARD -i "$iface" -s "$ip/128" -m comment --comment "$comment" -j DROP 2>/dev/null; do
      ip6tables -D FORWARD -i "$iface" -s "$ip/128" -m comment --comment "$comment" -j DROP 2>/dev/null || break
    done
  done < "$file"
  rm -f "$file"
}

apply_rule() {
  local protocol="$1" identity="$2" iface="$3" ip="$4" file comment
  command_exists ip6tables || return 1
  valid_ipv6_host "$ip" || return 1
  file="$(rule_file "$protocol" "$identity")"
  comment="MANAGER ipv6-$protocol:$identity"
  if ! ip6tables -C FORWARD -i "$iface" -s "$ip/128" -m comment --comment "$comment" -j DROP 2>/dev/null; then
    ip6tables -I FORWARD 1 -i "$iface" -s "$ip/128" -m comment --comment "$comment" -j DROP 2>/dev/null || return 1
  fi
  touch "$file"
  chmod 0600 "$file"
  grep -Fqx "$iface"$'\t'"$ip" "$file" 2>/dev/null || printf '%s\t%s\n' "$iface" "$ip" >> "$file"
}

wg_ipv6() {
  local client="$1" meta ip6
  meta="$WG_CLIENT_DIR/$client.meta"
  [[ -f "$meta" ]] || return 1
  ip6="$(awk -F= '$1=="ip6" {print $2; exit}' "$meta" 2>/dev/null || true)"
  valid_ipv6_host "$ip6" || return 1
  printf '%s\n' "$ip6"
}

openvpn_ipv6s() {
  local client="$1"
  [[ -f "$OVPN_STATUS" ]] || return 0
  awk -F, -v n="$client" '
    $1=="CLIENT_LIST" && $2==n && $5 ~ /:/ {print $5}
    $2==n && $1 ~ /:/ {print $1}
  ' "$OVPN_STATUS" 2>/dev/null | awk '!seen[$0]++'
}

reconcile_wireguard() {
  local file identity client ip6 state
  for file in "$IDENTITY_DIR"/*.conf; do
    [[ -f "$file" ]] || continue
    identity="${file##*/}"; identity="${identity%.conf}"
    client="$(identity_read "$identity" wireguard_client)"
    [[ -n "$client" ]] || { clear_rules wireguard "$identity"; continue; }
    ip6="$(wg_ipv6 "$client" 2>/dev/null || true)"
    [[ -n "$ip6" ]] || { clear_rules wireguard "$identity"; continue; }
    state="$(identity_effective_state "$identity")"
    if [[ "$state" == active ]] && identity_has_protocol "$identity" wireguard && lease_exists "$identity" wireguard "$client"; then
      clear_rules wireguard "$identity"
    else
      clear_rules wireguard "$identity"
      apply_rule wireguard "$identity" wg0 "$ip6" || true
    fi
  done
}

reconcile_openvpn() {
  local file identity client state ip6 found
  for file in "$IDENTITY_DIR"/*.conf; do
    [[ -f "$file" ]] || continue
    identity="${file##*/}"; identity="${identity%.conf}"
    client="$(identity_read "$identity" openvpn_client)"
    [[ -n "$client" ]] || { clear_rules openvpn "$identity"; continue; }
    state="$(identity_effective_state "$identity")"
    if [[ "$state" == active ]] && identity_has_protocol "$identity" openvpn && lease_exists "$identity" openvpn "$client"; then
      clear_rules openvpn "$identity"
      continue
    fi
    clear_rules openvpn "$identity"
    found=0
    while IFS= read -r ip6; do
      [[ -n "$ip6" ]] || continue
      found=1
      apply_rule openvpn "$identity" tun0 "$ip6" || true
    done < <(openvpn_ipv6s "$client")
    (( found == 1 )) || clear_rules openvpn "$identity"
  done
}

cleanup_orphans() {
  local file base protocol identity
  for file in "$STATE_DIR"/*.rules; do
    [[ -f "$file" ]] || continue
    base="${file##*/}"; base="${base%.rules}"
    protocol="${base%%-*}"
    identity="${base#*-}"
    if ! identity_exists "$identity"; then clear_rules "$protocol" "$identity"; fi
  done
}

reconcile_locked() {
  init_guard
  reconcile_wireguard
  reconcile_openvpn
  cleanup_orphans
}

clear_all() {
  local file base protocol identity
  init_guard
  for file in "$STATE_DIR"/*.rules; do
    [[ -f "$file" ]] || continue
    base="${file##*/}"; base="${base%.rules}"
    protocol="${base%%-*}"
    identity="${base#*-}"
    clear_rules "$protocol" "$identity"
  done
}

install_units() {
  init_guard
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=MANAGER IPv6 policy and lease guard
After=network-online.target

[Service]
Type=oneshot
ExecStart=$MANAGER_HOME/modules/ipv6_guard.sh --reconcile
EOF
  cat > "$TIMER_FILE" <<'EOF'
[Unit]
Description=Reconcile MANAGER IPv6 policy and leases

[Timer]
OnBootSec=15s
OnUnitActiveSec=5s
AccuracySec=1s
Unit=manager-ipv6-guard.service

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now manager-ipv6-guard.timer >/dev/null 2>&1 || true
  reconcile_locked
}

detach_units() {
  systemctl disable --now manager-ipv6-guard.timer >/dev/null 2>&1 || true
  clear_all || true
  rm -f "$SERVICE_FILE" "$TIMER_FILE"
  rm -rf "$RUNTIME"
  systemctl daemon-reload || true
}

status_machine() {
  init_guard
  printf 'ip6tables=%s\n' "$(command_exists ip6tables && echo 1 || echo 0)"
  printf 'host_ipv6_egress=%s\n' "$(ipv6_egress_available && echo 1 || echo 0)"
  printf 'wireguard_ipv6=%s\n' "$([[ -f "$MANAGER_ETC/wireguard/ipv6-enabled" ]] && cat "$MANAGER_ETC/wireguard/ipv6-enabled" || echo 0)"
  printf 'openvpn_ipv6=%s\n' "$([[ -f "$MANAGER_ETC/openvpn/ipv6-enabled" ]] && cat "$MANAGER_ETC/openvpn/ipv6-enabled" || echo 0)"
  printf 'active_rule_files=%s\n' "$(find "$STATE_DIR" -maxdepth 1 -type f -name '*.rules' 2>/dev/null | wc -l)"
}

case "${1:-}" in
  --install) flock -x "$LOCK_FILE" -c "$0 --install-unlocked"; exit $? ;;
  --install-unlocked) install_units; exit $? ;;
  --reconcile) init_guard; flock -x "$LOCK_FILE" -c "$0 --reconcile-unlocked"; exit $? ;;
  --reconcile-unlocked) reconcile_locked; exit $? ;;
  --clear) init_guard; flock -x "$LOCK_FILE" -c "$0 --clear-unlocked"; exit $? ;;
  --clear-unlocked) clear_all; exit $? ;;
  --detach) detach_units; exit 0 ;;
  --status) status_machine; exit 0 ;;
  *) err "Ação inválida: ${1:-}"; exit 64 ;;
esac
