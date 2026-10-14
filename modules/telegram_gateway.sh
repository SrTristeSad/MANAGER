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
GATEWAY_DIR="$STATE_DIR/gateway"
CREDENTIALS_DIR="$GATEWAY_DIR/credentials"
AUDIT_FILE="${MANAGER_TELEGRAM_GATEWAY_AUDIT_FILE:-/var/log/manager/telegram-gateway-audit.jsonl}"
AUTH_MODULE="${MANAGER_TELEGRAM_AUTH_MODULE:-$MANAGER_HOME/modules/telegram_auth.sh}"
IDENTITY_MODULE="${MANAGER_TELEGRAM_IDENTITY_MODULE:-$MANAGER_HOME/modules/telegram_identity.sh}"
AUTOMATION_CREDENTIALS="${MANAGER_AUTOMATION_CREDENTIALS_MODULE:-$MANAGER_HOME/modules/automation_credentials.sh}"
MANAGERCTL="${MANAGERCTL_BIN:-/usr/local/sbin/managerctl}"
[[ -x "$MANAGERCTL" ]] || MANAGERCTL="$MANAGER_HOME/modules/automation_v2.sh"
CONTRACT="manager-telegram-gateway-v1"
REQUEST_CONTRACT="manager-telegram-gateway-request-v1"
MAX_REQUEST_BYTES=16384

json_escape() {
  python3 -c 'import json,sys; print(json.dumps(sys.argv[1], ensure_ascii=False))' "$1"
}

init_state() {
  install -d -m 0700 "$STATE_DIR" "$GATEWAY_DIR" "$CREDENTIALS_DIR"
  install -d -m 0700 "$(dirname "$AUDIT_FILE")"
  if [[ ! -e "$AUDIT_FILE" ]]; then
    : > "$AUDIT_FILE"
  fi
  chmod 0600 "$AUDIT_FILE"
}

audit() {
  local event="$1" uid="${2:-}" principal="${3:-}" action="${4:-}" request_id="${5:-}" decision="${6:-}" code="${7:-70}" cached="${8:-0}" now
  now="$(date +%s)"
  [[ "$code" =~ ^[0-9]+$ ]] || code=70
  [[ "$cached" == 0 || "$cached" == 1 ]] || cached=0
  printf '{"contract":"%s","epoch":%s,"event":%s,"telegram_user_id":%s,"principal_id":%s,"action_id":%s,"request_id":%s,"decision":%s,"code":%s,"cached":%s}\n' \
    "$CONTRACT" "$now" "$(json_escape "$event")" "$(json_escape "$uid")" "$(json_escape "$principal")" \
    "$(json_escape "$action")" "$(json_escape "$request_id")" "$(json_escape "$decision")" "$code" "$cached" >> "$AUDIT_FILE"
  chmod 0600 "$AUDIT_FILE"
}

status() {
  init_state
  printf 'contract=%s\n' "$CONTRACT"
  printf 'request_contract=%s\n' "$REQUEST_CONTRACT"
  printf 'auth_contract=manager-telegram-authenticated-principal-v1\n'
  printf 'authorization_authority=automation-v2\n'
  printf 'automation_auth=ed25519-v2\n'
  printf 'typed_actions=system.describe,node.usage,connection.preflight,connection.create,connection.status,connection.revoke,ops.clients,ops.sessions,ops.products,ops.quotas,ops.nodes,ops.diagnostics\n'
  printf 'rate_limit=automation-v2-principal-action\n'
  printf 'idempotency=automation-v2-request-id\n'
  printf 'credential_model=per-principal-ed25519-client\n'
  printf 'credential_private_local=1\n'
  printf 'credential_registry=automation-v2-public\n'
  printf 'raw_initdata_argv=0\n'
  printf 'arbitrary_shell=0\n'
}

