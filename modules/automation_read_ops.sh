#!/usr/bin/env bash
set -Eeuo pipefail
set +x
umask 077

MANAGER_HOME="${MANAGER_HOME:-/opt/manager}"
# shellcheck source=/dev/null
source "$MANAGER_HOME/lib/common.sh"
require_root

command -v python3 >/dev/null 2>&1 || { err "Python 3 é necessário para operações read-only."; exit 69; }

python3 - "$@" <<'PY'
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

MANAGER_HOME = os.environ.get("MANAGER_HOME", "/opt/manager")
CONNECTION = os.path.join(MANAGER_HOME, "modules", "connection_engine.sh")
PRODUCTS = os.path.join(MANAGER_HOME, "modules", "products.sh")
SESSIONS = os.path.join(MANAGER_HOME, "modules", "session_engine.sh")
OBSERVABILITY = os.path.join(MANAGER_HOME, "modules", "hive_observability.sh")
CONTRACT = "manager-automation-read-ops-v1"
MAX_ITEMS = 100
MAX_OUTPUT = 1024 * 1024


def die(message, code=70):
    print(message, file=sys.stderr)
    raise SystemExit(code)


def run(cmd, allowed=(0,), timeout=30):
    try:
        proc = subprocess.run(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                              stderr=subprocess.DEVNULL, text=True, timeout=timeout,
                              check=False, env=os.environ.copy())
    except (OSError, subprocess.TimeoutExpired):
        die("backend read-only indisponível", 70)
    if proc.returncode not in allowed:
        return proc.returncode, ""
    if len(proc.stdout.encode("utf-8", "ignore")) > MAX_OUTPUT:
        die("resposta read-only excede o limite", 70)
    return proc.returncode, proc.stdout


def kv(text):
    out = {}
    for raw in text.splitlines():
        if "=" not in raw:
            continue
        key, value = raw.split("=", 1)
        if key and len(key) <= 64 and len(value) <= 4096:
            out[key] = value
    return out


def int_value(value, default=0):
    try:
        n = int(str(value))
    except (TypeError, ValueError):
        return default
    return n


def emit(kind, items=None, summary=None):
    obj = {"contract": CONTRACT, "kind": kind}
    if items is not None:
        obj["count"] = len(items)
        obj["items"] = items
    if summary is not None:
        obj["summary"] = summary
    print(json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False))


def identities():
    rc, text = run([CONNECTION, "--list"])
    if rc != 0:
        die("não foi possível listar identidades", 70)
    items = []
    for raw in text.splitlines():
        if len(items) >= MAX_ITEMS:
            break
        cols = raw.split("\t")
        if len(cols) < 5:
            continue
        ident, state, owner, max_sessions, protocols = cols[:5]
        item = {
            "id": ident[:48], "state": state[:24], "owner": owner[:48],
            "max_sessions": max(0, int_value(max_sessions)),
            "protocols": [x for x in protocols.split(",") if x in {"ssh", "wireguard", "openvpn"}],
        }
        arc, assignment = run([PRODUCTS, "--assignment", ident], allowed=(0, 66))
        if arc == 0:
            a = kv(assignment)
            item["product_id"] = a.get("product_id", "")[:64]
            item["quota_used_bytes"] = max(0, int_value(a.get("used_bytes", 0)))
            item["quota_bytes"] = max(0, int_value(a.get("quota_bytes", 0)))
            item["quota_exceeded"] = 1 if a.get("exceeded") == "1" else 0
            item["quota_enforceable"] = 1 if a.get("enforceable") == "1" else 0
            item["quota_period"] = a.get("cycle", "")[:64]
        else:
            item["product_id"] = ""
            item["quota_used_bytes"] = 0
            item["quota_bytes"] = 0
            item["quota_exceeded"] = 0
            item["quota_enforceable"] = 0
            item["quota_period"] = ""
        items.append(item)
    emit("identities", items=items)


def products():
    rc, text = run([PRODUCTS, "--list"])
    if rc != 0:
        die("não foi possível listar produtos", 70)
    ids = []
    for raw in text.splitlines():
        product_id = raw.split("\t", 1)[0].strip()
        if product_id and product_id not in ids:
            ids.append(product_id)
        if len(ids) >= MAX_ITEMS:
            break
    fields = {
        "id", "name", "enabled", "duration_days", "max_sessions", "protocols",
        "traffic_quota_bytes", "quota_period", "quota_action", "acl_regions",
        "acl_pools", "acl_nodes",
    }
    items = []
    for product_id in ids:
        src, shown = run([PRODUCTS, "--show", product_id], allowed=(0, 66))
        if src != 0:
            continue
        data = kv(shown)
        item = {k: data.get(k, "")[:256] for k in fields}
        for key in ("enabled", "duration_days", "max_sessions", "traffic_quota_bytes"):
            item[key] = max(0, int_value(item.get(key, 0)))
        item["protocols"] = [x for x in str(item.get("protocols", "")).split(",") if x in {"*", "ssh", "wireguard", "openvpn"}]
        items.append(item)
    emit("products", items=items)


