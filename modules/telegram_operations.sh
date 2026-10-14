#!/usr/bin/env bash
set -Eeuo pipefail
set +x
umask 077

MANAGER_HOME="${MANAGER_HOME:-/opt/manager}"
MANAGER_ETC="${MANAGER_ETC:-/etc/manager}"
# shellcheck source=/dev/null
source "$MANAGER_HOME/lib/common.sh"
require_root

GATEWAY_MODULE="${MANAGER_TELEGRAM_GATEWAY_MODULE:-$MANAGER_HOME/modules/telegram_gateway.sh}"
READ_OPS_MODULE="${MANAGER_AUTOMATION_READ_OPS_MODULE:-$MANAGER_HOME/modules/automation_read_ops.sh}"
STATE_DIR="${MANAGER_TELEGRAM_OPERATIONS_STATE_DIR:-$MANAGER_ETC/telegram/operations}"
AUDIT_FILE="${MANAGER_TELEGRAM_OPERATIONS_AUDIT_FILE:-/var/log/manager/telegram-operations-audit.jsonl}"
CONTRACT="manager-telegram-operations-v1"
REQUEST_CONTRACT="manager-telegram-operations-request-v1"
CAPABILITY="node.usage"
MAX_REQUEST_BYTES=16384

init_state() {
  install -d -m 0700 "$STATE_DIR"
  install -d -m 0750 "$(dirname "$AUDIT_FILE")"
  touch "$AUDIT_FILE"
  chmod 0600 "$AUDIT_FILE"
}

status() {
  init_state
  printf 'contract=%s\n' "$CONTRACT"
  printf 'request_contract=%s\n' "$REQUEST_CONTRACT"
  printf 'read_contract=manager-automation-read-ops-v1\n'
  printf 'authorization_authority=automation-v2\n'
  printf 'authorization_capability=%s\n' "$CAPABILITY"
  printf 'operations=identities,products,sessions,nodes,diagnostics\n'
  printf 'read_only=1\n'
  printf 'writes=0\n'
  printf 'arbitrary_shell=0\n'
  printf 'raw_initdata_argv=0\n'
  printf 'snapshot_cache=none\n'
}

call_ops() {
  local auth_mode="${1:-}" auth_source="${2:-}" request_file="${3:-}"
  init_state
  [[ -x "$GATEWAY_MODULE" ]] || { err "Gateway Telegram indisponível"; return 70; }
  [[ -x "$READ_OPS_MODULE" ]] || { err "Backend read-only indisponível"; return 70; }
  case "$auth_mode" in
    miniapp) [[ -n "$auth_source" && -f "$auth_source" && -r "$auth_source" && ! -L "$auth_source" ]] || { err "Arquivo initData inválido"; return 66; } ;;
    bot) [[ "$auth_source" =~ ^[1-9][0-9]{0,15}$ ]] || { err "Telegram user.id inválido"; return 64; } ;;
    *) err "Fonte de autenticação inválida"; return 64 ;;
  esac
  [[ -n "$request_file" && -f "$request_file" && -r "$request_file" && ! -L "$request_file" ]] || { err "Arquivo de requisição inválido"; return 66; }
  if (( $(stat -c '%s' "$request_file" 2>/dev/null || echo 999999) > MAX_REQUEST_BYTES )); then
    err "Requisição excede o limite"
    return 64
  fi

  python3 - "$CONTRACT" "$REQUEST_CONTRACT" "$CAPABILITY" "$GATEWAY_MODULE" "$READ_OPS_MODULE" "$AUDIT_FILE" "$auth_mode" "$auth_source" "$request_file" <<'PY'
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
import time

contract, request_contract, capability, gateway, read_ops, audit_file, auth_mode, auth_source, request_file = sys.argv[1:10]
REQUEST_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{7,95}$")
OPS = {
    "identities": "--identities",
    "products": "--products",
    "sessions": "--sessions",
    "nodes": "--nodes",
    "diagnostics": "--diagnostics",
}


def emit(obj):
    print(json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False))