call_gateway() {
  local auth_mode="${1:-}" auth_source="${2:-}" request_file="${3:-}" result rc meta uid principal action request_id code cached decision
  init_state
  [[ -x "$AUTH_MODULE" ]] || { err "Módulo de autenticação Telegram indisponível"; return 70; }
  [[ -x "$IDENTITY_MODULE" ]] || { err "Módulo de identidade Telegram indisponível"; return 70; }
  [[ -x "$AUTOMATION_CREDENTIALS" ]] || { err "Módulo de credenciais Automation v2 indisponível"; return 70; }
  [[ -x "$MANAGERCTL" ]] || { err "managerctl/Automation v2 indisponível"; return 70; }
  case "$auth_mode" in
    miniapp) [[ -n "$auth_source" && -f "$auth_source" && -r "$auth_source" && ! -L "$auth_source" ]] || { err "Arquivo initData inválido ou ilegível"; return 66; } ;;
    bot) [[ "$auth_source" =~ ^[1-9][0-9]{0,15}$ ]] || { err "Telegram user.id inválido"; return 64; } ;;
    *) err "Fonte de autenticação Telegram inválida"; return 64 ;;
  esac
  [[ -n "$request_file" && -f "$request_file" && -r "$request_file" && ! -L "$request_file" ]] || { err "Arquivo de requisição Telegram inválido ou ilegível"; return 66; }
  if (( $(stat -c '%s' "$request_file" 2>/dev/null || echo 999999) > MAX_REQUEST_BYTES )); then
    err "Requisição Telegram excede o limite"
    return 64
  fi

  result="$(mktemp "$GATEWAY_DIR/.result.XXXXXX")"
  meta="$(mktemp "$GATEWAY_DIR/.meta.XXXXXX")"
  set +e
  python3 - "$CONTRACT" "$REQUEST_CONTRACT" "$AUTH_MODULE" "$IDENTITY_MODULE" "$AUTOMATION_CREDENTIALS" "$MANAGERCTL" "$CREDENTIALS_DIR" "$auth_mode" "$auth_source" "$request_file" "$meta" > "$result" <<'PY'
import hashlib
import json
import os
import re
import stat
import subprocess
import sys

contract, request_contract, auth_module, identity_module, credential_module, managerctl, credential_dir, auth_mode, auth_source, request_file, meta_file = sys.argv[1:12]
REQUEST_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{7,95}$")
PRINCIPAL_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$")
ACTION_SCHEMAS = {
    "system.describe": (set(), set()),
    "node.usage": (set(), set()),
    "connection.preflight": ({"id", "plan"}, {"id", "plan", "owner", "protocols"}),
    "connection.create": ({"id", "plan"}, {"id", "plan", "owner", "protocols"}),
    "connection.status": ({"id"}, {"id"}),
    "connection.revoke": ({"id"}, {"id"}),
    "ops.clients": (set(), set()),
    "ops.sessions": (set(), set()),
    "ops.products": (set(), set()),
    "ops.quotas": (set(), set()),
    "ops.nodes": (set(), set()),
    "ops.diagnostics": (set(), set()),
}

