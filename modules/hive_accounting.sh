#!/usr/bin/env bash
set -Eeuo pipefail

MANAGER_HOME="${MANAGER_HOME:-/opt/manager}"
MANAGER_ETC="${MANAGER_ETC:-/etc/manager}"
# shellcheck source=/dev/null
source "$MANAGER_HOME/lib/common.sh"
# shellcheck source=/dev/null
source "$MANAGER_HOME/lib/identity.sh"
# shellcheck source=/dev/null
source "$MANAGER_HOME/lib/product_policy.sh"
require_root

LEASE_MODULE="$MANAGER_HOME/modules/hive_leases.sh"
IDENTITY_USAGE="$MANAGER_HOME/modules/identity_usage.sh"
ACCOUNTING_ETC="$MANAGER_ETC/hive/accounting"
NODE_CONF="$ACCOUNTING_ETC/node.conf"
CTRL_ETC="$MANAGER_ETC/hive/controller/accounting"
QUOTA_DIR="$CTRL_ETC/quotas"
DATA_ROOT="${MANAGER_HIVE_ACCOUNTING_DATA_DIR:-/var/lib/manager/hive-accounting}"
CTRL_STATE_DIR="$DATA_ROOT/controller/identities"
CTRL_SOURCE_DIR="$DATA_ROOT/controller/sources"
AUDIT_FILE="${MANAGER_HIVE_ACCOUNTING_AUDIT_FILE:-/var/log/manager/hive-accounting-audit.jsonl}"
USAGE_STATE_DIR="${MANAGER_USAGE_ROOT:-/var/lib/manager/identity-usage}/identities"
ENROLLMENT_CONF="$MANAGER_ETC/hive/node/enrollment.conf"
LEASE_NODE_CONF="$MANAGER_ETC/hive/leases/node.conf"
SYSTEMD_DIR="${MANAGER_HIVE_ACCOUNTING_SYSTEMD_DIR:-/etc/systemd/system}"
SYNC_SERVICE="$SYSTEMD_DIR/manager-hive-accounting-sync.service"
SYNC_TIMER="$SYSTEMD_DIR/manager-hive-accounting-sync.timer"
UNIT_MARKER="# MANAGER-HIVE-GLOBAL-ACCOUNTING v1"

init_dirs() {
  install -d -m 0700 "$ACCOUNTING_ETC" "$CTRL_ETC" "$QUOTA_DIR" "$DATA_ROOT" "$CTRL_STATE_DIR" "$CTRL_SOURCE_DIR"
}

read_kv() {
  local file="$1" key="$2"
  awk -F= -v k="$key" '$1==k {sub(/^[^=]*=/,""); print; exit}' "$file" 2>/dev/null || true
}

valid_id() { [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,47}$ ]]; }
valid_uint() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }
valid_period() { [[ "${1:-}" == none || "${1:-}" == monthly || "${1:-}" == lifetime ]]; }
valid_action() { [[ "${1:-}" == warn || "${1:-}" == block ]]; }

quota_file() { printf '%s/%s.conf\n' "$QUOTA_DIR" "$1"; }
state_file() { printf '%s/%s.json\n' "$CTRL_STATE_DIR" "$1"; }

current_total() {
  local id="$1" file
  file="$(state_file "$id")"
  python3 - "$file" <<'PY'
import json,sys
try:
    d=json.load(open(sys.argv[1]))
    print(int(d.get('download_bytes',0))+int(d.get('upload_bytes',0)))
except Exception:
    print(0)
PY
}

state_field() {
  local id="$1" key="$2" file
  file="$(state_file "$id")"
  python3 - "$file" "$key" <<'PY'
import json,sys
try:
    d=json.load(open(sys.argv[1]))
    v=d.get(sys.argv[2], '')
    if isinstance(v,bool): print(1 if v else 0)
    else: print(v)
except Exception:
    print('')
PY
}

quota_cycle() {
  local period="$1" seed="${2:-0}"
  case "$period" in
    monthly) date -u '+%Y-%m' ;;
    lifetime) printf 'lifetime-%s\n' "$seed" ;;
    none) printf 'none\n' ;;
  esac
}

