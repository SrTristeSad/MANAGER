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
IDENTITY_SLOTS_DIR="$STATE_DIR/identity-slots"
IDENTITY_DIR="$MANAGER_ETC/connection/identities"
LOCK_FILE="$STATE_DIR/.lock"

init_state() {
  mkdir -p "$RESELLERS_DIR" "$OWNERS_DIR" "$IDENTITY_SLOTS_DIR"
  chmod 0700 "$STATE_DIR" "$RESELLERS_DIR" "$OWNERS_DIR" "$IDENTITY_SLOTS_DIR"
  touch "$LOCK_FILE"
  chmod 0600 "$LOCK_FILE"
  [[ -d "$RESELLERS_DIR" && -d "$OWNERS_DIR" && -d "$IDENTITY_SLOTS_DIR" && -f "$LOCK_FILE" ]]
}

valid_id() {
  [[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,47}$ ]]
}

record_file() { printf '%s/%s.conf\n' "$RESELLERS_DIR" "$1"; }
owner_file() { printf '%s/%s\n' "$OWNERS_DIR" "$1"; }
identity_slot_file() { printf '%s/%s.conf\n' "$IDENTITY_SLOTS_DIR" "$1"; }
identity_file_path() { printf '%s/%s.conf\n' "$IDENTITY_DIR" "$1"; }

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

identity_owner() {
  read_field "$(identity_file_path "$1")" owner
}

identity_ssh_user() {
  read_field "$(identity_file_path "$1")" ssh_user
}

identity_slot_owner() {
  read_field "$(identity_slot_file "$1")" owner
}

identity_slot_active() {
  read_field "$(identity_slot_file "$1")" active
}

identity_counts_for_owner() {
  local identity_id="$1" reseller_id="$2" file slot
  file="$(identity_file_path "$identity_id")"
  [[ -f "$file" ]] || return 1
  [[ "$(read_field "$file" owner)" == "$reseller_id" ]] || return 1
  slot="$(identity_slot_file "$identity_id")"
  if [[ -f "$slot" ]]; then
    [[ "$(read_field "$slot" active)" == 1 && "$(read_field "$slot" owner)" == "$reseller_id" ]]
  else
    # Compatibilidade automática com identidades criadas antes da 0.6.7.
    return 0
  fi
}

legacy_user_covered_by_identity() {
  local user="$1" reseller_id="$2" slot file identity_id

  slot="$(identity_slot_file "$user")"
  if [[ -f "$slot" && "$(read_field "$slot" active)" == 1 && "$(read_field "$slot" owner)" == "$reseller_id" ]]; then
    return 0
  fi

  for file in "$IDENTITY_DIR"/*.conf; do
    [[ -f "$file" ]] || continue
    identity_id="${file##*/}"
    identity_id="${identity_id%.conf}"
    [[ "$(read_field "$file" ssh_user)" == "$user" ]] || continue
    identity_counts_for_owner "$identity_id" "$reseller_id" && return 0
  done
  return 1
}

direct_identity_usage() {
  local reseller_id="$1" file slot identity_id count=0
  init_state

  for file in "$IDENTITY_DIR"/*.conf; do
    [[ -f "$file" ]] || continue
    identity_id="${file##*/}"
    identity_id="${identity_id%.conf}"
    if identity_counts_for_owner "$identity_id" "$reseller_id"; then
      count=$((count + 1))
    fi
  done

  # Uma reserva existe antes do arquivo da identidade ser gravado. Ela já
  # precisa ocupar a vaga para impedir corrida de cota entre duas criações.
  for slot in "$IDENTITY_SLOTS_DIR"/*.conf; do
    [[ -f "$slot" ]] || continue
    [[ "$(read_field "$slot" active)" == 1 ]] || continue
    [[ "$(read_field "$slot" owner)" == "$reseller_id" ]] || continue
    identity_id="${slot##*/}"
    identity_id="${identity_id%.conf}"
    [[ -f "$(identity_file_path "$identity_id")" ]] && continue
    count=$((count + 1))
  done

  printf '%s\n' "$count"
}

