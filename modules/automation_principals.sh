#!/usr/bin/env bash
set -Eeuo pipefail

MANAGER_HOME="${MANAGER_HOME:-/opt/manager}"
MANAGER_ETC="${MANAGER_ETC:-/etc/manager}"
# shellcheck source=/dev/null
source "$MANAGER_HOME/lib/common.sh"
require_root

STATE_DIR="$MANAGER_ETC/automation/v2"
PRINCIPALS_DIR="$STATE_DIR/principals"
RESELLERS_DIR="$MANAGER_ETC/access/resellers"
IDENTITY_DIR="$MANAGER_ETC/connection/identities"
LOCAL_ROOT_ID="local-root"
HIVE_CONTROLLER_ID="hive-controller"

valid_principal_id() { [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9_.:-]{0,63}$ ]]; }
valid_subject_id() { [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,47}$ ]]; }
principal_file() { printf '%s/%s.conf\n' "$PRINCIPALS_DIR" "$1"; }
reseller_file() { printf '%s/%s.conf\n' "$RESELLERS_DIR" "$1"; }
identity_file() { printf '%s/%s.conf\n' "$IDENTITY_DIR" "$1"; }

read_field() {
  local file="$1" key="$2"
  awk -F= -v k="$key" '$1==k {sub(/^[^=]*=/,""); print; exit}' "$file" 2>/dev/null || true
}

normalize_products() {
  local input="${1:-*}" item out="" seen=""
  input="${input// /}"
  [[ -z "$input" || "$input" == "*" ]] && { printf '*\n'; return 0; }
  [[ "$input" == "-" ]] && { printf '%s\n' '-'; return 0; }
  IFS=',' read -r -a items <<< "$input"
  for item in "${items[@]}"; do
    [[ "$item" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$ ]] || return 1
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

normalize_remote_scope() {
  local input="${1:-*}" kind="${2:-label}" item out="" seen=""
  input="${input// /}"
  [[ -z "$input" || "$input" == "*" ]] && { printf '*\n'; return 0; }
  IFS=',' read -r -a items <<< "$input"
  for item in "${items[@]}"; do
    case "$kind" in
      node|pool)
        [[ "$item" =~ ^[A-Za-z0-9][A-Za-z0-9_.:-]{0,63}$ ]] || return 1
        ;;
      action)
        case "$item" in
          system.describe|node.usage|connection.preflight|connection.create|connection.status|connection.revoke|ops.read) ;;
          *) return 1 ;;
        esac
        ;;
      *) return 1 ;;
    esac
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

write_principal() {
  local id="$1" role="$2" subject="$3" products="$4" node_scope="$5" pool_scope="$6" action_scope="$7" enabled="$8" created="$9" updated="${10}" tmp
  tmp="$(mktemp "$STATE_DIR/.principal.XXXXXX")"
  {
    printf 'version=1\n'
    printf 'principal_id=%s\n' "$id"
    printf 'role=%s\n' "$role"
    printf 'subject=%s\n' "$subject"
    printf 'products=%s\n' "$products"
    printf 'node_scope=%s\n' "$node_scope"
    printf 'pool_scope=%s\n' "$pool_scope"
    printf 'action_scope=%s\n' "$action_scope"
    printf 'enabled=%s\n' "$enabled"
    printf 'created_epoch=%s\n' "$created"
    printf 'updated_epoch=%s\n' "$updated"
  } > "$tmp"
  install -m 0600 "$tmp" "$(principal_file "$id")"
  rm -f "$tmp"
}

