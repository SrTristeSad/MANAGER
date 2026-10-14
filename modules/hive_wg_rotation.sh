#!/usr/bin/env bash
set -Eeuo pipefail

MANAGER_HOME="${MANAGER_HOME:-/opt/manager}"
MANAGER_ETC="${MANAGER_ETC:-/etc/manager}"
MANAGER_HIVE_WG_DIR="${MANAGER_HIVE_WG_DIR:-/etc/wireguard}"
# shellcheck source=/dev/null
source "$MANAGER_HOME/lib/common.sh"
require_root

command -v python3 >/dev/null 2>&1 || { err "Python 3 é necessário para rotação WireGuard da Colmeia."; exit 69; }
command -v openssl >/dev/null 2>&1 || { err "OpenSSL é necessário para rotação WireGuard da Colmeia."; exit 69; }
command -v wg >/dev/null 2>&1 || { err "wireguard-tools é necessário para rotação WireGuard da Colmeia."; exit 69; }

python3 - "$@" <<'PY'
import base64
import fcntl
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path

MANAGER_HOME = os.environ.get("MANAGER_HOME", "/opt/manager")
MANAGER_ETC = os.environ.get("MANAGER_ETC", "/etc/manager")
WG_DIR = os.environ.get("MANAGER_HIVE_WG_DIR", "/etc/wireguard")
HIVE_DIR = os.path.join(MANAGER_ETC, "hive")
NODE_DIR = os.path.join(HIVE_DIR, "node")
NETWORK_DIR = os.path.join(HIVE_DIR, "network")
NODE_ID_KEY = os.path.join(NODE_DIR, "node.key")
NODE_ENROLLMENT = os.path.join(NODE_DIR, "enrollment.conf")
NODE_CONTROLLER_CONF = os.path.join(NODE_DIR, "controller.conf")
NODE_CONTROLLER_PUB = os.path.join(NODE_DIR, "controller.pub")
NODE_WG_KEY = os.path.join(NETWORK_DIR, "node.key")
NODE_WG_PUB = os.path.join(NETWORK_DIR, "node.pub")
NODE_NETWORK_CONF = os.path.join(NETWORK_DIR, "network.conf")
NODE_TOPOLOGY = os.path.join(NETWORK_DIR, "topology.json")
NODE_ROT_DIR = os.path.join(NETWORK_DIR, "rotation")
NODE_PENDING = os.path.join(NODE_ROT_DIR, "pending")
NODE_HISTORY = os.path.join(NODE_ROT_DIR, "history")
NODE_REPLAY = os.path.join(NODE_ROT_DIR, "replay")
NODE_ROT_STATE = os.path.join(NODE_ROT_DIR, "state.conf")
NODE_LOCK = os.path.join(NODE_ROT_DIR, "rotation.lock")

CTRL_DIR = os.path.join(HIVE_DIR, "controller")
CTRL_KEY = os.path.join(CTRL_DIR, "controller.key")
CTRL_PUB = os.path.join(CTRL_DIR, "controller.pub")
CTRL_CONF = os.path.join(CTRL_DIR, "controller.conf")
CTRL_NODES = os.path.join(CTRL_DIR, "nodes")
CTRL_KEY_ROT_STATE = os.path.join(CTRL_DIR, "rotation", "state.conf")
CTRL_NET_DIR = os.path.join(CTRL_DIR, "network")
CTRL_NET_CONF = os.path.join(CTRL_NET_DIR, "network.conf")
CTRL_NET_NODES = os.path.join(CTRL_NET_DIR, "nodes")
CTRL_ROT_DIR = os.path.join(CTRL_NET_DIR, "rotation")
CTRL_PENDING = os.path.join(CTRL_ROT_DIR, "pending")
CTRL_HISTORY = os.path.join(CTRL_ROT_DIR, "history")
CTRL_REPLAY = os.path.join(CTRL_ROT_DIR, "replay")
CTRL_LOCK = os.path.join(CTRL_ROT_DIR, "rotation.lock")

NETWORK_MODULE = os.path.join(MANAGER_HOME, "modules", "hive_network.sh")
REQ_CONTRACT = "manager-hive-wg-key-rotation-request-v1"
AUTH_CONTRACT = "manager-hive-wg-key-rotation-authorization-v1"
BUNDLE_CONTRACT = "manager-hive-network-bundle-v1"
STATUS_CONTRACT = "manager-hive-wg-key-rotation-v1"
VERSION = 1
MAX_AGE = 86400
NODE_ID_RE = re.compile(r"^node-[a-f0-9]{16}$")
ROT_ID_RE = re.compile(r"^wgrot-[a-f0-9]{24}$")
WG_KEY_RE = re.compile(r"^[A-Za-z0-9+/]{43}=$")
NONCE_RE = re.compile(r"^[A-Za-z0-9_-]{32,96}$")


def die(message, code=70):
    print(message, file=sys.stderr)
    raise SystemExit(code)


def ensure_dir(path):
    os.makedirs(path, mode=0o700, exist_ok=True)
    os.chmod(path, 0o700)


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
                k, v = raw.split("=", 1)
                data[k] = v
    return data


def conf_text(data, keys):
    return "".join(f"{k}={data.get(k, '')}\n" for k in keys)


def strict_regular(path, max_size=1048576):
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        die(f"Arquivo não encontrado: {path}", 66)
    if not stat.S_ISREG(st.st_mode) or st.st_size > max_size:
        die(f"Arquivo recusado: {path}", 64)


def read_json(path):
    strict_regular(path)
    try:
        with open(path, "r", encoding="utf-8") as fh:
            value = json.load(fh)
    except (UnicodeDecodeError, json.JSONDecodeError):
        die("Documento JSON inválido.", 64)
    if not isinstance(value, dict):
        die("Documento precisa ser objeto JSON.", 64)
    return value