direct_legacy_usage() {
  local reseller_id="$1" file owner count=0 user
  init_state
  for file in "$OWNERS_DIR"/*; do
    [[ -f "$file" ]] || continue
    user="${file##*/}"
    id "$user" >/dev/null 2>&1 || continue
    owner="$(read_field "$file" owner)"
    [[ "$owner" == "$reseller_id" ]] || continue
    legacy_user_covered_by_identity "$user" "$reseller_id" && continue
    count=$((count + 1))
  done
  printf '%s\n' "$count"
}

direct_usage() {
  local reseller_id="$1" identities legacy
  identities="$(direct_identity_usage "$reseller_id")"
  legacy="$(direct_legacy_usage "$reseller_id")"
  printf '%s\n' "$((identities + legacy))"
}

children_of() {
  local reseller_id="$1" file child parent
  for file in "$RESELLERS_DIR"/*.conf; do
    [[ -f "$file" ]] || continue
    child="${file##*/}"
    child="${child%.conf}"
    parent="$(read_field "$file" parent)"
    if [[ "$parent" == "$reseller_id" ]]; then
      printf '%s\n' "$child"
    fi
  done
}

subtree_usage() {
  local reseller_id="$1" total child child_usage
  total="$(direct_usage "$reseller_id")"
  while IFS= read -r child; do
    [[ -n "$child" ]] || continue
    child_usage="$(direct_usage "$child")"
    total=$((total + child_usage))
  done < <(children_of "$reseller_id")
  printf '%s\n' "$total"
}

usage_for() {
  local reseller_id="$1" role
  role="$(role_of "$reseller_id")"
  if [[ "$role" == reseller ]]; then
    subtree_usage "$reseller_id"
  else
    direct_usage "$reseller_id"
  fi
}

candidate_increment() {
  local reseller_id="$1" identity_id="${2:-}" file
  [[ -n "$identity_id" ]] || { printf '1\n'; return; }

  file="$(identity_slot_file "$identity_id")"
  if [[ -f "$file" && "$(read_field "$file" active)" == 1 && "$(read_field "$file" owner)" == "$reseller_id" ]]; then
    printf '0\n'
    return
  fi

  file="$(identity_file_path "$identity_id")"
  if [[ -f "$file" && "$(read_field "$file" owner)" == "$reseller_id" && ! -f "$(identity_slot_file "$identity_id")" ]]; then
    printf '0\n'
    return
  fi

  file="$(owner_file "$identity_id")"
  if [[ -f "$file" ]] && id "$identity_id" >/dev/null 2>&1 && [[ "$(read_field "$file" owner)" == "$reseller_id" ]]; then
    # Converter uma conta SSH antiga de mesmo nome em identidade não deve
    # consumir uma segunda vaga.
    printf '0\n'
    return
  fi

  printf '1\n'
}

quota_allows_one_more() {
  local reseller_id="$1" identity_id="${2:-}" quota used parent pquota pused increment
  reseller_exists "$reseller_id" || return 1
  [[ "$(enabled_of "$reseller_id")" == 1 ]] || return 1
  quota="$(quota_of "$reseller_id")"
  [[ "$quota" =~ ^[0-9]+$ ]] || return 1
  used="$(usage_for "$reseller_id")"
  increment="$(candidate_increment "$reseller_id" "$identity_id")"
  if (( quota > 0 && used + increment > quota )); then return 1; fi

  parent="$(parent_of "$reseller_id")"
  if [[ -n "$parent" ]]; then
    reseller_exists "$parent" || return 1
    [[ "$(enabled_of "$parent")" == 1 ]] || return 1
    pquota="$(quota_of "$parent")"
    [[ "$pquota" =~ ^[0-9]+$ ]] || return 1
    pused="$(subtree_usage "$parent")"
    if (( pquota > 0 && pused + increment > pquota )); then return 1; fi
  fi
  return 0
}

