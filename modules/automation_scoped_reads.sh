#!/usr/bin/env bash
set -Eeuo pipefail
set +x
umask 077

MANAGER_HOME="${MANAGER_HOME:-/opt/manager}"
MANAGER_ETC="${MANAGER_ETC:-/etc/manager}"
# shellcheck source=/dev/null
source "$MANAGER_HOME/lib/common.sh"
require_root

CONTRACT="manager-automation-scoped-reads-v1"
python3 - "$CONTRACT" "${1:-}" "${2:-}" "${3:-}" "${4:-*}" "${5:-0}" "${6:-8}" <<'PY'
import json
import os
import re
import stat
import subprocess
import sys
import time
from pathlib import Path

contract, command, role, subject, products_scope, page_s, limit_s = sys.argv[1:8]
manager_home = os.environ.get("MANAGER_HOME", "/opt/manager")
manager_etc = os.environ.get("MANAGER_ETC", "/etc/manager")
identity_dir = Path(manager_etc) / "connection" / "identities"
product_root = Path(manager_etc) / "connection" / "products"
product_dir = product_root / "catalog"
assignment_dir = product_root / "assignments"
local_quota_dir = Path(os.environ.get("MANAGER_PRODUCT_USAGE_ROOT", str(Path(manager_etc) / "connection" / "product-usage"))) / "identities"
reseller_dir = Path(manager_etc) / "access" / "resellers"
hive_lease_conf = Path(manager_etc) / "hive" / "controller" / "leases" / "controller.conf"
hive_lease_active = Path(os.environ.get("MANAGER_HIVE_LEASE_DATA_DIR", "/var/lib/manager/hive-leases")) / "active"
hive_quota_dir = Path(manager_etc) / "hive" / "controller" / "accounting" / "quotas"
hive_accounting_identity_dir = Path(os.environ.get("MANAGER_HIVE_ACCOUNTING_DATA_DIR", "/var/lib/manager/hive-accounting")) / "controller" / "identities"
local_session_dir = Path(os.environ.get("MANAGER_SESSION_RUNTIME", "/run/manager-session-leases")) / "active"

ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,47}$")
ROLE_SET = {"admin", "reseller", "subreseller", "user"}
PRODUCT_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,47}$")


def die(message, code=64):
    print(message, file=sys.stderr)
    raise SystemExit(code)


def secure_regular(path, max_bytes=262144):
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        return False
    if not stat.S_ISREG(st.st_mode) or st.st_uid != 0 or stat.S_IMODE(st.st_mode) & 0o022:
        return False
    return st.st_size <= max_bytes


def read_conf(path):
    path = str(path)
    if not secure_regular(path, 65536):
        return {}
    out = {}
    try:
        with open(path, encoding="utf-8", errors="strict") as fh:
            for raw in fh:
                if "=" not in raw:
                    continue
                key, value = raw.rstrip("\n").split("=", 1)
                if re.fullmatch(r"[A-Za-z0-9_.-]{1,64}", key):
                    out[key] = value[:4096]
    except Exception:
        return {}
    return out


def read_json(path):
    path = str(path)
    if not secure_regular(path, 262144):
        return {}
    try:
        with open(path, encoding="utf-8") as fh:
            value = json.load(fh)
        return value if isinstance(value, dict) else {}
    except Exception:
        return {}


def csv_set(value):
    if value == "*":
        return None
    result = {x for x in value.split(",") if PRODUCT_RE.fullmatch(x)}
    return result


def reseller_record(owner):
    if not ID_RE.fullmatch(owner or ""):
        return {}
    return read_conf(reseller_dir / f"{owner}.conf")


def owner_visible(owner):
    if role == "admin":
        return True
    if role == "subreseller":
        return owner == subject
    if role == "reseller":
        if owner == subject:
            return True
        record = reseller_record(owner)
        return record.get("role") == "subreseller" and record.get("parent") == subject and record.get("enabled") == "1"
    return False


def identity_visible(identity_id, owner=""):
    if role == "user":
        return identity_id == subject
    if not owner_visible(owner):
        return False
    if role in {"reseller", "subreseller"}:
        assignment = read_conf(assignment_dir / f"{identity_id}.conf")
        product_id = assignment.get("product_id", "")
        if product_id and not product_visible(product_id, identity_id):
            return False
    return True


def product_visible(product_id, identity_id=""):
    if role == "admin":
        return True
    if role in {"reseller", "subreseller"}:
        scope = csv_set(products_scope)
        return scope is None or product_id in scope
    if role == "user":
        assignment = read_conf(assignment_dir / f"{identity_id or subject}.conf")
        return assignment.get("product_id") == product_id
    return False


