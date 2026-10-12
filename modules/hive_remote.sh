#!/usr/bin/env bash
set -Eeuo pipefail

MANAGER_HOME="${MANAGER_HOME:-/opt/manager}"
MANAGER_ETC="${MANAGER_ETC:-/etc/manager}"
# shellcheck source=/dev/null
source "$MANAGER_HOME/lib/common.sh"
require_root

command -v python3 >/dev/null 2>&1 || { err "Python 3 é necessário para o roteamento remoto da Colmeia."; exit 69; }
command -v openssl >/dev/null 2>&1 || { err "OpenSSL é necessário para o roteamento remoto da Colmeia."; exit 69; }

python3 - "$@" <<'PY'
import base64
import hashlib
import ipaddress
import json
import os
import re
import secrets
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path

MANAGER_HOME = os.environ.get("MANAGER_HOME", "/opt/manager")
MANAGER_ETC = os.environ.get("MANAGER_ETC", "/etc/manager")
HIVE = os.path.join(MANAGER_ETC, "hive")
NODE_DIR = os.path.join(HIVE, "node")
CTRL_DIR = os.path.join(HIVE, "controller")
CTRL_NODES = os.path.join(CTRL_DIR, "nodes")
CTRL_REMOTE = os.path.join(CTRL_DIR, "remote")
NODE_KEY = os.path.join(NODE_DIR, "node.key")
NODE_PUB = os.path.join(NODE_DIR, "node.pub")
NODE_IDENTITY = os.path.join(NODE_DIR, "identity.conf")
NODE_ENROLLMENT = os.path.join(NODE_DIR, "enrollment.conf")
CTRL_KEY = os.path.join(CTRL_DIR, "controller.key")
CTRL_PUB = os.path.join(CTRL_DIR, "controller.pub")
CTRL_CONF = os.path.join(CTRL_DIR, "controller.conf")
AUTOMATION_DIR = os.path.join(MANAGER_ETC, "automation", "v2")
AUTOMATION_REMOTE = os.path.join(AUTOMATION_DIR, "remote.conf")
NODE_POLICY = os.path.join(AUTOMATION_DIR, "hive-controller.conf")
AUTOMATION = os.path.join(MANAGER_HOME, "modules", "automation_v2.sh")
SCHEDULER = os.path.join(MANAGER_HOME, "modules", "hive_scheduler.sh")
AUDIT = "/var/log/manager/hive-remote-audit.jsonl"
CONTRACT = "manager-hive-remote-route-v1"
POOL_RESULT_CONTRACT = "manager-hive-remote-pool-selection-v1"
VERSION = 1
MAX_AGE = 300
NODE_RE = re.compile(r"^node-[a-f0-9]{16}$")
CTRL_RE = re.compile(r"^controller-[a-f0-9]{16}$")
NODE_KEY_RE = re.compile(r"^node-ed25519-[a-f0-9]{16}$")
FP_RE = re.compile(r"^SHA256:[a-f0-9]{64}$")
ACTIONS = {
    "system.describe", "node.usage", "connection.preflight", "connection.create",
    "connection.status", "connection.revoke",
}


def die(message, code=70):
    print(message, file=sys.stderr)
    raise SystemExit(code)


def ensure_dir(path):
    os.makedirs(path, mode=0o700, exist_ok=True)
    os.chmod(path, 0o700)


def atomic_write(path, text, mode=0o600):
    ensure_dir(os.path.dirname(path))
    fd, tmp = tempfile.mkstemp(prefix=".tmp-", dir=os.path.dirname(path))
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)
        os.chmod(path, mode)
    finally:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass


def write_external_new(path, text):
    if not os.path.isabs(path) or not os.path.isdir(os.path.dirname(path)):
        die("Arquivo de saída precisa ser absoluto e ter diretório existente.", 64)
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        die("Arquivo de saída já existe; recusando sobrescrever.", 65)
    try:
        os.write(fd, text.encode("utf-8"))
        os.fsync(fd)
    finally:
        os.close(fd)
    os.chmod(path, 0o600)


