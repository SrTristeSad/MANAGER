#!/usr/bin/env bash
set -Eeuo pipefail
set +x
umask 077

MANAGER_HOME="${MANAGER_HOME:-/opt/manager}"
MANAGER_ETC="${MANAGER_ETC:-/etc/manager}"
# shellcheck source=/dev/null
source "$MANAGER_HOME/lib/common.sh"
require_root

STATE_DIR="${MANAGER_TELEGRAM_STATE_DIR:-$MANAGER_ETC/telegram}"
AUTH_DIR="$STATE_DIR/auth"
SECRETS_DIR="$STATE_DIR/secrets"
TOKEN_FILE="${MANAGER_TELEGRAM_BOT_TOKEN_FILE:-$SECRETS_DIR/bot-token}"
CONFIG_FILE="$AUTH_DIR/config.conf"
AUDIT_FILE="${MANAGER_TELEGRAM_AUTH_AUDIT_FILE:-/var/log/manager/telegram-auth-audit.jsonl}"
IDENTITY_MODULE="${MANAGER_TELEGRAM_IDENTITY_MODULE:-$MANAGER_HOME/modules/telegram_identity.sh}"
CONTRACT="manager-telegram-initdata-v1"
AUTHENTICATED_CONTRACT="manager-telegram-authenticated-principal-v1"
DEFAULT_MAX_AGE_SECONDS=300
DEFAULT_FUTURE_SKEW_SECONDS=30
MAX_INITDATA_BYTES=16384
MAX_INITDATA_FIELDS=64

read_field() {
  local file="$1" key="$2"
  awk -F= -v k="$key" '$1==k {sub(/^[^=]*=/,""); print; exit}' "$file" 2>/dev/null || true
}

json_escape() {
  python3 -c 'import json,sys; print(json.dumps(sys.argv[1], ensure_ascii=False))' "$1"
}

init_state() {
  install -d -m 0700 "$STATE_DIR" "$AUTH_DIR" "$SECRETS_DIR"
  install -d -m 0700 "$(dirname "$AUDIT_FILE")"
  if [[ ! -e "$CONFIG_FILE" ]]; then
    local tmp
    tmp="$(mktemp "$AUTH_DIR/.config.XXXXXX")"
    {
      printf 'version=1\n'
      printf 'max_age_seconds=%s\n' "$DEFAULT_MAX_AGE_SECONDS"
      printf 'future_skew_seconds=%s\n' "$DEFAULT_FUTURE_SKEW_SECONDS"
    } > "$tmp"
    install -m 0600 "$tmp" "$CONFIG_FILE"
    rm -f "$tmp"
  fi
  chmod 0600 "$CONFIG_FILE"
  if [[ ! -e "$AUDIT_FILE" ]]; then
    : > "$AUDIT_FILE"
  fi
  chmod 0600 "$AUDIT_FILE"
  [[ ! -e "$TOKEN_FILE" ]] || chmod 0600 "$TOKEN_FILE"
}

audit() {
  local event="$1" uid="${2:-}" reason="${3:-}" now
  now="$(date +%s)"
  printf '{"contract":"%s","epoch":%s,"event":%s,"telegram_user_id":%s,"reason":%s}\n' \
    "$CONTRACT" "$now" "$(json_escape "$event")" "$(json_escape "$uid")" "$(json_escape "$reason")" >> "$AUDIT_FILE"
  chmod 0600 "$AUDIT_FILE"
}