write_reseller() {
  local reseller_id="$1" role="$2" parent="$3" quota="$4" enabled="$5" created="$6" tmp
  tmp="$(mktemp)"
  {
    printf 'role=%s\n' "$role"
    printf 'parent=%s\n' "$parent"
    printf 'quota=%s\n' "$quota"
    printf 'enabled=%s\n' "$enabled"
    printf 'created_epoch=%s\n' "$created"
  } > "$tmp"
  install -m 0600 "$tmp" "$(record_file "$reseller_id")"
  rm -f "$tmp"
}

write_identity_slot() {
  local identity_id="$1" owner="$2" active="$3" assigned="$4" released="$5" tmp
  tmp="$(mktemp)"
  {
    printf 'version=1\n'
    printf 'identity_id=%s\n' "$identity_id"
    printf 'owner=%s\n' "$owner"
    printf 'active=%s\n' "$active"
    printf 'assigned_epoch=%s\n' "$assigned"
    printf 'released_epoch=%s\n' "$released"
  } > "$tmp"
  install -m 0600 "$tmp" "$(identity_slot_file "$identity_id")"
  rm -f "$tmp"
}

create_reseller_impl() {
  local reseller_id="$1" role="$2" parent="$3" quota="$4" enabled="${5:-1}" created
  valid_id "$reseller_id" || { err "ID inválido"; return 64; }
  reseller_exists "$reseller_id" && { err "ID já existe"; return 65; }
  case "$role" in reseller|subreseller) ;; *) err "Tipo inválido"; return 64 ;; esac
  [[ "$quota" =~ ^[0-9]+$ ]] || { err "Cota inválida"; return 64; }
  (( quota <= 1000000 )) || { err "Cota muito alta"; return 64; }
  [[ "$enabled" == 0 || "$enabled" == 1 ]] || { err "enabled inválido"; return 64; }
  if [[ "$role" == subreseller ]]; then
    valid_id "$parent" || { err "Revendedor pai inválido"; return 64; }
    reseller_exists "$parent" || { err "Revendedor pai não existe"; return 66; }
    [[ "$(role_of "$parent")" == reseller ]] || { err "Subrevendedor só pode ter revendedor como pai"; return 67; }
  else
    parent=""
  fi
  created="$(date +%s)"
  write_reseller "$reseller_id" "$role" "$parent" "$quota" "$enabled" "$created"
}

reserve_identity_impl() {
  local identity_id="$1" owner="$2" slot existing_owner active assigned now
  valid_id "$identity_id" || { err "ID de identidade inválido"; return 64; }
  valid_id "$owner" || { err "Proprietário inválido"; return 64; }
  reseller_exists "$owner" || { err "Revendedor não existe: $owner"; return 66; }
  [[ "$(enabled_of "$owner")" == 1 ]] || { err "Revendedor bloqueado: $owner"; return 73; }

  slot="$(identity_slot_file "$identity_id")"
  if [[ -f "$slot" ]]; then
    existing_owner="$(read_field "$slot" owner)"
    active="$(read_field "$slot" active)"
    if [[ "$active" == 1 ]]; then
      [[ "$existing_owner" == "$owner" ]] && return 0
      err "Identidade já ocupa cota de outro proprietário: $existing_owner"
      return 73
    fi
    [[ -z "$existing_owner" || "$existing_owner" == "$owner" ]] || {
      err "Identidade liberada pertence historicamente a outro proprietário: $existing_owner"
      return 73
    }
  fi

  quota_allows_one_more "$owner" "$identity_id" || {
    err "Cota/estado não permite nova identidade para $owner"
    return 73
  }

  now="$(date +%s)"
  assigned="$now"
  if [[ -f "$slot" ]]; then
    assigned="$(read_field "$slot" assigned_epoch)"
    [[ "$assigned" =~ ^[0-9]+$ ]] || assigned="$now"
  fi
  write_identity_slot "$identity_id" "$owner" 1 "$assigned" 0
}

release_identity_impl() {
  local identity_id="$1" slot owner assigned now
  valid_id "$identity_id" || return 64
  slot="$(identity_slot_file "$identity_id")"
  if [[ -f "$slot" ]]; then
    owner="$(read_field "$slot" owner)"
    assigned="$(read_field "$slot" assigned_epoch)"
  else
    owner="$(identity_owner "$identity_id")"
    [[ -n "$owner" ]] || return 0
    assigned="$(read_field "$(identity_file_path "$identity_id")" created_epoch)"
  fi
  [[ "$assigned" =~ ^[0-9]+$ ]] || assigned="$(date +%s)"
  now="$(date +%s)"
  write_identity_slot "$identity_id" "$owner" 0 "$assigned" "$now"
}