write_quota() {
  local id="$1" product="$2" quota="$3" period="$4" action="$5" cycle="$6" baseline="$7" created="$8" now="$9" tmp
  tmp="$(mktemp)"
  {
    printf 'version=1\n'
    printf 'identity_id=%s\n' "$id"
    printf 'product_id=%s\n' "$product"
    printf 'quota_bytes=%s\n' "$quota"
    printf 'quota_period=%s\n' "$period"
    printf 'quota_action=%s\n' "$action"
    printf 'cycle=%s\n' "$cycle"
    printf 'baseline_total_bytes=%s\n' "$baseline"
    printf 'created_epoch=%s\n' "$created"
    printf 'updated_epoch=%s\n' "$now"
  } >"$tmp"
  install -m 0600 "$tmp" "$(quota_file "$id")"
  rm -f "$tmp"
}

quota_set() {
  local id="$1" product="$2" quota="$3" period="$4" action="$5" now baseline cycle created file
  valid_id "$id" || { err "identity_id inválido"; return 64; }
  valid_id "$product" || { err "product_id inválido"; return 64; }
  valid_uint "$quota" || { err "quota inválida"; return 64; }
  valid_period "$period" || { err "quota_period inválido"; return 64; }
  valid_action "$action" || { err "quota_action inválido"; return 64; }
  if (( quota > 0 )) && [[ "$period" == none ]]; then
    err "Franquia finita exige período monthly ou lifetime"
    return 64
  fi
  init_dirs
  now="$(date +%s)"
  baseline="$(current_total "$id")"
  file="$(quota_file "$id")"
  created="$(read_kv "$file" created_epoch)"
  valid_uint "$created" || created="$now"
  cycle="$(quota_cycle "$period" "$created")"
  write_quota "$id" "$product" "$quota" "$period" "$action" "$cycle" "$baseline" "$created" "$now"
  printf 'identity_id=%s\nproduct_id=%s\nquota_bytes=%s\nquota_period=%s\nquota_action=%s\nbaseline_total_bytes=%s\n' \
    "$id" "$product" "$quota" "$period" "$action" "$baseline"
}

quota_unset() {
  local id="$1"
  valid_id "$id" || return 64
  rm -f "$(quota_file "$id")"
  printf 'quota_unset=1\nidentity_id=%s\n' "$id"
}

quota_import_local() {
  local id="$1" product quota period action
  identity_valid_id "$id" || return 64
  identity_exists "$id" || return 66
  product="$(product_for_identity "$id" 2>/dev/null || true)"
  [[ -n "$product" ]] || { err "Identidade sem produto local atribuído: $id"; return 66; }
  product_exists "$product" || { err "Produto local ausente: $product"; return 66; }
  quota="$(product_read "$product" traffic_quota_bytes)"
  period="$(product_read "$product" quota_period)"
  action="$(product_read "$product" quota_action)"
  quota_set "$id" "$product" "$quota" "$period" "$action"
}

quota_sync_local() {
  local file id imported=0 failed=0
  init_dirs
  for file in "$PRODUCT_ASSIGN_DIR"/*.conf; do
    [[ -f "$file" ]] || continue
    id="${file##*/}"; id="${id%.conf}"
    if quota_import_local "$id" >/dev/null; then imported=$((imported+1)); else failed=$((failed+1)); fi
  done
  printf 'quotas_imported=%s\nquotas_failed=%s\n' "$imported" "$failed"
  (( failed == 0 ))
}

quota_show() {
  local id="$1" file quota baseline total used remaining complete enforceable exceeded=0 period action cycle product
  valid_id "$id" || return 64
  file="$(quota_file "$id")"
  [[ -f "$file" ]] || return 66
  quota="$(read_kv "$file" quota_bytes)"; valid_uint "$quota" || quota=0
  baseline="$(read_kv "$file" baseline_total_bytes)"; valid_uint "$baseline" || baseline=0
  total="$(current_total "$id")"; valid_uint "$total" || total=0
  if (( total >= baseline )); then used=$((total-baseline)); else used="$total"; fi
  if (( quota == 0 )); then remaining=0; elif (( used >= quota )); then remaining=0; exceeded=1; else remaining=$((quota-used)); fi
  complete="$(state_field "$id" traffic_complete)"; [[ "$complete" == 0 || "$complete" == 1 ]] || complete=1
  enforceable="$complete"
  period="$(read_kv "$file" quota_period)"
  action="$(read_kv "$file" quota_action)"
  cycle="$(read_kv "$file" cycle)"
  product="$(read_kv "$file" product_id)"
  printf 'identity_id=%s\nproduct_id=%s\nquota_bytes=%s\nquota_used_bytes=%s\nquota_remaining_bytes=%s\nquota_exceeded=%s\nquota_enforceable=%s\nquota_period=%s\nquota_cycle=%s\nquota_action=%s\nglobal_total_bytes=%s\ntraffic_complete=%s\n' \
    "$id" "$product" "$quota" "$used" "$remaining" "$exceeded" "$enforceable" "$period" "$cycle" "$action" "$total" "$complete"
}

