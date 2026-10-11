#!/usr/bin/env bash
set -Eeuo pipefail

MANAGER_HOME="${MANAGER_HOME:-/opt/manager}"
MANAGER_ETC="${MANAGER_ETC:-/etc/manager}"
# shellcheck source=/dev/null
source "$MANAGER_HOME/lib/common.sh"
# shellcheck source=/dev/null
source "$MANAGER_HOME/lib/identity.sh"
require_root

IDENTITY_USAGE="$MANAGER_HOME/modules/identity_usage.sh"
NODE_METADATA="$MANAGER_HOME/modules/node_metadata.sh"
SESSION_ENGINE="$MANAGER_HOME/modules/session_engine.sh"
USAGE_STATE_DIR="${MANAGER_USAGE_ROOT:-/var/lib/manager/identity-usage}/identities"
NODE_CONF="$MANAGER_ETC/connection/node/node.conf"

read_kv_file() {
  local file="$1" key="$2"
  awk -F= -v k="$key" '$1==k {sub(/^[^=]*=/,""); print; exit}' "$file" 2>/dev/null || true
}

uint_or_zero() {
  local value="${1:-0}"
  [[ "$value" =~ ^[0-9]+$ ]] && printf '%s\n' "$value" || printf '0\n'
}

state_number() {
  local id="$1" key="$2"
  uint_or_zero "$(read_kv_file "$USAGE_STATE_DIR/$id.state" "$key")"
}

node_field() {
  local key="$1" default="${2:-}" value
  value="$(read_kv_file "$NODE_CONF" "$key")"
  printf '%s\n' "${value:-$default}"
}

require_sources() {
  [[ -x "$IDENTITY_USAGE" ]] || { err "Identity Usage ausente: $IDENTITY_USAGE"; return 69; }
  [[ -x "$NODE_METADATA" ]] || { err "Node Metadata ausente: $NODE_METADATA"; return 69; }
  [[ -x "$SESSION_ENGINE" ]] || { err "Session Engine ausente: $SESSION_ENGINE"; return 69; }
}

protocols_from_leases() {
  awk -F'\t' '
    {
      for (i=3; i<=NF; i++) {
        if ($i=="protocol=ssh") ssh=1
        else if ($i=="protocol=wireguard") wg=1
        else if ($i=="protocol=openvpn") ovpn=1
      }
    }
    END {
      out=""
      if (ssh) out="ssh"
      if (wg) out=(out==""?"wireguard":out ",wireguard")
      if (ovpn) out=(out==""?"openvpn":out ",openvpn")
      print out
    }
  '
}

unique_session_identities() {
  awk -F'\t' 'NF && !seen[$1]++ {c++} END {print c+0}'
}

