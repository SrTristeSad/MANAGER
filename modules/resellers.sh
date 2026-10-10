#!/usr/bin/env bash
set -Eeuo pipefail

MANAGER_HOME="${MANAGER_HOME:-/opt/manager}"
MANAGER_ETC="${MANAGER_ETC:-/etc/manager}"
# shellcheck source=/dev/null
source "$MANAGER_HOME/lib/common.sh"
require_root

STATE_DIR="$MANAGER_ETC/access"
RESELLERS_DIR="$STATE_DIR/resellers"
OWNERS_DIR="$STATE_DIR/owners"
LOCK_FILE="$STATE_DIR/.lock"

init_state() {
  mkdir -p "$RESELLERS_DIR" "$OWNERS_DIR"
  chmod 0700 "$STATE_DIR" "$RESELLERS_DIR" "$OWNERS_DIR"
  touch "$LOCK_FILE"
  chmod 0600 "$LOCK_FILE"
}

valid_id() {
  [[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,47}$ ]]
}

record_file() { printf '%s/%s.conf\n' "$RESELLERS_DIR" "$1"; }
owner_file() { printf '%s/%s\n' "$OWNERS_DIR" "$1"; }

read_field() {
  local file="$1" key="$2"
  awk -F= -v k="$key" '$1==k {sub(/^[^=]*=/,""); print; exit}' "$file" 2>/dev/null || true
}

reseller_exists() { [[ -f "$(record_file "$1")" ]]; }
role_of() { read_field "$(record_file "$1")" role; }
parent_of() { read_field "$(record_file "$1")" parent; }
quota_of() { read_field "$(record_file "$1")" quota; }
enabled_of() { read_field "$(record_file "$1")" enabled; }

owner_of_user() {
  local file
  file="$(owner_file "$1")"
  [[ -f "$file" ]] || return 0
  read_field "$file" owner
}

direct_usage() {
  local id="$1" file owner count=0 user
  init_state
  for file in "$OWNERS_DIR"/*; do
    [[ -f "$file" ]] || continue
    user="${file##*/}"
    id "$user" >/dev/null 2>&1 || continue
    owner="$(read_field "$file" owner)"
    [[ "$owner" == "$id" ]] && count=$((count + 1))
  done
  printf '%s\n' "$count"
}

children_of() {
  local id="$1" file child parent
  for file in "$RESELLERS_DIR"/*.conf; do
    [[ -f "$file" ]] || continue
    child="${file##*/}"
    child="${child%.conf}"
    parent="$(read_field "$file" parent)"
    [[ "$parent" == "$id" ]] && printf '%s\n' "$child"
  done
}

subtree_usage() {
  local id="$1" total child
  total="$(direct_usage "$id")"
  while IFS= read -r child; do
    [[ -n "$child" ]] || continue
    total=$((total + $(direct_usage "$child")))
  done < <(children_of "$id")
  printf '%s\n' "$total"
}

usage_for() {
  local id="$1" role
  role="$(role_of "$id")"
  if [[ "$role" == reseller ]]; then
    subtree_usage "$id"
  else
    direct_usage "$id"
  fi
}

quota_allows_one_more() {
  local id="$1" quota used parent pquota pused
  reseller_exists "$id" || return 1
  [[ "$(enabled_of "$id")" == 1 ]] || return 1

  quota="$(quota_of "$id")"
  [[ "$quota" =~ ^[0-9]+$ ]] || return 1
  used="$(usage_for "$id")"
  if (( quota > 0 && used >= quota )); then
    return 1
  fi

  parent="$(parent_of "$id")"
  if [[ -n "$parent" ]]; then
    reseller_exists "$parent" || return 1
    [[ "$(enabled_of "$parent")" == 1 ]] || return 1
    pquota="$(quota_of "$parent")"
    [[ "$pquota" =~ ^[0-9]+$ ]] || return 1
    pused="$(subtree_usage "$parent")"
    if (( pquota > 0 && pused >= pquota )); then
      return 1
    fi
  fi
  return 0
}

write_reseller() {
  local id="$1" role="$2" parent="$3" quota="$4" enabled="$5" created="$6" tmp
  tmp="$(mktemp)"
  {
    printf 'role=%s\n' "$role"
    printf 'parent=%s\n' "$parent"
    printf 'quota=%s\n' "$quota"
    printf 'enabled=%s\n' "$enabled"
    printf 'created_epoch=%s\n' "$created"
  } > "$tmp"
  install -m 0600 "$tmp" "$(record_file "$id")"
  rm -f "$tmp"
}

