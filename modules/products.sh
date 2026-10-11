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

PRODUCT_SERVICE="/etc/systemd/system/manager-product-policy.service"
PRODUCT_TIMER="/etc/systemd/system/manager-product-policy.timer"
RESELLER_PRODUCT_QUOTA_MODULE="$MANAGER_HOME/modules/reseller_product_quotas.sh"

product_init() {
  identity_init
  install -d -m 0700 "$PRODUCT_ROOT" "$PRODUCT_DIR" "$PRODUCT_ASSIGN_DIR" "$PRODUCT_USAGE_ROOT" "$PRODUCT_USAGE_DIR"
  touch "$PRODUCT_LOCK"
  chmod 0600 "$PRODUCT_LOCK"
}

valid_nonnegative() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }
valid_enabled() { [[ "${1:-}" == 0 || "${1:-}" == 1 ]]; }
valid_period() { [[ "${1:-}" == none || "${1:-}" == monthly || "${1:-}" == lifetime ]]; }
valid_action() { [[ "${1:-}" == warn || "${1:-}" == block ]]; }
valid_name() {
  local value="${1:-}"
  [[ -n "$value" && ${#value} -le 96 && "$value" != *$'\n'* && "$value" != *$'\t'* ]]
}
valid_acl_token() { [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9_.:-]{0,63}$ ]]; }

normalize_protocols() {
  local input="${1:-}" item out="" seen=""
  [[ "$input" == "*" ]] && { printf '*\n'; return 0; }
  input="${input// /}"
  IFS=',' read -r -a items <<< "$input"
  for item in "${items[@]}"; do
    case "$item" in
      ssh|wireguard|openvpn)
        if [[ ",$seen," != *",$item,"* ]]; then
          [[ -n "$out" ]] && out+=","
          out+="$item"
          [[ -n "$seen" ]] && seen+=","
          seen+="$item"
        fi
        ;;
      *) return 1 ;;
    esac
  done
  [[ -n "$out" ]] || return 1
  printf '%s\n' "$out"
}

normalize_acl() {
  local input="${1:-*}" item out="" seen=""
  input="${input// /}"
  [[ -z "$input" || "$input" == "*" ]] && { printf '*\n'; return 0; }
  IFS=',' read -r -a items <<< "$input"
  for item in "${items[@]}"; do
    valid_acl_token "$item" || return 1
    if [[ ",$seen," != *",$item,"* ]]; then
      [[ -n "$out" ]] && out+=","
      out+="$item"
      [[ -n "$seen" ]] && seen+=","
      seen+="$item"
    fi
  done
  [[ -n "$out" ]] || return 1
  printf '%s\n' "$out"
}

intersect_protocols() {
  local base="$1" policy="$2" item out=""
  [[ "$policy" == "*" ]] && { printf '%s\n' "$base"; return 0; }
  IFS=',' read -r -a base_items <<< "$base"
  for item in "${base_items[@]}"; do
    case ",$policy," in
      *",$item,"*)
        [[ -n "$out" ]] && out+=","
        out+="$item"
        ;;
    esac
  done
  [[ -n "$out" ]] || return 1
  printf '%s\n' "$out"
}

write_product() {
  local id="$1" name="$2" enabled="$3" duration_days="$4" max_sessions="$5" protocols="$6"
  local quota="$7" period="$8" action="$9" regions="${10}" pools="${11}" nodes="${12}" created="${13}" updated="${14}" tmp
  tmp="$(mktemp)"
  {
    printf 'version=1\n'
    printf 'id=%s\n' "$id"
    printf 'name=%s\n' "$name"
    printf 'enabled=%s\n' "$enabled"
    printf 'duration_days=%s\n' "$duration_days"
    printf 'max_sessions=%s\n' "$max_sessions"
    printf 'protocols=%s\n' "$protocols"
    printf 'traffic_quota_bytes=%s\n' "$quota"
    printf 'quota_period=%s\n' "$period"
    printf 'quota_action=%s\n' "$action"
    printf 'acl_regions=%s\n' "$regions"
    printf 'acl_pools=%s\n' "$pools"
    printf 'acl_nodes=%s\n' "$nodes"
    printf 'created_epoch=%s\n' "$created"
    printf 'updated_epoch=%s\n' "$updated"
  } > "$tmp"
  install -m 0600 "$tmp" "$(product_record_file "$id")"
  rm -f "$tmp"
}

