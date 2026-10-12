#!/usr/bin/env bash
set -Eeuo pipefail

MANAGER_HOME="${MANAGER_HOME:-/opt/manager}"
MANAGER_ETC="${MANAGER_ETC:-/etc/manager}"
# shellcheck source=/dev/null
source "$MANAGER_HOME/lib/common.sh"
require_root

command -v python3 >/dev/null 2>&1 || { err "Python 3 é necessário para leases globais da Colmeia."; exit 69; }
command -v openssl >/dev/null 2>&1 || { err "OpenSSL é necessário para leases globais da Colmeia."; exit 69; }

python3 - "$@" <<'PY'
import base64
import fcntl
import hashlib
import ipaddress
import json
import os
import re
import secrets
import shutil
import socket
import socketserver
import ssl
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path

MANAGER_HOME = os.environ.get("MANAGER_HOME", "/opt/manager")
MANAGER_ETC = os.environ.get("MANAGER_ETC", "/etc/manager")
HIVE_DIR = os.path.join(MANAGER_ETC, "hive")
NODE_DIR = os.path.join(HIVE_DIR, "node")
NODE_KEY = os.path.join(NODE_DIR, "node.key")
NODE_ENROLLMENT = os.path.join(NODE_DIR, "enrollment.conf")

CTRL_DIR = os.path.join(HIVE_DIR, "controller")
CTRL_CONF = os.path.join(CTRL_DIR, "controller.conf")
CTRL_NODES = os.path.join(CTRL_DIR, "nodes")
LEASE_ETC = os.path.join(CTRL_DIR, "leases")
CTRL_LEASE_CONF = os.path.join(LEASE_ETC, "controller.conf")
LIMIT_DIR = os.path.join(LEASE_ETC, "limits")
TLS_DIR = os.path.join(LEASE_ETC, "tls")
TLS_KEY = os.path.join(TLS_DIR, "server.key")
TLS_CERT = os.path.join(TLS_DIR, "server.crt")
NODE_LEASE_DIR = os.path.join(HIVE_DIR, "leases")
NODE_CONF = os.path.join(NODE_LEASE_DIR, "node.conf")

DATA_DIR = os.environ.get("MANAGER_HIVE_LEASE_DATA_DIR", "/var/lib/manager/hive-leases")
ACTIVE_DIR = os.path.join(DATA_DIR, "active")
EPOCH_DIR = os.path.join(DATA_DIR, "epochs")
REPLAY_DIR = os.path.join(DATA_DIR, "replay")
NODE_AUTH_STATE = os.path.join(DATA_DIR, "node-authority.state")
LOCK_FILE = os.path.join(DATA_DIR, ".lock")
AUDIT_FILE = os.environ.get("MANAGER_HIVE_LEASE_AUDIT_FILE", "/var/log/manager/hive-lease-audit.jsonl")
ALLOCATION_OUTBOX_DIR = os.environ.get("MANAGER_HIVE_ALLOCATION_OUTBOX_DIR", "/var/lib/manager/hive-allocations/controller/outbox")
ALLOCATION_RESULT_DIR = os.environ.get("MANAGER_HIVE_ALLOCATION_RESULT_DIR", "/var/lib/manager/hive-allocations/controller/results")
ACCOUNTING_ETC = os.path.join(CTRL_DIR, "accounting")
ACCOUNTING_QUOTA_DIR = os.path.join(ACCOUNTING_ETC, "quotas")
ACCOUNTING_DATA_DIR = os.environ.get("MANAGER_HIVE_ACCOUNTING_DATA_DIR", "/var/lib/manager/hive-accounting")
ACCOUNTING_CTRL_DIR = os.path.join(ACCOUNTING_DATA_DIR, "controller")
ACCOUNTING_IDENTITY_DIR = os.path.join(ACCOUNTING_CTRL_DIR, "identities")
ACCOUNTING_SOURCE_DIR = os.path.join(ACCOUNTING_CTRL_DIR, "sources")
ACCOUNTING_AUDIT_FILE = os.environ.get("MANAGER_HIVE_ACCOUNTING_AUDIT_FILE", "/var/log/manager/hive-accounting-audit.jsonl")
SYSTEMD_DIR = os.environ.get("MANAGER_HIVE_LEASE_SYSTEMD_DIR", "/etc/systemd/system")
CTRL_SERVICE = os.path.join(SYSTEMD_DIR, "manager-hive-lease-controller.service")
UNIT_MARKER = "# MANAGER-HIVE-GLOBAL-LEASE v1"

REQ_CONTRACT = "manager-hive-global-lease-request-v1"
RESP_CONTRACT = "manager-hive-global-lease-response-v1"
STATUS_CONTRACT = "manager-hive-global-lease-v1"
VERSION = 1
DEFAULT_PORT = 9445
DEFAULT_TTL = 60
DEFAULT_MAX_TTL = 300
AUTH_SKEW = 120
REPLAY_TTL = 600
MAX_MESSAGE = 65536
IDENTITY_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,47}$")
NODE_ID_RE = re.compile(r"^node-[a-f0-9]{16}$")
SESSION_RE = re.compile(r"^[a-f0-9]{32}$")
NONCE_RE = re.compile(r"^[A-Za-z0-9_-]{32,96}$")
RESOURCE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.:@-]{0,63}$")
DEVICE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.:@-]{0,95}$")
PRODUCT_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,47}$")
SOURCE_EPOCH_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.:-]{0,95}$")
HOST_RE = re.compile(r"^(?=.{1,253}$)(?:[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?)$")
FP_RE = re.compile(r"^SHA256:[a-f0-9]{64}$")
ALLOWED_PROTOCOLS = {"ssh", "wireguard", "openvpn"}


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
    if not stat.S_ISREG(st.st_mode) or st.st_size > MAX_MESSAGE:
        return None
    try:
        value = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        return None
    return value if isinstance(value, dict) else None


