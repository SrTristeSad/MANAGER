#!/usr/bin/env bash
set -Eeuo pipefail

MANAGER_HOME="${MANAGER_HOME:-/opt/manager}"
MANAGER_ETC="${MANAGER_ETC:-/etc/manager}"
# shellcheck source=/dev/null
source "$MANAGER_HOME/lib/common.sh"
require_root

STATE_DIR="$MANAGER_ETC/automation/v2"
DATA_DIR="/var/lib/manager/automation-v2"
IDEMPOTENCY_DIR="$DATA_DIR/idempotency"
AUDIT_DIR="/var/log/manager"
AUDIT_FILE="$AUDIT_DIR/automation-v2-audit.jsonl"
RUNTIME_DIR="/run/manager-automation-v2"
SOCKET_FILE="$RUNTIME_DIR/manager.sock"
SERVICE_FILE="/etc/systemd/system/manager-automation-v2.service"
CONNECTION_ACTIONS="$MANAGER_HOME/modules/connection_actions.sh"
NODE_USAGE="$MANAGER_HOME/modules/node_usage.sh"
CONTRACT="manager-automation-v2-local-v1"

case "$(basename "$0")" in
  managerctl) set -- --call "$@" ;;
  managerd) set -- --serve "$@" ;;
esac

ensure_dirs() {
  install -d -m 0700 "$STATE_DIR" "$DATA_DIR" "$IDEMPOTENCY_DIR" "$AUDIT_DIR"
  touch "$AUDIT_FILE"
  chmod 0600 "$AUDIT_FILE"
}

ensure_dependencies() {
  if ! command -v python3 >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y python3
  fi
  command -v python3 >/dev/null 2>&1
}

write_service() {
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=MANAGER Automation v2 local Unix-socket daemon
After=network.target
ConditionPathExists=$MANAGER_HOME/modules/automation_v2.sh

[Service]
Type=simple
ExecStart=$MANAGER_HOME/modules/automation_v2.sh --serve
Restart=on-failure
RestartSec=2s
RuntimeDirectory=manager-automation-v2
RuntimeDirectoryMode=0700
UMask=0077
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "$SERVICE_FILE"
  systemctl daemon-reload
}

install_v2() {
  local socket_mode=""
  ensure_dependencies || { err "Python 3 é necessário para Automation v2."; return 69; }
  ensure_dirs
  write_service
  systemctl enable --now manager-automation-v2.service >/dev/null

  # Type=simple pode ficar active antes do bind() do processo Python. O install
  # só termina quando a interface realmente existe e está root-only.
  for _ in {1..50}; do
    if [[ -S "$SOCKET_FILE" ]]; then
      socket_mode="$(stat -c '%a' "$SOCKET_FILE" 2>/dev/null || true)"
      [[ "$socket_mode" == "600" ]] && return 0
    fi
    if ! systemctl is-active --quiet manager-automation-v2.service 2>/dev/null; then
      err "Automation v2 encerrou antes de disponibilizar o socket local."
      systemctl --no-pager --full status manager-automation-v2.service >&2 || true
      return 70
    fi
    sleep 0.1
  done

  err "Automation v2 não disponibilizou $SOCKET_FILE com modo 0600."
  systemctl --no-pager --full status manager-automation-v2.service >&2 || true
  return 70
}

detach_v2() {
  systemctl disable --now manager-automation-v2.service >/dev/null 2>&1 || true
  rm -f "$SERVICE_FILE"
  rm -rf "$RUNTIME_DIR"
  systemctl daemon-reload >/dev/null 2>&1 || true
}

purge_v2() {
  detach_v2
  rm -rf "$STATE_DIR" "$DATA_DIR"
  rm -f "$AUDIT_FILE"
}

show_status() {
  local service_state="inactive" socket_state="missing" socket_mode="-"
  systemctl is-active --quiet manager-automation-v2.service 2>/dev/null && service_state="active"
  if [[ -S "$SOCKET_FILE" ]]; then
    socket_state="ready"
    socket_mode="$(stat -c '%a' "$SOCKET_FILE" 2>/dev/null || echo '?')"
  fi
  printf 'contract=%s\n' "$CONTRACT"
  printf 'version=1\ntransport=unix\n'
  printf 'socket=%s\nsocket_mode=%s\nservice=%s\nsocket_state=%s\n' \
    "$SOCKET_FILE" "$socket_mode" "$service_state" "$socket_state"
  printf 'remote_transport=0\narbitrary_shell=0\n'
  printf 'rbac=0\ncryptographic_auth=0\nanti_replay=0\nrate_limit=0\n'
  printf 'idempotency=1\naudit=1\n'
}