list_resellers() {
  header
  say "${C_WHITE}REVENDEDORES E SUBREVENDEDORES${C_RESET}\n"
  init_state
  printf '%-20s %-14s %-20s %-8s %-8s %-10s\n' "ID" "PAPEL" "PAI" "USO" "COTA" "ESTADO"
  printf '%-20s %-14s %-20s %-8s %-8s %-10s\n' "--------------------" "--------------" "--------------------" "--------" "--------" "----------"
  local file id role parent quota enabled used found=0
  for file in "$RESELLERS_DIR"/*.conf; do
    [[ -f "$file" ]] || continue
    found=1
    id="${file##*/}"; id="${id%.conf}"
    role="$(read_field "$file" role)"
    parent="$(read_field "$file" parent)"; [[ -n "$parent" ]] || parent="-"
    quota="$(read_field "$file" quota)"; [[ "$quota" != 0 ]] || quota="∞"
    enabled="$(read_field "$file" enabled)"; [[ "$enabled" == 1 ]] && enabled="ativo" || enabled="bloqueado"
    used="$(usage_for "$id")"
    printf '%-20s %-14s %-20s %-8s %-8s %-10s\n' "$id" "$role" "$parent" "$used" "$quota" "$enabled"
  done
  (( found == 1 )) || info "Nenhum revendedor cadastrado"
  pause
}

create_reseller() {
  header
  say "${C_WHITE}CRIAR REVENDEDOR${C_RESET}\n"
  init_state
  local id role parent="" quota created
  read -r -p "ID: " id
  valid_id "$id" || { err "ID inválido"; pause; return; }
  reseller_exists "$id" && { err "ID já existe"; pause; return; }
  read -r -p "Tipo [revendedor/subrevendedor]: " role
  case "${role,,}" in
    revendedor|reseller) role="reseller" ;;
    subrevendedor|subreseller) role="subreseller" ;;
    *) err "Tipo inválido"; pause; return ;;
  esac

  if [[ "$role" == subreseller ]]; then
    read -r -p "Revendedor pai: " parent
    reseller_exists "$parent" || { err "Revendedor pai não existe"; pause; return; }
    [[ "$(role_of "$parent")" == reseller ]] || { err "Subrevendedor só pode ter revendedor como pai"; pause; return; }
  fi

  read -r -p "Cota de contas (0 = ilimitada): " quota
  [[ "$quota" =~ ^[0-9]+$ ]] || { err "Cota inválida"; pause; return; }
  (( quota <= 1000000 )) || { err "Cota muito alta"; pause; return; }
  created="$(date +%s)"

  (
    flock -x 9
    write_reseller "$id" "$role" "$parent" "$quota" 1 "$created"
  ) 9>"$LOCK_FILE"
  ok "$id criado"
  pause
}

change_quota() {
  header
  local id quota used role current parent pquota
  read -r -p "ID: " id
  reseller_exists "$id" || { err "ID não existe"; pause; return; }
  used="$(usage_for "$id")"
  current="$(quota_of "$id")"
  read -r -p "Nova cota (0 = ilimitada) [atual $current / uso $used]: " quota
  [[ "$quota" =~ ^[0-9]+$ ]] || { err "Cota inválida"; pause; return; }
  if (( quota > 0 && quota < used )); then
    err "A nova cota não pode ficar abaixo do uso atual ($used)"
    pause
    return
  fi
  role="$(role_of "$id")"
  parent="$(parent_of "$id")"
  if [[ "$role" == subreseller && -n "$parent" ]]; then
    pquota="$(quota_of "$parent")"
    if [[ "$pquota" =~ ^[0-9]+$ ]] && (( pquota > 0 && quota > pquota )); then
      warn "A cota do subrevendedor é maior que a do pai; o limite total do pai continuará valendo."
    fi
  fi
  (
    flock -x 9
    write_reseller "$id" "$role" "$parent" "$quota" "$(enabled_of "$id")" "$(read_field "$(record_file "$id")" created_epoch)"
  ) 9>"$LOCK_FILE"
  ok "Cota atualizada"
  pause
}

toggle_reseller() {
  header
  local id role parent quota enabled created
  read -r -p "ID: " id
  reseller_exists "$id" || { err "ID não existe"; pause; return; }
  role="$(role_of "$id")"; parent="$(parent_of "$id")"; quota="$(quota_of "$id")"
  enabled="$(enabled_of "$id")"; created="$(read_field "$(record_file "$id")" created_epoch)"
  if [[ "$enabled" == 1 ]]; then enabled=0; else enabled=1; fi
  (
    flock -x 9
    write_reseller "$id" "$role" "$parent" "$quota" "$enabled" "$created"
  ) 9>"$LOCK_FILE"
  [[ "$enabled" == 1 ]] && ok "$id ativado" || ok "$id bloqueado"
  pause
}