validate_product_values() {
  local id="$1" name="$2" enabled="$3" duration_days="$4" max_sessions="$5" protocols="$6"
  local quota="$7" period="$8" action="$9" regions="${10}" pools="${11}" nodes="${12}"
  product_valid_id "$id" || { err "ID de produto inválido"; return 64; }
  valid_name "$name" || { err "Nome do produto inválido"; return 64; }
  valid_enabled "$enabled" || { err "enabled deve ser 0 ou 1"; return 64; }
  valid_nonnegative "$duration_days" || { err "duration_days inválido"; return 64; }
  valid_nonnegative "$max_sessions" || { err "max_sessions inválido"; return 64; }
  valid_nonnegative "$quota" || { err "traffic_quota_bytes inválido"; return 64; }
  (( duration_days <= 36500 )) || { err "duration_days muito alto"; return 64; }
  (( max_sessions <= 10000 )) || { err "max_sessions muito alto"; return 64; }
  normalize_protocols "$protocols" >/dev/null || { err "Protocolos inválidos"; return 64; }
  valid_period "$period" || { err "quota_period inválido"; return 64; }
  valid_action "$action" || { err "quota_action inválido"; return 64; }
  normalize_acl "$regions" >/dev/null || { err "ACL de regiões inválida"; return 64; }
  normalize_acl "$pools" >/dev/null || { err "ACL de pools inválida"; return 64; }
  normalize_acl "$nodes" >/dev/null || { err "ACL de nós inválida"; return 64; }
  if (( quota > 0 )) && [[ "$period" == none ]]; then
    err "Uma franquia finita exige quota_period monthly ou lifetime"
    return 64
  fi
}

assignment_base_value() {
  local identity="$1" key="$2" current_key="$3" value
  value="$(product_assignment_read "$identity" "$key")"
  if [[ -n "$value" ]]; then
    printf '%s\n' "$value"
  else
    identity_read "$identity" "$current_key"
  fi
}

write_assignment() {
  local identity="$1" product="$2" assigned="$3" base_max="$4" base_protocols="$5" base_expires="$6" tmp
  tmp="$(mktemp)"
  {
    printf 'version=1\n'
    printf 'identity_id=%s\n' "$identity"
    printf 'product_id=%s\n' "$product"
    printf 'assigned_epoch=%s\n' "$assigned"
    printf 'base_max_sessions=%s\n' "$base_max"
    printf 'base_protocols=%s\n' "$base_protocols"
    printf 'base_expires_epoch=%s\n' "$base_expires"
  } > "$tmp"
  install -m 0600 "$tmp" "$(product_assignment_file "$identity")"
  rm -f "$tmp"
}

write_quota_state() {
  local identity="$1" product="$2" cycle="$3" baseline="$4" used="$5" quota="$6" exceeded="$7" enforceable="$8" action="$9" now="${10}" tmp
  tmp="$(mktemp)"
  {
    printf 'version=1\n'
    printf 'identity_id=%s\n' "$identity"
    printf 'product_id=%s\n' "$product"
    printf 'cycle=%s\n' "$cycle"
    printf 'baseline_total_bytes=%s\n' "$baseline"
    printf 'used_bytes=%s\n' "$used"
    printf 'quota_bytes=%s\n' "$quota"
    printf 'exceeded=%s\n' "$exceeded"
    printf 'enforceable=%s\n' "$enforceable"
    printf 'quota_action=%s\n' "$action"
    printf 'updated_epoch=%s\n' "$now"
  } > "$tmp"
  install -m 0600 "$tmp" "$(product_quota_file "$identity")"
  rm -f "$tmp"
}

calculate_identity_policy() {
  local product="$1" base_max="$2" base_protocols="$3" base_expires="$4" assigned_epoch="$5"
  local pmax pprotocols duration effective_max effective_protocols plan_expires effective_expires
  pmax="$(product_read "$product" max_sessions)"
  pprotocols="$(product_read "$product" protocols)"
  duration="$(product_read "$product" duration_days)"
  [[ "$pmax" =~ ^[0-9]+$ ]] || pmax=0
  [[ "$duration" =~ ^[0-9]+$ ]] || duration=0

  effective_protocols="$(intersect_protocols "$base_protocols" "$pprotocols")" || return 67
  effective_max="$base_max"
  if (( pmax > 0 && pmax < effective_max )); then effective_max="$pmax"; fi

  effective_expires="$base_expires"
  if (( duration > 0 )); then
    plan_expires=$((assigned_epoch + duration * 86400))
    if (( effective_expires == 0 || plan_expires < effective_expires )); then effective_expires="$plan_expires"; fi
  fi
  printf '%s\t%s\t%s\n' "$effective_max" "$effective_protocols" "$effective_expires"
}

