#!/usr/bin/env bash
set -Eeuo pipefail

MANAGER_HOME="${MANAGER_HOME:-/opt/manager}"
MANAGER_ETC="${MANAGER_ETC:-/etc/manager}"
# shellcheck source=/dev/null
source "$MANAGER_HOME/lib/common.sh"
# shellcheck source=/dev/null
source "$MANAGER_HOME/lib/identity.sh"
require_root

RUNTIME_DIR="$IDENTITY_ROOT/runtime"
POLICY_LOCK="$IDENTITY_ROOT/.policy-lock"
SSH_POLICY_FILE="/etc/ssh/sshd_config.d/65-manager-identity-policy.conf"
SSH_LIMITS_FILE="/etc/security/limits.d/98-manager-identity.conf"
POLICY_SERVICE="/etc/systemd/system/manager-policy-reconcile.service"
POLICY_TIMER="/etc/systemd/system/manager-policy-reconcile.timer"
POLICY_PATH="/etc/systemd/system/manager-policy-reconcile.path"
WG_CLIENT_DIR="$MANAGER_ETC/wireguard/clients"
OVPN_CONF="/etc/openvpn/server/manager.conf"
OVPN_STATUS="/run/openvpn/manager-status.log"
OVPN_HOOK="$IDENTITY_ROOT/openvpn-policy-hook.sh"
OVPN_PENDING="$RUNTIME_DIR/openvpn-hook-pending-restart"

init_policy_state() {
  identity_init
  install -d -m 0700 "$RUNTIME_DIR"
  touch "$POLICY_LOCK"
  chmod 0600 "$POLICY_LOCK"
}

binding_for() {
  case "$1" in
    ssh) identity_read "$2" ssh_user ;;
    wireguard) identity_read "$2" wireguard_client ;;
    openvpn) identity_read "$2" openvpn_client ;;
    *) return 1 ;;
  esac
}

find_identity_by_binding() {
  local protocol="$1" resource="$2" file id value
  identity_init
  for file in "$IDENTITY_DIR"/*.conf; do
    [[ -f "$file" ]] || continue
    id="${file##*/}"; id="${id%.conf}"
    value="$(binding_for "$protocol" "$id")"
    if [[ -n "$value" && "$value" == "$resource" ]]; then
      printf '%s\n' "$id"
      return 0
    fi
  done
  return 1
}

ssh_session_count() {
  local user="$1"
  [[ -n "$user" ]] || { printf '0\n'; return; }
  who 2>/dev/null | awk -v u="$user" '$1==u {c++} END {print c+0}'
}

wg_session_count() {
  local client="$1" meta pub last now
  [[ -n "$client" ]] || { printf '0\n'; return; }
  meta="$WG_CLIENT_DIR/$client.meta"
  [[ -f "$meta" ]] || { printf '0\n'; return; }
  command_exists wg || { printf '0\n'; return; }
  wg show wg0 >/dev/null 2>&1 || { printf '0\n'; return; }
  pub="$(awk -F= '$1=="public_key"{print $2; exit}' "$meta" 2>/dev/null || true)"
  [[ -n "$pub" ]] || { printf '0\n'; return; }
  last="$(wg show wg0 latest-handshakes 2>/dev/null | awk -v p="$pub" '$1==p {print $2; exit}')"
  [[ "$last" =~ ^[0-9]+$ ]] || { printf '0\n'; return; }
  (( last > 0 )) || { printf '0\n'; return; }
  now="$(date +%s)"
  if (( now - last <= 180 )); then printf '1\n'; else printf '0\n'; fi
}

ovpn_session_count() {
  local client="$1"
  [[ -n "$client" && -f "$OVPN_STATUS" ]] || { printf '0\n'; return; }
  awk -F, -v n="$client" '
    $1=="CLIENT_LIST" && $2==n {c++}
    $0=="ROUTING TABLE" {legacy=0}
    $0=="Common Name,Real Address,Bytes Received,Bytes Sent,Connected Since" {legacy=1; next}
    legacy && $1==n {c++}
    END {print c+0}
  ' "$OVPN_STATUS" 2>/dev/null
}