serve_v2() {
  ensure_dependencies || exit 69
  ensure_dirs
  [[ -x "$CONNECTION_ACTIONS" ]] || { err "Contrato de conexão ausente: $CONNECTION_ACTIONS"; exit 69; }
  [[ -x "$NODE_USAGE" ]] || { err "Agregador do nó ausente: $NODE_USAGE"; exit 69; }

  exec python3 - "$SOCKET_FILE" "$IDEMPOTENCY_DIR" "$AUDIT_FILE" \
    "$CONNECTION_ACTIONS" "$NODE_USAGE" "$CONTRACT" <<'PY'
import hashlib
import json
import os
import re
import signal
import socket
import stat
import struct
import subprocess
import sys
import tempfile
import time

SOCKET_FILE, IDEMPOTENCY_DIR, AUDIT_FILE, CONNECTION_ACTIONS, NODE_USAGE, CONTRACT = sys.argv[1:]
VERSION = 1
MAX_REQUEST = 65536
IDEMPOTENCY_TTL = 7 * 24 * 60 * 60
REQUEST_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{7,127}$")
KEY_RE = re.compile(r"^[A-Za-z0-9_.-]{1,64}$")
ACTIONS = {
    "system.describe",
    "node.usage",
    "connection.preflight",
    "connection.create",
    "connection.status",
    "connection.revoke",
}


def line(obj):
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n"


def response_error(request_id, action_id, code, message):
    return {
        "contract": CONTRACT,
        "version": VERSION,
        "request_id": request_id,
        "action_id": action_id,
        "ok": False,
        "code": int(code),
        "error": str(message)[:4096],
        "cached": False,
    }


def audit(request_id, action_id, uid, response, cached=False):
    event = {
        "ts_epoch": int(time.time()),
        "request_id": request_id,
        "action_id": action_id,
        "peer_uid": uid,
        "ok": bool(response.get("ok", False)),
        "code": int(response.get("code", 70)),
        "cached": bool(cached),
    }
    with open(AUDIT_FILE, "a", encoding="utf-8") as fh:
        fh.write(line(event))
    os.chmod(AUDIT_FILE, 0o600)


def parse_kv(text):
    data = {}
    for raw in text.splitlines():
        if "=" not in raw:
            continue
        key, value = raw.split("=", 1)
        if KEY_RE.fullmatch(key):
            data[key] = value
    return data


def string_param(params, key, required=True):
    value = params.get(key, "")
    if value is None:
        value = ""
    if not isinstance(value, str):
        raise ValueError(f"{key} deve ser string")
    if required and not value:
        raise ValueError(f"campo obrigatório ausente: {key}")
    if len(value) > 512:
        raise ValueError(f"{key} excede o limite")
    return value


def command_for(action_id, params):
    if not isinstance(params, dict):
        raise ValueError("params deve ser objeto")
    if action_id == "system.describe":
        if params:
            raise ValueError("system.describe não aceita parâmetros")
        return [CONNECTION_ACTIONS, "--describe"]
    if action_id == "node.usage":
        if params:
            raise ValueError("node.usage não aceita parâmetros")
        return [NODE_USAGE, "--show"]
    if action_id in {"connection.status", "connection.revoke"}:
        if set(params) != {"id"}:
            raise ValueError("parâmetro não permitido")
        ident = string_param(params, "id")
        flag = "--status" if action_id.endswith("status") else "--revoke"
        return [CONNECTION_ACTIONS, flag, ident]
    if action_id in {"connection.preflight", "connection.create"}:
        allowed = {"id", "plan", "owner", "protocols"}
        if set(params) - allowed:
            raise ValueError("parâmetro não permitido")
        ident = string_param(params, "id")
        plan = string_param(params, "plan")
        owner = string_param(params, "owner", required=False)
        protocols = string_param(params, "protocols", required=False)
        flag = "--preflight" if action_id.endswith("preflight") else "--create"
        return [CONNECTION_ACTIONS, flag, ident, plan, owner, protocols]
    raise ValueError("ação não permitida")


def request_hash(action_id, params):
    raw = json.dumps(
        {"version": VERSION, "action_id": action_id, "params": params},
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
    ).encode("utf-8")
    return hashlib.sha256(raw).hexdigest()


def cache_path(request_id):
    return os.path.join(IDEMPOTENCY_DIR, request_id + ".json")


def load_cache(request_id, req_hash):
    path = cache_path(request_id)
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        return None
    if not stat.S_ISREG(st.st_mode) or st.st_uid != 0:
        raise RuntimeError("entrada de idempotência inválida")
    with open(path, "r", encoding="utf-8") as fh:
        saved = json.load(fh)
    if saved.get("request_hash") != req_hash:
        return "conflict"
    saved_response = saved.get("response")
    if not isinstance(saved_response, dict):
        raise RuntimeError("cache de idempotência corrompido")
    cached = dict(saved_response)
    cached["cached"] = True
    return cached


def save_cache(request_id, req_hash, response):
    os.makedirs(IDEMPOTENCY_DIR, mode=0o700, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".idem-", dir=IDEMPOTENCY_DIR, text=True)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(
                {"request_hash": req_hash, "response": response},
                fh,
                sort_keys=True,
                separators=(",", ":"),
                ensure_ascii=False,
            )
            fh.write("\n")
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, cache_path(request_id))
    finally:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass


def prune_cache():
    cutoff = time.time() - IDEMPOTENCY_TTL
    try:
        names = os.listdir(IDEMPOTENCY_DIR)
    except FileNotFoundError:
        return
    for name in names:
        if not name.endswith(".json"):
            continue
        path = os.path.join(IDEMPOTENCY_DIR, name)
        try:
            st = os.lstat(path)
            if stat.S_ISREG(st.st_mode) and st.st_mtime < cutoff:
                os.unlink(path)
        except (FileNotFoundError, OSError):
            pass


def execute(request, uid):
    request_id = request.get("request_id", "")
    action_id = request.get("action_id", "")
    params = request.get("params", {})

    if request.get("version") != VERSION:
        return response_error(str(request_id), str(action_id), 64, "versão de envelope não suportada")
    if not isinstance(request_id, str) or not REQUEST_RE.fullmatch(request_id):
        return response_error(str(request_id), str(action_id), 64, "request_id inválido")
    if not isinstance(action_id, str) or action_id not in ACTIONS:
        return response_error(request_id, str(action_id), 64, "action_id não permitido")
    if uid != 0:
        return response_error(request_id, action_id, 67, "peer não autorizado")
    if not isinstance(params, dict):
        return response_error(request_id, action_id, 64, "params deve ser objeto")

    req_hash = request_hash(action_id, params)
    cached = load_cache(request_id, req_hash)
    if cached == "conflict":
        result = response_error(request_id, action_id, 65, "request_id reutilizado com payload diferente")
        audit(request_id, action_id, uid, result)
        return result
    if isinstance(cached, dict):
        audit(request_id, action_id, uid, cached, cached=True)
        return cached

    try:
        cmd = command_for(action_id, params)
    except ValueError as exc:
        result = response_error(request_id, action_id, 64, str(exc))
        save_cache(request_id, req_hash, result)
        audit(request_id, action_id, uid, result)
        return result

    env = os.environ.copy()
    env["LC_ALL"] = "C.UTF-8"
    try:
        proc = subprocess.run(
            cmd,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=180,
            shell=False,
            env=env,
        )
        result = {
            "contract": CONTRACT,
            "version": VERSION,
            "request_id": request_id,
            "action_id": action_id,
            "ok": proc.returncode == 0,
            "code": int(proc.returncode),
            "result": {"data": parse_kv(proc.stdout), "stdout": proc.stdout[:65536]},
            "cached": False,
        }
        if proc.stderr:
            result["stderr"] = proc.stderr[:8192]
    except subprocess.TimeoutExpired:
        result = response_error(request_id, action_id, 70, "tempo limite da operação excedido")

    save_cache(request_id, req_hash, result)
    audit(request_id, action_id, uid, result)
    return result


def peer_uid(conn):
    raw = conn.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i"))
    _pid, uid, _gid = struct.unpack("3i", raw)
    return uid


