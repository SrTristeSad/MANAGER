#!/usr/bin/env bash
set -Eeuo pipefail

MANAGER_HOME="${MANAGER_HOME:-/opt/manager}"
MANAGER_ETC="${MANAGER_ETC:-/etc/manager}"
# shellcheck source=/dev/null
source "$MANAGER_HOME/lib/common.sh"
require_root

command -v python3 >/dev/null 2>&1 || { err "Python 3 é necessário para o scheduler da Colmeia."; exit 69; }

python3 - "$@" <<'PY'
import hashlib
import json
import math
import os
import re
import shutil
import stat
import sys
import tempfile
import time
from pathlib import Path

MANAGER_ETC = os.environ.get("MANAGER_ETC", "/etc/manager")
CTRL_DIR = os.path.join(MANAGER_ETC, "hive", "controller")
CTRL_NODES = os.path.join(CTRL_DIR, "nodes")
CTRL_HEALTH_CONF = os.path.join(CTRL_DIR, "health", "controller.conf")
SCHED_DIR = os.path.join(CTRL_DIR, "scheduler")
PLACEMENT_DIR = os.path.join(SCHED_DIR, "nodes")
HEALTH_DATA = os.environ.get("MANAGER_HIVE_HEALTH_DATA_DIR", "/var/lib/manager/hive-health")
OBS_DIR = os.path.join(HEALTH_DATA, "nodes")
RUNTIME_DIR = os.environ.get("MANAGER_HIVE_SCHEDULER_DATA_DIR", "/var/lib/manager/hive-scheduler")
STICKY_DIR = os.path.join(RUNTIME_DIR, "sticky")
AUDIT_FILE = os.environ.get("MANAGER_HIVE_SCHEDULER_AUDIT_FILE", "/var/log/manager/hive-scheduler-audit.jsonl")
GLOBAL_LEASE_CONF = os.path.join(CTRL_DIR, "leases", "controller.conf")

STATUS_CONTRACT = "manager-hive-scheduler-v1"
SELECTION_CONTRACT = "manager-hive-scheduler-selection-v1"
NODE_ID_RE = re.compile(r"^node-[a-f0-9]{16}$")
LABEL_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$")
NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$")
ALLOWED_PROTOCOLS = {"ssh", "wireguard", "openvpn"}
DEFAULT_DEGRADED_AFTER = 75
MAX_JSON = 65536


def die(message, code=70):
    print(message, file=sys.stderr)
    raise SystemExit(code)


def ensure_dir(path, mode=0o700):
    os.makedirs(path, mode=mode, exist_ok=True)
    os.chmod(path, mode)


def atomic_write(path, data, mode=0o600):
    ensure_dir(os.path.dirname(path))
    fd, tmp = tempfile.mkstemp(prefix=".tmp-", dir=os.path.dirname(path))
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "wb") as fh:
            if isinstance(data, str):
                data = data.encode("utf-8")
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


def read_conf(path):
    out = {}
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        return out
    if not stat.S_ISREG(st.st_mode):
        return out
    try:
        with open(path, "r", encoding="utf-8") as fh:
            for raw in fh:
                raw = raw.rstrip("\n")
                if "=" in raw:
                    k, v = raw.split("=", 1)
                    out[k] = v
    except (OSError, UnicodeDecodeError):
        return {}
    return out


def read_json(path):
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        return None
    if not stat.S_ISREG(st.st_mode) or st.st_size > MAX_JSON:
        return None
    try:
        value = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        return None
    return value if isinstance(value, dict) else None


def identity_path(node_id):
    return os.path.join(CTRL_NODES, node_id + ".conf")


def placement_path(node_id):
    return os.path.join(PLACEMENT_DIR, node_id + ".conf")


def observation_path(node_id):
    return os.path.join(OBS_DIR, node_id + ".json")


def validate_node_id(node_id):
    if not NODE_ID_RE.fullmatch(node_id):
        die("node_id inválido.", 64)
    return node_id


def identity(node_id):
    validate_node_id(node_id)
    conf = read_conf(identity_path(node_id))
    if not conf:
        die("Nó não está enrolled neste controlador.", 66)
    return conf