rewrite_identity_policy() {
  local identity="$1" max_sessions="$2" protocols="$3" expires="$4"
  local owner enabled created ssh_user wg ovpn
  owner="$(identity_read "$identity" owner)"
  enabled="$(identity_read "$identity" enabled)"
  created="$(identity_read "$identity" created_epoch)"
  ssh_user="$(identity_read "$identity" ssh_user)"
  wg="$(identity_read "$identity" wireguard_client)"
  ovpn="$(identity_read "$identity" openvpn_client)"
  identity_write "$identity" "$owner" "$enabled" "$expires" "$max_sessions" "$protocols" "$created" "$(date +%s)" "$ssh_user" "$wg" "$ovpn"
}

apply_assignment_locked() {
  local identity="$1" product="$2" base_max="$3" base_protocols="$4" base_expires="$5" assigned="$6" calculated max protocols expires
  identity_exists "$identity" || return 66
  product_exists "$product" || return 66
  calculated="$(calculate_identity_policy "$product" "$base_max" "$base_protocols" "$base_expires" "$assigned")" || return $?
  IFS=$'\t' read -r max protocols expires <<< "$calculated"
  rewrite_identity_policy "$identity" "$max" "$protocols" "$expires"
}

init_quota_for_assignment() {
  local identity="$1" product="$2" assigned="$3" period cycle total quota action enforceable now
  period="$(product_read "$product" quota_period)"
  cycle="$(product_quota_cycle "$period" "$assigned")"
  total="$(product_current_usage_total "$identity")"
  quota="$(product_read "$product" traffic_quota_bytes)"
  action="$(product_read "$product" quota_action)"
  enforceable="$(product_quota_enforceable "$identity")"
  [[ "$quota" =~ ^[0-9]+$ ]] || quota=0
  now="$(date +%s)"
  write_quota_state "$identity" "$product" "$cycle" "$total" 0 "$quota" 0 "$enforceable" "$action" "$now"
}

reseller_product_allows_assignment() {
  local identity="$1" product="$2" owner
  owner="$(identity_read "$identity" owner)"
  [[ -n "$owner" ]] || return 0
  [[ -x "$RESELLER_PRODUCT_QUOTA_MODULE" ]] || {
    err "Módulo de cota de produto por revendedor ausente"
    return 69
  }
  if ! "$RESELLER_PRODUCT_QUOTA_MODULE" --can-assign "$owner" "$product" "$identity" >/dev/null 2>&1; then
    err "Cota do produto $product esgotada ou indisponível para $owner"
    return 73
  fi
}

assign_product_impl() {
  local identity="$1" product="$2" base_max base_protocols base_expires assigned calculated
  identity_valid_id "$identity" || return 64
  identity_exists "$identity" || { err "Identidade não encontrada: $identity"; return 66; }
  product_exists "$product" || { err "Produto não encontrado: $product"; return 66; }
  reseller_product_allows_assignment "$identity" "$product" || return $?

  base_max="$(assignment_base_value "$identity" base_max_sessions max_sessions)"
  base_protocols="$(assignment_base_value "$identity" base_protocols protocols)"
  base_expires="$(assignment_base_value "$identity" base_expires_epoch expires_epoch)"
  [[ "$base_max" =~ ^[1-9][0-9]*$ ]] || { err "max_sessions base inválido"; return 64; }
  identity_protocols_valid "$base_protocols" || { err "protocolos base inválidos"; return 64; }
  [[ "$base_expires" =~ ^[0-9]+$ ]] || base_expires=0
  assigned="$(date +%s)"
  calculated="$(calculate_identity_policy "$product" "$base_max" "$base_protocols" "$base_expires" "$assigned")" || {
    err "O produto não permite nenhum dos protocolos base de $identity"
    return 67
  }
  : "$calculated"

  apply_assignment_locked "$identity" "$product" "$base_max" "$base_protocols" "$base_expires" "$assigned"
  write_assignment "$identity" "$product" "$assigned" "$base_max" "$base_protocols" "$base_expires"
  init_quota_for_assignment "$identity" "$product" "$assigned"
  identity_signal_change
}

