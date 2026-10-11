#!/usr/bin/env bash

IDENTITY_ROOT="${IDENTITY_ROOT:-${MANAGER_ETC:-/etc/manager}/connection}"
IDENTITY_DIR="$IDENTITY_ROOT/identities"
IDENTITY_LOCK="$IDENTITY_ROOT/.lock"
IDENTITY_CHANGED="$IDENTITY_ROOT/.changed"

identity_init() {
  mkdir -p "$IDENTITY_DIR"
  chmod 0700 "$IDENTITY_ROOT" "$IDENTITY_DIR"
  touch "$IDENTITY_LOCK"
  chmod 0600 "$IDENTITY_LOCK"
  if [[ ! -e "$IDENTITY_CHANGED" ]]; then
    touch "$IDENTITY_CHANGED"
    chmod 0600 "$IDENTITY_CHANGED"
  fi
}

identity_signal_change() {
  identity_init
  # Provisionamento transacional pode fazer várias escritas intermediárias.
  # Nesses casos o chamador sinaliza uma única vez depois do commit/rollback,
  # evitando que o watcher aplique uma identidade parcialmente construída.
  [[ "${MANAGER_DEFER_POLICY_SIGNAL:-0}" == 1 ]] && return 0
  touch "$IDENTITY_CHANGED"
}

identity_valid_id() {
  [[ "${1:-}" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,47}$ ]]
}

identity_file() {
  printf '%s/%s.conf\n' "$IDENTITY_DIR" "$1"
}

identity_exists() {
  [[ -f "$(identity_file "$1")" ]]
}

identity_read() {
  local id="$1" key="$2" file
  file="$(identity_file "$id")"
  awk -F= -v k="$key" '$1==k {sub(/^[^=]*=/,""); print; exit}' "$file" 2>/dev/null || true
}

identity_protocols_valid() {
  local value="${1:-}" item
  [[ -n "$value" ]] || return 1
  IFS=',' read -r -a _identity_protocol_items <<< "$value"
  for item in "${_identity_protocol_items[@]}"; do
    case "$item" in
      ssh|wireguard|openvpn) ;;
      *) return 1 ;;
    esac
  done
}

identity_has_protocol() {
  local id="$1" wanted="$2" protocols item
  protocols="$(identity_read "$id" protocols)"
  IFS=',' read -r -a _identity_protocol_items <<< "$protocols"
  for item in "${_identity_protocol_items[@]}"; do
    [[ "$item" == "$wanted" ]] && return 0
  done
  return 1
}

identity_write() {
  local id="$1" owner="$2" enabled="$3" expires_epoch="$4" max_sessions="$5" protocols="$6" created_epoch="$7" updated_epoch="$8" ssh_user="$9" wireguard_client="${10}" openvpn_client="${11}" tmp file
  identity_init
  file="$(identity_file "$id")"
  tmp="$(mktemp)"
  {
    printf 'id=%s\n' "$id"
    printf 'owner=%s\n' "$owner"
    printf 'enabled=%s\n' "$enabled"
    printf 'expires_epoch=%s\n' "$expires_epoch"
    printf 'max_sessions=%s\n' "$max_sessions"
    printf 'protocols=%s\n' "$protocols"
    printf 'created_epoch=%s\n' "$created_epoch"
    printf 'updated_epoch=%s\n' "$updated_epoch"
    printf 'ssh_user=%s\n' "$ssh_user"
    printf 'wireguard_client=%s\n' "$wireguard_client"
    printf 'openvpn_client=%s\n' "$openvpn_client"
  } > "$tmp"
  install -m 0600 "$tmp" "$file"
  rm -f "$tmp"
  identity_signal_change
}

identity_is_expired() {
  local id="$1" expires now
  expires="$(identity_read "$id" expires_epoch)"
  [[ "$expires" =~ ^[0-9]+$ ]] || return 1
  (( expires > 0 )) || return 1
  now="$(date +%s)"
  (( now >= expires ))
}

identity_effective_state() {
  local id="$1" enabled product_state
  enabled="$(identity_read "$id" enabled)"
  if [[ "$enabled" != 1 ]]; then
    printf 'disabled\n'
  elif identity_is_expired "$id"; then
    printf 'expired\n'
  elif declare -F product_identity_state >/dev/null 2>&1; then
    product_state="$(product_identity_state "$id")"
    if [[ "$product_state" == active ]]; then
      printf 'active\n'
    else
      printf '%s\n' "$product_state"
    fi
  else
    printf 'active\n'
  fi
}

# A camada de produto é opcional para preservar rollback/compatibilidade com
# versões anteriores. Quando instalada, acrescenta estado de plano/franquia à
# identidade sem alterar o contrato base do Connection Engine.
_product_policy_lib="${MANAGER_HOME:-/opt/manager}/lib/product_policy.sh"
if [[ -r "$_product_policy_lib" ]]; then
  # shellcheck source=/dev/null
  source "$_product_policy_lib"
fi
unset _product_policy_lib