def valid_label(value, field, allow_empty=True):
    if value in ("", "-", "*") and allow_empty:
        return ""
    if not isinstance(value, str) or not LABEL_RE.fullmatch(value):
        die(f"{field} inválido; use label simples até 64 caracteres.", 64)
    return value


def init_scheduler():
    ensure_dir(SCHED_DIR)
    ensure_dir(PLACEMENT_DIR)
    ensure_dir(RUNTIME_DIR)
    ensure_dir(STICKY_DIR)
    return True


def write_placement(node_id, name, country, region, pool, draining=None, reason=None):
    current = read_conf(placement_path(node_id))
    now = int(time.time())
    created = current.get("created_epoch", str(now))
    if draining is None:
        draining = current.get("draining", "0")
    if reason is None:
        reason = current.get("drain_reason", "")
    text = (
        f"version=1\nnode_id={node_id}\nname={name}\ncountry={country}\nregion={region}\npool={pool}\n"
        f"draining={draining}\ndrain_reason={reason}\ncreated_epoch={created}\nupdated_epoch={now}\n"
    )
    atomic_write(placement_path(node_id), text)
    return read_conf(placement_path(node_id))


def set_placement(node_id, name, country, region, pool):
    init_scheduler()
    identity(node_id)
    if not NAME_RE.fullmatch(name):
        die("Nome do nó inválido; use label simples até 64 caracteres.", 64)
    country = valid_label(country, "country")
    region = valid_label(region, "region")
    pool = valid_label(pool, "pool")
    # Node aliases are controller-authoritative and must be unique.
    for path in Path(PLACEMENT_DIR).glob("*.conf"):
        p = read_conf(str(path))
        if p.get("node_id") != node_id and p.get("name") == name:
            die("Nome de nó já está atribuído a outro node_id.", 65)
    conf = write_placement(node_id, name, country, region, pool)
    audit("placement", node_id=node_id, name=name, country=country, region=region, pool=pool)
    print("placement_updated=1")
    for key in ("node_id", "name", "country", "region", "pool", "draining"):
        print(f"{key}={conf.get(key,'')}")


def resolve_node(ref):
    if NODE_ID_RE.fullmatch(ref):
        identity(ref)
        return ref
    if not NAME_RE.fullmatch(ref):
        die("Referência de nó inválida.", 64)
    matches = []
    if os.path.isdir(PLACEMENT_DIR):
        for path in Path(PLACEMENT_DIR).glob("*.conf"):
            p = read_conf(str(path))
            if p.get("name") == ref and NODE_ID_RE.fullmatch(p.get("node_id", "")):
                matches.append(p["node_id"])
    if len(matches) != 1:
        die("Nome de nó não encontrado ou ambíguo no scheduler.", 66)
    return matches[0]


def set_drain(ref, enabled, reason=""):
    init_scheduler()
    node_id = resolve_node(ref)
    ident = identity(node_id)
    current = read_conf(placement_path(node_id))
    name = current.get("name", node_id)
    country = current.get("country", "")
    region = current.get("region", "")
    pool = current.get("pool", "")
    if reason:
        reason = valid_label(reason, "motivo de drain", allow_empty=False)
    if not enabled:
        reason = ""
    conf = write_placement(node_id, name, country, region, pool, "1" if enabled else "0", reason)
    audit("drain" if enabled else "undrain", node_id=node_id, node_epoch=ident.get("node_epoch", ""), reason=reason)
    print(f"draining={1 if enabled else 0}")
    print(f"node_id={node_id}")
    print(f"name={conf.get('name','')}")
    print("existing_sessions_terminated=0")
    print("new_allocations_allowed=0" if enabled else "new_allocations_allowed=1")


def thresholds():
    conf = read_conf(CTRL_HEALTH_CONF)
    try:
        degraded = int(conf.get("degraded_after_seconds", str(DEFAULT_DEGRADED_AFTER)))
    except ValueError:
        degraded = DEFAULT_DEGRADED_AFTER
    return max(1, degraded)


