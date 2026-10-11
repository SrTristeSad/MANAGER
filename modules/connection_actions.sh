#!/usr/bin/env bash
set -Eeuo pipefail

MANAGER_HOME="${MANAGER_HOME:-/opt/manager}"
MANAGER_ETC="${MANAGER_ETC:-/etc/manager}"
# shellcheck source=/dev/null
source "$MANAGER_HOME/lib/common.sh"
# shellcheck source=/dev/null
source "$MANAGER_HOME/lib/identity.sh"
require_root

PROVISION_MODULE="$MANAGER_HOME/modules/provision.sh"
CONNECTION_MODULE="$MANAGER_HOME/modules/connection_engine.sh"
CONNECTION_CHANGED="$MANAGER_ETC/connection/.changed"
WG_CLIENT_DIR="$MANAGER_ETC/wireguard/clients"
OVPN_CLIENT_DIR="$MANAGER_ETC/openvpn/clients"
OVPN_META_DIR="$MANAGER_ETC/openvpn/meta"

signal_policy_change() {
  install -d -m 0700 "$(dirname "$CONNECTION_CHANGED")"
  touch "$CONNECTION_CHANGED"
  chmod 0600 "$CONNECTION_CHANGED"
}

require_runtime() {
  [[ -x "$PROVISION_MODULE" ]] || { err "Provisionador ausente: $PROVISION_MODULE"; return 69; }
  [[ -x "$CONNECTION_MODULE" ]] || { err "Connection Engine ausente: $CONNECTION_MODULE"; return 69; }
}

run_transaction() {
  local rc=0
  require_runtime || return $?
  MANAGER_DEFER_POLICY_SIGNAL=1 "$PROVISION_MODULE" "$@" || rc=$?
  signal_policy_change
  return "$rc"
}

binding_status() {
  local protocol="$1" resource="$2" meta status
  [[ -n "$resource" ]] || { printf 'unbound\n'; return 0; }
  case "$protocol" in
    ssh)
      if id "$resource" >/dev/null 2>&1; then printf 'present\n'; else printf 'missing\n'; fi
      ;;
    wireguard)
      if [[ -f "$WG_CLIENT_DIR/$resource.conf" && -f "$WG_CLIENT_DIR/$resource.meta" ]]; then
        printf 'present\n'
      else
        printf 'missing\n'
      fi
      ;;
    openvpn)
      meta="$OVPN_META_DIR/$resource.meta"
      if [[ -f "$meta" ]]; then
        status="$(awk -F= '$1=="status"{print $2; exit}' "$meta" 2>/dev/null || true)"
        if [[ "$status" == revoked ]]; then
          printf 'revoked\n'
        elif [[ -f "$OVPN_CLIENT_DIR/$resource.ovpn" ]]; then
          printf 'present\n'
        else
          printf 'missing\n'
        fi
      else
        printf 'missing\n'
      fi
      ;;
    *) return 64 ;;
  esac
}

protocol_allowed() {
  local id="$1" protocol="$2"
  if identity_has_protocol "$id" "$protocol"; then printf '1\n'; else printf '0\n'; fi
}

show_status() {
  local id="$1" product="" ssh wg ovpn
  identity_valid_id "$id" || { err "ID de identidade inválido"; return 64; }
  identity_exists "$id" || { err "Identidade não encontrada: $id"; return 66; }

  ssh="$(identity_read "$id" ssh_user)"
  wg="$(identity_read "$id" wireguard_client)"
  ovpn="$(identity_read "$id" openvpn_client)"
  if declare -F product_for_identity >/dev/null 2>&1; then
    product="$(product_for_identity "$id" 2>/dev/null || true)"
  fi

  printf 'contract=manager-connection-actions-v1\n'
  printf 'identity_id=%s\n' "$id"
  printf 'state=%s\n' "$(identity_effective_state "$id")"
  printf 'owner=%s\n' "$(identity_read "$id" owner)"
  printf 'product_id=%s\n' "$product"
  printf 'protocols=%s\n' "$(identity_read "$id" protocols)"
  printf 'expires_epoch=%s\n' "$(identity_read "$id" expires_epoch)"
  printf 'max_sessions=%s\n' "$(identity_read "$id" max_sessions)"
  printf 'ssh_allowed=%s\n' "$(protocol_allowed "$id" ssh)"
  printf 'ssh_resource=%s\n' "$ssh"
  printf 'ssh_status=%s\n' "$(binding_status ssh "$ssh")"
  printf 'wireguard_allowed=%s\n' "$(protocol_allowed "$id" wireguard)"
  printf 'wireguard_resource=%s\n' "$wg"
  printf 'wireguard_status=%s\n' "$(binding_status wireguard "$wg")"
  printf 'openvpn_allowed=%s\n' "$(protocol_allowed "$id" openvpn)"
  printf 'openvpn_resource=%s\n' "$ovpn"
  printf 'openvpn_status=%s\n' "$(binding_status openvpn "$ovpn")"
}

show_contract() {
  cat <<'EOF'
contract=manager-connection-actions-v1
version=1
actions=preflight,create,revoke,status,describe
create_secret_delivery=stdout-once
arbitrary_shell=0
arbitrary_command=0
arbitrary_path=0
protocols=ssh,wireguard,openvpn
exit_success=0
exit_invalid_input=64
exit_conflict=65
exit_not_found=66
exit_policy_denied=67
exit_disabled=68
exit_dependency_unavailable=69
exit_operation_failed=70
exit_quota_denied=73
EOF
}

case "${1:-}" in
  --describe)
    [[ $# -eq 1 ]] || exit 64
    show_contract
    ;;
  --status)
    [[ $# -eq 2 ]] || { err "Uso: connection_actions.sh --status ID"; exit 64; }
    show_status "$2"
    ;;
  --preflight)
    (( $# >= 3 && $# <= 5 )) || { err "Uso: connection_actions.sh --preflight ID PLAN [OWNER] [PROTOCOLS]"; exit 64; }
    require_runtime || exit $?
    "$PROVISION_MODULE" --preflight "$2" "$3" "${4:-}" "${5:-}"
    ;;
  --create)
    (( $# >= 3 && $# <= 5 )) || { err "Uso: connection_actions.sh --create ID PLAN [OWNER] [PROTOCOLS]"; exit 64; }
    run_transaction --create "$2" "$3" "${4:-}" "${5:-}"
    ;;
  --revoke)
    [[ $# -eq 2 ]] || { err "Uso: connection_actions.sh --revoke ID"; exit 64; }
    run_transaction --revoke "$2"
    ;;
  "")
    show_contract
    ;;
  *)
    err "Ação não permitida: ${1:-vazia}"
    err "Use somente --describe, --status, --preflight, --create ou --revoke."
    exit 64
    ;;
esac