identity_slot_is_active_for() {
  local identity_id="$1" owner="$2" slot
  slot="$(identity_slot_file "$identity_id")"
  if [[ -f "$slot" ]]; then
    [[ "$(read_field "$slot" active)" == 1 && "$(read_field "$slot" owner)" == "$owner" ]]
    return
  fi
  [[ -f "$(identity_file_path "$identity_id")" && "$(identity_owner "$identity_id")" == "$owner" ]]
}

identity_covers_ssh_user() {
  local user="$1" owner="$2" file identity_id
  if identity_slot_is_active_for "$user" "$owner"; then return 0; fi
  for file in "$IDENTITY_DIR"/*.conf; do
    [[ -f "$file" ]] || continue
    [[ "$(read_field "$file" owner)" == "$owner" ]] || continue
    [[ "$(read_field "$file" ssh_user)" == "$user" ]] || continue
    identity_id="${file##*/}"
    identity_id="${identity_id%.conf}"
    identity_slot_is_active_for "$identity_id" "$owner" && return 0
  done
  return 1
}

assign_owner_record() {
  local user="$1" owner="$2" tmp
  tmp="$(mktemp)"
  {
    printf 'owner=%s\n' "$owner"
    printf 'assigned_epoch=%s\n' "$(date +%s)"
  } > "$tmp"
  install -m 0600 "$tmp" "$(owner_file "$user")"
  rm -f "$tmp"
}

assign_owner_impl() {
  local user="$1" owner="$2" old
  id "$user" >/dev/null 2>&1 || { err "Usuário Linux não existe: $user"; return 1; }
  [[ "$user" != root ]] || { err "root não pode pertencer a revendedor"; return 1; }
  reseller_exists "$owner" || { err "Revendedor não existe: $owner"; return 1; }
  old="$(owner_of_user "$user")"
  [[ "$old" == "$owner" ]] && return 0
  if ! identity_covers_ssh_user "$user" "$owner"; then
    quota_allows_one_more "$owner" || { err "Cota/estado não permite nova conta para $owner"; return 1; }
  fi
  assign_owner_record "$user" "$owner"
}

assign_owner_for_identity_impl() {
  local user="$1" owner="$2" identity_id="$3"
  id "$user" >/dev/null 2>&1 || { err "Usuário Linux não existe: $user"; return 1; }
  [[ "$user" != root ]] || { err "root não pode pertencer a revendedor"; return 1; }
  reserve_identity_impl "$identity_id" "$owner" || return $?
  identity_slot_is_active_for "$identity_id" "$owner" || return 73
  assign_owner_record "$user" "$owner"
}

list_resellers() {
  header
  say "${C_WHITE}REVENDEDORES E SUBREVENDEDORES${C_RESET}\n"
  init_state
  printf '%-20s %-14s %-20s %-8s %-8s %-10s\n' "ID" "PAPEL" "PAI" "USO" "COTA" "ESTADO"
  printf '%-20s %-14s %-20s %-8s %-8s %-10s\n' "--------------------" "--------------" "--------------------" "--------" "--------" "----------"
  local file reseller_id role parent quota enabled used found=0
  for file in "$RESELLERS_DIR"/*.conf; do
    [[ -f "$file" ]] || continue
    found=1
    reseller_id="${file##*/}"; reseller_id="${reseller_id%.conf}"
    role="$(read_field "$file" role)"
    parent="$(read_field "$file" parent)"; [[ -n "$parent" ]] || parent="-"
    quota="$(read_field "$file" quota)"; [[ "$quota" != 0 ]] || quota="∞"
    enabled="$(read_field "$file" enabled)"
    if [[ "$enabled" == 1 ]]; then enabled="ativo"; else enabled="bloqueado"; fi
    used="$(usage_for "$reseller_id")"
    printf '%-20s %-14s %-20s %-8s %-8s %-10s\n' "$reseller_id" "$role" "$parent" "$used" "$quota" "$enabled"
  done
  (( found == 1 )) || info "Nenhum revendedor cadastrado"
  say "\nUso = identidades lógicas ativas na cota + contas SSH legadas ainda não absorvidas por identidade."
  pause
}

