#!/usr/bin/env bash
set -Eeuo pipefail

MANAGER_HOME="${MANAGER_HOME:-/opt/manager}"
MANAGER_ETC="${MANAGER_ETC:-/etc/manager}"
# shellcheck source=/dev/null
source "$MANAGER_HOME/lib/common.sh"
require_root

command -v python3 >/dev/null 2>&1 || { err "Python 3 é necessário para a rede da Colmeia."; exit 69; }
command -v openssl >/dev/null 2>&1 || { err "OpenSSL é necessário para a rede da Colmeia."; exit 69; }
command -v wg >/dev/null 2>&1 || { err "wireguard-tools é necessário para a rede da Colmeia."; exit 69; }
command -v wg-quick >/dev/null 2>&1 || { err "wg-quick é necessário para a rede da Colmeia."; exit 69; }

python3 - "$@" <<'PY'
import base64
import hashlib
import ipaddress
import json
import os
import re
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
NODE_HIVE = os.path.join(HIVE_DIR, "node")
NODE_ID_KEY = os.path.join(NODE_HIVE, "node.key")
NODE_ENROLLMENT = os.path.join(NODE_HIVE, "enrollment.conf")
NODE_CONTROLLER_PUB = os.path.join(NODE_HIVE, "controller.pub")
NODE_CONTROLLER_CONF = os.path.join(NODE_HIVE, "controller.conf")
NETWORK_DIR = os.path.join(HIVE_DIR, "network")
NODE_WG_KEY = os.path.join(NETWORK_DIR, "node.key")
NODE_WG_PUB = os.path.join(NETWORK_DIR, "node.pub")
NODE_NETWORK_CONF = os.path.join(NETWORK_DIR, "network.conf")
NODE_TOPOLOGY = os.path.join(NETWORK_DIR, "topology.json")
WG_CONF = os.path.join(WG_DIR, "mgh0.conf")

CTRL_DIR = os.path.join(HIVE_DIR, "controller")
CTRL_KEY = os.path.join(CTRL_DIR, "controller.key")
CTRL_PUB = os.path.join(CTRL_DIR, "controller.pub")
CTRL_CONF = os.path.join(CTRL_DIR, "controller.conf")
CTRL_NODES = os.path.join(CTRL_DIR, "nodes")
CTRL_NET_DIR = os.path.join(CTRL_DIR, "network")
CTRL_NET_CONF = os.path.join(CTRL_NET_DIR, "network.conf")
CTRL_NET_NODES = os.path.join(CTRL_NET_DIR, "nodes")

REQ_CONTRACT = "manager-hive-network-request-v1"
BUNDLE_CONTRACT = "manager-hive-network-bundle-v1"
STATUS_CONTRACT = "manager-hive-network-v1"
VERSION = 1
IFACE = "mgh0"
DEFAULT_PORT = 51870
IPV4_CIDR = "10.253.0.0/16"
IPV6_CIDR = "fd42:4d47:4800::/64"
REQUEST_MAX_AGE = 86400
BUNDLE_MAX_AGE = 86400
NODE_ID_RE = re.compile(r"^node-[a-f0-9]{16}$")
WG_KEY_RE = re.compile(r"^[A-Za-z0-9+/]{43}=$")
HOST_RE = re.compile(r"^(?=.{1,253}$)(?:[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?)$")


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
        for line in fh:
            line = line.rstrip("\n")
            if "=" in line:
                k, v = line.split("=", 1)
                data[k] = v
    return data


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


def sign(private_path, payload):
    if not os.path.isfile(private_path):
        die("Chave de assinatura da Colmeia não encontrada.", 69)
    dfd, dpath = tempfile.mkstemp(prefix="hive-net-data-")
    sfd, spath = tempfile.mkstemp(prefix="hive-net-sig-")
    os.close(sfd)
    try:
        os.fchmod(dfd, 0o600)
        with os.fdopen(dfd, "wb") as fh:
            fh.write(payload)
        proc = subprocess.run(["openssl", "pkeyutl", "-sign", "-inkey", private_path, "-rawin", "-in", dpath, "-out", spath],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=20, check=False)
        if proc.returncode != 0:
            die("Falha ao assinar configuração da rede da Colmeia.")
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
        sig = base64.b64decode(signature_text.encode("ascii"), validate=True)
    except Exception:
        return False
    if len(sig) != 64:
        return False
    dfd, dpath = tempfile.mkstemp(prefix="hive-net-data-")
    sfd, spath = tempfile.mkstemp(prefix="hive-net-sig-")
    try:
        os.fchmod(dfd, 0o600); os.fchmod(sfd, 0o600)
        with os.fdopen(dfd, "wb") as fh: fh.write(payload)
        with os.fdopen(sfd, "wb") as fh: fh.write(sig)
        proc = subprocess.run(["openssl", "pkeyutl", "-verify", "-pubin", "-inkey", pub_path, "-rawin", "-in", dpath, "-sigfile", spath],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=20, check=False)
        return proc.returncode == 0
    finally:
        for p in (dpath, spath):
            try: os.unlink(p)
            except FileNotFoundError: pass