unassign_product_impl() {
  local identity="$1" file base_max base_protocols base_expires
  file="$(product_assignment_file "$identity")"
  [[ -f "$file" ]] || return 66
  identity_exists "$identity" || { rm -f "$file" "$(product_quota_file "$identity")"; return 0; }
  base_max="$(product_assignment_read "$identity" base_max_sessions)"
  base_protocols="$(product_assignment_read "$identity" base_protocols)"
  base_expires="$(product_assignment_read "$identity" base_expires_epoch)"
  [[ "$base_max" =~ ^[1-9][0-9]*$ ]] || return 64
  identity_protocols_valid "$base_protocols" || return 64
  [[ "$base_expires" =~ ^[0-9]+$ ]] || base_expires=0
  rewrite_identity_policy "$identity" "$base_max" "$base_protocols" "$base_expires"
  rm -f "$file" "$(product_quota_file "$identity")"
  identity_signal_change
}

validate_assignments_for_protocols() {
  local product="$1" protocols="$2" file identity base
  for file in "$PRODUCT_ASSIGN_DIR"/*.conf; do
    [[ -f "$file" ]] || continue
    [[ "$(product_read_file_field "$file" product_id)" == "$product" ]] || continue
    identity="${file##*/}"; identity="${identity%.conf}"
    base="$(product_read_file_field "$file" base_protocols)"
    identity_protocols_valid "$base" || continue
    intersect_protocols "$base" "$protocols" >/dev/null || {
      err "A alteração deixaria $identity sem protocolo permitido"
      return 67
    }
  done
}

upsert_product_impl() {
  local mode="$1" id="$2" name="$3" enabled="$4" duration="$5" max_sessions="$6" protocols="$7" quota="$8" period="$9"
  local action="${10}" regions="${11}" pools="${12}" nodes="${13}" normalized_protocols normalized_regions normalized_pools normalized_nodes created now
  validate_product_values "$id" "$name" "$enabled" "$duration" "$max_sessions" "$protocols" "$quota" "$period" "$action" "$regions" "$pools" "$nodes" || return $?
  normalized_protocols="$(normalize_protocols "$protocols")"
  normalized_regions="$(normalize_acl "$regions")"
  normalized_pools="$(normalize_acl "$pools")"
  normalized_nodes="$(normalize_acl "$nodes")"

  if [[ "$mode" == create ]]; then
    product_exists "$id" && { err "Produto já existe: $id"; return 65; }
    created="$(date +%s)"
  else
    product_exists "$id" || { err "Produto não encontrado: $id"; return 66; }
    created="$(product_read "$id" created_epoch)"
    [[ "$created" =~ ^[0-9]+$ ]] || created="$(date +%s)"
    validate_assignments_for_protocols "$id" "$normalized_protocols" || return $?
  fi

  now="$(date +%s)"
  write_product "$id" "$name" "$enabled" "$duration" "$max_sessions" "$normalized_protocols" "$quota" "$period" "$action" \
    "$normalized_regions" "$normalized_pools" "$normalized_nodes" "$created" "$now"

  if [[ "$mode" == update ]]; then
    reconcile_assignments_for_product "$id"
  fi
  identity_signal_change
}