validate_bound_subject() {
  local role="$1" subject="$2" file actual_role
  case "$role" in
    admin)
      [[ "$subject" == "*" ]] || { err "Principal admin deve usar subject=*"; return 64; }
      ;;
    reseller|subreseller)
      valid_subject_id "$subject" || { err "Subject de revenda inválido"; return 64; }
      file="$(reseller_file "$subject")"
      [[ -f "$file" ]] || { err "Revendedor/subrevendedor não existe: $subject"; return 66; }
      actual_role="$(read_field "$file" role)"
      [[ "$actual_role" == "$role" ]] || { err "Role do principal não corresponde ao subject ($actual_role)"; return 67; }
      ;;
    user)
      valid_subject_id "$subject" || { err "Subject de usuário inválido"; return 64; }
      [[ -f "$(identity_file "$subject")" ]] || { err "Identidade não existe: $subject"; return 66; }
      ;;
    *)
      err "Role inválida: $role"
      return 64
      ;;
  esac
}

init_state() {
  install -d -m 0700 "$STATE_DIR" "$PRINCIPALS_DIR"
  local file now role subject
  file="$(principal_file "$LOCAL_ROOT_ID")"
  if [[ ! -f "$file" ]]; then
    now="$(date +%s)"
    write_principal "$LOCAL_ROOT_ID" admin '*' '*' '*' '*' '*' 1 "$now" "$now"
  else
    role="$(read_field "$file" role)"
    subject="$(read_field "$file" subject)"
    [[ "$role" == admin && "$subject" == '*' ]] || {
      err "Principal reservado $LOCAL_ROOT_ID está corrompido; não será sobrescrito automaticamente."
      return 70
    }
    chmod 0600 "$file"
  fi
}

create_principal() {
  local id="${1:-}" role="${2:-}" subject="${3:-}" products="${4:-*}" normalized now
  init_state
  valid_principal_id "$id" || { err "principal_id inválido"; return 64; }
  [[ "$id" != "$LOCAL_ROOT_ID" ]] || { err "$LOCAL_ROOT_ID é reservado"; return 65; }
  [[ "$id" != "$HIVE_CONTROLLER_ID" ]] || { err "$HIVE_CONTROLLER_ID é reservado para a identidade da Colmeia"; return 65; }
  [[ ! -e "$(principal_file "$id")" ]] || { err "Principal já existe: $id"; return 65; }

  case "$role" in
    admin)
      [[ -z "$subject" || "$subject" == '*' || "$subject" == '-' ]] || { err "Admin não aceita subject externo"; return 64; }
      subject='*'
      products='*'
      ;;
    reseller|subreseller)
      validate_bound_subject "$role" "$subject" || return $?
      normalized="$(normalize_products "$products")" || { err "Escopo de produtos inválido"; return 64; }
      [[ "$normalized" != '-' ]] || { err "Revenda precisa de products=* ou lista CSV"; return 64; }
      products="$normalized"
      ;;
    user)
      validate_bound_subject "$role" "$subject" || return $?
      products='-'
      ;;
    *)
      err "Role inválida. Use admin, reseller, subreseller ou user."
      return 64
      ;;
  esac

  validate_bound_subject "$role" "$subject" || return $?
  now="$(date +%s)"
  write_principal "$id" "$role" "$subject" "$products" '*' '*' '*' 1 "$now" "$now"
  printf 'principal_id=%s\nrole=%s\nsubject=%s\nproducts=%s\nenabled=1\n' "$id" "$role" "$subject" "$products"
}

set_enabled() {
  local id="${1:-}" enabled="$2" file role subject products node_scope pool_scope action_scope created now
  init_state
  valid_principal_id "$id" || return 64
  [[ "$enabled" == 0 || "$enabled" == 1 ]] || return 64
  file="$(principal_file "$id")"
  [[ -f "$file" ]] || { err "Principal não existe: $id"; return 66; }
  if [[ "$id" == "$LOCAL_ROOT_ID" && "$enabled" == 0 ]]; then
    err "$LOCAL_ROOT_ID não pode ser desabilitado"
    return 73
  fi
  role="$(read_field "$file" role)"
  subject="$(read_field "$file" subject)"
  products="$(read_field "$file" products)"
  node_scope="$(read_field "$file" node_scope)"; node_scope="${node_scope:-*}"
  pool_scope="$(read_field "$file" pool_scope)"; pool_scope="${pool_scope:-*}"
  action_scope="$(read_field "$file" action_scope)"; action_scope="${action_scope:-*}"
  created="$(read_field "$file" created_epoch)"
  [[ "$created" =~ ^[0-9]+$ ]] || created="$(date +%s)"
  validate_bound_subject "$role" "$subject" || return $?
  now="$(date +%s)"
  write_principal "$id" "$role" "$subject" "$products" "$node_scope" "$pool_scope" "$action_scope" "$enabled" "$created" "$now"
  printf 'principal_id=%s\nenabled=%s\n' "$id" "$enabled"
}

