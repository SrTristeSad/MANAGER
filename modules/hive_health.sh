#!/usr/bin/env bash
set -Eeuo pipefail

MANAGER_HOME="${MANAGER_HOME:-/opt/manager}"
MANAGER_ETC="${MANAGER_ETC:-/etc/manager}"
# shellcheck source=/dev/null
source "$MANAGER_HOME/lib/common.sh"
require_root

command -v python3 >/dev/null 2>&1 || { err "Python 3 é necessário para heartbeat da Colmeia."; exit 69; }
command -v openssl >/dev/null 2>&1 || { err "OpenSSL é necessário para heartbeat da Colmeia."; exit 69; }

python3 - "$@" <<'PY'
import base64
import hashlib
import ipaddress
import json
import math
import os
import re
import shutil
import socket
import socketserver
import ssl
import stat
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

MANAGER_HOME = os.environ.get("MANAGER_HOME", "/opt/manager")
MANAGER_ETC = os.environ.get("MANAGER_ETC", "/etc/manager")
HIVE_DIR = os.path.join(MANAGER_ETC, "hive")
NODE_DIR = os.path.join(HIVE_DIR, "node")
NODE_KEY = os.path.join(NODE_DIR, "node.key")
NODE_ENROLLMENT = os.path.join(NODE_DIR, "enrollment.conf")
NODE_CONTROLLER_PUB = os.path.join(NODE_DIR, "controller.pub")
NODE_META = os.path.join(MANAGER_ETC, "connection", "node", "node.conf")
NODE_NETWORK = os.path.join(HIVE_DIR, "network", "network.conf")

CTRL_DIR = os.path.join(HIVE_DIR, "controller")
CTRL_KEY = os.path.join(CTRL_DIR, "controller.key")
CTRL_PUB = os.path.join(CTRL_DIR, "controller.pub")
CTRL_CONF = os.path.join(CTRL_DIR, "controller.conf")
CTRL_NODES = os.path.join(CTRL_DIR, "nodes")

HEALTH_DIR = os.path.join(HIVE_DIR, "health")
NODE_CLIENT_CONF = os.path.join(HEALTH_DIR, "node.conf")
CTRL_HEALTH_DIR = os.path.join(CTRL_DIR, "health")
CTRL_HEALTH_CONF = os.path.join(CTRL_HEALTH_DIR, "controller.conf")
CTRL_TLS_DIR = os.path.join(CTRL_HEALTH_DIR, "tls")
CTRL_TLS_KEY = os.path.join(CTRL_TLS_DIR, "server.key")
CTRL_TLS_CERT = os.path.join(CTRL_TLS_DIR, "server.crt")

DATA_DIR = os.environ.get("MANAGER_HIVE_HEALTH_DATA_DIR", "/var/lib/manager/hive-health")
OBS_DIR = os.path.join(DATA_DIR, "nodes")
REPLAY_DIR = os.path.join(DATA_DIR, "replay")
NODE_STATE = os.path.join(DATA_DIR, "node.state")
AUDIT_FILE = os.environ.get("MANAGER_HIVE_HEALTH_AUDIT_FILE", "/var/log/manager/hive-health-audit.jsonl")
SYSTEMD_DIR = os.environ.get("MANAGER_HIVE_HEALTH_SYSTEMD_DIR", "/etc/systemd/system")
NODE_SERVICE = os.path.join(SYSTEMD_DIR, "manager-hive-heartbeat.service")
NODE_TIMER = os.path.join(SYSTEMD_DIR, "manager-hive-heartbeat.timer")
CTRL_SERVICE = os.path.join(SYSTEMD_DIR, "manager-hive-health-controller.service")

HEARTBEAT_CONTRACT = "manager-hive-heartbeat-v1"
ACK_CONTRACT = "manager-hive-heartbeat-ack-v1"
NODE_STATUS_CONTRACT = "manager-hive-health-node-v1"
CTRL_STATUS_CONTRACT = "manager-hive-health-controller-v1"
VERSION = 1
DEFAULT_PORT = 9444
DEFAULT_INTERVAL = 30
DEFAULT_DEGRADED_AFTER = 75
DEFAULT_OFFLINE_AFTER = 180
AUTH_SKEW = 120
REPLAY_TTL = 600
MAX_MESSAGE = 65536
NODE_ID_RE = re.compile(r"^node-[a-f0-9]{16}$")
NONCE_RE = re.compile(r"^[A-Za-z0-9_-]{32,96}$")
FP_RE = re.compile(r"^SHA256:[a-f0-9]{64}$")
HOST_RE = re.compile(r"^(?=.{1,253}$)(?:[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?)$")
ALLOWED_PROTOCOLS = {"ssh", "wireguard", "openvpn"}
SERVICE_STATES = {"active", "inactive", "unavailable", "unknown"}
RATE_LOCK = threading.Lock()
RATE_BUCKETS = {}


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


def write_external_new(path, data):
    if not os.path.isabs(path):
        die("O arquivo de saída precisa usar caminho absoluto.", 64)
    parent = os.path.dirname(path)
    if not os.path.isdir(parent):
        die("O diretório de saída não existe.", 64)
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        die("O arquivo de saída já existe; recusando sobrescrever.", 65)
    try:
        if isinstance(data, str):
            data = data.encode("utf-8")
        os.write(fd, data)
        os.fsync(fd)
    finally:
        os.close(fd)
    os.chmod(path, 0o600)


def read_conf(path):
    data = {}
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        return data
    if not stat.S_ISREG(st.st_mode):
        die(f"Estado inválido: {path} não é arquivo regular.")
    with open(path, "r", encoding="utf-8") as fh:
        for raw in fh:
            raw = raw.rstrip("\n")
            if "=" in raw:
                key, value = raw.split("=", 1)
                data[key] = value
    return data


def strict_regular(path, max_size=MAX_MESSAGE):
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        die(f"Arquivo não encontrado: {path}", 66)
    if not stat.S_ISREG(st.st_mode) or st.st_size > max_size:
        die(f"Arquivo recusado: {path}", 64)


def json_load_bytes(raw):
    def bad_constant(_):
        raise ValueError("constant")
    try:
        value = json.loads(raw.decode("utf-8"), parse_constant=bad_constant)
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError):
        raise ValueError("JSON inválido")
    if not isinstance(value, dict):
        raise ValueError("mensagem precisa ser objeto JSON")
    return value


def read_json(path):
    strict_regular(path)
    try:
        return json_load_bytes(Path(path).read_bytes())
    except ValueError as exc:
        die(str(exc), 64)