reconcile_identity_quota() {
  local identity="$1" product assigned period cycle old_cycle baseline total used quota action enforceable exceeded=0
  local old_exceeded old_enforceable old_action old_quota now changed=0
  product="$(product_for_identity "$identity" 2>/dev/null || true)"
  [[ -n "$product" ]] || return 0
  product_exists "$product" || { identity_signal_change; return 0; }
  assigned="$(product_assignment_read "$identity" assigned_epoch)"
  [[ "$assigned" =~ ^[0-9]+$ ]] || assigned=0
  period="$(product_read "$product" quota_period)"
  cycle="$(product_quota_cycle "$period" "$assigned")"
  old_cycle="$(product_quota_read "$identity" cycle)"
  baseline="$(product_quota_read "$identity" baseline_total_bytes)"
  total="$(product_current_usage_total "$identity")"
  [[ "$baseline" =~ ^[0-9]+$ ]] || baseline="$total"
  if [[ "$old_cycle" != "$cycle" ]]; then baseline="$total"; changed=1; fi
  if (( total >= baseline )); then used=$((total - baseline)); else used="$total"; fi
  quota="$(product_read "$product" traffic_quota_bytes)"
  [[ "$quota" =~ ^[0-9]+$ ]] || quota=0
  if (( quota > 0 && used >= quota )); then exceeded=1; fi
  enforceable="$(product_quota_enforceable "$identity")"
  action="$(product_read "$product" quota_action)"
  case "$action" in block|warn) ;; *) action=warn ;; esac

  old_exceeded="$(product_quota_read "$identity" exceeded)"
  old_enforceable="$(product_quota_read "$identity" enforceable)"
  old_action="$(product_quota_read "$identity" quota_action)"
  old_quota="$(product_quota_read "$identity" quota_bytes)"
  [[ "$old_exceeded" == "$exceeded" ]] || changed=1
  [[ "$old_enforceable" == "$enforceable" ]] || changed=1
  [[ "$old_action" == "$action" ]] || changed=1
  [[ "$old_quota" == "$quota" ]] || changed=1
  now="$(date +%s)"
  write_quota_state "$identity" "$product" "$cycle" "$baseline" "$used" "$quota" "$exceeded" "$enforceable" "$action" "$now"
  (( changed == 0 )) || identity_signal_change
}

reconcile_assignments_for_product() {
  local product="$1" file identity base_max base_protocols base_expires assigned
  for file in "$PRODUCT_ASSIGN_DIR"/*.conf; do
    [[ -f "$file" ]] || continue
    [[ "$(product_read_file_field "$file" product_id)" == "$product" ]] || continue
    identity="${file##*/}"; identity="${identity%.conf}"
    identity_exists "$identity" || continue
    base_max="$(product_read_file_field "$file" base_max_sessions)"
    base_protocols="$(product_read_file_field "$file" base_protocols)"
    base_expires="$(product_read_file_field "$file" base_expires_epoch)"
    assigned="$(product_read_file_field "$file" assigned_epoch)"
    apply_assignment_locked "$identity" "$product" "$base_max" "$base_protocols" "$base_expires" "$assigned" || true
    reconcile_identity_quota "$identity"
  done
}

reconcile_all_locked() {
  local file identity product base_max base_protocols base_expires assigned
  product_init
  for file in "$PRODUCT_ASSIGN_DIR"/*.conf; do
    [[ -f "$file" ]] || continue
    identity="${file##*/}"; identity="${identity%.conf}"
    identity_exists "$identity" || continue
    product="$(product_read_file_field "$file" product_id)"
    if product_exists "$product"; then
      base_max="$(product_read_file_field "$file" base_max_sessions)"
      base_protocols="$(product_read_file_field "$file" base_protocols)"
      base_expires="$(product_read_file_field "$file" base_expires_epoch)"
      assigned="$(product_read_file_field "$file" assigned_epoch)"
      apply_assignment_locked "$identity" "$product" "$base_max" "$base_protocols" "$base_expires" "$assigned" || true
    fi
    reconcile_identity_quota "$identity"
  done
}

reset_quota_impl() {
  local identity="$1" product assigned
  identity_exists "$identity" || return 66
  product="$(product_for_identity "$identity" 2>/dev/null || true)"
  [[ -n "$product" ]] || return 66
  assigned="$(product_assignment_read "$identity" assigned_epoch)"
  init_quota_for_assignment "$identity" "$product" "$assigned"
  identity_signal_change
}

show_product_machine() {
  local id="$1"
  product_exists "$id" || return 66
  printf 'id=%s\n' "$id"
  printf 'name=%s\n' "$(product_read "$id" name)"
  printf 'enabled=%s\n' "$(product_read "$id" enabled)"
  printf 'duration_days=%s\n' "$(product_read "$id" duration_days)"
  printf 'max_sessions=%s\n' "$(product_read "$id" max_sessions)"
  printf 'protocols=%s\n' "$(product_read "$id" protocols)"
  printf 'traffic_quota_bytes=%s\n' "$(product_read "$id" traffic_quota_bytes)"
  printf 'quota_period=%s\n' "$(product_read "$id" quota_period)"
  printf 'quota_action=%s\n' "$(product_read "$id" quota_action)"
  printf 'acl_regions=%s\n' "$(product_read "$id" acl_regions)"
  printf 'acl_pools=%s\n' "$(product_read "$id" acl_pools)"
  printf 'acl_nodes=%s\n' "$(product_read "$id" acl_nodes)"
}

