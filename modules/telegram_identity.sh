#!/usr/bin/env bash
set -Eeuo pipefail

MANAGER_HOME="${MANAGER_HOME:-/opt/manager}"
MANAGER_ETC="${MANAGER_ETC:-/etc/manager}"
# shellcheck source=/dev/null
source "$MANAGER_HOME/lib/common.sh"
require_root

STATE_DIR="${MANAGER_TELEGRAM_STATE_DIR:-$MANAGER_ETC/telegram}"
BINDINGS_DIR="$STATE_DIR/bindings"
AUDIT_FILE="${MANAGER_TELEGRAM_AUDIT_FILE:-/var/log/manager/telegram-identity-audit.jsonl}"
PRINCIPALS_DIR="$MANAGER_ETC/automation/v2/principals"
CONTRACT="manager-telegram-identity-v1"

valid_telegram_user_id() {
  [[ "${1:-}" =~ ^[1-9][0-9]{0,18}$ ]] || return 1
  python3 - "$1" <<'PY'
import sys
v=int(sys.argv[1])
raise SystemExit(0 if 0 < v <= 9223372036854775807 else 1)
PY
}

valid_principal_id() { [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9_.:-]{0,63}$ ]]; }
principal_file() { printf '%s/%s.conf\n' "$PRINCIPALS_DIR" "$1"; }
binding_file() { printf '%s/%s.conf\n' "$BINDINGS_DIR" "$1"; }

read_field() {
  local file="$1" key="$2"
  awk -F= -v k="$key" '$1==k {sub(/^[^=]*=/,""); print; exit}' "$file" 2>/dev/null || true
}

init_state() {
  install -d -m 0700 "$STATE_DIR" "$BINDINGS_DIR"
  install -d -m 0700 "$(dirname "$AUDIT_FILE")"
  if [[ ! -e "$AUDIT_FILE" ]]; then
    : > "$AUDIT_FILE"
  fi
  chmod 0600 "$AUDIT_FILE"
}

json_escape() {
  python3 -c 'import json,sys; print(json.dumps(sys.argv[1], ensure_ascii=False))' "$1"
}

audit() {
  local event="$1" uid="${2:-}" principal="${3:-}" reason="${4:-}" now
  now="$(date +%s)"
  printf '{"contract":"%s","epoch":%s,"event":%s,"telegram_user_id":%s,"principal_id":%s,"reason":%s}\n' \
    "$CONTRACT" "$now" "$(json_escape "$event")" "$(json_escape "$uid")" \
    "$(json_escape "$principal")" "$(json_escape "$reason")" >> "$AUDIT_FILE"
  chmod 0600 "$AUDIT_FILE"
}

write_binding() {
  local uid="$1" principal="$2" enabled="$3" created="$4" updated="$5" tmp
  tmp="$(mktemp "$STATE_DIR/.binding.XXXXXX")"
  {
    printf 'version=1\n'
    printf 'contract=%s\n' "$CONTRACT"
    printf 'telegram_user_id=%s\n' "$uid"
    printf 'principal_id=%s\n' "$principal"
    printf 'enabled=%s\n' "$enabled"
    printf 'created_epoch=%s\n' "$created"
    printf 'updated_epoch=%s\n' "$updated"
  } > "$tmp"
  install -m 0600 "$tmp" "$(binding_file "$uid")"
  rm -f "$tmp"
}

assert_principal_exists() {
  local principal="$1" file
  valid_principal_id "$principal" || { err "principal_id inválido"; return 64; }
  file="$(principal_file "$principal")"
  [[ -f "$file" ]] || { err "Principal Automation v2 não existe: $principal"; return 66; }
}