def effective_state(conf):
    if conf.get("enabled", "0") != "1":
        return "disabled"
    try:
        expires = int(conf.get("expires_epoch", "0") or 0)
    except ValueError:
        expires = 0
    if expires and expires < int(time.time()):
        return "expired"
    return "active"


def emit(view, items=None, **extra):
    payload = {"contract": contract, "version": 1, "view": view, "generated_at": int(time.time())}
    if items is not None:
        # Apply RBAC before pagination; never calculate offsets against global rows.
        start = page * limit
        visible = items[start:start + limit]
        has_more = start + limit < len(items)
        payload.update({"items": visible, "count": len(visible), "page": page,
                        "limit": limit, "has_more": has_more,
                        "next_page": page + 1 if has_more else None})
    payload.update(extra)
    print(json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False))


def clients_view():
    rows = []
    for path in sorted(identity_dir.glob("*.conf")):
        identity_id = path.stem
        if not ID_RE.fullmatch(identity_id):
            continue
        conf = read_conf(path)
        if not conf:
            continue
        owner = conf.get("owner", "")
        if not identity_visible(identity_id, owner):
            continue
        assignment = read_conf(assignment_dir / f"{identity_id}.conf")
        rows.append({
            "identity_id": identity_id,
            "state": effective_state(conf),
            "owner": owner,
            "max_sessions": int(conf.get("max_sessions", "0")) if conf.get("max_sessions", "").isdigit() else 0,
            "protocols": [x for x in conf.get("protocols", "").split(",") if x in {"ssh", "wireguard", "openvpn"}],
            "expires_epoch": int(conf.get("expires_epoch", "0")) if conf.get("expires_epoch", "").isdigit() else 0,
            "product_id": assignment.get("product_id", "") if PRODUCT_RE.fullmatch(assignment.get("product_id", "")) else "",
        })
    emit("clients", rows)


def sessions_view():
    rows = []
    source = "local"
    controller = read_conf(hive_lease_conf)
    now = int(time.time())
    if controller.get("enabled") == "1" and hive_lease_active.is_dir():
        source = "hive-global"
        for path in sorted(hive_lease_active.glob("*.json")):
            lease = read_json(path)
            identity_id = str(lease.get("identity_id", ""))
            conf = read_conf(identity_dir / f"{identity_id}.conf")
            if not ID_RE.fullmatch(identity_id) or not identity_visible(identity_id, conf.get("owner", "")):
                continue
            try:
                expires = int(lease.get("expires_epoch", 0) or 0)
            except (TypeError, ValueError):
                expires = 0
            rows.append({
                "identity_id": identity_id,
                "session_id": str(lease.get("global_lease_id", ""))[:64],
                "local_session_id": str(lease.get("local_session_id", ""))[:64],
                "node_id": str(lease.get("node_id", ""))[:64],
                "protocol": str(lease.get("protocol", "")) if lease.get("protocol") in {"ssh", "wireguard", "openvpn"} else "",
                "lease_state": str(lease.get("lease_state", ""))[:32],
                "expires_epoch": expires,
                "remaining_seconds": max(0, expires - now) if expires else 0,
            })
    else:
        for path in sorted(local_session_dir.glob("*.lease")):
            conf = read_conf(path)
            identity_id = conf.get("identity_id", "")
            identity_conf = read_conf(identity_dir / f"{identity_id}.conf")
            if not ID_RE.fullmatch(identity_id) or not identity_visible(identity_id, identity_conf.get("owner", "")):
                continue
            expires = int(conf.get("expires_epoch", "0")) if conf.get("expires_epoch", "").isdigit() else 0
            rows.append({
                "identity_id": identity_id,
                "session_id": path.stem[:64],
                "protocol": conf.get("protocol", "") if conf.get("protocol") in {"ssh", "wireguard", "openvpn"} else "",
                "session_epoch": int(conf.get("session_epoch", "0")) if conf.get("session_epoch", "").isdigit() else 0,
                "expires_epoch": expires,
                "remaining_seconds": max(0, expires - now) if expires else 0,
            })
    emit("sessions", rows, source=source)