quota_list() {
  local file id
  init_dirs
  for file in "$QUOTA_DIR"/*.conf; do
    [[ -f "$file" ]] || continue
    id="${file##*/}"; id="${id%.conf}"
    printf '%s\tproduct=%s\tquota=%s\tperiod=%s\taction=%s\tused=%s\texceeded=%s\n' \
      "$id" "$(read_kv "$file" product_id)" "$(read_kv "$file" quota_bytes)" "$(read_kv "$file" quota_period)" \
      "$(read_kv "$file" quota_action)" "$(quota_show "$id" | awk -F= '$1=="quota_used_bytes"{print $2}')" \
      "$(quota_show "$id" | awk -F= '$1=="quota_exceeded"{print $2}')"
  done
}

controller_show() {
  local id="$1" file
  valid_id "$id" || return 64
  file="$(state_file "$id")"
  [[ -f "$file" ]] || return 66
  python3 - "$file" <<'PY'
import json,sys
x=json.load(open(sys.argv[1]))
for k in ('identity_id','product_id','download_bytes','upload_bytes','total_bytes','wireguard_download_bytes','wireguard_upload_bytes','openvpn_download_bytes','openvpn_upload_bytes','traffic_complete','source_nodes','updated_epoch'):
    print(f"{k}={x.get(k,'')}")
PY
  if [[ -f "$(quota_file "$id")" ]]; then
    quota_show "$id"
  else
    printf 'global_quota_configured=0\n'
  fi
}

controller_list() {
  local file id
  init_dirs
  for file in "$CTRL_STATE_DIR"/*.json; do
    [[ -f "$file" ]] || continue
    id="${file##*/}"; id="${id%.json}"
    printf '%s\ttotal=%s\tcomplete=%s\tproduct=%s\n' "$id" "$(state_field "$id" total_bytes)" "$(state_field "$id" traffic_complete)" "$(state_field "$id" product_id)"
  done
}

node_conf_valid() {
  [[ -f "$NODE_CONF" ]] || return 1
  [[ "$(read_kv "$NODE_CONF" enabled)" == 1 ]] || return 1
  local node epoch
  node="$(read_kv "$ENROLLMENT_CONF" node_id)"
  epoch="$(read_kv "$ENROLLMENT_CONF" node_epoch)"
  [[ -n "$node" && -n "$epoch" ]] || return 1
  [[ "$(read_kv "$NODE_CONF" node_id)" == "$node" && "$(read_kv "$NODE_CONF" node_epoch)" == "$epoch" ]]
}

owned_unit() {
  local file="$1" first=""
  [[ -f "$file" && ! -L "$file" ]] || return 1
  IFS= read -r first <"$file" || true
  [[ "$first" == "$UNIT_MARKER" ]]
}

write_units() {
  local file
  for file in "$SYNC_SERVICE" "$SYNC_TIMER"; do
    if [[ -e "$file" || -L "$file" ]]; then
      owned_unit "$file" || { err "Recusando substituir unit externa: $file"; return 65; }
    fi
  done
  cat >"$SYNC_SERVICE" <<EOF
$UNIT_MARKER
[Unit]
Description=MANAGER Hive global accounting sync
After=network-online.target manager-hive-lease-controller.service manager-identity-usage.service

[Service]
Type=oneshot
ExecStart=$MANAGER_HOME/modules/hive_accounting.sh --sync
UMask=0077
PrivateTmp=true
NoNewPrivileges=true
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
PrivateDevices=true
RestrictSUIDSGID=true
EOF
  cat >"$SYNC_TIMER" <<EOF
$UNIT_MARKER
[Unit]
Description=MANAGER periodic Hive global accounting sync

[Timer]
OnBootSec=25s
OnUnitActiveSec=30s
AccuracySec=3s
Persistent=true
Unit=manager-hive-accounting-sync.service

[Install]
WantedBy=timers.target
EOF
  chmod 0644 "$SYNC_SERVICE" "$SYNC_TIMER"
  systemctl daemon-reload
}