def audit(uid, principal, operation, request_id, decision, code, auth_cached=False):
    row = {
        "contract": contract,
        "epoch": int(time.time()),
        "telegram_user_id": str(uid)[:32],
        "principal_id": str(principal)[:64],
        "operation": str(operation)[:32],
        "request_id": str(request_id)[:96],
        "decision": decision if decision in {"allow", "deny"} else "deny",
        "code": int(code),
        "authorization_cached": 1 if auth_cached else 0,
    }
    fd = os.open(audit_file, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    try:
        os.write(fd, (json.dumps(row, sort_keys=True, separators=(",", ":")) + "\n").encode())
    finally:
        os.close(fd)
    os.chmod(audit_file, 0o600)


def fail(message, code, operation="", request_id="", uid="", principal="", auth_cached=False):
    audit(uid, principal, operation, request_id, "deny", code, auth_cached)
    emit({
        "contract": contract,
        "request_contract": request_contract,
        "operation": operation,
        "telegram_request_id": request_id,
        "ok": False,
        "code": int(code),
        "error": str(message)[:4096],
        "authorization_authority": "automation-v2",
        "authorization_capability": capability,
    })
    raise SystemExit(int(code))


try:
    raw = open(request_file, "rb").read(16385)
except OSError:
    fail("requisição operacional ilegível", 66)
if len(raw) > 16384 or b"\x00" in raw:
    fail("requisição operacional inválida", 64)
try:
    req = json.loads(raw.decode("utf-8"))
except Exception:
    fail("requisição operacional não é JSON válido", 64)
if not isinstance(req, dict) or set(req) != {"contract", "request_id", "operation", "params"}:
    fail("envelope operacional possui campos inválidos", 64)
if req.get("contract") != request_contract:
    fail("contrato operacional inválido", 64)
request_id = req.get("request_id")
operation = req.get("operation")
params = req.get("params")
if not isinstance(request_id, str) or not REQUEST_RE.fullmatch(request_id):
    fail("request_id operacional inválido", 64, operation=str(operation or ""), request_id=str(request_id or ""))
if not isinstance(operation, str) or operation not in OPS:
    fail("operação read-only não allowlisted", 64, operation=str(operation or ""), request_id=request_id)
if params != {}:
    fail("operações read-only não aceitam parâmetros", 64, operation=operation, request_id=request_id)

probe_id = "ops-auth-" + hashlib.sha256((operation + "\0" + request_id).encode()).hexdigest()[:48]
probe = {
    "contract": "manager-telegram-gateway-request-v1",
    "request_id": probe_id,
    "action_id": capability,
    "params": {},
}
fd, probe_path = tempfile.mkstemp(prefix="manager-telegram-ops-probe-", suffix=".json")
os.fchmod(fd, 0o600)
with os.fdopen(fd, "w", encoding="utf-8") as fh:
    json.dump(probe, fh, separators=(",", ":"))
    fh.write("\n")
try:
    if auth_mode == "miniapp":
        cmd = [gateway, "--call", auth_source, probe_path]
    else:
        cmd = [gateway, "--call-bot-user", auth_source, probe_path]
    auth_proc = subprocess.run(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                               text=True, timeout=210, check=False)
finally:
    try: os.unlink(probe_path)
    except FileNotFoundError: pass
try:
    auth = json.loads(auth_proc.stdout)
except Exception:
    fail("resposta de autorização inválida", 70, operation=operation, request_id=request_id)
if not isinstance(auth, dict):
    fail("resposta de autorização inválida", 70, operation=operation, request_id=request_id)
uid = auth.get("telegram_user_id", "")
principal = auth.get("principal_id", "")
auth_cached = bool(auth.get("cached", False))
code = auth.get("code", auth_proc.returncode)
if isinstance(code, bool) or not isinstance(code, int) or not (0 <= code <= 255):
    code = 70
if not auth.get("ok") or code != 0:
    fail(str(auth.get("error", "autorização recusada")), code or 67,
         operation=operation, request_id=request_id, uid=uid, principal=principal, auth_cached=auth_cached)
if auth.get("action_id") != capability or auth.get("authorization_authority") != "automation-v2":
    fail("capability de autorização inválida", 70, operation=operation, request_id=request_id,
         uid=uid, principal=principal, auth_cached=auth_cached)

read_proc = subprocess.run([read_ops, OPS[operation]], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                           stderr=subprocess.DEVNULL, text=True, timeout=60, check=False)
if read_proc.returncode != 0:
    fail("consulta read-only falhou", read_proc.returncode if 0 < read_proc.returncode <= 255 else 70,
         operation=operation, request_id=request_id, uid=uid, principal=principal, auth_cached=auth_cached)
try:
    result = json.loads(read_proc.stdout)
except Exception:
    fail("resposta read-only inválida", 70, operation=operation, request_id=request_id,
         uid=uid, principal=principal, auth_cached=auth_cached)
if not isinstance(result, dict) or result.get("contract") != "manager-automation-read-ops-v1" or result.get("kind") != operation:
    fail("contrato read-only inválido", 70, operation=operation, request_id=request_id,
         uid=uid, principal=principal, auth_cached=auth_cached)

out = {
    "contract": contract,
    "request_contract": request_contract,
    "telegram_request_id": request_id,
    "telegram_user_id": uid,
    "principal_id": principal,
    "operation": operation,
    "ok": True,
    "code": 0,
    "authorization_authority": "automation-v2",
    "authorization_capability": capability,
    "authorization_cached": auth_cached,
    "snapshot_cached": False,
    "result": result,
}
audit(uid, principal, operation, request_id, "allow", 0, auth_cached)
emit(out)
PY
}

call_stdin() {
  local request_file="${1:-}" input rc
  init_state
  [[ -n "$request_file" ]] || { err "Uso: telegram_operations.sh --call-stdin REQUEST.json"; return 64; }
  input="$(mktemp "$STATE_DIR/.initdata.XXXXXX")"
  chmod 0600 "$input"
  head -c 16385 > "$input"
  set +e
  call_ops miniapp "$input" "$request_file"
  rc=$?
  set -e
  rm -f "$input"
  return "$rc"
}

case "${1:-}" in
  --install|--init) init_state ;;
  --status) status ;;
  --call) call_ops miniapp "${2:-}" "${3:-}" ;;
  --call-stdin) call_stdin "${2:-}" ;;
  --call-bot-user) call_ops bot "${2:-}" "${3:-}" ;;
  *)
    cat >&2 <<'USAGE'
Uso:
  telegram_operations.sh --status
  telegram_operations.sh --call /CAMINHO/INITDATA /CAMINHO/REQUEST.json
  telegram_operations.sh --call-stdin /CAMINHO/REQUEST.json
  telegram_operations.sh --call-bot-user TELEGRAM_USER_ID /CAMINHO/REQUEST.json
USAGE
    exit 64
    ;;
esac