def placement(node_id):
    return read_conf(placement_path(node_id))


def health_state(node_id, ident, obs):
    if ident.get("enabled") != "1" or ident.get("revoked_epoch", "0") != "0":
        return "OFFLINE", "authority-disabled", 2**31
    if not obs:
        return "OFFLINE", "no-heartbeat", 2**31
    try:
        epoch = int(ident.get("node_epoch", "0"))
    except ValueError:
        epoch = 0
    if obs.get("node_epoch") != epoch:
        return "OFFLINE", "epoch-mismatch", 2**31
    try:
        seen = int(obs.get("received_at", 0))
    except (TypeError, ValueError):
        seen = 0
    age = max(0, int(time.time()) - seen) if seen else 2**31
    if age > thresholds():
        return "DEGRADED", "heartbeat-delayed", age
    state = obs.get("base_state", "DEGRADED")
    reason = obs.get("base_reason", "unknown")
    if state not in {"HEALTHY", "DEGRADED", "DRAINING"}:
        return "DEGRADED", "invalid-base-state", age
    return state, reason, age


def protocol_service_key(protocol):
    return {"ssh": "service_ssh", "wireguard": "service_wireguard", "openvpn": "service_openvpn"}[protocol]


def parse_scope(value):
    if value in ("", "*"):
        return None
    nodes = set()
    for part in value.split(","):
        validate_node_id(part)
        nodes.add(part)
    return nodes


def sticky_path(key):
    digest = hashlib.sha256(key.encode("utf-8")).hexdigest()
    return os.path.join(STICKY_DIR, digest + ".conf")


def sticky_node(key):
    if not key:
        return ""
    return read_conf(sticky_path(key)).get("node_id", "")


def save_sticky(key, node_id):
    if not key:
        return
    now = int(time.time())
    atomic_write(sticky_path(key), f"version=1\nnode_id={node_id}\nupdated_epoch={now}\n")


def candidate_for(node_id, protocol, region, pool, scope):
    try:
        ident = identity(node_id)
    except SystemExit:
        return None
    if scope is not None and node_id not in scope:
        return None
    p = placement(node_id)
    if p.get("draining") == "1":
        return None
    if region and p.get("region") != region:
        return None
    if pool and p.get("pool") != pool:
        return None
    obs = read_json(observation_path(node_id))
    state, reason, age = health_state(node_id, ident, obs)
    if state != "HEALTHY":
        return None
    metrics = obs.get("metrics") if isinstance(obs, dict) else None
    if not isinstance(metrics, dict):
        return None
    protocols = metrics.get("protocols")
    if not isinstance(protocols, list) or protocol not in protocols:
        return None
    if metrics.get(protocol_service_key(protocol)) != "active":
        return None
    try:
        sessions = max(0, int(metrics.get("sessions", 0)))
        max_sessions = max(0, int(metrics.get("max_sessions", 0)))
        capacity = max(1, int(metrics.get("capacity", 1)))
        weight = max(1, int(metrics.get("weight", 1)))
        rtt = float(metrics.get("previous_rtt_ms", -1))
    except (TypeError, ValueError):
        return None
    if max_sessions > 0 and sessions >= max_sessions:
        return None
    if not math.isfinite(rtt) or rtt < 0:
        rtt = 999999.0
    effective = max_sessions if max_sessions > 0 else capacity
    load_score = (sessions + 1.0) / (max(1, effective) * weight)
    score = load_score + min(rtt, 999999.0) / 1_000_000.0
    return {
        "node_id": node_id, "name": p.get("name", node_id), "country": p.get("country", ""),
        "region": p.get("region", ""), "pool": p.get("pool", ""), "state": state, "reason": reason,
        "heartbeat_age": age, "sessions": sessions, "max_sessions": max_sessions, "capacity": capacity,
        "weight": weight, "rtt_ms": rtt, "score": score,
    }


def all_node_ids():
    if not os.path.isdir(CTRL_NODES):
        return []
    out = []
    for path in Path(CTRL_NODES).glob("*.conf"):
        node_id = path.stem
        if NODE_ID_RE.fullmatch(node_id):
            out.append(node_id)
    return sorted(set(out))