create_reseller() {
  header
  say "${C_WHITE}CRIAR REVENDEDOR${C_RESET}\n"
  init_state
  local reseller_id role parent="" quota
  read -r -p "ID: " reseller_id
  read -r -p "Tipo [revendedor/subrevendedor]: " role
  case "${role,,}" in
    revendedor|reseller) role="reseller" ;;
    subrevendedor|subreseller) role="subreseller" ;;
    *) err "Tipo inválido"; pause; return ;;
  esac
  if [[ "$role" == subreseller ]]; then
    read -r -p "Revendedor pai: " parent
  fi
  read -r -p "Cota de clientes/identidades (0 = ilimitada): " quota
  if ( flock -x 9; create_reseller_impl "$reseller_id" "$role" "$parent" "$quota" 1 ) 9>"$LOCK_FILE"; then
    ok "$reseller_id criado"
  fi
  pause
}

change_quota() {
  header
  local reseller_id quota used role current parent pquota
  read -r -p "ID: " reseller_id
  reseller_exists "$reseller_id" || { err "ID não existe"; pause; return; }
  used="$(usage_for "$reseller_id")"; current="$(quota_of "$reseller_id")"
  read -r -p "Nova cota de clientes (0 = ilimitada) [atual $current / uso $used]: " quota
  [[ "$quota" =~ ^[0-9]+$ ]] || { err "Cota inválida"; pause; return; }
  if (( quota > 0 && quota < used )); then err "A nova cota não pode ficar abaixo do uso atual ($used)"; pause; return; fi
  role="$(role_of "$reseller_id")"; parent="$(parent_of "$reseller_id")"
  if [[ "$role" == subreseller && -n "$parent" ]]; then
    pquota="$(quota_of "$parent")"
    if [[ "$pquota" =~ ^[0-9]+$ ]] && (( pquota > 0 && quota > pquota )); then warn "A cota do subrevendedor é maior que a do pai; o limite total do pai continuará valendo."; fi
  fi
  ( flock -x 9; write_reseller "$reseller_id" "$role" "$parent" "$quota" "$(enabled_of "$reseller_id")" "$(read_field "$(record_file "$reseller_id")" created_epoch)" ) 9>"$LOCK_FILE"
  ok "Cota atualizada"
  pause
}

toggle_reseller() {
  header
  local reseller_id role parent quota enabled created
  read -r -p "ID: " reseller_id
  reseller_exists "$reseller_id" || { err "ID não existe"; pause; return; }
  role="$(role_of "$reseller_id")"; parent="$(parent_of "$reseller_id")"; quota="$(quota_of "$reseller_id")"
  enabled="$(enabled_of "$reseller_id")"; created="$(read_field "$(record_file "$reseller_id")" created_epoch)"
  if [[ "$enabled" == 1 ]]; then enabled=0; else enabled=1; fi
  ( flock -x 9; write_reseller "$reseller_id" "$role" "$parent" "$quota" "$enabled" "$created" ) 9>"$LOCK_FILE"
  if [[ "$enabled" == 1 ]]; then ok "$reseller_id ativado"; else ok "$reseller_id bloqueado"; fi
  pause
}

assign_owner() {
  header
  local user owner
  read -r -p "Usuário SSH legado: " user; read -r -p "Revendedor/subrevendedor: " owner
  if ( flock -x 9; assign_owner_impl "$user" "$owner" ) 9>"$LOCK_FILE"; then ok "$user agora pertence a $owner"; fi
  pause
}

unassign_owner() {
  header
  local user file
  read -r -p "Usuário SSH legado: " user; file="$(owner_file "$user")"
  if [[ -f "$file" ]]; then rm -f "$file"; ok "Propriedade SSH legada removida"; else info "$user não possui proprietário registrado"; fi
  pause
}

