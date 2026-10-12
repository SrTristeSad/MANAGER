#!/usr/bin/env bash
set -Eeuo pipefail

MANAGER_HOME="${MANAGER_HOME:-/opt/manager}"
MANAGER_ETC="${MANAGER_ETC:-/etc/manager}"
# shellcheck source=/dev/null
source "$MANAGER_HOME/lib/common.sh"
require_root

command -v python3 >/dev/null 2>&1 || { err "Python 3 é necessário para allocations da Colmeia."; exit 69; }
command -v openssl >/dev/null 2>&1 || { err "OpenSSL é necessário para allocations da Colmeia."; exit 69; }

python3 - "$@" <<'PY'
import base64
import fcntl
import hashlib
import hmac
import ipaddress
import json
import os
import re
import secrets
import shutil
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
NODE_ENROLLMENT = os.path.join(NODE_DIR, "enrollment.conf")
NODE_CONTROLLER_PUB = os.path.join(NODE_DIR, "controller.pub")
NODE_LEASE_CONF = os.path.join(HIVE_DIR, "leases", "node.conf")
ALLOC_ETC = os.path.join(HIVE_DIR, "allocations")
NODE_CONF = os.path.join(ALLOC_ETC, "node.conf")
CTRL_DIR = os.path.join(HIVE_DIR, "controller")
CTRL_CONF = os.path.join(CTRL_DIR, "controller.conf")
CTRL_KEY = os.path.join(CTRL_DIR, "controller.key")
CTRL_NODES = os.path.join(CTRL_DIR, "nodes")
LIMIT_DIR = os.path.join(CTRL_DIR, "leases", "limits")
DATA_DIR = os.environ.get("MANAGER_HIVE_ALLOCATION_DATA_DIR", "/var/lib/manager/hive-allocations")
CTRL_EPOCH_DIR = os.path.join(DATA_DIR, "controller", "epochs")
CTRL_OUTBOX_DIR = os.path.join(DATA_DIR, "controller", "outbox")
CTRL_ENDPOINT_DIR = os.path.join(ALLOC_ETC, "controller-endpoints")
NODE_ACTIVE_DIR = os.path.join(DATA_DIR, "node", "active")
NODE_STATE_DIR = os.path.join(DATA_DIR, "node", "state")
NODE_EPOCH_DIR = os.path.join(DATA_DIR, "node", "epochs")
NODE_PROVISION_DIR = os.path.join(DATA_DIR, "node", "provisioned")
NODE_CLAIM_DIR = os.path.join(DATA_DIR, "node", "claims")
LOCK_FILE = os.path.join(DATA_DIR, ".lock")
AUDIT_FILE = os.environ.get("MANAGER_HIVE_ALLOCATION_AUDIT_FILE", "/var/log/manager/hive-allocation-audit.jsonl")
LEASE_MODULE = os.path.join(MANAGER_HOME, "modules", "hive_leases.sh")
PROVISION_MODULE = os.path.join(MANAGER_HOME, "modules", "provision.sh")
AUTOMATION_REMOTE_CONF = os.path.join(MANAGER_ETC, "automation", "v2", "remote.conf")
AUTOMATION_REMOTE_CERT = os.path.join(MANAGER_ETC, "automation", "v2", "tls", "server.crt")
SYSTEMD_DIR = os.environ.get("MANAGER_HIVE_ALLOCATION_SYSTEMD_DIR", "/etc/systemd/system")
SYNC_SERVICE = os.path.join(SYSTEMD_DIR, "manager-hive-allocation-sync.service")
SYNC_TIMER = os.path.join(SYSTEMD_DIR, "manager-hive-allocation-sync.timer")
SYNC_SERVICE_MARKER = "# MANAGER-HIVE-ALLOCATION-SYNC-SERVICE v1"
SYNC_TIMER_MARKER = "# MANAGER-HIVE-ALLOCATION-SYNC-TIMER v1"
CONTRACT = "manager-hive-vpn-allocation-v1"
CLAIM_CONTRACT = "manager-hive-vpn-allocation-v2"
CLIENT_LOGIN_CONTRACT = "manager-hive-public-login-v1"
CLAIM_RESULT_CONTRACT = "manager-hive-public-login-result-v1"
STATUS_CONTRACT = "manager-hive-vpn-allocation-status-v1"
VERSION = 1
DEFAULT_TTL = 60
DEFAULT_LOGIN_TTL = 180
PENDING_TTL = 15
MAX_JSON = 65536
MAX_PROFILE = 262144
IDENTITY_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,47}$")
NODE_ID_RE = re.compile(r"^node-[a-f0-9]{16}$")
ID_RE = re.compile(r"^[a-f0-9]{32}$")
TOKEN_RE = re.compile(r"^[a-f0-9]{32,64}$")
CLAIM_TOKEN_RE = re.compile(r"^[A-Za-z0-9_-]{40,128}$")
FP_RE = re.compile(r"^SHA256:[a-f0-9]{64}$")
LABEL_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$")
ALLOWED_PROTOCOLS = {"ssh", "wireguard", "openvpn"}


def die(message, code=70):
    print(message, file=sys.stderr)
    raise SystemExit(code)


def ensure_dir(path, mode=0o700):
    os.makedirs(path, mode=mode, exist_ok=True)
    os.chmod(path, mode)


def init_dirs():
    ensure_dir(ALLOC_ETC)
    ensure_dir(DATA_DIR)
    ensure_dir(CTRL_EPOCH_DIR)
    ensure_dir(CTRL_OUTBOX_DIR)
    ensure_dir(CTRL_ENDPOINT_DIR)
    ensure_dir(NODE_ACTIVE_DIR)
    ensure_dir(NODE_STATE_DIR)
    ensure_dir(NODE_EPOCH_DIR)
    ensure_dir(NODE_PROVISION_DIR)
    ensure_dir(NODE_CLAIM_DIR)
    Path(LOCK_FILE).touch(mode=0o600, exist_ok=True)
    os.chmod(LOCK_FILE, 0o600)


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
        try: os.unlink(tmp)
        except FileNotFoundError: pass


def systemctl(*args):
    if os.environ.get("MANAGER_HIVE_ALLOCATION_SKIP_SYSTEMD") == "1": return 0
    try:
        return subprocess.run(["systemctl", *args], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                              timeout=30, check=False).returncode
    except (OSError, subprocess.TimeoutExpired): return 1


def unit_owned(path, marker):
    try:
        st = os.lstat(path)
        return stat.S_ISREG(st.st_mode) and Path(path).read_text(encoding="utf-8").splitlines()[0] == marker
    except Exception: return False


def write_sync_units():
    ensure_dir(SYSTEMD_DIR, 0o755)
    for path, marker in ((SYNC_SERVICE, SYNC_SERVICE_MARKER), (SYNC_TIMER, SYNC_TIMER_MARKER)):
        if os.path.lexists(path) and not unit_owned(path, marker):
            die(f"Unidade externa encontrada; recusando sobrescrever {os.path.basename(path)}.", 65)
    service = f"""{SYNC_SERVICE_MARKER}
[Unit]
Description=MANAGER Hive automatic VPN allocation delivery
After=network-online.target
ConditionPathExists={NODE_CONF}
ConditionPathExists={NODE_LEASE_CONF}

[Service]
Type=oneshot
ExecStart={MANAGER_HOME}/modules/hive_allocations.sh --sync 8
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
    timer = f"""{SYNC_TIMER_MARKER}
[Unit]
Description=Poll MANAGER Hive controller for signed VPN allocations

[Timer]
OnBootSec=2s
OnUnitActiveSec=3s
AccuracySec=1s
Unit=manager-hive-allocation-sync.service

