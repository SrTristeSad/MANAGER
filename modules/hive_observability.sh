#!/usr/bin/env bash
set -Eeuo pipefail

MANAGER_HOME="${MANAGER_HOME:-/opt/manager}"
MANAGER_ETC="${MANAGER_ETC:-/etc/manager}"
# shellcheck source=/dev/null
source "$MANAGER_HOME/lib/common.sh"
require_root

command -v python3 >/dev/null 2>&1 || { err "Python 3 é necessário para observabilidade da Colmeia."; exit 69; }

python3 - "$@" <<'PY'
import fcntl
import json
import math
import os
import re
import stat
import sys
import tempfile
import time
from collections import deque
from pathlib import Path

DATA_DIR = os.environ.get("MANAGER_HIVE_OBSERVABILITY_DATA_DIR", "/var/lib/manager/hive-observability")
HEALTH_HISTORY = os.path.join(DATA_DIR, "health-history.jsonl")
HEALTH_DATA_DIR = os.environ.get("MANAGER_HIVE_HEALTH_DATA_DIR", "/var/lib/manager/hive-health")
HEALTH_OBS_DIR = os.path.join(HEALTH_DATA_DIR, "nodes")
SCHED_AUDIT = os.environ.get("MANAGER_HIVE_SCHEDULER_AUDIT_FILE", "/var/log/manager/hive-scheduler-audit.jsonl")
LEASE_AUDIT = os.environ.get("MANAGER_HIVE_LEASE_AUDIT_FILE", "/var/log/manager/hive-lease-audit.jsonl")
AUDIT_FILE = os.environ.get("MANAGER_HIVE_OBSERVABILITY_AUDIT_FILE", "/var/log/manager/hive-observability-audit.jsonl")
SCHED_ARCHIVE_DIR = os.environ.get("MANAGER_HIVE_SCHEDULER_AUDIT_ARCHIVE_DIR", SCHED_AUDIT + ".d")
LEASE_ARCHIVE_DIR = os.environ.get("MANAGER_HIVE_LEASE_AUDIT_ARCHIVE_DIR", LEASE_AUDIT + ".d")
LOCK_FILE = os.path.join(DATA_DIR, ".lock")
CONTRACT = "manager-hive-observability-v1"
HEALTH_CONTRACT = "manager-hive-health-history-v1"
NODE_RE = re.compile(r"^node-[a-f0-9]{16}$")
IDENTITY_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,47}$")
DEFAULT_LIMIT = 50
MAX_LIMIT = 500
DEFAULT_WINDOW = 3600
DEFAULT_RETENTION = 7 * 24 * 3600
DEFAULT_AUDIT_RETENTION = 14 * 24 * 3600
DEFAULT_AUDIT_MAX_BYTES = 4 * 1024 * 1024
MAX_AUDIT_MAX_BYTES = 512 * 1024 * 1024
MAX_RETENTION = 90 * 24 * 3600
MAX_LINE = 256 * 1024


def die(message, code=70):
    print(message, file=sys.stderr)
    raise SystemExit(code)


def ensure_dir(path, mode=0o700):
    os.makedirs(path, mode=mode, exist_ok=True)
    os.chmod(path, mode)


def init_dirs():
    ensure_dir(DATA_DIR, 0o700)
    ensure_dir(SCHED_ARCHIVE_DIR, 0o700)
    ensure_dir(LEASE_ARCHIVE_DIR, 0o700)
    Path(LOCK_FILE).touch(mode=0o600, exist_ok=True)
    os.chmod(LOCK_FILE, 0o600)
    if os.path.exists(HEALTH_HISTORY):
        os.chmod(HEALTH_HISTORY, 0o600)


def atomic_write(path, data, mode=0o600):
    ensure_dir(os.path.dirname(path), 0o700)
    fd, tmp = tempfile.mkstemp(prefix=".tmp-", dir=os.path.dirname(path))
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(data)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)
        os.chmod(path, mode)
    finally:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass


def strict_regular(path, max_size=None):
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        return False
    if not stat.S_ISREG(st.st_mode):
        return False
    if max_size is not None and st.st_size > max_size:
        return False
    return True


def parse_int(value, name, minimum, maximum):
    try:
        out = int(value)
    except (TypeError, ValueError):
        die(f"{name} inválido.", 64)
    if out < minimum or out > maximum:
        die(f"{name} deve estar entre {minimum} e {maximum}.", 64)
    return out


def retention_seconds(value=None):
    raw = value if value not in (None, "") else os.environ.get("MANAGER_HIVE_OBSERVABILITY_RETENTION_SECONDS", str(DEFAULT_RETENTION))
    return parse_int(raw, "retention_seconds", 3600, MAX_RETENTION)


def audit_retention_seconds(value=None):
    raw = value if value not in (None, "") else os.environ.get(
        "MANAGER_HIVE_OBSERVABILITY_AUDIT_RETENTION_SECONDS", str(DEFAULT_AUDIT_RETENTION)
    )
    return parse_int(raw, "audit_retention_seconds", 3600, MAX_RETENTION)


def audit_max_bytes(value=None):
    raw = value if value not in (None, "") else os.environ.get(
        "MANAGER_HIVE_OBSERVABILITY_AUDIT_MAX_BYTES", str(DEFAULT_AUDIT_MAX_BYTES)
    )
    return parse_int(raw, "audit_max_bytes", 1024, MAX_AUDIT_MAX_BYTES)


def read_json_file(path):
    if not strict_regular(path, MAX_LINE):
        die("Snapshot de health ausente, não regular ou grande demais.", 66)
    try:
        obj = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        die("Snapshot de health inválido.", 64)
    if not isinstance(obj, dict):
        die("Snapshot de health precisa ser objeto JSON.", 64)
    return obj


def safe_number(value, default=0.0):
    if isinstance(value, bool):
        return default
    try:
        n = float(value)
    except (TypeError, ValueError):
        return default
    return n if math.isfinite(n) else default


def health_record(obj):
    node_id = obj.get("node_id", "")
    if not isinstance(node_id, str) or not NODE_RE.fullmatch(node_id):
        die("node_id inválido no snapshot de health.", 64)
    try:
        node_epoch = int(obj.get("node_epoch", 0))
        epoch = int(obj.get("received_at", 0))
    except (TypeError, ValueError):
        die("epoch inválido no snapshot de health.", 64)
    if node_epoch < 1 or epoch < 1:
        die("snapshot de health sem epoch válido.", 64)
    metrics = obj.get("metrics", {})
    if not isinstance(metrics, dict):
        die("métricas inválidas no snapshot de health.", 64)
    state = str(obj.get("base_state", "DEGRADED"))
    if state not in {"HEALTHY", "DEGRADED", "DRAINING", "OFFLINE"}:
        state = "DEGRADED"
    reason = str(obj.get("base_reason", "unknown"))[:96]
    return {
        "contract": HEALTH_CONTRACT,
        "epoch": epoch,
        "node_id": node_id,
        "node_epoch": node_epoch,
        "state": state,
        "reason": reason,
        "sessions": max(0, int(safe_number(metrics.get("sessions", 0)))),
        "max_sessions": max(0, int(safe_number(metrics.get("max_sessions", 0)))),
        "capacity": max(0, int(safe_number(metrics.get("capacity", 0)))),
        "weight": max(0, int(safe_number(metrics.get("weight", 0)))),
        "cpu_percent": round(safe_number(metrics.get("cpu_percent", 0)), 2),
        "memory_used_percent": round(safe_number(metrics.get("memory_used_percent", 0)), 2),
        "rtt_ms": round(safe_number(metrics.get("previous_rtt_ms", -1), -1), 2),
        "hive_network_peer_count": max(0, int(safe_number(metrics.get("hive_network_peer_count", 0)))),
    }