def read_conf(path, strict=False):
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        return {}
    if not stat.S_ISREG(st.st_mode):
        die(f"Estado inválido: {path} não é arquivo regular.")
    if strict and (st.st_uid != 0 or stat.S_IMODE(st.st_mode) & 0o077):
        die(f"Estado protegido inseguro: {path}", 67)
    data = {}
    with open(path, "r", encoding="utf-8") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if "=" in line:
                k, v = line.split("=", 1)
                data[k] = v
    return data


def strict_json(path):
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        die(f"Arquivo não encontrado: {path}", 66)
    if not stat.S_ISREG(st.st_mode) or st.st_size > 262144:
        die("Documento de rota inválido.", 64)
    try:
        with open(path, "r", encoding="utf-8") as fh:
            obj = json.load(fh)
    except Exception:
        die("Documento JSON de rota inválido.", 64)
    if not isinstance(obj, dict):
        die("Documento de rota precisa ser objeto JSON.", 64)
    return obj


def openssl(args, input_data=None):
    proc = subprocess.run(["openssl", *args], input=input_data, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, timeout=15, check=False)
    if proc.returncode != 0:
        die("Falha criptográfica do OpenSSL.")
    return proc.stdout


def pub_der(path):
    return openssl(["pkey", "-pubin", "-in", path, "-outform", "DER"])


def pub_hash(path):
    return hashlib.sha256(pub_der(path)).digest()


def node_key_id(path):
    return "node-ed25519-" + pub_hash(path).hex()[:16]


def node_fingerprint(path):
    return "SHA256:" + pub_hash(path).hex()


def controller_id(path):
    return "controller-" + pub_hash(path).hex()[:16]