def products_view():
    rows = []
    for path in sorted(product_dir.glob("*.conf")):
        product_id = path.stem
        if not PRODUCT_RE.fullmatch(product_id) or not product_visible(product_id):
            continue
        conf = read_conf(path)
        if not conf:
            continue
        def number(key):
            value = conf.get(key, "")
            return int(value) if value.isdigit() else 0
        rows.append({
            "product_id": product_id,
            "name": conf.get("name", "")[:96],
            "enabled": 1 if conf.get("enabled") == "1" else 0,
            "duration_days": number("duration_days"),
            "max_sessions": number("max_sessions"),
            "protocols": [x for x in conf.get("protocols", "").split(",") if x in {"ssh", "wireguard", "openvpn"}],
            "traffic_quota_bytes": number("traffic_quota_bytes"),
            "quota_period": conf.get("quota_period", "") if conf.get("quota_period") in {"none", "monthly", "lifetime"} else "",
            "quota_action": conf.get("quota_action", "") if conf.get("quota_action") in {"warn", "block"} else "",
        })
    emit("products", rows)


def quota_metrics(identity_id):
    global_quota = read_conf(hive_quota_dir / f"{identity_id}.conf")
    global_state = read_json(hive_accounting_identity_dir / f"{identity_id}.json")
    if global_quota:
        quota = int(global_quota.get("quota_bytes", "0")) if global_quota.get("quota_bytes", "").isdigit() else 0
        baseline = int(global_quota.get("baseline_total_bytes", "0")) if global_quota.get("baseline_total_bytes", "").isdigit() else 0
        total = 0
        for key in ("download_bytes", "upload_bytes"):
            try: total += int(global_state.get(key, 0) or 0)
            except (TypeError, ValueError): pass
        used = max(0, total - baseline)
        remaining = max(0, quota - used) if quota else 0
        return {
            "source": "hive-global", "product_id": global_quota.get("product_id", "")[:48],
            "quota_bytes": quota, "used_bytes": used, "remaining_bytes": remaining,
            "exceeded": 1 if quota and used >= quota else 0,
            "enforceable": 1 if global_state.get("traffic_complete", True) not in {False, 0, "0"} else 0,
            "period": global_quota.get("quota_period", "")[:16], "cycle": global_quota.get("cycle", "")[:64],
            "action": global_quota.get("quota_action", "")[:16],
        }
    local = read_conf(local_quota_dir / f"{identity_id}.state")
    assignment = read_conf(assignment_dir / f"{identity_id}.conf")
    if not local and not assignment:
        return None
    def num(key):
        value = local.get(key, "")
        return int(value) if value.isdigit() else 0
    quota = num("quota_bytes")
    used = num("used_bytes")
    remaining = max(0, quota - used) if quota else 0
    return {
        "source": "local", "product_id": assignment.get("product_id", "")[:48],
        "quota_bytes": quota, "used_bytes": used, "remaining_bytes": remaining,
        "exceeded": 1 if local.get("exceeded") == "1" else 0,
        "enforceable": 1 if local.get("enforceable") == "1" else 0,
        "period": "", "cycle": local.get("cycle", "")[:64], "action": local.get("quota_action", "")[:16],
    }


def quotas_view():
    rows = []
    for path in sorted(identity_dir.glob("*.conf")):
        identity_id = path.stem
        conf = read_conf(path)
        if not ID_RE.fullmatch(identity_id) or not conf or not identity_visible(identity_id, conf.get("owner", "")):
            continue
        metrics = quota_metrics(identity_id)
        if not metrics:
            continue
        metrics["identity_id"] = identity_id
        if metrics.get("product_id") and not product_visible(metrics["product_id"], identity_id):
            continue
        rows.append(metrics)
    emit("quotas", rows)


if role not in ROLE_SET:
    die("ops-role-invalid", 64)
if role == "admin":
    subject = "*"
elif not ID_RE.fullmatch(subject or ""):
    die("ops-subject-invalid", 64)
if role == "user":
    if products_scope != "-":
        die("ops-user-products-sentinel-invalid", 64)
elif products_scope != "*":
    parts = products_scope.split(",")
    if not parts or any(not PRODUCT_RE.fullmatch(x) for x in parts):
        die("ops-products-scope-invalid", 64)

handlers = {
    "--clients": clients_view,
    "--sessions": sessions_view,
    "--products": products_view,
    "--quotas": quotas_view,
}
if not page_s.isascii() or not page_s.isdecimal() or len(page_s) > 6:
    die("page-invalid", 64)
if not limit_s.isascii() or not limit_s.isdecimal() or len(limit_s) > 2:
    die("limit-invalid", 64)
page, limit = int(page_s), int(limit_s)
if page > 100000 or not (1 <= limit <= 25):
    die("pagination-out-of-bounds", 64)

handler = handlers.get(command)
if not handler:
    die("Uso: automation_scoped_reads.sh --clients|--sessions|--products|--quotas ROLE SUBJECT PRODUCTS PAGE LIMIT", 64)
handler()
PY