principal_bound_elsewhere() {
  local principal="$1" except_uid="${2:-}" file uid
  for file in "$BINDINGS_DIR"/*.conf; do
    [[ -f "$file" ]] || continue
    uid="$(read_field "$file" telegram_user_id)"
    [[ "$uid" == "$except_uid" ]] && continue
    [[ "$(read_field "$file" principal_id)" == "$principal" ]] && return 0
  done
  return 1
}

bind_identity() {
  local uid="${1:-}" principal="${2:-}" now
  init_state
  valid_telegram_user_id "$uid" || { err "Telegram user.id inválido"; return 64; }
  assert_principal_exists "$principal" || return $?
  [[ ! -e "$(binding_file "$uid")" ]] || { err "Telegram user.id já vinculado: $uid"; return 65; }
  if principal_bound_elsewhere "$principal"; then
    err "Principal já está vinculado a outro Telegram user.id: $principal"
    return 65
  fi
  now="$(date +%s)"
  write_binding "$uid" "$principal" 1 "$now" "$now"
  audit bind "$uid" "$principal" local-root
  printf 'contract=%s\ntelegram_user_id=%s\nprincipal_id=%s\nenabled=1\n' "$CONTRACT" "$uid" "$principal"
}

set_enabled() {
  local uid="${1:-}" enabled="$2" file principal created now
  init_state
  valid_telegram_user_id "$uid" || { err "Telegram user.id inválido"; return 64; }
  [[ "$enabled" == 0 || "$enabled" == 1 ]] || return 64
  file="$(binding_file "$uid")"
  [[ -f "$file" ]] || { err "Vínculo Telegram não existe: $uid"; return 66; }
  principal="$(read_field "$file" principal_id)"
  assert_principal_exists "$principal" || return $?
  created="$(read_field "$file" created_epoch)"
  [[ "$created" =~ ^[0-9]+$ ]] || created="$(date +%s)"
  now="$(date +%s)"
  write_binding "$uid" "$principal" "$enabled" "$created" "$now"
  if [[ "$enabled" == 1 ]]; then audit enable "$uid" "$principal" local-root; else audit disable "$uid" "$principal" local-root; fi
  printf 'telegram_user_id=%s\nprincipal_id=%s\nenabled=%s\n' "$uid" "$principal" "$enabled"
}

show_binding() {
  local uid="${1:-}" file
  init_state
  valid_telegram_user_id "$uid" || return 64
  file="$(binding_file "$uid")"
  [[ -f "$file" ]] || return 66
  cat "$file"
}

list_bindings() {
  local file found=0
  init_state
  printf '%-22s %-30s %-8s\n' TELEGRAM_USER_ID PRINCIPAL ENABLED
  for file in "$BINDINGS_DIR"/*.conf; do
    [[ -f "$file" ]] || continue
    found=1
    printf '%-22s %-30s %-8s\n' \
      "$(read_field "$file" telegram_user_id)" \
      "$(read_field "$file" principal_id)" \
      "$(read_field "$file" enabled)"
  done
  (( found == 1 )) || return 1
}

resolve_identity() {
  local uid="${1:-}" binding principal_file_path principal binding_enabled principal_enabled role subject products node_scope pool_scope action_scope
  init_state
  valid_telegram_user_id "$uid" || { err "Telegram user.id inválido"; return 64; }
  binding="$(binding_file "$uid")"
  [[ -f "$binding" ]] || { audit resolve-deny "$uid" '' unbound; err "Telegram user.id não autorizado"; return 66; }
  binding_enabled="$(read_field "$binding" enabled)"
  principal="$(read_field "$binding" principal_id)"
  [[ "$binding_enabled" == 1 ]] || { audit resolve-deny "$uid" "$principal" binding-disabled; err "Vínculo Telegram desabilitado"; return 77; }
  assert_principal_exists "$principal" || { audit resolve-deny "$uid" "$principal" principal-missing; return 66; }
  principal_file_path="$(principal_file "$principal")"
  principal_enabled="$(read_field "$principal_file_path" enabled)"
  [[ "$principal_enabled" == 1 ]] || { audit resolve-deny "$uid" "$principal" principal-disabled; err "Principal Automation v2 desabilitado"; return 77; }

  role="$(read_field "$principal_file_path" role)"
  subject="$(read_field "$principal_file_path" subject)"
  products="$(read_field "$principal_file_path" products)"
  node_scope="$(read_field "$principal_file_path" node_scope)"; node_scope="${node_scope:-*}"
  pool_scope="$(read_field "$principal_file_path" pool_scope)"; pool_scope="${pool_scope:-*}"
  action_scope="$(read_field "$principal_file_path" action_scope)"; action_scope="${action_scope:-*}"

  python3 - "$CONTRACT" "$uid" "$principal" "$role" "$subject" "$products" "$node_scope" "$pool_scope" "$action_scope" <<'PY'
import json,sys
keys=['contract','telegram_user_id','principal_id','role','subject','products','node_scope','pool_scope','action_scope']
obj=dict(zip(keys,sys.argv[1:]))
obj['enabled']=1
obj['authority']='automation-v2-principal'
obj['username_is_authority']=0
print(json.dumps(obj,separators=(',',':'),ensure_ascii=False))
PY
  audit resolve "$uid" "$principal" automation-v2-principal
}

status() {
  init_state
  local total=0 enabled=0 file
  for file in "$BINDINGS_DIR"/*.conf; do
    [[ -f "$file" ]] || continue
    total=$((total+1))
    [[ "$(read_field "$file" enabled)" == 1 ]] && enabled=$((enabled+1))
  done
  printf 'contract=%s\n' "$CONTRACT"
  printf 'identity_source=telegram_user_id\n'
  printf 'username_is_authority=0\n'
  printf 'rbac_authority=automation-v2-principal\n'
  printf 'bindings=%s\n' "$total"
  printf 'enabled_bindings=%s\n' "$enabled"
  printf 'arbitrary_shell=0\n'
}

case "${1:-}" in
  --install|--init) init_state; exit 0 ;;
  --status) status; exit $? ;;
  --bind) bind_identity "${2:-}" "${3:-}"; exit $? ;;
  --enable) set_enabled "${2:-}" 1; exit $? ;;
  --disable) set_enabled "${2:-}" 0; exit $? ;;
  --show) show_binding "${2:-}"; exit $? ;;
  --list) list_bindings; exit $? ;;
  --resolve) resolve_identity "${2:-}"; exit $? ;;
  *)
    cat >&2 <<'EOF'
Uso:
  telegram_identity.sh --status
  telegram_identity.sh --bind TELEGRAM_USER_ID PRINCIPAL_ID
  telegram_identity.sh --enable TELEGRAM_USER_ID
  telegram_identity.sh --disable TELEGRAM_USER_ID
  telegram_identity.sh --show TELEGRAM_USER_ID
  telegram_identity.sh --list
  telegram_identity.sh --resolve TELEGRAM_USER_ID
EOF
    exit 64
    ;;
esac