valid_uint_range() {
  local value="${1:-}" min="$2" max="$3" n
  [[ "$value" =~ ^[0-9]+$ ]] || return 1
  n=$((10#$value))
  (( n >= min && n <= max ))
}

write_config() {
  local max_age="$1" future_skew="$2" tmp
  tmp="$(mktemp "$AUTH_DIR/.config.XXXXXX")"
  {
    printf 'version=1\n'
    printf 'max_age_seconds=%s\n' "$max_age"
    printf 'future_skew_seconds=%s\n' "$future_skew"
  } > "$tmp"
  install -m 0600 "$tmp" "$CONFIG_FILE"
  rm -f "$tmp"
}

set_freshness() {
  local max_age="${1:-}" future_skew="${2:-$DEFAULT_FUTURE_SKEW_SECONDS}"
  init_state
  valid_uint_range "$max_age" 30 86400 || { err "max_age_seconds inválido (30..86400)"; return 64; }
  valid_uint_range "$future_skew" 0 300 || { err "future_skew_seconds inválido (0..300)"; return 64; }
  max_age=$((10#$max_age)); future_skew=$((10#$future_skew))
  write_config "$max_age" "$future_skew"
  audit freshness-set '' "max-age=${max_age};future-skew=${future_skew}"
  printf 'max_age_seconds=%s\nfuture_skew_seconds=%s\n' "$max_age" "$future_skew"
}

install_token() {
  local source="${1:-}" rc
  init_state
  [[ -n "$source" && -f "$source" && -r "$source" && ! -L "$source" ]] || { err "Arquivo de bot token inválido ou ilegível"; return 66; }
  set +e
  python3 - "$source" "$TOKEN_FILE" <<'PY'
import os,re,sys,tempfile
src,dst=sys.argv[1:3]
raw=open(src,'rb').read()
if len(raw)>256 or b'\x00' in raw:
    raise SystemExit(64)
try:
    text=raw.decode('ascii')
except UnicodeDecodeError:
    raise SystemExit(64)
text=text.rstrip('\r\n')
if '\n' in text or '\r' in text or not re.fullmatch(r'[1-9][0-9]{4,15}:[A-Za-z0-9_-]{20,128}', text):
    raise SystemExit(64)
os.makedirs(os.path.dirname(dst), mode=0o700, exist_ok=True)
fd,tmp=tempfile.mkstemp(prefix='.bot-token.', dir=os.path.dirname(dst))
try:
    os.fchmod(fd,0o600)
    with os.fdopen(fd,'wb') as f:
        f.write(text.encode('ascii')+b'\n')
        f.flush(); os.fsync(f.fileno())
    os.replace(tmp,dst)
    os.chmod(dst,0o600)
except Exception:
    try: os.unlink(tmp)
    except FileNotFoundError: pass
    raise
PY
  rc=$?
  set -e
  if (( rc != 0 )); then
    err "Formato de bot token recusado"
    return "$rc"
  fi
  audit token-installed '' local-root
  printf 'token_configured=1\n'
}

bot_id() {
  [[ -r "$TOKEN_FILE" ]] || return 1
  local id rest
  IFS=: read -r id rest < "$TOKEN_FILE"
  [[ "$id" =~ ^[1-9][0-9]{4,15}$ && "$rest" =~ ^[A-Za-z0-9_-]{20,128}$ ]] || return 1
  printf '%s\n' "$id"
}

status() {
  init_state
  local max_age future_skew configured=0 valid=0 id=''
  max_age="$(read_field "$CONFIG_FILE" max_age_seconds)"
  future_skew="$(read_field "$CONFIG_FILE" future_skew_seconds)"
  if [[ -r "$TOKEN_FILE" ]]; then
    configured=1
    if id="$(bot_id)"; then valid=1; fi
  fi
  printf 'contract=%s\n' "$CONTRACT"
  printf 'auth_source=telegram_webapp_initdata\n'
  printf 'auth_method=hmac-sha256-webappdata\n'
  printf 'token_configured=%s\n' "$configured"
  printf 'token_valid=%s\n' "$valid"
  printf 'bot_id=%s\n' "$id"
  printf 'max_age_seconds=%s\n' "$max_age"
  printf 'future_skew_seconds=%s\n' "$future_skew"
  printf 'raw_initdata_argv=0\n'
  printf 'username_is_authority=0\n'
  printf 'identity_authority=automation-v2-principal\n'
  printf 'arbitrary_shell=0\n'
}

verify_to_file() {
  local input_path="$1" output_path="$2" reason_file rc uid reason
  init_state
  if [[ ! -r "$TOKEN_FILE" ]]; then
    audit verify-deny '' token-not-configured
    err "Bot token Telegram não configurado"
    return 77
  fi
  reason_file="$(mktemp "$AUTH_DIR/.verify-reason.XXXXXX")"
  : > "$reason_file"
  set +e
  python3 - "$TOKEN_FILE" "$CONFIG_FILE" "$reason_file" "$MAX_INITDATA_BYTES" "$MAX_INITDATA_FIELDS" "$input_path" > "$output_path" <<'PY'
import hashlib,hmac,json,re,sys,time
from urllib.parse import parse_qsl

token_file,config_file,reason_file,max_bytes,max_fields,input_path=sys.argv[1:7]
max_bytes=int(max_bytes); max_fields=int(max_fields)

def fail(reason, code=77):
    with open(reason_file,'w',encoding='ascii') as f:
        f.write(reason)
    raise SystemExit(code)

def load_config():
    out={}
    try:
        lines=open(config_file,encoding='ascii').read().splitlines()
    except Exception:
        fail('config-unreadable',70)
    for line in lines:
        if '=' in line:
            k,v=line.split('=',1); out[k]=v
    try:
        max_age=int(out['max_age_seconds']); skew=int(out['future_skew_seconds'])
    except Exception:
        fail('config-invalid',70)
    if not (30 <= max_age <= 86400 and 0 <= skew <= 300):
        fail('config-invalid',70)
    return max_age,skew

try:
    if input_path == '-':
        rawb=sys.stdin.buffer.read(max_bytes+1)
    else:
        with open(input_path,'rb') as f:
            rawb=f.read(max_bytes+1)
except Exception:
    fail('initdata-unreadable',66)
if len(rawb)>max_bytes:
    fail('initdata-too-large',64)
try:
    raw=rawb.decode('utf-8').rstrip('\r\n')
except UnicodeDecodeError:
    fail('initdata-not-utf8',64)
if not raw:
    fail('initdata-empty',64)
if '\x00' in raw or re.search(r'%(?![0-9A-Fa-f]{2})', raw):
    fail('initdata-malformed',64)
try:
    pairs=parse_qsl(raw,keep_blank_values=True,strict_parsing=True,max_num_fields=max_fields)
except Exception:
    fail('initdata-malformed',64)
keys=[k for k,_ in pairs]
if len(keys)!=len(set(keys)):
    fail('duplicate-field',64)
params=dict(pairs)
received=params.get('hash','')
if not re.fullmatch(r'[0-9A-Fa-f]{64}',received):
    fail('hash-missing-or-invalid',64)
try:
    token=open(token_file,encoding='ascii').read().rstrip('\r\n')
except Exception:
    fail('token-unreadable',70)
if not re.fullmatch(r'[1-9][0-9]{4,15}:[A-Za-z0-9_-]{20,128}',token):
    fail('token-invalid',70)
check='\n'.join(f'{k}={v}' for k,v in sorted(pairs) if k!='hash')
secret=hmac.new(b'WebAppData',token.encode('ascii'),hashlib.sha256).digest()
calc=hmac.new(secret,check.encode('utf-8'),hashlib.sha256).hexdigest()
if not hmac.compare_digest(calc,received.lower()):
    fail('hash-mismatch')
try:
    auth_date=int(params.get('auth_date',''))
except Exception:
    fail('auth-date-invalid',64)
max_age,skew=load_config(); now=int(time.time()); age=now-auth_date
if auth_date<=0:
    fail('auth-date-invalid',64)
if age>max_age:
    fail('auth-date-expired')
if age < -skew:
    fail('auth-date-future')
try:
    user=json.loads(params.get('user',''))
except Exception:
    fail('user-json-invalid',64)
if not isinstance(user,dict):
    fail('user-json-invalid',64)
uid=user.get('id')
if isinstance(uid,bool) or not isinstance(uid,int) or not (0 < uid <= (2**52-1)):
    fail('user-id-invalid',64)
obj={
    'contract':'manager-telegram-initdata-v1',
    'telegram_user_id':str(uid),
    'auth_date':auth_date,
    'age_seconds':age,
    'max_age_seconds':max_age,
    'future_skew_seconds':skew,
    'hash_valid':1,
    'fresh':1,
    'auth_method':'hmac-sha256-webappdata',
    'query_id_present':1 if bool(params.get('query_id')) else 0,
    'signature_present':1 if bool(params.get('signature')) else 0,
    'username_is_authority':0,
}
print(json.dumps(obj,separators=(',',':'),ensure_ascii=False))
PY
  rc=$?
  set -e
  if (( rc != 0 )); then
    reason="$(cat "$reason_file" 2>/dev/null || true)"
    [[ "$reason" =~ ^[a-z0-9-]{1,64}$ ]] || reason=invalid-initdata
    rm -f "$reason_file" "$output_path"
    audit verify-deny '' "$reason"
    err "Telegram initData recusado: $reason"
    return "$rc"
  fi
  rm -f "$reason_file"
  uid="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["telegram_user_id"])' "$output_path")"
  audit verify-ok "$uid" hmac-sha256-webappdata
}

verify_file() {
  local input="${1:-}" out rc
  init_state
  [[ -n "$input" && -f "$input" && -r "$input" ]] || { err "Arquivo initData inválido ou ilegível"; return 66; }
  out="$(mktemp "$AUTH_DIR/.verified.XXXXXX")"
  set +e
  verify_to_file "$input" "$out"
  rc=$?
  set -e
  if (( rc == 0 )); then cat "$out"; fi
  rm -f "$out"
  return "$rc"
}

verify_stdin() {
  local input out rc
  init_state
  input="$(mktemp "$AUTH_DIR/.initdata.XXXXXX")"
  out="$(mktemp "$AUTH_DIR/.verified.XXXXXX")"
  head -c $((MAX_INITDATA_BYTES+1)) > "$input"
  set +e
  verify_to_file "$input" "$out"
  rc=$?
  set -e
  if (( rc == 0 )); then cat "$out"; fi
  rm -f "$input" "$out"
  return "$rc"
}

resolve_verified() {
  local input_path="$1" verified identity out uid rc
  init_state
  [[ -x "$IDENTITY_MODULE" ]] || { audit resolve-deny '' identity-module-missing; err "Módulo de identidade Telegram indisponível"; return 70; }
  if [[ ! -f "$input_path" || ! -r "$input_path" ]]; then
    err "Arquivo initData inválido ou ilegível"
    return 66
  fi
  verified="$(mktemp "$AUTH_DIR/.verified.XXXXXX")"
  identity="$(mktemp "$AUTH_DIR/.identity.XXXXXX")"
  out="$(mktemp "$AUTH_DIR/.resolved.XXXXXX")"
  set +e
  verify_to_file "$input_path" "$verified"
  rc=$?
  set -e
  if (( rc != 0 )); then
    rm -f "$verified" "$identity" "$out"
    return "$rc"
  fi
  uid="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["telegram_user_id"])' "$verified")"
  set +e
  "$IDENTITY_MODULE" --resolve "$uid" > "$identity"
  rc=$?
  set -e
  if (( rc != 0 )); then
    audit resolve-deny "$uid" identity-denied
    rm -f "$verified" "$identity" "$out"
    err "Identidade Telegram autenticada, mas sem autorização RBAC"
    return "$rc"
  fi
  set +e
  python3 - "$AUTHENTICATED_CONTRACT" "$verified" "$identity" > "$out" <<'PY'
import json,sys
contract,auth_path,identity_path=sys.argv[1:4]
a=json.load(open(auth_path)); i=json.load(open(identity_path))
if a.get('telegram_user_id') != i.get('telegram_user_id'):
    raise SystemExit(70)
obj={
    'contract':contract,
    'telegram_user_id':a['telegram_user_id'],
    'principal_id':i['principal_id'],
    'role':i['role'],
    'subject':i['subject'],
    'products':i['products'],
    'node_scope':i['node_scope'],
    'pool_scope':i['pool_scope'],
    'action_scope':i['action_scope'],
    'enabled':i['enabled'],
    'auth_date':a['auth_date'],
    'age_seconds':a['age_seconds'],
    'auth_method':a['auth_method'],
    'identity_authority':i['authority'],
    'username_is_authority':0,
}
print(json.dumps(obj,separators=(',',':'),ensure_ascii=False))
PY
  rc=$?
  set -e
  if (( rc != 0 )); then
    audit resolve-deny "$uid" contract-mismatch
    rm -f "$verified" "$identity" "$out"
    err "Falha ao compor contexto Telegram autenticado"
    return "$rc"
  fi
  audit resolve-ok "$uid" automation-v2-principal
  cat "$out"
  rm -f "$verified" "$identity" "$out"
}

resolve_stdin() {
  local input rc
  init_state
  input="$(mktemp "$AUTH_DIR/.initdata.XXXXXX")"
  head -c $((MAX_INITDATA_BYTES+1)) > "$input"
  set +e
  resolve_verified "$input"
  rc=$?
  set -e
  rm -f "$input"
  return "$rc"
}

case "${1:-}" in
  --install|--init) init_state; exit 0 ;;
  --status) status; exit $? ;;
  --token-install) install_token "${2:-}"; exit $? ;;
  --freshness-set) set_freshness "${2:-}" "${3:-$DEFAULT_FUTURE_SKEW_SECONDS}"; exit $? ;;
  --verify) verify_file "${2:-}"; exit $? ;;
  --verify-stdin) verify_stdin; exit $? ;;
  --resolve) resolve_verified "${2:-}"; exit $? ;;
  --resolve-stdin) resolve_stdin; exit $? ;;
  *)
    cat >&2 <<'USAGE'
Uso:
  telegram_auth.sh --status
  telegram_auth.sh --token-install /CAMINHO/BOT_TOKEN
  telegram_auth.sh --freshness-set MAX_AGE_SECONDS [FUTURE_SKEW_SECONDS]
  telegram_auth.sh --verify /CAMINHO/INITDATA
  telegram_auth.sh --verify-stdin
  telegram_auth.sh --resolve /CAMINHO/INITDATA
  telegram_auth.sh --resolve-stdin
USAGE
    exit 64
    ;;
esac
