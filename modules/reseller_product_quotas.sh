#!/usr/bin/env bash
set -Eeuo pipefail

MANAGER_HOME="${MANAGER_HOME:-/opt/manager}"
MANAGER_ETC="${MANAGER_ETC:-/etc/manager}"
# shellcheck source=/dev/null
source "$MANAGER_HOME/lib/common.sh"
require_root

ACCESS_DIR="$MANAGER_ETC/access"
RESELLERS_DIR="$ACCESS_DIR/resellers"
IDENTITY_SLOTS_DIR="$ACCESS_DIR/identity-slots"
PRODUCT_QUOTAS_DIR="$ACCESS_DIR/product-quotas"
IDENTITY_DIR="$MANAGER_ETC/connection/identities"
PRODUCT_DIR="$MANAGER_ETC/connection/products/catalog"
ASSIGN_DIR="$MANAGER_ETC/connection/products/assignments"
LOCK_FILE="$ACCESS_DIR/.lock"

init_state() {
  install -d -m 0700 "$ACCESS_DIR" "$RESELLERS_DIR" "$IDENTITY_SLOTS_DIR" "$PRODUCT_QUOTAS_DIR"
  touch "$LOCK_FILE"
  chmod 0600 "$LOCK_FILE"
}

valid_id() { [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,47}$ ]]; }
read_field() {
  local file="$1" key="$2"
  awk -F= -v k="$key" '$1==k {sub(/^[^=]*=/,""); print; exit}' "$file" 2>/dev/null || true
}
reseller_file() { printf '%s/%s.conf\n' "$RESELLERS_DIR" "$1"; }
identity_file() { printf '%s/%s.conf\n' "$IDENTITY_DIR" "$1"; }
slot_file() { printf '%s/%s.conf\n' "$IDENTITY_SLOTS_DIR" "$1"; }
assignment_file() { printf '%s/%s.conf\n' "$ASSIGN_DIR" "$1"; }
product_file() { printf '%s/%s.conf\n' "$PRODUCT_DIR" "$1"; }
quota_dir() { printf '%s/%s\n' "$PRODUCT_QUOTAS_DIR" "$1"; }
quota_file() { printf '%s/%s/%s.conf\n' "$PRODUCT_QUOTAS_DIR" "$1" "$2"; }

reseller_exists() { valid_id "$1" && [[ -f "$(reseller_file "$1")" ]]; }
product_exists_local() { valid_id "$1" && [[ -f "$(product_file "$1")" ]]; }
role_of() { read_field "$(reseller_file "$1")" role; }
parent_of() { read_field "$(reseller_file "$1")" parent; }
enabled_of() { read_field "$(reseller_file "$1")" enabled; }

identity_counts_for_owner() {
  local identity_id="$1" owner="$2" identity slot
  identity="$(identity_file "$identity_id")"
  [[ -f "$identity" ]] || return 1
  [[ "$(read_field "$identity" owner)" == "$owner" ]] || return 1
  slot="$(slot_file "$identity_id")"
  if [[ -f "$slot" ]]; then
    [[ "$(read_field "$slot" active)" == 1 && "$(read_field "$slot" owner)" == "$owner" ]]
  else
    return 0
  fi
}

quota_of() {
  local owner="$1" product="$2" file value
  file="$(quota_file "$owner" "$product")"
  [[ -f "$file" ]] || { printf '0\n'; return 0; }
  value="$(read_field "$file" quota)"
  [[ "$value" =~ ^[0-9]+$ ]] || value=0
  printf '%s\n' "$value"
}

children_of() {
  local owner="$1" file child
  for file in "$RESELLERS_DIR"/*.conf; do
    [[ -f "$file" ]] || continue
    [[ "$(read_field "$file" parent)" == "$owner" ]] || continue
    child="${file##*/}"
    printf '%s\n' "${child%.conf}"
  done
}