def sessions():
    rc, text = run([SESSIONS, "--list"])
    if rc != 0:
        die("não foi possível listar sessões", 70)
    items = []
    for raw in text.splitlines():
        if len(items) >= MAX_ITEMS:
            break
        cols = raw.split("\t")
        if len(cols) < 2:
            continue
        item = {"identity_id": cols[0][:48], "session_id": cols[1][:64]}
        for token in cols[2:]:
            if "=" not in token:
                continue
            key, value = token.split("=", 1)
            if key in {"epoch", "heartbeat", "expires"}:
                item[key] = max(0, int_value(value))
            elif key == "remaining":
                value = value[:-1] if value.endswith("s") else value
                item["remaining_seconds"] = max(0, int_value(value))
            elif key in {"protocol", "resource", "device"}:
                item[key] = value[:96]
        items.append(item)
    emit("sessions", items=items)


def nodes():
    rc, text = run([OBSERVABILITY, "--export", "3600", str(MAX_ITEMS)])
    if rc != 0:
        die("observabilidade da Colmeia indisponível", 70)
    try:
        data = json.loads(text)
    except json.JSONDecodeError:
        die("export da Colmeia inválido", 70)
    latest = {}
    for row in data.get("health", []) if isinstance(data, dict) else []:
        if not isinstance(row, dict):
            continue
        node_id = row.get("node_id")
        if not isinstance(node_id, str) or not node_id.startswith("node-"):
            continue
        epoch = int_value(row.get("epoch", 0))
        if node_id not in latest or epoch >= int_value(latest[node_id].get("epoch", 0)):
            latest[node_id] = row
    allowed = {
        "epoch", "node_id", "node_epoch", "state", "reason", "sessions", "max_sessions",
        "capacity", "weight", "cpu_percent", "memory_used_percent", "load1", "rtt_ms",
        "protocols", "service_ssh", "service_wireguard", "service_openvpn",
        "hive_network_service", "hive_network_peer_count",
    }
    items = []
    for node_id in sorted(latest)[:MAX_ITEMS]:
        row = latest[node_id]
        items.append({k: row[k] for k in allowed if k in row and isinstance(row[k], (str, int, float, bool, list))})
    emit("nodes", items=items)


def service_state(unit):
    if not shutil.which("systemctl"):
        return "unknown"
    try:
        proc = subprocess.run(["systemctl", "is-active", unit], stdin=subprocess.DEVNULL,
                              stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                              text=True, timeout=3, check=False)
        value = proc.stdout.strip()
        return value if value in {"active", "inactive", "failed", "activating", "deactivating"} else "inactive"
    except (OSError, subprocess.TimeoutExpired):
        return "unknown"


def diagnostics():
    mem_total = mem_avail = 0
    try:
        for raw in Path("/proc/meminfo").read_text(encoding="utf-8").splitlines():
            if raw.startswith("MemTotal:"):
                mem_total = int(raw.split()[1])
            elif raw.startswith("MemAvailable:"):
                mem_avail = int(raw.split()[1])
    except (OSError, ValueError):
        pass
    mem_pct = round(((mem_total - mem_avail) * 100.0 / mem_total), 2) if mem_total else 0.0
    try:
        usage = shutil.disk_usage("/")
        disk_pct = round((usage.used * 100.0 / usage.total), 2) if usage.total else 0.0
    except OSError:
        disk_pct = 0.0
    try:
        load1, load5, load15 = os.getloadavg()
    except OSError:
        load1 = load5 = load15 = 0.0
    default_ipv4 = 0
    try:
        lines = Path("/proc/net/route").read_text(encoding="utf-8").splitlines()[1:]
        default_ipv4 = 1 if any(len(x.split()) > 1 and x.split()[1] == "00000000" for x in lines) else 0
    except OSError:
        pass
    summary = {
        "default_ipv4_route": default_ipv4,
        "load1": round(load1, 3), "load5": round(load5, 3), "load15": round(load15, 3),
        "memory_used_percent": mem_pct, "root_disk_used_percent": disk_pct,
        "reboot_required": 1 if os.path.exists("/var/run/reboot-required") else 0,
        "ssh": "active" if service_state("ssh") == "active" or service_state("sshd") == "active" else "inactive",
        "wireguard": service_state("wg-quick@wg0.service"),
        "openvpn": service_state("openvpn-server@manager.service"),
        "automation_v2": service_state("manager-automation-v2.service"),
        "telegram_bot": service_state("manager-telegram-bot.service"),
    }
    emit("diagnostics", summary=summary)


def status():
    print("contract=" + CONTRACT)
    print("read_only=1")
    print("max_items=" + str(MAX_ITEMS))
    print("secret_fields=0")
    print("actions=operations.identities,operations.products,operations.sessions,operations.nodes,operations.diagnostics")


cmd = sys.argv[1] if len(sys.argv) > 1 else "--status"
if cmd == "--status":
    status()
elif cmd == "--identities":
    identities()
elif cmd == "--products":
    products()
elif cmd == "--sessions":
    sessions()
elif cmd == "--nodes":
    nodes()
elif cmd == "--diagnostics":
    diagnostics()
else:
    die("Uso: automation_read_ops.sh --status|--identities|--products|--sessions|--nodes|--diagnostics", 64)
PY