show_assignment_machine() {
  local identity="$1" product metrics quota used remaining exceeded enforceable cycle action
  [[ -f "$(product_assignment_file "$identity")" ]] || return 66
  product="$(product_for_identity "$identity")"
  printf 'identity_id=%s\n' "$identity"
  printf 'product_id=%s\n' "$product"
  printf 'assigned_epoch=%s\n' "$(product_assignment_read "$identity" assigned_epoch)"
  printf 'base_max_sessions=%s\n' "$(product_assignment_read "$identity" base_max_sessions)"
  printf 'base_protocols=%s\n' "$(product_assignment_read "$identity" base_protocols)"
  printf 'base_expires_epoch=%s\n' "$(product_assignment_read "$identity" base_expires_epoch)"
  if identity_exists "$identity"; then
    printf 'effective_state=%s\n' "$(identity_effective_state "$identity")"
    printf 'effective_max_sessions=%s\n' "$(identity_read "$identity" max_sessions)"
    printf 'effective_protocols=%s\n' "$(identity_read "$identity" protocols)"
    printf 'effective_expires_epoch=%s\n' "$(identity_read "$identity" expires_epoch)"
  fi
  metrics="$(product_quota_metrics "$identity")"
  IFS=$'\t' read -r quota used remaining exceeded enforceable cycle action <<< "$metrics"
  printf 'quota_bytes=%s\n' "$quota"
  printf 'quota_used_bytes=%s\n' "$used"
  printf 'quota_remaining_bytes=%s\n' "$remaining"
  printf 'quota_exceeded=%s\n' "$exceeded"
  printf 'quota_enforceable=%s\n' "$enforceable"
  printf 'quota_cycle=%s\n' "$cycle"
  printf 'quota_action=%s\n' "$action"
}

list_products_machine() {
  local file id
  product_init
  for file in "$PRODUCT_DIR"/*.conf; do
    [[ -f "$file" ]] || continue
    id="${file##*/}"; id="${id%.conf}"
    printf '%s\t%s\tenabled=%s\tmax=%s\tprotocols=%s\tquota=%s\tperiod=%s\taction=%s\n' \
      "$id" "$(product_read "$id" name)" "$(product_read "$id" enabled)" "$(product_read "$id" max_sessions)" \
      "$(product_read "$id" protocols)" "$(product_read "$id" traffic_quota_bytes)" "$(product_read "$id" quota_period)" "$(product_read "$id" quota_action)"
  done
}

install_units() {
  product_init
  cat > "$PRODUCT_SERVICE" <<EOF
[Unit]
Description=MANAGER product, ACL and quota reconciliation
After=network.target

[Service]
Type=oneshot
ExecStart=$MANAGER_HOME/modules/products.sh --reconcile
EOF
  cat > "$PRODUCT_TIMER" <<'EOF'
[Unit]
Description=Periodic MANAGER product/quota reconciliation

[Timer]
OnBootSec=20s
OnUnitActiveSec=30s
AccuracySec=5s
Unit=manager-product-policy.service

[Install]
WantedBy=timers.target
EOF
  chmod 0644 "$PRODUCT_SERVICE" "$PRODUCT_TIMER"
  systemctl daemon-reload
  systemctl enable --now manager-product-policy.timer >/dev/null 2>&1 || true
  reconcile_all_locked
}

detach_units() {
  systemctl disable --now manager-product-policy.timer >/dev/null 2>&1 || true
  rm -f "$PRODUCT_SERVICE" "$PRODUCT_TIMER"
  systemctl daemon-reload || true
}

human_bytes() {
  local bytes="$1"
  awk -v b="$bytes" 'BEGIN {
    split("B KiB MiB GiB TiB PiB", u, " "); i=1;
    while (b>=1024 && i<6) {b/=1024; i++}
    if (i==1) printf "%.0f %s", b, u[i]; else printf "%.2f %s", b, u[i]
  }'
}