def finish_meta(**values):
    safe = {
        "telegram_user_id": str(values.get("telegram_user_id", ""))[:32],
        "principal_id": str(values.get("principal_id", ""))[:64],
        "action_id": str(values.get("action_id", ""))[:64],
        "request_id": str(values.get("request_id", ""))[:96],
        "decision": str(values.get("decision", "deny"))[:32],
        "code": int(values.get("code", 70)),
        "cached": 1 if values.get("cached") else 0,
    }
    fd = os.open(meta_file, os.O_WRONLY | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(safe, fh, sort_keys=True, separators=(",", ":"))
        fh.write("\n")

def fail(message, code=64, **meta):
    finish_meta(code=code, decision="deny", **meta)
    print(json.dumps({"contract": contract, "ok": False, "code": code, "error": message}, separators=(",", ":"), ensure_ascii=False))
    raise SystemExit(code)

def run_json(cmd):
    proc = subprocess.run(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=200, check=False)
    if proc.returncode != 0:
        return proc.returncode, None
    try:
        data = json.loads(proc.stdout)
    except Exception:
        return 70, None
    if not isinstance(data, dict):
        return 70, None
    return 0, data

# Authentication is completed before a principal or requested action is trusted.
if auth_mode == "miniapp":
    auth_rc, auth = run_json([auth_module, "--resolve", auth_source])
    if auth_rc != 0 or not auth:
        fail("autenticação Telegram recusada", auth_rc or 67)
    if auth.get("contract") != "manager-telegram-authenticated-principal-v1":
        fail("contrato de autenticação Telegram inválido", 70)
    uid = auth.get("telegram_user_id", "")
    principal = auth.get("principal_id", "")
elif auth_mode == "bot":
    auth_rc, identity = run_json([identity_module, "--resolve", auth_source])
    if auth_rc != 0 or not identity:
        fail("identidade Telegram Bot recusada", auth_rc or 67)
    if identity.get("contract") != "manager-telegram-identity-v1":
        fail("contrato de identidade Telegram inválido", 70)
    uid = identity.get("telegram_user_id", "")
    principal = identity.get("principal_id", "")
else:
    fail("fonte de autenticação Telegram inválida", 64)
if not isinstance(uid, str) or not uid.isdigit() or not PRINCIPAL_RE.fullmatch(principal or ""):
    fail("contexto Telegram autenticado inválido", 70)

try:
    raw = open(request_file, "rb").read(16385)
except Exception:
    fail("requisição Telegram ilegível", 66, telegram_user_id=uid, principal_id=principal)
if len(raw) > 16384 or b"\x00" in raw:
    fail("requisição Telegram inválida", 64, telegram_user_id=uid, principal_id=principal)
try:
    req = json.loads(raw.decode("utf-8"))
except Exception:
    fail("requisição Telegram não é JSON válido", 64, telegram_user_id=uid, principal_id=principal)
if not isinstance(req, dict) or set(req) != {"contract", "request_id", "action_id", "params"}:
    fail("envelope Telegram possui campos inválidos", 64, telegram_user_id=uid, principal_id=principal)
if req.get("contract") != request_contract:
    fail("contrato de requisição Telegram inválido", 64, telegram_user_id=uid, principal_id=principal)
request_id, action, params = req.get("request_id"), req.get("action_id"), req.get("params")
base_meta = {"telegram_user_id": uid, "principal_id": principal, "request_id": request_id or "", "action_id": action or ""}
if not isinstance(request_id, str) or not REQUEST_RE.fullmatch(request_id):
    fail("request_id Telegram inválido", 64, **base_meta)
if not isinstance(action, str) or action not in ACTION_SCHEMAS:
    fail("ação Telegram não allowlisted", 64, **base_meta)
if not isinstance(params, dict):
    fail("params deve ser objeto", 64, **base_meta)
required, allowed = ACTION_SCHEMAS[action]
if set(params) - allowed or not required.issubset(params):
    fail("parâmetros não permitidos para a ação", 64, **base_meta)
for key, value in params.items():
    if not isinstance(value, str) or len(value) > 512 or "\x00" in value:
        fail("parâmetro Telegram inválido", 64, **base_meta)
    if key in required and not value:
        fail("parâmetro obrigatório vazio", 64, **base_meta)

os.makedirs(credential_dir, mode=0o700, exist_ok=True)
os.chmod(credential_dir, 0o700)
cred_path = os.path.join(credential_dir, principal + ".credential")

def credential_live(path):
    try:
        st = os.lstat(path)
        if not stat.S_ISREG(st.st_mode) or st.st_uid != 0 or stat.S_IMODE(st.st_mode) & 0o077:
            return False
        data = json.load(open(path, encoding="utf-8"))
        if data.get("version") != 1 or data.get("principal_id") != principal or data.get("algorithm") != "ed25519":
            return False
        key_id = data.get("key_id", "")
        if not re.fullmatch(r"ed25519-[a-f0-9]{16}", key_id):
            return False
        meta_path = os.path.join(os.environ.get("MANAGER_ETC", "/etc/manager"), "automation", "v2", "credentials", principal, key_id + ".conf")
        meta = {}
        for line in open(meta_path, encoding="utf-8"):
            if "=" in line:
                k, v = line.rstrip("\n").split("=", 1); meta[k] = v
        return meta.get("principal_id") == principal and meta.get("key_id") == key_id and meta.get("enabled") == "1" and meta.get("revoked_epoch", "0") == "0"
    except Exception:
        return False

if not credential_live(cred_path):
    try:
        os.unlink(cred_path)
    except FileNotFoundError:
        pass
    proc = subprocess.run([credential_module, "--enroll", principal, cred_path], stdin=subprocess.DEVNULL,
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30, check=False)
    if proc.returncode != 0 or not credential_live(cred_path):
        fail("não foi possível preparar credencial do gateway", 70, **base_meta)
os.chmod(cred_path, 0o600)

# Namespace the external request id per principal. Same Telegram retry maps to the
# same Automation request_id; another principal may safely reuse the external id.
internal_id = "tg-" + hashlib.sha256((principal + "\0" + request_id).encode("utf-8")).hexdigest()[:48]
cmd = [managerctl, "--principal", principal, "--credential", cred_path, action, "--request-id", internal_id]
for key in sorted(params):
    cmd.append(f"{key}={params[key]}")
proc = subprocess.run(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                      text=True, timeout=200, check=False)
try:
    automation = json.loads(proc.stdout)
except Exception:
    fail("resposta inválida da Automation v2", 70, **base_meta)
if not isinstance(automation, dict):
    fail("resposta inválida da Automation v2", 70, **base_meta)
code = automation.get("code", proc.returncode)
if isinstance(code, bool) or not isinstance(code, int) or not (0 <= code <= 255):
    code = 70
ok = bool(automation.get("ok", False)) and code == 0
cached = bool(automation.get("cached", False))
out = {
    "contract": contract,
    "request_contract": request_contract,
    "telegram_request_id": request_id,
    "telegram_user_id": uid,
    "principal_id": principal,
    "action_id": action,
    "ok": ok,
    "code": code,
    "cached": cached,
    "authorization_authority": "automation-v2",
    "rate_limit_authority": "automation-v2-principal-action",
    "idempotency_authority": "automation-v2-request-id",
}
if "retry_after_seconds" in automation and isinstance(automation["retry_after_seconds"], int):
    out["retry_after_seconds"] = automation["retry_after_seconds"]
if ok:
    if isinstance(automation.get("result"), dict):
        out["result"] = automation["result"]
else:
    out["error"] = str(automation.get("error", "operação recusada"))[:4096]
finish_meta(code=code, decision="allow" if ok else "deny", cached=cached, **base_meta)
print(json.dumps(out, sort_keys=True, separators=(",", ":"), ensure_ascii=False))
raise SystemExit(code)
PY
  rc=$?
  set -e

  if [[ -s "$meta" ]]; then
    uid="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("telegram_user_id",""))' "$meta" 2>/dev/null || true)"
    principal="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("principal_id",""))' "$meta" 2>/dev/null || true)"
    action="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("action_id",""))' "$meta" 2>/dev/null || true)"
    request_id="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("request_id",""))' "$meta" 2>/dev/null || true)"
    code="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("code",70))' "$meta" 2>/dev/null || echo 70)"
    cached="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("cached",0))' "$meta" 2>/dev/null || echo 0)"
    decision="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("decision","deny"))' "$meta" 2>/dev/null || echo deny)"
    audit gateway-call "$uid" "$principal" "$action" "$request_id" "$decision" "$code" "$cached"
  else
    audit gateway-call '' '' '' '' deny "$rc" 0
  fi
  cat "$result"
  rm -f "$result" "$meta"
  return "$rc"
}