list_owners() {
  header
  say "${C_WHITE}CLIENTES LÓGICOS / PROPRIEDADE${C_RESET}\n"
  init_state
  printf '%-24s %-24s %-10s\n' "IDENTIDADE" "PROPRIETÁRIO" "COTA"
  printf '%-24s %-24s %-10s\n' "------------------------" "------------------------" "----------"
  local file identity_id owner active found=0
  for file in "$IDENTITY_DIR"/*.conf; do
    [[ -f "$file" ]] || continue
    owner="$(read_field "$file" owner)"
    [[ -n "$owner" ]] || continue
    found=1
    identity_id="${file##*/}"; identity_id="${identity_id%.conf}"
    if identity_counts_for_owner "$identity_id" "$owner"; then active="ocupa"; else active="liberada"; fi
    printf '%-24s %-24s %-10s\n' "$identity_id" "$owner" "$active"
  done
  (( found == 1 )) || info "Nenhuma identidade de revenda registrada"

  say "\n${C_WHITE}CONTAS SSH LEGADAS${C_RESET}"
  printf '%-24s %-24s %-12s\n' "USUÁRIO" "PROPRIETÁRIO" "CONTAGEM"
  printf '%-24s %-24s %-12s\n' "------------------------" "------------------------" "------------"
  found=0
  for file in "$OWNERS_DIR"/*; do
    [[ -f "$file" ]] || continue
    found=1
    identity_id="${file##*/}"; owner="$(read_field "$file" owner)"
    if legacy_user_covered_by_identity "$identity_id" "$owner"; then active="deduplicada"; else active="legada"; fi
    printf '%-24s %-24s %-12s\n' "$identity_id" "$owner" "$active"
  done
  (( found == 1 )) || info "Nenhuma conta SSH legada possui proprietário"
  pause
}

reconcile_owners_impl() {
  local file user removed=0 identity_id owner created migrated=0
  for file in "$OWNERS_DIR"/*; do
    [[ -f "$file" ]] || continue
    user="${file##*/}"
    if ! id "$user" >/dev/null 2>&1; then rm -f "$file"; removed=$((removed + 1)); fi
  done

  for file in "$IDENTITY_DIR"/*.conf; do
    [[ -f "$file" ]] || continue
    identity_id="${file##*/}"; identity_id="${identity_id%.conf}"
    owner="$(read_field "$file" owner)"
    [[ -n "$owner" && -f "$(record_file "$owner")" ]] || continue
    [[ ! -f "$(identity_slot_file "$identity_id")" ]] || continue
    created="$(read_field "$file" created_epoch)"
    [[ "$created" =~ ^[0-9]+$ ]] || created="$(date +%s)"
    write_identity_slot "$identity_id" "$owner" 1 "$created" 0
    migrated=$((migrated + 1))
  done
  printf '%s\t%s\n' "$removed" "$migrated"
}

reconcile_owners() {
  header
  init_state
  local result removed migrated
  result="$(flock -x "$LOCK_FILE" "$0" --reconcile-unlocked)"
  IFS=$'\t' read -r removed migrated <<< "$result"
  ok "$removed registro(s) SSH órfão(s) removido(s); $migrated identidade(s) migrada(s) para slots explícitos"
  pause
}