interactive_list() {
  header
  say "${C_WHITE}PRODUTOS / PLANOS${C_RESET}\n"
  local file id found=0 quota
  printf '%-18s %-24s %-7s %-8s %-23s %-14s\n' "ID" "NOME" "ATIVO" "SESSÕES" "PROTOCOLOS" "FRANQUIA"
  for file in "$PRODUCT_DIR"/*.conf; do
    [[ -f "$file" ]] || continue
    found=1
    id="${file##*/}"; id="${id%.conf}"
    quota="$(product_read "$id" traffic_quota_bytes)"
    if [[ "$quota" =~ ^[0-9]+$ ]] && (( quota > 0 )); then quota="$(human_bytes "$quota")"; else quota="ilimitada"; fi
    printf '%-18s %-24s %-7s %-8s %-23s %-14s\n' "$id" "$(product_read "$id" name)" "$(product_read "$id" enabled)" \
      "$(product_read "$id" max_sessions)" "$(product_read "$id" protocols)" "$quota"
  done
  (( found == 1 )) || info "Nenhum produto criado"
  pause
}

interactive_create_or_update() {
  local mode="$1" id name enabled duration max protocols quota period action regions pools nodes current
  header
  if [[ "$mode" == create ]]; then say "${C_WHITE}CRIAR PRODUTO / PLANO${C_RESET}\n"; else say "${C_WHITE}ATUALIZAR PRODUTO / PLANO${C_RESET}\n"; fi
  read -r -p "ID: " id
  if [[ "$mode" == update ]]; then
    product_exists "$id" || { err "Produto não existe"; pause; return; }
    current="$(product_read "$id" name)"; read -r -p "Nome [$current]: " name; name="${name:-$current}"
    current="$(product_read "$id" enabled)"; read -r -p "Ativo 1/0 [$current]: " enabled; enabled="${enabled:-$current}"
    current="$(product_read "$id" duration_days)"; read -r -p "Duração em dias, 0=herdar [$current]: " duration; duration="${duration:-$current}"
    current="$(product_read "$id" max_sessions)"; read -r -p "Máx. sessões, 0=herdar [$current]: " max; max="${max:-$current}"
    current="$(product_read "$id" protocols)"; read -r -p "Protocolos ou * [$current]: " protocols; protocols="${protocols:-$current}"
    current="$(product_read "$id" traffic_quota_bytes)"; read -r -p "Franquia em bytes, 0=ilimitada [$current]: " quota; quota="${quota:-$current}"
    current="$(product_read "$id" quota_period)"; read -r -p "Período none/monthly/lifetime [$current]: " period; period="${period:-$current}"
    current="$(product_read "$id" quota_action)"; read -r -p "Ação warn/block [$current]: " action; action="${action:-$current}"
    current="$(product_read "$id" acl_regions)"; read -r -p "ACL regiões, *=todas [$current]: " regions; regions="${regions:-$current}"
    current="$(product_read "$id" acl_pools)"; read -r -p "ACL pools, *=todos [$current]: " pools; pools="${pools:-$current}"
    current="$(product_read "$id" acl_nodes)"; read -r -p "ACL nós, *=todos [$current]: " nodes; nodes="${nodes:-$current}"
  else
    read -r -p "Nome: " name
    read -r -p "Ativo 1/0 [1]: " enabled; enabled="${enabled:-1}"
    read -r -p "Duração em dias (0 = herdar identidade) [0]: " duration; duration="${duration:-0}"
    read -r -p "Máx. sessões (0 = herdar identidade) [0]: " max; max="${max:-0}"
    read -r -p "Protocolos [ssh,wireguard,openvpn]: " protocols; protocols="${protocols:-ssh,wireguard,openvpn}"
    read -r -p "Franquia em bytes (0 = ilimitada) [0]: " quota; quota="${quota:-0}"
    if (( quota > 0 )); then
      read -r -p "Período [monthly/lifetime]: " period; period="${period:-monthly}"
    else
      period=none
    fi
    read -r -p "Ao exceder [warn/block] [warn]: " action; action="${action:-warn}"
    read -r -p "ACL regiões (* ou CSV) [*]: " regions; regions="${regions:-*}"
    read -r -p "ACL pools (* ou CSV) [*]: " pools; pools="${pools:-*}"
    read -r -p "ACL nós (* ou CSV) [*]: " nodes; nodes="${nodes:-*}"
  fi
  if ( flock -x 9; upsert_product_impl "$mode" "$id" "$name" "$enabled" "$duration" "$max" "$protocols" "$quota" "$period" "$action" "$regions" "$pools" "$nodes" ) 9>"$PRODUCT_LOCK"; then
    ok "Produto $id salvo"
  fi
  pause
}