call_stdin() {
  local request_file="${1:-}" input rc
  init_state
  [[ -n "$request_file" ]] || { err "Uso: telegram_gateway.sh --call-stdin REQUEST_JSON"; return 64; }
  input="$(mktemp "$GATEWAY_DIR/.initdata.XXXXXX")"
  head -c 16385 > "$input"
  set +e
  call_gateway miniapp "$input" "$request_file"
  rc=$?
  set -e
  rm -f "$input"
  return "$rc"
}

case "${1:-}" in
  --install|--init) init_state; exit 0 ;;
  --status) status; exit $? ;;
  --call) call_gateway miniapp "${2:-}" "${3:-}"; exit $? ;;
  --call-stdin) call_stdin "${2:-}"; exit $? ;;
  --call-bot-user) call_gateway bot "${2:-}" "${3:-}"; exit $? ;;
  *)
    cat >&2 <<'USAGE'
Uso:
  telegram_gateway.sh --status
  telegram_gateway.sh --call /CAMINHO/INITDATA /CAMINHO/REQUEST.json
  telegram_gateway.sh --call-stdin /CAMINHO/REQUEST.json
  telegram_gateway.sh --call-bot-user TELEGRAM_USER_ID /CAMINHO/REQUEST.json   # uso interno do Bot
USAGE
    exit 64
    ;;
esac