show_machine() {
  local generated node_id country region pool capacity weight node_max enabled capabilities ipv6
  local identities_total=0 identities_active=0 identities_tracked=0 partial_identities=0
  local download=0 upload=0 wg_download=0 wg_upload=0 ovpn_download=0 ovpn_upload=0
  local latest_activity=0 file id value sessions_cache sessions_total session_identities active_protocols traffic_complete

  require_sources || return $?
  "$NODE_METADATA" --init >/dev/null
  "$IDENTITY_USAGE" --collect >/dev/null

  generated="$(date +%s)"
  node_id="$(node_field node_id)"
  country="$(node_field country)"
  region="$(node_field region)"
  pool="$(node_field pool)"
  capacity="$(node_field capacity 1)"
  weight="$(node_field weight 1)"
  node_max="$(node_field max_sessions 0)"
  enabled="$(node_field enabled 1)"

  capabilities="$("$NODE_METADATA" --capabilities 2>/dev/null || true)"
  ipv6="$(printf '%s\n' "$capabilities" | awk -F= '$1=="ipv6"{print $2; exit}')"
  [[ "$ipv6" == 0 || "$ipv6" == 1 ]] || ipv6=0

  for file in "$IDENTITY_DIR"/*.conf; do
    [[ -f "$file" ]] || continue
    id="${file##*/}"
    id="${id%.conf}"
    identities_total=$((identities_total + 1))
    [[ "$(identity_effective_state "$id")" == active ]] && identities_active=$((identities_active + 1))

    if [[ -f "$USAGE_STATE_DIR/$id.state" ]]; then
      identities_tracked=$((identities_tracked + 1))
      value="$(state_number "$id" download_bytes)"; download=$((download + value))
      value="$(state_number "$id" upload_bytes)"; upload=$((upload + value))
      value="$(state_number "$id" wireguard_download_bytes)"; wg_download=$((wg_download + value))
      value="$(state_number "$id" wireguard_upload_bytes)"; wg_upload=$((wg_upload + value))
      value="$(state_number "$id" openvpn_download_bytes)"; ovpn_download=$((ovpn_download + value))
      value="$(state_number "$id" openvpn_upload_bytes)"; ovpn_upload=$((ovpn_upload + value))
      value="$(state_number "$id" last_activity_epoch)"
      (( value > latest_activity )) && latest_activity="$value"
    fi

    if identity_has_protocol "$id" ssh && [[ -n "$(identity_read "$id" ssh_user)" ]]; then
      partial_identities=$((partial_identities + 1))
    fi
  done

  sessions_cache="$("$SESSION_ENGINE" --list 2>/dev/null || true)"
  if [[ -n "$sessions_cache" ]]; then
    sessions_total="$(printf '%s\n' "$sessions_cache" | awk 'NF{c++} END{print c+0}')"
    session_identities="$(printf '%s\n' "$sessions_cache" | unique_session_identities)"
    active_protocols="$(printf '%s\n' "$sessions_cache" | protocols_from_leases)"
  else
    sessions_total=0
    session_identities=0
    active_protocols=""
  fi

  if (( partial_identities > 0 )); then traffic_complete=0; else traffic_complete=1; fi

  printf 'contract=manager-node-usage-v1\n'
  printf 'usage_scope=node-local\n'
  printf 'aggregation_kind=cumulative-local-metered\n'
  printf 'billing_authoritative=0\n'
  printf 'global_usage_supported=0\n'
  printf 'generated_epoch=%s\n' "$generated"
  printf 'node_id=%s\n' "$node_id"
  printf 'country=%s\n' "$country"
  printf 'region=%s\n' "$region"
  printf 'pool=%s\n' "$pool"
  printf 'node_enabled=%s\n' "$enabled"
  printf 'capacity=%s\n' "$capacity"
  printf 'weight=%s\n' "$weight"
  printf 'node_max_sessions=%s\n' "$node_max"
  printf 'ipv6=%s\n' "$ipv6"
  printf 'identities_total=%s\n' "$identities_total"
  printf 'identities_active=%s\n' "$identities_active"
  printf 'identities_tracked=%s\n' "$identities_tracked"
  printf 'identities_partial_traffic=%s\n' "$partial_identities"
  printf 'sessions=%s\n' "$sessions_total"
  printf 'session_identities=%s\n' "$session_identities"
  printf 'active_protocols=%s\n' "$active_protocols"
  printf 'download_bytes=%s\n' "$download"
  printf 'upload_bytes=%s\n' "$upload"
  printf 'total_bytes=%s\n' "$((download + upload))"
  printf 'wireguard_download_bytes=%s\n' "$wg_download"
  printf 'wireguard_upload_bytes=%s\n' "$wg_upload"
  printf 'wireguard_total_bytes=%s\n' "$((wg_download + wg_upload))"
  printf 'openvpn_download_bytes=%s\n' "$ovpn_download"
  printf 'openvpn_upload_bytes=%s\n' "$ovpn_upload"
  printf 'openvpn_total_bytes=%s\n' "$((ovpn_download + ovpn_upload))"
  printf 'traffic_complete=%s\n' "$traffic_complete"
  printf 'metered_protocols=wireguard,openvpn\n'
  printf 'ssh_bytes_supported=0\n'
  printf 'last_activity_epoch=%s\n' "$latest_activity"
  printf 'billing_note=local_telemetry_not_global_billing\n'
}

human_summary() {
  local output
  output="$(show_machine)" || return $?
  header
  say "${C_WHITE}USO AGREGADO DO NÓ${C_RESET}\n"
  printf '%s\n' "$output" | awk -F= '
    $1=="node_id" {printf "Nó:                  %s\n", $2}
    $1=="region" {printf "Região:              %s\n", ($2==""?"-":$2)}
    $1=="pool" {printf "Pool:                %s\n", ($2==""?"-":$2)}
    $1=="identities_total" {printf "Identidades:         %s\n", $2}
    $1=="identities_active" {printf "Identidades ativas:  %s\n", $2}
    $1=="sessions" {printf "Leases/sessões:      %s\n", $2}
    $1=="download_bytes" {printf "Download medido:     %s bytes\n", $2}
    $1=="upload_bytes" {printf "Upload medido:       %s bytes\n", $2}
    $1=="total_bytes" {printf "Total medido:        %s bytes\n", $2}
    $1=="traffic_complete" {printf "Cobertura completa:  %s\n", ($2=="1"?"sim":"não (há SSH sem byte accounting)")}
  '
  say ""
  info "Este agregado é telemetria local do nó. Não é faturamento global nem soma autoritativa da Colmeia."
}

case "${1:-}" in
  --show|--collect)
    [[ $# -eq 1 ]] || exit 64
    show_machine
    ;;
  --human|"")
    human_summary
    ;;
  --describe)
    cat <<'EOF'
contract=manager-node-usage-v1
usage_scope=node-local
billing_authoritative=0
global_usage_supported=0
metered_protocols=wireguard,openvpn
ssh_bytes_supported=0
EOF
    ;;
  *)
    err "Uso: node_usage.sh --show|--human|--describe"
    exit 64
    ;;
esac