def canonical(obj):
    clean = dict(obj)
    clean.pop("signature", None)
    return json.dumps(clean, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def sign(private_path, payload):
    if not os.path.isfile(private_path):
        die("Chave privada de assinatura da Colmeia não encontrada.", 69)
    dfd, dpath = tempfile.mkstemp(prefix="hive-health-data-")
    sfd, spath = tempfile.mkstemp(prefix="hive-health-sig-")
    os.close(sfd)
    try:
        os.fchmod(dfd, 0o600)
        with os.fdopen(dfd, "wb") as fh:
            fh.write(payload)
        proc = subprocess.run(["openssl", "pkeyutl", "-sign", "-inkey", private_path, "-rawin", "-in", dpath, "-out", spath],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=20, check=False)
        if proc.returncode != 0:
            die("Falha ao assinar heartbeat da Colmeia.")
        sig = Path(spath).read_bytes()
    finally:
        for path in (dpath, spath):
            try: os.unlink(path)
            except FileNotFoundError: pass
    if len(sig) != 64:
        die("Assinatura Ed25519 inválida.")
    return base64.b64encode(sig).decode("ascii")


def verify(pub_path, payload, signature_text):
    try:
        sig = base64.b64decode(signature_text.encode("ascii"), validate=True)
    except Exception:
        return False
    if len(sig) != 64:
        return False
    dfd, dpath = tempfile.mkstemp(prefix="hive-health-data-")
    sfd, spath = tempfile.mkstemp(prefix="hive-health-sig-")
    try:
        os.fchmod(dfd, 0o600); os.fchmod(sfd, 0o600)
        with os.fdopen(dfd, "wb") as fh: fh.write(payload)
        with os.fdopen(sfd, "wb") as fh: fh.write(sig)
        proc = subprocess.run(["openssl", "pkeyutl", "-verify", "-pubin", "-inkey", pub_path, "-rawin",
                               "-in", dpath, "-sigfile", spath], stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL, timeout=20, check=False)
        return proc.returncode == 0
    finally:
        for path in (dpath, spath):
            try: os.unlink(path)
            except FileNotFoundError: pass


def valid_fp(value):
    return isinstance(value, str) and FP_RE.fullmatch(value.lower().replace("sha256:", "SHA256:", 1)) is not None


def normalize_fp(value):
    value = value.strip().lower().replace("sha256:", "SHA256:", 1)
    if not FP_RE.fullmatch(value):
        die("Fingerprint TLS deve ser SHA256:<64 hex>.", 64)
    return value


def cert_fingerprint(path):
    proc = subprocess.run(["openssl", "x509", "-in", path, "-outform", "DER"], stdout=subprocess.PIPE,
                          stderr=subprocess.DEVNULL, timeout=10, check=False)
    if proc.returncode != 0 or not proc.stdout:
        die("Certificado TLS do heartbeat é inválido.")
    return "SHA256:" + hashlib.sha256(proc.stdout).hexdigest()


def controller_identity():
    conf = read_conf(CTRL_CONF)
    if not conf or not os.path.isfile(CTRL_KEY) or not os.path.isfile(CTRL_PUB):
        die("Inicialize o controlador da Colmeia primeiro.", 67)
    return conf


def node_enrollment():
    conf = read_conf(NODE_ENROLLMENT)
    if not conf or not os.path.isfile(NODE_KEY) or not os.path.isfile(NODE_CONTROLLER_PUB):
        die("Este nó precisa concluir o enrollment da Colmeia antes do heartbeat.", 67)
    node_id = conf.get("node_id", "")
    try: node_epoch = int(conf.get("node_epoch", "0"))
    except ValueError: node_epoch = 0
    if not NODE_ID_RE.fullmatch(node_id) or node_epoch < 1 or not conf.get("controller_id"):
        die("Enrollment local inválido.", 67)
    return conf, node_id, node_epoch


def controller_node(node_id):
    if not NODE_ID_RE.fullmatch(node_id):
        raise PermissionError("node_id inválido")
    conf_path = os.path.join(CTRL_NODES, node_id + ".conf")
    pub_path = os.path.join(CTRL_NODES, node_id + ".pub")
    conf = read_conf(conf_path)
    if not conf or not os.path.isfile(pub_path):
        raise PermissionError("nó desconhecido")
    try: epoch = int(conf.get("node_epoch", "0"))
    except ValueError: epoch = 0
    if conf.get("enabled") != "1" or conf.get("revoked_epoch", "0") != "0" or epoch < 1:
        raise PermissionError("nó revogado ou desabilitado")
    return conf, pub_path, epoch


def test_skip_systemd():
    value = os.environ.get("MANAGER_HIVE_HEALTH_SKIP_SYSTEMD", "0") == "1"
    if value and os.environ.get("GITHUB_ACTIONS") != "true" and os.environ.get("MANAGER_HIVE_HEALTH_ALLOW_TEST") != "1":
        die("SKIP_SYSTEMD é reservado para CI/testes explícitos.", 64)
    return value


def systemctl(*args, check=False):
    if test_skip_systemd():
        return 0
    proc = subprocess.run(["systemctl", *args], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                          timeout=30, check=False)
    if check and proc.returncode != 0:
        die("Falha ao atualizar serviço systemd da saúde da Colmeia.")
    return proc.returncode


def write_units(interval=None):
    ensure_dir(SYSTEMD_DIR, 0o755)
    if interval is None:
        c = read_conf(NODE_CLIENT_CONF)
        try: interval = int(c.get("interval_seconds", str(DEFAULT_INTERVAL)))
        except ValueError: interval = DEFAULT_INTERVAL
    node_service = f"""# MANAGER-HIVE-HEALTH v1
[Unit]
Description=MANAGER Hive signed heartbeat sender
After=network-online.target
ConditionPathExists={NODE_CLIENT_CONF}
ConditionPathExists={NODE_KEY}

[Service]
Type=oneshot
ExecStart={MANAGER_HOME}/modules/hive_health.sh --send
UMask=0077
PrivateTmp=true
NoNewPrivileges=true
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
PrivateDevices=true
RestrictSUIDSGID=true
"""
    node_timer = f"""# MANAGER-HIVE-HEALTH v1
[Unit]
Description=MANAGER Hive heartbeat timer

[Timer]
OnBootSec={interval}s
OnUnitActiveSec={interval}s
AccuracySec=5s
Persistent=false
Unit=manager-hive-heartbeat.service

[Install]
WantedBy=timers.target
"""
    ctrl_service = f"""# MANAGER-HIVE-HEALTH v1
[Unit]
Description=MANAGER Hive health controller TLS gateway
After=network-online.target
ConditionPathExists={CTRL_HEALTH_CONF}
ConditionPathExists={CTRL_TLS_CERT}
ConditionPathExists={CTRL_TLS_KEY}

[Service]
Type=simple
ExecStart={MANAGER_HOME}/modules/hive_health.sh --serve-controller
Restart=on-failure
RestartSec=2s
UMask=0077
PrivateTmp=true
NoNewPrivileges=true
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
PrivateDevices=true
RestrictSUIDSGID=true
ProtectSystem=full

[Install]
WantedBy=multi-user.target
"""
    atomic_write(NODE_SERVICE, node_service, 0o644)
    atomic_write(NODE_TIMER, node_timer, 0o644)
    atomic_write(CTRL_SERVICE, ctrl_service, 0o644)
    systemctl("daemon-reload")


def remove_owned_unit(path):
    if not os.path.lexists(path):
        return
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        return
    if not stat.S_ISREG(st.st_mode):
        die(f"Unidade externa/não regular encontrada; recusando remover: {path}", 65)
    try:
        first = Path(path).read_text(encoding="utf-8").splitlines()[0]
    except (UnicodeDecodeError, OSError, IndexError):
        die(f"Unidade externa encontrada; recusando remover: {path}", 65)
    if first != "# MANAGER-HIVE-HEALTH v1":
        die(f"Unidade não pertence ao MANAGER: {path}", 65)
    os.unlink(path)


def generate_tls():
    ensure_dir(CTRL_TLS_DIR)
    if os.path.exists(CTRL_TLS_KEY) != os.path.exists(CTRL_TLS_CERT):
        die("Estado TLS parcial do heartbeat; não sobrescrevendo material existente.", 65)
    if not os.path.exists(CTRL_TLS_KEY):
        tmp = tempfile.mkdtemp(prefix=".health-tls-", dir=CTRL_HEALTH_DIR)
        try:
            key = os.path.join(tmp, "server.key")
            cert = os.path.join(tmp, "server.crt")
            p1 = subprocess.run(["openssl", "genpkey", "-algorithm", "ED25519", "-out", key],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=20, check=False)
            p2 = subprocess.run(["openssl", "req", "-new", "-x509", "-key", key, "-out", cert, "-days", "825",
                                 "-subj", "/CN=manager-hive-health"], stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL, timeout=20, check=False) if p1.returncode == 0 else None
            if p1.returncode != 0 or p2 is None or p2.returncode != 0:
                die("Não foi possível gerar certificado TLS do heartbeat.")
            atomic_write(CTRL_TLS_KEY, Path(key).read_bytes())
            atomic_write(CTRL_TLS_CERT, Path(cert).read_bytes())
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
    return cert_fingerprint(CTRL_TLS_CERT)


def validate_bind(value):
    try:
        ipaddress.ip_address(value)
    except ValueError:
        die("BIND_IP deve ser IPv4/IPv6 literal válido.", 64)
    return value


def validate_host(value):
    if not isinstance(value, str) or not value or len(value) > 253 or any(ch.isspace() for ch in value) or "/" in value:
        die("Host do controlador inválido.", 64)
    try:
        ipaddress.ip_address(value)
        return value
    except ValueError:
        if not HOST_RE.fullmatch(value) or ".." in value:
            die("Host do controlador deve ser IP ou hostname válido.", 64)
    return value.lower()


def validate_port(value):
    try: port = int(value)
    except (TypeError, ValueError): die("Porta inválida.", 64)
    if port < 1024 or port > 65535:
        die("Porta deve estar entre 1024 e 65535.", 64)
    return port


def validate_interval(value):
    try: interval = int(value)
    except (TypeError, ValueError): die("Intervalo de heartbeat inválido.", 64)
    if interval < 10 or interval > 300:
        die("Intervalo deve estar entre 10 e 300 segundos.", 64)
    return interval


def controller_init():
    ctrl = controller_identity()
    ensure_dir(CTRL_HEALTH_DIR)
    fp = generate_tls()
    current = read_conf(CTRL_HEALTH_CONF)
    if not current:
        now = int(time.time())
        atomic_write(CTRL_HEALTH_CONF,
                     f"version=1\nenabled=0\ncontroller_id={ctrl['controller_id']}\nbind=127.0.0.1\nport={DEFAULT_PORT}\n"
                     f"tls_fingerprint={fp}\ndegraded_after_seconds={DEFAULT_DEGRADED_AFTER}\n"
                     f"offline_after_seconds={DEFAULT_OFFLINE_AFTER}\ncreated_epoch={now}\nupdated_epoch={now}\n")
    return read_conf(CTRL_HEALTH_CONF)


def write_controller_conf(conf, enabled=None, bind=None, port=None, fp=None, degraded=None, offline=None):
    now = int(time.time())
    created = conf.get("created_epoch", str(now))
    ctrl = controller_identity()
    text = (f"version=1\nenabled={enabled if enabled is not None else conf.get('enabled','0')}\n"
            f"controller_id={ctrl['controller_id']}\nbind={bind if bind is not None else conf.get('bind','127.0.0.1')}\n"
            f"port={port if port is not None else conf.get('port',str(DEFAULT_PORT))}\n"
            f"tls_fingerprint={fp if fp is not None else conf.get('tls_fingerprint','')}\n"
            f"degraded_after_seconds={degraded if degraded is not None else conf.get('degraded_after_seconds',str(DEFAULT_DEGRADED_AFTER))}\n"
            f"offline_after_seconds={offline if offline is not None else conf.get('offline_after_seconds',str(DEFAULT_OFFLINE_AFTER))}\n"
            f"created_epoch={created}\nupdated_epoch={now}\n")
    atomic_write(CTRL_HEALTH_CONF, text)
    return read_conf(CTRL_HEALTH_CONF)


def controller_enable(bind, port):
    conf = controller_init()
    bind = validate_bind(bind)
    port = validate_port(port)
    fp = generate_tls()
    conf = write_controller_conf(conf, enabled=1, bind=bind, port=port, fp=fp)
    write_units()
    systemctl("enable", "--now", "manager-hive-health-controller.service", check=True)
    print("controller_health_enabled=1")
    print(f"bind={bind}")
    print(f"port={port}")
    print("tls=TLSv1.3")
    print(f"tls_fingerprint={fp}")
    print("firewall_auto_open=0")


def controller_disable():
    conf = controller_init()
    write_controller_conf(conf, enabled=0)
    systemctl("disable", "--now", "manager-hive-health-controller.service")
    print("controller_health_enabled=0")


def controller_rotate_tls():
    conf = controller_init()
    for path in (CTRL_TLS_KEY, CTRL_TLS_CERT):
        try: os.unlink(path)
        except FileNotFoundError: pass
    fp = generate_tls()
    write_controller_conf(conf, fp=fp)
    if conf.get("enabled") == "1":
        write_units()
        systemctl("restart", "manager-hive-health-controller.service", check=True)
    print("tls_rotated=1")
    print(f"tls_fingerprint={fp}")


def controller_thresholds(degraded, offline):
    conf = controller_init()
    try: degraded = int(degraded); offline = int(offline)
    except ValueError: die("Thresholds devem ser inteiros em segundos.", 64)
    if degraded < 30 or degraded > 1800 or offline < degraded + 30 or offline > 3600:
        die("Use degraded entre 30-1800s e offline pelo menos 30s maior, até 3600s.", 64)
    write_controller_conf(conf, degraded=degraded, offline=offline)
    print(f"degraded_after_seconds={degraded}")
    print(f"offline_after_seconds={offline}")


def node_configure(host, port, fp, interval):
    enroll, node_id, node_epoch = node_enrollment()
    host = validate_host(host)
    port = validate_port(port)
    fp = normalize_fp(fp)
    interval = validate_interval(interval)
    ensure_dir(HEALTH_DIR)
    now = int(time.time())
    atomic_write(NODE_CLIENT_CONF,
                 f"version=1\nenabled=1\nnode_id={node_id}\nnode_epoch={node_epoch}\ncontroller_id={enroll['controller_id']}\n"
                 f"host={host}\nport={port}\ntls_fingerprint={fp}\ninterval_seconds={interval}\nupdated_epoch={now}\n")
    write_units(interval)
    systemctl("enable", "--now", "manager-hive-heartbeat.timer", check=True)
    print("heartbeat_configured=1")
    print(f"host={host}")
    print(f"port={port}")
    print(f"interval_seconds={interval}")
    print(f"tls_fingerprint={fp}")


def node_disable():
    conf = read_conf(NODE_CLIENT_CONF)
    if conf:
        conf["enabled"] = "0"
        now = int(time.time())
        atomic_write(NODE_CLIENT_CONF,
                     f"version=1\nenabled=0\nnode_id={conf.get('node_id','')}\nnode_epoch={conf.get('node_epoch','')}\n"
                     f"controller_id={conf.get('controller_id','')}\nhost={conf.get('host','')}\nport={conf.get('port','')}\n"
                     f"tls_fingerprint={conf.get('tls_fingerprint','')}\ninterval_seconds={conf.get('interval_seconds',str(DEFAULT_INTERVAL))}\nupdated_epoch={now}\n")
    systemctl("disable", "--now", "manager-hive-heartbeat.timer")
    print("heartbeat_enabled=0")


def command_output(args, timeout=10):
    try:
        proc = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, timeout=timeout, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return ""
    return proc.stdout if proc.returncode == 0 else ""


def service_state(candidates, available):
    if not available:
        return "unavailable"
    for name in candidates:
        if subprocess.run(["systemctl", "is-active", "--quiet", name], stdout=subprocess.DEVNULL,
                          stderr=subprocess.DEVNULL, timeout=5, check=False).returncode == 0:
            return "active"
    return "inactive"


def cpu_percent():
    def sample():
        try:
            parts = Path("/proc/stat").read_text(encoding="ascii").splitlines()[0].split()[1:]
            nums = [int(x) for x in parts]
        except Exception:
            return None
        idle = nums[3] + (nums[4] if len(nums) > 4 else 0)
        return sum(nums), idle
    first = sample()
    if first is None: return 0.0
    time.sleep(0.12)
    second = sample()
    if second is None: return 0.0
    total = second[0] - first[0]
    idle = second[1] - first[1]
    if total <= 0: return 0.0
    return round(max(0.0, min(100.0, (total - idle) * 100.0 / total)), 2)


def memory_metrics():
    values = {}
    try:
        for line in Path("/proc/meminfo").read_text(encoding="ascii").splitlines():
            if ":" not in line: continue
            key, rest = line.split(":", 1)
            token = rest.strip().split()[0]
            values[key] = int(token) * 1024
    except Exception:
        return 0, 0, 0.0
    total = values.get("MemTotal", 0)
    avail = values.get("MemAvailable", values.get("MemFree", 0))
    used_pct = round((total - avail) * 100.0 / total, 2) if total > 0 else 0.0
    return total, avail, max(0.0, min(100.0, used_pct))


def default_interface():
    out = command_output(["ip", "-4", "route", "show", "default"])
    for line in out.splitlines():
        fields = line.split()
        if "dev" in fields:
            idx = fields.index("dev")
            if idx + 1 < len(fields): return fields[idx + 1]
    out = command_output(["ip", "-6", "route", "show", "default"])
    for line in out.splitlines():
        fields = line.split()
        if "dev" in fields:
            idx = fields.index("dev")
            if idx + 1 < len(fields): return fields[idx + 1]
    return ""


def network_bytes(iface):
    if not iface: return 0, 0
    try:
        for line in Path("/proc/net/dev").read_text(encoding="ascii").splitlines():
            if ":" not in line: continue
            name, rest = line.split(":", 1)
            if name.strip() != iface: continue
            fields = rest.split()
            return int(fields[0]), int(fields[8])
    except Exception:
        pass
    return 0, 0


def last_rtt():
    state = read_conf(NODE_STATE)
    try: return float(state.get("rtt_ms", "-1"))
    except ValueError: return -1.0


def collect_metrics():
    meta = read_conf(NODE_META)
    protocols = []
    out = command_output([os.path.join(MANAGER_HOME, "modules", "node_metadata.sh"), "--capabilities"], timeout=15)
    caps = {}
    for line in out.splitlines():
        if "=" in line:
            k, v = line.split("=", 1); caps[k] = v
    for item in caps.get("protocols", "").split(","):
        if item in ALLOWED_PROTOCOLS and item not in protocols: protocols.append(item)
    sessions_out = command_output([os.path.join(MANAGER_HOME, "modules", "session_engine.sh"), "--list"], timeout=15)
    session_lines = [line for line in sessions_out.splitlines() if line.strip()]
    session_ids = set()
    for line in session_lines:
        session_ids.add(line.split("\t", 1)[0])
    try: load1, load5, load15 = [float(x) for x in Path("/proc/loadavg").read_text(encoding="ascii").split()[:3]]
    except Exception: load1 = load5 = load15 = 0.0
    total_mem, avail_mem, mem_pct = memory_metrics()
    iface = default_interface()
    rx, tx = network_bytes(iface)
    ssh_available = "ssh" in protocols
    wg_available = "wireguard" in protocols
    ovpn_available = "openvpn" in protocols
    net = read_conf(NODE_NETWORK)
    hive_service = service_state(["wg-quick@mgh0.service"], bool(net))
    try: peer_count = int(net.get("peer_count", "0")) if net else 0
    except ValueError: peer_count = 0
    try: max_sessions = int(caps.get("max_sessions", meta.get("max_sessions", "0") or "0"))
    except ValueError: max_sessions = 0
    try: capacity = int(caps.get("capacity", meta.get("capacity", "1") or "1"))
    except ValueError: capacity = 1
    try: weight = int(caps.get("weight", meta.get("weight", "1") or "1"))
    except ValueError: weight = 1
    try: node_enabled = int(caps.get("enabled", meta.get("enabled", "1") or "1"))
    except ValueError: node_enabled = 1
    return {
        "uptime_seconds": int(float(Path("/proc/uptime").read_text(encoding="ascii").split()[0])) if os.path.isfile("/proc/uptime") else 0,
        "cpu_percent": cpu_percent(), "cpu_count": os.cpu_count() or 1,
        "load1": round(load1, 3), "load5": round(load5, 3), "load15": round(load15, 3),
        "memory_total_bytes": total_mem, "memory_available_bytes": avail_mem, "memory_used_percent": mem_pct,
        "network_interface": iface, "network_rx_bytes": rx, "network_tx_bytes": tx,
        "sessions": len(session_lines), "session_identities": len(session_ids),
        "max_sessions": max(0, max_sessions), "capacity": max(1, capacity), "weight": max(1, weight),
        "node_enabled": 1 if node_enabled == 1 else 0, "protocols": protocols,
        "service_ssh": service_state(["ssh.service", "sshd.service"], ssh_available),
        "service_wireguard": service_state(["wg-quick@wg0.service"], wg_available),
        "service_openvpn": service_state(["openvpn-server@manager.service", "openvpn@manager.service"], ovpn_available),
        "hive_network_configured": 1 if net else 0, "hive_network_service": hive_service,
        "hive_network_peer_count": max(0, peer_count), "previous_rtt_ms": round(last_rtt(), 2),
    }


def make_heartbeat_object():
    enroll, node_id, node_epoch = node_enrollment()
    obj = {"contract": HEARTBEAT_CONTRACT, "version": VERSION, "controller_id": enroll["controller_id"],
           "node_id": node_id, "node_epoch": node_epoch, "issued_at": int(time.time()),
           "nonce": base64.urlsafe_b64encode(os.urandom(24)).decode("ascii").rstrip("="),
           "metrics": collect_metrics()}
    obj["signature"] = sign(NODE_KEY, canonical(obj))
    return obj


def heartbeat_file(out_path):
    obj = make_heartbeat_object()
    write_external_new(out_path, json.dumps(obj, sort_keys=True, separators=(",", ":")) + "\n")
    print(f"heartbeat_file={out_path}")
    print(f"node_id={obj['node_id']}")
    print(f"node_epoch={obj['node_epoch']}")


def finite_num(value, low, high, integer=False):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return False
    if not math.isfinite(float(value)):
        return False
    if integer and not isinstance(value, int):
        return False
    return low <= value <= high


def validate_metrics(metrics):
    expected = {"uptime_seconds","cpu_percent","cpu_count","load1","load5","load15","memory_total_bytes",
                "memory_available_bytes","memory_used_percent","network_interface","network_rx_bytes","network_tx_bytes",
                "sessions","session_identities","max_sessions","capacity","weight","node_enabled","protocols",
                "service_ssh","service_wireguard","service_openvpn","hive_network_configured","hive_network_service",
                "hive_network_peer_count","previous_rtt_ms"}
    if not isinstance(metrics, dict) or set(metrics) != expected:
        raise ValueError("métricas de heartbeat inválidas")
    for key in ("uptime_seconds","cpu_count","memory_total_bytes","memory_available_bytes","network_rx_bytes","network_tx_bytes",
                "sessions","session_identities","max_sessions","capacity","weight","hive_network_peer_count"):
        if not finite_num(metrics[key], 0, 2**63-1, integer=True): raise ValueError(f"métrica inválida: {key}")
    for key in ("cpu_percent","memory_used_percent"):
        if not finite_num(metrics[key], 0, 100): raise ValueError(f"métrica inválida: {key}")
    for key in ("load1","load5","load15"):
        if not finite_num(metrics[key], 0, 1000000): raise ValueError(f"métrica inválida: {key}")
    if not finite_num(metrics["previous_rtt_ms"], -1, 3600000): raise ValueError("métrica inválida: previous_rtt_ms")
    if metrics["node_enabled"] not in (0,1) or metrics["hive_network_configured"] not in (0,1): raise ValueError("flag de métrica inválida")
    if not isinstance(metrics["network_interface"], str) or len(metrics["network_interface"]) > 64: raise ValueError("interface inválida")
    protocols = metrics["protocols"]
    if not isinstance(protocols, list) or len(protocols) > 3 or len(protocols) != len(set(protocols)) or any(x not in ALLOWED_PROTOCOLS for x in protocols):
        raise ValueError("protocolos inválidos")
    for key in ("service_ssh","service_wireguard","service_openvpn","hive_network_service"):
        if metrics[key] not in SERVICE_STATES: raise ValueError(f"estado de serviço inválido: {key}")
    return metrics


def validate_heartbeat(obj, consume=True):
    expected = {"contract","version","controller_id","node_id","node_epoch","issued_at","nonce","metrics","signature"}
    if set(obj) != expected or obj.get("contract") != HEARTBEAT_CONTRACT or obj.get("version") != VERSION:
        raise ValueError("contrato de heartbeat inválido")
    ctrl = controller_identity()
    if obj.get("controller_id") != ctrl.get("controller_id"):
        raise PermissionError("heartbeat pertence a outro controlador")
    node_id = obj.get("node_id", "")
    conf, pub_path, epoch = controller_node(node_id)
    node_epoch = obj.get("node_epoch")
    if isinstance(node_epoch, bool) or not isinstance(node_epoch, int) or node_epoch != epoch:
        raise PermissionError("node_epoch obsoleto")
    issued_at = obj.get("issued_at")
    now = int(time.time())
    if isinstance(issued_at, bool) or not isinstance(issued_at, int) or abs(now - issued_at) > AUTH_SKEW:
        raise PermissionError("heartbeat fora da janela de freshness")
    nonce = obj.get("nonce")
    if not isinstance(nonce, str) or not NONCE_RE.fullmatch(nonce):
        raise ValueError("nonce inválido")
    metrics = validate_metrics(obj.get("metrics"))
    if not isinstance(obj.get("signature"), str) or not verify(pub_path, canonical(obj), obj.get("signature", "")):
        raise PermissionError("assinatura do heartbeat não confere")
    if consume:
        consume_nonce(node_id, nonce, issued_at)
    return conf, node_id, node_epoch, metrics


def prune_replay():
    cutoff = time.time() - REPLAY_TTL
    root = Path(REPLAY_DIR)
    if not root.exists(): return
    for path in root.rglob("*"):
        try:
            if path.is_file() and not path.is_symlink() and path.stat().st_mtime < cutoff: path.unlink()
        except OSError: pass
    for path in sorted(root.rglob("*"), key=lambda p: len(p.parts), reverse=True):
        try:
            if path.is_dir() and not any(path.iterdir()): path.rmdir()
        except OSError: pass


def consume_nonce(node_id, nonce, issued_at):
    nonce_hash = hashlib.sha256(nonce.encode("ascii")).hexdigest()
    base = os.path.join(REPLAY_DIR, node_id)
    ensure_dir(REPLAY_DIR); ensure_dir(base)
    path = os.path.join(base, nonce_hash)
    try:
        fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    except FileExistsError as exc:
        raise PermissionError("replay de heartbeat detectado") from exc
    try:
        os.write(fd, f"issued_at={issued_at}\nseen_at={int(time.time())}\n".encode("ascii")); os.fsync(fd)
    finally:
        os.close(fd)
    prune_replay()


def controller_threshold_values():
    conf = controller_init()
    try: degraded = int(conf.get("degraded_after_seconds", str(DEFAULT_DEGRADED_AFTER)))
    except ValueError: degraded = DEFAULT_DEGRADED_AFTER
    try: offline = int(conf.get("offline_after_seconds", str(DEFAULT_OFFLINE_AFTER)))
    except ValueError: offline = DEFAULT_OFFLINE_AFTER
    return degraded, offline


def base_health(metrics):
    if metrics.get("node_enabled") == 0:
        return "DRAINING", "node-disabled-local"
    protocols = set(metrics.get("protocols", []))
    mapping = {"ssh":"service_ssh", "wireguard":"service_wireguard", "openvpn":"service_openvpn"}
    for protocol in sorted(protocols):
        if metrics.get(mapping[protocol]) != "active":
            return "DEGRADED", f"service-{protocol}-inactive"
    if metrics.get("hive_network_configured") == 1 and metrics.get("hive_network_service") != "active":
        return "DEGRADED", "hive-network-inactive"
    if float(metrics.get("cpu_percent", 0)) >= 95.0:
        return "DEGRADED", "cpu-pressure"
    if float(metrics.get("memory_used_percent", 0)) >= 95.0:
        return "DEGRADED", "memory-pressure"
    max_sessions = int(metrics.get("max_sessions", 0))
    if max_sessions > 0 and int(metrics.get("sessions", 0)) >= max_sessions:
        return "DEGRADED", "session-capacity"
    return "HEALTHY", "ok"


def observation_path(node_id):
    return os.path.join(OBS_DIR, node_id + ".json")


def load_observation(node_id):
    path = observation_path(node_id)
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        return None
    if not stat.S_ISREG(st.st_mode) or st.st_size > MAX_MESSAGE:
        return None
    try:
        value = json_load_bytes(Path(path).read_bytes())
    except ValueError:
        return None
    return value


def derived_health(node_id, observation=None):
    try:
        conf, _, epoch = controller_node(node_id)
    except PermissionError as exc:
        return "OFFLINE", "authority-disabled", 0, None
    observation = observation if observation is not None else load_observation(node_id)
    if not observation:
        return "OFFLINE", "no-heartbeat", 0, None
    if observation.get("node_epoch") != epoch:
        return "OFFLINE", "epoch-mismatch", 0, observation
    try: seen = int(observation.get("received_at", 0))
    except (TypeError, ValueError): seen = 0
    age = max(0, int(time.time()) - seen) if seen else 2**31
    degraded_after, offline_after = controller_threshold_values()
    if age > offline_after:
        return "OFFLINE", "heartbeat-timeout", age, observation
    if age > degraded_after:
        return "DEGRADED", "heartbeat-delayed", age, observation
    state = observation.get("base_state", "DEGRADED")
    reason = observation.get("base_reason", "unknown")
    if state not in {"HEALTHY","DEGRADED","DRAINING"}:
        state, reason = "DEGRADED", "invalid-base-state"
    return state, reason, age, observation


def store_observation(node_id, node_epoch, issued_at, metrics, source):
    ensure_dir(OBS_DIR)
    state, reason = base_health(metrics)
    now = int(time.time())
    obs = {"version":1, "node_id":node_id, "node_epoch":node_epoch, "issued_at":issued_at,
           "received_at":now, "source":source, "base_state":state, "base_reason":reason, "metrics":metrics}
    atomic_write(observation_path(node_id), json.dumps(obs, sort_keys=True, separators=(",", ":")) + "\n")
    return state, reason, now


def audit(event, **fields):
    ensure_dir(os.path.dirname(AUDIT_FILE))
    record = {"epoch":int(time.time()), "event":event}
    for key, value in fields.items():
        if isinstance(value, (str,int,float,bool)) or value is None:
            record[key] = value
    line = (json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")
    fd = os.open(AUDIT_FILE, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    try: os.write(fd, line)
    finally: os.close(fd)


def make_ack(node_id, node_epoch, state, reason, received_at):
    ctrl = controller_identity()
    ack = {"contract":ACK_CONTRACT, "version":VERSION, "controller_id":ctrl["controller_id"], "node_id":node_id,
           "node_epoch":node_epoch, "received_at":received_at, "state":state, "reason":reason}
    ack["signature"] = sign(CTRL_KEY, canonical(ack))
    return ack


def validate_ack(ack, expected_node, expected_epoch, expected_controller):
    expected = {"contract","version","controller_id","node_id","node_epoch","received_at","state","reason","signature"}
    if set(ack) != expected or ack.get("contract") != ACK_CONTRACT or ack.get("version") != VERSION:
        die("ACK de heartbeat inválido.", 67)
    if ack.get("controller_id") != expected_controller or ack.get("node_id") != expected_node or ack.get("node_epoch") != expected_epoch:
        die("ACK foi emitido para outra autoridade/nó/epoch.", 67)
    if ack.get("state") not in {"HEALTHY","DEGRADED","DRAINING","OFFLINE"}:
        die("Estado inválido no ACK.", 67)
    if not verify(NODE_CONTROLLER_PUB, canonical(ack), ack.get("signature", "")):
        die("Assinatura do ACK do controlador não confere.", 67)
    return ack


def send_heartbeat_object(obj):
    conf = read_conf(NODE_CLIENT_CONF)
    if not conf or conf.get("enabled") != "1":
        die("Heartbeat do nó não está configurado/habilitado.", 67)
    enroll, node_id, node_epoch = node_enrollment()
    if conf.get("node_id") != node_id or conf.get("controller_id") != enroll.get("controller_id"):
        die("Configuração de heartbeat pertence a outro enrollment.", 67)
    try: configured_epoch = int(conf.get("node_epoch", "0"))
    except ValueError: configured_epoch = 0
    if configured_epoch != node_epoch:
        die("Configuração de heartbeat está cercada por node_epoch antigo; reconfigure o nó.", 67)
    host = validate_host(conf.get("host", "")); port = validate_port(conf.get("port", "")); fp = normalize_fp(conf.get("tls_fingerprint", ""))
    raw = (json.dumps(obj, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")
    if len(raw) > MAX_MESSAGE: die("Heartbeat excede limite de transporte.", 64)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.minimum_version = ssl.TLSVersion.TLSv1_3
    context.maximum_version = ssl.TLSVersion.TLSv1_3
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    start = time.monotonic()
    try:
        with socket.create_connection((host, port), timeout=8) as sock:
            with context.wrap_socket(sock, server_hostname=None) as tls:
                der = tls.getpeercert(binary_form=True)
                actual_fp = "SHA256:" + hashlib.sha256(der).hexdigest()
                if actual_fp != fp:
                    die("Fingerprint TLS do controlador não confere.", 67)
                tls.sendall(raw)
                fh = tls.makefile("rb")
                reply = fh.readline(MAX_MESSAGE + 1)
                if not reply or len(reply) > MAX_MESSAGE:
                    die("Resposta do controlador ausente ou grande demais.", 70)
    except SystemExit:
        raise
    except (OSError, ssl.SSLError) as exc:
        die(f"Falha no transporte TLS do heartbeat: {exc}", 69)
    rtt_ms = round((time.monotonic() - start) * 1000.0, 2)
    try: response = json_load_bytes(reply)
    except ValueError as exc: die(f"Resposta inválida do controlador: {exc}", 67)
    if response.get("accepted") != 1 or not isinstance(response.get("ack"), dict):
        die(f"Controlador recusou heartbeat: {response.get('error','erro remoto')}", 67)
    ack = validate_ack(response["ack"], node_id, node_epoch, enroll["controller_id"])
    ensure_dir(DATA_DIR)
    atomic_write(NODE_STATE,
                 f"version=1\nlast_success_epoch={int(time.time())}\nrtt_ms={rtt_ms}\ncontroller_state={ack['state']}\n"
                 f"controller_reason={ack['reason']}\nreceived_at={ack['received_at']}\n")
    print("heartbeat_accepted=1")
    print(f"node_id={node_id}")
    print(f"node_epoch={node_epoch}")
    print(f"state={ack['state']}")
    print(f"reason={ack['reason']}")
    print(f"rtt_ms={rtt_ms}")


def rate_allow(source):
    now = time.monotonic(); rate = 2.0; burst = 20.0
    with RATE_LOCK:
        tokens, last = RATE_BUCKETS.get(source, (burst, now))
        tokens = min(burst, tokens + max(0.0, now - last) * rate)
        if tokens < 1.0:
            RATE_BUCKETS[source] = (tokens, now); return False
        RATE_BUCKETS[source] = (tokens - 1.0, now); return True


class HealthHandler(socketserver.StreamRequestHandler):
    def handle(self):
        source = self.client_address[0]
        if not rate_allow(source):
            audit("reject", source=source, reason="rate-limit")
            return
        try:
            raw = self.rfile.readline(MAX_MESSAGE + 1)
            if not raw or len(raw) > MAX_MESSAGE:
                raise ValueError("mensagem ausente ou grande demais")
            obj = json_load_bytes(raw)
            _, node_id, node_epoch, metrics = validate_heartbeat(obj, consume=True)
            state, reason, received_at = store_observation(node_id, node_epoch, obj["issued_at"], metrics, source)
            ack = make_ack(node_id, node_epoch, state, reason, received_at)
            response = {"accepted":1, "ack":ack}
            audit("accepted", source=source, node_id=node_id, node_epoch=node_epoch, state=state, reason=reason)
        except PermissionError as exc:
            response = {"accepted":0, "error":str(exc)}
            audit("reject", source=source, reason=str(exc))
        except ValueError as exc:
            response = {"accepted":0, "error":str(exc)}
            audit("reject", source=source, reason=str(exc))
        except Exception:
            response = {"accepted":0, "error":"erro interno"}
            audit("reject", source=source, reason="internal-error")
        try:
            self.wfile.write((json.dumps(response, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8"))
            self.wfile.flush()
        except OSError:
            pass


class HealthServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True
    def __init__(self, address, handler, context, ipv6=False):
        if ipv6:
            self.address_family = socket.AF_INET6
        self.context = context
        super().__init__(address, handler)
    def get_request(self):
        sock, addr = super().get_request()
        try:
            return self.context.wrap_socket(sock, server_side=True), addr
        except Exception:
            sock.close(); raise


def serve_controller():
    conf = controller_init()
    if conf.get("enabled") != "1":
        die("Listener de saúde do controlador está desabilitado.", 67)
    bind = validate_bind(conf.get("bind", "")); port = validate_port(conf.get("port", ""))
    generate_tls()
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_3
    context.maximum_version = ssl.TLSVersion.TLSv1_3
    context.load_cert_chain(CTRL_TLS_CERT, CTRL_TLS_KEY)
    ipv6 = ipaddress.ip_address(bind).version == 6
    ensure_dir(DATA_DIR); ensure_dir(OBS_DIR); ensure_dir(REPLAY_DIR)
    with HealthServer((bind, port), HealthHandler, context, ipv6=ipv6) as server:
        server.serve_forever(poll_interval=0.5)


def controller_node_view(node_id):
    state, reason, age, obs = derived_health(node_id)
    conf_path = os.path.join(CTRL_NODES, node_id + ".conf")
    conf = read_conf(conf_path)
    print(f"contract={CTRL_STATUS_CONTRACT}")
    print(f"node_id={node_id}")
    print(f"node_epoch={conf.get('node_epoch','')}")
    print(f"authority_enabled={conf.get('enabled','0')}")
    print(f"state={state}")
    print(f"reason={reason}")
    print(f"heartbeat_age_seconds={age if obs else -1}")
    if not obs:
        print("last_heartbeat_epoch=0")
        return
    print(f"last_heartbeat_epoch={obs.get('received_at',0)}")
    print(f"source={obs.get('source','')}")
    metrics = obs.get("metrics", {})
    for key in sorted(metrics):
        value = metrics[key]
        if isinstance(value, list): value = ",".join(value)
        print(f"metric_{key}={value}")


def controller_list():
    controller_identity()
    print("node_id|state|reason|last_heartbeat|age_seconds|sessions|max_sessions|cpu_percent|memory_used_percent|rtt_ms")
    if not os.path.isdir(CTRL_NODES): return
    for path in sorted(Path(CTRL_NODES).glob("*.conf")):
        conf = read_conf(str(path)); node_id = conf.get("node_id", "")
        if not NODE_ID_RE.fullmatch(node_id): continue
        state, reason, age, obs = derived_health(node_id)
        metrics = obs.get("metrics", {}) if obs else {}
        last = obs.get("received_at", 0) if obs else 0
        print("|".join(str(x) for x in (node_id,state,reason,last,age if obs else -1,metrics.get("sessions",0),
                                        metrics.get("max_sessions",0),metrics.get("cpu_percent",0),
                                        metrics.get("memory_used_percent",0),metrics.get("previous_rtt_ms",-1))))


def controller_status():
    conf = controller_init(); fp = generate_tls()
    enabled = conf.get("enabled", "0"); service = "inactive"
    if not test_skip_systemd() and systemctl("is-active", "--quiet", "manager-hive-health-controller.service") == 0:
        service = "active"
    counts = {"HEALTHY":0,"DEGRADED":0,"DRAINING":0,"OFFLINE":0}
    total = 0
    if os.path.isdir(CTRL_NODES):
        for path in Path(CTRL_NODES).glob("*.conf"):
            node_id = read_conf(str(path)).get("node_id", "")
            if not NODE_ID_RE.fullmatch(node_id): continue
            state, _, _, _ = derived_health(node_id); counts[state] += 1; total += 1
    print(f"contract={CTRL_STATUS_CONTRACT}")
    print(f"controller_id={conf.get('controller_id','')}")
    print(f"enabled={enabled}")
    print(f"service={service}")
    print(f"bind={conf.get('bind','')}")
    print(f"port={conf.get('port','')}")
    print("tls=TLSv1.3")
    print(f"tls_fingerprint={fp}")
    print(f"degraded_after_seconds={conf.get('degraded_after_seconds','')}")
    print(f"offline_after_seconds={conf.get('offline_after_seconds','')}")
    print(f"nodes_registered={total}")
    for key in ("HEALTHY","DEGRADED","DRAINING","OFFLINE"):
        print(f"nodes_{key.lower()}={counts[key]}")
    print("signed_heartbeat=1")
    print("freshness=1")
    print("anti_replay=1")
    print("node_epoch_fencing=1")
    print("controller_in_user_vpn_path=0")
    print("firewall_auto_open=0")


def node_status():
    conf = read_conf(NODE_CLIENT_CONF); state = read_conf(NODE_STATE)
    timer = "inactive"
    if not test_skip_systemd() and systemctl("is-active", "--quiet", "manager-hive-heartbeat.timer") == 0:
        timer = "active"
    print(f"contract={NODE_STATUS_CONTRACT}")
    print(f"configured={1 if conf else 0}")
    print(f"enabled={conf.get('enabled','0') if conf else 0}")
    print(f"timer={timer}")
    for key in ("node_id","node_epoch","controller_id","host","port","tls_fingerprint","interval_seconds"):
        print(f"{key}={conf.get(key,'') if conf else ''}")
    print(f"last_success_epoch={state.get('last_success_epoch','0')}")
    print(f"rtt_ms={state.get('rtt_ms','-1')}")
    print(f"controller_state={state.get('controller_state','UNKNOWN')}")
    print(f"controller_reason={state.get('controller_reason','never-sent')}")
    print("heartbeat_signed=1")
    print("transport=TLSv1.3")
    print("tls_server_pinning=sha256")


def install_health():
    node_conf = read_conf(NODE_CLIENT_CONF)
    ctrl_conf = read_conf(CTRL_HEALTH_CONF)
    if node_conf or ctrl_conf:
        interval = DEFAULT_INTERVAL
        try: interval = int(node_conf.get("interval_seconds", str(DEFAULT_INTERVAL))) if node_conf else DEFAULT_INTERVAL
        except ValueError: pass
        write_units(interval)
    if node_conf and node_conf.get("enabled") == "1":
        systemctl("enable", "--now", "manager-hive-heartbeat.timer")
    if ctrl_conf and ctrl_conf.get("enabled") == "1":
        generate_tls(); systemctl("enable", "--now", "manager-hive-health-controller.service")


def detach_health():
    systemctl("disable", "--now", "manager-hive-heartbeat.timer")
    systemctl("stop", "manager-hive-heartbeat.service")
    systemctl("disable", "--now", "manager-hive-health-controller.service")
    for path in (NODE_TIMER, NODE_SERVICE, CTRL_SERVICE): remove_owned_unit(path)
    systemctl("daemon-reload")


def purge_health():
    detach_health()
    shutil.rmtree(HEALTH_DIR, ignore_errors=True)
    shutil.rmtree(CTRL_HEALTH_DIR, ignore_errors=True)
    shutil.rmtree(DATA_DIR, ignore_errors=True)
    try: os.unlink(AUDIT_FILE)
    except FileNotFoundError: pass


def usage():
    print("Uso: hive_health.sh {--status|--configure HOST PORT FP [INTERVAL]|--disable|--heartbeat OUT|--send|--send-file FILE|--controller-init|--controller-status|--controller-enable BIND [PORT]|--controller-disable|--controller-thresholds DEGRADED OFFLINE|--controller-rotate-tls|--controller-list|--controller-show NODE|--serve-controller}", file=sys.stderr)
    raise SystemExit(64)


def main(argv):
    cmd = argv[0] if argv else "--status"
    if cmd == "--status": node_status(); return
    if cmd == "--configure" and len(argv) in {4,5}:
        node_configure(argv[1], argv[2], argv[3], argv[4] if len(argv) == 5 else DEFAULT_INTERVAL); return
    if cmd == "--disable": node_disable(); return
    if cmd == "--heartbeat" and len(argv) == 2: heartbeat_file(argv[1]); return
    if cmd == "--send" and len(argv) == 1: send_heartbeat_object(make_heartbeat_object()); return
    if cmd == "--send-file" and len(argv) == 2: send_heartbeat_object(read_json(argv[1])); return
    if cmd == "--controller-init": conf = controller_init(); controller_status(); return
    if cmd == "--controller-status": controller_status(); return
    if cmd == "--controller-enable" and len(argv) in {2,3}: controller_enable(argv[1], argv[2] if len(argv) == 3 else DEFAULT_PORT); return
    if cmd == "--controller-disable": controller_disable(); return
    if cmd == "--controller-thresholds" and len(argv) == 3: controller_thresholds(argv[1], argv[2]); return
    if cmd == "--controller-rotate-tls": controller_rotate_tls(); return
    if cmd == "--controller-list": controller_list(); return
    if cmd == "--controller-show" and len(argv) == 2: controller_node_view(argv[1]); return
    if cmd == "--serve-controller": serve_controller(); return
    if cmd == "--install": install_health(); return
    if cmd == "--detach": detach_health(); return
    if cmd == "--purge": purge_health(); return
    usage()

main(sys.argv[1:])
PY