assign_owner_impl() {
  local user="$1" owner="$2" old tmp
  id "$user" >/dev/null 2>&1 || { err "Usuário Linux não existe: $user"; return 1; }
  [[ "$user" != root ]] || { err "root não pode pertencer a revendedor"; return 1; }
  reseller_exists "$owner" || { err "Revendedor não existe: $owner"; return 1; }
  old="$(owner_of_user "$user")"
  [[ "$old" == "$owner" ]] && return 0
  quota_allows_one_more "$owner" || { err "Cota/estado não permite nova conta para $owner"; return 1; }
  tmp="$(mktemp)"
  {
    printf 'owner=%s\n' "$owner"
    printf 'assigned_epoch=%s\n' "$(date +%s)"
  } > "$tmp"
  install -m 0600 "$tmp" "$(owner_file "$user")"
  rm -f "$tmp"
}

assign_owner() {
  header
  local user owner
  read -r -p "Usuário SSH: " user
  read -r -p "Revendedor/subrevendedor: " owner
  if (
    flock -x 9
    assign_owner_impl "$user" "$owner"
  ) 9>"$LOCK_FILE"; then
    ok "$user agora pertence a $owner"
  fi
  pause
}

unassign_owner() {
  header
  local user file
  read -r -p "Usuário SSH: " user
  file="$(owner_file "$user")"
  if [[ -f "$file" ]]; then
    rm -f "$file"
    ok "Propriedade removida"
  else
    info "$user não possui proprietário registrado"
  fi
  pause
}

list_owners() {
  header
  say "${C_WHITE}PROPRIEDADE DAS CONTAS${C_RESET}\n"
  init_state
  printf '%-24s %-24s %-10s\n' "USUÁRIO" "PROPRIETÁRIO" "EXISTE"
  printf '%-24s %-24s %-10s\n' "------------------------" "------------------------" "----------"
  local file user owner exists found=0
  for file in "$OWNERS_DIR"/*; do
    [[ -f "$file" ]] || continue
    found=1
    user="${file##*/}"
    owner="$(read_field "$file" owner)"
    if id "$user" >/dev/null 2>&1; then exists="sim"; else exists="não"; fi
    printf '%-24s %-24s %-10s\n' "$user" "$owner" "$exists"
  done
  (( found == 1 )) || info "Nenhuma conta possui proprietário registrado"
  pause
}

reconcile_owners() {
  header
  init_state
  local file user removed=0
  for file in "$OWNERS_DIR"/*; do
    [[ -f "$file" ]] || continue
    user="${file##*/}"
    if ! id "$user" >/dev/null 2>&1; then
      rm -f "$file"
      removed=$((removed + 1))
    fi
  done
  ok "$removed registro(s) órfão(s) removido(s)"
  pause
}

machine_usage() {
  local id="${1:-}"
  valid_id "$id" || exit 64
  reseller_exists "$id" || exit 66
  usage_for "$id"
}

machine_can_create() {
  local id="${1:-}"
  valid_id "$id" || exit 64
  quota_allows_one_more "$id"
}

machine_assign() {
  local user="${1:-}" owner="${2:-}"
  is_valid_username "$user" || exit 64
  valid_id "$owner" || exit 64
  init_state
  (
    flock -x 9
    assign_owner_impl "$user" "$owner"
  ) 9>"$LOCK_FILE"
}

init_state
case "${1:-}" in
  --usage) machine_usage "${2:-}"; exit $? ;;
  --can-create) machine_can_create "${2:-}"; exit $? ;;
  --assign) machine_assign "${2:-}" "${3:-}"; exit $? ;;
  --owner) owner_of_user "${2:-}"; exit 0 ;;
esac

while true; do
  header
  say "${C_WHITE}REVENDEDORES, COTAS E PROPRIEDADE${C_RESET}\n"
  say " 1) Listar revendedores"
  say " 2) Criar revendedor/subrevendedor"
  say " 3) Alterar cota"
  say " 4) Ativar/bloquear revendedor"
  say " 5) Atribuir usuário SSH"
  say " 6) Remover propriedade"
  say " 7) Listar propriedade das contas"
  say " 8) Limpar registros órfãos"
  say " 0) Voltar"
  say ""
  read -r -p "Opção: " opt
  case "$opt" in
    1) list_resellers ;;
    2) create_reseller ;;
    3) change_quota ;;
    4) toggle_reseller ;;
    5) assign_owner ;;
    6) unassign_owner ;;
    7) list_owners ;;
    8) reconcile_owners ;;
    0) exit 0 ;;
    *) warn "Opção inválida"; sleep 1 ;;
  esac
done