set_products() {
  local id="${1:-}" input="${2:-}" file role subject enabled created products node_scope pool_scope action_scope now
  init_state
  valid_principal_id "$id" || return 64
  file="$(principal_file "$id")"
  [[ -f "$file" ]] || { err "Principal não existe: $id"; return 66; }
  role="$(read_field "$file" role)"
  [[ "$role" == reseller || "$role" == subreseller ]] || { err "Escopo de produto só se aplica a reseller/subreseller"; return 67; }
  products="$(normalize_products "$input")" || { err "Escopo de produtos inválido"; return 64; }
  [[ "$products" != '-' ]] || { err "Use * ou uma lista CSV de produtos"; return 64; }
  subject="$(read_field "$file" subject)"
  enabled="$(read_field "$file" enabled)"
  node_scope="$(read_field "$file" node_scope)"; node_scope="${node_scope:-*}"
  pool_scope="$(read_field "$file" pool_scope)"; pool_scope="${pool_scope:-*}"
  action_scope="$(read_field "$file" action_scope)"; action_scope="${action_scope:-*}"
  created="$(read_field "$file" created_epoch)"
  [[ "$created" =~ ^[0-9]+$ ]] || created="$(date +%s)"
  validate_bound_subject "$role" "$subject" || return $?
  now="$(date +%s)"
  write_principal "$id" "$role" "$subject" "$products" "$node_scope" "$pool_scope" "$action_scope" "$enabled" "$created" "$now"
  printf 'principal_id=%s\nproducts=%s\n' "$id" "$products"
}

set_remote_scope() {
  local id="${1:-}" nodes="${2:-*}" pools="${3:-*}" actions="${4:-*}"
  local file role subject products enabled created now node_scope pool_scope action_scope
  init_state
  valid_principal_id "$id" || { err "principal_id inválido"; return 64; }
  file="$(principal_file "$id")"
  [[ -f "$file" ]] || { err "Principal não existe: $id"; return 66; }
  [[ "$id" != "$LOCAL_ROOT_ID" ]] || { err "$LOCAL_ROOT_ID mantém escopo local irrestrito"; return 73; }
  node_scope="$(normalize_remote_scope "$nodes" node)" || { err "Escopo de nós inválido"; return 64; }
  pool_scope="$(normalize_remote_scope "$pools" pool)" || { err "Escopo de pools inválido"; return 64; }
  action_scope="$(normalize_remote_scope "$actions" action)" || { err "Escopo de ações inválido"; return 64; }
  role="$(read_field "$file" role)"
  subject="$(read_field "$file" subject)"
  products="$(read_field "$file" products)"
  enabled="$(read_field "$file" enabled)"
  created="$(read_field "$file" created_epoch)"
  [[ "$created" =~ ^[0-9]+$ ]] || created="$(date +%s)"
  validate_bound_subject "$role" "$subject" || return $?
  now="$(date +%s)"
  write_principal "$id" "$role" "$subject" "$products" "$node_scope" "$pool_scope" "$action_scope" "$enabled" "$created" "$now"
  printf 'principal_id=%s\nnode_scope=%s\npool_scope=%s\naction_scope=%s\n' "$id" "$node_scope" "$pool_scope" "$action_scope"
}

