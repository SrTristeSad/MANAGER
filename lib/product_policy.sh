#!/usr/bin/env bash

PRODUCT_ROOT="${PRODUCT_ROOT:-${IDENTITY_ROOT:-${MANAGER_ETC:-/etc/manager}/connection}/products}"
PRODUCT_DIR="$PRODUCT_ROOT/catalog"
PRODUCT_ASSIGN_DIR="$PRODUCT_ROOT/assignments"
PRODUCT_USAGE_ROOT="${MANAGER_PRODUCT_USAGE_ROOT:-${IDENTITY_ROOT:-${MANAGER_ETC:-/etc/manager}/connection}/product-usage}"
PRODUCT_USAGE_DIR="$PRODUCT_USAGE_ROOT/identities"
IDENTITY_USAGE_DIR="${MANAGER_USAGE_ROOT:-/var/lib/manager/identity-usage}/identities"

product_valid_id() {
  [[ "${1:-}" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,47}$ ]]
}

product_record_file() {
  printf '%s/%s.conf\n' "$PRODUCT_DIR" "$1"
}

product_assignment_file() {
  printf '%s/%s.conf\n' "$PRODUCT_ASSIGN_DIR" "$1"
}

product_quota_file() {
  printf '%s/%s.state\n' "$PRODUCT_USAGE_DIR" "$1"
}

product_exists() {
  product_valid_id "$1" && [[ -f "$(product_record_file "$1")" ]]
}

product_read_file_field() {
  local file="$1" key="$2"
  awk -F= -v k="$key" '$1==k {sub(/^[^=]*=/,""); print; exit}' "$file" 2>/dev/null || true
}

product_read() {
  product_read_file_field "$(product_record_file "$1")" "$2"
}

product_assignment_read() {
  product_read_file_field "$(product_assignment_file "$1")" "$2"
}

product_quota_read() {
  product_read_file_field "$(product_quota_file "$1")" "$2"
}

product_for_identity() {
  local identity="$1" product
  product="$(product_assignment_read "$identity" product_id)"
  [[ -n "$product" ]] || return 1
  printf '%s\n' "$product"
}

product_acl_allows() {
  local list="${1:-*}" value="${2:-}" item
  [[ -n "$value" ]] || return 0
  [[ -n "$list" ]] || list="*"
  [[ "$list" == "*" ]] && return 0
  IFS=',' read -r -a _product_acl_items <<< "$list"
  for item in "${_product_acl_items[@]}"; do
    [[ "$item" == "$value" ]] && return 0
  done
  return 1
}

product_current_usage_total() {
  local identity="$1" file download upload
  file="$IDENTITY_USAGE_DIR/$identity.state"
  [[ -f "$file" ]] || { printf '0\n'; return 0; }
  download="$(product_read_file_field "$file" download_bytes)"
  upload="$(product_read_file_field "$file" upload_bytes)"
  [[ "$download" =~ ^[0-9]+$ ]] || download=0
  [[ "$upload" =~ ^[0-9]+$ ]] || upload=0
  printf '%s\n' "$((download + upload))"
}

product_quota_cycle() {
  local period="$1" assigned_epoch="${2:-0}"
  case "$period" in
    monthly) date -u '+%Y-%m' ;;
    lifetime) printf 'lifetime-%s\n' "$assigned_epoch" ;;
    none|'') printf 'none\n' ;;
    *) printf 'invalid\n' ;;
  esac
}

product_quota_enforceable() {
  local identity="$1" ssh_user
  if declare -F identity_has_protocol >/dev/null 2>&1 && identity_has_protocol "$identity" ssh; then
    ssh_user="$(identity_read "$identity" ssh_user 2>/dev/null || true)"
    if [[ -n "$ssh_user" ]]; then
      printf '0\n'
      return 0
    fi
  fi
  printf '1\n'
}

product_quota_metrics() {
  local identity="$1" product quota period action assigned cycle state_cycle baseline total used remaining exceeded=0 enforceable
  product="$(product_for_identity "$identity" 2>/dev/null || true)"
  if [[ -z "$product" || ! -f "$(product_record_file "$product")" ]]; then
    printf '0\t0\t0\t0\t1\tnone\tnone\n'
    return 0
  fi

  quota="$(product_read "$product" traffic_quota_bytes)"
  period="$(product_read "$product" quota_period)"
  action="$(product_read "$product" quota_action)"
  assigned="$(product_assignment_read "$identity" assigned_epoch)"
  [[ "$quota" =~ ^[0-9]+$ ]] || quota=0
  [[ "$assigned" =~ ^[0-9]+$ ]] || assigned=0
  case "$period" in monthly|lifetime|none) ;; *) period=none ;; esac
  case "$action" in block|warn) ;; *) action=warn ;; esac

  cycle="$(product_quota_cycle "$period" "$assigned")"
  state_cycle="$(product_quota_read "$identity" cycle)"
  baseline="$(product_quota_read "$identity" baseline_total_bytes)"
  total="$(product_current_usage_total "$identity")"
  [[ "$baseline" =~ ^[0-9]+$ ]] || baseline="$total"
  if [[ "$state_cycle" != "$cycle" ]]; then baseline="$total"; fi
  if (( total >= baseline )); then used=$((total - baseline)); else used="$total"; fi

  if (( quota == 0 )); then
    remaining=0
  elif (( used >= quota )); then
    remaining=0
    exceeded=1
  else
    remaining=$((quota - used))
  fi
  enforceable="$(product_quota_enforceable "$identity")"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$quota" "$used" "$remaining" "$exceeded" "$enforceable" "$cycle" "$action"
}

product_identity_state() {
  local identity="$1" product enabled metrics quota used remaining exceeded enforceable cycle action
  product="$(product_for_identity "$identity" 2>/dev/null || true)"
  [[ -n "$product" ]] || { printf 'active\n'; return 0; }
  product_exists "$product" || { printf 'product-missing\n'; return 0; }
  enabled="$(product_read "$product" enabled)"
  [[ "$enabled" == 1 ]] || { printf 'product-disabled\n'; return 0; }

  metrics="$(product_quota_metrics "$identity")"
  IFS=$'\t' read -r quota used remaining exceeded enforceable cycle action <<< "$metrics"
  : "$quota" "$used" "$remaining" "$cycle"
  if [[ "$action" == block && "$exceeded" == 1 && "$enforceable" == 1 ]]; then
    printf 'quota-exceeded\n'
  else
    printf 'active\n'
  fi
}

product_context_authorized() {
  local identity="$1" protocol="${2:-}" region="${3:-}" pool="${4:-}" node="${5:-}" product state
  state="$(identity_effective_state "$identity")"
  [[ "$state" == active ]] || return 68
  if [[ -n "$protocol" ]]; then
    identity_has_protocol "$identity" "$protocol" || return 67
  fi
  product="$(product_for_identity "$identity" 2>/dev/null || true)"
  [[ -n "$product" ]] || return 0
  product_exists "$product" || return 68
  product_acl_allows "$(product_read "$product" acl_regions)" "$region" || return 67
  product_acl_allows "$(product_read "$product" acl_pools)" "$pool" || return 67
  product_acl_allows "$(product_read "$product" acl_nodes)" "$node" || return 67
  return 0
}