def json_line(obj):
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def iter_jsonl(path):
    if not strict_regular(path):
        return
    try:
        with open(path, "r", encoding="utf-8") as fh:
            for raw in fh:
                if len(raw) > MAX_LINE:
                    continue
                try:
                    obj = json.loads(raw)
                except json.JSONDecodeError:
                    continue
                if isinstance(obj, dict):
                    yield obj
    except (OSError, UnicodeDecodeError):
        return


def prune_locked(retention):
    if not strict_regular(HEALTH_HISTORY):
        return 0
    cutoff = int(time.time()) - retention
    kept = []
    for obj in iter_jsonl(HEALTH_HISTORY) or ():
        try:
            epoch = int(obj.get("epoch", 0))
        except (TypeError, ValueError):
            continue
        if epoch >= cutoff and obj.get("contract") == HEALTH_CONTRACT:
            kept.append(json_line(obj))
    atomic_write(HEALTH_HISTORY, ("\n".join(kept) + "\n") if kept else "", 0o600)
    return len(kept)


def record_health(path):
    init_dirs()
    expected = os.path.realpath(HEALTH_OBS_DIR) + os.sep
    real = os.path.realpath(path)
    if not real.startswith(expected):
        die("Snapshot de health fora do diretório gerenciado.", 64)
    record = health_record(read_json_file(real))
    retention = retention_seconds()
    with open(LOCK_FILE, "r+", encoding="utf-8") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        ensure_dir(DATA_DIR)
        fd = os.open(HEALTH_HISTORY, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        try:
            os.write(fd, (json_line(record) + "\n").encode("utf-8"))
            os.fsync(fd)
        finally:
            os.close(fd)
        os.chmod(HEALTH_HISTORY, 0o600)
        prune_locked(retention)
        fcntl.flock(lock.fileno(), fcntl.LOCK_UN)
    audit("health-recorded", node_id=record["node_id"], node_epoch=record["node_epoch"])


def audit(event, **fields):
    record = {"epoch": int(time.time()), "event": event}
    for key, value in fields.items():
        if isinstance(value, (str, int, float, bool)) or value is None:
            record[key] = value
    ensure_dir(os.path.dirname(AUDIT_FILE), 0o750)
    fd = os.open(AUDIT_FILE, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    try:
        os.write(fd, (json_line(record) + "\n").encode("utf-8"))
    finally:
        os.close(fd)


def tail_records_many(paths, limit, predicate=None, sanitizer=None, since=0):
    out = deque(maxlen=limit)
    for path in paths:
        for obj in iter_jsonl(path) or ():
            try:
                epoch = int(obj.get("epoch", obj.get("received_at", 0)))
            except (TypeError, ValueError):
                continue
            if epoch < since:
                continue
            if predicate and not predicate(obj):
                continue
            if sanitizer:
                obj = sanitizer(obj)
                if obj is None:
                    continue
            out.append(obj)
    return list(out)


def tail_records(path, limit, predicate=None, sanitizer=None, since=0):
    return tail_records_many([path], limit, predicate, sanitizer, since)


def audit_archive_files(kind):
    archive_dir = SCHED_ARCHIVE_DIR if kind == "scheduler" else LEASE_ARCHIVE_DIR
    if not os.path.isdir(archive_dir):
        return []
    return [str(path) for path in sorted(Path(archive_dir).glob("*.jsonl")) if strict_regular(str(path))]


def audit_source_paths(kind):
    if kind == "scheduler":
        active = SCHED_AUDIT
    elif kind == "leases":
        active = LEASE_AUDIT
    else:
        die("Fonte de audit inválida.", 64)
    paths = audit_archive_files(kind)
    if strict_regular(active):
        paths.append(active)
    return paths


def next_archive_path(kind, archive_dir):
    ensure_dir(archive_dir, 0o700)
    epoch = int(time.time())
    for seq in range(1000):
        path = os.path.join(archive_dir, f"{kind}-{epoch}-{seq:03d}.jsonl")
        if not os.path.lexists(path):
            return path
    die("Não foi possível reservar nome para segmento de audit.", 70)


def rotate_audit_locked(kind, active, archive_dir, max_bytes, force=False):
    if not strict_regular(active):
        return 0, ""
    try:
        size = os.path.getsize(active)
    except OSError:
        return 0, ""
    if size <= 0 or (not force and size < max_bytes):
        return 0, ""
    target = next_archive_path(kind, archive_dir)
    os.replace(active, target)
    os.chmod(target, 0o600)
    try:
        fd = os.open(active, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        os.close(fd)
    except FileExistsError:
        pass
    if os.path.exists(active):
        os.chmod(active, 0o600)
    return 1, target


def prune_audit_archives_locked(retention):
    cutoff = int(time.time()) - retention
    removed = {"scheduler": 0, "leases": 0}
    for kind, archive_dir in (("scheduler", SCHED_ARCHIVE_DIR), ("leases", LEASE_ARCHIVE_DIR)):
        if not os.path.isdir(archive_dir):
            continue
        for path in Path(archive_dir).glob("*.jsonl"):
            try:
                st = path.lstat()
            except FileNotFoundError:
                continue
            if not stat.S_ISREG(st.st_mode):
                continue
            if int(st.st_mtime) < cutoff:
                try:
                    path.unlink()
                    removed[kind] += 1
                except FileNotFoundError:
                    pass
    return removed


def audit_storage_stats(kind):
    active = SCHED_AUDIT if kind == "scheduler" else LEASE_AUDIT
    archives = audit_archive_files(kind)
    active_bytes = os.path.getsize(active) if strict_regular(active) else 0
    archive_bytes = 0
    for path in archives:
        try:
            archive_bytes += os.path.getsize(path)
        except OSError:
            pass
    return active_bytes, len(archives), archive_bytes


def audit_maintain(retention_value=None, max_bytes_value=None, force=False):
    init_dirs()
    retention = audit_retention_seconds(retention_value)
    max_bytes = audit_max_bytes(max_bytes_value)
    with open(LOCK_FILE, "r+", encoding="utf-8") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        sched_rotated, sched_path = rotate_audit_locked(
            "scheduler", SCHED_AUDIT, SCHED_ARCHIVE_DIR, max_bytes, force
        )
        lease_rotated, lease_path = rotate_audit_locked(
            "leases", LEASE_AUDIT, LEASE_ARCHIVE_DIR, max_bytes, force
        )
        removed = prune_audit_archives_locked(retention)
        fcntl.flock(lock.fileno(), fcntl.LOCK_UN)
    audit(
        "audit-maintain",
        retention_seconds=retention,
        max_bytes=max_bytes,
        scheduler_rotated=sched_rotated,
        leases_rotated=lease_rotated,
        scheduler_pruned=removed["scheduler"],
        leases_pruned=removed["leases"],
    )
    print(f"audit_retention_seconds={retention}")
    print(f"audit_max_bytes={max_bytes}")
    print(f"scheduler_rotated={sched_rotated}")
    print(f"leases_rotated={lease_rotated}")
    print(f"scheduler_pruned={removed['scheduler']}")
    print(f"leases_pruned={removed['leases']}")
    if sched_path:
        print(f"scheduler_archive={sched_path}")
    if lease_path:
        print(f"leases_archive={lease_path}")


def audit_status():
    init_dirs()
    retention = audit_retention_seconds()
    max_bytes = audit_max_bytes()
    sched_active, sched_segments, sched_archive = audit_storage_stats("scheduler")
    lease_active, lease_segments, lease_archive = audit_storage_stats("leases")
    print(f"contract={CONTRACT}")
    print(f"audit_retention_seconds={retention}")
    print(f"audit_max_bytes={max_bytes}")
    print(f"scheduler_active_bytes={sched_active}")
    print(f"scheduler_archive_segments={sched_segments}")
    print(f"scheduler_archive_bytes={sched_archive}")
    print(f"leases_active_bytes={lease_active}")
    print(f"leases_archive_segments={lease_segments}")
    print(f"leases_archive_bytes={lease_archive}")
    print("rotation_strategy=atomic-rename")
    print("archive_compression=0")
    print("controller_in_user_vpn_path=0")


def sanitize_scheduler(obj):
    allowed = {"epoch", "event", "node_id", "protocol", "region", "pool", "reason", "score", "sticky", "name", "country", "node_epoch"}
    return {k: obj[k] for k in allowed if k in obj}


def sanitize_lease(obj):
    allowed = {"epoch", "event", "identity_id", "product_id", "node_id", "global_lease_id", "local_session_id",
               "reason", "active", "max_sessions_global", "authority_epoch", "outage_started_epoch", "recovery_count",
               "previous_state", "seen_authority_epoch", "returned_authority_epoch", "removed", "global_epoch"}
    return {k: obj[k] for k in allowed if k in obj}


def validate_limit(value):
    return parse_int(value, "limit", 1, MAX_LIMIT)


def show_health(node_id, limit):
    if node_id not in ("", "*") and not NODE_RE.fullmatch(node_id):
        die("node_id inválido.", 64)
    pred = None if node_id in ("", "*") else lambda o: o.get("node_id") == node_id
    for obj in tail_records(HEALTH_HISTORY, limit, pred):
        print(json_line(obj))


def show_scheduler(limit):
    for obj in tail_records_many(audit_source_paths("scheduler"), limit, sanitizer=sanitize_scheduler):
        print(json_line(obj))


def show_leases(identity_id, limit):
    if identity_id not in ("", "*") and not IDENTITY_RE.fullmatch(identity_id):
        die("identity_id inválido.", 64)
    pred = None if identity_id in ("", "*") else lambda o: o.get("identity_id") == identity_id
    for obj in tail_records_many(audit_source_paths("leases"), limit, pred, sanitize_lease):
        print(json_line(obj))


def percentile95(values):
    values = sorted(v for v in values if math.isfinite(v) and v >= 0)
    if not values:
        return -1.0
    idx = max(0, math.ceil(len(values) * 0.95) - 1)
    return values[idx]


def summary(window):
    now = int(time.time())
    since = now - window
    health = tail_records(HEALTH_HISTORY, MAX_LIMIT, since=since)
    sched = tail_records_many(audit_source_paths("scheduler"), MAX_LIMIT, sanitizer=sanitize_scheduler, since=since)
    leases = tail_records_many(audit_source_paths("leases"), MAX_LIMIT, sanitizer=sanitize_lease, since=since)
    latest = {}
    rtts = []
    for item in health:
        latest[item.get("node_id", "")] = item
        rtt = safe_number(item.get("rtt_ms", -1), -1)
        if rtt >= 0:
            rtts.append(rtt)
    states = {"HEALTHY": 0, "DEGRADED": 0, "DRAINING": 0, "OFFLINE": 0}
    for item in latest.values():
        state = item.get("state", "DEGRADED")
        states[state if state in states else "DEGRADED"] += 1
    selections = sum(1 for x in sched if x.get("event") == "select")
    failovers = sum(1 for x in sched if x.get("event") == "select" and x.get("reason") == "sticky-failover")
    drains = sum(1 for x in sched if x.get("event") == "drain")
    undrains = sum(1 for x in sched if x.get("event") == "undrain")
    grants = sum(1 for x in leases if x.get("event") == "grant")
    denies = sum(1 for x in leases if x.get("event") == "deny")
    releases = sum(1 for x in leases if x.get("event") == "release")
    outages = sum(1 for x in leases if x.get("event") == "node-authority-outage")
    recoveries = sum(1 for x in leases if x.get("event") == "node-authority-recovered")
    fenced = sum(1 for x in leases if x.get("event") == "node-authority-fenced")
    avg = round(sum(rtts) / len(rtts), 2) if rtts else -1.0
    result = {
        "contract": CONTRACT,
        "generated_epoch": now,
        "window_seconds": window,
        "health_samples": len(health),
        "nodes_observed": len(latest),
        "nodes_healthy": states["HEALTHY"],
        "nodes_degraded": states["DEGRADED"],
        "nodes_draining": states["DRAINING"],
        "nodes_offline": states["OFFLINE"],
        "rtt_avg_ms": avg,
        "rtt_p95_ms": round(percentile95(rtts), 2),
        "scheduler_selections": selections,
        "scheduler_failovers": failovers,
        "drains": drains,
        "undrains": undrains,
        "lease_grants": grants,
        "lease_denies": denies,
        "lease_releases": releases,
        "authority_outages": outages,
        "authority_recoveries": recoveries,
        "authority_fenced": fenced,
        "controller_in_user_vpn_path": 0,
    }
    print(json_line(result))


def status():
    init_dirs()
    health_count = sum(1 for _ in iter_jsonl(HEALTH_HISTORY) or ())
    print(f"contract={CONTRACT}")
    print("enabled=1")
    print(f"health_history_entries={health_count}")
    print(f"health_history_file={HEALTH_HISTORY}")
    print(f"scheduler_audit_available={1 if strict_regular(SCHED_AUDIT) else 0}")
    print(f"lease_audit_available={1 if strict_regular(LEASE_AUDIT) else 0}")
    print(f"retention_seconds={retention_seconds()}")
    print(f"audit_retention_seconds={audit_retention_seconds()}")
    print(f"audit_max_bytes={audit_max_bytes()}")
    sched_active, sched_segments, sched_archive = audit_storage_stats("scheduler")
    lease_active, lease_segments, lease_archive = audit_storage_stats("leases")
    print(f"scheduler_active_bytes={sched_active}")
    print(f"scheduler_archive_segments={sched_segments}")
    print(f"scheduler_archive_bytes={sched_archive}")
    print(f"leases_active_bytes={lease_active}")
    print(f"leases_archive_segments={lease_segments}")
    print(f"leases_archive_bytes={lease_archive}")
    print("contains_private_keys=0")
    print("controller_in_user_vpn_path=0")


def prune(value=None):
    init_dirs()
    retention = retention_seconds(value)
    with open(LOCK_FILE, "r+", encoding="utf-8") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        kept = prune_locked(retention)
        fcntl.flock(lock.fileno(), fcntl.LOCK_UN)
    audit("prune", retention_seconds=retention, kept=kept)
    print(f"retention_seconds={retention}")
    print(f"health_history_entries={kept}")


def usage():
    print("Uso: hive_observability.sh --status|--summary [WINDOW]|--health [NODE|*] [LIMIT]|--scheduler [LIMIT]|--leases [IDENTITY|*] [LIMIT]|--prune [SECONDS]|--audit-status|--audit-maintain [RETENTION] [MAX_BYTES] [force]", file=sys.stderr)
    raise SystemExit(64)


args = sys.argv[1:]
cmd = args[0] if args else "--status"
if cmd == "--install":
    init_dirs(); status()
elif cmd == "--record-health":
    if len(args) != 2: usage()
    record_health(args[1])
elif cmd == "--status":
    status()
elif cmd == "--health":
    show_health(args[1] if len(args) > 1 else "*", validate_limit(args[2] if len(args) > 2 else DEFAULT_LIMIT))
elif cmd == "--scheduler":
    show_scheduler(validate_limit(args[1] if len(args) > 1 else DEFAULT_LIMIT))
elif cmd == "--leases":
    show_leases(args[1] if len(args) > 1 else "*", validate_limit(args[2] if len(args) > 2 else DEFAULT_LIMIT))
elif cmd == "--summary":
    summary(parse_int(args[1] if len(args) > 1 else DEFAULT_WINDOW, "window_seconds", 60, MAX_RETENTION))
elif cmd == "--prune":
    prune(args[1] if len(args) > 1 else None)
elif cmd == "--audit-status":
    audit_status()
elif cmd == "--audit-maintain":
    if len(args) > 4:
        usage()
    force = len(args) > 3 and args[3].lower() in {"1", "true", "yes", "force"}
    if len(args) > 3 and not force:
        die("Terceiro argumento deve ser 'force' quando informado.", 64)
    audit_maintain(args[1] if len(args) > 1 else None, args[2] if len(args) > 2 else None, force)
else:
    usage()
PY