identity_session_counts() {
  local id="$1" ssh_user wg_client ovpn_client ssh_n wg_n ovpn_n total
  ssh_user="$(identity_read "$id" ssh_user)"
  wg_client="$(identity_read "$id" wireguard_client)"
  ovpn_client="$(identity_read "$id" openvpn_client)"
  ssh_n="$(ssh_session_count "$ssh_user")"
  wg_n="$(wg_session_count "$wg_client")"
  ovpn_n="$(ovpn_session_count "$ovpn_client")"
  total=$((ssh_n + wg_n + ovpn_n))
  printf '%s %s %s %s\n' "$ssh_n" "$wg_n" "$ovpn_n" "$total"
}

show_sessions_machine() {
  local wanted="${1:-}" file id counts ssh_n wg_n ovpn_n total max state
  identity_init
  for file in "$IDENTITY_DIR"/*.conf; do
    [[ -f "$file" ]] || continue
    id="${file##*/}"; id="${id%.conf}"
    [[ -z "$wanted" || "$id" == "$wanted" ]] || continue
    counts="$(identity_session_counts "$id")"
    read -r ssh_n wg_n ovpn_n total <<< "$counts"
    max="$(identity_read "$id" max_sessions)"
    state="$(identity_effective_state "$id")"
    printf '%s\t%s\tssh=%s\twg=%s\tovpn=%s\ttotal=%s\tmax=%s\n' \
      "$id" "$state" "$ssh_n" "$wg_n" "$ovpn_n" "$total" "$max"
  done
}

resource_authorized() {
  local protocol="$1" resource="$2" id state counts ssh_n wg_n ovpn_n total max current=0
  id="$(find_identity_by_binding "$protocol" "$resource" 2>/dev/null || true)"
  [[ -n "$id" ]] || return 0
  state="$(identity_effective_state "$id")"
  [[ "$state" == active ]] || return 68
  identity_has_protocol "$id" "$protocol" || return 67
  counts="$(identity_session_counts "$id")"
  read -r ssh_n wg_n ovpn_n total <<< "$counts"
  max="$(identity_read "$id" max_sessions)"
  [[ "$max" =~ ^[1-9][0-9]*$ ]] || return 64
  case "$protocol" in
    ssh) current="$ssh_n" ;;
    wireguard) current="$wg_n" ;;
    openvpn) current="$ovpn_n" ;;
  esac
  if (( current == 0 && total >= max )); then return 69; fi
  if [[ "$protocol" == openvpn ]] && (( total >= max )); then return 69; fi
  return 0
}

disconnect_ssh_user() {
  local user="$1" tty
  [[ -n "$user" && "$user" != root ]] || return 0
  while IFS= read -r tty; do
    [[ -n "$tty" ]] || continue
    pkill -TERM -t "$tty" 2>/dev/null || true
    sleep 0.1
    pkill -KILL -t "$tty" 2>/dev/null || true
  done < <(who 2>/dev/null | awk -v u="$user" '$1==u {print $2}')
}

