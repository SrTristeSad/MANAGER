#!/usr/bin/env bash
set -Eeuo pipefail

MANAGER_HOME="${MANAGER_HOME:-/opt/manager}"
MANAGER_ETC="${MANAGER_ETC:-/etc/manager}"
# shellcheck source=/dev/null
source "$MANAGER_HOME/lib/common.sh"
require_root

command -v python3 >/dev/null 2>&1 || { err "Python 3 é necessário para rotação de chaves da Colmeia."; exit 69; }
command -v openssl >/dev/null 2>&1 || { err "OpenSSL é necessário para rotação de chaves da Colmeia."; exit 69; }

python3 - "$@" <<'PY'
import base64
import hashlib
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

MANAGER_ETC = os.environ.get("MANAGER_ETC", "/etc/manager")
HIVE_DIR = os.path.join(MANAGER_ETC, "hive")
NODE_DIR = os.path.join(HIVE_DIR, "node")
CTRL_DIR = os.path.join(HIVE_DIR, "controller")
CTRL_NODES = os.path.join(CTRL_DIR, "nodes")

NODE_KEY = os.path.join(NODE_DIR, "node.key")
NODE_PUB = os.path.join(NODE_DIR, "node.pub")
NODE_IDENTITY = os.path.join(NODE_DIR, "identity.conf")
NODE_ENROLLMENT = os.path.join(NODE_DIR, "enrollment.conf")
NODE_CONTROLLER = os.path.join(NODE_DIR, "controller.conf")
NODE_CONTROLLER_PUB = os.path.join(NODE_DIR, "controller.pub")

CTRL_KEY = os.path.join(CTRL_DIR, "controller.key")
CTRL_PUB = os.path.join(CTRL_DIR, "controller.pub")
CTRL_CONF = os.path.join(CTRL_DIR, "controller.conf")

NODE_ROT_DIR = os.path.join(NODE_DIR, "rotation")
NODE_PENDING = os.path.join(NODE_ROT_DIR, "pending")
NODE_HISTORY = os.path.join(NODE_ROT_DIR, "history")
NODE_REPLAY = os.path.join(NODE_ROT_DIR, "replay")
NODE_ROT_STATE = os.path.join(NODE_ROT_DIR, "state.conf")
CTRL_ROT_DIR = os.path.join(CTRL_DIR, "rotation")
CTRL_PENDING = os.path.join(CTRL_ROT_DIR, "pending")
CTRL_HISTORY = os.path.join(CTRL_ROT_DIR, "history")
CTRL_NODE_HISTORY = os.path.join(CTRL_ROT_DIR, "nodes")
CTRL_REPLAY = os.path.join(CTRL_ROT_DIR, "replay")
CTRL_ROT_STATE = os.path.join(CTRL_ROT_DIR, "state.conf")

NODE_REQ_CONTRACT = "manager-hive-node-key-rotation-request-v1"
NODE_BUNDLE_CONTRACT = "manager-hive-node-key-rotation-bundle-v1"
CTRL_TRANSITION_CONTRACT = "manager-hive-controller-key-transition-v1"
STATUS_CONTRACT = "manager-hive-key-rotation-v1"
VERSION = 1
ROTATION_MAX_AGE = 86400
NODE_ID_RE = re.compile(r"^node-[a-f0-9]{16}$")
FP_RE = re.compile(r"^SHA256:[a-f0-9]{64}$")
KEY_ID_RE = re.compile(r"^(?:node-ed25519-|controller-)[a-f0-9]{16}$")
NONCE_RE = re.compile(r"^[A-Za-z0-9_-]{32,96}$")
ROT_ID_RE = re.compile(r"^rot-[a-f0-9]{24}$")


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


def ensure_external_target(path):
    if not os.path.isabs(path):
        die("O arquivo de saída precisa usar caminho absoluto.", 64)
    parent = os.path.dirname(path)
    if not os.path.isdir(parent):
        die("O diretório do arquivo de saída não existe.", 64)
    if os.path.lexists(path):
        die("O arquivo de saída já existe; recusando sobrescrever.", 65)


def write_external_new(path, data):
    ensure_external_target(path)
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


def conf_text(data, keys):
    return "".join(f"{key}={data.get(key, '')}\n" for key in keys)


def strict_regular(path, max_size=262144):
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
        die("Documento de rotação precisa ser objeto JSON.", 64)
    return value