machine_usage() { local reseller_id="${1:-}"; valid_id "$reseller_id" || exit 64; reseller_exists "$reseller_id" || exit 66; usage_for "$reseller_id"; }
machine_usage_detail() {
  local reseller_id="${1:-}" identities legacy total quota remaining
  valid_id "$reseller_id" || exit 64
  reseller_exists "$reseller_id" || exit 66
  identities="$(direct_identity_usage "$reseller_id")"
  legacy="$(direct_legacy_usage "$reseller_id")"
  total="$(usage_for "$reseller_id")"
  quota="$(quota_of "$reseller_id")"
  if [[ "$quota" == 0 ]]; then remaining="unlimited"; else remaining="$((quota - total))"; (( remaining >= 0 )) || remaining=0; fi
  printf 'id=%s\nrole=%s\ndirect_identities=%s\ndirect_legacy_ssh=%s\ntotal_usage=%s\nquota=%s\nremaining=%s\n' \
    "$reseller_id" "$(role_of "$reseller_id")" "$identities" "$legacy" "$total" "$quota" "$remaining"
}
machine_can_create() { local reseller_id="${1:-}" identity_id="${2:-}"; valid_id "$reseller_id" || exit 64; quota_allows_one_more "$reseller_id" "$identity_id"; }
machine_assign() {
  local user="${1:-}" owner="${2:-}"
  is_valid_username "$user" || exit 64; valid_id "$owner" || exit 64; init_state
  ( flock -x 9; assign_owner_impl "$user" "$owner" ) 9>"$LOCK_FILE"
}
machine_assign_for_identity() {
  local user="${1:-}" owner="${2:-}" identity_id="${3:-}"
  is_valid_username "$user" || exit 64; valid_id "$owner" || exit 64; valid_id "$identity_id" || exit 64; init_state
  ( flock -x 9; assign_owner_for_identity_impl "$user" "$owner" "$identity_id" ) 9>"$LOCK_FILE"
}
machine_reserve_identity() {
  local identity_id="${1:-}" owner="${2:-}"
  valid_id "$identity_id" || exit 64; valid_id "$owner" || exit 64; init_state
  ( flock -x 9; reserve_identity_impl "$identity_id" "$owner" ) 9>"$LOCK_FILE"
}
machine_release_identity() {
  local identity_id="${1:-}"
  valid_id "$identity_id" || exit 64; init_state
  ( flock -x 9; release_identity_impl "$identity_id" ) 9>"$LOCK_FILE"
}
machine_create_reseller() {
  local reseller_id="${1:-}" role="${2:-}" parent="${3:-}" quota="${4:-}" enabled="${5:-1}"
  init_state
  ( flock -x 9; create_reseller_impl "$reseller_id" "$role" "$parent" "$quota" "$enabled" ) 9>"$LOCK_FILE"
}
machine_reconcile() {
  init_state
  ( flock -x 9; reconcile_owners_impl ) 9>"$LOCK_FILE"
}
machine_init() {
  init_state
  printf '%s\n' "$STATE_DIR"
}

case "${1:-}" in
  --init) machine_init; exit 0 ;;
  --usage) init_state; machine_usage "${2:-}"; exit $? ;;
  --usage-detail) init_state; machine_usage_detail "${2:-}"; exit $? ;;
  --can-create) init_state; machine_can_create "${2:-}" "${3:-}"; exit $? ;;
  --assign) init_state; machine_assign "${2:-}" "${3:-}"; exit $? ;;
  --assign-for-identity) machine_assign_for_identity "${2:-}" "${3:-}" "${4:-}"; exit $? ;;
  --reserve-identity) machine_reserve_identity "${2:-}" "${3:-}"; exit $? ;;
  --release-identity) machine_release_identity "${2:-}"; exit $? ;;
  --identity-slot-owner) init_state; identity_slot_owner "${2:-}"; exit 0 ;;
  --identity-slot-active) init_state; identity_slot_active "${2:-}"; exit 0 ;;
  --create-reseller) machine_create_reseller "${2:-}" "${3:-}" "${4:-}" "${5:-}" "${6:-1}"; exit $? ;;
  --reconcile) machine_reconcile; exit $? ;;
  --reconcile-unlocked) reconcile_owners_impl; exit $? ;;
  --owner) init_state; owner_of_user "${2:-}"; exit 0 ;;
esac

init_state
while true; do
  header
  say "${C_WHITE}REVENDEDORES, COTAS E PROPRIEDADE${C_RESET}\n"
  say " 1) Listar revendedores"
  say " 2) Criar revendedor/subrevendedor"
  say " 3) Alterar cota"
  say " 4) Ativar/bloquear revendedor"
  say " 5) Atribuir usuário SSH legado"
  say " 6) Remover propriedade SSH legada"
  say " 7) Listar clientes/identidades"
  say " 8) Reconciliar legado e slots de identidade"
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