enable_timer() {
  write_units
  systemctl enable --now manager-hive-accounting-sync.timer >/dev/null 2>&1 || true
}

detach() {
  systemctl disable --now manager-hive-accounting-sync.timer >/dev/null 2>&1 || true
  systemctl stop manager-hive-accounting-sync.service >/dev/null 2>&1 || true
  owned_unit "$SYNC_SERVICE" && rm -f "$SYNC_SERVICE"
  owned_unit "$SYNC_TIMER" && rm -f "$SYNC_TIMER"
  systemctl daemon-reload >/dev/null 2>&1 || true
}

node_enable() {
  local node epoch now tmp
  [[ -x "$LEASE_MODULE" && -f "$LEASE_NODE_CONF" && "$(read_kv "$LEASE_NODE_CONF" enabled)" == 1 ]] || {
    err "Configure primeiro a autoridade global de leases neste nó"
    return 67
  }
  [[ -x "$IDENTITY_USAGE" ]] || { err "Identity Usage ausente"; return 69; }
  node="$(read_kv "$ENROLLMENT_CONF" node_id)"
  epoch="$(read_kv "$ENROLLMENT_CONF" node_epoch)"
  [[ -n "$node" && -n "$epoch" ]] || { err "Enrollment da Colmeia ausente"; return 67; }
  init_dirs
  now="$(date +%s)"
  tmp="$(mktemp)"
  printf 'version=1\nenabled=1\nnode_id=%s\nnode_epoch=%s\ninterval_seconds=30\nupdated_epoch=%s\n' "$node" "$epoch" "$now" >"$tmp"
  install -m 0600 "$tmp" "$NODE_CONF"
  rm -f "$tmp"
  enable_timer
  printf 'global_accounting=1\nnode_id=%s\nnode_epoch=%s\nsync_interval_seconds=30\ntransport=lease-control-ed25519-tls13\n' "$node" "$epoch"
}

node_disable() {
  local tmp now
  detach
  if [[ -f "$NODE_CONF" ]]; then
    now="$(date +%s)"; tmp="$(mktemp)"
    sed 's/^enabled=.*/enabled=0/' "$NODE_CONF" >"$tmp"
    if ! grep -q '^updated_epoch=' "$tmp"; then printf 'updated_epoch=%s\n' "$now" >>"$tmp"; fi
    install -m 0600 "$tmp" "$NODE_CONF"; rm -f "$tmp"
  fi
  printf 'global_accounting=0\n'
}

sync_one() {
  local id="$1" file product tracking updated download upload wg_d wg_u ovpn_d ovpn_u complete=1 source_epoch
  file="$USAGE_STATE_DIR/$id.state"
  [[ -f "$file" ]] || return 0
  product="$(product_for_identity "$id" 2>/dev/null || true)"
  product="${product:-unassigned}"
  tracking="$(read_kv "$file" tracking_started_epoch)"; valid_uint "$tracking" || tracking=0
  updated="$(read_kv "$file" updated_epoch)"; valid_uint "$updated" || updated="$(date +%s)"
  download="$(read_kv "$file" download_bytes)"; valid_uint "$download" || download=0
  upload="$(read_kv "$file" upload_bytes)"; valid_uint "$upload" || upload=0
  wg_d="$(read_kv "$file" wireguard_download_bytes)"; valid_uint "$wg_d" || wg_d=0
  wg_u="$(read_kv "$file" wireguard_upload_bytes)"; valid_uint "$wg_u" || wg_u=0
  ovpn_d="$(read_kv "$file" openvpn_download_bytes)"; valid_uint "$ovpn_d" || ovpn_d=0
  ovpn_u="$(read_kv "$file" openvpn_upload_bytes)"; valid_uint "$ovpn_u" || ovpn_u=0
  if identity_has_protocol "$id" ssh && [[ -n "$(identity_read "$id" ssh_user)" ]]; then complete=0; fi
  source_epoch="usage-$tracking"
  "$LEASE_MODULE" --usage-ingest-node "$id" "$product" "$source_epoch" "$download" "$upload" "$wg_d" "$wg_u" "$ovpn_d" "$ovpn_u" "$complete" "$updated" >/dev/null
}