def canonical(obj):
    clean = dict(obj)
    for key in ("signature", "old_signature", "new_signature", "controller_signature"):
        clean.pop(key, None)
    return json.dumps(clean, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def openssl(args, input_data=None):
    proc = subprocess.run(["openssl", *args], input=input_data, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, timeout=20, check=False)
    if proc.returncode != 0:
        die("Falha criptográfica do OpenSSL.")
    return proc.stdout


def public_der(pub_path):
    return openssl(["pkey", "-pubin", "-in", pub_path, "-outform", "DER"])


def fingerprint(pub_path):
    return "SHA256:" + hashlib.sha256(public_der(pub_path)).hexdigest()


def key_id(prefix, pub_path):
    return prefix + hashlib.sha256(public_der(pub_path)).hexdigest()[:16]


def generate_keypair(private_path, public_path):
    ensure_dir(os.path.dirname(private_path))
    if os.path.lexists(private_path) or os.path.lexists(public_path):
        die("Já existe material de chave pendente; conclua a rotação antes de iniciar outra.", 65)
    key = openssl(["genpkey", "-algorithm", "ED25519"])
    fd, tmp = tempfile.mkstemp(prefix=".key-", dir=os.path.dirname(private_path))
    try:
        os.fchmod(fd, 0o600)
        os.write(fd, key)
        os.close(fd)
        pub = openssl(["pkey", "-in", tmp, "-pubout"])
        os.replace(tmp, private_path)
        os.chmod(private_path, 0o600)
        atomic_write(public_path, pub, 0o600)
    finally:
        try:
            os.close(fd)
        except OSError:
            pass
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass


def sign(private_path, payload):
    if not os.path.isfile(private_path):
        die("Chave privada necessária para a rotação não foi encontrada.", 69)
    dfd, dpath = tempfile.mkstemp(prefix="hive-rotate-data-")
    sfd, spath = tempfile.mkstemp(prefix="hive-rotate-sig-")
    os.close(sfd)
    try:
        os.fchmod(dfd, 0o600)
        with os.fdopen(dfd, "wb") as fh:
            fh.write(payload)
        proc = subprocess.run(["openssl", "pkeyutl", "-sign", "-inkey", private_path,
                               "-rawin", "-in", dpath, "-out", spath],
                              stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                              timeout=20, check=False)
        if proc.returncode != 0:
            die("Falha ao assinar transição de chave.")
        sig = Path(spath).read_bytes()
    finally:
        for path in (dpath, spath):
            try:
                os.unlink(path)
            except FileNotFoundError:
                pass
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
    dfd, dpath = tempfile.mkstemp(prefix="hive-rotate-data-")
    sfd, spath = tempfile.mkstemp(prefix="hive-rotate-sig-")
    try:
        os.fchmod(dfd, 0o600); os.fchmod(sfd, 0o600)
        with os.fdopen(dfd, "wb") as fh:
            fh.write(payload)
        with os.fdopen(sfd, "wb") as fh:
            fh.write(sig)
        proc = subprocess.run(["openssl", "pkeyutl", "-verify", "-pubin", "-inkey", pub_path,
                               "-rawin", "-in", dpath, "-sigfile", spath],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                              timeout=20, check=False)
        return proc.returncode == 0
    finally:
        for path in (dpath, spath):
            try:
                os.unlink(path)
            except FileNotFoundError:
                pass


def pem_to_temp(text):
    if not isinstance(text, str) or "BEGIN PUBLIC KEY" not in text or len(text) > 8192:
        die("Chave pública inválida.", 64)
    fd, path = tempfile.mkstemp(prefix="hive-rotate-pub-")
    os.fchmod(fd, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(text)
    return path


def validate_pub(text, prefix, expected_fp, expected_kid):
    path = pem_to_temp(text)
    try:
        actual_fp = fingerprint(path)
        actual_kid = key_id(prefix, path)
        if actual_fp != expected_fp or actual_kid != expected_kid:
            die("Fingerprint/key_id da chave de transição não conferem.", 67)
        return Path(path).read_text(encoding="utf-8")
    finally:
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass


def check_fresh(obj):
    issued = obj.get("issued_at")
    if isinstance(issued, bool) or not isinstance(issued, int) or abs(int(time.time()) - issued) > ROTATION_MAX_AGE:
        die("Mensagem de rotação expirada ou com timestamp inválido.", 67)
    nonce = obj.get("nonce", "")
    if not isinstance(nonce, str) or not NONCE_RE.fullmatch(nonce):
        die("Nonce de rotação inválido.", 64)


def consume_nonce(root, scope, nonce):
    ensure_dir(root)
    safe_scope = re.sub(r"[^A-Za-z0-9_.:-]", "_", scope)[:96]
    scope_dir = os.path.join(root, safe_scope)
    ensure_dir(scope_dir)
    name = hashlib.sha256(nonce.encode("utf-8")).hexdigest()
    path = os.path.join(scope_dir, name)
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        die("Replay de mensagem de rotação recusado.", 67)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(str(int(time.time())) + "\n")
        fh.flush()
        os.fsync(fh.fileno())


def copy_pub_history(src, dst_dir, name):
    ensure_dir(dst_dir)
    if os.path.isfile(src):
        atomic_write(os.path.join(dst_dir, name), Path(src).read_bytes(), 0o600)


def replace_keypair(stage_key, stage_pub, live_key, live_pub):
    if not os.path.isfile(stage_key) or not os.path.isfile(stage_pub):
        die("Material de chave staged não encontrado.", 66)
    atomic_write(live_key, Path(stage_key).read_bytes(), 0o600)
    atomic_write(live_pub, Path(stage_pub).read_bytes(), 0o600)


def node_current():
    ident = read_conf(NODE_IDENTITY)
    enroll = read_conf(NODE_ENROLLMENT)
    ctrl = read_conf(NODE_CONTROLLER)
    if not ident or not enroll or not ctrl or not os.path.isfile(NODE_KEY) or not os.path.isfile(NODE_PUB) or not os.path.isfile(NODE_CONTROLLER_PUB):
        die("Nó precisa estar enrolled antes de rotacionar identidade.", 67)
    node_id = ident.get("node_id", "")
    if not NODE_ID_RE.fullmatch(node_id) or enroll.get("node_id") != node_id:
        die("Estado de identidade/enrollment do nó é inconsistente.", 67)
    fp = fingerprint(NODE_PUB)
    kid = key_id("node-ed25519-", NODE_PUB)
    if ident.get("fingerprint") != fp or ident.get("key_id") != kid:
        die("Arquivo de identidade não corresponde à chave pública local.", 67)
    try:
        node_epoch = int(enroll.get("node_epoch", "0"))
    except ValueError:
        node_epoch = 0
    if node_epoch < 1:
        die("node_epoch local inválido.", 67)
    return ident, enroll, ctrl, node_id, node_epoch, fp, kid


def controller_current():
    conf = read_conf(CTRL_CONF)
    if not conf or not os.path.isfile(CTRL_KEY) or not os.path.isfile(CTRL_PUB):
        die("Controlador da Colmeia precisa estar inicializado.", 67)
    fp = fingerprint(CTRL_PUB)
    cid = key_id("controller-", CTRL_PUB)
    if conf.get("fingerprint") != fp or conf.get("controller_id") != cid:
        die("Estado da identidade do controlador é inconsistente.", 67)
    state = read_conf(CTRL_ROT_STATE)
    try:
        epoch = int(state.get("controller_epoch", "1"))
    except ValueError:
        epoch = 0
    if epoch < 1:
        die("controller_epoch inválido.", 67)
    return conf, cid, fp, epoch


def controller_node(node_id):
    if not NODE_ID_RE.fullmatch(node_id):
        die("node_id inválido.", 64)
    conf_path = os.path.join(CTRL_NODES, node_id + ".conf")
    pub_path = os.path.join(CTRL_NODES, node_id + ".pub")
    conf = read_conf(conf_path)
    if not conf or not os.path.isfile(pub_path):
        die("Nó não está registrado no controlador.", 66)
    try:
        epoch = int(conf.get("node_epoch", "0"))
    except ValueError:
        epoch = 0
    if conf.get("enabled") != "1" or conf.get("revoked_epoch", "0") != "0" or epoch < 1:
        die("Nó está revogado/desabilitado; rotação exige identidade ativa.", 67)
    actual_fp = fingerprint(pub_path)
    actual_kid = key_id("node-ed25519-", pub_path)
    if conf.get("fingerprint") != actual_fp or conf.get("key_id") != actual_kid:
        die("Registro do nó não corresponde à chave pública atual.", 67)
    return conf_path, pub_path, conf, epoch, actual_fp, actual_kid


def node_pending_paths():
    return (os.path.join(NODE_PENDING, "new.key"), os.path.join(NODE_PENDING, "new.pub"),
            os.path.join(NODE_PENDING, "request.json"), os.path.join(NODE_PENDING, "pending.conf"))


def node_prepare(out_path):
    ident, enroll, _, node_id, node_epoch, current_fp, current_kid = node_current()
    ensure_external_target(out_path)
    stage_key, stage_pub, req_path, pending_conf = node_pending_paths()
    if os.path.isfile(req_path) and os.path.isfile(stage_key) and os.path.isfile(stage_pub):
        req = read_json(req_path)
        check_fresh(req)
        write_external_new(out_path, json.dumps(req, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n")
        print("rotation_pending=1")
        print(f"rotation_id={req.get('rotation_id','')}")
        print(f"node_id={node_id}")
        print("cached_request=1")
        return
    if os.path.lexists(NODE_PENDING):
        die("Estado pendente de rotação do nó está incompleto; intervenção manual necessária.", 65)
    ensure_dir(NODE_PENDING)
    generate_keypair(stage_key, stage_pub)
    new_fp = fingerprint(stage_pub)
    new_kid = key_id("node-ed25519-", stage_pub)
    new_pub = Path(stage_pub).read_text(encoding="utf-8")
    rotation_id = "rot-" + secrets.token_hex(12)
    req = {
        "contract": NODE_REQ_CONTRACT, "version": VERSION, "rotation_id": rotation_id,
        "node_id": node_id, "node_epoch": node_epoch,
        "current_key_id": current_kid, "current_fingerprint": current_fp,
        "new_key_id": new_kid, "new_fingerprint": new_fp, "new_public_key": new_pub,
        "issued_at": int(time.time()), "nonce": secrets.token_urlsafe(24),
    }
    payload = canonical(req)
    req["old_signature"] = sign(NODE_KEY, payload)
    req["new_signature"] = sign(stage_key, payload)
    text = json.dumps(req, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n"
    atomic_write(req_path, text)
    atomic_write(pending_conf,
                 f"version=1\nrotation_id={rotation_id}\nnode_id={node_id}\nnode_epoch_from={node_epoch}\n"
                 f"current_key_id={current_kid}\ncurrent_fingerprint={current_fp}\nnew_key_id={new_kid}\nnew_fingerprint={new_fp}\n"
                 f"created_epoch={int(time.time())}\n")
    write_external_new(out_path, text)
    print("rotation_pending=1")
    print(f"rotation_id={rotation_id}")
    print(f"node_id={node_id}")
    print(f"node_epoch_from={node_epoch}")
    print(f"new_key_id={new_kid}")
    print(f"new_fingerprint={new_fp}")


def validate_node_request(req, current_pub, current_conf, current_epoch, current_fp, current_kid):
    expected = {"contract","version","rotation_id","node_id","node_epoch","current_key_id","current_fingerprint",
                "new_key_id","new_fingerprint","new_public_key","issued_at","nonce","old_signature","new_signature"}
    if set(req) != expected or req.get("contract") != NODE_REQ_CONTRACT or req.get("version") != VERSION:
        die("Contrato de rotação de identidade do nó inválido.", 64)
    check_fresh(req)
    if not ROT_ID_RE.fullmatch(req.get("rotation_id", "")) or req.get("node_id") != current_conf.get("node_id"):
        die("Identidade/rotation_id do request inválido.", 64)
    if req.get("node_epoch") != current_epoch:
        die("Request de rotação cercado por node_epoch diferente do atual.", 67)
    if req.get("current_fingerprint") != current_fp or req.get("current_key_id") != current_kid:
        die("Request não parte da chave atual registrada para o nó.", 67)
    if not FP_RE.fullmatch(req.get("new_fingerprint", "")) or not KEY_ID_RE.fullmatch(req.get("new_key_id", "")):
        die("Nova identidade Ed25519 do nó é inválida.", 64)
    new_pub_text = validate_pub(req.get("new_public_key"), "node-ed25519-", req["new_fingerprint"], req["new_key_id"])
    payload = canonical(req)
    if not verify(current_pub, payload, req.get("old_signature", "")):
        die("Assinatura da chave atual do nó não confere.", 67)
    new_pub_tmp = pem_to_temp(new_pub_text)
    try:
        if not verify(new_pub_tmp, payload, req.get("new_signature", "")):
            die("Prova de posse da nova chave do nó não confere.", 67)
    finally:
        os.unlink(new_pub_tmp)
    if req["new_fingerprint"] == current_fp:
        die("A nova chave do nó não pode ser igual à chave atual.", 65)
    return new_pub_text


def controller_accept_node(request_path, out_path):
    ctrl_conf, controller_id, controller_fp, _ = controller_current()
    ensure_external_target(out_path)
    req = read_json(request_path)
    node_id = req.get("node_id", "")
    conf_path, pub_path, node_conf, node_epoch, current_fp, current_kid = controller_node(node_id)
    rotation_id = req.get("rotation_id", "")
    history_dir = os.path.join(CTRL_NODE_HISTORY, node_id)
    history_bundle = os.path.join(history_dir, rotation_id + ".bundle.json") if ROT_ID_RE.fullmatch(rotation_id) else ""
    history_req = os.path.join(history_dir, rotation_id + ".request.sha256") if ROT_ID_RE.fullmatch(rotation_id) else ""
    req_digest = hashlib.sha256(canonical(req) + req.get("old_signature", "").encode() + req.get("new_signature", "").encode()).hexdigest()
    if history_bundle and os.path.isfile(history_bundle):
        recorded = Path(history_req).read_text(encoding="utf-8").strip() if os.path.isfile(history_req) else ""
        if recorded != req_digest:
            die("rotation_id já foi usado por outro request.", 67)
        write_external_new(out_path, Path(history_bundle).read_bytes())
        print("rotation_accepted=1")
        print("cached_bundle=1")
        print(f"rotation_id={rotation_id}")
        print(f"node_id={node_id}")
        return
    new_pub_text = validate_node_request(req, pub_path, node_conf, node_epoch, current_fp, current_kid)
    consume_nonce(CTRL_REPLAY, "node-" + node_id, req["nonce"])
    new_epoch = node_epoch + 1
    now = int(time.time())
    bundle = {
        "contract": NODE_BUNDLE_CONTRACT, "version": VERSION, "rotation_id": rotation_id,
        "controller_id": controller_id, "controller_fingerprint": controller_fp,
        "node_id": node_id, "node_epoch_from": node_epoch, "node_epoch_to": new_epoch,
        "old_key_id": current_kid, "old_fingerprint": current_fp,
        "new_key_id": req["new_key_id"], "new_fingerprint": req["new_fingerprint"],
        "request_sha256": req_digest, "issued_at": now, "nonce": secrets.token_urlsafe(24),
    }
    bundle["controller_signature"] = sign(CTRL_KEY, canonical(bundle))
    text = json.dumps(bundle, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n"
    ensure_dir(history_dir)
    copy_pub_history(pub_path, history_dir, rotation_id + ".old.pub")
    atomic_write(history_req, req_digest + "\n")
    atomic_write(history_bundle, text)
    atomic_write(pub_path, new_pub_text, 0o600)
    updated = dict(node_conf)
    updated.update({"key_id": req["new_key_id"], "fingerprint": req["new_fingerprint"], "node_epoch": str(new_epoch),
                    "updated_epoch": str(now), "enabled": "1", "revoked_epoch": "0", "revocation_reason": ""})
    keys = ("version","node_id","algorithm","key_id","fingerprint","enabled","node_epoch","created_epoch","updated_epoch","revoked_epoch","revocation_reason")
    atomic_write(conf_path, conf_text(updated, keys))
    write_external_new(out_path, text)
    print("rotation_accepted=1")
    print("cached_bundle=0")
    print(f"rotation_id={rotation_id}")
    print(f"node_id={node_id}")
    print(f"node_epoch_from={node_epoch}")
    print(f"node_epoch_to={new_epoch}")
    print(f"new_key_id={req['new_key_id']}")


def node_commit(bundle_path):
    ident, enroll, ctrl, node_id, current_epoch, current_fp, current_kid = node_current()
    bundle = read_json(bundle_path)
    expected = {"contract","version","rotation_id","controller_id","controller_fingerprint","node_id","node_epoch_from","node_epoch_to",
                "old_key_id","old_fingerprint","new_key_id","new_fingerprint","request_sha256","issued_at","nonce","controller_signature"}
    if set(bundle) != expected or bundle.get("contract") != NODE_BUNDLE_CONTRACT or bundle.get("version") != VERSION:
        die("Bundle de rotação do nó inválido.", 64)
    check_fresh(bundle)
    if bundle.get("node_id") != node_id or bundle.get("controller_id") != ctrl.get("controller_id") or bundle.get("controller_fingerprint") != ctrl.get("fingerprint"):
        die("Bundle de rotação pertence a outro nó/controlador.", 67)
    if not verify(NODE_CONTROLLER_PUB, canonical(bundle), bundle.get("controller_signature", "")):
        die("Assinatura do controlador no bundle de rotação não confere.", 67)
    rotation_id = bundle.get("rotation_id", "")
    if not ROT_ID_RE.fullmatch(rotation_id):
        die("rotation_id inválido.", 64)
    # Retry after successful commit is idempotent.
    if current_fp == bundle.get("new_fingerprint") and current_kid == bundle.get("new_key_id") and current_epoch == bundle.get("node_epoch_to"):
        print("rotated=1")
        print("cached=1")
        print(f"rotation_id={rotation_id}")
        print(f"node_id={node_id}")
        print(f"node_epoch={current_epoch}")
        return
    if current_epoch != bundle.get("node_epoch_from") or current_fp != bundle.get("old_fingerprint") or current_kid != bundle.get("old_key_id"):
        die("Bundle cercado por identidade/node_epoch que não é mais atual.", 67)
    if bundle.get("node_epoch_to") != current_epoch + 1:
        die("Transição de node_epoch inválida.", 67)
    stage_key, stage_pub, req_path, pending_conf = node_pending_paths()
    if not all(os.path.isfile(p) for p in (stage_key, stage_pub, req_path, pending_conf)):
        die("Material staged da nova identidade do nó não foi encontrado.", 66)
    pending = read_conf(pending_conf)
    req = read_json(req_path)
    req_digest = hashlib.sha256(canonical(req) + req.get("old_signature", "").encode() + req.get("new_signature", "").encode()).hexdigest()
    if pending.get("rotation_id") != rotation_id or req_digest != bundle.get("request_sha256"):
        die("Bundle não corresponde ao request staged local.", 67)
    if fingerprint(stage_pub) != bundle.get("new_fingerprint") or key_id("node-ed25519-", stage_pub) != bundle.get("new_key_id"):
        die("Nova chave staged não corresponde ao bundle aprovado.", 67)
    consume_nonce(NODE_REPLAY, "node-bundle", bundle["nonce"])
    hist_dir = os.path.join(NODE_HISTORY, rotation_id)
    ensure_dir(hist_dir)
    copy_pub_history(NODE_PUB, hist_dir, "old.pub")
    atomic_write(os.path.join(hist_dir, "bundle.json"), json.dumps(bundle, sort_keys=True, separators=(",", ":")) + "\n")
    replace_keypair(stage_key, stage_pub, NODE_KEY, NODE_PUB)
    now = int(time.time())
    created = ident.get("created_epoch", str(now))
    rot_state = read_conf(NODE_ROT_STATE)
    try:
        key_epoch = int(rot_state.get("key_epoch", "1")) + 1
    except ValueError:
        die("key_epoch local inválido.", 67)
    atomic_write(NODE_IDENTITY,
                 f"version=1\nnode_id={node_id}\nalgorithm=ed25519\nkey_id={bundle['new_key_id']}\n"
                 f"fingerprint={bundle['new_fingerprint']}\ncreated_epoch={created}\n")
    atomic_write(NODE_ROT_STATE,
                 f"version=1\nkey_epoch={key_epoch}\nlast_rotation_id={rotation_id}\nrotated_epoch={now}\n")
    enrolled = dict(enroll)
    enrolled["node_epoch"] = str(bundle["node_epoch_to"])
    enrolled["enrolled_epoch"] = str(now)
    enrolled["last_node_rotation_id"] = rotation_id
    keys = ("version","node_id","controller_id","controller_fingerprint","controller_epoch","node_epoch","enrollment_id","bundle_issued_epoch","enrolled_epoch","last_node_rotation_id")
    atomic_write(NODE_ENROLLMENT, conf_text(enrolled, keys))
    shutil.rmtree(NODE_PENDING, ignore_errors=True)
    print("rotated=1")
    print("cached=0")
    print(f"rotation_id={rotation_id}")
    print(f"node_id={node_id}")
    print(f"node_epoch={bundle['node_epoch_to']}")
    print(f"key_epoch={key_epoch}")


def controller_pending_paths():
    return (os.path.join(CTRL_PENDING, "new.key"), os.path.join(CTRL_PENDING, "new.pub"),
            os.path.join(CTRL_PENDING, "transition.json"), os.path.join(CTRL_PENDING, "pending.conf"))


def controller_prepare(out_path):
    conf, cid, cfp, epoch = controller_current()
    ensure_external_target(out_path)
    stage_key, stage_pub, transition_path, pending_conf = controller_pending_paths()
    if os.path.isfile(transition_path) and os.path.isfile(stage_key) and os.path.isfile(stage_pub):
        transition = read_json(transition_path)
        check_fresh(transition)
        write_external_new(out_path, json.dumps(transition, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n")
        print("rotation_pending=1")
        print("cached_transition=1")
        print(f"rotation_id={transition.get('rotation_id','')}")
        return
    if os.path.lexists(CTRL_PENDING):
        die("Estado pendente de rotação do controlador está incompleto; intervenção manual necessária.", 65)
    ensure_dir(CTRL_PENDING)
    generate_keypair(stage_key, stage_pub)
    new_fp = fingerprint(stage_pub)
    new_cid = key_id("controller-", stage_pub)
    old_pub = Path(CTRL_PUB).read_text(encoding="utf-8")
    new_pub = Path(stage_pub).read_text(encoding="utf-8")
    rotation_id = "rot-" + secrets.token_hex(12)
    transition = {
        "contract": CTRL_TRANSITION_CONTRACT, "version": VERSION, "rotation_id": rotation_id,
        "controller_epoch_from": epoch, "controller_epoch_to": epoch + 1,
        "old_controller_id": cid, "old_fingerprint": cfp, "old_public_key": old_pub,
        "new_controller_id": new_cid, "new_fingerprint": new_fp, "new_public_key": new_pub,
        "issued_at": int(time.time()), "nonce": secrets.token_urlsafe(24),
    }
    payload = canonical(transition)
    transition["old_signature"] = sign(CTRL_KEY, payload)
    transition["new_signature"] = sign(stage_key, payload)
    text = json.dumps(transition, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n"
    atomic_write(transition_path, text)
    atomic_write(pending_conf,
                 f"version=1\nrotation_id={rotation_id}\ncontroller_epoch_from={epoch}\ncontroller_epoch_to={epoch+1}\n"
                 f"old_controller_id={cid}\nold_fingerprint={cfp}\nnew_controller_id={new_cid}\nnew_fingerprint={new_fp}\n"
                 f"created_epoch={int(time.time())}\n")
    write_external_new(out_path, text)
    print("rotation_pending=1")
    print("cached_transition=0")
    print(f"rotation_id={rotation_id}")
    print(f"controller_epoch_from={epoch}")
    print(f"controller_epoch_to={epoch+1}")
    print(f"new_controller_id={new_cid}")
    print(f"new_fingerprint={new_fp}")


def validate_controller_transition(transition, old_pub_path=None):
    expected = {"contract","version","rotation_id","controller_epoch_from","controller_epoch_to",
                "old_controller_id","old_fingerprint","old_public_key","new_controller_id","new_fingerprint","new_public_key",
                "issued_at","nonce","old_signature","new_signature"}
    if set(transition) != expected or transition.get("contract") != CTRL_TRANSITION_CONTRACT or transition.get("version") != VERSION:
        die("Contrato de transição do controlador inválido.", 64)
    check_fresh(transition)
    if not ROT_ID_RE.fullmatch(transition.get("rotation_id", "")):
        die("rotation_id inválido.", 64)
    ef = transition.get("controller_epoch_from")
    et = transition.get("controller_epoch_to")
    if isinstance(ef, bool) or not isinstance(ef, int) or isinstance(et, bool) or not isinstance(et, int) or ef < 1 or et != ef + 1:
        die("Transição de controller_epoch inválida.", 64)
    if not FP_RE.fullmatch(transition.get("old_fingerprint", "")) or not FP_RE.fullmatch(transition.get("new_fingerprint", "")):
        die("Fingerprint de controlador inválido.", 64)
    if not KEY_ID_RE.fullmatch(transition.get("old_controller_id", "")) or not KEY_ID_RE.fullmatch(transition.get("new_controller_id", "")):
        die("controller_id da transição inválido.", 64)
    old_text = validate_pub(transition.get("old_public_key"), "controller-", transition["old_fingerprint"], transition["old_controller_id"])
    new_text = validate_pub(transition.get("new_public_key"), "controller-", transition["new_fingerprint"], transition["new_controller_id"])
    payload = canonical(transition)
    old_tmp = pem_to_temp(old_text)
    new_tmp = pem_to_temp(new_text)
    try:
        if old_pub_path is not None:
            if fingerprint(old_pub_path) != transition["old_fingerprint"] or key_id("controller-", old_pub_path) != transition["old_controller_id"]:
                die("Transição não parte do controlador atualmente confiável.", 67)
        if not verify(old_tmp, payload, transition.get("old_signature", "")):
            die("Assinatura da chave antiga do controlador não confere.", 67)
        if not verify(new_tmp, payload, transition.get("new_signature", "")):
            die("Prova de posse da nova chave do controlador não confere.", 67)
    finally:
        os.unlink(old_tmp); os.unlink(new_tmp)
    if transition["old_fingerprint"] == transition["new_fingerprint"]:
        die("A nova chave do controlador não pode ser igual à atual.", 65)
    return old_text, new_text


def controller_commit(transition_path):
    conf, cid, cfp, epoch = controller_current()
    transition = read_json(transition_path)
    rotation_id = transition.get("rotation_id", "")
    history_path = os.path.join(CTRL_HISTORY, rotation_id + ".transition.json") if ROT_ID_RE.fullmatch(rotation_id) else ""
    # Idempotent retry after commit.
    if cid == transition.get("new_controller_id") and cfp == transition.get("new_fingerprint") and epoch == transition.get("controller_epoch_to"):
        validate_controller_transition(transition)
        print("rotated=1")
        print("cached=1")
        print(f"rotation_id={rotation_id}")
        print(f"controller_epoch={epoch}")
        return
    if cid != transition.get("old_controller_id") or cfp != transition.get("old_fingerprint") or epoch != transition.get("controller_epoch_from"):
        die("Transição não corresponde à identidade/epoch atual do controlador.", 67)
    _, new_pub_text = validate_controller_transition(transition, CTRL_PUB)
    stage_key, stage_pub, pending_transition, pending_conf = controller_pending_paths()
    if not all(os.path.isfile(p) for p in (stage_key, stage_pub, pending_transition, pending_conf)):
        die("Material staged da nova identidade do controlador não foi encontrado.", 66)
    pending = read_json(pending_transition)
    if hashlib.sha256(canonical(pending)).hexdigest() != hashlib.sha256(canonical(transition)).hexdigest():
        die("Transição informada não corresponde ao material staged do controlador.", 67)
    if fingerprint(stage_pub) != transition["new_fingerprint"] or key_id("controller-", stage_pub) != transition["new_controller_id"]:
        die("Nova chave staged do controlador não corresponde à transição.", 67)
    consume_nonce(CTRL_REPLAY, "controller-transition", transition["nonce"])
    ensure_dir(CTRL_HISTORY)
    copy_pub_history(CTRL_PUB, CTRL_HISTORY, rotation_id + ".old.pub")
    atomic_write(history_path, json.dumps(transition, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n")
    replace_keypair(stage_key, stage_pub, CTRL_KEY, CTRL_PUB)
    now = int(time.time())
    created = conf.get("created_epoch", str(now))
    atomic_write(CTRL_CONF,
                 f"version=1\ncontroller_id={transition['new_controller_id']}\nalgorithm=ed25519\n"
                 f"fingerprint={transition['new_fingerprint']}\ncreated_epoch={created}\n")
    atomic_write(CTRL_ROT_STATE,
                 f"version=1\ncontroller_epoch={transition['controller_epoch_to']}\nlast_rotation_id={rotation_id}\nrotated_epoch={now}\n")
    shutil.rmtree(CTRL_PENDING, ignore_errors=True)
    print("rotated=1")
    print("cached=0")
    print(f"rotation_id={rotation_id}")
    print(f"controller_id={transition['new_controller_id']}")
    print(f"controller_fingerprint={transition['new_fingerprint']}")
    print(f"controller_epoch={transition['controller_epoch_to']}")
    print("nodes_require_transition_accept=1")


def node_accept_controller(transition_path):
    ident, enroll, ctrl, node_id, node_epoch, _, _ = node_current()
    transition = read_json(transition_path)
    rotation_id = transition.get("rotation_id", "")
    current_cid = ctrl.get("controller_id", "")
    current_fp = ctrl.get("fingerprint", "")
    try:
        local_epoch = int(ctrl.get("controller_epoch", "1"))
    except ValueError:
        local_epoch = 0
    # Idempotent retry after acceptance.
    if current_cid == transition.get("new_controller_id") and current_fp == transition.get("new_fingerprint"):
        validate_controller_transition(transition)
        if local_epoch != transition.get("controller_epoch_to"):
            die("controller_epoch local diverge da transição já aceita.", 67)
        print("controller_rotation_accepted=1")
        print("cached=1")
        print(f"rotation_id={rotation_id}")
        print(f"controller_epoch={local_epoch}")
        return
    if current_cid != transition.get("old_controller_id") or current_fp != transition.get("old_fingerprint"):
        die("Transição não parte do controlador atualmente pinado no nó.", 67)
    old_text, new_text = validate_controller_transition(transition, NODE_CONTROLLER_PUB)
    if transition.get("controller_epoch_to", 0) <= local_epoch:
        die("Transição de controlador antiga recusada por fencing de controller_epoch.", 67)
    consume_nonce(NODE_REPLAY, "controller-transition", transition["nonce"])
    hist_dir = os.path.join(NODE_HISTORY, "controller-" + rotation_id)
    ensure_dir(hist_dir)
    atomic_write(os.path.join(hist_dir, "old.pub"), old_text, 0o600)
    atomic_write(os.path.join(hist_dir, "transition.json"), json.dumps(transition, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n")
    atomic_write(NODE_CONTROLLER_PUB, new_text, 0o600)
    atomic_write(NODE_CONTROLLER,
                 f"version=1\ncontroller_id={transition['new_controller_id']}\nfingerprint={transition['new_fingerprint']}\n"
                 f"algorithm=ed25519\ncontroller_epoch={transition['controller_epoch_to']}\nlast_rotation_id={rotation_id}\n")
    enrolled = dict(enroll)
    enrolled["controller_id"] = transition["new_controller_id"]
    enrolled["controller_fingerprint"] = transition["new_fingerprint"]
    enrolled["controller_epoch"] = str(transition["controller_epoch_to"])
    enrolled["enrolled_epoch"] = str(int(time.time()))
    enrolled["last_controller_rotation_id"] = rotation_id
    keys = ("version","node_id","controller_id","controller_fingerprint","controller_epoch","node_epoch","enrollment_id","bundle_issued_epoch","enrolled_epoch","last_node_rotation_id","last_controller_rotation_id")
    atomic_write(NODE_ENROLLMENT, conf_text(enrolled, keys))
    print("controller_rotation_accepted=1")
    print("cached=0")
    print(f"rotation_id={rotation_id}")
    print(f"node_id={node_id}")
    print(f"node_epoch={node_epoch}")
    print(f"controller_id={transition['new_controller_id']}")
    print(f"controller_epoch={transition['controller_epoch_to']}")


def status():
    node_ident = read_conf(NODE_IDENTITY)
    node_enroll = read_conf(NODE_ENROLLMENT)
    node_rot = read_conf(NODE_ROT_STATE)
    ctrl_conf = read_conf(CTRL_CONF)
    ctrl_rot = read_conf(CTRL_ROT_STATE)
    _, _, node_req, _ = node_pending_paths()
    _, _, ctrl_transition, _ = controller_pending_paths()
    print(f"contract={STATUS_CONTRACT}")
    print("algorithm=ed25519")
    print("custom_crypto=0")
    print(f"rotation_message_max_age={ROTATION_MAX_AGE}")
    print("nonce_replay_cache=1")
    print(f"node_rotation_pending={1 if os.path.isfile(node_req) else 0}")
    print(f"controller_rotation_pending={1 if os.path.isfile(ctrl_transition) else 0}")
    print(f"node_key_epoch={node_rot.get('key_epoch','1') if node_ident else ''}")
    print(f"node_epoch={node_enroll.get('node_epoch','') if node_enroll else ''}")
    print(f"controller_epoch={ctrl_rot.get('controller_epoch','1') if ctrl_conf else ''}")
    print("old_private_key_retained=0")
    print("rotation_fail_closed=1")


def usage():
    print("Uso: hive_key_rotation.sh {--status|--node-prepare OUT|--controller-accept-node REQUEST OUT|--node-commit BUNDLE|--controller-prepare OUT|--controller-commit TRANSITION|--node-accept-controller TRANSITION}", file=sys.stderr)
    raise SystemExit(64)


def main(argv):
    cmd = argv[0] if argv else "--status"
    if cmd in {"--status", "--install"}: status(); return
    if cmd == "--node-prepare" and len(argv) == 2: node_prepare(argv[1]); return
    if cmd == "--controller-accept-node" and len(argv) == 3: controller_accept_node(argv[1], argv[2]); return
    if cmd == "--node-commit" and len(argv) == 2: node_commit(argv[1]); return
    if cmd == "--controller-prepare" and len(argv) == 2: controller_prepare(argv[1]); return
    if cmd == "--controller-commit" and len(argv) == 2: controller_commit(argv[1]); return
    if cmd == "--node-accept-controller" and len(argv) == 2: node_accept_controller(argv[1]); return
    if cmd in {"--detach", "--purge"}:
        return
    usage()

main(sys.argv[1:])
PY