def canonical(obj):
    clean = dict(obj)
    clean.pop("signature", None)
    return json.dumps(clean, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def signed_digest(obj):
    sig = obj.get("signature", "")
    if not isinstance(sig, str):
        sig = ""
    return hashlib.sha256(canonical(obj) + b"\0" + sig.encode("ascii", "ignore")).hexdigest()


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


def openssl_sign(private_path, payload):
    if not os.path.isfile(private_path):
        die("Chave privada Ed25519 necessária não foi encontrada.", 69)
    dfd, dpath = tempfile.mkstemp(prefix="hive-wgrot-data-")
    sfd, spath = tempfile.mkstemp(prefix="hive-wgrot-sig-")
    os.close(sfd)
    try:
        os.fchmod(dfd, 0o600)
        with os.fdopen(dfd, "wb") as fh:
            fh.write(payload)
        proc = subprocess.run(
            ["openssl", "pkeyutl", "-sign", "-inkey", private_path, "-rawin", "-in", dpath, "-out", spath],
            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=20, check=False,
        )
        if proc.returncode != 0:
            die("Falha ao assinar contrato de rotação WireGuard.")
        sig = Path(spath).read_bytes()
    finally:
        for p in (dpath, spath):
            try:
                os.unlink(p)
            except FileNotFoundError:
                pass
    if len(sig) != 64:
        die("Assinatura Ed25519 inválida.")
    return base64.b64encode(sig).decode("ascii")


def openssl_verify(pub_path, payload, signature_text):
    try:
        sig = base64.b64decode(signature_text.encode("ascii"), validate=True)
    except Exception:
        return False
    if len(sig) != 64:
        return False
    dfd, dpath = tempfile.mkstemp(prefix="hive-wgrot-data-")
    sfd, spath = tempfile.mkstemp(prefix="hive-wgrot-sig-")
    try:
        os.fchmod(dfd, 0o600)
        os.fchmod(sfd, 0o600)
        with os.fdopen(dfd, "wb") as fh:
            fh.write(payload)
        with os.fdopen(sfd, "wb") as fh:
            fh.write(sig)
        proc = subprocess.run(
            ["openssl", "pkeyutl", "-verify", "-pubin", "-inkey", pub_path, "-rawin", "-in", dpath, "-sigfile", spath],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=20, check=False,
        )
        return proc.returncode == 0
    finally:
        for p in (dpath, spath):
            try:
                os.unlink(p)
            except FileNotFoundError:
                pass


def fresh(obj):
    issued = obj.get("issued_at")
    if isinstance(issued, bool) or not isinstance(issued, int) or abs(int(time.time()) - issued) > MAX_AGE:
        die("Contrato de rotação WireGuard expirado ou com timestamp inválido.", 67)
    nonce = obj.get("nonce")
    if not isinstance(nonce, str) or not NONCE_RE.fullmatch(nonce):
        die("Nonce de rotação WireGuard inválido.", 64)


def nonce_path(root, scope, nonce):
    ensure_dir(root)
    scope_dir = os.path.join(root, re.sub(r"[^A-Za-z0-9_.:-]", "_", scope)[:96])
    ensure_dir(scope_dir)
    return os.path.join(scope_dir, hashlib.sha256(nonce.encode("utf-8")).hexdigest())


def consume_nonce(root, scope, nonce):
    path = nonce_path(root, scope, nonce)
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        die("Replay de rotação WireGuard recusado.", 67)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(str(int(time.time())) + "\n")
        fh.flush()
        os.fsync(fh.fileno())


def valid_wg_key(value):
    if not isinstance(value, str) or not WG_KEY_RE.fullmatch(value):
        return False
    try:
        return len(base64.b64decode(value, validate=True)) == 32
    except Exception:
        return False


def wg_key_id(public):
    if not valid_wg_key(public):
        die("Chave pública WireGuard inválida.", 64)
    return "wg-" + hashlib.sha256(base64.b64decode(public)).hexdigest()[:16]


def derive_wg_public(private):
    if not valid_wg_key(private):
        die("Chave privada WireGuard inválida.", 67)
    proc = subprocess.run(
        ["wg", "pubkey"], input=private + "\n", text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        timeout=10, check=False,
    )
    if proc.returncode != 0:
        die("Não foi possível derivar chave pública WireGuard.", 69)
    public = proc.stdout.strip()
    if not valid_wg_key(public):
        die("wireguard-tools retornou chave pública inválida.", 69)
    return public


def generate_staged_wg(stage_key, stage_pub):
    if os.path.lexists(stage_key) or os.path.lexists(stage_pub):
        die("Já existe material WireGuard staged; conclua a rotação atual primeiro.", 65)
    proc = subprocess.run(["wg", "genkey"], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10, check=False)
    if proc.returncode != 0:
        die("Não foi possível gerar nova chave WireGuard.", 69)
    private = proc.stdout.strip()
    public = derive_wg_public(private)
    atomic_write(stage_key, private + "\n", 0o600)
    atomic_write(stage_pub, public + "\n", 0o600)
    return private, public


def live_wg():
    if not os.path.isfile(NODE_WG_KEY) or not os.path.isfile(NODE_WG_PUB):
        die("A identidade WireGuard da malha ainda não foi inicializada.", 67)
    private = Path(NODE_WG_KEY).read_text(encoding="utf-8").strip()
    public = Path(NODE_WG_PUB).read_text(encoding="utf-8").strip()
    if derive_wg_public(private) != public:
        die("Chave privada WireGuard local não corresponde à chave pública.", 67)
    return private, public, wg_key_id(public)


def controller_epoch():
    state = read_conf(CTRL_KEY_ROT_STATE)
    try:
        value = int(state.get("controller_epoch", "1"))
    except ValueError:
        value = 0
    if value < 1:
        die("controller_epoch inválido.", 67)
    return value


def node_controller_epoch():
    conf = read_conf(NODE_CONTROLLER_CONF)
    try:
        value = int(conf.get("controller_epoch", "1"))
    except ValueError:
        value = 0
    if value < 1:
        die("controller_epoch local inválido.", 67)
    return value


def node_context(strict_topology=True):
    enroll = read_conf(NODE_ENROLLMENT)
    ctrl = read_conf(NODE_CONTROLLER_CONF)
    net = read_conf(NODE_NETWORK_CONF)
    if not enroll or not ctrl or not net or not os.path.isfile(NODE_ID_KEY) or not os.path.isfile(NODE_CONTROLLER_PUB):
        die("O nó precisa estar enrolled e com a malha mgh0 configurada antes da rotação.", 67)
    node_id = enroll.get("node_id", "")
    if not NODE_ID_RE.fullmatch(node_id):
        die("node_id local inválido.", 67)
    try:
        node_epoch = int(enroll.get("node_epoch", "0"))
        config_epoch = int(net.get("config_epoch", "0"))
        network_generation = int(net.get("network_generation", "0"))
    except ValueError:
        die("Epoch/generation local inválido.", 67)
    if node_epoch < 1 or config_epoch < 1 or network_generation < 1:
        die("Epoch/generation local inválido.", 67)
    if ctrl.get("controller_id") != enroll.get("controller_id"):
        die("Enrollment e pin do controlador estão inconsistentes.", 67)
    private, public, kid = live_wg()
    if os.path.isfile(NODE_TOPOLOGY):
        topology = read_json(NODE_TOPOLOGY)
        target = topology.get("target")
        if not isinstance(target, dict) or target.get("node_id") != node_id:
            die("Topologia local não corresponde ao nó.", 67)
        if strict_topology and (target.get("wireguard_public_key") != public or target.get("wireguard_key_id") != kid):
            die("Topologia local não corresponde à chave WireGuard ativa.", 67)
        if target.get("network_generation") != network_generation or topology.get("config_epoch") != config_epoch:
            die("Topologia e estado local da malha divergem.", 67)
    return enroll, ctrl, net, node_id, node_epoch, config_epoch, network_generation, private, public, kid


def controller_context():
    ctrl = read_conf(CTRL_CONF)
    net = read_conf(CTRL_NET_CONF)
    if not ctrl or not net or not os.path.isfile(CTRL_KEY) or not os.path.isfile(CTRL_PUB):
        die("Controlador e rede privada da Colmeia precisam estar inicializados.", 67)
    try:
        config_epoch = int(net.get("config_epoch", "0"))
    except ValueError:
        config_epoch = 0
    if config_epoch < 1:
        die("config_epoch do controlador inválido.", 67)
    return ctrl, net, controller_epoch(), config_epoch


def controller_node_identity(node_id):
    if not NODE_ID_RE.fullmatch(node_id):
        die("node_id inválido.", 64)
    conf_path = os.path.join(CTRL_NODES, node_id + ".conf")
    pub_path = os.path.join(CTRL_NODES, node_id + ".pub")
    conf = read_conf(conf_path)
    if not conf or not os.path.isfile(pub_path):
        die("Nó não está enrolled no controlador.", 67)
    try:
        node_epoch = int(conf.get("node_epoch", "0"))
    except ValueError:
        node_epoch = 0
    if conf.get("enabled") != "1" or conf.get("revoked_epoch", "0") != "0" or node_epoch < 1:
        die("Nó está desabilitado/revogado.", 67)
    return conf, pub_path, node_epoch


def controller_network_node(node_id):
    path = os.path.join(CTRL_NET_NODES, node_id + ".conf")
    conf = read_conf(path)
    if not conf:
        die("Nó não possui estado de rede aprovado no controlador.", 66)
    try:
        generation = int(conf.get("network_generation", "0"))
    except ValueError:
        generation = 0
    if conf.get("enabled") != "1" or generation < 1:
        die("Nó não está ativo na topologia privada.", 67)
    if not valid_wg_key(conf.get("wireguard_public_key", "")):
        die("Registro WireGuard do nó é inválido.", 67)
    return path, conf, generation


def pending_node_paths():
    return (
        os.path.join(NODE_PENDING, "new.key"),
        os.path.join(NODE_PENDING, "new.pub"),
        os.path.join(NODE_PENDING, "request.json"),
        os.path.join(NODE_PENDING, "pending.conf"),
    )


def lock(path):
    ensure_dir(os.path.dirname(path))
    fh = open(path, "a+", encoding="utf-8")
    os.chmod(path, 0o600)
    fcntl.flock(fh.fileno(), fcntl.LOCK_EX)
    return fh


def node_prepare(out_path):
    with lock(NODE_LOCK):
        enroll, ctrl, net, node_id, node_epoch, config_epoch, generation, _, current_pub, current_kid = node_context()
        stage_key, stage_pub, req_path, pending_conf = pending_node_paths()
        if os.path.isfile(req_path) and os.path.isfile(stage_key) and os.path.isfile(stage_pub):
            req = read_json(req_path)
            write_external_new(out_path, json.dumps(req, sort_keys=True, separators=(",", ":")) + "\n")
            print("rotation_pending=1")
            print("cached_request=1")
            print(f"rotation_id={req.get('rotation_id','')}")
            print(f"node_id={node_id}")
            return
        if os.path.lexists(NODE_PENDING):
            die("Estado staged WireGuard está incompleto; intervenção manual necessária.", 65)
        ensure_dir(NODE_PENDING)
        _, new_pub = generate_staged_wg(stage_key, stage_pub)
        new_kid = wg_key_id(new_pub)
        if new_pub == current_pub:
            die("A nova chave WireGuard não pode ser igual à atual.", 65)
        rotation_id = "wgrot-" + os.urandom(12).hex()
        req = {
            "contract": REQ_CONTRACT,
            "version": VERSION,
            "rotation_id": rotation_id,
            "controller_id": ctrl.get("controller_id", ""),
            "controller_epoch": node_controller_epoch(),
            "node_id": node_id,
            "node_epoch": node_epoch,
            "config_epoch": config_epoch,
            "network_generation": generation,
            "current_wireguard_key_id": current_kid,
            "current_wireguard_public_key": current_pub,
            "new_wireguard_key_id": new_kid,
            "new_wireguard_public_key": new_pub,
            "issued_at": int(time.time()),
            "nonce": base64.urlsafe_b64encode(os.urandom(24)).decode("ascii").rstrip("="),
        }
        req["signature"] = openssl_sign(NODE_ID_KEY, canonical(req))
        text = json.dumps(req, sort_keys=True, separators=(",", ":")) + "\n"
        atomic_write(req_path, text)
        atomic_write(
            pending_conf,
            f"version=1\nrotation_id={rotation_id}\nnode_id={node_id}\nnode_epoch={node_epoch}\n"
            f"controller_epoch={req['controller_epoch']}\nconfig_epoch_from={config_epoch}\n"
            f"network_generation_from={generation}\nold_wireguard_key_id={current_kid}\n"
            f"new_wireguard_key_id={new_kid}\ncreated_epoch={int(time.time())}\n",
        )
        write_external_new(out_path, text)
        print("rotation_pending=1")
        print("cached_request=0")
        print(f"rotation_id={rotation_id}")
        print(f"node_id={node_id}")
        print(f"node_epoch={node_epoch}")
        print(f"config_epoch_from={config_epoch}")
        print(f"network_generation_from={generation}")
        print(f"new_wireguard_key_id={new_kid}")


def validate_rotation_request(req):
    expected = {
        "contract", "version", "rotation_id", "controller_id", "controller_epoch", "node_id", "node_epoch",
        "config_epoch", "network_generation", "current_wireguard_key_id", "current_wireguard_public_key",
        "new_wireguard_key_id", "new_wireguard_public_key", "issued_at", "nonce", "signature",
    }
    if set(req) != expected or req.get("contract") != REQ_CONTRACT or req.get("version") != VERSION:
        die("Contrato de request de rotação WireGuard inválido.", 64)
    if not ROT_ID_RE.fullmatch(req.get("rotation_id", "")):
        die("rotation_id WireGuard inválido.", 64)
    fresh(req)
    ctrl, net, ctrl_epoch, config_epoch = controller_context()
    if req.get("controller_id") != ctrl.get("controller_id") or req.get("controller_epoch") != ctrl_epoch:
        die("Request foi emitido para outra geração do controlador.", 67)
    node_id = req.get("node_id", "")
    _, pub_path, node_epoch = controller_node_identity(node_id)
    if req.get("node_epoch") != node_epoch:
        die("Request cercado por node_epoch diferente do atual.", 67)
    net_path, net_node, generation = controller_network_node(node_id)
    if req.get("config_epoch") != config_epoch or req.get("network_generation") != generation:
        die("Request cercado por config_epoch/network_generation obsoleto.", 67)
    current_pub = net_node.get("wireguard_public_key", "")
    current_kid = net_node.get("wireguard_key_id", "")
    if req.get("current_wireguard_public_key") != current_pub or req.get("current_wireguard_key_id") != current_kid:
        die("Request não parte da chave WireGuard atualmente autorizada.", 67)
    new_pub = req.get("new_wireguard_public_key", "")
    new_kid = req.get("new_wireguard_key_id", "")
    if not valid_wg_key(new_pub) or wg_key_id(new_pub) != new_kid or new_pub == current_pub:
        die("Nova chave WireGuard do request é inválida.", 64)
    if not openssl_verify(pub_path, canonical(req), req.get("signature", "")):
        die("Assinatura Ed25519 do nó no request de rotação não confere.", 67)
    return ctrl, net, ctrl_epoch, config_epoch, node_id, node_epoch, net_path, net_node, generation


def controller_stage(request_path, out_path):
    req = read_json(request_path)
    rotation_id = req.get("rotation_id", "")
    if not ROT_ID_RE.fullmatch(rotation_id):
        die("rotation_id WireGuard inválido.", 64)
    with lock(CTRL_LOCK):
        ensure_dir(CTRL_PENDING)
        req_store = os.path.join(CTRL_PENDING, rotation_id + ".request.json")
        auth_store = os.path.join(CTRL_PENDING, rotation_id + ".authorization.json")
        state_store = os.path.join(CTRL_PENDING, rotation_id + ".conf")
        incoming_digest = signed_digest(req)
        if os.path.isfile(auth_store):
            old_req = read_json(req_store)
            if signed_digest(old_req) != incoming_digest:
                die("rotation_id já foi usado por outro request.", 67)
            write_external_new(out_path, Path(auth_store).read_bytes())
            state = read_conf(state_store)
            print("rotation_staged=1")
            print("cached_authorization=1")
            print(f"rotation_id={rotation_id}")
            print(f"status={state.get('status','staged')}")
            return
        ctrl, net, ctrl_epoch, config_epoch, node_id, node_epoch, _, net_node, generation = validate_rotation_request(req)
        consume_nonce(CTRL_REPLAY, "request-" + node_id, req["nonce"])
        auth = {
            "contract": AUTH_CONTRACT,
            "version": VERSION,
            "rotation_id": rotation_id,
            "controller_id": ctrl.get("controller_id", ""),
            "controller_epoch": ctrl_epoch,
            "node_id": node_id,
            "node_epoch": node_epoch,
            "config_epoch_from": config_epoch,
            "config_epoch_to": config_epoch + 1,
            "network_generation_from": generation,
            "network_generation_to": generation + 1,
            "old_wireguard_key_id": req["current_wireguard_key_id"],
            "old_wireguard_public_key": req["current_wireguard_public_key"],
            "new_wireguard_key_id": req["new_wireguard_key_id"],
            "new_wireguard_public_key": req["new_wireguard_public_key"],
            "request_sha256": incoming_digest,
            "issued_at": int(time.time()),
            "nonce": base64.urlsafe_b64encode(os.urandom(24)).decode("ascii").rstrip("="),
        }
        auth["signature"] = openssl_sign(CTRL_KEY, canonical(auth))
        auth_text = json.dumps(auth, sort_keys=True, separators=(",", ":")) + "\n"
        atomic_write(req_store, json.dumps(req, sort_keys=True, separators=(",", ":")) + "\n")
        atomic_write(auth_store, auth_text)
        atomic_write(
            state_store,
            f"version=1\nrotation_id={rotation_id}\nstatus=staged\nnode_id={node_id}\nnode_epoch={node_epoch}\n"
            f"controller_epoch={ctrl_epoch}\nconfig_epoch_from={config_epoch}\nconfig_epoch_to={config_epoch+1}\n"
            f"network_generation_from={generation}\nnetwork_generation_to={generation+1}\n"
            f"old_wireguard_key_id={auth['old_wireguard_key_id']}\nnew_wireguard_key_id={auth['new_wireguard_key_id']}\n"
            f"staged_epoch={int(time.time())}\nactivated_epoch=\n",
        )
        write_external_new(out_path, auth_text)
        print("rotation_staged=1")
        print("cached_authorization=0")
        print(f"rotation_id={rotation_id}")
        print(f"node_id={node_id}")
        print(f"config_epoch_from={config_epoch}")
        print(f"config_epoch_to={config_epoch+1}")
        print(f"network_generation_from={generation}")
        print(f"network_generation_to={generation+1}")


def validate_authorization(auth, check_fresh=True):
    expected = {
        "contract", "version", "rotation_id", "controller_id", "controller_epoch", "node_id", "node_epoch",
        "config_epoch_from", "config_epoch_to", "network_generation_from", "network_generation_to",
        "old_wireguard_key_id", "old_wireguard_public_key", "new_wireguard_key_id", "new_wireguard_public_key",
        "request_sha256", "issued_at", "nonce", "signature",
    }
    if set(auth) != expected or auth.get("contract") != AUTH_CONTRACT or auth.get("version") != VERSION:
        die("Contrato de autorização de rotação WireGuard inválido.", 64)
    if not ROT_ID_RE.fullmatch(auth.get("rotation_id", "")):
        die("rotation_id WireGuard inválido.", 64)
    if check_fresh:
        fresh(auth)
    if auth.get("config_epoch_to") != auth.get("config_epoch_from", 0) + 1:
        die("Transição config_epoch inválida.", 64)
    if auth.get("network_generation_to") != auth.get("network_generation_from", 0) + 1:
        die("Transição network_generation inválida.", 64)
    for prefix in ("old", "new"):
        pub = auth.get(prefix + "_wireguard_public_key", "")
        kid = auth.get(prefix + "_wireguard_key_id", "")
        if not valid_wg_key(pub) or wg_key_id(pub) != kid:
            die("Chave WireGuard da autorização é inválida.", 64)
    if auth["old_wireguard_public_key"] == auth["new_wireguard_public_key"]:
        die("Autorização não troca a chave WireGuard.", 64)
    return auth


def active_records_with_replacement(node_id, auth):
    records = []
    if not os.path.isdir(CTRL_NET_NODES):
        die("Nenhum nó de rede registrado.", 67)
    for path in sorted(Path(CTRL_NET_NODES).glob("*.conf")):
        n = read_conf(str(path))
        nid = n.get("node_id", "")
        if not NODE_ID_RE.fullmatch(nid) or n.get("enabled") != "1":
            continue
        try:
            ident, _, ident_epoch = controller_node_identity(nid)
        except SystemExit:
            continue
        if n.get("node_epoch") != str(ident_epoch):
            continue
        if not valid_wg_key(n.get("wireguard_public_key", "")):
            continue
        current = dict(n)
        if nid == node_id:
            current["wireguard_public_key"] = auth["new_wireguard_public_key"]
            current["wireguard_key_id"] = auth["new_wireguard_key_id"]
            current["network_generation"] = str(auth["network_generation_to"])
        records.append(current)
    if not any(x.get("node_id") == node_id for x in records):
        die("Nó alvo deixou de estar ativo na topologia.", 67)
    return records


def bundle_for(target, records, net, ctrl, config_epoch):
    peers = []
    for n in records:
        if n["node_id"] == target["node_id"]:
            continue
        peers.append({
            "node_id": n["node_id"],
            "node_epoch": int(n["node_epoch"]),
            "wireguard_public_key": n["wireguard_public_key"],
            "endpoint": n["endpoint"],
            "listen_port": int(n["listen_port"]),
            "ipv4": n["ipv4"],
            "ipv6": n["ipv6"],
        })
    bundle = {
        "contract": BUNDLE_CONTRACT,
        "version": 1,
        "network_id": net["network_id"],
        "topology": "mesh",
        "config_epoch": config_epoch,
        "controller_id": ctrl["controller_id"],
        "target": {
            "node_id": target["node_id"],
            "node_epoch": int(target["node_epoch"]),
            "network_generation": int(target["network_generation"]),
            "wireguard_key_id": target["wireguard_key_id"],
            "wireguard_public_key": target["wireguard_public_key"],
            "ipv4": target["ipv4"],
            "ipv6": target["ipv6"],
            "listen_port": int(target["listen_port"]),
        },
        "peers": peers,
        "issued_at": int(time.time()),
    }
    bundle["signature"] = openssl_sign(CTRL_KEY, canonical(bundle))
    return bundle


def write_ctrl_net_conf(net, epoch):
    now = int(time.time())
    atomic_write(
        CTRL_NET_CONF,
        f"version=1\nnetwork_id={net['network_id']}\ntopology=mesh\nipv4_cidr={net['ipv4_cidr']}\n"
        f"ipv6_cidr={net['ipv6_cidr']}\nconfig_epoch={epoch}\n"
        f"created_epoch={net.get('created_epoch', str(now))}\nupdated_epoch={now}\n",
    )


def net_node_text(n):
    now = int(time.time())
    keys = (
        "version", "node_id", "node_epoch", "network_generation", "enabled", "slot", "ipv4", "ipv6",
        "wireguard_key_id", "wireguard_public_key", "endpoint", "listen_port",
    )
    return "".join(f"{k}={n.get(k,'')}\n" for k in keys) + f"updated_epoch={now}\n"


def ensure_bundle_targets(out_dir, records):
    if not os.path.isabs(out_dir) or not os.path.isdir(out_dir):
        die("activate exige diretório absoluto já existente para os bundles.", 64)
    finals = [os.path.join(out_dir, n["node_id"] + ".network.json") for n in records]
    for path in finals:
        if os.path.lexists(path):
            die(f"Bundle de saída já existe: {path}", 65)
    return finals


def controller_activate(rotation_id, out_dir):
    if not ROT_ID_RE.fullmatch(rotation_id):
        die("rotation_id WireGuard inválido.", 64)
    with lock(CTRL_LOCK):
        req_path = os.path.join(CTRL_PENDING, rotation_id + ".request.json")
        auth_path = os.path.join(CTRL_PENDING, rotation_id + ".authorization.json")
        state_path = os.path.join(CTRL_PENDING, rotation_id + ".conf")
        if not all(os.path.isfile(p) for p in (req_path, auth_path, state_path)):
            die("Rotação WireGuard não foi staged no controlador.", 66)
        req = read_json(req_path)
        auth = validate_authorization(read_json(auth_path), check_fresh=False)
        state = read_conf(state_path)
        if signed_digest(req) != auth["request_sha256"]:
            die("Autorização não corresponde ao request staged.", 67)
        ctrl, net, ctrl_epoch, config_epoch = controller_context()
        if auth["controller_id"] != ctrl.get("controller_id") or auth["controller_epoch"] != ctrl_epoch:
            die("Rotação cercada por controller_epoch diferente do atual.", 67)
        node_id = auth["node_id"]
        _, _, identity_epoch = controller_node_identity(node_id)
        net_path, net_node, generation = controller_network_node(node_id)

        already = (
            state.get("status") == "activated"
            and config_epoch == auth["config_epoch_to"]
            and generation == auth["network_generation_to"]
            and net_node.get("wireguard_public_key") == auth["new_wireguard_public_key"]
        )
        if already:
            records = active_records_with_replacement(node_id, auth)
            finals = ensure_bundle_targets(out_dir, records)
            bundles = [bundle_for(n, records, net, ctrl, auth["config_epoch_to"]) for n in records]
            for path, bundle in zip(finals, bundles):
                write_external_new(path, json.dumps(bundle, sort_keys=True, separators=(",", ":")) + "\n")
            print("rotation_activated=1")
            print("cached_activation=1")
            print(f"rotation_id={rotation_id}")
            print(f"config_epoch={auth['config_epoch_to']}")
            print(f"bundle_count={len(finals)}")
            return

        if state.get("status") != "staged":
            die("Estado de rotação WireGuard inválido para ativação.", 67)
        if identity_epoch != auth["node_epoch"]:
            die("node_epoch mudou depois do stage; rotação cercada.", 67)
        if config_epoch != auth["config_epoch_from"] or generation != auth["network_generation_from"]:
            die("Topologia mudou depois do stage; gere uma nova rotação.", 67)
        if net_node.get("wireguard_public_key") != auth["old_wireguard_public_key"]:
            die("Chave WireGuard ativa mudou depois do stage.", 67)

        records = active_records_with_replacement(node_id, auth)
        finals = ensure_bundle_targets(out_dir, records)
        bundles = [bundle_for(n, records, net, ctrl, auth["config_epoch_to"]) for n in records]

        old_node = Path(net_path).read_bytes()
        old_net = Path(CTRL_NET_CONF).read_bytes()
        tmp_paths = []
        try:
            for final, bundle in zip(finals, bundles):
                fd, tmp = tempfile.mkstemp(prefix=".wgrot-", dir=out_dir)
                os.fchmod(fd, 0o600)
                with os.fdopen(fd, "w", encoding="utf-8") as fh:
                    fh.write(json.dumps(bundle, sort_keys=True, separators=(",", ":")) + "\n")
                    fh.flush()
                    os.fsync(fh.fileno())
                tmp_paths.append((tmp, final))

            updated = dict(net_node)
            updated["wireguard_public_key"] = auth["new_wireguard_public_key"]
            updated["wireguard_key_id"] = auth["new_wireguard_key_id"]
            updated["network_generation"] = str(auth["network_generation_to"])
            atomic_write(net_path, net_node_text(updated))
            write_ctrl_net_conf(net, auth["config_epoch_to"])
            now = int(time.time())
            atomic_write(
                state_path,
                f"version=1\nrotation_id={rotation_id}\nstatus=activated\nnode_id={node_id}\nnode_epoch={auth['node_epoch']}\n"
                f"controller_epoch={auth['controller_epoch']}\nconfig_epoch_from={auth['config_epoch_from']}\n"
                f"config_epoch_to={auth['config_epoch_to']}\nnetwork_generation_from={auth['network_generation_from']}\n"
                f"network_generation_to={auth['network_generation_to']}\nold_wireguard_key_id={auth['old_wireguard_key_id']}\n"
                f"new_wireguard_key_id={auth['new_wireguard_key_id']}\nstaged_epoch={state.get('staged_epoch','')}\n"
                f"activated_epoch={now}\n",
            )
            ensure_dir(CTRL_HISTORY)
            atomic_write(os.path.join(CTRL_HISTORY, rotation_id + ".request.json"), json.dumps(req, sort_keys=True, separators=(",", ":")) + "\n")
            atomic_write(os.path.join(CTRL_HISTORY, rotation_id + ".authorization.json"), json.dumps(auth, sort_keys=True, separators=(",", ":")) + "\n")
            atomic_write(os.path.join(CTRL_HISTORY, rotation_id + ".old.pub"), auth["old_wireguard_public_key"] + "\n")
            for tmp, final in tmp_paths:
                os.replace(tmp, final)
                os.chmod(final, 0o600)
            tmp_paths = []
        except Exception:
            atomic_write(net_path, old_node)
            atomic_write(CTRL_NET_CONF, old_net)
            for tmp, final in tmp_paths:
                try:
                    os.unlink(tmp)
                except FileNotFoundError:
                    pass
                try:
                    os.unlink(final)
                except FileNotFoundError:
                    pass
            raise

        print("rotation_activated=1")
        print("cached_activation=0")
        print(f"rotation_id={rotation_id}")
        print(f"node_id={node_id}")
        print(f"config_epoch={auth['config_epoch_to']}")
        print(f"network_generation={auth['network_generation_to']}")
        print(f"bundle_count={len(finals)}")
        print(f"bundle_dir={out_dir}")


def validate_node_auth(auth, allow_stale=False, strict_topology=False):
    validate_authorization(auth, check_fresh=not allow_stale)
    enroll, ctrl, net, node_id, node_epoch, config_epoch, generation, _, current_pub, current_kid = node_context(strict_topology=strict_topology)
    if auth["controller_id"] != ctrl.get("controller_id") or auth["controller_epoch"] != node_controller_epoch():
        die("Autorização pertence a outra geração do controlador.", 67)
    if auth["node_id"] != node_id or auth["node_epoch"] != node_epoch:
        die("Autorização pertence a outro nó/node_epoch.", 67)
    if not openssl_verify(NODE_CONTROLLER_PUB, canonical(auth), auth.get("signature", "")):
        die("Assinatura do controlador na autorização WireGuard não confere.", 67)
    return enroll, ctrl, net, node_id, node_epoch, config_epoch, generation, current_pub, current_kid


def validate_target_bundle(bundle, auth):
    expected = {"contract", "version", "network_id", "topology", "config_epoch", "controller_id", "target", "peers", "issued_at", "signature"}
    if set(bundle) != expected or bundle.get("contract") != BUNDLE_CONTRACT or bundle.get("version") != 1 or bundle.get("topology") != "mesh":
        die("Bundle de topologia da rotação é inválido.", 64)
    if bundle.get("controller_id") != auth["controller_id"] or bundle.get("config_epoch") != auth["config_epoch_to"]:
        die("Bundle não corresponde à autorização de rotação.", 67)
    issued = bundle.get("issued_at")
    if isinstance(issued, bool) or not isinstance(issued, int) or abs(int(time.time()) - issued) > MAX_AGE:
        die("Bundle da rotação expirado.", 67)
    if not openssl_verify(NODE_CONTROLLER_PUB, canonical(bundle), bundle.get("signature", "")):
        die("Assinatura do bundle de rotação não confere.", 67)
    target = bundle.get("target")
    if not isinstance(target, dict):
        die("Target do bundle é inválido.", 64)
    if (
        target.get("node_id") != auth["node_id"]
        or target.get("node_epoch") != auth["node_epoch"]
        or target.get("network_generation") != auth["network_generation_to"]
        or target.get("wireguard_key_id") != auth["new_wireguard_key_id"]
        or target.get("wireguard_public_key") != auth["new_wireguard_public_key"]
    ):
        die("Target do bundle não corresponde à nova chave autorizada.", 67)


def run_network_accept(bundle_path):
    if not os.path.isfile(NETWORK_MODULE):
        die("Módulo hive_network.sh não encontrado.", 69)
    proc = subprocess.run([NETWORK_MODULE, "--accept", bundle_path], env=os.environ.copy(), timeout=60, check=False)
    return proc.returncode


def run_network_reconcile():
    if not os.path.isfile(NETWORK_MODULE) or not os.path.isfile(NODE_TOPOLOGY):
        return
    subprocess.run([NETWORK_MODULE, "--reconcile"], env=os.environ.copy(), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=60, check=False)


def node_commit(auth_path, bundle_path):
    auth = read_json(auth_path)
    rotation_id = auth.get("rotation_id", "")
    if not ROT_ID_RE.fullmatch(rotation_id):
        die("rotation_id WireGuard inválido.", 64)
    with lock(NODE_LOCK):
        history_dir = os.path.join(NODE_HISTORY, rotation_id)
        state = read_conf(NODE_ROT_STATE)
        # Completed retry remains idempotent even after freshness window.
        if os.path.isfile(os.path.join(history_dir, "authorization.json")):
            old_auth = read_json(os.path.join(history_dir, "authorization.json"))
            if signed_digest(old_auth) != signed_digest(auth):
                die("rotation_id local já foi concluído com outra autorização.", 67)
            _, _, net, node_id, _, config_epoch, generation, current_pub, current_kid = validate_node_auth(auth, allow_stale=True)
            if (
                current_pub == auth["new_wireguard_public_key"]
                and current_kid == auth["new_wireguard_key_id"]
                and config_epoch == auth["config_epoch_to"]
                and generation == auth["network_generation_to"]
            ):
                print("wireguard_rotated=1")
                print("cached=1")
                print(f"rotation_id={rotation_id}")
                print(f"node_id={node_id}")
                print(f"wg_key_epoch={state.get('wg_key_epoch','')}")
                return
            die("Histórico indica rotação concluída, mas o estado local diverge.", 67)

        validate_node_auth(auth)
        bundle = read_json(bundle_path)
        validate_target_bundle(bundle, auth)

        stage_key, stage_pub, req_path, pending_conf = pending_node_paths()
        if not all(os.path.isfile(p) for p in (stage_key, stage_pub, req_path, pending_conf)):
            die("Material WireGuard staged local não foi encontrado.", 66)
        req = read_json(req_path)
        pending = read_conf(pending_conf)
        if req.get("rotation_id") != rotation_id or pending.get("rotation_id") != rotation_id:
            die("Autorização não corresponde à rotação staged local.", 67)
        if signed_digest(req) != auth["request_sha256"]:
            die("Autorização não corresponde ao request staged local.", 67)

        staged_private = Path(stage_key).read_text(encoding="utf-8").strip()
        staged_public = Path(stage_pub).read_text(encoding="utf-8").strip()
        if derive_wg_public(staged_private) != staged_public:
            die("Par WireGuard staged local é inconsistente.", 67)
        if staged_public != auth["new_wireguard_public_key"] or wg_key_id(staged_public) != auth["new_wireguard_key_id"]:
            die("Chave WireGuard staged não corresponde à autorização.", 67)

        enroll, ctrl, net, node_id, node_epoch, config_epoch, generation, old_private, old_public, old_kid = node_context(strict_topology=False)
        partial_new = old_public == auth["new_wireguard_public_key"]
        if not partial_new:
            if (
                old_public != auth["old_wireguard_public_key"]
                or old_kid != auth["old_wireguard_key_id"]
                or config_epoch != auth["config_epoch_from"]
                or generation != auth["network_generation_from"]
            ):
                die("Estado WireGuard local foi alterado depois do stage.", 67)
        else:
            if config_epoch not in (auth["config_epoch_from"], auth["config_epoch_to"]):
                die("Estado parcial da rotação possui config_epoch inválido.", 67)

        backup_private = old_private
        backup_public = old_public
        normal_old = not partial_new
        try:
            if normal_old:
                atomic_write(NODE_WG_KEY, staged_private + "\n", 0o600)
                atomic_write(NODE_WG_PUB, staged_public + "\n", 0o600)
            rc = run_network_accept(bundle_path)
            if rc != 0:
                raise RuntimeError("network-accept-failed")
        except Exception:
            if normal_old:
                atomic_write(NODE_WG_KEY, backup_private + "\n", 0o600)
                atomic_write(NODE_WG_PUB, backup_public + "\n", 0o600)
                run_network_reconcile()
            die("Falha ao aplicar a topologia da nova chave; chave WireGuard anterior restaurada.", 70)

        replay_marker = nonce_path(NODE_REPLAY, "authorization", auth["nonce"])
        if os.path.exists(replay_marker):
            final_net = read_conf(NODE_NETWORK_CONF)
            final_public = Path(NODE_WG_PUB).read_text(encoding="utf-8").strip()
            if (
                final_public != auth["new_wireguard_public_key"]
                or final_net.get("config_epoch") != str(auth["config_epoch_to"])
                or final_net.get("network_generation") != str(auth["network_generation_to"])
            ):
                die("Replay de autorização WireGuard recusado.", 67)
        else:
            consume_nonce(NODE_REPLAY, "authorization", auth["nonce"])
        ensure_dir(history_dir)
        atomic_write(os.path.join(history_dir, "old.pub"), auth["old_wireguard_public_key"] + "\n")
        atomic_write(os.path.join(history_dir, "request.json"), json.dumps(req, sort_keys=True, separators=(",", ":")) + "\n")
        atomic_write(os.path.join(history_dir, "authorization.json"), json.dumps(auth, sort_keys=True, separators=(",", ":")) + "\n")
        atomic_write(os.path.join(history_dir, "bundle.sha256"), hashlib.sha256(Path(bundle_path).read_bytes()).hexdigest() + "\n")
        try:
            key_epoch = int(state.get("wg_key_epoch", "1")) + 1
        except ValueError:
            die("wg_key_epoch local inválido.", 67)
        atomic_write(
            NODE_ROT_STATE,
            f"version=1\nwg_key_epoch={key_epoch}\nlast_rotation_id={rotation_id}\n"
            f"config_epoch={auth['config_epoch_to']}\nnetwork_generation={auth['network_generation_to']}\n"
            f"rotated_epoch={int(time.time())}\n",
        )
        shutil.rmtree(NODE_PENDING, ignore_errors=True)
        print("wireguard_rotated=1")
        print("cached=0")
        print(f"rotation_id={rotation_id}")
        print(f"node_id={node_id}")
        print(f"config_epoch={auth['config_epoch_to']}")
        print(f"network_generation={auth['network_generation_to']}")
        print(f"wg_key_epoch={key_epoch}")
        print("old_private_key_retained=0")


def controller_status():
    _, net, ctrl_epoch, config_epoch = controller_context()
    pending = []
    if os.path.isdir(CTRL_PENDING):
        for path in sorted(Path(CTRL_PENDING).glob("*.conf")):
            c = read_conf(str(path))
            if c.get("rotation_id"):
                pending.append(c)
    print(f"contract={STATUS_CONTRACT}")
    print("role=controller")
    print(f"controller_epoch={ctrl_epoch}")
    print(f"config_epoch={config_epoch}")
    print(f"rotations_tracked={len(pending)}")
    print(f"rotations_staged={sum(1 for x in pending if x.get('status') == 'staged')}")
    print(f"rotations_activated={sum(1 for x in pending if x.get('status') == 'activated')}")
    print("old_private_key_retained=0")
    print("controller_in_user_vpn_path=0")


def node_status():
    state = read_conf(NODE_ROT_STATE)
    pending_req = os.path.join(NODE_PENDING, "request.json")
    print(f"contract={STATUS_CONTRACT}")
    print("role=node")
    print(f"rotation_pending={1 if os.path.isfile(pending_req) else 0}")
    print(f"wg_key_epoch={state.get('wg_key_epoch','1')}")
    try:
        _, _, _, node_id, node_epoch, config_epoch, generation, _, _, kid = node_context()
        print(f"node_id={node_id}")
        print(f"node_epoch={node_epoch}")
        print(f"controller_epoch={node_controller_epoch()}")
        print(f"config_epoch={config_epoch}")
        print(f"network_generation={generation}")
        print(f"wireguard_key_id={kid}")
    except SystemExit:
        print("node_id=")
        print("node_epoch=")
        print("controller_epoch=")
        print("config_epoch=")
        print("network_generation=")
        print("wireguard_key_id=")
    print("old_private_key_retained=0")
    print("rotation_fail_closed=1")


def usage():
    print(
        "Uso: hive_wg_rotation.sh {--status|--node-prepare OUT|--node-commit AUTH BUNDLE|"
        "--controller-status|--controller-stage REQUEST OUT|--controller-activate ROTATION_ID OUT_DIR}",
        file=sys.stderr,
    )
    raise SystemExit(64)


def main(argv):
    cmd = argv[0] if argv else "--status"
    if cmd in {"--status", "--install"}:
        node_status()
        return
    if cmd == "--node-prepare" and len(argv) == 2:
        node_prepare(argv[1])
        return
    if cmd == "--node-commit" and len(argv) == 3:
        node_commit(argv[1], argv[2])
        return
    if cmd == "--controller-status":
        controller_status()
        return
    if cmd == "--controller-stage" and len(argv) == 3:
        controller_stage(argv[1], argv[2])
        return
    if cmd == "--controller-activate" and len(argv) == 3:
        controller_activate(argv[1], argv[2])
        return
    if cmd in {"--detach", "--purge"}:
        return
    usage()


main(sys.argv[1:])
PY