def choose(protocol, region="", pool="", sticky="", node_scope="*"):
    init_scheduler()
    if protocol not in ALLOWED_PROTOCOLS:
        die("Protocolo inválido; use ssh, wireguard ou openvpn.", 64)
    region = "" if region in ("", "*") else valid_label(region, "region", allow_empty=False)
    pool = "" if pool in ("", "*") else valid_label(pool, "pool", allow_empty=False)
    if sticky and (len(sticky) > 128 or any(ord(ch) < 32 for ch in sticky)):
        die("Sticky key inválida.", 64)
    scope = parse_scope(node_scope)
    candidates = []
    for node_id in all_node_ids():
        c = candidate_for(node_id, protocol, region, pool, scope)
        if c:
            candidates.append(c)
    if not candidates:
        audit("select-denied", protocol=protocol, region=region, pool=pool, reason="no-eligible-node")
        die("Nenhum nó HEALTHY/elegível atende aos filtros solicitados.", 67)

    by_id = {c["node_id"]: c for c in candidates}
    previous = sticky_node(sticky)
    sticky_hit = bool(sticky and previous in by_id)
    if sticky_hit:
        selected = by_id[previous]
        selection_reason = "sticky-eligible"
    else:
        # Weighted least-loaded. Latency is only a small secondary component; node_id makes ties deterministic.
        selected = min(candidates, key=lambda c: (round(c["score"], 12), c["rtt_ms"], c["node_id"]))
        selection_reason = "weighted-least-loaded" if not previous else "sticky-failover"
        save_sticky(sticky, selected["node_id"])

    audit("select", node_id=selected["node_id"], protocol=protocol, region=region, pool=pool,
          reason=selection_reason, score=round(selected["score"], 12), sticky=bool(sticky))
    print(f"contract={SELECTION_CONTRACT}")
    print(f"selected_node={selected['node_id']}")
    print(f"selected_name={selected['name']}")
    print(f"state={selected['state']}")
    print(f"protocol={protocol}")
    print(f"country={selected['country']}")
    print(f"region={selected['region']}")
    print(f"pool={selected['pool']}")
    print(f"sessions={selected['sessions']}")
    print(f"max_sessions={selected['max_sessions']}")
    print(f"capacity={selected['capacity']}")
    print(f"weight={selected['weight']}")
    print(f"rtt_ms={selected['rtt_ms']}")
    print(f"score={selected['score']:.12f}")
    print(f"selection_reason={selection_reason}")
    print(f"sticky={1 if sticky else 0}")
    print(f"sticky_hit={1 if sticky_hit else 0}")
    print("existing_sessions_modified=0")
    print("global_lease_authority=1")
    print("controller_in_user_vpn_path=0")


def node_view(ref):
    init_scheduler()
    node_id = resolve_node(ref)
    ident = identity(node_id)
    p = placement(node_id)
    obs = read_json(observation_path(node_id))
    state, reason, age = health_state(node_id, ident, obs)
    print("contract=manager-hive-scheduler-node-v1")
    print(f"node_id={node_id}")
    print(f"name={p.get('name',node_id)}")
    print(f"country={p.get('country','')}")
    print(f"region={p.get('region','')}")
    print(f"pool={p.get('pool','')}")
    print(f"draining={p.get('draining','0')}")
    print(f"drain_reason={p.get('drain_reason','')}")
    print(f"health={state}")
    print(f"health_reason={reason}")
    print(f"heartbeat_age_seconds={age}")
    metrics = obs.get("metrics", {}) if isinstance(obs, dict) else {}
    for key in ("sessions", "max_sessions", "capacity", "weight", "previous_rtt_ms"):
        print(f"{key}={metrics.get(key,'')}")
    protocols = metrics.get("protocols", []) if isinstance(metrics, dict) else []
    print("protocols=" + ",".join(protocols) if isinstance(protocols, list) else "protocols=")