direct_product_usage() {
  local owner="$1" product="$2" file identity_id count=0
  for file in "$ASSIGN_DIR"/*.conf; do
    [[ -f "$file" ]] || continue
    [[ "$(read_field "$file" product_id)" == "$product" ]] || continue
    identity_id="${file##*/}"
    identity_id="${identity_id%.conf}"
    identity_counts_for_owner "$identity_id" "$owner" || continue
    count=$((count + 1))
  done
  printf '%s\n' "$count"
}

subtree_product_usage() {
  local owner="$1" product="$2" total child child_usage
  total="$(direct_product_usage "$owner" "$product")"
  while IFS= read -r child; do
    [[ -n "$child" ]] || continue
    child_usage="$(direct_product_usage "$child" "$product")"
    total=$((total + child_usage))
  done < <(children_of "$owner")
  printf '%s\n' "$total"
}

product_usage_for() {
  local owner="$1" product="$2"
  if [[ "$(role_of "$owner")" == reseller ]]; then
    subtree_product_usage "$owner" "$product"
  else
    direct_product_usage "$owner" "$product"
  fi
}

assignment_increment() {
  local identity_id="$1" product="$2" file
  file="$(assignment_file "$identity_id")"
  if [[ -f "$file" && "$(read_field "$file" product_id)" == "$product" ]]; then
    printf '0\n'
  else
    printf '1\n'
  fi
}

can_assign_impl() {
  local owner="$1" product="$2" identity_id="$3" quota used increment parent pquota pused identity
  reseller_exists "$owner" || return 66
  product_exists_local "$product" || return 66
  [[ "$(enabled_of "$owner")" == 1 ]] || return 73

  identity="$(identity_file "$identity_id")"
  if [[ -f "$identity" ]]; then
    identity_counts_for_owner "$identity_id" "$owner" || return 73
  fi

  increment="$(assignment_increment "$identity_id" "$product")"
  quota="$(quota_of "$owner" "$product")"
  used="$(product_usage_for "$owner" "$product")"
  if (( quota > 0 && used + increment > quota )); then return 73; fi

  parent="$(parent_of "$owner")"
  if [[ -n "$parent" ]]; then
    reseller_exists "$parent" || return 66
    [[ "$(enabled_of "$parent")" == 1 ]] || return 73
    pquota="$(quota_of "$parent" "$product")"
    pused="$(subtree_product_usage "$parent" "$product")"
    if (( pquota > 0 && pused + increment > pquota )); then return 73; fi
  fi
  return 0
}

write_quota() {
  local owner="$1" product="$2" quota="$3" now tmp dir
  dir="$(quota_dir "$owner")"
  install -d -m 0700 "$dir"
  tmp="$(mktemp)"
  now="$(date +%s)"
  {
    printf 'version=1\n'
    printf 'owner=%s\n' "$owner"
    printf 'product_id=%s\n' "$product"
    printf 'quota=%s\n' "$quota"
    printf 'updated_epoch=%s\n' "$now"
  } > "$tmp"
  install -m 0600 "$tmp" "$(quota_file "$owner" "$product")"
  rm -f "$tmp"
}

set_quota_impl() {
  local owner="$1" product="$2" quota="$3" used parent pquota
  reseller_exists "$owner" || { err "Revendedor não encontrado: $owner"; return 66; }
  product_exists_local "$product" || { err "Produto não encontrado: $product"; return 66; }
  [[ "$quota" =~ ^[0-9]+$ ]] || { err "Cota de produto inválida"; return 64; }
  (( quota <= 1000000 )) || { err "Cota de produto muito alta"; return 64; }
  used="$(product_usage_for "$owner" "$product")"
  if (( quota > 0 && quota < used )); then
    err "A cota não pode ficar abaixo do uso atual ($used)"
    return 73
  fi
  parent="$(parent_of "$owner")"
  if [[ -n "$parent" ]]; then
    pquota="$(quota_of "$parent" "$product")"
    if (( pquota > 0 && quota > pquota )); then
      warn "A cota local supera a cota do pai; o limite do pai continuará valendo."
    fi
  fi
  write_quota "$owner" "$product" "$quota"
}