def canonical(obj):
    clean = dict(obj)
    clean.pop("signature", None)
    return json.dumps(clean, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def sign(private_path, payload):
    if not os.path.isfile(private_path):
        die("Chave privada do nó não encontrada.", 67)
    dfd, dpath = tempfile.mkstemp(prefix="hive-lease-data-")
    sfd, spath = tempfile.mkstemp(prefix="hive-lease-sig-")
    os.close(sfd)
    try:
        os.fchmod(dfd, 0o600)
        with os.fdopen(dfd, "wb") as fh:
            fh.write(payload)
        proc = subprocess.run(["openssl", "pkeyutl", "-sign", "-inkey", private_path, "-rawin", "-in", dpath, "-out", spath],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10, check=False)
        if proc.returncode != 0:
            die("Falha ao assinar requisição de lease global.")
        sig = Path(spath).read_bytes()
    finally:
        for p in (dpath, spath):
            try: os.unlink(p)
            except FileNotFoundError: pass
    if len(sig) != 64:
        die("Assinatura Ed25519 inválida.")
    return base64.b64encode(sig).decode("ascii")


def verify(pub_path, payload, signature_text):
    try:
        sig = base64.b64decode(str(signature_text).encode("ascii"), validate=True)
    except Exception:
        return False
    if len(sig) != 64:
        return False
    dfd, dpath = tempfile.mkstemp(prefix="hive-lease-data-")
    sfd, spath = tempfile.mkstemp(prefix="hive-lease-sig-")
    try:
        os.fchmod(dfd, 0o600); os.fchmod(sfd, 0o600)
        with os.fdopen(dfd, "wb") as fh: fh.write(payload)
        with os.fdopen(sfd, "wb") as fh: fh.write(sig)
        proc = subprocess.run(["openssl", "pkeyutl", "-verify", "-pubin", "-inkey", pub_path, "-rawin",
                               "-in", dpath, "-sigfile", spath], stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL, timeout=10, check=False)
        return proc.returncode == 0
    finally:
        for p in (dpath, spath):
            try: os.unlink(p)
            except FileNotFoundError: pass


def cert_fingerprint(path):
    proc = subprocess.run(["openssl", "x509", "-in", path, "-outform", "DER"], stdout=subprocess.PIPE,
                          stderr=subprocess.DEVNULL, timeout=10, check=False)
    if proc.returncode != 0 or not proc.stdout:
        die("Certificado TLS de leases globais é inválido.")
    return "SHA256:" + hashlib.sha256(proc.stdout).hexdigest()


def validate_fp(value):
    value = str(value).strip().lower().replace("sha256:", "SHA256:", 1)
    if not FP_RE.fullmatch(value):
        die("Fingerprint TLS deve ser SHA256:<64 hex>.", 64)
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


def validate_bind(value):
    try:
        ipaddress.ip_address(value)
    except ValueError:
        die("BIND_IP deve ser IPv4/IPv6 literal válido.", 64)
    return value


def validate_port(value):
    try: port = int(value)
    except (TypeError, ValueError): die("Porta inválida.", 64)
    if port < 1024 or port > 65535:
        die("Porta deve estar entre 1024 e 65535.", 64)
    return port


def validate_identity(value):
    if not isinstance(value, str) or not IDENTITY_RE.fullmatch(value):
        raise ValueError("identity_id inválido")
    return value


def validate_session(value):
    if not isinstance(value, str) or not SESSION_RE.fullmatch(value):
        raise ValueError("local_session_id inválido")
    return value


def validate_ttl(value, max_ttl=DEFAULT_MAX_TTL):
    try: ttl = int(value)
    except (TypeError, ValueError): raise ValueError("TTL inválido")
    if ttl < 10 or ttl > max_ttl:
        raise ValueError(f"TTL deve estar entre 10 e {max_ttl} segundos")
    return ttl


def init_dirs():
    ensure_dir(LEASE_ETC)
    ensure_dir(LIMIT_DIR)
    ensure_dir(DATA_DIR)
    ensure_dir(ACTIVE_DIR)
    ensure_dir(EPOCH_DIR)
    ensure_dir(REPLAY_DIR)
    ensure_dir(ALLOCATION_RESULT_DIR)
    ensure_dir(ACCOUNTING_ETC)
    ensure_dir(ACCOUNTING_QUOTA_DIR)
    ensure_dir(ACCOUNTING_DATA_DIR)
    ensure_dir(ACCOUNTING_CTRL_DIR)
    ensure_dir(ACCOUNTING_IDENTITY_DIR)
    ensure_dir(ACCOUNTING_SOURCE_DIR)
    Path(LOCK_FILE).touch(mode=0o600, exist_ok=True)
    os.chmod(LOCK_FILE, 0o600)


def controller_identity():
    conf = read_conf(CTRL_CONF)
    if not conf:
        die("Inicialize o controlador da Colmeia primeiro.", 67)
    return conf


def node_enrollment():
    conf = read_conf(NODE_ENROLLMENT)
    if not conf or not os.path.isfile(NODE_KEY):
        die("Este nó precisa concluir o enrollment da Colmeia primeiro.", 67)
    node_id = conf.get("node_id", "")
    try: epoch = int(conf.get("node_epoch", "0"))
    except ValueError: epoch = 0
    if not NODE_ID_RE.fullmatch(node_id) or epoch < 1:
        die("Enrollment local inválido.", 67)
    return conf, node_id, epoch


def controller_node(node_id):
    if not NODE_ID_RE.fullmatch(node_id):
        raise PermissionError("node_id inválido")
    conf = read_conf(os.path.join(CTRL_NODES, node_id + ".conf"))
    pub = os.path.join(CTRL_NODES, node_id + ".pub")
    if not conf or not os.path.isfile(pub):
        raise PermissionError("nó não enrolled")
    try: epoch = int(conf.get("node_epoch", "0"))
    except ValueError: epoch = 0
    if conf.get("enabled") != "1" or conf.get("revoked_epoch", "0") != "0" or epoch < 1:
        raise PermissionError("nó revogado/desabilitado")
    return conf, pub, epoch


def generate_tls():
    ensure_dir(TLS_DIR)
    if os.path.exists(TLS_KEY) != os.path.exists(TLS_CERT):
        die("Estado TLS parcial das leases globais; recusando sobrescrever.", 65)
    if not os.path.exists(TLS_KEY):
        tmp = tempfile.mkdtemp(prefix=".hive-lease-tls-", dir=LEASE_ETC)
        try:
            key = os.path.join(tmp, "server.key")
            cert = os.path.join(tmp, "server.crt")
            p1 = subprocess.run(["openssl", "genpkey", "-algorithm", "ED25519", "-out", key],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=20, check=False)
            p2 = subprocess.run(["openssl", "req", "-new", "-x509", "-key", key, "-out", cert, "-days", "825",
                                 "-subj", "/CN=manager-hive-global-lease"], stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL, timeout=20, check=False) if p1.returncode == 0 else None
            if p1.returncode != 0 or p2 is None or p2.returncode != 0:
                die("Não foi possível gerar TLS das leases globais.")
            atomic_write(TLS_KEY, Path(key).read_bytes())
            atomic_write(TLS_CERT, Path(cert).read_bytes())
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
    return cert_fingerprint(TLS_CERT)


def controller_init():
    init_dirs()
    ctrl = controller_identity()
    fp = generate_tls()
    conf = read_conf(CTRL_LEASE_CONF)
    if not conf:
        now = int(time.time())
        atomic_write(CTRL_LEASE_CONF,
                     f"version=1\nenabled=0\ncontroller_id={ctrl.get('controller_id','')}\nbind=127.0.0.1\nport={DEFAULT_PORT}\n"
                     f"tls_fingerprint={fp}\ndefault_ttl={DEFAULT_TTL}\nmax_ttl={DEFAULT_MAX_TTL}\nauthority_epoch=1\ncreated_epoch={now}\nupdated_epoch={now}\n")
    return read_conf(CTRL_LEASE_CONF)


def write_controller_conf(conf, **changes):
    now = int(time.time())
    ctrl = controller_identity()
    values = {
        "enabled": conf.get("enabled", "0"), "bind": conf.get("bind", "127.0.0.1"),
        "port": conf.get("port", str(DEFAULT_PORT)), "tls_fingerprint": conf.get("tls_fingerprint", ""),
        "default_ttl": conf.get("default_ttl", str(DEFAULT_TTL)), "max_ttl": conf.get("max_ttl", str(DEFAULT_MAX_TTL)),
        "authority_epoch": conf.get("authority_epoch", "1"),
    }
    values.update({k: str(v) for k, v in changes.items()})
    atomic_write(CTRL_LEASE_CONF,
                 f"version=1\nenabled={values['enabled']}\ncontroller_id={ctrl.get('controller_id','')}\nbind={values['bind']}\n"
                 f"port={values['port']}\n"
                 f"tls_fingerprint={values['tls_fingerprint']}\ndefault_ttl={values['default_ttl']}\n"
                 f"max_ttl={values['max_ttl']}\nauthority_epoch={values['authority_epoch']}\n"
                 f"created_epoch={conf.get('created_epoch',str(now))}\nupdated_epoch={now}\n")
    return read_conf(CTRL_LEASE_CONF)


def unit_owned():
    try:
        st = os.lstat(CTRL_SERVICE)
        if not stat.S_ISREG(st.st_mode): return False
        return Path(CTRL_SERVICE).read_text(encoding="utf-8").splitlines()[0] == UNIT_MARKER
    except Exception:
        return False


def systemctl(*args):
    if os.environ.get("MANAGER_HIVE_LEASE_SKIP_SYSTEMD") == "1":
        return 0
    try:
        return subprocess.run(["systemctl", *args], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                              timeout=30, check=False).returncode
    except (OSError, subprocess.TimeoutExpired):
        return 1


def write_unit():
    ensure_dir(SYSTEMD_DIR, 0o755)
    if os.path.lexists(CTRL_SERVICE) and not unit_owned():
        die("Unidade externa encontrada; recusando sobrescrever manager-hive-lease-controller.service.", 65)
    text = f"""{UNIT_MARKER}
[Unit]
Description=MANAGER Hive global lease authority
After=network-online.target
ConditionPathExists={CTRL_LEASE_CONF}
ConditionPathExists={TLS_CERT}
ConditionPathExists={TLS_KEY}

[Service]
Type=simple
ExecStart={MANAGER_HOME}/modules/hive_leases.sh --serve-controller
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
ReadWritePaths={LEASE_ETC} {ACCOUNTING_ETC}

[Install]
WantedBy=multi-user.target
"""
    atomic_write(CTRL_SERVICE, text, 0o644)
    systemctl("daemon-reload")


def controller_enable(bind, port):
    conf = controller_init()
    bind = validate_bind(bind)
    port = validate_port(port)
    fp = generate_tls()
    try: authority_epoch = int(conf.get("authority_epoch", "1")) + 1
    except ValueError: authority_epoch = 2
    write_controller_conf(conf, enabled=1, bind=bind, port=port, tls_fingerprint=fp, authority_epoch=authority_epoch)
    write_unit()
    if systemctl("enable", "--now", "manager-hive-lease-controller.service") != 0:
        die("Não foi possível iniciar a autoridade global de leases.")
    print("global_lease_authority=1")
    print(f"bind={bind}")
    print(f"port={port}")
    print("tls=TLSv1.3")
    print(f"tls_fingerprint={fp}")
    print(f"authority_epoch={authority_epoch}")
    print("controller_in_user_vpn_path=0")
    print("firewall_auto_open=0")


def controller_disable():
    conf = controller_init()
    write_controller_conf(conf, enabled=0)
    systemctl("disable", "--now", "manager-hive-lease-controller.service")
    print("global_lease_authority=0")


def controller_rotate_tls():
    conf = controller_init()
    for p in (TLS_KEY, TLS_CERT):
        try: os.unlink(p)
        except FileNotFoundError: pass
    fp = generate_tls()
    write_controller_conf(conf, tls_fingerprint=fp)
    if conf.get("enabled") == "1":
        write_unit(); systemctl("restart", "manager-hive-lease-controller.service")
    print("tls_rotated=1")
    print(f"tls_fingerprint={fp}")


def node_configure(host, port, fingerprint, grace_seconds=30):
    enroll, node_id, node_epoch = node_enrollment()
    host = validate_host(host); port = validate_port(port); fingerprint = validate_fp(fingerprint)
    try: grace_seconds = int(grace_seconds)
    except (TypeError, ValueError): die("grace_seconds inválido.", 64)
    if grace_seconds < 0 or grace_seconds > 120:
        die("grace_seconds deve ficar entre 0 e 120.", 64)
    ensure_dir(NODE_LEASE_DIR)
    now = int(time.time())
    atomic_write(NODE_CONF,
                 f"version=1\nenabled=1\nnode_id={node_id}\nnode_epoch={node_epoch}\ncontroller_id={enroll.get('controller_id','')}\n"
                 f"host={host}\nport={port}\ntls_fingerprint={fingerprint}\ngrace_seconds={grace_seconds}\nupdated_epoch={now}\n")
    print("global_lease_enforcement=1")
    print(f"host={host}")
    print(f"port={port}")
    print(f"tls_fingerprint={fingerprint}")
    print(f"grace_seconds={grace_seconds}")
    print("new_grants_failure_mode=fail-closed")


def node_disable():
    conf = read_conf(NODE_CONF)
    if conf:
        conf["enabled"] = "0"
        atomic_write(NODE_CONF,
                     f"version=1\nenabled=0\nnode_id={conf.get('node_id','')}\nnode_epoch={conf.get('node_epoch','')}\n"
                     f"controller_id={conf.get('controller_id','')}\nhost={conf.get('host','')}\nport={conf.get('port','')}\n"
                     f"tls_fingerprint={conf.get('tls_fingerprint','')}\ngrace_seconds={conf.get('grace_seconds','30')}\nupdated_epoch={int(time.time())}\n")
    print("global_lease_enforcement=0")


def limit_path(identity_id):
    validate_identity(identity_id)
    return os.path.join(LIMIT_DIR, identity_id + ".conf")


def set_limit(identity_id, max_sessions, source="manual", product_id=""):
    init_dirs(); validate_identity(identity_id)
    try: maximum = int(max_sessions)
    except (TypeError, ValueError): die("max_sessions_global inválido.", 64)
    if maximum < 1 or maximum > 10000:
        die("max_sessions_global deve estar entre 1 e 10000.", 64)
    if source not in {"manual", "local-import"}:
        source = "manual"
    if product_id and not IDENTITY_RE.fullmatch(product_id):
        die("product_id inválido.", 64)
    now = int(time.time()); current = read_conf(limit_path(identity_id))
    atomic_write(limit_path(identity_id),
                 f"version=1\nidentity_id={identity_id}\nproduct_id={product_id}\nmax_sessions_global={maximum}\nsource={source}\n"
                 f"created_epoch={current.get('created_epoch',str(now))}\nupdated_epoch={now}\n")
    audit("limit-set", identity_id=identity_id, max_sessions_global=maximum, source=source)
    print(f"identity_id={identity_id}")
    print(f"product_id={product_id}")
    print(f"max_sessions_global={maximum}")
    print(f"source={source}")


def import_local(identity_id):
    validate_identity(identity_id)
    path = os.path.join(MANAGER_ETC, "connection", "identities", identity_id + ".conf")
    conf = read_conf(path)
    maximum = conf.get("max_sessions", "")
    if not maximum.isdigit() or int(maximum) < 1:
        die("Identidade local não existe ou possui max_sessions inválido.", 66)
    assignment = read_conf(os.path.join(MANAGER_ETC, "connection", "products", "assignments", identity_id + ".conf"))
    set_limit(identity_id, maximum, "local-import", assignment.get("product_id", ""))


def sync_local():
    root = Path(MANAGER_ETC) / "connection" / "identities"
    count = 0
    if root.is_dir():
        for path in sorted(root.glob("*.conf")):
            ident = path.stem
            if IDENTITY_RE.fullmatch(ident):
                conf = read_conf(str(path)); maximum = conf.get("max_sessions", "")
                if maximum.isdigit() and int(maximum) >= 1:
                    assignment = read_conf(os.path.join(MANAGER_ETC, "connection", "products", "assignments", ident + ".conf"))
                    set_limit(ident, maximum, "local-import", assignment.get("product_id", "")); count += 1
    print(f"limits_synced={count}")


def get_limit(identity_id):
    conf = read_conf(limit_path(identity_id))
    try: maximum = int(conf.get("max_sessions_global", "0"))
    except ValueError: maximum = 0
    return maximum, conf


def show_limit(identity_id):
    maximum, conf = get_limit(identity_id)
    if maximum < 1: die("Política global não encontrada para a identidade.", 66)
    for key in ("identity_id", "product_id", "max_sessions_global", "source", "created_epoch", "updated_epoch"):
        print(f"{key}={conf.get(key,'')}")


def list_limits():
    init_dirs()
    print("identity_id|product_id|max_sessions_global|source|updated_epoch")
    for path in sorted(Path(LIMIT_DIR).glob("*.conf")):
        conf = read_conf(str(path))
        if conf:
            print("|".join([conf.get("identity_id", path.stem), conf.get("product_id", ""), conf.get("max_sessions_global", ""),
                            conf.get("source", ""), conf.get("updated_epoch", "")]))


def unset_limit(identity_id):
    path = limit_path(identity_id)
    try: os.unlink(path)
    except FileNotFoundError: pass
    audit("limit-unset", identity_id=identity_id)
    print("limit_removed=1")


def epoch_path(identity_id):
    return os.path.join(EPOCH_DIR, identity_id + ".epoch")


def current_epoch(identity_id):
    path = epoch_path(identity_id)
    try: value = int(Path(path).read_text(encoding="ascii").strip())
    except Exception: value = 1
    if value < 1: value = 1
    atomic_write(path, str(value) + "\n")
    return value


def bump_epoch(identity_id):
    value = current_epoch(identity_id) + 1
    atomic_write(epoch_path(identity_id), str(value) + "\n")
    return value


def lease_path(global_id):
    return os.path.join(ACTIVE_DIR, global_id + ".json")


def authority_valid(node_id, node_epoch):
    try:
        conf, _, epoch = controller_node(node_id)
        return epoch == int(node_epoch) and conf.get("enabled") == "1"
    except Exception:
        return False


def cleanup_locked():
    now = int(time.time())
    for path in list(Path(ACTIVE_DIR).glob("*.json")):
        lease = read_json(str(path))
        if not lease:
            try: path.unlink()
            except FileNotFoundError: pass
            continue
        try: expires = int(lease.get("expires_epoch", 0))
        except (TypeError, ValueError): expires = 0
        stale = expires <= now or not authority_valid(lease.get("node_id", ""), lease.get("node_epoch", 0))
        if stale:
            audit("expire" if expires <= now else "fence-node", identity_id=lease.get("identity_id"),
                  node_id=lease.get("node_id"), global_lease_id=lease.get("global_lease_id"))
            try: path.unlink()
            except FileNotFoundError: pass


def find_local_locked(node_id, local_session_id):
    for path in Path(ACTIVE_DIR).glob("*.json"):
        lease = read_json(str(path))
        if lease and lease.get("node_id") == node_id and lease.get("local_session_id") == local_session_id:
            return str(path), lease
    return None, None


def active_count_locked(identity_id):
    count = 0
    now = int(time.time())
    for path in Path(ACTIVE_DIR).glob("*.json"):
        lease = read_json(str(path))
        if lease and lease.get("identity_id") == identity_id:
            try: expires = int(lease.get("expires_epoch", 0))
            except (TypeError, ValueError): expires = 0
            if expires > now: count += 1
    return count


def parse_params(params, require_full=True):
    if not isinstance(params, dict): raise ValueError("params inválido")
    identity_id = validate_identity(params.get("identity_id"))
    local_session_id = validate_session(params.get("local_session_id"))
    if not require_full:
        return identity_id, local_session_id, "", "", "", 0
    protocol = params.get("protocol")
    resource = params.get("resource")
    device = params.get("device_id")
    if protocol not in ALLOWED_PROTOCOLS: raise ValueError("protocolo inválido")
    if not isinstance(resource, str) or not RESOURCE_RE.fullmatch(resource): raise ValueError("resource inválido")
    if not isinstance(device, str) or not DEVICE_RE.fullmatch(device): raise ValueError("device_id inválido")
    conf = read_conf(CTRL_LEASE_CONF)
    try: max_ttl = int(conf.get("max_ttl", str(DEFAULT_MAX_TTL)))
    except ValueError: max_ttl = DEFAULT_MAX_TTL
    ttl = validate_ttl(params.get("ttl", DEFAULT_TTL), max_ttl)
    return identity_id, local_session_id, protocol, resource, device, ttl


def acquire_locked(node_id, node_epoch, params):
    identity_id, local_session_id, protocol, resource, device, ttl = parse_params(params, True)
    exact_global_id = params.get("global_lease_id", "") if isinstance(params, dict) else ""
    if exact_global_id and not SESSION_RE.fullmatch(str(exact_global_id)):
        raise LeaseError(64, "invalid-global-lease-id")
    if accounting_quota_blocked(identity_id):
        metrics = accounting_quota_metrics(identity_id)
        accounting_audit("quota-deny", identity_id=identity_id, node_id=node_id, node_epoch=node_epoch,
                         quota_bytes=metrics["quota_bytes"], quota_used_bytes=metrics["used_bytes"], action=metrics["action"])
        raise LeaseError(73, "global-traffic-quota-exceeded")
    maximum, policy = get_limit(identity_id)
    if maximum < 1:
        raise LeaseError(67, "no-global-policy")
    cleanup_locked()
    path, existing = find_local_locked(node_id, local_session_id)
    now = int(time.time())
    if existing:
        expected = (identity_id, protocol, resource, device)
        actual = (existing.get("identity_id"), existing.get("protocol"), existing.get("resource"), existing.get("device_id"))
        if actual != expected:
            raise LeaseError(65, "local-session-conflict")
        if exact_global_id and existing.get("global_lease_id") != exact_global_id:
            raise LeaseError(65, "exact-grant-session-conflict")
        existing["heartbeat_epoch"] = now
        existing["expires_epoch"] = now + ttl
        atomic_write(path, json.dumps(existing, sort_keys=True, separators=(",", ":")) + "\n")
        audit("renew", identity_id=identity_id, node_id=node_id, global_lease_id=existing.get("global_lease_id"),
              local_session_id=local_session_id)
        return existing
    # 0.8.5 can require one exact controller-issued grant. In that mode there is no
    # fallback to another reservation or to generic free global capacity.
    if exact_global_id:
        reserved_path = lease_path(exact_global_id)
        reserved = read_json(reserved_path)
        if not reserved or reserved.get("lease_state") != "reserved":
            raise LeaseError(69, "exact-global-grant-not-reserved")
        expected = (identity_id, node_id, int(node_epoch), protocol, device, current_epoch(identity_id))
        actual = (reserved.get("identity_id"), reserved.get("node_id"), int(reserved.get("node_epoch", 0)),
                  reserved.get("protocol"), reserved.get("device_id"), int(reserved.get("global_epoch", 0)))
        if actual != expected:
            raise LeaseError(67, "exact-global-grant-mismatch")
        reserved["lease_state"] = "active"
        reserved["local_session_id"] = local_session_id
        reserved["resource"] = resource
        reserved["heartbeat_epoch"] = now
        reserved["expires_epoch"] = now + ttl
        atomic_write(reserved_path, json.dumps(reserved, sort_keys=True, separators=(",", ":")) + "\n")
        audit("grant-claim-exact", identity_id=identity_id, node_id=node_id,
              global_lease_id=reserved.get("global_lease_id"), local_session_id=local_session_id)
        return reserved

    # Compatibility path for 0.8.4 callers that did not receive an exact allocation ticket.
    for reserved_path in Path(ACTIVE_DIR).glob("*.json"):
        reserved = read_json(str(reserved_path))
        if not reserved or reserved.get("lease_state") != "reserved":
            continue
        if (reserved.get("identity_id") == identity_id and reserved.get("node_id") == node_id and
                reserved.get("protocol") == protocol and reserved.get("device_id") == device):
            reserved["lease_state"] = "active"
            reserved["local_session_id"] = local_session_id
            reserved["resource"] = resource
            reserved["heartbeat_epoch"] = now
            reserved["expires_epoch"] = now + ttl
            atomic_write(str(reserved_path), json.dumps(reserved, sort_keys=True, separators=(",", ":")) + "\n")
            audit("grant-claim", identity_id=identity_id, node_id=node_id, global_lease_id=reserved.get("global_lease_id"),
                  local_session_id=local_session_id)
            return reserved
    active = active_count_locked(identity_id)
    if active >= maximum:
        audit("deny", identity_id=identity_id, node_id=node_id, local_session_id=local_session_id,
              reason="global-session-limit", active=active, max_sessions_global=maximum)
        raise LeaseError(69, "global-session-limit")
    global_id = secrets.token_hex(16)
    lease = {
        "version": 1, "global_lease_id": global_id, "identity_id": identity_id, "node_id": node_id,
        "node_epoch": int(node_epoch), "local_session_id": local_session_id, "protocol": protocol,
        "resource": resource, "device_id": device, "global_epoch": current_epoch(identity_id),
        "created_epoch": now, "heartbeat_epoch": now, "expires_epoch": now + ttl,
        "max_sessions_global": maximum, "product_id": policy.get("product_id", ""), "lease_state": "active",
    }
    atomic_write(lease_path(global_id), json.dumps(lease, sort_keys=True, separators=(",", ":")) + "\n")
    audit("acquire", identity_id=identity_id, node_id=node_id, global_lease_id=global_id,
          local_session_id=local_session_id, active_after=active + 1, max_sessions_global=maximum)
    return lease


def heartbeat_locked(node_id, node_epoch, params):
    identity_id, local_session_id, _, _, _, _ = parse_params(params, False)
    cleanup_locked(); path, lease = find_local_locked(node_id, local_session_id)
    if not lease or lease.get("identity_id") != identity_id or int(lease.get("node_epoch", 0)) != int(node_epoch):
        raise LeaseError(66, "global-lease-not-found")
    conf = read_conf(CTRL_LEASE_CONF)
    try: max_ttl = int(conf.get("max_ttl", str(DEFAULT_MAX_TTL)))
    except ValueError: max_ttl = DEFAULT_MAX_TTL
    ttl = validate_ttl(params.get("ttl", DEFAULT_TTL), max_ttl)
    now = int(time.time()); lease["heartbeat_epoch"] = now; lease["expires_epoch"] = now + ttl
    atomic_write(path, json.dumps(lease, sort_keys=True, separators=(",", ":")) + "\n")
    audit("heartbeat", identity_id=identity_id, node_id=node_id, global_lease_id=lease.get("global_lease_id"),
          local_session_id=local_session_id)
    return lease


def release_locked(node_id, params):
    identity_id, local_session_id, _, _, _, _ = parse_params(params, False)
    cleanup_locked(); path, lease = find_local_locked(node_id, local_session_id)
    if lease and lease.get("identity_id") != identity_id:
        raise LeaseError(65, "local-session-conflict")
    if path:
        try: os.unlink(path)
        except FileNotFoundError: pass
        audit("release", identity_id=identity_id, node_id=node_id, global_lease_id=lease.get("global_lease_id"),
              local_session_id=local_session_id)
    return {"released": True, "identity_id": identity_id, "local_session_id": local_session_id}



def accounting_audit(event, **fields):
    ensure_dir(os.path.dirname(ACCOUNTING_AUDIT_FILE), 0o750)
    record = {"epoch": int(time.time()), "event": event}
    for key, value in fields.items():
        if isinstance(value, (str, int, float, bool)) or value is None:
            record[key] = value
    fd = os.open(ACCOUNTING_AUDIT_FILE, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    try:
        os.write(fd, (json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8"))
    finally:
        os.close(fd)


def accounting_identity_path(identity_id):
    return os.path.join(ACCOUNTING_IDENTITY_DIR, identity_id + ".json")


def accounting_source_path(node_id, identity_id):
    return os.path.join(ACCOUNTING_SOURCE_DIR, node_id, identity_id + ".json")


def accounting_quota_path(identity_id):
    return os.path.join(ACCOUNTING_QUOTA_DIR, identity_id + ".conf")


def accounting_int(value, name, maximum=(2**63 - 1)):
    try:
        value = int(value)
    except (TypeError, ValueError):
        raise LeaseError(64, f"invalid-{name}")
    if value < 0 or value > maximum:
        raise LeaseError(64, f"invalid-{name}")
    return value


def accounting_state(identity_id):
    state = read_json(accounting_identity_path(identity_id)) or {}
    return {
        "contract": "manager-hive-global-usage-state-v1",
        "identity_id": identity_id,
        "product_id": str(state.get("product_id", "")),
        "download_bytes": accounting_int(state.get("download_bytes", 0), "stored-download"),
        "upload_bytes": accounting_int(state.get("upload_bytes", 0), "stored-upload"),
        "wireguard_download_bytes": accounting_int(state.get("wireguard_download_bytes", 0), "stored-wg-download"),
        "wireguard_upload_bytes": accounting_int(state.get("wireguard_upload_bytes", 0), "stored-wg-upload"),
        "openvpn_download_bytes": accounting_int(state.get("openvpn_download_bytes", 0), "stored-ovpn-download"),
        "openvpn_upload_bytes": accounting_int(state.get("openvpn_upload_bytes", 0), "stored-ovpn-upload"),
        "traffic_complete": 1 if state.get("traffic_complete", 1) in {1, True, "1"} else 0,
        "source_nodes": accounting_int(state.get("source_nodes", 0), "stored-source-nodes"),
        "updated_epoch": accounting_int(state.get("updated_epoch", 0), "stored-updated"),
    }


def accounting_total(identity_id):
    state = accounting_state(identity_id)
    return state["download_bytes"] + state["upload_bytes"]


def accounting_cycle(period, created_epoch=0):
    if period == "monthly":
        return time.strftime("%Y-%m", time.gmtime())
    if period == "lifetime":
        return f"lifetime-{created_epoch}"
    return "none"


def accounting_write_quota(identity_id, conf, *, cycle=None, baseline=None):
    created = accounting_int(conf.get("created_epoch", int(time.time())), "quota-created")
    quota = accounting_int(conf.get("quota_bytes", 0), "quota-bytes")
    product = str(conf.get("product_id", ""))
    period = str(conf.get("quota_period", "none"))
    action = str(conf.get("quota_action", "warn"))
    if not PRODUCT_RE.fullmatch(product) or period not in {"none", "monthly", "lifetime"} or action not in {"warn", "block"}:
        raise LeaseError(70, "invalid-global-quota-policy")
    if quota > 0 and period == "none":
        raise LeaseError(70, "invalid-global-quota-period")
    if cycle is None:
        cycle = str(conf.get("cycle", accounting_cycle(period, created)))
    if baseline is None:
        baseline = accounting_int(conf.get("baseline_total_bytes", 0), "quota-baseline")
    text = (
        "version=1\n"
        f"identity_id={identity_id}\n"
        f"product_id={product}\n"
        f"quota_bytes={quota}\n"
        f"quota_period={period}\n"
        f"quota_action={action}\n"
        f"cycle={cycle}\n"
        f"baseline_total_bytes={baseline}\n"
        f"created_epoch={created}\n"
        f"updated_epoch={int(time.time())}\n"
    )
    atomic_write(accounting_quota_path(identity_id), text)
    return read_conf(accounting_quota_path(identity_id))


def accounting_refresh_quota_locked(identity_id, product_id=""):
    conf = read_conf(accounting_quota_path(identity_id))
    if not conf:
        return None
    expected = conf.get("product_id", "")
    if product_id and expected and product_id != expected:
        raise LeaseError(73, "global-quota-product-mismatch")
    created = accounting_int(conf.get("created_epoch", 0), "quota-created")
    period = conf.get("quota_period", "none")
    wanted = accounting_cycle(period, created)
    if conf.get("cycle", "") != wanted:
        conf = accounting_write_quota(identity_id, conf, cycle=wanted, baseline=accounting_total(identity_id))
        accounting_audit("quota-cycle", identity_id=identity_id, product_id=conf.get("product_id", ""), cycle=wanted,
                         baseline_total_bytes=conf.get("baseline_total_bytes", "0"))
    return conf


def accounting_quota_metrics(identity_id, refresh=False):
    conf = accounting_refresh_quota_locked(identity_id) if refresh else read_conf(accounting_quota_path(identity_id))
    state = accounting_state(identity_id)
    total = state["download_bytes"] + state["upload_bytes"]
    if not conf:
        return {"configured": 0, "quota_bytes": 0, "used_bytes": total, "remaining_bytes": 0,
                "exceeded": 0, "enforceable": state["traffic_complete"], "action": "none", "cycle": "none"}
    quota = accounting_int(conf.get("quota_bytes", 0), "quota-bytes")
    baseline = accounting_int(conf.get("baseline_total_bytes", 0), "quota-baseline")
    used = total - baseline if total >= baseline else total
    exceeded = 1 if quota > 0 and used >= quota else 0
    remaining = 0 if quota == 0 or used >= quota else quota - used
    return {"configured": 1, "quota_bytes": quota, "used_bytes": used, "remaining_bytes": remaining,
            "exceeded": exceeded, "enforceable": state["traffic_complete"],
            "action": conf.get("quota_action", "warn"), "cycle": conf.get("cycle", "none")}


def accounting_quota_blocked(identity_id):
    metrics = accounting_quota_metrics(identity_id, refresh=True)
    return bool(metrics["configured"] and metrics["action"] == "block" and metrics["exceeded"] and metrics["enforceable"])


def accounting_complete_for_identity(identity_id):
    found = 0
    complete = 1
    root = Path(ACCOUNTING_SOURCE_DIR)
    if not root.is_dir():
        return 1, 0
    for node_dir in root.iterdir():
        if not node_dir.is_dir():
            continue
        sample = read_json(str(node_dir / (identity_id + ".json")))
        if not sample:
            continue
        found += 1
        if sample.get("traffic_complete") not in {1, True, "1"}:
            complete = 0
    return complete, found


def usage_ingest_locked(node_id, node_epoch, params):
    allowed = {"identity_id", "product_id", "source_epoch", "download_bytes", "upload_bytes",
               "wireguard_download_bytes", "wireguard_upload_bytes", "openvpn_download_bytes",
               "openvpn_upload_bytes", "traffic_complete", "sample_epoch"}
    if not isinstance(params, dict) or set(params) != allowed:
        raise LeaseError(64, "invalid-usage-ingest-params")
    identity_id = validate_identity(params.get("identity_id"))
    product_id = str(params.get("product_id", ""))
    source_epoch = str(params.get("source_epoch", ""))
    if not PRODUCT_RE.fullmatch(product_id):
        raise LeaseError(64, "invalid-product-id")
    if not SOURCE_EPOCH_RE.fullmatch(source_epoch):
        raise LeaseError(64, "invalid-source-epoch")
    counters = {
        "download_bytes": accounting_int(params.get("download_bytes"), "download-bytes"),
        "upload_bytes": accounting_int(params.get("upload_bytes"), "upload-bytes"),
        "wireguard_download_bytes": accounting_int(params.get("wireguard_download_bytes"), "wg-download-bytes"),
        "wireguard_upload_bytes": accounting_int(params.get("wireguard_upload_bytes"), "wg-upload-bytes"),
        "openvpn_download_bytes": accounting_int(params.get("openvpn_download_bytes"), "ovpn-download-bytes"),
        "openvpn_upload_bytes": accounting_int(params.get("openvpn_upload_bytes"), "ovpn-upload-bytes"),
    }
    traffic_complete = accounting_int(params.get("traffic_complete"), "traffic-complete", 1)
    sample_epoch = accounting_int(params.get("sample_epoch"), "sample-epoch")
    accounting_refresh_quota_locked(identity_id, product_id)

    source_path = accounting_source_path(node_id, identity_id)
    previous = read_json(source_path)
    deltas = {key: 0 for key in counters}
    baseline = previous is None
    reset = False
    if previous:
        previous_epoch = str(previous.get("source_epoch", ""))
        previous_sample = accounting_int(previous.get("sample_epoch", 0), "previous-sample-epoch")
        if previous_epoch == source_epoch:
            if sample_epoch < previous_sample:
                raise LeaseError(73, "stale-usage-sample")
            for key, current in counters.items():
                old = accounting_int(previous.get(key, 0), f"previous-{key}")
                if current < old:
                    raise LeaseError(73, "usage-counter-regression")
                deltas[key] = current - old
        else:
            reset = True
            baseline = True

    sample = {"contract": "manager-hive-global-usage-source-v1", "node_id": node_id, "node_epoch": node_epoch,
              "identity_id": identity_id, "product_id": product_id, "source_epoch": source_epoch,
              "traffic_complete": traffic_complete, "sample_epoch": sample_epoch, "received_epoch": int(time.time()), **counters}
    atomic_write(source_path, json.dumps(sample, sort_keys=True, separators=(",", ":")) + "\n")

    state = accounting_state(identity_id)
    state["product_id"] = product_id
    for key, delta in deltas.items():
        state[key] += delta
    state["total_bytes"] = state["download_bytes"] + state["upload_bytes"]
    state["traffic_complete"], state["source_nodes"] = accounting_complete_for_identity(identity_id)
    state["updated_epoch"] = int(time.time())
    atomic_write(accounting_identity_path(identity_id), json.dumps(state, sort_keys=True, separators=(",", ":")) + "\n")
    metrics = accounting_quota_metrics(identity_id)
    delta_total = deltas["download_bytes"] + deltas["upload_bytes"]
    accounting_audit("usage-ingest", identity_id=identity_id, product_id=product_id, node_id=node_id, node_epoch=node_epoch,
                     source_epoch=source_epoch, delta_bytes=delta_total, global_total_bytes=state["total_bytes"],
                     baseline=bool(baseline), source_reset=bool(reset), traffic_complete=state["traffic_complete"],
                     quota_exceeded=metrics["exceeded"], quota_enforceable=metrics["enforceable"])
    return {"ingested": True, "identity_id": identity_id, "product_id": product_id, "delta_bytes": delta_total,
            "global_total_bytes": state["total_bytes"], "baseline": bool(baseline), "source_reset": bool(reset),
            "traffic_complete": state["traffic_complete"], "source_nodes": state["source_nodes"],
            "quota_configured": metrics["configured"], "quota_bytes": metrics["quota_bytes"],
            "quota_used_bytes": metrics["used_bytes"], "quota_remaining_bytes": metrics["remaining_bytes"],
            "quota_exceeded": metrics["exceeded"], "quota_enforceable": metrics["enforceable"],
            "quota_action": metrics["action"], "quota_cycle": metrics["cycle"]}

def allocation_pull_locked(node_id, node_epoch, params):
    if not isinstance(params, dict) or set(params) - {"limit"}:
        raise LeaseError(64, "invalid-allocation-pull-params")
    try: limit = int(params.get("limit", 4))
    except (TypeError, ValueError): raise LeaseError(64, "invalid-allocation-pull-limit")
    if limit < 1 or limit > 8:
        raise LeaseError(64, "allocation-pull-limit-out-of-range")
    root = Path(ALLOCATION_OUTBOX_DIR) / node_id
    if not root.is_dir():
        return {"count": 0, "bundles": []}
    now = int(time.time()); bundles = []
    for path in sorted(root.glob("*.json")):
        if len(bundles) >= limit: break
        bundle = read_json(str(path))
        if not bundle:
            audit("allocation-delivery-deny", node_id=node_id, reason="invalid-outbox-bundle", file=path.name)
            continue
        if bundle.get("selected_node") != node_id:
            audit("allocation-delivery-deny", node_id=node_id, reason="wrong-selected-node", allocation_id=bundle.get("allocation_id"))
            continue
        try:
            bundle_node_epoch = int(bundle.get("node_epoch", 0)); expires = int(bundle.get("expires_epoch", 0))
        except (TypeError, ValueError):
            audit("allocation-delivery-deny", node_id=node_id, reason="invalid-bundle-epoch", allocation_id=bundle.get("allocation_id"))
            continue
        if bundle_node_epoch != int(node_epoch):
            try: path.unlink()
            except FileNotFoundError: pass
            audit("allocation-delivery-fence", node_id=node_id, allocation_id=bundle.get("allocation_id"),
                  bundle_node_epoch=bundle_node_epoch, node_epoch=int(node_epoch))
            continue
        if expires <= now:
            try: path.unlink()
            except FileNotFoundError: pass
            audit("allocation-delivery-expire", node_id=node_id, allocation_id=bundle.get("allocation_id"))
            continue
        bundles.append(bundle)
    audit("allocation-pull", node_id=node_id, count=len(bundles))
    return {"count": len(bundles), "bundles": bundles}


def validate_allocation_result(result, bundle, node_id, node_epoch):
    if not isinstance(result, dict):
        raise LeaseError(64, "invalid-allocation-result")
    expected = {"contract","version","allocation_id","identity_id","product_id","protocol","selected_node","selected_name",
                "node_epoch","expires_epoch","credential_state","credentials"}
    if set(result) != expected or result.get("contract") != "manager-hive-vpn-login-result-v1" or result.get("version") != 1:
        raise LeaseError(64, "invalid-allocation-result-contract")
    if (result.get("allocation_id") != bundle.get("allocation_id") or result.get("identity_id") != bundle.get("identity_id") or
            result.get("product_id") != bundle.get("product_id") or result.get("protocol") != bundle.get("protocol") or
            result.get("selected_node") != node_id or result.get("node_epoch") != int(node_epoch) or
            result.get("expires_epoch") != bundle.get("expires_epoch")):
        raise LeaseError(67, "allocation-result-bundle-mismatch")
    if result.get("credential_state") not in {"issued", "existing"}:
        raise LeaseError(64, "invalid-allocation-credential-state")
    creds = result.get("credentials")
    if not isinstance(creds, dict):
        raise LeaseError(64, "invalid-allocation-credentials")
    protocol = result.get("protocol")
    allowed = {"ssh": {"username","password"},
               "wireguard": {"client","ipv4","ipv6","profile_b64","profile_encoding"},
               "openvpn": {"client","ipv6","profile_b64","profile_encoding"}}.get(protocol)
    if allowed is None or set(creds) - allowed:
        raise LeaseError(64, "invalid-allocation-credential-fields")
    if protocol == "ssh":
        if not creds.get("username") or len(str(creds.get("username"))) > 64:
            raise LeaseError(64, "invalid-ssh-login-result")
        if result.get("credential_state") == "issued" and not creds.get("password"):
            raise LeaseError(64, "missing-issued-ssh-password")
        if "password" in creds and len(str(creds.get("password"))) > 512:
            raise LeaseError(64, "invalid-ssh-password-result")
    else:
        if creds.get("profile_encoding") != "base64" or not creds.get("profile_b64"):
            raise LeaseError(64, "missing-vpn-profile-result")
        try: decoded = base64.b64decode(str(creds.get("profile_b64")).encode("ascii"), validate=True)
        except Exception: raise LeaseError(64, "invalid-vpn-profile-base64")
        if not decoded or len(decoded) > 49152:
            raise LeaseError(64, "invalid-vpn-profile-size")
    encoded = json.dumps(result, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    if len(encoded) > 60000:
        raise LeaseError(64, "allocation-result-too-large")
    return result, encoded


def allocation_ack_locked(node_id, node_epoch, params):
    if not isinstance(params, dict) or set(params) not in ({"allocation_id"}, {"allocation_id", "result"}):
        raise LeaseError(64, "invalid-allocation-ack-params")
    allocation_id = str(params.get("allocation_id", ""))
    if not SESSION_RE.fullmatch(allocation_id):
        raise LeaseError(64, "invalid-allocation-id")
    path = Path(ALLOCATION_OUTBOX_DIR) / node_id / f"{allocation_id}.json"
    result_path = Path(ALLOCATION_RESULT_DIR) / f"{allocation_id}.json"
    if not path.exists():
        if "result" in params and result_path.exists():
            current = read_json(str(result_path))
            incoming = params.get("result")
            if current != incoming:
                raise LeaseError(65, "allocation-result-idempotency-conflict")
        return {"acked": True, "idempotent": True, "allocation_id": allocation_id, "result_stored": result_path.exists()}
    bundle = read_json(str(path))
    if not bundle:
        raise LeaseError(70, "invalid-outbox-bundle")
    try: bundle_node_epoch = int(bundle.get("node_epoch", 0))
    except (TypeError, ValueError): bundle_node_epoch = 0
    if bundle.get("selected_node") != node_id or bundle_node_epoch != int(node_epoch):
        raise LeaseError(67, "allocation-ack-node-mismatch")
    if "result" not in params:
        raise LeaseError(64, "allocation-ack-result-required")
    result, encoded = validate_allocation_result(params.get("result"), bundle, node_id, node_epoch)
    if result_path.exists():
        current = read_json(str(result_path))
        if current != result:
            raise LeaseError(65, "allocation-result-idempotency-conflict")
    else:
        atomic_write(str(result_path), encoded + b"\n", 0o600)
    try: path.unlink()
    except FileNotFoundError: pass
    audit("allocation-ack", node_id=node_id, allocation_id=allocation_id,
          identity_id=bundle.get("identity_id"), global_lease_id=bundle.get("global_lease_id"), result_stored=1)
    return {"acked": True, "idempotent": False, "allocation_id": allocation_id, "result_stored": True}


class LeaseError(Exception):
    def __init__(self, code, reason):
        super().__init__(reason); self.code = code; self.reason = reason


def replay_path(node_id, nonce):
    return os.path.join(REPLAY_DIR, node_id, hashlib.sha256(nonce.encode("ascii")).hexdigest() + ".nonce")


def cleanup_replay_locked(node_id):
    root = Path(REPLAY_DIR) / node_id
    if not root.is_dir(): return
    cutoff = int(time.time()) - REPLAY_TTL
    for path in root.glob("*.nonce"):
        try:
            if int(path.stat().st_mtime) < cutoff: path.unlink()
        except OSError: pass


def check_auth_locked(request):
    if request.get("contract") != REQ_CONTRACT or request.get("version") != VERSION:
        raise LeaseError(64, "invalid-contract")
    node_id = request.get("node_id", "")
    try: node_epoch = int(request.get("node_epoch", 0)); issued = int(request.get("issued_at", 0))
    except (TypeError, ValueError): raise LeaseError(64, "invalid-auth-envelope")
    nonce = request.get("nonce", "")
    if not NODE_ID_RE.fullmatch(str(node_id)) or node_epoch < 1 or not NONCE_RE.fullmatch(str(nonce)):
        raise LeaseError(64, "invalid-auth-envelope")
    now = int(time.time())
    if abs(now - issued) > AUTH_SKEW:
        raise LeaseError(70, "timestamp-skew")
    try: _, pub, registered_epoch = controller_node(node_id)
    except PermissionError as exc: raise LeaseError(67, str(exc))
    if registered_epoch != node_epoch:
        raise LeaseError(70, "node-epoch-fenced")
    if not verify(pub, canonical(request), request.get("signature", "")):
        raise LeaseError(67, "bad-signature")
    cleanup_replay_locked(node_id)
    rp = replay_path(node_id, nonce)
    if os.path.exists(rp):
        raise LeaseError(70, "replay")
    atomic_write(rp, f"issued_at={issued}\n")
    return node_id, node_epoch


def response(ok, code, result=None, error=None):
    conf = read_conf(CTRL_LEASE_CONF)
    try: authority_epoch = int(conf.get("authority_epoch", "1"))
    except ValueError: authority_epoch = 1
    return {"contract": RESP_CONTRACT, "version": VERSION, "authority_epoch": authority_epoch,
            "ok": bool(ok), "code": int(code), "result": result if isinstance(result, dict) else {}, "error": error or ""}


def handle_request(request):
    init_dirs()
    with open(LOCK_FILE, "r+") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        try:
            node_id, node_epoch = check_auth_locked(request)
            action = request.get("action")
            params = request.get("params", {})
            if action == "acquire": result = acquire_locked(node_id, node_epoch, params)
            elif action == "heartbeat": result = heartbeat_locked(node_id, node_epoch, params)
            elif action == "release": result = release_locked(node_id, params)
            elif action == "usage_ingest": result = usage_ingest_locked(node_id, node_epoch, params)
            elif action == "allocation_pull": result = allocation_pull_locked(node_id, node_epoch, params)
            elif action == "allocation_ack": result = allocation_ack_locked(node_id, node_epoch, params)
            else: raise LeaseError(64, "invalid-action")
            return response(True, 0, result=result)
        except LeaseError as exc:
            return response(False, exc.code, error=exc.reason)
        except ValueError as exc:
            return response(False, 64, error=str(exc))
        finally:
            fcntl.flock(lock.fileno(), fcntl.LOCK_UN)


class LeaseHandler(socketserver.StreamRequestHandler):
    def handle(self):
        self.connection.settimeout(5)
        raw = self.rfile.readline(MAX_MESSAGE + 1)
        if not raw or len(raw) > MAX_MESSAGE:
            return
        try:
            request = json.loads(raw.decode("utf-8"))
            if not isinstance(request, dict): raise ValueError
            answer = handle_request(request)
        except Exception:
            answer = response(False, 64, error="invalid-json")
        payload = (json.dumps(answer, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")
        self.wfile.write(payload)


class ThreadedServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True
    address_family = socket.AF_INET6 if ":" in read_conf(CTRL_LEASE_CONF).get("bind", "") else socket.AF_INET


def serve_controller():
    conf = controller_init()
    if conf.get("enabled") != "1": die("Autoridade global de leases está desabilitada.", 67)
    bind = validate_bind(conf.get("bind", "127.0.0.1")); port = validate_port(conf.get("port", str(DEFAULT_PORT)))
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); context.minimum_version = ssl.TLSVersion.TLSv1_3
    context.load_cert_chain(TLS_CERT, TLS_KEY)
    server = ThreadedServer((bind, port), LeaseHandler)
    server.socket = context.wrap_socket(server.socket, server_side=True)
    server.serve_forever(poll_interval=0.5)


def node_request(action, params):
    conf = read_conf(NODE_CONF)
    if conf.get("enabled") != "1": die("Enforcement global de leases não está configurado neste nó.", 67)
    enroll, node_id, node_epoch = node_enrollment()
    if conf.get("node_id") != node_id or conf.get("node_epoch") != str(node_epoch):
        die("Configuração de lease global ficou stale após reenrollment; configure novamente.", 70)
    req = {"contract": REQ_CONTRACT, "version": VERSION, "action": action, "node_id": node_id,
           "node_epoch": node_epoch, "issued_at": int(time.time()), "nonce": secrets.token_urlsafe(32), "params": params}
    req["signature"] = sign(NODE_KEY, canonical(req))
    host = validate_host(conf.get("host", "")); port = validate_port(conf.get("port", str(DEFAULT_PORT)))
    wanted_fp = validate_fp(conf.get("tls_fingerprint", ""))
    raw = (json.dumps(req, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT); context.minimum_version = ssl.TLSVersion.TLSv1_3
    context.check_hostname = False; context.verify_mode = ssl.CERT_NONE
    try:
        with socket.create_connection((host, port), timeout=4) as sock:
            with context.wrap_socket(sock, server_hostname=host) as tls:
                cert = tls.getpeercert(binary_form=True)
                actual_fp = "SHA256:" + hashlib.sha256(cert).hexdigest()
                if actual_fp != wanted_fp:
                    die("Fingerprint TLS do controlador não corresponde ao pin configurado.", 67)
                tls.sendall(raw)
                buf = b""
                while not buf.endswith(b"\n") and len(buf) <= MAX_MESSAGE:
                    chunk = tls.recv(4096)
                    if not chunk: break
                    buf += chunk
    except (OSError, ssl.SSLError, socket.timeout):
        die("Autoridade global de leases indisponível; acesso recusado em fail-closed.", 69)
    if not buf or len(buf) > MAX_MESSAGE: die("Resposta inválida da autoridade global.", 70)
    try: answer = json.loads(buf.decode("utf-8"))
    except Exception: die("Resposta JSON inválida da autoridade global.", 70)
    if answer.get("contract") != RESP_CONTRACT or answer.get("version") != VERSION:
        die("Contrato de resposta da autoridade global inválido.", 70)
    try: authority_epoch = int(answer.get("authority_epoch", 0))
    except (TypeError, ValueError): authority_epoch = 0
    state = read_conf(NODE_AUTH_STATE)
    try: seen_authority = int(state.get("authority_epoch", "0"))
    except ValueError: seen_authority = 0
    if authority_epoch < 1 or authority_epoch < seen_authority:
        die("Autoridade global antiga/fenced tentou retornar.", 70)
    if authority_epoch > seen_authority:
        atomic_write(NODE_AUTH_STATE, f"authority_epoch={authority_epoch}\nupdated_epoch={int(time.time())}\n")
    if not answer.get("ok"):
        code = answer.get("code", 70)
        try: code = int(code)
        except Exception: code = 70
        die(f"Lease global recusada: {answer.get('error','denied')}", code)
    return answer.get("result", {})


def node_acquire(identity_id, protocol, resource, device, local_session_id, ttl, global_lease_id=""):
    params = {"identity_id": validate_identity(identity_id), "protocol": protocol, "resource": resource,
              "device_id": device, "local_session_id": validate_session(local_session_id), "ttl": int(ttl)}
    if global_lease_id:
        if not SESSION_RE.fullmatch(str(global_lease_id)):
            die("global_lease_id inválido.", 64)
        params["global_lease_id"] = global_lease_id
    result = node_request("acquire", params)
    print(f"global_lease_id={result.get('global_lease_id','')}")
    print(f"global_epoch={result.get('global_epoch','')}")
    print(f"expires_epoch={result.get('expires_epoch','')}")
    print(f"max_sessions_global={result.get('max_sessions_global','')}")


def node_heartbeat(identity_id, local_session_id, ttl):
    result = node_request("heartbeat", {"identity_id": validate_identity(identity_id),
                                         "local_session_id": validate_session(local_session_id), "ttl": int(ttl)})
    print(f"global_lease_id={result.get('global_lease_id','')}")
    print(f"global_epoch={result.get('global_epoch','')}")
    print(f"expires_epoch={result.get('expires_epoch','')}")


def node_release(identity_id, local_session_id):
    node_request("release", {"identity_id": validate_identity(identity_id), "local_session_id": validate_session(local_session_id)})
    print("released=1")



def node_usage_ingest(identity_id, product_id, source_epoch, download, upload, wg_download, wg_upload,
                      ovpn_download, ovpn_upload, traffic_complete, sample_epoch):
    identity_id = validate_identity(identity_id)
    if not PRODUCT_RE.fullmatch(str(product_id)):
        die("product_id de accounting inválido.", 64)
    if not SOURCE_EPOCH_RE.fullmatch(str(source_epoch)):
        die("source_epoch de accounting inválido.", 64)
    params = {
        "identity_id": identity_id, "product_id": str(product_id), "source_epoch": str(source_epoch),
        "download_bytes": accounting_int(download, "download-bytes"),
        "upload_bytes": accounting_int(upload, "upload-bytes"),
        "wireguard_download_bytes": accounting_int(wg_download, "wg-download-bytes"),
        "wireguard_upload_bytes": accounting_int(wg_upload, "wg-upload-bytes"),
        "openvpn_download_bytes": accounting_int(ovpn_download, "ovpn-download-bytes"),
        "openvpn_upload_bytes": accounting_int(ovpn_upload, "ovpn-upload-bytes"),
        "traffic_complete": accounting_int(traffic_complete, "traffic-complete", 1),
        "sample_epoch": accounting_int(sample_epoch, "sample-epoch"),
    }
    result = node_request("usage_ingest", params)
    for key in ("identity_id", "product_id", "delta_bytes", "global_total_bytes", "baseline", "source_reset",
                "traffic_complete", "source_nodes", "quota_configured", "quota_bytes", "quota_used_bytes",
                "quota_remaining_bytes", "quota_exceeded", "quota_enforceable", "quota_action", "quota_cycle"):
        value = result.get(key, "")
        if isinstance(value, bool): value = 1 if value else 0
        print(f"{key}={value}")

def node_allocation_pull(limit=4):
    try: limit = int(limit)
    except (TypeError, ValueError): die("limit de allocation inválido.", 64)
    if limit < 1 or limit > 8: die("limit de allocation deve ficar entre 1 e 8.", 64)
    result = node_request("allocation_pull", {"limit": limit})
    bundles = result.get("bundles", [])
    if not isinstance(bundles, list): die("Resposta de allocation do controlador inválida.", 70)
    print(json.dumps({"count": len(bundles), "bundles": bundles}, sort_keys=True, separators=(",", ":")))


def node_allocation_ack(allocation_id, result_file=""):
    if not SESSION_RE.fullmatch(str(allocation_id)): die("allocation_id inválido.", 64)
    params = {"allocation_id": allocation_id}
    if result_file:
        result = read_json(result_file)
        if not result: die("Arquivo de resultado da allocation é inválido.", 64)
        params["result"] = result
    answer = node_request("allocation_ack", params)
    print(f"allocation_acked={1 if answer.get('acked') else 0}")
    print(f"idempotent={1 if answer.get('idempotent') else 0}")
    print(f"result_stored={1 if answer.get('result_stored') else 0}")
    print(f"allocation_id={allocation_id}")


def controller_list(identity_id=""):
    init_dirs()
    if identity_id: validate_identity(identity_id)
    with open(LOCK_FILE, "r+") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX); cleanup_locked()
        print("identity_id|global_lease_id|node_id|local_session_id|protocol|device_id|global_epoch|expires_epoch")
        for path in sorted(Path(ACTIVE_DIR).glob("*.json")):
            lease = read_json(str(path))
            if not lease or (identity_id and lease.get("identity_id") != identity_id): continue
            print("|".join(str(lease.get(k, "")) for k in
                           ("identity_id", "global_lease_id", "node_id", "local_session_id", "protocol", "device_id", "global_epoch", "expires_epoch")))
        fcntl.flock(lock.fileno(), fcntl.LOCK_UN)


def controller_grant(identity_id, protocol, region="", pool="", sticky="", node_scope="*", device="grant", ttl=DEFAULT_TTL):
    init_dirs(); identity_id = validate_identity(identity_id)
    if accounting_quota_blocked(identity_id):
        metrics = accounting_quota_metrics(identity_id)
        accounting_audit("quota-deny-grant", identity_id=identity_id, quota_bytes=metrics["quota_bytes"],
                         quota_used_bytes=metrics["used_bytes"], action=metrics["action"])
        die("Franquia global excedida para esta identidade.", 73)
    if protocol not in ALLOWED_PROTOCOLS: die("Protocolo inválido.", 64)
    if not isinstance(device, str) or not DEVICE_RE.fullmatch(device): die("device_id inválido.", 64)
    conf = read_conf(CTRL_LEASE_CONF)
    try: max_ttl = int(conf.get("max_ttl", str(DEFAULT_MAX_TTL)))
    except ValueError: max_ttl = DEFAULT_MAX_TTL
    try: ttl = validate_ttl(ttl, max_ttl)
    except ValueError as exc: die(str(exc), 64)
    maximum, policy = get_limit(identity_id)
    if maximum < 1: die("Política global não encontrada para a identidade.", 67)
    scheduler = os.path.join(MANAGER_HOME, "modules", "hive_scheduler.sh")
    proc = subprocess.run([scheduler, "--select", protocol, region or "*", pool or "*", sticky, node_scope],
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=15, check=False)
    if proc.returncode != 0: die("Scheduler não encontrou nó elegível para o grant.", proc.returncode)
    selected = {}
    for line in proc.stdout.splitlines():
        if "=" in line:
            k, v = line.split("=", 1); selected[k] = v
    node_id = selected.get("selected_node", "")
    try: _, _, node_epoch = controller_node(node_id)
    except PermissionError: die("Nó selecionado deixou de ser autoritativo.", 67)
    now = int(time.time())
    with open(LOCK_FILE, "r+") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX); cleanup_locked()
        active = active_count_locked(identity_id)
        if active >= maximum:
            fcntl.flock(lock.fileno(), fcntl.LOCK_UN)
            die("Limite global atingido antes da reserva.", 69)
        global_id = secrets.token_hex(16)
        lease = {"version":1,"global_lease_id":global_id,"identity_id":identity_id,"product_id":policy.get("product_id",""),
                 "node_id":node_id,"node_epoch":node_epoch,"local_session_id":"","protocol":protocol,"resource":"",
                 "device_id":device,"global_epoch":current_epoch(identity_id),"lease_state":"reserved",
                 "created_epoch":now,"heartbeat_epoch":now,"expires_epoch":now+ttl,"max_sessions_global":maximum}
        atomic_write(lease_path(global_id), json.dumps(lease, sort_keys=True, separators=(",", ":")) + "\n")
        audit("grant", identity_id=identity_id, product_id=policy.get("product_id",""), node_id=node_id,
              global_lease_id=global_id, max_sessions_global=maximum)
        fcntl.flock(lock.fileno(), fcntl.LOCK_UN)
    print("contract=manager-hive-global-grant-v1")
    print(f"global_lease_id={global_id}")
    print(f"global_epoch={lease['global_epoch']}")
    print(f"selected_node={node_id}")
    print(f"selected_name={selected.get('selected_name','')}")
    print(f"product_id={policy.get('product_id','')}")
    print(f"max_sessions_global={maximum}")
    print(f"expires_epoch={lease['expires_epoch']}")
    print("lease_state=reserved")


def controller_revoke(identity_id, reason="admin"):
    init_dirs(); validate_identity(identity_id)
    if not re.fullmatch(r"[A-Za-z0-9_.:-]{1,64}", reason): die("Motivo inválido.", 64)
    removed = 0
    with open(LOCK_FILE, "r+") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX); cleanup_locked(); new_epoch = bump_epoch(identity_id)
        for path in list(Path(ACTIVE_DIR).glob("*.json")):
            lease = read_json(str(path))
            if lease and lease.get("identity_id") == identity_id:
                try: path.unlink(); removed += 1
                except FileNotFoundError: pass
        audit("revoke-identity", identity_id=identity_id, reason=reason, removed=removed, global_epoch=new_epoch)
        fcntl.flock(lock.fileno(), fcntl.LOCK_UN)
    print(f"identity_id={identity_id}")
    print(f"leases_revoked={removed}")
    print(f"global_epoch={new_epoch}")


def audit(event, **fields):
    ensure_dir(os.path.dirname(AUDIT_FILE), 0o750)
    record = {"epoch": int(time.time()), "event": event}
    for k, v in fields.items():
        if isinstance(v, (str, int, float, bool)) or v is None: record[k] = v
    fd = os.open(AUDIT_FILE, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    try: os.write(fd, (json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8"))
    finally: os.close(fd)


def status():
    ctrl = read_conf(CTRL_LEASE_CONF); node = read_conf(NODE_CONF)
    active = 0
    if os.path.isdir(ACTIVE_DIR):
        active = sum(1 for p in Path(ACTIVE_DIR).glob("*.json") if read_json(str(p)))
    print(f"contract={STATUS_CONTRACT}")
    print("global_lease_capability=1")
    print(f"controller_enabled={1 if ctrl.get('enabled') == '1' else 0}")
    print(f"node_enforcement_enabled={1 if node.get('enabled') == '1' else 0}")
    print("failure_mode=fail-closed")
    print("authority_auth=ed25519-enrolled-node")
    print("transport=tls1.3-pinned")
    print("global_grant_capability=1")
    print("authority_epoch_fencing=1")
    print("bounded_existing_session_grace=1")
    print("controller_in_user_vpn_path=0")
    print(f"active_global_leases={active}")


def controller_status():
    conf = controller_init()
    print("contract=manager-hive-global-lease-controller-v1")
    print(f"enabled={conf.get('enabled','0')}")
    print(f"bind={conf.get('bind','127.0.0.1')}")
    print(f"port={conf.get('port',str(DEFAULT_PORT))}")
    print(f"tls_fingerprint={conf.get('tls_fingerprint','')}")
    print(f"authority_epoch={conf.get('authority_epoch','1')}")
    print("global_lease_authority=1")
    print("max_sessions_global=1")
    print("controller_in_user_vpn_path=0")


def node_status():
    conf = read_conf(NODE_CONF)
    print("contract=manager-hive-global-lease-node-v1")
    print(f"enabled={conf.get('enabled','0')}")
    print(f"host={conf.get('host','')}")
    print(f"port={conf.get('port','')}")
    print(f"tls_fingerprint={conf.get('tls_fingerprint','')}")
    print(f"grace_seconds={conf.get('grace_seconds','30')}")
    print("new_grants_failure_mode=fail-closed")


def install():
    init_dirs()
    conf = read_conf(CTRL_LEASE_CONF)
    if conf.get("enabled") == "1":
        generate_tls(); write_unit(); systemctl("enable", "--now", "manager-hive-lease-controller.service")


def detach():
    systemctl("disable", "--now", "manager-hive-lease-controller.service")
    if os.path.lexists(CTRL_SERVICE):
        if unit_owned(): os.unlink(CTRL_SERVICE)
        else: die("Unidade externa encontrada; recusando remover.", 65)
    systemctl("daemon-reload")


def purge():
    detach()
    shutil.rmtree(LEASE_ETC, ignore_errors=True)
    shutil.rmtree(NODE_LEASE_DIR, ignore_errors=True)
    shutil.rmtree(DATA_DIR, ignore_errors=True)
    try: os.unlink(AUDIT_FILE)
    except FileNotFoundError: pass


def usage():
    print("Uso: hive_leases.sh {--status|--node-status|--node-configure HOST PORT FP [GRACE]|--node-disable|--controller-init|--controller-status|--controller-enable BIND [PORT]|--controller-disable|--controller-rotate-tls|--controller-grant ID PROTO [REGION] [POOL] [STICKY] [SCOPE] [DEVICE] [TTL]|--limit-set ID MAX [PRODUCT]|--limit-import-local ID|--limit-sync-local|--limit-show ID|--limit-list|--limit-unset ID|--controller-list [ID]|--controller-revoke ID [REASON]|--acquire-node ID PROTO RESOURCE DEVICE SESSION [TTL] [GLOBAL_LEASE_ID]|--heartbeat-node ID SESSION [TTL]|--release-node ID SESSION|--allocation-pull-node [LIMIT]|--allocation-ack-node ALLOCATION_ID [RESULT_JSON]|--serve-controller|--install|--detach|--purge}", file=sys.stderr)
    raise SystemExit(64)


def main(argv):
    cmd = argv[0] if argv else "--status"
    if cmd == "--status": status(); return
    if cmd == "--node-status": node_status(); return
    if cmd == "--node-configure" and len(argv) in {4,5}: node_configure(argv[1], argv[2], argv[3], argv[4] if len(argv) == 5 else 30); return
    if cmd == "--node-disable": node_disable(); return
    if cmd == "--controller-init": controller_status(); return
    if cmd == "--controller-status": controller_status(); return
    if cmd == "--controller-enable" and len(argv) in {2,3}: controller_enable(argv[1], argv[2] if len(argv) == 3 else DEFAULT_PORT); return
    if cmd == "--controller-disable": controller_disable(); return
    if cmd == "--controller-rotate-tls": controller_rotate_tls(); return
    if cmd == "--controller-grant" and 3 <= len(argv) <= 9:
        controller_grant(argv[1], argv[2], argv[3] if len(argv)>3 else "", argv[4] if len(argv)>4 else "",
                         argv[5] if len(argv)>5 else "", argv[6] if len(argv)>6 else "*",
                         argv[7] if len(argv)>7 else "grant", argv[8] if len(argv)>8 else DEFAULT_TTL); return
    if cmd == "--limit-set" and len(argv) in {3,4}: set_limit(argv[1], argv[2], "manual", argv[3] if len(argv)==4 else ""); return
    if cmd == "--limit-import-local" and len(argv) == 2: import_local(argv[1]); return
    if cmd == "--limit-sync-local": sync_local(); return
    if cmd == "--limit-show" and len(argv) == 2: show_limit(argv[1]); return
    if cmd == "--limit-list": list_limits(); return
    if cmd == "--limit-unset" and len(argv) == 2: unset_limit(argv[1]); return
    if cmd == "--controller-list" and len(argv) <= 2: controller_list(argv[1] if len(argv) == 2 else ""); return
    if cmd == "--controller-revoke" and len(argv) in {2,3}: controller_revoke(argv[1], argv[2] if len(argv) == 3 else "admin"); return
    if cmd == "--acquire-node" and len(argv) in {6,7,8}:
        node_acquire(argv[1], argv[2], argv[3], argv[4], argv[5],
                     argv[6] if len(argv) >= 7 else DEFAULT_TTL,
                     argv[7] if len(argv) == 8 else ""); return
    if cmd == "--heartbeat-node" and len(argv) in {3,4}: node_heartbeat(argv[1], argv[2], argv[3] if len(argv) == 4 else DEFAULT_TTL); return
    if cmd == "--release-node" and len(argv) == 3: node_release(argv[1], argv[2]); return
    if cmd == "--usage-ingest-node" and len(argv) == 12:
        node_usage_ingest(*argv[1:]); return
    if cmd == "--allocation-pull-node" and len(argv) in {1,2}: node_allocation_pull(argv[1] if len(argv) == 2 else 4); return
    if cmd == "--allocation-ack-node" and len(argv) in {2,3}: node_allocation_ack(argv[1], argv[2] if len(argv) == 3 else ""); return
    if cmd == "--serve-controller": serve_controller(); return
    if cmd == "--install": install(); return
    if cmd == "--detach": detach(); return
    if cmd == "--purge": purge(); return
    usage()

main(sys.argv[1:])
PY