sync_node() {
  local wanted="${1:-}" file id synced=0 failed=0
  node_conf_valid || { err "Accounting global não está habilitado ou ficou stale após reenrollment"; return 67; }
  "$IDENTITY_USAGE" --collect >/dev/null
  if [[ -n "$wanted" ]]; then
    identity_valid_id "$wanted" || return 64
    identity_exists "$wanted" || return 66
    if sync_one "$wanted"; then synced=1; else failed=1; fi
  else
    for file in "$IDENTITY_DIR"/*.conf; do
      [[ -f "$file" ]] || continue
      id="${file##*/}"; id="${id%.conf}"
      if sync_one "$id"; then synced=$((synced+1)); else failed=$((failed+1)); fi
    done
  fi
  printf 'accounting_synced=%s\naccounting_failed=%s\n' "$synced" "$failed"
  (( failed == 0 ))
}

status() {
  local enabled=0 active=0 node="" epoch=""
  init_dirs
  if node_conf_valid; then enabled=1; node="$(read_kv "$NODE_CONF" node_id)"; epoch="$(read_kv "$NODE_CONF" node_epoch)"; fi
  systemctl is-active --quiet manager-hive-accounting-sync.timer 2>/dev/null && active=1 || true
  printf 'contract=manager-hive-global-accounting-v1\nglobal_accounting=%s\nnode_id=%s\nnode_epoch=%s\ntransport=lease-control-ed25519-tls13\ningestion=cumulative-per-node-delta-dedup\nbilling_authoritative=1\nmetered_protocols=wireguard,openvpn\nssh_bytes_supported=0\nsync_timer_active=%s\n' "$enabled" "$node" "$epoch" "$active"
}

controller_status() {
  init_dirs
  local identities quotas
  identities="$(find "$CTRL_STATE_DIR" -maxdepth 1 -type f -name '*.json' 2>/dev/null | wc -l)"
  quotas="$(find "$QUOTA_DIR" -maxdepth 1 -type f -name '*.conf' 2>/dev/null | wc -l)"
  printf 'contract=manager-hive-global-accounting-v1\ncontroller_accounting=1\nglobal_usage_authority=1\ndeduplication=per-node-cumulative\nquota_authority=separate-from-max-sessions\nidentities=%s\nquotas=%s\n' "$identities" "$quotas"
}

install_module() {
  init_dirs
  if node_conf_valid; then enable_timer; fi
}

purge_module() {
  detach
  rm -rf "$ACCOUNTING_ETC" "$CTRL_ETC" "$DATA_ROOT"
  rm -f "$AUDIT_FILE"
}

init_dirs
case "${1:-}" in
  --install) install_module ;;
  --detach) detach ;;
  --purge) purge_module ;;
  --status|"") status ;;
  --node-enable) node_enable ;;
  --node-disable) node_disable ;;
  --sync) sync_node "${2:-}" ;;
  --controller-status) controller_status ;;
  --controller-show) [[ -n "${2:-}" ]] || exit 64; controller_show "$2" ;;
  --controller-list) controller_list ;;
  --quota-set) [[ -n "${2:-}" && -n "${3:-}" && -n "${4:-}" && -n "${5:-}" && -n "${6:-}" ]] || exit 64; quota_set "$2" "$3" "$4" "$5" "$6" ;;
  --quota-unset) [[ -n "${2:-}" ]] || exit 64; quota_unset "$2" ;;
  --quota-show) [[ -n "${2:-}" ]] || exit 64; quota_show "$2" ;;
  --quota-list) quota_list ;;
  --quota-import-local) [[ -n "${2:-}" ]] || exit 64; quota_import_local "$2" ;;
  --quota-sync-local) quota_sync_local ;;
  *)
    err "Uso: hive_accounting.sh --status|--node-enable|--node-disable|--sync [ID]|--controller-status|--controller-show ID|--controller-list|--quota-set ID PRODUCT BYTES PERIOD ACTION|--quota-show ID|--quota-list|--quota-import-local ID|--quota-sync-local|--quota-unset ID"
    exit 64
    ;;
esac