show_machine() {
  local owner="$1" product="$2" quota usage parent parent_quota parent_usage remaining
  reseller_exists "$owner" || return 66
  product_exists_local "$product" || return 66
  quota="$(quota_of "$owner" "$product")"
  usage="$(product_usage_for "$owner" "$product")"
  if (( quota == 0 )); then remaining="unlimited"; else remaining=$((quota - usage)); (( remaining >= 0 )) || remaining=0; fi
  parent="$(parent_of "$owner")"
  printf 'owner=%s\nproduct_id=%s\nusage=%s\nquota=%s\nremaining=%s\n' "$owner" "$product" "$usage" "$quota" "$remaining"
  if [[ -n "$parent" ]]; then
    parent_quota="$(quota_of "$parent" "$product")"
    parent_usage="$(subtree_product_usage "$parent" "$product")"
    printf 'parent=%s\nparent_usage=%s\nparent_quota=%s\n' "$parent" "$parent_usage" "$parent_quota"
  fi
}

list_machine() {
  local owner="${1:-}" dir file product quota usage
  if [[ -n "$owner" ]]; then
    valid_id "$owner" || return 64
    reseller_exists "$owner" || return 66
    dir="$(quota_dir "$owner")"
    [[ -d "$dir" ]] || return 0
    for file in "$dir"/*.conf; do
      [[ -f "$file" ]] || continue
      product="${file##*/}"; product="${product%.conf}"
      quota="$(quota_of "$owner" "$product")"
      usage="$(product_usage_for "$owner" "$product")"
      printf '%s\t%s\t%s\t%s\n' "$owner" "$product" "$usage" "$quota"
    done
    return 0
  fi

  for dir in "$PRODUCT_QUOTAS_DIR"/*; do
    [[ -d "$dir" ]] || continue
    owner="${dir##*/}"
    list_machine "$owner"
  done
}

interactive_list() {
  local owner
  header
  say "${C_WHITE}COTAS DE PRODUTO POR REVENDEDOR${C_RESET}\n"
  read -r -p "Revendedor/subrevendedor (vazio = todos): " owner
  printf '%-20s %-20s %-8s %-8s\n' "REVENDEDOR" "PRODUTO" "USO" "COTA"
  printf '%-20s %-20s %-8s %-8s\n' "--------------------" "--------------------" "--------" "--------"
  list_machine "$owner" || warn "Não foi possível listar"
  pause
}

interactive_set() {
  local owner product quota
  header
  say "${C_WHITE}DEFINIR COTA DE PRODUTO${C_RESET}\n"
  read -r -p "Revendedor/subrevendedor: " owner
  read -r -p "Produto: " product
  read -r -p "Cota deste produto (0 = ilimitada): " quota
  if ( flock -x 9; set_quota_impl "$owner" "$product" "$quota" ) 9>"$LOCK_FILE"; then
    ok "Cota salva"
    show_machine "$owner" "$product"
  fi
  pause
}

init_state
case "${1:-}" in
  --set)
    valid_id "${2:-}" || exit 64
    valid_id "${3:-}" || exit 64
    ( flock -x 9; set_quota_impl "$2" "$3" "${4:-}" ) 9>"$LOCK_FILE"
    exit $?
    ;;
  --show) show_machine "${2:-}" "${3:-}"; exit $? ;;
  --list) list_machine "${2:-}"; exit $? ;;
  --can-assign)
    valid_id "${2:-}" || exit 64
    valid_id "${3:-}" || exit 64
    valid_id "${4:-}" || exit 64
    can_assign_impl "$2" "$3" "$4"
    exit $?
    ;;
  "") ;;
  *) err "Ação inválida: $1"; exit 64 ;;
esac

while true; do
  header
  say "${C_WHITE}COTAS DE PRODUTO POR REVENDEDOR${C_RESET}\n"
  say " 1) Listar cotas"
  say " 2) Definir/alterar cota"
  say " 0) Voltar"
  say ""
  read -r -p "Opção: " opt
  case "$opt" in
    1) interactive_list ;;
    2) interactive_set ;;
    0) exit 0 ;;
    *) warn "Opção inválida"; sleep 1 ;;
  esac
done