[Install]
WantedBy=timers.target
"""
    atomic_write(SYNC_SERVICE, service, 0o644); atomic_write(SYNC_TIMER, timer, 0o644)
    systemctl("daemon-reload")


def enable_sync_timer():
    write_sync_units()
    if systemctl("enable", "--now", "manager-hive-allocation-sync.timer") != 0:
        die("Não foi possível ativar a distribuição automática de allocations.", 70)


def disable_sync_timer(remove_units=False):
    systemctl("disable", "--now", "manager-hive-allocation-sync.timer")
    if remove_units:
        for path, marker in ((SYNC_TIMER, SYNC_TIMER_MARKER), (SYNC_SERVICE, SYNC_SERVICE_MARKER)):
            if os.path.lexists(path):
                if unit_owned(path, marker): os.unlink(path)
                else: die(f"Unidade externa encontrada; recusando remover {os.path.basename(path)}.", 65)
        systemctl("daemon-reload")


def write_external_new(path, data):
    if not isinstance(path, str) or not os.path.isabs(path):
        die("O arquivo de allocation precisa usar caminho absoluto.", 64)
    parent = os.path.dirname(path)
    if not os.path.isdir(parent):
        die("O diretório de saída da allocation não existe.", 64)
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        die("O arquivo de allocation já existe; recusando sobrescrever.", 65)
    try:
        payload = data.encode("utf-8") if isinstance(data, str) else data
        os.write(fd, payload)
        os.fsync(fd)
    finally:
        os.close(fd)
    os.chmod(path, 0o600)


def read_conf(path):
    out = {}
    try: st = os.lstat(path)
    except FileNotFoundError: return out
    if not stat.S_ISREG(st.st_mode): return out
    try:
        with open(path, "r", encoding="utf-8") as fh:
            for raw in fh:
                raw = raw.rstrip("\n")
                if "=" in raw:
                    k, v = raw.split("=", 1); out[k] = v
    except (OSError, UnicodeDecodeError):
        return {}
    return out


def read_json(path):
    try: st = os.lstat(path)
    except FileNotFoundError: return None
    if not stat.S_ISREG(st.st_mode) or st.st_size > MAX_JSON: return None
    try: value = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError): return None
    return value if isinstance(value, dict) else None


def canonical(obj):
    clean = dict(obj); clean.pop("signature", None)
    return json.dumps(clean, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def sign(private_path, payload):
    if not os.path.isfile(private_path): die("Chave privada do controlador da Colmeia não encontrada.", 67)
    dfd, dpath = tempfile.mkstemp(prefix="hive-allocation-data-")
    sfd, spath = tempfile.mkstemp(prefix="hive-allocation-sig-"); os.close(sfd)
    try:
        os.fchmod(dfd, 0o600)
        with os.fdopen(dfd, "wb") as fh: fh.write(payload)
        proc = subprocess.run(["openssl","pkeyutl","-sign","-inkey",private_path,"-rawin","-in",dpath,"-out",spath],
                              stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=10,check=False)
        if proc.returncode != 0: die("Falha ao assinar allocation da Colmeia.")
        sig = Path(spath).read_bytes()
    finally:
        for path in (dpath, spath):
            try: os.unlink(path)
            except FileNotFoundError: pass
    if len(sig) != 64: die("Assinatura Ed25519 da allocation inválida.")
    return base64.b64encode(sig).decode("ascii")


def verify(pub_path, payload, signature_text):
    try: sig = base64.b64decode(str(signature_text).encode("ascii"), validate=True)
    except Exception: return False
    if len(sig) != 64 or not os.path.isfile(pub_path): return False
    dfd, dpath = tempfile.mkstemp(prefix="hive-allocation-data-")
    sfd, spath = tempfile.mkstemp(prefix="hive-allocation-sig-")
    try:
        os.fchmod(dfd,0o600); os.fchmod(sfd,0o600)
        with os.fdopen(dfd,"wb") as fh: fh.write(payload)
        with os.fdopen(sfd,"wb") as fh: fh.write(sig)
        proc = subprocess.run(["openssl","pkeyutl","-verify","-pubin","-inkey",pub_path,"-rawin","-in",dpath,"-sigfile",spath],
                              stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=10,check=False)
        return proc.returncode == 0
    finally:
        for path in (dpath, spath):
            try: os.unlink(path)
            except FileNotFoundError: pass


def validate_identity(value):
    if not isinstance(value,str) or not IDENTITY_RE.fullmatch(value): die("identity_id inválido.",64)
    return value


def validate_protocol(value):
    if value not in ALLOWED_PROTOCOLS: die("Protocolo inválido; use ssh, wireguard ou openvpn.",64)
    return value


def validate_label(value, field, allow_empty=True):
    if value in ("","*","-") and allow_empty: return ""
    if not isinstance(value,str) or not LABEL_RE.fullmatch(value): die(f"{field} inválido.",64)
    return value


def validate_node_id(value):
    if not isinstance(value,str) or not NODE_ID_RE.fullmatch(value): die("node_id inválido.",64)
    return value


def controller_identity():
    conf = read_conf(CTRL_CONF)
    if not conf or not os.path.isfile(CTRL_KEY): die("Inicialize o controlador da Colmeia primeiro.",67)
    if not conf.get("controller_id"): die("Identidade do controlador inválida.",67)
    return conf


def node_enrollment():
    conf = read_conf(NODE_ENROLLMENT)
    if not conf or not os.path.isfile(NODE_CONTROLLER_PUB): die("Este nó precisa concluir enrollment e pin do controlador.",67)
    node_id = conf.get("node_id","")
    try: node_epoch = int(conf.get("node_epoch","0"))
    except ValueError: node_epoch = 0
    if not NODE_ID_RE.fullmatch(node_id) or node_epoch < 1 or not conf.get("controller_id"): die("Enrollment local inválido.",67)
    return conf,node_id,node_epoch


def controller_node(node_id):
    validate_node_id(node_id)
    conf = read_conf(os.path.join(CTRL_NODES,node_id+".conf"))
    if not conf: die("Nó selecionado não está enrolled.",67)
    try: epoch = int(conf.get("node_epoch","0"))
    except ValueError: epoch = 0
    if conf.get("enabled") != "1" or conf.get("revoked_epoch","0") != "0" or epoch < 1:
        die("Nó selecionado está revogado/desabilitado.",67)
    return conf,epoch


def limit_policy(identity_id):
    conf = read_conf(os.path.join(LIMIT_DIR,identity_id+".conf"))
    try: maximum = int(conf.get("max_sessions_global","0"))
    except ValueError: maximum = 0
    if maximum < 1: die("Política global de sessões não encontrada para a identidade.",67)
    product_id = conf.get("product_id","")
    if not product_id or not IDENTITY_RE.fullmatch(product_id): die("Allocation 0.8.5 exige product_id válido na política global.",67)
    return conf,maximum,product_id


def epoch_path(root,identity_id):
    validate_identity(identity_id); return os.path.join(root,identity_id+".epoch")


def read_epoch(root,identity_id):
    path = epoch_path(root,identity_id)
    try: value = int(Path(path).read_text(encoding="ascii").strip())
    except Exception: value = 1
    if value < 1: value = 1
    atomic_write(path,str(value)+"\n"); return value


def bump_epoch(root,identity_id):
    value = read_epoch(root,identity_id)+1
    atomic_write(epoch_path(root,identity_id),str(value)+"\n"); return value


def parse_kv(text):
    out={}
    for line in text.splitlines():
        if "=" in line:
            k,v=line.split("=",1); out[k]=v
    return out


def normalize_fp(value):
    value = str(value or "").strip()
    if value.startswith("SHA256:"):
        value = "SHA256:" + value.split(":", 1)[1].lower()
    if not FP_RE.fullmatch(value):
        die("Fingerprint TLS inválido; esperado SHA256:<64 hex>.", 64)
    return value


def public_endpoint(host, port):
    try:
        addr = ipaddress.ip_address(str(host))
        port_i = int(port)
    except (ValueError, TypeError):
        die("Endpoint público exige IP literal e porta válida.", 64)
    if not 1024 <= port_i <= 65535:
        die("Porta do endpoint público deve ficar entre 1024 e 65535.", 64)
    rendered = f"[{addr.compressed}]:{port_i}" if addr.version == 6 else f"{addr.compressed}:{port_i}"
    return rendered, port_i


def parse_public_endpoint(value):
    value = str(value or "")
    if value.startswith("["):
        end = value.find("]")
        if end < 0 or end + 2 > len(value) or value[end + 1] != ":":
            die("Endpoint público IPv6 inválido.", 64)
        host, port = value[1:end], value[end + 2:]
    else:
        if value.count(":") != 1:
            die("Endpoint público inválido.", 64)
        host, port = value.rsplit(":", 1)
    return public_endpoint(host, port)


def endpoint_path(node_id):
    validate_node_id(node_id)
    return os.path.join(CTRL_ENDPOINT_DIR, node_id + ".conf")


def controller_endpoint_set(node_id, host, port, tls_fp):
    init_dirs(); controller_identity(); controller_node(node_id)
    endpoint, port_i = public_endpoint(host, port); tls_fp = normalize_fp(tls_fp)
    atomic_write(endpoint_path(node_id),
                 f"version=1\nnode_id={node_id}\nendpoint={endpoint}\nport={port_i}\n"
                 f"tls_fingerprint={tls_fp}\nupdated_epoch={int(time.time())}\n")
    audit("endpoint-set", node_id=node_id, endpoint=endpoint, tls_fingerprint=tls_fp)
    print("endpoint_configured=1"); print(f"node_id={node_id}"); print(f"endpoint={endpoint}")
    print(f"tls_fingerprint={tls_fp}")


def controller_endpoint(node_id):
    conf = read_conf(endpoint_path(node_id))
    if conf.get("version") != "1" or conf.get("node_id") != node_id:
        die("Nó selecionado não possui endpoint público de claim configurado.", 69)
    endpoint, _ = parse_public_endpoint(conf.get("endpoint", ""))
    tls_fp = normalize_fp(conf.get("tls_fingerprint", ""))
    return endpoint, tls_fp


def local_remote_fingerprint():
    try:
        st = os.lstat(AUTOMATION_REMOTE_CERT)
    except FileNotFoundError:
        die("Automation v2 remota precisa estar habilitada no nó para public login.", 69)
    if not stat.S_ISREG(st.st_mode) or st.st_uid != 0 or stat.S_IMODE(st.st_mode) & 0o077:
        die("Certificado TLS da Automation v2 possui permissões inseguras.", 67)
    proc = subprocess.run(["openssl", "x509", "-in", AUTOMATION_REMOTE_CERT, "-outform", "DER"],
                          stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=10, check=False)
    if proc.returncode != 0 or not proc.stdout:
        die("Certificado TLS da Automation v2 é inválido.", 67)
    return "SHA256:" + hashlib.sha256(proc.stdout).hexdigest()


def validate_local_claim_endpoint(bundle):
    if bundle.get("contract") != CLAIM_CONTRACT:
        return
    conf = read_conf(AUTOMATION_REMOTE_CONF)
    if conf.get("enabled") != "1" or conf.get("tls") != "TLSv1.3":
        die("Public login exige Automation v2 remota TLS 1.3 habilitada no nó.", 69)
    _endpoint, signed_port = parse_public_endpoint(bundle.get("claim_endpoint", ""))
    try:
        local_port = int(conf.get("port", "0"))
    except ValueError:
        local_port = 0
    if local_port != signed_port:
        die("Porta pública assinada não corresponde ao gateway TLS local.", 67)
    expected = normalize_fp(bundle.get("claim_tls_fingerprint", ""))
    if not hmac.compare_digest(local_remote_fingerprint(), expected):
        die("Fingerprint público assinado não corresponde ao certificado TLS local.", 67)


def controller_outbox_path(node_id, allocation_id):
    validate_node_id(node_id)
    if not ID_RE.fullmatch(str(allocation_id)): die("allocation_id inválido.", 64)
    root = os.path.join(CTRL_OUTBOX_DIR, node_id); ensure_dir(root)
    return os.path.join(root, allocation_id + ".json")


def queue_bundle(bundle):
    path = controller_outbox_path(bundle.get("selected_node", ""), bundle.get("allocation_id", ""))
    if os.path.exists(path):
        current = read_json(path)
        if current != bundle: die("allocation_id colidiu no outbox do controlador.", 65)
        return path
    atomic_write(path, json.dumps(bundle, sort_keys=True, separators=(",", ":")) + "\n")
    return path


def purge_controller_outbox_identity(identity_id):
    removed = 0
    for path in list(Path(CTRL_OUTBOX_DIR).glob("node-*/*.json")):
        bundle = read_json(str(path))
        if bundle and bundle.get("identity_id") == identity_id:
            try: path.unlink(); removed += 1
            except FileNotFoundError: pass
    return removed


def controller_create(identity_id,protocol,out_path,region="",pool="",sticky="",node_scope="*",ttl=DEFAULT_TTL):
    init_dirs(); ctrl=controller_identity()
    identity_id=validate_identity(identity_id); protocol=validate_protocol(protocol)
    region=validate_label(region,"region"); pool=validate_label(pool,"pool")
    if sticky and (len(sticky)>128 or any(ord(ch)<32 for ch in sticky)): die("Sticky key inválida.",64)
    if not isinstance(node_scope,str) or not node_scope: node_scope="*"
    try: ttl=int(ttl)
    except (TypeError,ValueError): die("TTL inválido.",64)
    if ttl<10 or ttl>300: die("TTL da allocation deve ficar entre 10 e 300 segundos.",64)
    _,maximum,product_id=limit_policy(identity_id)
    if not os.path.isfile(LEASE_MODULE): die("Módulo de leases globais não encontrado.",69)
    if not isinstance(out_path,str) or not os.path.isabs(out_path) or not os.path.isdir(os.path.dirname(out_path)):
        die("O arquivo de allocation exige caminho absoluto em diretório existente.",64)
    if os.path.exists(out_path):
        die("O arquivo de allocation já existe; recusando reservar grant sem destino livre.",65)

    allocation_id=secrets.token_hex(16); grant_device="alloc-"+allocation_id
    proc=subprocess.run([LEASE_MODULE,"--controller-grant",identity_id,protocol,region or "*",pool or "*",
                         sticky,node_scope,grant_device,str(ttl)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,
                        text=True,timeout=20,check=False)
    if proc.returncode!=0: die(proc.stderr.strip() or "Não foi possível reservar grant global.",proc.returncode)
    grant=parse_kv(proc.stdout)
    global_id=grant.get("global_lease_id",""); selected_node=grant.get("selected_node","")
    if not ID_RE.fullmatch(global_id) or not NODE_ID_RE.fullmatch(selected_node):
        subprocess.run([LEASE_MODULE,"--controller-revoke",identity_id,"allocation-invalid-grant"],
                       stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=10,check=False)
        die("Resposta do grant global ficou incompleta.",70)
    _,node_epoch=controller_node(selected_node)
    try: global_epoch_i=int(grant.get("global_epoch","")); expires_i=int(grant.get("expires_epoch",""))
    except ValueError: die("Epoch/expiração inválidos no grant global.",70)
    if global_epoch_i<1 or expires_i<=int(time.time()): die("Grant global retornou estado inválido.",70)

    session_epoch=read_epoch(CTRL_EPOCH_DIR,identity_id); now=int(time.time())
    allocation={"contract":CONTRACT,"version":VERSION,"allocation_id":allocation_id,
                "controller_id":ctrl.get("controller_id",""),"identity_id":identity_id,"product_id":product_id,
                "protocol":protocol,"region":region,"pool":pool,"node_scope":node_scope,
                "selected_node":selected_node,"selected_name":grant.get("selected_name",""),"node_epoch":node_epoch,
                "global_lease_id":global_id,"global_epoch":global_epoch_i,"grant_device":grant_device,
                "session_epoch":session_epoch,"max_sessions_global":maximum,"issued_at":now,"expires_epoch":expires_i}
    allocation["signature"]=sign(CTRL_KEY,canonical(allocation))
    payload=json.dumps(allocation,sort_keys=True,separators=(",",":"))+"\n"
    write_external_new(out_path,payload)
    queued_path=queue_bundle(allocation)
    audit("create",identity_id=identity_id,product_id=product_id,protocol=protocol,allocation_id=allocation_id,
          global_lease_id=global_id,node_id=selected_node,node_epoch=node_epoch,session_epoch=session_epoch,
          expires_epoch=expires_i,distribution_queued=1)
    print(f"contract={CONTRACT}"); print(f"allocation_file={out_path}"); print(f"allocation_id={allocation_id}")
    print(f"identity_id={identity_id}"); print(f"product_id={product_id}"); print(f"protocol={protocol}")
    print(f"selected_node={selected_node}"); print(f"selected_name={grant.get('selected_name','')}")
    print(f"node_epoch={node_epoch}"); print(f"global_lease_id={global_id}"); print(f"global_epoch={global_epoch_i}")
    print(f"session_epoch={session_epoch}"); print(f"expires_epoch={expires_i}"); print("lease_state=reserved")
    print("distribution_queued=1"); print(f"distribution_queue={queued_path}")
    print("delivery_transport=lease-control-pull"); print("controller_in_user_vpn_path=0")


def controller_login(identity_id, protocol, out_path, region="", pool="", sticky="", node_scope="*", ttl=DEFAULT_LOGIN_TTL):
    init_dirs(); ctrl = controller_identity()
    identity_id = validate_identity(identity_id); protocol = validate_protocol(protocol)
    region = validate_label(region, "region"); pool = validate_label(pool, "pool")
    if sticky and (len(sticky) > 128 or any(ord(ch) < 32 for ch in sticky)):
        die("Sticky key inválida.", 64)
    if not isinstance(node_scope, str) or not node_scope:
        node_scope = "*"
    try:
        ttl = int(ttl)
    except (TypeError, ValueError):
        die("TTL inválido.", 64)
    if ttl < 30 or ttl > 300:
        die("TTL do public login deve ficar entre 30 e 300 segundos.", 64)
    _, maximum, product_id = limit_policy(identity_id)
    if not isinstance(out_path, str) or not os.path.isabs(out_path) or not os.path.isdir(os.path.dirname(out_path)):
        die("O arquivo de public login exige caminho absoluto em diretório existente.", 64)
    if os.path.exists(out_path):
        die("O arquivo de public login já existe; recusando reservar grant sem destino livre.", 65)

    allocation_id = secrets.token_hex(16); grant_device = "alloc-" + allocation_id
    proc = subprocess.run([LEASE_MODULE, "--controller-grant", identity_id, protocol, region or "*", pool or "*",
                           sticky, node_scope, grant_device, str(ttl)], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          text=True, timeout=20, check=False)
    if proc.returncode != 0:
        die(proc.stderr.strip() or "Não foi possível reservar grant global.", proc.returncode)
    grant = parse_kv(proc.stdout)
    global_id = grant.get("global_lease_id", ""); selected_node = grant.get("selected_node", "")
    if not ID_RE.fullmatch(global_id) or not NODE_ID_RE.fullmatch(selected_node):
        die("Resposta do grant global ficou incompleta.", 70)
    _, node_epoch = controller_node(selected_node)
    endpoint, tls_fp = controller_endpoint(selected_node)
    try:
        global_epoch_i = int(grant.get("global_epoch", "")); expires_i = int(grant.get("expires_epoch", ""))
    except ValueError:
        die("Epoch/expiração inválidos no grant global.", 70)
    if global_epoch_i < 1 or expires_i <= int(time.time()):
        die("Grant global retornou estado inválido.", 70)

    claim_token = secrets.token_urlsafe(32)
    claim_hash = hashlib.sha256(claim_token.encode("ascii")).hexdigest()
    session_epoch = read_epoch(CTRL_EPOCH_DIR, identity_id); now = int(time.time())
    allocation = {"contract": CLAIM_CONTRACT, "version": VERSION, "allocation_id": allocation_id,
                  "controller_id": ctrl.get("controller_id", ""), "identity_id": identity_id, "product_id": product_id,
                  "protocol": protocol, "region": region, "pool": pool, "node_scope": node_scope,
                  "selected_node": selected_node, "selected_name": grant.get("selected_name", ""), "node_epoch": node_epoch,
                  "global_lease_id": global_id, "global_epoch": global_epoch_i, "grant_device": grant_device,
                  "session_epoch": session_epoch, "max_sessions_global": maximum, "issued_at": now,
                  "expires_epoch": expires_i, "claim_token_hash": claim_hash, "claim_endpoint": endpoint,
                  "claim_tls_fingerprint": tls_fp}
    allocation["signature"] = sign(CTRL_KEY, canonical(allocation))
    queued_path = queue_bundle(allocation)
    client = {"contract": CLIENT_LOGIN_CONTRACT, "version": VERSION, "allocation_id": allocation_id,
              "identity_id": identity_id, "product_id": product_id, "protocol": protocol,
              "selected_node": selected_node, "selected_name": grant.get("selected_name", ""),
              "endpoint": endpoint, "server_fingerprint": tls_fp, "claim_token": claim_token,
              "expires_epoch": expires_i}
    write_external_new(out_path, json.dumps(client, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n")
    audit("login-create", identity_id=identity_id, product_id=product_id, protocol=protocol,
          allocation_id=allocation_id, global_lease_id=global_id, node_id=selected_node,
          node_epoch=node_epoch, session_epoch=session_epoch, expires_epoch=expires_i, distribution_queued=1)
    print(f"contract={CLIENT_LOGIN_CONTRACT}"); print(f"login_bundle={out_path}"); print(f"allocation_id={allocation_id}")
    print(f"identity_id={identity_id}"); print(f"product_id={product_id}"); print(f"protocol={protocol}")
    print(f"selected_node={selected_node}"); print(f"selected_name={grant.get('selected_name','')}")
    print(f"claim_endpoint={endpoint}"); print(f"claim_tls_fingerprint={tls_fp}")
    print(f"expires_epoch={expires_i}"); print("claim_token_logged=0"); print("vpn_secret_on_controller=0")
    print("distribution_queued=1"); print(f"distribution_queue={queued_path}")
    print("controller_in_user_vpn_path=0")


def validate_bundle(bundle):
    base_expected = {"contract", "version", "allocation_id", "controller_id", "identity_id", "product_id", "protocol",
                     "region", "pool", "node_scope", "selected_node", "selected_name", "node_epoch", "global_lease_id",
                     "global_epoch", "grant_device", "session_epoch", "max_sessions_global", "issued_at", "expires_epoch",
                     "signature"}
    contract = bundle.get("contract") if isinstance(bundle, dict) else ""
    if contract == CONTRACT:
        expected = base_expected
    elif contract == CLAIM_CONTRACT:
        expected = base_expected | {"claim_token_hash", "claim_endpoint", "claim_tls_fingerprint"}
    else:
        die("Contrato de allocation inválido.", 64)
    if set(bundle) != expected or bundle.get("version") != VERSION:
        die("Versão/contrato de allocation inválido.", 64)
    enrollment, node_id, node_epoch = node_enrollment()
    if bundle.get("controller_id") != enrollment.get("controller_id"):
        die("Allocation pertence a outro controlador.", 67)
    if bundle.get("selected_node") != node_id or bundle.get("node_epoch") != node_epoch:
        die("Allocation foi emitida para outro nó ou node_epoch.", 67)
    validate_identity(bundle.get("identity_id")); validate_protocol(bundle.get("protocol"))
    if not IDENTITY_RE.fullmatch(str(bundle.get("product_id", ""))):
        die("product_id inválido na allocation.", 64)
    if not ID_RE.fullmatch(str(bundle.get("allocation_id", ""))) or not ID_RE.fullmatch(str(bundle.get("global_lease_id", ""))):
        die("IDs da allocation inválidos.", 64)
    if bundle.get("grant_device") != "alloc-" + bundle.get("allocation_id", ""):
        die("grant_device não corresponde à allocation.", 64)
    for field in ("node_epoch", "global_epoch", "session_epoch", "max_sessions_global", "issued_at", "expires_epoch"):
        value = bundle.get(field)
        if isinstance(value, bool) or not isinstance(value, int) or value < 1:
            die(f"{field} inválido na allocation.", 64)
    if contract == CLAIM_CONTRACT:
        if not re.fullmatch(r"[a-f0-9]{64}", str(bundle.get("claim_token_hash", ""))):
            die("claim_token_hash inválido na allocation.", 64)
        parse_public_endpoint(bundle.get("claim_endpoint", ""))
        normalize_fp(bundle.get("claim_tls_fingerprint", ""))
    now = int(time.time())
    if bundle["issued_at"] > now + 120 or bundle["expires_epoch"] <= now or bundle["expires_epoch"] <= bundle["issued_at"]:
        die("Allocation expirada ou com timestamp inválido.", 67)
    if not verify(NODE_CONTROLLER_PUB, canonical(bundle), bundle.get("signature", "")):
        die("Assinatura da allocation não confere.", 67)
    return bundle


def node_enable():
    init_dirs(); enrollment,node_id,node_epoch=node_enrollment(); lease=read_conf(NODE_LEASE_CONF)
    if lease.get("enabled")!="1" or lease.get("node_id")!=node_id or lease.get("node_epoch")!=str(node_epoch):
        die("Ative/configure a autoridade global de leases neste nó antes da allocation 0.8.5.",67)
    atomic_write(NODE_CONF,f"version=1\nenabled=1\nnode_id={node_id}\nnode_epoch={node_epoch}\n"
                           f"controller_id={enrollment.get('controller_id','')}\nupdated_epoch={int(time.time())}\n")
    enable_sync_timer()
    print("vpn_allocation_enforcement=1"); print(f"node_id={node_id}"); print(f"node_epoch={node_epoch}")
    print("automatic_distribution=1"); print("automatic_remote_provisioning=1"); print("sync_interval_seconds=3"); print("failure_mode=fail-closed")


def node_disable():
    init_dirs(); disable_sync_timer(False); conf=read_conf(NODE_CONF)
    if conf:
        atomic_write(NODE_CONF,f"version=1\nenabled=0\nnode_id={conf.get('node_id','')}\nnode_epoch={conf.get('node_epoch','')}\n"
                               f"controller_id={conf.get('controller_id','')}\nupdated_epoch={int(time.time())}\n")
    print("vpn_allocation_enforcement=0")


def node_enabled():
    conf=read_conf(NODE_CONF)
    if conf.get("enabled")!="1": return False
    try: enrollment,node_id,node_epoch=node_enrollment()
    except SystemExit: return False
    return conf.get("node_id")==node_id and conf.get("node_epoch")==str(node_epoch) and conf.get("controller_id")==enrollment.get("controller_id")


def bundle_path(allocation_id): return os.path.join(NODE_ACTIVE_DIR,allocation_id+".json")
def state_path(allocation_id): return os.path.join(NODE_STATE_DIR,allocation_id+".conf")


def state_write(allocation_id,status,token="",pending_until=0,session_id=""):
    atomic_write(state_path(allocation_id),f"version=1\nallocation_id={allocation_id}\nstatus={status}\nreservation_token={token}\n"
                                         f"pending_until={pending_until}\nlocal_session_id={session_id}\nupdated_epoch={int(time.time())}\n")


def cleanup_node_locked():
    now=int(time.time())
    for path in list(Path(NODE_ACTIVE_DIR).glob("*.json")):
        bundle=read_json(str(path)); allocation_id=path.stem
        if not bundle:
            try: path.unlink()
            except FileNotFoundError: pass
            try: os.unlink(state_path(allocation_id))
            except FileNotFoundError: pass
            continue
        try: expires=int(bundle.get("expires_epoch",0))
        except (TypeError,ValueError): expires=0
        if expires<=now:
            try: path.unlink()
            except FileNotFoundError: pass
            try: os.unlink(state_path(allocation_id))
            except FileNotFoundError: pass
            audit("expire-local",identity_id=bundle.get("identity_id"),allocation_id=allocation_id)
            continue
        st=read_conf(state_path(allocation_id))
        if st.get("status")=="pending":
            try: pending_until=int(st.get("pending_until","0"))
            except ValueError: pending_until=0
            if pending_until<=now:
                state_write(allocation_id,"ready")
                audit("reservation-timeout",identity_id=bundle.get("identity_id"),allocation_id=allocation_id)


def purge_older_identity_allocations(identity_id,minimum_epoch,keep_id=""):
    for path in list(Path(NODE_ACTIVE_DIR).glob("*.json")):
        bundle=read_json(str(path))
        if not bundle or bundle.get("identity_id")!=identity_id or path.stem==keep_id: continue
        try: epoch=int(bundle.get("session_epoch",0))
        except (TypeError,ValueError): epoch=0
        if epoch<minimum_epoch:
            try: path.unlink()
            except FileNotFoundError: pass
            try: os.unlink(state_path(path.stem))
            except FileNotFoundError: pass


def accept_bundle_object(raw_bundle):
    init_dirs()
    if not node_enabled(): die("Allocation enforcement está desabilitado neste nó.",67)
    bundle=validate_bundle(raw_bundle); identity_id=bundle["identity_id"]; allocation_id=bundle["allocation_id"]
    idempotent=False
    with open(LOCK_FILE,"r+") as lock:
        fcntl.flock(lock.fileno(),fcntl.LOCK_EX); cleanup_node_locked()
        seen=read_epoch(NODE_EPOCH_DIR,identity_id); incoming=bundle["session_epoch"]
        if incoming<seen: die("Allocation usa session_epoch antigo/fenced.",70)
        if incoming>seen:
            atomic_write(epoch_path(NODE_EPOCH_DIR,identity_id),str(incoming)+"\n")
            purge_older_identity_allocations(identity_id,incoming,allocation_id)
        dest=bundle_path(allocation_id)
        if os.path.exists(dest):
            current=read_json(dest)
            if current!=bundle: die("allocation_id colidiu com conteúdo diferente.",65)
            idempotent=True
        else:
            atomic_write(dest,json.dumps(bundle,sort_keys=True,separators=(",",":"))+"\n"); state_write(allocation_id,"ready")
            audit("accept",identity_id=identity_id,product_id=bundle["product_id"],protocol=bundle["protocol"],
                  allocation_id=allocation_id,global_lease_id=bundle["global_lease_id"],node_id=bundle["selected_node"],
                  session_epoch=incoming)
        fcntl.flock(lock.fileno(),fcntl.LOCK_UN)
    return bundle,idempotent


def accept_bundle(path):
    bundle,idempotent=accept_bundle_object(read_json(path))
    print("allocation_accepted=1"); print(f"idempotent={1 if idempotent else 0}"); print(f"allocation_id={bundle['allocation_id']}")
    print(f"identity_id={bundle['identity_id']}"); print(f"product_id={bundle['product_id']}"); print(f"protocol={bundle['protocol']}")
    print(f"global_lease_id={bundle['global_lease_id']}"); print(f"session_epoch={bundle['session_epoch']}")
    print(f"expires_epoch={bundle['expires_epoch']}")


def provision_receipt_path(allocation_id):
    if not ID_RE.fullmatch(str(allocation_id)): die("allocation_id inválido para receipt de provisionamento.",64)
    return os.path.join(NODE_PROVISION_DIR,allocation_id+".conf")


def receipt_matches(receipt,bundle):
    return (receipt.get("status")=="ok" and receipt.get("allocation_id")==bundle.get("allocation_id") and
            receipt.get("identity_id")==bundle.get("identity_id") and receipt.get("product_id")==bundle.get("product_id") and
            receipt.get("protocol")==bundle.get("protocol"))


def provision_bundle(bundle):
    init_dirs(); validate_local_claim_endpoint(bundle)
    path=provision_receipt_path(bundle["allocation_id"]); receipt=read_conf(path)
    if receipt:
        if not receipt_matches(receipt,bundle): die("Receipt local de provisionamento colidiu com outra allocation.",65)
        return receipt,True
    if not os.path.isfile(PROVISION_MODULE) or not os.access(PROVISION_MODULE,os.X_OK):
        die("Módulo de provisionamento local não está disponível no nó.",69)
    proc=subprocess.run([PROVISION_MODULE,"--ensure",bundle["identity_id"],bundle["product_id"],bundle["protocol"]],
                        stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,timeout=90,check=False)
    if proc.returncode!=0:
        audit("provision-failed",identity_id=bundle.get("identity_id"),product_id=bundle.get("product_id"),
              protocol=bundle.get("protocol"),allocation_id=bundle.get("allocation_id"),result=proc.returncode)
        die(proc.stderr.strip() or "Provisionamento local da allocation falhou.",proc.returncode)
    result=parse_kv(proc.stdout)
    if result.get("status")!="ok" or result.get("identity_id")!=bundle["identity_id"] or result.get("product_id")!=bundle["product_id"]:
        die("Provisionamento local retornou identidade/produto inesperado.",70)
    provisioned_protocols=result.get("protocols","").split(",")
    if bundle["protocol"] not in provisioned_protocols: die("Provisionamento local não confirmou o protocolo da allocation.",70)
    lines=["version=1","status=ok",f"allocation_id={bundle['allocation_id']}",f"identity_id={bundle['identity_id']}",
           f"product_id={bundle['product_id']}",f"protocol={bundle['protocol']}",
           f"resource_created={result.get('resource_created','0')}",f"provision_action={result.get('provision_action','')}",
           f"provisioned_epoch={int(time.time())}"]
    secret_keys=("ssh_user","ssh_password","wireguard_client","wireguard_ip","wireguard_ipv4","wireguard_ipv6","wireguard_profile",
                 "openvpn_client","openvpn_ipv6","openvpn_profile")
    for key in secret_keys:
        value=result.get(key)
        if value is not None and "\n" not in value and "\r" not in value:
            lines.append(f"{key}={value}")
    atomic_write(path,"\n".join(lines)+"\n")
    receipt=read_conf(path)
    audit("provision-ok",identity_id=bundle.get("identity_id"),product_id=bundle.get("product_id"),protocol=bundle.get("protocol"),
          allocation_id=bundle.get("allocation_id"),resource_created=result.get("resource_created","0"))
    return receipt,False



def claim_state_path(allocation_id):
    if not ID_RE.fullmatch(str(allocation_id)):
        die("allocation_id inválido para claim.", 64)
    return os.path.join(NODE_CLAIM_DIR, allocation_id + ".conf")


def strict_profile(path):
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        die("Profile provisionado não está disponível no nó.", 69)
    if not stat.S_ISREG(st.st_mode) or st.st_uid != 0 or stat.S_IMODE(st.st_mode) & 0o077 or st.st_size > MAX_PROFILE:
        die("Profile provisionado possui ownership, permissões ou tamanho inválidos.", 67)
    try:
        return Path(path).read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        die("Profile provisionado não pôde ser lido com segurança.", 70)


def claim(allocation_id):
    init_dirs()
    if not ID_RE.fullmatch(str(allocation_id)):
        die("allocation_id inválido.", 64)
    token = sys.stdin.readline(256).strip()
    if not CLAIM_TOKEN_RE.fullmatch(token):
        die("Claim inválido.", 67)
    with open(LOCK_FILE, "r+") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX); cleanup_node_locked()
        bundle = read_json(bundle_path(allocation_id))
        if not bundle or bundle.get("contract") != CLAIM_CONTRACT:
            die("Public login não está disponível para esta allocation.", 69)
        now = int(time.time())
        if int(bundle.get("expires_epoch", 0)) <= now:
            die("Public login expirou.", 69)
        seen = read_epoch(NODE_EPOCH_DIR, bundle.get("identity_id", ""))
        if int(bundle.get("session_epoch", 0)) != seen:
            die("Public login foi fenced por uma geração mais nova.", 67)
        expected = str(bundle.get("claim_token_hash", ""))
        actual = hashlib.sha256(token.encode("ascii")).hexdigest()
        if not hmac.compare_digest(expected, actual):
            audit("claim-denied", identity_id=bundle.get("identity_id"), protocol=bundle.get("protocol"),
                  allocation_id=allocation_id, reason="token")
            die("Claim inválido.", 67)
        claim_state = read_conf(claim_state_path(allocation_id))
        if claim_state.get("status") == "consumed":
            audit("claim-denied", identity_id=bundle.get("identity_id"), protocol=bundle.get("protocol"),
                  allocation_id=allocation_id, reason="consumed")
            die("Public login já foi consumido.", 67)
        receipt = read_conf(provision_receipt_path(allocation_id))
        if not receipt_matches(receipt, bundle):
            die("Credencial ainda não foi provisionada no nó selecionado.", 69)
        protocol = bundle["protocol"]
        result = {"contract": CLAIM_RESULT_CONTRACT, "version": VERSION, "allocation_id": allocation_id,
                  "identity_id": bundle["identity_id"], "product_id": bundle["product_id"], "protocol": protocol,
                  "selected_node": bundle["selected_node"], "expires_epoch": bundle["expires_epoch"]}
        if protocol == "ssh":
            username, password = receipt.get("ssh_user", ""), receipt.get("ssh_password", "")
            if not username or not password:
                die("Esta allocation SSH reutilizou uma credencial sem senha recuperável; claim recusado sem rotação implícita.", 69)
            result.update({"username": username, "password": password})
        elif protocol == "wireguard":
            profile_path = receipt.get("wireguard_profile", "")
            result.update({"profile_format": "wireguard", "profile": strict_profile(profile_path),
                           "address": receipt.get("wireguard_ip", ""), "address_ipv6": receipt.get("wireguard_ipv6", "")})
        elif protocol == "openvpn":
            profile_path = receipt.get("openvpn_profile", "")
            result.update({"profile_format": "openvpn", "profile": strict_profile(profile_path),
                           "address_ipv6": receipt.get("openvpn_ipv6", "")})
        else:
            die("Protocolo do public login não é suportado.", 64)
        atomic_write(claim_state_path(allocation_id),
                     f"version=1\nallocation_id={allocation_id}\nstatus=consumed\nconsumed_epoch={now}\n")
        audit("claim-ok", identity_id=bundle.get("identity_id"), product_id=bundle.get("product_id"),
              protocol=protocol, allocation_id=allocation_id, result="one-shot")
        fcntl.flock(lock.fileno(), fcntl.LOCK_UN)
    print(json.dumps(result, sort_keys=True, separators=(",", ":"), ensure_ascii=False))


def sync_node(limit=8):
    init_dirs()
    if not node_enabled(): die("Allocation enforcement está desabilitado neste nó.",67)
    try: limit=int(limit)
    except (TypeError,ValueError): die("limit de sync inválido.",64)
    if limit<1 or limit>8: die("limit de sync deve ficar entre 1 e 8.",64)
    proc=subprocess.run([LEASE_MODULE,"--allocation-pull-node",str(limit)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,
                        text=True,timeout=20,check=False)
    if proc.returncode!=0: die(proc.stderr.strip() or "Falha ao buscar allocations no controlador.",proc.returncode)
    try: result=json.loads(proc.stdout)
    except json.JSONDecodeError: die("Resposta de distribuição de allocation não é JSON válido.",70)
    bundles=result.get("bundles",[]) if isinstance(result,dict) else []
    if not isinstance(bundles,list) or len(bundles)>limit: die("Resposta de distribuição de allocation inválida.",70)
    accepted=idempotent_count=acked=provisioned=provision_idempotent=0
    for raw in bundles:
        bundle,was_idempotent=accept_bundle_object(raw)
        if was_idempotent: idempotent_count+=1
        else: accepted+=1
        _,was_provisioned=provision_bundle(bundle)
        if was_provisioned: provision_idempotent+=1
        else: provisioned+=1
        ack=subprocess.run([LEASE_MODULE,"--allocation-ack-node",bundle["allocation_id"]],stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE,text=True,timeout=20,check=False)
        if ack.returncode!=0:
            audit("sync-ack-failed",identity_id=bundle.get("identity_id"),allocation_id=bundle.get("allocation_id"))
            die(ack.stderr.strip() or "Allocation foi persistida localmente, mas o ACK ao controlador falhou.",ack.returncode)
        acked+=1
        audit("sync-delivered",identity_id=bundle.get("identity_id"),protocol=bundle.get("protocol"),
              allocation_id=bundle.get("allocation_id"),global_lease_id=bundle.get("global_lease_id"))
    print(f"allocations_pulled={len(bundles)}"); print(f"allocations_accepted={accepted}")
    print(f"allocations_idempotent={idempotent_count}"); print(f"allocations_provisioned={provisioned}")
    print(f"allocations_provision_idempotent={provision_idempotent}"); print(f"allocations_acked={acked}")
    print("delivery_transport=lease-control-pull"); print("automatic_remote_provisioning=1")


def reserve(identity_id,protocol):
    init_dirs()
    if not node_enabled(): die("Allocation enforcement está desabilitado neste nó.",67)
    identity_id=validate_identity(identity_id); protocol=validate_protocol(protocol); now=int(time.time())
    with open(LOCK_FILE,"r+") as lock:
        fcntl.flock(lock.fileno(),fcntl.LOCK_EX); cleanup_node_locked(); seen=read_epoch(NODE_EPOCH_DIR,identity_id)
        chosen=None
        for path in sorted(Path(NODE_ACTIVE_DIR).glob("*.json")):
            bundle=read_json(str(path))
            if not bundle or bundle.get("identity_id")!=identity_id or bundle.get("protocol")!=protocol: continue
            if bundle.get("session_epoch")!=seen or bundle.get("expires_epoch",0)<=now: continue
            st=read_conf(state_path(path.stem))
            if st.get("status","ready")!="ready": continue
            chosen=bundle; break
        if not chosen:
            audit("reserve-denied",identity_id=identity_id,protocol=protocol,reason="no-current-allocation")
            die("Nenhuma allocation atual/autorizada disponível para esta sessão.",69)
        token=secrets.token_hex(16); pending_until=min(int(chosen["expires_epoch"]),now+PENDING_TTL)
        state_write(chosen["allocation_id"],"pending",token,pending_until)
        audit("reserve",identity_id=identity_id,protocol=protocol,allocation_id=chosen["allocation_id"],
              global_lease_id=chosen["global_lease_id"],pending_until=pending_until)
        fcntl.flock(lock.fileno(),fcntl.LOCK_UN)
    print(f"allocation_id={chosen['allocation_id']}"); print(f"reservation_token={token}")
    print(f"identity_id={identity_id}"); print(f"product_id={chosen['product_id']}"); print(f"protocol={protocol}")
    print(f"global_lease_id={chosen['global_lease_id']}"); print(f"grant_device={chosen['grant_device']}")
    print(f"global_epoch={chosen['global_epoch']}"); print(f"session_epoch={chosen['session_epoch']}")
    print(f"expires_epoch={chosen['expires_epoch']}")


def validate_reservation(allocation_id,token):
    if not ID_RE.fullmatch(str(allocation_id)): die("allocation_id inválido.",64)
    if not TOKEN_RE.fullmatch(str(token)): die("reservation_token inválido.",64)
    bundle=read_json(bundle_path(allocation_id))
    if not bundle: die("Allocation local não encontrada.",66)
    st=read_conf(state_path(allocation_id))
    if st.get("status")!="pending" or st.get("reservation_token")!=token:
        die("Reserva de allocation não corresponde ao token atual.",67)
    try: pending_until=int(st.get("pending_until","0"))
    except ValueError: pending_until=0
    if pending_until<=int(time.time()) or int(bundle.get("expires_epoch",0))<=int(time.time()):
        state_write(allocation_id,"ready"); die("Reserva de allocation expirou.",69)
    return bundle,st


def commit(allocation_id,token,local_session_id):
    init_dirs()
    if not ID_RE.fullmatch(str(local_session_id)): die("local_session_id inválido.",64)
    with open(LOCK_FILE,"r+") as lock:
        fcntl.flock(lock.fileno(),fcntl.LOCK_EX); cleanup_node_locked(); bundle,_=validate_reservation(allocation_id,token)
        state_write(allocation_id,"consumed","",0,local_session_id)
        audit("commit",identity_id=bundle.get("identity_id"),protocol=bundle.get("protocol"),allocation_id=allocation_id,
              global_lease_id=bundle.get("global_lease_id"),local_session_id=local_session_id)
        fcntl.flock(lock.fileno(),fcntl.LOCK_UN)
    print("allocation_committed=1"); print(f"allocation_id={allocation_id}"); print(f"local_session_id={local_session_id}")


def abort(allocation_id,token):
    init_dirs()
    with open(LOCK_FILE,"r+") as lock:
        fcntl.flock(lock.fileno(),fcntl.LOCK_EX); cleanup_node_locked(); bundle,_=validate_reservation(allocation_id,token)
        state_write(allocation_id,"ready")
        audit("abort",identity_id=bundle.get("identity_id"),protocol=bundle.get("protocol"),allocation_id=allocation_id,
              global_lease_id=bundle.get("global_lease_id"))
        fcntl.flock(lock.fileno(),fcntl.LOCK_UN)
    print("allocation_aborted=1")


def controller_revoke(identity_id,reason="admin"):
    init_dirs(); identity_id=validate_identity(identity_id)
    if not re.fullmatch(r"[A-Za-z0-9_.:-]{1,64}",reason): die("Motivo inválido.",64)
    new_epoch=bump_epoch(CTRL_EPOCH_DIR,identity_id); queued_removed=purge_controller_outbox_identity(identity_id)
    proc=subprocess.run([LEASE_MODULE,"--controller-revoke",identity_id,reason],stdout=subprocess.PIPE,stderr=subprocess.PIPE,
                        text=True,timeout=15,check=False)
    if proc.returncode!=0: die(proc.stderr.strip() or "Falha ao revogar grants/leases globais.",proc.returncode)
    result=parse_kv(proc.stdout)
    audit("revoke",identity_id=identity_id,reason=reason,session_epoch=new_epoch,global_epoch=result.get("global_epoch",""),
          leases_revoked=result.get("leases_revoked",""))
    print(f"identity_id={identity_id}"); print(f"session_epoch={new_epoch}"); print(f"global_epoch={result.get('global_epoch','')}")
    print(f"leases_revoked={result.get('leases_revoked','')}"); print(f"queued_allocations_revoked={queued_removed}")


def node_status():
    init_dirs(); conf=read_conf(NODE_CONF)
    print(f"contract={STATUS_CONTRACT}"); print(f"enabled={1 if node_enabled() else 0}")
    print(f"node_id={conf.get('node_id','')}"); print(f"node_epoch={conf.get('node_epoch','')}")
    print(f"controller_id={conf.get('controller_id','')}"); print("signed_allocation_bundle=1")
    print("exact_global_grant_required_when_enabled=1"); print("automatic_distribution=1"); print("sync_interval_seconds=3")
    print(f"sync_timer_active={1 if systemctl('is-active','--quiet','manager-hive-allocation-sync.timer')==0 else 0}")
    print("delivery_transport=lease-control-pull"); print("automatic_remote_provisioning=1"); print("controller_in_user_vpn_path=0")
    print("public_login_claim=1"); print("public_login_transport=direct-node-tls1.3"); print("claim_one_shot=1")
    print(f"provision_receipts={sum(1 for path in Path(NODE_PROVISION_DIR).glob('*.conf') if read_conf(str(path)).get('status')=='ok')}")
    ready=pending=consumed=0
    for path in Path(NODE_STATE_DIR).glob("*.conf"):
        state=read_conf(str(path)).get("status")
        if state=="ready": ready+=1
        elif state=="pending": pending+=1
        elif state=="consumed": consumed+=1
    print(f"allocations_ready={ready}"); print(f"allocations_pending={pending}"); print(f"allocations_consumed={consumed}")


def controller_status():
    init_dirs(); ctrl=controller_identity()
    queued=sum(1 for path in Path(CTRL_OUTBOX_DIR).glob("node-*/*.json") if read_json(str(path)))
    print(f"contract={STATUS_CONTRACT}"); print("role=controller"); print(f"controller_id={ctrl.get('controller_id','')}")
    print("signed_allocation_bundle=1"); print("global_grant_binding=1"); print("session_epoch_fencing=1")
    print("automatic_distribution=1"); print("delivery_transport=lease-control-pull"); print(f"queued_allocations={queued}")
    print("protocols=ssh,wireguard,openvpn"); print("public_login_contract=manager-hive-public-login-v1")
    print("vpn_secret_on_controller=0"); print("controller_in_user_vpn_path=0")


def audit(event,**fields):
    ensure_dir(os.path.dirname(AUDIT_FILE),0o750); record={"epoch":int(time.time()),"event":event}
    for key,value in fields.items():
        if isinstance(value,(str,int,float,bool)) or value is None: record[key]=value
    fd=os.open(AUDIT_FILE,os.O_WRONLY|os.O_CREAT|os.O_APPEND,0o600)
    try: os.write(fd,(json.dumps(record,sort_keys=True,separators=(",",":"))+"\n").encode("utf-8"))
    finally: os.close(fd)


def install():
    init_dirs()
    if read_conf(NODE_CONF).get("enabled")=="1" and node_enabled(): enable_sync_timer()


def detach():
    disable_sync_timer(True)


def purge():
    detach(); shutil.rmtree(ALLOC_ETC,ignore_errors=True); shutil.rmtree(DATA_DIR,ignore_errors=True)
    try: os.unlink(AUDIT_FILE)
    except FileNotFoundError: pass


def usage():
    print("Uso: hive_allocations.sh {--status|--node-enable|--node-disable|--accept BUNDLE|--sync [LIMIT]|--claim ALLOCATION_ID|"
          "--controller-status|--controller-endpoint NODE_ID HOST PORT TLS_FP|"
          "--controller-create ID PROTO OUT [REGION] [POOL] [STICKY] [SCOPE] [TTL]|"
          "--controller-login ID PROTO OUT [REGION] [POOL] [STICKY] [SCOPE] [TTL]|--controller-revoke ID [REASON]|"
          "--reserve ID PROTO|--commit ALLOCATION_ID TOKEN SESSION|--abort ALLOCATION_ID TOKEN|--install|--detach|--purge}",
          file=sys.stderr)
    raise SystemExit(64)


def main(argv):
    cmd=argv[0] if argv else "--status"
    if cmd=="--status": node_status(); return
    if cmd=="--node-enable": node_enable(); return
    if cmd=="--node-disable": node_disable(); return
    if cmd=="--accept" and len(argv)==2: accept_bundle(argv[1]); return
    if cmd=="--sync" and len(argv) in {1,2}: sync_node(argv[1] if len(argv)==2 else 8); return
    if cmd=="--claim" and len(argv)==2: claim(argv[1]); return
    if cmd=="--controller-status": controller_status(); return
    if cmd=="--controller-endpoint" and len(argv)==5: controller_endpoint_set(argv[1],argv[2],argv[3],argv[4]); return
    if cmd=="--controller-create" and 4<=len(argv)<=9:
        controller_create(argv[1],argv[2],argv[3],argv[4] if len(argv)>4 else "",argv[5] if len(argv)>5 else "",
                          argv[6] if len(argv)>6 else "",argv[7] if len(argv)>7 else "*",
                          argv[8] if len(argv)>8 else DEFAULT_TTL); return
    if cmd=="--controller-login" and 4<=len(argv)<=9:
        controller_login(argv[1],argv[2],argv[3],argv[4] if len(argv)>4 else "",argv[5] if len(argv)>5 else "",
                         argv[6] if len(argv)>6 else "",argv[7] if len(argv)>7 else "*",
                         argv[8] if len(argv)>8 else DEFAULT_LOGIN_TTL); return
    if cmd=="--controller-revoke" and len(argv) in {2,3}:
        controller_revoke(argv[1],argv[2] if len(argv)==3 else "admin"); return
    if cmd=="--reserve" and len(argv)==3: reserve(argv[1],argv[2]); return
    if cmd=="--commit" and len(argv)==4: commit(argv[1],argv[2],argv[3]); return
    if cmd=="--abort" and len(argv)==3: abort(argv[1],argv[2]); return
    if cmd=="--install": install(); return
    if cmd=="--detach": detach(); return
    if cmd=="--purge": purge(); return
    usage()

main(sys.argv[1:])
PY