interactive_assign() {
  local identity product
  header
  say "${C_WHITE}VINCULAR PRODUTO A IDENTIDADE${C_RESET}\n"
  read -r -p "Identidade: " identity
  read -r -p "Produto: " product
  if ( flock -x 9; assign_product_impl "$identity" "$product" ) 9>"$PRODUCT_LOCK"; then ok "$product aplicado a $identity"; fi
  pause
}

interactive_unassign() {
  local identity
  header
  read -r -p "Identidade: " identity
  if confirm "Remover o produto e restaurar limites base de $identity?"; then
    if ( flock -x 9; unassign_product_impl "$identity" ) 9>"$PRODUCT_LOCK"; then ok "Produto removido"; fi
  fi
  pause
}

interactive_assignment() {
  local identity
  header
  read -r -p "Identidade: " identity
  if ! show_assignment_machine "$identity"; then warn "Identidade sem produto atribuído"; fi
  pause
}

product_init
case "${1:-}" in
  --init) printf '%s\n' "$PRODUCT_ROOT"; exit 0 ;;
  --list) list_products_machine; exit 0 ;;
  --show) show_product_machine "${2:-}"; exit $? ;;
  --assignment) show_assignment_machine "${2:-}"; exit $? ;;
  --create)
    shift
    ( flock -x 9; upsert_product_impl create "${1:-}" "${2:-}" "${3:-1}" "${4:-0}" "${5:-0}" "${6:-*}" "${7:-0}" "${8:-none}" "${9:-warn}" "${10:-*}" "${11:-*}" "${12:-*}" ) 9>"$PRODUCT_LOCK"
    exit $?
    ;;
  --update)
    shift
    ( flock -x 9; upsert_product_impl update "${1:-}" "${2:-}" "${3:-1}" "${4:-0}" "${5:-0}" "${6:-*}" "${7:-0}" "${8:-none}" "${9:-warn}" "${10:-*}" "${11:-*}" "${12:-*}" ) 9>"$PRODUCT_LOCK"
    exit $?
    ;;
  --assign) ( flock -x 9; assign_product_impl "${2:-}" "${3:-}" ) 9>"$PRODUCT_LOCK"; exit $? ;;
  --unassign) ( flock -x 9; unassign_product_impl "${2:-}" ) 9>"$PRODUCT_LOCK"; exit $? ;;
  --authorize) product_context_authorized "${2:-}" "${3:-}" "${4:-}" "${5:-}" "${6:-}"; exit $? ;;
  --reset-quota) ( flock -x 9; reset_quota_impl "${2:-}" ) 9>"$PRODUCT_LOCK"; exit $? ;;
  --reconcile) ( flock -x 9; reconcile_all_locked ) 9>"$PRODUCT_LOCK"; exit $? ;;
  --install) ( flock -x 9; install_units ) 9>"$PRODUCT_LOCK"; exit $? ;;
  --detach) detach_units; exit 0 ;;
  "") ;;
  *) err "Ação inválida: $1"; exit 64 ;;
esac

while true; do
  header
  say "${C_WHITE}PRODUTOS, PLANOS, ACL E FRANQUIAS${C_RESET}\n"
  say " 1) Listar produtos"
  say " 2) Criar produto"
  say " 3) Atualizar produto"
  say " 4) Vincular produto a identidade"
  say " 5) Ver produto/consumo da identidade"
  say " 6) Remover produto da identidade"
  say " 7) Resetar ciclo/franquia da identidade"
  say " 8) Reconciliar agora"
  say " 0) Voltar"
  say ""
  read -r -p "Opção: " opt
  case "$opt" in
    1) interactive_list ;;
    2) interactive_create_or_update create ;;
    3) interactive_create_or_update update ;;
    4) interactive_assign ;;
    5) interactive_assignment ;;
    6) interactive_unassign ;;
    7)
      header
      read -r -p "Identidade: " identity
      if confirm "Resetar a franquia atual de $identity a partir de agora?"; then
        ( flock -x 9; reset_quota_impl "$identity" ) 9>"$PRODUCT_LOCK" && ok "Franquia reiniciada"
      fi
      pause
      ;;
    8) ( flock -x 9; reconcile_all_locked ) 9>"$PRODUCT_LOCK"; ok "Produtos e cotas reconciliados"; pause ;;
    0) exit 0 ;;
    *) warn "Opção inválida"; sleep 1 ;;
  esac
done