def list_nodes():
    init_scheduler()
    print("node_id|name|country|region|pool|draining|health|sessions|max_sessions|capacity|weight|rtt_ms")
    for node_id in all_node_ids():
        ident = read_conf(identity_path(node_id))
        p = placement(node_id)
        obs = read_json(observation_path(node_id))
        state, _, _ = health_state(node_id, ident, obs)
        metrics = obs.get("metrics", {}) if isinstance(obs, dict) else {}
        row = [node_id, p.get("name", node_id), p.get("country", ""), p.get("region", ""), p.get("pool", ""),
               p.get("draining", "0"), state, str(metrics.get("sessions", "")), str(metrics.get("max_sessions", "")),
               str(metrics.get("capacity", "")), str(metrics.get("weight", "")), str(metrics.get("previous_rtt_ms", ""))]
        print("|".join(row))


def global_lease_controller_enabled():
    return 1 if read_conf(GLOBAL_LEASE_CONF).get("enabled") == "1" else 0


def status():
    init_scheduler()
    nodes = all_node_ids()
    healthy = draining = 0
    for node_id in nodes:
        ident = read_conf(identity_path(node_id))
        p = placement(node_id)
        obs = read_json(observation_path(node_id))
        state, _, _ = health_state(node_id, ident, obs)
        if state == "HEALTHY":
            healthy += 1
        if p.get("draining") == "1":
            draining += 1
    print(f"contract={STATUS_CONTRACT}")
    print("scheduler=weighted-least-loaded")
    print("sticky_session=1")
    print("drain_runtime=1")
    print("selection_failover=1")
    print("placement_authority=controller-admin")
    print(f"nodes_registered={len(nodes)}")
    print(f"nodes_healthy={healthy}")
    print(f"nodes_draining={draining}")
    print("global_lease_authority=1")
    print(f"global_lease_controller_enabled={global_lease_controller_enabled()}")
    print("global_max_sessions=1")
    print("controller_in_user_vpn_path=0")


def audit(event, **fields):
    ensure_dir(os.path.dirname(AUDIT_FILE))
    record = {"epoch": int(time.time()), "event": event}
    for key, value in fields.items():
        if isinstance(value, (str, int, float, bool)) or value is None:
            record[key] = value
    line = (json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")
    fd = os.open(AUDIT_FILE, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    try:
        os.write(fd, line)
    finally:
        os.close(fd)


def purge():
    shutil.rmtree(SCHED_DIR, ignore_errors=True)
    shutil.rmtree(RUNTIME_DIR, ignore_errors=True)
    try:
        os.unlink(AUDIT_FILE)
    except FileNotFoundError:
        pass


def usage():
    print("Uso: hive_scheduler.sh {--status|--list|--show NODE|--placement NODE NAME COUNTRY REGION POOL|--drain NODE [REASON]|--undrain NODE|--select PROTOCOL [REGION] [POOL] [STICKY] [NODE_SCOPE]|--install|--purge}", file=sys.stderr)
    raise SystemExit(64)


def main(argv):
    cmd = argv[0] if argv else "--status"
    if cmd in {"--status"}: status(); return
    if cmd in {"--install", "--init"}: init_scheduler(); return
    if cmd == "--list": list_nodes(); return
    if cmd == "--show" and len(argv) == 2: node_view(argv[1]); return
    if cmd == "--placement" and len(argv) == 6: set_placement(argv[1], argv[2], argv[3], argv[4], argv[5]); return
    if cmd == "--drain" and len(argv) in {2, 3}: set_drain(argv[1], True, argv[2] if len(argv) == 3 else "admin-drain"); return
    if cmd == "--undrain" and len(argv) == 2: set_drain(argv[1], False); return
    if cmd == "--select" and 2 <= len(argv) <= 6:
        choose(argv[1], argv[2] if len(argv) > 2 else "", argv[3] if len(argv) > 3 else "",
               argv[4] if len(argv) > 4 else "", argv[5] if len(argv) > 5 else "*"); return
    if cmd == "--purge": purge(); return
    if cmd == "--detach": return
    usage()

main(sys.argv[1:])
PY