show_principal() {
  local id="${1:-}" file
  init_state
  valid_principal_id "$id" || return 64
  file="$(principal_file "$id")"
  [[ -f "$file" ]] || return 66
  cat "$file"
}

list_principals() {
  local file found=0
  init_state
  printf '%-28s %-14s %-24s %-24s %-8s\n' "PRINCIPAL" "ROLE" "SUBJECT" "PRODUCTS" "ENABLED"
  for file in "$PRINCIPALS_DIR"/*.conf; do
    [[ -f "$file" ]] || continue
    found=1
    printf '%-28s %-14s %-24s %-24s %-8s\n' \
      "$(read_field "$file" principal_id)" \
      "$(read_field "$file" role)" \
      "$(read_field "$file" subject)" \
      "$(read_field "$file" products)" \
      "$(read_field "$file" enabled)"
  done
  (( found == 1 )) || return 1
}

interactive_create() {
  header
  local id role subject products='*'
  read -r -p "Principal ID: " id
  read -r -p "Role (admin/reseller/subreseller/user): " role
  if [[ "$role" != admin ]]; then
    read -r -p "Subject (revendedor/subrevendedor/identidade): " subject
  fi
  if [[ "$role" == reseller || "$role" == subreseller ]]; then
    read -r -p "Produtos permitidos (* ou CSV) [*]: " products
    products="${products:-*}"
  fi
  if create_principal "$id" "$role" "$subject" "$products"; then ok "Principal criado"; fi
  pause
}

interactive_toggle() {
  header
  local id enabled
  read -r -p "Principal ID: " id
  read -r -p "Habilitar? (1=sim, 0=não): " enabled
  if set_enabled "$id" "$enabled"; then ok "Estado atualizado"; fi
  pause
}

interactive_products() {
  header
  local id products
  read -r -p "Principal ID: " id
  read -r -p "Produtos permitidos (* ou CSV): " products
  if set_products "$id" "$products"; then ok "Escopo de produtos atualizado"; fi
  pause
}

case "${1:-}" in
  --init) init_state; printf '%s\n' "$PRINCIPALS_DIR"; exit 0 ;;
  --list) list_principals; exit $? ;;
  --show) show_principal "${2:-}"; exit $? ;;
  --create) create_principal "${2:-}" "${3:-}" "${4:-}" "${5:-*}"; exit $? ;;
  --enable) set_enabled "${2:-}" 1; exit $? ;;
  --disable) set_enabled "${2:-}" 0; exit $? ;;
  --set-products) set_products "${2:-}" "${3:-}"; exit $? ;;
  --set-scope) set_remote_scope "${2:-}" "${3:-*}" "${4:-*}" "${5:-*}"; exit $? ;;
esac

init_state
while true; do
  header
  say "${C_WHITE}AUTOMATION V2 — PRINCIPALS / RBAC${C_RESET}\n"
  say " 1) Listar principals"
  say " 2) Mostrar principal"
  say " 3) Criar principal"
  say " 4) Habilitar/desabilitar"
  say " 5) Alterar escopo de produtos"
  say " 6) Alterar escopo remoto (nó/pool/ação)"
  say " 0) Voltar"
  say ""
  read -r -p "Opção: " opt
  case "$opt" in
    1) header; list_principals || true; pause ;;
    2) header; read -r -p "Principal ID: " id; show_principal "$id" || err "Principal não encontrado"; pause ;;
    3) interactive_create ;;
    4) interactive_toggle ;;
    5) interactive_products ;;
    6)
      header
      read -r -p "Principal ID: " id
      read -r -p "Nós permitidos (* ou CSV): " nodes
      read -r -p "Pools permitidos (* ou CSV): " pools
      read -r -p "Ações permitidas (* ou CSV): " actions
      if set_remote_scope "$id" "${nodes:-*}" "${pools:-*}" "${actions:-*}"; then ok "Escopo remoto atualizado"; fi
      pause
      ;;
    0) exit 0 ;;
    *) warn "Opção inválida"; sleep 1 ;;
  esac
done