def read_request(conn):
    chunks = []
    total = 0
    while True:
        data = conn.recv(4096)
        if not data:
            break
        total += len(data)
        if total > MAX_REQUEST:
            raise ValueError("requisição excede 64 KiB")
        chunks.append(data)
        if b"\n" in data:
            break
    raw = b"".join(chunks).split(b"\n", 1)[0]
    if not raw:
        raise ValueError("requisição vazia")
    request = json.loads(raw.decode("utf-8"))
    if not isinstance(request, dict):
        raise ValueError("envelope deve ser objeto JSON")
    return request


def cleanup(*_args):
    try:
        os.unlink(SOCKET_FILE)
    except FileNotFoundError:
        pass
    raise SystemExit(0)

os.makedirs(os.path.dirname(SOCKET_FILE), mode=0o700, exist_ok=True)
os.makedirs(IDEMPOTENCY_DIR, mode=0o700, exist_ok=True)
prune_cache()
if os.path.lexists(SOCKET_FILE):
    st = os.lstat(SOCKET_FILE)
    if not stat.S_ISSOCK(st.st_mode):
        raise SystemExit("socket path ocupado por objeto que não é socket")
    os.unlink(SOCKET_FILE)

server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(SOCKET_FILE)
os.chmod(SOCKET_FILE, 0o600)
server.listen(32)
signal.signal(signal.SIGTERM, cleanup)
signal.signal(signal.SIGINT, cleanup)

while True:
    conn, _ = server.accept()
    with conn:
        try:
            result = execute(read_request(conn), peer_uid(conn))
        except Exception as exc:
            result = response_error("unknown", "unknown", 64, str(exc))
        conn.sendall(line(result).encode("utf-8"))
PY
}

call_v2() {
  ensure_dependencies || exit 69
  [[ -S "$SOCKET_FILE" ]] || { err "Automation v2 não está disponível em $SOCKET_FILE"; exit 69; }
  exec python3 - "$SOCKET_FILE" "$@" <<'PY'
import json
import re
import socket
import sys
import uuid

socket_file = sys.argv[1]
args = sys.argv[2:]
if not args:
    print("Uso: managerctl ACTION [key=value ...] [--request-id ID]", file=sys.stderr)
    raise SystemExit(64)

action = "system.describe" if args[0] == "describe" else args[0]
request_id = None
params = {}
i = 1
while i < len(args):
    item = args[i]
    if item == "--request-id":
        if i + 1 >= len(args):
            print("--request-id exige valor", file=sys.stderr)
            raise SystemExit(64)
        request_id = args[i + 1]
        i += 2
        continue
    if "=" not in item:
        print(f"argumento inválido: {item}", file=sys.stderr)
        raise SystemExit(64)
    key, value = item.split("=", 1)
    if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_.-]{0,63}", key):
        print(f"chave inválida: {key}", file=sys.stderr)
        raise SystemExit(64)
    params[key] = value
    i += 1

request = {
    "version": 1,
    "request_id": request_id or str(uuid.uuid4()),
    "action_id": action,
    "params": params,
}
raw = (json.dumps(request, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n").encode("utf-8")
client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
client.settimeout(190)
try:
    client.connect(socket_file)
    client.sendall(raw)
    chunks = []
    total = 0
    while True:
        data = client.recv(4096)
        if not data:
            break
        total += len(data)
        if total > 262144:
            print("resposta excede limite local", file=sys.stderr)
            raise SystemExit(70)
        chunks.append(data)
        if b"\n" in data:
            break
finally:
    client.close()

payload = b"".join(chunks).split(b"\n", 1)[0]
if not payload:
    print("resposta vazia do managerd", file=sys.stderr)
    raise SystemExit(70)
result = json.loads(payload.decode("utf-8"))
print(json.dumps(result, sort_keys=True, ensure_ascii=False))
code = result.get("code", 70)
raise SystemExit(code if isinstance(code, int) and 0 <= code <= 255 else 70)
PY
}

case "${1:-}" in
  --install) install_v2 ;;
  --detach) detach_v2 ;;
  --purge) purge_v2 ;;
  --status) show_status ;;
  --serve) serve_v2 ;;
  --call)
    shift
    call_v2 "$@"
    ;;
  "") show_status ;;
  *)
    err "Uso: automation_v2.sh {--install|--detach|--purge|--status|--serve|--call ACTION [key=value ...]}"
    exit 64
    ;;
esac