def canonical(obj):
    clean = dict(obj)
    clean.pop("signature", None)
    return json.dumps(clean, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def sign(private_path, payload):
    data_fd, data_path = tempfile.mkstemp(prefix="manager-remote-data-")
    sig_fd, sig_path = tempfile.mkstemp(prefix="manager-remote-sig-")
    os.close(sig_fd)
    try:
        os.fchmod(data_fd, 0o600)
        with os.fdopen(data_fd, "wb") as fh:
            fh.write(payload)
        proc = subprocess.run(["openssl", "pkeyutl", "-sign", "-inkey", private_path,
                               "-rawin", "-in", data_path, "-out", sig_path],
                              stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                              stderr=subprocess.PIPE, timeout=15, check=False)
        if proc.returncode != 0:
            die("Falha ao assinar anúncio de rota.")
        with open(sig_path, "rb") as fh:
            raw = fh.read()
    finally:
        for path in (data_path, sig_path):
            try:
                os.unlink(path)
            except FileNotFoundError:
                pass
    if len(raw) != 64:
        die("Assinatura Ed25519 inválida.")
    return base64.b64encode(raw).decode("ascii")


def verify(pub_path, payload, signature_text):
    try:
        sig = base64.b64decode(signature_text.encode("ascii"), validate=True)
    except Exception:
        return False
    if len(sig) != 64:
        return False
    data_fd, data_path = tempfile.mkstemp(prefix="manager-remote-data-")
    sig_fd, sig_path = tempfile.mkstemp(prefix="manager-remote-sig-")
    try:
        os.fchmod(data_fd, 0o600); os.fchmod(sig_fd, 0o600)
        with os.fdopen(data_fd, "wb") as fh:
            fh.write(payload)
        with os.fdopen(sig_fd, "wb") as fh:
            fh.write(sig)
        proc = subprocess.run(["openssl", "pkeyutl", "-verify", "-pubin", "-inkey", pub_path,
                               "-rawin", "-in", data_path, "-sigfile", sig_path],
                              stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL, timeout=15, check=False)
        return proc.returncode == 0
    finally:
        for path in (data_path, sig_path):
            try:
                os.unlink(path)
            except FileNotFoundError:
                pass


def normalize_actions(value):
    if not isinstance(value, str):
        die("Escopo de ações inválido.", 64)
    items = value.replace(" ", "").split(",")
    if not items or any(not item for item in items):
        die("Escopo de ações não pode ser vazio.", 64)
    out = []
    for item in items:
        if item not in ACTIONS:
            die(f"Ação remota não allowlisted: {item}", 64)
        if item not in out:
            out.append(item)
    return ",".join(out)


def action_allowed(scope, action):
    return action in set(scope.split(","))


def parse_endpoint(value):
    if not isinstance(value, str):
        die("Endpoint remoto inválido.", 64)
    if value.startswith("["):
        end = value.find("]")
        if end < 0 or end + 2 > len(value) or value[end + 1] != ":":
            die("Endpoint IPv6 inválido; use [IP]:PORT.", 64)
        host, port_text = value[1:end], value[end + 2:]
    else:
        if value.count(":") != 1:
            die("Endpoint inválido; use IP:PORT.", 64)
        host, port_text = value.rsplit(":", 1)
    try:
        ip = ipaddress.ip_address(host)
        port = int(port_text)
    except ValueError:
        die("Endpoint remoto precisa usar IP literal e porta válida.", 64)
    if not 1024 <= port <= 65535:
        die("Porta remota deve estar entre 1024 e 65535.", 64)
    if ip.is_multicast:
        die("Endpoint multicast não é permitido.", 64)
    rendered = f"[{ip.compressed}]:{port}" if ip.version == 6 else f"{ip.compressed}:{port}"
    return ip, port, rendered


def audit(event, **fields):
    ensure_dir(os.path.dirname(AUDIT))
    row = {"ts_epoch": int(time.time()), "event": event}
    row.update(fields)
    with open(AUDIT, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(row, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n")
    os.chmod(AUDIT, 0o600)


def node_state():
    identity = read_conf(NODE_IDENTITY, True)
    enrollment = read_conf(NODE_ENROLLMENT, True)
    if not identity or not enrollment:
        die("Nó precisa estar enrolled antes de habilitar roteamento remoto.", 67)
    node_id = identity.get("node_id", "")
    if not NODE_RE.fullmatch(node_id) or enrollment.get("node_id") != node_id:
        die("Identidade/enrollment local inconsistente.", 67)
    try:
        node_epoch = int(enrollment.get("node_epoch", "0"))
    except ValueError:
        die("node_epoch local inválido.", 67)
    cid = enrollment.get("controller_id", "")
    if node_epoch < 1 or not CTRL_RE.fullmatch(cid):
        die("Enrollment local inválido.", 67)
    if not os.path.isfile(NODE_KEY) or not os.path.isfile(NODE_PUB):
        die("Chave Ed25519 do nó ausente.", 67)
    if identity.get("key_id") != node_key_id(NODE_PUB) or identity.get("fingerprint") != node_fingerprint(NODE_PUB):
        die("Chave Ed25519 local não confere com a identidade do nó.", 67)
    return node_id, node_epoch, cid, identity["key_id"]


def automation_remote():
    conf = read_conf(AUTOMATION_REMOTE, True)
    if not conf or conf.get("enabled") != "1":
        die("Gateway remoto da Automation v2 precisa estar habilitado.", 69)
    try:
        port = int(conf.get("port", "0"))
    except ValueError:
        die("Configuração remota da Automation v2 inválida.", 69)
    fp = conf.get("server_fingerprint", "")
    if not 1024 <= port <= 65535 or not FP_RE.fullmatch(fp):
        die("Configuração TLS remota da Automation v2 inválida.", 69)
    return conf.get("bind", ""), port, fp


def node_policy_text(enabled, node_id, node_epoch, cid, endpoint, fp, actions, route_epoch):
    return (f"version=1\nenabled={1 if enabled else 0}\nnode_id={node_id}\nnode_epoch={node_epoch}\n"
            f"controller_id={cid}\nendpoint={endpoint}\nserver_fingerprint={fp}\n"
            f"action_scope={actions}\nroute_epoch={route_epoch}\nupdated_epoch={int(time.time())}\n")


def make_advertisement(enabled, out_path, endpoint=None, actions=None):
    node_id, node_epoch, cid, nkid = node_state()
    old = read_conf(NODE_POLICY, True)
    previous_epoch = int(old.get("route_epoch", "0")) if old.get("route_epoch", "0").isdigit() else 0
    route_epoch = previous_epoch + 1
    if enabled:
        bind, remote_port, fp = automation_remote()
        _ip, endpoint_port, rendered = parse_endpoint(endpoint)
        if endpoint_port != remote_port:
            die("A porta anunciada precisa coincidir com a porta ativa da Automation v2.", 64)
        actions = normalize_actions(actions)
        endpoint = rendered
    else:
        if not old:
            die("Roteamento remoto do nó ainda não possui estado para desabilitar.", 66)
        endpoint = old.get("endpoint", "")
        fp = old.get("server_fingerprint", "")
        actions = normalize_actions(old.get("action_scope", ""))
        parse_endpoint(endpoint)
        if not FP_RE.fullmatch(fp):
            die("Estado local de fingerprint remoto inválido.", 67)
    atomic_write(NODE_POLICY, node_policy_text(enabled, node_id, node_epoch, cid, endpoint, fp, actions, route_epoch))
    ad = {
        "contract": CONTRACT, "version": VERSION, "enabled": bool(enabled),
        "node_id": node_id, "node_epoch": node_epoch, "node_key_id": nkid,
        "controller_id": cid, "endpoint": endpoint, "server_fingerprint": fp,
        "action_scope": actions, "route_epoch": route_epoch,
        "issued_at": int(time.time()), "nonce": secrets.token_urlsafe(24),
    }
    ad["signature"] = sign(NODE_KEY, canonical(ad))
    write_external_new(out_path, json.dumps(ad, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n")
    audit("node-route-advertised", node_id=node_id, node_epoch=node_epoch, route_epoch=route_epoch,
          enabled=bool(enabled), endpoint=endpoint, action_scope=actions)
    print(f"route_advertisement={out_path}")
    print(f"node_id={node_id}")
    print(f"node_epoch={node_epoch}")
    print(f"route_epoch={route_epoch}")
    print(f"route_enabled={1 if enabled else 0}")
    print(f"endpoint={endpoint}")
    print(f"server_fingerprint={fp}")
    print(f"action_scope={actions}")


def node_status():
    conf = read_conf(NODE_POLICY, True)
    print(f"contract={CONTRACT}")
    print("routing_mode=signed-node-advertisement")
    print("arbitrary_target=0")
    print("controller_private_key_distribution=0")
    if not conf:
        print("route_configured=0")
        return
    print("route_configured=1")
    for key in ("enabled", "node_id", "node_epoch", "controller_id", "endpoint", "server_fingerprint", "action_scope", "route_epoch", "updated_epoch"):
        print(f"{key}={conf.get(key, '')}")


def controller_state():
    conf = read_conf(CTRL_CONF, True)
    if not conf or not os.path.isfile(CTRL_KEY) or not os.path.isfile(CTRL_PUB):
        die("Controlador da Colmeia precisa estar inicializado.", 69)
    cid = conf.get("controller_id", "")
    if not CTRL_RE.fullmatch(cid) or cid != controller_id(CTRL_PUB):
        die("Identidade do controlador inconsistente.", 67)
    return cid


def registered_node(node_id):
    if not NODE_RE.fullmatch(node_id):
        die("node_id inválido.", 64)
    conf_path = os.path.join(CTRL_NODES, node_id + ".conf")
    pub_path = os.path.join(CTRL_NODES, node_id + ".pub")
    conf = read_conf(conf_path, True)
    if not conf or not os.path.isfile(pub_path):
        die("Nó não está registrado no controlador.", 66)
    if conf.get("enabled") != "1" or conf.get("revoked_epoch", "0") != "0":
        die("Nó está revogado/desabilitado no controlador.", 67)
    try:
        epoch = int(conf.get("node_epoch", "0"))
    except ValueError:
        die("node_epoch registrado inválido.", 67)
    if epoch < 1 or conf.get("fingerprint") != node_fingerprint(pub_path) or conf.get("key_id") != node_key_id(pub_path):
        die("Registro criptográfico do nó inconsistente.", 67)
    return conf, pub_path, epoch


def validate_ad(ad):
    expected = {"contract", "version", "enabled", "node_id", "node_epoch", "node_key_id", "controller_id",
                "endpoint", "server_fingerprint", "action_scope", "route_epoch", "issued_at", "nonce", "signature"}
    if set(ad) != expected or ad.get("contract") != CONTRACT or ad.get("version") != VERSION:
        die("Contrato de anúncio remoto inválido.", 64)
    if not isinstance(ad.get("enabled"), bool):
        die("Campo enabled do anúncio inválido.", 64)
    node_id = ad.get("node_id", "")
    if not NODE_RE.fullmatch(node_id) or not NODE_KEY_RE.fullmatch(ad.get("node_key_id", "")):
        die("Identidade do nó no anúncio inválida.", 64)
    if not CTRL_RE.fullmatch(ad.get("controller_id", "")):
        die("controller_id do anúncio inválido.", 64)
    _ip, _port, rendered = parse_endpoint(ad.get("endpoint", ""))
    if rendered != ad.get("endpoint"):
        die("Endpoint do anúncio não está em forma canônica.", 64)
    if not FP_RE.fullmatch(ad.get("server_fingerprint", "")):
        die("Fingerprint TLS do anúncio inválido.", 64)
    actions = normalize_actions(ad.get("action_scope", ""))
    if actions != ad.get("action_scope"):
        die("Escopo de ações do anúncio não está normalizado.", 64)
    for key in ("node_epoch", "route_epoch", "issued_at"):
        value = ad.get(key)
        if isinstance(value, bool) or not isinstance(value, int) or value < 1:
            die(f"{key} inválido no anúncio.", 64)
    if abs(int(time.time()) - ad["issued_at"]) > MAX_AGE:
        die("Anúncio remoto expirado.", 67)
    nonce = ad.get("nonce", "")
    if not isinstance(nonce, str) or len(nonce) < 32 or len(nonce) > 96:
        die("Nonce do anúncio inválido.", 64)
    return node_id


def route_path(node_id):
    return os.path.join(CTRL_REMOTE, node_id + ".conf")


def controller_accept(path):
    cid = controller_state()
    ad = strict_json(path)
    node_id = validate_ad(ad)
    node_conf, pub_path, expected_epoch = registered_node(node_id)
    if ad["controller_id"] != cid:
        die("Anúncio foi emitido para outro controlador.", 67)
    if ad["node_epoch"] != expected_epoch:
        die("Anúncio cercado por node_epoch diferente da geração registrada.", 67)
    if ad["node_key_id"] != node_conf.get("key_id"):
        die("node_key_id do anúncio não corresponde ao nó registrado.", 67)
    if not verify(pub_path, canonical(ad), ad.get("signature", "")):
        die("Assinatura do anúncio remoto não confere.", 67)
    payload_hash = hashlib.sha256(canonical(ad)).hexdigest()
    ensure_dir(CTRL_REMOTE)
    old = read_conf(route_path(node_id), True)
    old_epoch = int(old.get("route_epoch", "0")) if old.get("route_epoch", "0").isdigit() else 0
    if ad["route_epoch"] < old_epoch:
        die("Anúncio remoto antigo recusado por route_epoch.", 67)
    if ad["route_epoch"] == old_epoch and old:
        if old.get("payload_sha256") != payload_hash:
            die("Conflito de anúncio reutilizando o mesmo route_epoch.", 67)
        print("route_accepted=1")
        print("idempotent=1")
        print(f"node_id={node_id}")
        print(f"route_epoch={ad['route_epoch']}")
        return
    text = (f"version=1\nnode_id={node_id}\nnode_epoch={ad['node_epoch']}\ncontroller_id={cid}\n"
            f"enabled={1 if ad['enabled'] else 0}\nendpoint={ad['endpoint']}\n"
            f"server_fingerprint={ad['server_fingerprint']}\naction_scope={ad['action_scope']}\n"
            f"route_epoch={ad['route_epoch']}\npayload_sha256={payload_hash}\nupdated_epoch={int(time.time())}\n")
    atomic_write(route_path(node_id), text)
    audit("controller-route-accepted", node_id=node_id, node_epoch=ad["node_epoch"], route_epoch=ad["route_epoch"],
          enabled=ad["enabled"], endpoint=ad["endpoint"], action_scope=ad["action_scope"])
    print("route_accepted=1")
    print("idempotent=0")
    print(f"node_id={node_id}")
    print(f"route_epoch={ad['route_epoch']}")
    print(f"route_enabled={1 if ad['enabled'] else 0}")


def controller_show(node_id):
    controller_state()
    if not NODE_RE.fullmatch(node_id):
        die("node_id inválido.", 64)
    path = route_path(node_id)
    if not os.path.isfile(path):
        die("Nó ainda não possui rota remota aceita.", 66)
    with open(path, "r", encoding="utf-8") as fh:
        sys.stdout.write(fh.read())


def controller_list():
    controller_state(); ensure_dir(CTRL_REMOTE)
    print("node_id|enabled|node_epoch|route_epoch|endpoint|action_scope")
    for path in sorted(Path(CTRL_REMOTE).glob("node-*.conf")):
        conf = read_conf(str(path), True)
        print("|".join(conf.get(k, "") for k in ("node_id", "enabled", "node_epoch", "route_epoch", "endpoint", "action_scope")))


def controller_status():
    controller_state(); ensure_dir(CTRL_REMOTE)
    total = enabled = 0
    for path in Path(CTRL_REMOTE).glob("node-*.conf"):
        conf = read_conf(str(path), True); total += 1
        enabled += 1 if conf.get("enabled") == "1" else 0
    print(f"contract={CONTRACT}")
    print("controller_routing=1")
    print("routing_target=registered-node-id")
    print("arbitrary_target=0")
    print("transport=tls1.3-pinned")
    print("request_auth=hive-controller-ed25519")
    print("pool_routing=1")
    print("pool_selector=hive-scheduler-weighted-least-loaded")
    print("pool_health_required=HEALTHY")
    print("pool_drain_respected=1")
    print(f"routes_registered={total}")
    print(f"routes_enabled={enabled}")


def route_candidates_for_action(action):
    ensure_dir(CTRL_REMOTE)
    candidates=[]
    for path in sorted(Path(CTRL_REMOTE).glob("node-*.conf")):
        route=read_conf(str(path), True)
        node_id=route.get("node_id", "")
        if not NODE_RE.fullmatch(node_id) or route.get("enabled") != "1":
            continue
        try:
            route_epoch=int(route.get("node_epoch", "0"))
        except ValueError:
            continue
        ident=read_conf(os.path.join(CTRL_NODES, node_id + ".conf"), True)
        if not ident or ident.get("enabled") != "1" or ident.get("revoked_epoch", "0") != "0":
            continue
        try:
            ident_epoch=int(ident.get("node_epoch", "0"))
        except ValueError:
            continue
        if route_epoch < 1 or route_epoch != ident_epoch:
            continue
        try:
            scope=normalize_actions(route.get("action_scope", ""))
        except SystemExit:
            continue
        if action_allowed(scope, action):
            candidates.append(node_id)
    return candidates


def validate_pool(value):
    if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,63}", value):
        die("Pool remoto inválido; use label simples até 64 caracteres.", 64)
    return value


def scheduler_select(pool, protocol, action, sticky=""):
    controller_state()
    pool=validate_pool(pool)
    if protocol not in {"ssh", "wireguard", "openvpn"}:
        die("Protocolo de seleção inválido; use ssh, wireguard ou openvpn.", 64)
    if action not in ACTIONS:
        die("Ação remota não está na allowlist tipada da Automation v2.", 64)
    if sticky and (len(sticky) > 128 or any(ord(ch) < 32 for ch in sticky)):
        die("Sticky key remota inválida.", 64)
    candidates=route_candidates_for_action(action)
    if not candidates:
        audit("controller-pool-deny", pool=pool, protocol=protocol, action_id=action, reason="no-route-candidate")
        die("Nenhum nó possui rota remota válida para a ação solicitada.", 67)
    node_scope=",".join(candidates)
    proc=subprocess.run([SCHEDULER, "--select", protocol, "", pool, sticky, node_scope],
                        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                        timeout=30, check=False, text=True)
    if proc.returncode != 0:
        if proc.stderr:
            sys.stderr.write(proc.stderr)
        audit("controller-pool-deny", pool=pool, protocol=protocol, action_id=action,
              reason="scheduler-no-eligible-node", route_candidates=len(candidates))
        raise SystemExit(proc.returncode)
    fields={}
    for line in proc.stdout.splitlines():
        if "=" in line:
            k,v=line.split("=",1); fields[k]=v
    selected=fields.get("selected_node", "")
    if not NODE_RE.fullmatch(selected) or selected not in set(candidates):
        die("Scheduler retornou nó fora do escopo de rotas remotas.", 70)
    # Revalidate route/authority after scheduler selection to close selection races.
    _ident, _pub, expected_epoch=registered_node(selected)
    route=read_conf(route_path(selected), True)
    try:
        selected_route_epoch=int(route.get("node_epoch", "0"))
    except ValueError:
        selected_route_epoch=0
    if route.get("enabled") != "1" or selected_route_epoch != expected_epoch or not action_allowed(normalize_actions(route.get("action_scope", "")), action):
        die("Rota selecionada mudou durante a decisão; operação recusada.", 67)
    audit("controller-pool-select", pool=pool, protocol=protocol, action_id=action,
          node_id=selected, selection_reason=fields.get("selection_reason", ""), sticky=bool(sticky),
          route_candidates=len(candidates))
    return fields


def controller_select_pool(argv):
    if len(argv) not in {3,4}:
        die("Uso: hive_remote.sh --controller-select-pool POOL PROTOCOL ACTION [STICKY]", 64)
    fields=scheduler_select(argv[0], argv[1], argv[2], argv[3] if len(argv)==4 else "")
    print(f"contract={POOL_RESULT_CONTRACT}")
    for key in ("selected_node","selected_name","state","protocol","country","region","pool","sessions","max_sessions","capacity","weight","rtt_ms","score","selection_reason","sticky","sticky_hit"):
        print(f"{key}={fields.get(key,'')}")
    print("routing_source=signed-route-registry+hive-scheduler")
    print("arbitrary_target=0")


def split_pool_call_args(rest):
    sticky=""; out=[]; i=0
    while i < len(rest):
        if rest[i] == "--sticky":
            if sticky or i+1 >= len(rest):
                die("--sticky exige uma única chave.", 64)
            sticky=rest[i+1]; i += 2; continue
        out.append(rest[i]); i += 1
    return sticky, out


def controller_call_pool(argv):
    if len(argv) < 3:
        die("Uso: hive_remote.sh --controller-call-pool POOL PROTOCOL ACTION [--sticky KEY] [KEY=VALUE|--request-id ID]", 64)
    pool, protocol, action=argv[:3]
    sticky, passthrough=split_pool_call_args(argv[3:])
    fields=scheduler_select(pool, protocol, action, sticky)
    selected=fields["selected_node"]
    audit("controller-pool-call", pool=pool, protocol=protocol, action_id=action, node_id=selected,
          selection_reason=fields.get("selection_reason", ""), sticky=bool(sticky))
    controller_call([selected, action, *passthrough])


def controller_call(argv):
    if len(argv) < 2:
        die("Uso: hive_remote.sh --controller-call NODE_ID ACTION [KEY=VALUE|--request-id ID]", 64)
    node_id, action, rest = argv[0], argv[1], argv[2:]
    controller_state()
    if action not in ACTIONS:
        die("Ação remota não está na allowlist tipada da Automation v2.", 64)
    node_conf, _pub, epoch = registered_node(node_id)
    route = read_conf(route_path(node_id), True)
    if not route or route.get("enabled") != "1":
        die("Rota remota do nó não está habilitada.", 69)
    if route.get("controller_id") != controller_state():
        die("Rota pertence a outra identidade de controlador.", 67)
    try:
        route_node_epoch = int(route.get("node_epoch", "0"))
    except ValueError:
        die("node_epoch da rota é inválido.", 67)
    if route_node_epoch != epoch:
        die("Rota remota cercada por mudança de node_epoch.", 67)
    endpoint = route.get("endpoint", "")
    fp = route.get("server_fingerprint", "")
    parse_endpoint(endpoint)
    if not FP_RE.fullmatch(fp):
        die("Fingerprint TLS armazenado da rota é inválido.", 67)
    scope = normalize_actions(route.get("action_scope", ""))
    if not action_allowed(scope, action):
        audit("controller-route-deny", node_id=node_id, action_id=action, reason="action-out-of-route-scope")
        die("Ação não está no escopo anunciado pelo nó.", 67)
    cmd = [AUTOMATION, "--call", "--hive-controller", "--remote", endpoint,
           "--server-fingerprint", fp, action, *rest]
    started = int(time.time())
    proc = subprocess.run(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          timeout=195, check=False, text=True)
    audit("controller-route-call", node_id=node_id, node_epoch=epoch, action_id=action,
          route_epoch=int(route.get("route_epoch", "0") or 0), result_code=proc.returncode,
          duration_seconds=max(0, int(time.time()) - started))
    if proc.stdout:
        sys.stdout.write(proc.stdout)
    if proc.stderr:
        sys.stderr.write(proc.stderr)
    raise SystemExit(proc.returncode)


def install_state():
    ensure_dir(CTRL_REMOTE)
    print("remote_routing_state=ready")


def purge_state():
    import shutil
    shutil.rmtree(CTRL_REMOTE, ignore_errors=True)
    try:
        os.unlink(NODE_POLICY)
    except FileNotFoundError:
        pass
    try:
        os.unlink(AUDIT)
    except FileNotFoundError:
        pass
    print("remote_routing_purged=1")


def usage():
    print("Uso: hive_remote.sh {--status|--node-enable ENDPOINT ACTIONS OUT|--node-disable OUT|--controller-status|--controller-accept AD|--controller-list|--controller-show NODE|--controller-call NODE ACTION [ARGS...]|--controller-select-pool POOL PROTOCOL ACTION [STICKY]|--controller-call-pool POOL PROTOCOL ACTION [ARGS...]|--install|--detach|--purge}", file=sys.stderr)
    raise SystemExit(64)


def main(argv):
    cmd = argv[0] if argv else "--status"
    if cmd == "--install": install_state(); return
    if cmd == "--detach": return
    if cmd == "--purge": purge_state(); return
    if cmd == "--status": node_status(); return
    if cmd == "--node-enable" and len(argv) == 4: make_advertisement(True, argv[3], argv[1], argv[2]); return
    if cmd == "--node-disable" and len(argv) == 2: make_advertisement(False, argv[1]); return
    if cmd == "--controller-status": controller_status(); return
    if cmd == "--controller-accept" and len(argv) == 2: controller_accept(argv[1]); return
    if cmd == "--controller-list": controller_list(); return
    if cmd == "--controller-show" and len(argv) == 2: controller_show(argv[1]); return
    if cmd == "--controller-call" and len(argv) >= 3: controller_call(argv[1:]); return
    if cmd == "--controller-select-pool" and len(argv) in {4,5}: controller_select_pool(argv[1:]); return
    if cmd == "--controller-call-pool" and len(argv) >= 4: controller_call_pool(argv[1:]); return
    usage()

main(sys.argv[1:])
PY