write_ssh_policy() {
  local tmp backup had_old=0 file id state user counts ssh_n wg_n ovpn_n total max other available
  local deny=() limits=()
  tmp="$(mktemp)"
  backup="$(mktemp)"
  trap 'rm -f "$tmp" "$backup"' RETURN

  for file in "$IDENTITY_DIR"/*.conf; do
    [[ -f "$file" ]] || continue
    id="${file##*/}"; id="${id%.conf}"
    user="$(identity_read "$id" ssh_user)"
    [[ -n "$user" ]] || continue
    is_valid_username "$user" || continue
    [[ "$user" != root ]] || continue
    state="$(identity_effective_state "$id")"
    counts="$(identity_session_counts "$id")"
    read -r ssh_n wg_n ovpn_n total <<< "$counts"
    max="$(identity_read "$id" max_sessions)"
    [[ "$max" =~ ^[1-9][0-9]*$ ]] || max=1

    if [[ "$state" != active ]] || ! identity_has_protocol "$id" ssh; then
      deny+=("$user")
      disconnect_ssh_user "$user"
      continue
    fi

    other=$((wg_n + ovpn_n))
    available=$((max - other))
    if (( available <= 0 )); then
      deny+=("$user")
    else
      (( available > 50 )) && available=50
      limits+=("$user hard maxlogins $available")
    fi
  done

  {
    printf '# Managed by MANAGER Connection Engine. Do not edit manually.\n'
    if (( ${#deny[@]} > 0 )); then
      printf 'DenyUsers'
      printf ' %s' "${deny[@]}"
      printf '\n'
    fi
  } > "$tmp"

  mkdir -p "$(dirname "$SSH_POLICY_FILE")"
  if [[ -f "$SSH_POLICY_FILE" ]]; then
    cp -a "$SSH_POLICY_FILE" "$backup"
    had_old=1
  fi
  if [[ -f "$SSH_POLICY_FILE" ]] && cmp -s "$tmp" "$SSH_POLICY_FILE"; then
    :
  else
    install -m 0644 "$tmp" "$SSH_POLICY_FILE"
    if command_exists sshd && ! sshd -t; then
      if (( had_old == 1 )); then install -m 0644 "$backup" "$SSH_POLICY_FILE"; else rm -f "$SSH_POLICY_FILE"; fi
      err "Política SSH recusada por sshd -t; alteração revertida"
      return 1
    fi
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
  fi

  mkdir -p "$(dirname "$SSH_LIMITS_FILE")"
  if (( ${#limits[@]} == 0 )); then
    rm -f "$SSH_LIMITS_FILE"
  else
    {
      printf '# Managed by MANAGER Connection Engine.\n'
      printf '%s\n' "${limits[@]}"
    } > "$tmp"
    install -m 0644 "$tmp" "$SSH_LIMITS_FILE"
  fi
}

wg_peer_present() {
  local pub="$1"
  wg show wg0 peers 2>/dev/null | grep -Fxq "$pub"
}

wg_remove_client() {
  local client="$1" meta pub
  meta="$WG_CLIENT_DIR/$client.meta"
  [[ -f "$meta" ]] || return 0
  command_exists wg || return 0
  wg show wg0 >/dev/null 2>&1 || return 0
  pub="$(awk -F= '$1=="public_key"{print $2; exit}' "$meta" 2>/dev/null || true)"
  [[ -n "$pub" ]] || return 0
  wg set wg0 peer "$pub" remove 2>/dev/null || true
}

wg_restore_client() {
  local client="$1" meta conf pub ip psk psk_file
  meta="$WG_CLIENT_DIR/$client.meta"
  conf="$WG_CLIENT_DIR/$client.conf"
  [[ -f "$meta" && -f "$conf" ]] || return 0
  command_exists wg || return 0
  wg show wg0 >/dev/null 2>&1 || return 0
  pub="$(awk -F= '$1=="public_key"{print $2; exit}' "$meta" 2>/dev/null || true)"
  ip="$(awk -F= '$1=="ip"{print $2; exit}' "$meta" 2>/dev/null || true)"
  psk="$(awk -F' = ' '$1=="PresharedKey"{print $2; exit}' "$conf" 2>/dev/null || true)"
  [[ -n "$pub" && -n "$ip" && -n "$psk" ]] || return 0
  wg_peer_present "$pub" && return 0
  psk_file="$(mktemp)"
  chmod 0600 "$psk_file"
  printf '%s\n' "$psk" > "$psk_file"
  wg set wg0 peer "$pub" preshared-key "$psk_file" allowed-ips "$ip/32" 2>/dev/null || true
  rm -f "$psk_file"
}

reconcile_wireguard() {
  local file id client state counts ssh_n wg_n ovpn_n total max other
  command_exists wg || return 0
  wg show wg0 >/dev/null 2>&1 || return 0
  for file in "$IDENTITY_DIR"/*.conf; do
    [[ -f "$file" ]] || continue
    id="${file##*/}"; id="${id%.conf}"
    client="$(identity_read "$id" wireguard_client)"
    [[ -n "$client" ]] || continue
    state="$(identity_effective_state "$id")"
    counts="$(identity_session_counts "$id")"
    read -r ssh_n wg_n ovpn_n total <<< "$counts"
    max="$(identity_read "$id" max_sessions)"
    [[ "$max" =~ ^[1-9][0-9]*$ ]] || max=1
    other=$((ssh_n + ovpn_n))
    if [[ "$state" != active ]] || ! identity_has_protocol "$id" wireguard; then
      wg_remove_client "$client"
    elif (( wg_n == 0 && other >= max )); then
      wg_remove_client "$client"
    else
      wg_restore_client "$client"
    fi
  done
}

openvpn_virtual_ips() {
  local client="$1"
  [[ -f "$OVPN_STATUS" ]] || return 0
  awk -F, -v n="$client" '
    $1=="CLIENT_LIST" && $2==n && $4 ~ /^[0-9]+\./ {print $4}
    $2==n && $1 ~ /^[0-9]+\./ {print $1}
  ' "$OVPN_STATUS" 2>/dev/null | sort -u
}

clear_ovpn_drop_rules() {
  local id="$1" file ip comment
  file="$RUNTIME_DIR/openvpn-$id.ips"
  [[ -f "$file" ]] || return 0
  command_exists iptables || { rm -f "$file"; return 0; }
  comment="MANAGER identity:$id"
  while IFS= read -r ip; do
    [[ "$ip" =~ ^[0-9]+(\.[0-9]+){3}$ ]] || continue
    while iptables -C FORWARD -i tun0 -s "$ip" -m comment --comment "$comment" -j DROP 2>/dev/null; do
      iptables -D FORWARD -i tun0 -s "$ip" -m comment --comment "$comment" -j DROP 2>/dev/null || break
    done
  done < "$file"
  rm -f "$file"
}

apply_ovpn_drop_rules() {
  local id="$1" client="$2" file ip comment found=0
  command_exists iptables || return 0
  file="$RUNTIME_DIR/openvpn-$id.ips"
  comment="MANAGER identity:$id"
  : > "$file"
  chmod 0600 "$file"
  while IFS= read -r ip; do
    [[ "$ip" =~ ^[0-9]+(\.[0-9]+){3}$ ]] || continue
    found=1
    if ! iptables -C FORWARD -i tun0 -s "$ip" -m comment --comment "$comment" -j DROP 2>/dev/null; then
      iptables -I FORWARD 1 -i tun0 -s "$ip" -m comment --comment "$comment" -j DROP
    fi
    printf '%s\n' "$ip" >> "$file"
  done < <(openvpn_virtual_ips "$client")
  (( found == 1 )) || rm -f "$file"
}

write_openvpn_hook() {
  cat > "$OVPN_HOOK" <<EOF
#!/usr/bin/env bash
set -u
POLICY_ENGINE="$MANAGER_HOME/modules/policy_engine.sh"
[[ -x "\$POLICY_ENGINE" ]] || exit 1
exec "\$POLICY_ENGINE" --authorize openvpn "\${common_name:-}"
EOF
  chmod 0700 "$OVPN_HOOK"
}

ensure_openvpn_config_hook() {
  local tmp active_clients
  [[ -f "$OVPN_CONF" ]] || return 0
  write_openvpn_hook
  if grep -q '^# MANAGER-IDENTITY-POLICY-BEGIN$' "$OVPN_CONF" 2>/dev/null; then
    return 0
  fi
  tmp="$(mktemp)"
  cat "$OVPN_CONF" > "$tmp"
  cat >> "$tmp" <<EOF

# MANAGER-IDENTITY-POLICY-BEGIN
script-security 2
client-connect $OVPN_HOOK
# MANAGER-IDENTITY-POLICY-END
EOF
  install -m 0644 "$tmp" "$OVPN_CONF"
  rm -f "$tmp"
  active_clients="$(awk -F, '$1=="CLIENT_LIST"{c++} $0=="Common Name,Real Address,Bytes Received,Bytes Sent,Connected Since"{legacy=1;next} $0=="ROUTING TABLE"{legacy=0} legacy{c++} END{print c+0}' "$OVPN_STATUS" 2>/dev/null || echo 0)"
  if systemctl is-active --quiet openvpn-server@manager 2>/dev/null; then
    if [[ "$active_clients" =~ ^[0-9]+$ ]] && (( active_clients == 0 )); then
      systemctl restart openvpn-server@manager 2>/dev/null || true
      rm -f "$OVPN_PENDING"
    else
      touch "$OVPN_PENDING"
      chmod 0600 "$OVPN_PENDING"
    fi
  fi
}

activate_pending_openvpn_hook() {
  local active_clients
  [[ -f "$OVPN_PENDING" ]] || return 0
  systemctl is-active --quiet openvpn-server@manager 2>/dev/null || { rm -f "$OVPN_PENDING"; return 0; }
  active_clients="$(awk -F, '$1=="CLIENT_LIST"{c++} $0=="Common Name,Real Address,Bytes Received,Bytes Sent,Connected Since"{legacy=1;next} $0=="ROUTING TABLE"{legacy=0} legacy{c++} END{print c+0}' "$OVPN_STATUS" 2>/dev/null || echo 0)"
  if [[ "$active_clients" =~ ^[0-9]+$ ]] && (( active_clients == 0 )); then
    systemctl restart openvpn-server@manager 2>/dev/null || true
    rm -f "$OVPN_PENDING"
  fi
}

reconcile_openvpn() {
  local file id client state
  ensure_openvpn_config_hook
  for file in "$IDENTITY_DIR"/*.conf; do
    [[ -f "$file" ]] || continue
    id="${file##*/}"; id="${id%.conf}"
    client="$(identity_read "$id" openvpn_client)"
    [[ -n "$client" ]] || continue
    state="$(identity_effective_state "$id")"
    if [[ "$state" != active ]] || ! identity_has_protocol "$id" openvpn; then
      clear_ovpn_drop_rules "$id"
      apply_ovpn_drop_rules "$id" "$client"
    else
      clear_ovpn_drop_rules "$id"
    fi
  done
  activate_pending_openvpn_hook
}

reconcile_all() {
  init_policy_state
  write_ssh_policy
  reconcile_wireguard
  reconcile_openvpn
}

install_units() {
  init_policy_state
  cat > "$POLICY_SERVICE" <<EOF
[Unit]
Description=MANAGER Connection Engine policy reconciliation
After=network-online.target

[Service]
Type=oneshot
ExecStart=$MANAGER_HOME/modules/policy_engine.sh --reconcile
EOF

  cat > "$POLICY_TIMER" <<'EOF'
[Unit]
Description=MANAGER periodic identity policy reconciliation

[Timer]
OnBootSec=20s
OnUnitActiveSec=30s
AccuracySec=5s
Persistent=true
Unit=manager-policy-reconcile.service

[Install]
WantedBy=timers.target
EOF

  cat > "$POLICY_PATH" <<EOF
[Unit]
Description=MANAGER identity policy change watcher

[Path]
PathChanged=$IDENTITY_CHANGED
Unit=manager-policy-reconcile.service

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "$POLICY_SERVICE" "$POLICY_TIMER" "$POLICY_PATH"
  systemctl daemon-reload
  systemctl enable --now manager-policy-reconcile.timer manager-policy-reconcile.path >/dev/null 2>&1 || true
  reconcile_all
}

remove_openvpn_hook_block() {
  local tmp
  [[ -f "$OVPN_CONF" ]] || return 0
  grep -q '^# MANAGER-IDENTITY-POLICY-BEGIN$' "$OVPN_CONF" 2>/dev/null || return 0
  tmp="$(mktemp)"
  awk '
    $0=="# MANAGER-IDENTITY-POLICY-BEGIN" {skip=1; next}
    $0=="# MANAGER-IDENTITY-POLICY-END" {skip=0; next}
    !skip {print}
  ' "$OVPN_CONF" > "$tmp"
  install -m 0644 "$tmp" "$OVPN_CONF"
  rm -f "$tmp"
}

detach_policy() {
  local file id client
  init_policy_state
  systemctl disable --now manager-policy-reconcile.timer manager-policy-reconcile.path >/dev/null 2>&1 || true
  rm -f "$POLICY_SERVICE" "$POLICY_TIMER" "$POLICY_PATH"
  rm -f "$SSH_POLICY_FILE" "$SSH_LIMITS_FILE"
  for file in "$IDENTITY_DIR"/*.conf; do
    [[ -f "$file" ]] || continue
    id="${file##*/}"; id="${id%.conf}"
    clear_ovpn_drop_rules "$id"
    client="$(identity_read "$id" wireguard_client)"
    [[ -z "$client" ]] || wg_restore_client "$client"
  done
  remove_openvpn_hook_block
  rm -f "$OVPN_HOOK" "$OVPN_PENDING"
  systemctl daemon-reload || true
  if command_exists sshd && sshd -t; then
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
  fi
  if systemctl is-active --quiet openvpn-server@manager 2>/dev/null; then
    systemctl restart openvpn-server@manager 2>/dev/null || true
  fi
}

init_policy_state
case "${1:-}" in
  --install) ( flock -x 9; install_units ) 9>"$POLICY_LOCK" ;;
  --reconcile) ( flock -n 9; reconcile_all ) 9>"$POLICY_LOCK" || exit 0 ;;
  --detach) ( flock -x 9; detach_policy ) 9>"$POLICY_LOCK" ;;
  --sessions) show_sessions_machine "${2:-}" ;;
  --authorize)
    [[ -n "${2:-}" && -n "${3:-}" ]] || exit 64
    resource_authorized "$2" "$3"
    ;;
  *)
    err "Uso: policy_engine.sh --install|--reconcile|--detach|--sessions [ID]|--authorize PROTOCOLO RECURSO"
    exit 64
    ;;
esac