def valid_wg_key(key):
    if not isinstance(key, str) or not WG_KEY_RE.fullmatch(key):
        return False
    try:
        return len(base64.b64decode(key, validate=True)) == 32
    except Exception:
        return False


def wg_key_id(key):
    if not valid_wg_key(key):
        die("Chave pública WireGuard inválida.", 64)
    return "wg-" + hashlib.sha256(base64.b64decode(key)).hexdigest()[:16]


def generate_wg_keypair():
    ensure_dir(NETWORK_DIR)
    if os.path.exists(NODE_WG_KEY) != os.path.exists(NODE_WG_PUB):
        die("Identidade WireGuard da Colmeia está incompleta; não sobrescrevendo estado.", 65)
    if not os.path.exists(NODE_WG_KEY):
        proc = subprocess.run(["wg", "genkey"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=10, check=False)
        if proc.returncode != 0:
            die("Não foi possível gerar chave WireGuard.", 69)
        private = proc.stdout.strip()
        proc = subprocess.run(["wg", "pubkey"], input=private + "\n", stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              text=True, timeout=10, check=False)
        if proc.returncode != 0:
            die("Não foi possível derivar chave pública WireGuard.", 69)
        public = proc.stdout.strip()
        if not valid_wg_key(private) or not valid_wg_key(public):
            die("wireguard-tools retornou chave inválida.")
        atomic_write(NODE_WG_KEY, private + "\n")
        atomic_write(NODE_WG_PUB, public + "\n")
    private = Path(NODE_WG_KEY).read_text(encoding="utf-8").strip()
    public = Path(NODE_WG_PUB).read_text(encoding="utf-8").strip()
    if not valid_wg_key(private) or not valid_wg_key(public):
        die("Material WireGuard local inválido.")
    return public, wg_key_id(public)


def enrollment():
    c = read_conf(NODE_ENROLLMENT)
    if not c or not os.path.isfile(NODE_ID_KEY) or not os.path.isfile(NODE_CONTROLLER_PUB):
        die("Este nó precisa concluir o enrollment da Colmeia antes da rede privada.", 67)
    node_id = c.get("node_id", "")
    try: epoch = int(c.get("node_epoch", "0"))
    except ValueError: epoch = 0
    if not NODE_ID_RE.fullmatch(node_id) or epoch < 1:
        die("Enrollment local inválido.", 67)
    return c, node_id, epoch


def controller_identity():
    conf = read_conf(CTRL_CONF)
    if not conf or not os.path.isfile(CTRL_KEY) or not os.path.isfile(CTRL_PUB):
        die("Inicialize o controlador da Colmeia primeiro.", 67)
    return conf


def controller_node(node_id):
    if not NODE_ID_RE.fullmatch(node_id):
        die("node_id inválido.", 64)
    conf_path = os.path.join(CTRL_NODES, node_id + ".conf")
    pub_path = os.path.join(CTRL_NODES, node_id + ".pub")
    conf = read_conf(conf_path)
    if not conf or not os.path.isfile(pub_path):
        die("Nó não está enrolled neste controlador.", 67)
    try: epoch = int(conf.get("node_epoch", "0"))
    except ValueError: epoch = 0
    if conf.get("enabled") != "1" or conf.get("revoked_epoch", "0") != "0" or epoch < 1:
        die("Nó está revogado/desabilitado no controlador.", 67)
    return conf, pub_path, epoch


def validate_endpoint(host):
    if not isinstance(host, str) or not host or len(host) > 253 or any(c.isspace() for c in host) or "/" in host:
        die("Endpoint da Colmeia inválido.", 64)
    try:
        ipaddress.ip_address(host)
        return host
    except ValueError:
        if not HOST_RE.fullmatch(host) or ".." in host:
            die("Endpoint da Colmeia deve ser IP ou hostname válido.", 64)
    return host.lower()


def validate_port(value):
    try: port = int(value)
    except (TypeError, ValueError): die("Porta WireGuard inválida.", 64)
    if port < 1 or port > 65535:
        die("Porta WireGuard inválida.", 64)
    return port


def format_endpoint(host, port):
    try:
        ip = ipaddress.ip_address(host)
        if ip.version == 6:
            return f"[{host}]:{port}"
    except ValueError:
        pass
    return f"{host}:{port}"


def init_node_network():
    public, kid = generate_wg_keypair()
    print(f"contract={STATUS_CONTRACT}")
    print(f"interface={IFACE}")
    print("topology=mesh")
    print("wireguard_private_key_local=1")
    print("wireguard_private_key_exported=0")
    print(f"wireguard_key_id={kid}")
    print(f"wireguard_public_key={public}")


def make_request(endpoint, out_path, port_value):
    c, node_id, epoch = enrollment()
    public, kid = generate_wg_keypair()
    endpoint = validate_endpoint(endpoint)
    port = validate_port(port_value)
    req = {
        "contract": REQ_CONTRACT, "version": VERSION, "node_id": node_id, "node_epoch": epoch,
        "controller_id": c.get("controller_id", ""), "wireguard_key_id": kid,
        "wireguard_public_key": public, "endpoint": endpoint, "listen_port": port,
        "issued_at": int(time.time()), "nonce": base64.urlsafe_b64encode(os.urandom(24)).decode("ascii").rstrip("="),
    }
    req["signature"] = sign(NODE_ID_KEY, canonical(req))
    write_external_new(out_path, json.dumps(req, sort_keys=True, separators=(",", ":")) + "\n")
    print(f"request_file={out_path}")
    print(f"node_id={node_id}")
    print(f"node_epoch={epoch}")
    print(f"wireguard_key_id={kid}")
    print(f"endpoint={endpoint}")
    print(f"listen_port={port}")


def controller_network_init():
    ctrl = controller_identity()
    ensure_dir(CTRL_NET_DIR); ensure_dir(CTRL_NET_NODES)
    current = read_conf(CTRL_NET_CONF)
    if current:
        return current
    controller_id = ctrl.get("controller_id", "")
    network_id = "hive-net-" + hashlib.sha256(controller_id.encode()).hexdigest()[:16]
    now = int(time.time())
    text = (f"version=1\nnetwork_id={network_id}\ntopology=mesh\nipv4_cidr={IPV4_CIDR}\n"
            f"ipv6_cidr={IPV6_CIDR}\nconfig_epoch=1\ncreated_epoch={now}\nupdated_epoch={now}\n")
    atomic_write(CTRL_NET_CONF, text)
    return read_conf(CTRL_NET_CONF)


def write_ctrl_net_conf(conf, epoch):
    now = int(time.time())
    atomic_write(CTRL_NET_CONF,
                 f"version=1\nnetwork_id={conf['network_id']}\ntopology=mesh\nipv4_cidr={conf['ipv4_cidr']}\n"
                 f"ipv6_cidr={conf['ipv6_cidr']}\nconfig_epoch={epoch}\ncreated_epoch={conf.get('created_epoch', str(now))}\nupdated_epoch={now}\n")


def ctrl_net_node_path(node_id):
    return os.path.join(CTRL_NET_NODES, node_id + ".conf")


def validate_network_request(req):
    expected = {"contract", "version", "node_id", "node_epoch", "controller_id", "wireguard_key_id",
                "wireguard_public_key", "endpoint", "listen_port", "issued_at", "nonce", "signature"}
    if set(req) != expected or req.get("contract") != REQ_CONTRACT or req.get("version") != VERSION:
        die("Contrato de network request inválido.", 64)
    node_id = req.get("node_id", "")
    conf, pub_path, current_epoch = controller_node(node_id)
    if req.get("controller_id") != controller_identity().get("controller_id"):
        die("Network request pertence a outro controlador.", 67)
    epoch = req.get("node_epoch")
    if isinstance(epoch, bool) or not isinstance(epoch, int) or epoch != current_epoch:
        die("node_epoch do network request está obsoleto.", 67)
    issued = req.get("issued_at")
    if isinstance(issued, bool) or not isinstance(issued, int) or abs(int(time.time()) - issued) > REQUEST_MAX_AGE:
        die("Network request expirado ou com timestamp inválido.", 67)
    nonce = req.get("nonce")
    if not isinstance(nonce, str) or len(nonce) < 32 or len(nonce) > 96:
        die("Nonce do network request inválido.", 64)
    key = req.get("wireguard_public_key", "")
    if not valid_wg_key(key) or wg_key_id(key) != req.get("wireguard_key_id"):
        die("Identidade WireGuard do request inválida.", 67)
    endpoint = validate_endpoint(req.get("endpoint"))
    port = validate_port(req.get("listen_port"))
    if not verify(pub_path, canonical(req), req.get("signature", "")):
        die("Assinatura do network request não confere.", 67)
    return conf, node_id, current_epoch, key, endpoint, port


def used_slots():
    slots = set()
    if os.path.isdir(CTRL_NET_NODES):
        for path in Path(CTRL_NET_NODES).glob("*.conf"):
            c = read_conf(str(path))
            try: slots.add(int(c.get("slot", "0")))
            except ValueError: pass
    return {x for x in slots if x > 0}


def allocate_slot():
    used = used_slots()
    for slot in range(1, 65534):
        if slot not in used:
            return slot
    die("Faixa interna da Colmeia esgotada.", 73)


def addresses_for_slot(slot, net_conf):
    v4 = ipaddress.ip_network(net_conf["ipv4_cidr"])
    v6 = ipaddress.ip_network(net_conf["ipv6_cidr"])
    ip4 = str(v4.network_address + slot)
    ip6 = str(v6.network_address + slot)
    if ipaddress.ip_address(ip4) == v4.broadcast_address:
        die("Slot interno inválido.")
    return ip4, ip6


def controller_approve(request_path):
    net = controller_network_init()
    req = read_json(request_path)
    _, node_id, node_epoch, key, endpoint, port = validate_network_request(req)
    path = ctrl_net_node_path(node_id)
    existing = read_conf(path)
    slot = int(existing.get("slot", "0")) if existing else allocate_slot()
    if slot < 1: slot = allocate_slot()
    ip4, ip6 = addresses_for_slot(slot, net)
    kid = wg_key_id(key)
    changed = (not existing or existing.get("wireguard_public_key") != key or existing.get("endpoint") != endpoint or
               existing.get("listen_port") != str(port) or existing.get("node_epoch") != str(node_epoch) or existing.get("enabled") != "1")
    now = int(time.time())
    generation = int(existing.get("network_generation", "0")) + (1 if changed else 0)
    if generation < 1: generation = 1
    atomic_write(path,
                 f"version=1\nnode_id={node_id}\nnode_epoch={node_epoch}\nnetwork_generation={generation}\n"
                 f"enabled=1\nslot={slot}\nipv4={ip4}\nipv6={ip6}\nwireguard_key_id={kid}\n"
                 f"wireguard_public_key={key}\nendpoint={endpoint}\nlisten_port={port}\nupdated_epoch={now}\n")
    config_epoch = int(net.get("config_epoch", "1"))
    if changed:
        config_epoch += 1
        write_ctrl_net_conf(net, config_epoch)
    print("approved=1")
    print(f"node_id={node_id}")
    print(f"node_epoch={node_epoch}")
    print(f"network_generation={generation}")
    print(f"ipv4={ip4}")
    print(f"ipv6={ip6}")
    print(f"config_epoch={config_epoch}")


def active_network_records():
    net = controller_network_init()
    out = []
    for path in sorted(Path(CTRL_NET_NODES).glob("*.conf")):
        n = read_conf(str(path))
        node_id = n.get("node_id", "")
        if not NODE_ID_RE.fullmatch(node_id) or n.get("enabled") != "1":
            continue
        try:
            identity, _, epoch = controller_node(node_id)
        except SystemExit:
            continue
        if n.get("node_epoch") != str(epoch):
            continue
        if not valid_wg_key(n.get("wireguard_public_key", "")):
            continue
        out.append(n)
    return net, out


def controller_bundle(node_id, out_path):
    ctrl = controller_identity()
    net, records = active_network_records()
    target = next((x for x in records if x.get("node_id") == node_id), None)
    if target is None:
        die("Nó não está ativo na topologia privada da Colmeia.", 67)
    peers = []
    for n in records:
        if n["node_id"] == node_id:
            continue
        peers.append({
            "node_id": n["node_id"], "node_epoch": int(n["node_epoch"]),
            "wireguard_public_key": n["wireguard_public_key"], "endpoint": n["endpoint"],
            "listen_port": int(n["listen_port"]), "ipv4": n["ipv4"], "ipv6": n["ipv6"],
        })
    bundle = {
        "contract": BUNDLE_CONTRACT, "version": VERSION, "network_id": net["network_id"], "topology": "mesh",
        "config_epoch": int(net["config_epoch"]), "controller_id": ctrl["controller_id"],
        "target": {"node_id": target["node_id"], "node_epoch": int(target["node_epoch"]),
                   "network_generation": int(target["network_generation"]),
                   "wireguard_key_id": target["wireguard_key_id"], "wireguard_public_key": target["wireguard_public_key"],
                   "ipv4": target["ipv4"], "ipv6": target["ipv6"], "listen_port": int(target["listen_port"])},
        "peers": peers, "issued_at": int(time.time())
    }
    bundle["signature"] = sign(CTRL_KEY, canonical(bundle))
    write_external_new(out_path, json.dumps(bundle, sort_keys=True, separators=(",", ":")) + "\n")
    print(f"bundle_file={out_path}")
    print(f"node_id={node_id}")
    print(f"config_epoch={net['config_epoch']}")
    print(f"peer_count={len(peers)}")


def controller_bundle_all(out_dir):
    if not os.path.isabs(out_dir) or not os.path.isdir(out_dir):
        die("bundle-all exige diretório absoluto já existente.", 64)
    _, records = active_network_records()
    for n in records:
        out = os.path.join(out_dir, n["node_id"] + ".network.json")
        controller_bundle(n["node_id"], out)


def controller_set_enabled(node_id, enabled):
    net = controller_network_init()
    controller_node(node_id)
    path = ctrl_net_node_path(node_id)
    n = read_conf(path)
    if not n:
        die("Nó ainda não possui network request aprovado.", 66)
    desired = "1" if enabled else "0"
    if n.get("enabled") == desired:
        print(f"network_enabled={desired}")
        print(f"node_id={node_id}")
        print(f"config_epoch={net['config_epoch']}")
        return
    n["enabled"] = desired
    now = int(time.time())
    text = "".join(f"{key}={n.get(key,'')}\n" for key in
                   ("version","node_id","node_epoch","network_generation","enabled","slot","ipv4","ipv6",
                    "wireguard_key_id","wireguard_public_key","endpoint","listen_port")) + f"updated_epoch={now}\n"
    atomic_write(path, text)
    epoch = int(net["config_epoch"]) + 1
    write_ctrl_net_conf(net, epoch)
    print(f"network_enabled={desired}")
    print(f"node_id={node_id}")
    print(f"config_epoch={epoch}")


def controller_list():
    controller_network_init()
    print("node_id|enabled|node_epoch|ipv4|ipv6|endpoint|listen_port|network_generation")
    for path in sorted(Path(CTRL_NET_NODES).glob("*.conf")):
        n = read_conf(str(path))
        print("|".join(n.get(k, "") for k in ("node_id","enabled","node_epoch","ipv4","ipv6","endpoint","listen_port","network_generation")))


def controller_show(node_id):
    if not NODE_ID_RE.fullmatch(node_id): die("node_id inválido.", 64)
    path = ctrl_net_node_path(node_id)
    if not os.path.isfile(path): die("Nó sem estado de rede no controlador.", 66)
    sys.stdout.write(Path(path).read_text(encoding="utf-8"))


def validate_bundle(bundle):
    expected = {"contract","version","network_id","topology","config_epoch","controller_id","target","peers","issued_at","signature"}
    if set(bundle) != expected or bundle.get("contract") != BUNDLE_CONTRACT or bundle.get("version") != VERSION or bundle.get("topology") != "mesh":
        die("Bundle de topologia inválido.", 64)
    enrolled, node_id, node_epoch = enrollment()
    controller_conf = read_conf(NODE_CONTROLLER_CONF)
    if bundle.get("controller_id") != controller_conf.get("controller_id") or bundle.get("controller_id") != enrolled.get("controller_id"):
        die("Bundle pertence a outro controlador.", 67)
    issued = bundle.get("issued_at")
    if isinstance(issued, bool) or not isinstance(issued, int) or abs(int(time.time()) - issued) > BUNDLE_MAX_AGE:
        die("Bundle de topologia expirado ou com timestamp inválido.", 67)
    epoch = bundle.get("config_epoch")
    if isinstance(epoch, bool) or not isinstance(epoch, int) or epoch < 1:
        die("config_epoch inválido.", 64)
    target = bundle.get("target")
    if not isinstance(target, dict) or target.get("node_id") != node_id or target.get("node_epoch") != node_epoch:
        die("Bundle foi emitido para outro nó/epoch.", 67)
    local_public, local_kid = generate_wg_keypair()
    if target.get("wireguard_public_key") != local_public or target.get("wireguard_key_id") != local_kid:
        die("Bundle não corresponde à chave WireGuard local.", 67)
    for field in ("ipv4","ipv6"):
        try: ipaddress.ip_address(target.get(field, ""))
        except ValueError: die("Endereço interno do target inválido.", 64)
    validate_port(target.get("listen_port"))
    peers = bundle.get("peers")
    if not isinstance(peers, list) or len(peers) > 4096:
        die("Lista de peers inválida.", 64)
    seen_nodes, seen_ips = set(), set()
    for p in peers:
        if not isinstance(p, dict) or set(p) != {"node_id","node_epoch","wireguard_public_key","endpoint","listen_port","ipv4","ipv6"}:
            die("Peer inválido no bundle.", 64)
        if not NODE_ID_RE.fullmatch(p.get("node_id", "")) or p["node_id"] == node_id or p["node_id"] in seen_nodes:
            die("node_id de peer inválido/duplicado.", 64)
        if not isinstance(p.get("node_epoch"), int) or p["node_epoch"] < 1 or not valid_wg_key(p.get("wireguard_public_key", "")):
            die("Identidade de peer inválida.", 64)
        validate_endpoint(p.get("endpoint")); validate_port(p.get("listen_port"))
        try:
            ip4 = str(ipaddress.ip_address(p.get("ipv4", ""))); ip6 = str(ipaddress.ip_address(p.get("ipv6", "")))
        except ValueError:
            die("Endereço interno de peer inválido.", 64)
        if ip4 in seen_ips or ip6 in seen_ips or ip4 == target["ipv4"] or ip6 == target["ipv6"]:
            die("Endereço interno duplicado no bundle.", 64)
        seen_nodes.add(p["node_id"]); seen_ips.update((ip4, ip6))
    if not verify(NODE_CONTROLLER_PUB, canonical(bundle), bundle.get("signature", "")):
        die("Assinatura do bundle de topologia não confere.", 67)
    current = read_conf(NODE_NETWORK_CONF)
    current_epoch = int(current.get("config_epoch", "0")) if current else 0
    digest = hashlib.sha256(canonical(bundle)).hexdigest()
    if epoch < current_epoch:
        die("Bundle antigo recusado por fencing de config_epoch.", 67)
    if epoch == current_epoch and current and current.get("bundle_sha256") not in ("", digest):
        die("Bundle divergente reutilizou config_epoch existente.", 67)
    return node_id, node_epoch, epoch, target, peers, digest


def render_config(target, peers):
    private = Path(NODE_WG_KEY).read_text(encoding="utf-8").strip()
    lines = ["# MANAGER-HIVE-NETWORK v1", "[Interface]", f"PrivateKey = {private}",
             f"Address = {target['ipv4']}/32, {target['ipv6']}/128", f"ListenPort = {target['listen_port']}", "SaveConfig = false"]
    for p in sorted(peers, key=lambda x: x["node_id"]):
        lines.extend(["", f"# HIVE-PEER {p['node_id']} epoch={p['node_epoch']}", "[Peer]",
                      f"PublicKey = {p['wireguard_public_key']}",
                      f"Endpoint = {format_endpoint(p['endpoint'], p['listen_port'])}",
                      f"AllowedIPs = {p['ipv4']}/32, {p['ipv6']}/128", "PersistentKeepalive = 25"])
    return "\n".join(lines) + "\n"


def validate_wg_config(text):
    ensure_dir(WG_DIR)
    fd, path = tempfile.mkstemp(prefix="mgh0-", suffix=".conf", dir=WG_DIR)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as fh: fh.write(text)
        proc = subprocess.run(["wg-quick", "strip", path], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=20, check=False)
        if proc.returncode != 0:
            die("Configuração WireGuard da Colmeia não passou em wg-quick strip.")
    finally:
        try: os.unlink(path)
        except FileNotFoundError: pass


def test_skip_apply():
    skip = os.environ.get("MANAGER_HIVE_NETWORK_SKIP_APPLY", "0") == "1"
    if skip and os.environ.get("GITHUB_ACTIONS", "false") != "true" and os.environ.get("MANAGER_HIVE_NETWORK_TEST_MODE", "0") != "1":
        die("SKIP_APPLY é reservado para CI/testes explícitos.", 64)
    return skip


def apply_service():
    if test_skip_apply():
        return
    proc = subprocess.run(["systemctl", "enable", "--now", f"wg-quick@{IFACE}.service"], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=30, check=False)
    if proc.returncode != 0:
        proc = subprocess.run(["systemctl", "restart", f"wg-quick@{IFACE}.service"], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=30, check=False)
    if proc.returncode != 0:
        die("A topologia foi validada, mas a interface mgh0 não pôde ser ativada; verifique kernel/firewall/endpoint.", 70)


def accept_bundle(path):
    bundle = read_json(path)
    node_id, node_epoch, epoch, target, peers, digest = validate_bundle(bundle)
    config = render_config(target, peers)
    validate_wg_config(config)
    old_wg = Path(WG_CONF).read_bytes() if os.path.isfile(WG_CONF) else None
    old_state = Path(NODE_NETWORK_CONF).read_bytes() if os.path.isfile(NODE_NETWORK_CONF) else None
    old_topology = Path(NODE_TOPOLOGY).read_bytes() if os.path.isfile(NODE_TOPOLOGY) else None
    ensure_dir(WG_DIR); ensure_dir(NETWORK_DIR)
    atomic_write(WG_CONF, config)
    atomic_write(NODE_TOPOLOGY, json.dumps(bundle, sort_keys=True, separators=(",", ":")) + "\n")
    now = int(time.time())
    state = (f"version=1\nnetwork_id={bundle['network_id']}\ntopology=mesh\nnode_id={node_id}\nnode_epoch={node_epoch}\n"
             f"config_epoch={epoch}\nnetwork_generation={target['network_generation']}\nipv4={target['ipv4']}\nipv6={target['ipv6']}\n"
             f"listen_port={target['listen_port']}\npeer_count={len(peers)}\nbundle_sha256={digest}\naccepted_epoch={now}\n")
    atomic_write(NODE_NETWORK_CONF, state)
    try:
        apply_service()
    except SystemExit:
        if old_wg is None:
            try: os.unlink(WG_CONF)
            except FileNotFoundError: pass
        else: atomic_write(WG_CONF, old_wg)
        if old_state is None:
            try: os.unlink(NODE_NETWORK_CONF)
            except FileNotFoundError: pass
        else: atomic_write(NODE_NETWORK_CONF, old_state)
        if old_topology is None:
            try: os.unlink(NODE_TOPOLOGY)
            except FileNotFoundError: pass
        else: atomic_write(NODE_TOPOLOGY, old_topology)
        raise
    print("network_configured=1")
    print(f"interface={IFACE}")
    print(f"node_id={node_id}")
    print(f"config_epoch={epoch}")
    print(f"ipv4={target['ipv4']}")
    print(f"ipv6={target['ipv6']}")
    print(f"listen_port={target['listen_port']}")
    print(f"peer_count={len(peers)}")


def reconcile():
    if not os.path.isfile(NODE_TOPOLOGY):
        die("Nenhuma topologia assinada foi aceita neste nó.", 66)
    bundle = read_json(NODE_TOPOLOGY)
    _, _, _, target, peers, _ = validate_bundle(bundle)
    config = render_config(target, peers)
    validate_wg_config(config)
    atomic_write(WG_CONF, config)
    apply_service()
    print("reconciled=1")
    print(f"interface={IFACE}")


def stop_service(remove_conf=False):
    if os.environ.get("GITHUB_ACTIONS", "false") != "true" or os.environ.get("MANAGER_HIVE_NETWORK_SKIP_APPLY", "0") != "1":
        subprocess.run(["systemctl", "disable", "--now", f"wg-quick@{IFACE}.service"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30, check=False)
    if remove_conf:
        try: os.unlink(WG_CONF)
        except FileNotFoundError: pass


def status():
    public, kid = generate_wg_keypair()
    enrolled = bool(read_conf(NODE_ENROLLMENT))
    state = read_conf(NODE_NETWORK_CONF)
    service = "inactive"
    if not test_skip_apply():
        proc = subprocess.run(["systemctl", "is-active", f"wg-quick@{IFACE}.service"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, timeout=10, check=False)
        service = proc.stdout.strip() or "inactive"
    print(f"contract={STATUS_CONTRACT}")
    print(f"interface={IFACE}")
    print("topology=mesh")
    print("wireguard_private_key_local=1")
    print("wireguard_private_key_exported=0")
    print(f"wireguard_key_id={kid}")
    print(f"wireguard_public_key={public}")
    print(f"identity_enrolled={1 if enrolled else 0}")
    print(f"network_configured={1 if state else 0}")
    print(f"service={service}")
    print("default_route_exported=0")
    print("user_vpn_traffic_transit=0")
    print("firewall_auto_open=0")
    for k in ("network_id","node_id","node_epoch","config_epoch","network_generation","ipv4","ipv6","listen_port","peer_count"):
        print(f"{k}={state.get(k,'')}")


def controller_status():
    net = controller_network_init()
    count = len(list(Path(CTRL_NET_NODES).glob("*.conf"))) if os.path.isdir(CTRL_NET_NODES) else 0
    _, active = active_network_records()
    print("contract=manager-hive-network-controller-v1")
    for k in ("network_id","topology","ipv4_cidr","ipv6_cidr","config_epoch","created_epoch","updated_epoch"):
        print(f"{k}={net.get(k,'')}")
    print(f"nodes_registered={count}")
    print(f"nodes_active={len(active)}")


def usage():
    print("Uso: hive_network.sh {--init|--status|--request ENDPOINT OUT [PORT]|--accept BUNDLE|--reconcile|--down|--controller-init|--controller-status|--controller-approve REQUEST|--controller-list|--controller-show NODE|--controller-enable NODE|--controller-disable NODE|--controller-bundle NODE OUT|--controller-bundle-all DIR}", file=sys.stderr)
    raise SystemExit(64)


def main(argv):
    cmd = argv[0] if argv else "--status"
    if cmd == "--init": init_node_network(); return
    if cmd == "--install":
        generate_wg_keypair()
        if os.path.isfile(NODE_TOPOLOGY): reconcile()
        return
    if cmd == "--status": status(); return
    if cmd == "--request" and len(argv) in {3,4}: make_request(argv[1], argv[2], argv[3] if len(argv)==4 else DEFAULT_PORT); return
    if cmd == "--accept" and len(argv) == 2: accept_bundle(argv[1]); return
    if cmd in {"--reconcile","--up"}: reconcile(); return
    if cmd == "--down": stop_service(False); print("network_up=0"); return
    if cmd == "--detach": stop_service(True); return
    if cmd == "--purge":
        stop_service(True)
        import shutil
        shutil.rmtree(NETWORK_DIR, ignore_errors=True)
        shutil.rmtree(CTRL_NET_DIR, ignore_errors=True)
        return
    if cmd == "--controller-init": controller_network_init(); controller_status(); return
    if cmd == "--controller-status": controller_status(); return
    if cmd == "--controller-approve" and len(argv) == 2: controller_approve(argv[1]); return
    if cmd == "--controller-list": controller_list(); return
    if cmd == "--controller-show" and len(argv) == 2: controller_show(argv[1]); return
    if cmd == "--controller-enable" and len(argv) == 2: controller_set_enabled(argv[1], True); return
    if cmd == "--controller-disable" and len(argv) == 2: controller_set_enabled(argv[1], False); return
    if cmd == "--controller-bundle" and len(argv) == 3: controller_bundle(argv[1], argv[2]); return
    if cmd == "--controller-bundle-all" and len(argv) == 2: controller_bundle_all(argv[1]); return
    usage()

main(sys.argv[1:])
PY
