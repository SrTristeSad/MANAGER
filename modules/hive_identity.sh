#!/usr/bin/env bash
set -Eeuo pipefail

MANAGER_HOME="${MANAGER_HOME:-/opt/manager}"
MANAGER_ETC="${MANAGER_ETC:-/etc/manager}"
# shellcheck source=/dev/null
source "$MANAGER_HOME/lib/common.sh"
require_root

command -v python3 >/dev/null 2>&1 || { err "Python 3 é necessário para a identidade da Colmeia."; exit 69; }
command -v openssl >/dev/null 2>&1 || { err "OpenSSL é necessário para a identidade da Colmeia."; exit 69; }

python3 - "$@" <<'PY'
import base64
import hashlib
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
NODE_META = os.path.join(MANAGER_ETC, "connection", "node", "node.conf")
NODE_META_MODULE = os.path.join(MANAGER_HOME, "modules", "node_metadata.sh")
HIVE_DIR = os.path.join(MANAGER_ETC, "hive")
NODE_DIR = os.path.join(HIVE_DIR, "node")
CONTROLLER_DIR = os.path.join(HIVE_DIR, "controller")
CONTROLLER_NODES = os.path.join(CONTROLLER_DIR, "nodes")
NODE_KEY = os.path.join(NODE_DIR, "node.key")
NODE_PUB = os.path.join(NODE_DIR, "node.pub")
NODE_IDENTITY = os.path.join(NODE_DIR, "identity.conf")
NODE_CONTROLLER = os.path.join(NODE_DIR, "controller.conf")
NODE_CONTROLLER_PUB = os.path.join(NODE_DIR, "controller.pub")
NODE_ENROLLMENT = os.path.join(NODE_DIR, "enrollment.conf")
CTRL_KEY = os.path.join(CONTROLLER_DIR, "controller.key")
CTRL_PUB = os.path.join(CONTROLLER_DIR, "controller.pub")
CTRL_CONF = os.path.join(CONTROLLER_DIR, "controller.conf")
REQUEST_CONTRACT = "manager-hive-enrollment-request-v1"
BUNDLE_CONTRACT = "manager-hive-enrollment-bundle-v1"
VERSION = 1
REQUEST_MAX_AGE = 86400
NODE_ID_RE = re.compile(r"^node-[a-f0-9]{16}$")
SAFE_LABEL_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.:-]{0,63}$")
FP_RE = re.compile(r"^SHA256:[a-f0-9]{64}$")


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
        die("O diretório do arquivo de saída não existe.", 64)
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    try:
        fd = os.open(path, flags, 0o600)
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
                key, value = line.split("=", 1)
                data[key] = value
    return data


def strict_regular(path, max_size=262144):
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        die(f"Arquivo não encontrado: {path}", 66)
    if not stat.S_ISREG(st.st_mode) or st.st_size > max_size:
        die(f"Arquivo recusado: {path}", 64)


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
    if os.path.exists(private_path) or os.path.exists(public_path):
        die("Estado de chave parcial/inconsistente; não sobrescrevendo material existente.", 65)
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
    data_fd, data_path = tempfile.mkstemp(prefix="manager-hive-data-")
    sig_fd, sig_path = tempfile.mkstemp(prefix="manager-hive-sig-")
    os.close(sig_fd)
    try:
        os.fchmod(data_fd, 0o600)
        with os.fdopen(data_fd, "wb") as fh:
            fh.write(payload)
        proc = subprocess.run(["openssl", "pkeyutl", "-sign", "-inkey", private_path,
                               "-rawin", "-in", data_path, "-out", sig_path],
                              stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                              stderr=subprocess.PIPE, timeout=20, check=False)
        if proc.returncode != 0:
            die("Falha ao assinar payload da Colmeia.")
        with open(sig_path, "rb") as fh:
            sig = fh.read()
    finally:
        for path in (data_path, sig_path):
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
    data_fd, data_path = tempfile.mkstemp(prefix="manager-hive-data-")
    sig_fd, sig_path = tempfile.mkstemp(prefix="manager-hive-sig-")
    try:
        os.fchmod(data_fd, 0o600); os.fchmod(sig_fd, 0o600)
        with os.fdopen(data_fd, "wb") as fh:
            fh.write(payload)
        with os.fdopen(sig_fd, "wb") as fh:
            fh.write(sig)
        proc = subprocess.run(["openssl", "pkeyutl", "-verify", "-pubin", "-inkey", pub_path,
                               "-rawin", "-in", data_path, "-sigfile", sig_path],
                              stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL, timeout=20, check=False)
        return proc.returncode == 0
    finally:
        for path in (data_path, sig_path):
            try:
                os.unlink(path)
            except FileNotFoundError:
                pass


def canonical(obj):
    clean = dict(obj)
    clean.pop("signature", None)
    return json.dumps(clean, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def pem_to_temp(text):
    if not isinstance(text, str) or "BEGIN PUBLIC KEY" not in text or len(text) > 8192:
        die("Chave pública inválida.", 64)
    fd, path = tempfile.mkstemp(prefix="manager-hive-pub-")
    os.fchmod(fd, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(text)
    return path


def read_json(path):
    strict_regular(path)
    try:
        with open(path, "r", encoding="utf-8") as fh:
            value = json.load(fh)
    except (UnicodeDecodeError, json.JSONDecodeError):
        die("Documento JSON inválido.", 64)
    if not isinstance(value, dict):
        die("Documento de enrollment precisa ser objeto JSON.", 64)
    return value


def ensure_node_metadata():
    if not os.path.isfile(NODE_META):
        proc = subprocess.run([NODE_META_MODULE, "--init"], stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL, timeout=20, check=False)
        if proc.returncode != 0:
            die("Não foi possível inicializar node metadata.", 69)
    meta = read_conf(NODE_META)
    node_id = meta.get("node_id", "")
    if not NODE_ID_RE.fullmatch(node_id):
        die("node_id local inválido.")
    return meta


def init_node():
    meta = ensure_node_metadata()
    ensure_dir(HIVE_DIR); ensure_dir(NODE_DIR)
    if os.path.exists(NODE_KEY) != os.path.exists(NODE_PUB):
        die("Identidade do nó está incompleta; intervenção manual necessária.")
    if not os.path.exists(NODE_KEY):
        generate_keypair(NODE_KEY, NODE_PUB)
    fp = fingerprint(NODE_PUB)
    kid = key_id("node-ed25519-", NODE_PUB)
    existing = read_conf(NODE_IDENTITY)
    created = existing.get("created_epoch", str(int(time.time())))
    text = (f"version=1\nnode_id={meta['node_id']}\nalgorithm=ed25519\nkey_id={kid}\n"
            f"fingerprint={fp}\ncreated_epoch={created}\n")
    atomic_write(NODE_IDENTITY, text)
    return meta, fp, kid


def init_controller():
    ensure_dir(HIVE_DIR); ensure_dir(CONTROLLER_DIR); ensure_dir(CONTROLLER_NODES)
    if os.path.exists(CTRL_KEY) != os.path.exists(CTRL_PUB):
        die("Identidade do controlador está incompleta; intervenção manual necessária.")
    if not os.path.exists(CTRL_KEY):
        generate_keypair(CTRL_KEY, CTRL_PUB)
    fp = fingerprint(CTRL_PUB)
    cid = key_id("controller-", CTRL_PUB)
    existing = read_conf(CTRL_CONF)
    created = existing.get("created_epoch", str(int(time.time())))
    atomic_write(CTRL_CONF, f"version=1\ncontroller_id={cid}\nalgorithm=ed25519\nfingerprint={fp}\ncreated_epoch={created}\n")
    return cid, fp


def node_status():
    meta, fp, kid = init_node()
    enrolled = os.path.isfile(NODE_ENROLLMENT) and os.path.isfile(NODE_CONTROLLER_PUB)
    print("contract=manager-hive-node-identity-v1")
    print(f"node_id={meta['node_id']}")
    print("algorithm=ed25519")
    print(f"key_id={kid}")
    print(f"fingerprint={fp}")
    print(f"enrolled={1 if enrolled else 0}")
    if enrolled:
        for key in ("controller_id", "controller_fingerprint", "node_epoch", "enrollment_id", "enrolled_epoch"):
            value = read_conf(NODE_ENROLLMENT).get(key, "")
            print(f"{key}={value}")


def controller_status():
    if not os.path.isfile(CTRL_CONF):
        print("controller_initialized=0")
        return
    conf = read_conf(CTRL_CONF)
    print("contract=manager-hive-controller-identity-v1")
    print("controller_initialized=1")
    for key in ("controller_id", "algorithm", "fingerprint", "created_epoch"):
        print(f"{key}={conf.get(key, '')}")
    count = len(list(Path(CONTROLLER_NODES).glob("*.conf"))) if os.path.isdir(CONTROLLER_NODES) else 0
    print(f"nodes_registered={count}")


def make_request(out_path):
    meta, fp, kid = init_node()
    with open(NODE_PUB, "r", encoding="utf-8") as fh:
        pub = fh.read()
    fields = {k: meta.get(k, "") for k in ("name", "country", "region", "pool", "provider", "city", "capacity", "weight", "max_sessions", "enabled")}
    req = {"contract": REQUEST_CONTRACT, "version": VERSION, "node_id": meta["node_id"],
           "node_key_id": kid, "node_fingerprint": fp, "node_public_key": pub,
           "issued_at": int(time.time()), "nonce": secrets.token_urlsafe(24), "metadata": fields}
    req["signature"] = sign(NODE_KEY, canonical(req))
    write_external_new(out_path, json.dumps(req, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n")
    print(f"request_file={out_path}")
    print(f"node_id={meta['node_id']}")
    print(f"node_fingerprint={fp}")


def validate_request(req):
    expected = {"contract", "version", "node_id", "node_key_id", "node_fingerprint", "node_public_key", "issued_at", "nonce", "metadata", "signature"}
    if set(req) != expected or req.get("contract") != REQUEST_CONTRACT or req.get("version") != VERSION:
        die("Contrato de enrollment request inválido.", 64)
    node_id = req.get("node_id", "")
    if not NODE_ID_RE.fullmatch(node_id):
        die("node_id do request inválido.", 64)
    issued = req.get("issued_at")
    if isinstance(issued, bool) or not isinstance(issued, int) or abs(int(time.time()) - issued) > REQUEST_MAX_AGE:
        die("Enrollment request expirado ou com timestamp inválido.", 67)
    nonce = req.get("nonce", "")
    if not isinstance(nonce, str) or len(nonce) < 32 or len(nonce) > 96:
        die("Nonce do enrollment request inválido.", 64)
    metadata = req.get("metadata")
    if not isinstance(metadata, dict):
        die("Metadata do enrollment request inválido.", 64)
    pub_path = pem_to_temp(req.get("node_public_key"))
    try:
        actual_fp = fingerprint(pub_path)
        actual_kid = key_id("node-ed25519-", pub_path)
        if actual_fp != req.get("node_fingerprint") or actual_kid != req.get("node_key_id"):
            die("Fingerprint/key_id do nó não conferem.", 67)
        if not verify(pub_path, canonical(req), req.get("signature", "")):
            die("Assinatura do enrollment request não confere.", 67)
    finally:
        os.unlink(pub_path)
    return node_id, actual_fp, actual_kid


def controller_node_paths(node_id):
    return (os.path.join(CONTROLLER_NODES, node_id + ".conf"), os.path.join(CONTROLLER_NODES, node_id + ".pub"))


def controller_approve(request_path, out_path, reenroll=False):
    cid, cfp = init_controller()
    req = read_json(request_path)
    node_id, nfp, nkid = validate_request(req)
    conf_path, pub_path = controller_node_paths(node_id)
    existing = read_conf(conf_path)
    now = int(time.time())
    if existing:
        same = existing.get("fingerprint") == nfp
        active = existing.get("enabled") == "1" and existing.get("revoked_epoch", "0") == "0"
        if not reenroll and (not same or not active):
            die("Nó já registrado com outra geração/estado; use controller reenroll explicitamente.", 65)
        epoch = int(existing.get("node_epoch", "1")) + (1 if reenroll else 0)
        created = existing.get("created_epoch", str(now))
    else:
        epoch, created = 1, str(now)
    atomic_write(pub_path, req["node_public_key"])
    conf = (f"version=1\nnode_id={node_id}\nalgorithm=ed25519\nkey_id={nkid}\nfingerprint={nfp}\n"
            f"enabled=1\nnode_epoch={epoch}\ncreated_epoch={created}\nupdated_epoch={now}\nrevoked_epoch=0\nrevocation_reason=\n")
    atomic_write(conf_path, conf)
    with open(CTRL_PUB, "r", encoding="utf-8") as fh:
        cpub = fh.read()
    enrollment_id = "enroll-" + secrets.token_hex(12)
    bundle = {"contract": BUNDLE_CONTRACT, "version": VERSION, "controller_id": cid,
              "controller_fingerprint": cfp, "controller_public_key": cpub, "node_id": node_id,
              "node_key_id": nkid, "node_fingerprint": nfp, "node_epoch": epoch,
              "enrollment_id": enrollment_id, "issued_at": now,
              "metadata": req.get("metadata", {})}
    bundle["signature"] = sign(CTRL_KEY, canonical(bundle))
    write_external_new(out_path, json.dumps(bundle, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n")
    print(f"bundle_file={out_path}")
    print(f"controller_id={cid}")
    print(f"controller_fingerprint={cfp}")
    print(f"node_id={node_id}")
    print(f"node_epoch={epoch}")
    print(f"enrollment_id={enrollment_id}")


def node_accept(bundle_path, expected_fp):
    meta, local_fp, local_kid = init_node()
    if not FP_RE.fullmatch(expected_fp):
        die("Fingerprint esperado do controlador deve ser SHA256:<64 hex>.", 64)
    bundle = read_json(bundle_path)
    expected = {"contract", "version", "controller_id", "controller_fingerprint", "controller_public_key",
                "node_id", "node_key_id", "node_fingerprint", "node_epoch", "enrollment_id", "issued_at", "metadata", "signature"}
    if set(bundle) != expected or bundle.get("contract") != BUNDLE_CONTRACT or bundle.get("version") != VERSION:
        die("Enrollment bundle inválido.", 64)
    if bundle.get("node_id") != meta["node_id"] or bundle.get("node_fingerprint") != local_fp or bundle.get("node_key_id") != local_kid:
        die("Bundle foi emitido para outra identidade/generação de nó.", 67)
    if bundle.get("controller_fingerprint") != expected_fp:
        die("Fingerprint pinado do controlador não confere.", 67)
    pub_path = pem_to_temp(bundle.get("controller_public_key"))
    try:
        actual_fp = fingerprint(pub_path)
        actual_id = key_id("controller-", pub_path)
        if actual_fp != expected_fp or actual_id != bundle.get("controller_id"):
            die("Identidade pública do controlador não confere.", 67)
        if not verify(pub_path, canonical(bundle), bundle.get("signature", "")):
            die("Assinatura do enrollment bundle não confere.", 67)
        with open(pub_path, "rb") as fh:
            controller_pub = fh.read()
    finally:
        os.unlink(pub_path)
    epoch = bundle.get("node_epoch")
    if isinstance(epoch, bool) or not isinstance(epoch, int) or epoch < 1:
        die("node_epoch inválido no bundle.", 64)
    current = read_conf(NODE_ENROLLMENT)
    if current and current.get("controller_id") not in ("", bundle["controller_id"]):
        die("Nó já pertence a outro controlador; remoção/re-enrollment deve ser explícita.", 65)
    if current and int(current.get("node_epoch", "0")) > epoch:
        die("Bundle antigo recusado por fencing de node_epoch.", 67)
    atomic_write(NODE_CONTROLLER_PUB, controller_pub)
    atomic_write(NODE_CONTROLLER, f"version=1\ncontroller_id={bundle['controller_id']}\nfingerprint={expected_fp}\nalgorithm=ed25519\n")
    now = int(time.time())
    atomic_write(NODE_ENROLLMENT,
                 f"version=1\nnode_id={meta['node_id']}\ncontroller_id={bundle['controller_id']}\n"
                 f"controller_fingerprint={expected_fp}\nnode_epoch={epoch}\nenrollment_id={bundle['enrollment_id']}\n"
                 f"bundle_issued_epoch={bundle['issued_at']}\nenrolled_epoch={now}\n")
    print("enrolled=1")
    print(f"node_id={meta['node_id']}")
    print(f"controller_id={bundle['controller_id']}")
    print(f"node_epoch={epoch}")
    print(f"enrollment_id={bundle['enrollment_id']}")


def controller_list():
    init_controller()
    print("node_id|enabled|node_epoch|fingerprint|revoked_epoch")
    for path in sorted(Path(CONTROLLER_NODES).glob("*.conf")):
        c = read_conf(str(path))
        print("|".join(c.get(k, "") for k in ("node_id", "enabled", "node_epoch", "fingerprint", "revoked_epoch")))


def controller_show(node_id):
    if not NODE_ID_RE.fullmatch(node_id):
        die("node_id inválido.", 64)
    conf_path, _ = controller_node_paths(node_id)
    if not os.path.isfile(conf_path):
        die("Nó não registrado no controlador.", 66)
    with open(conf_path, "r", encoding="utf-8") as fh:
        sys.stdout.write(fh.read())


def controller_revoke(node_id, reason):
    init_controller()
    if not NODE_ID_RE.fullmatch(node_id):
        die("node_id inválido.", 64)
    if reason and (len(reason) > 80 or not SAFE_LABEL_RE.fullmatch(reason)):
        die("Motivo de revogação inválido; use label simples até 64 caracteres.", 64)
    conf_path, _ = controller_node_paths(node_id)
    c = read_conf(conf_path)
    if not c:
        die("Nó não registrado no controlador.", 66)
    if c.get("enabled") == "0" and c.get("revoked_epoch", "0") != "0":
        print("revoked=1")
        print(f"node_id={node_id}")
        print(f"node_epoch={c.get('node_epoch', '')}")
        return
    epoch = int(c.get("node_epoch", "1")) + 1
    now = int(time.time())
    text = (f"version=1\nnode_id={node_id}\nalgorithm=ed25519\nkey_id={c.get('key_id','')}\nfingerprint={c.get('fingerprint','')}\n"
            f"enabled=0\nnode_epoch={epoch}\ncreated_epoch={c.get('created_epoch', str(now))}\nupdated_epoch={now}\n"
            f"revoked_epoch={now}\nrevocation_reason={reason or 'admin-revoked'}\n")
    atomic_write(conf_path, text)
    print("revoked=1")
    print(f"node_id={node_id}")
    print(f"node_epoch={epoch}")


def usage():
    print("Uso: hive_identity.sh {--init|--status|--request OUT|--accept BUNDLE CONTROLLER_FP|--controller-init|--controller-status|--controller-fingerprint|--controller-list|--controller-show NODE|--controller-approve REQUEST OUT|--controller-reenroll REQUEST OUT|--controller-revoke NODE [REASON]}", file=sys.stderr)
    raise SystemExit(64)


def main(argv):
    cmd = argv[0] if argv else "--status"
    if cmd in {"--init", "--install"}:
        meta, fp, kid = init_node(); print(f"node_id={meta['node_id']}"); print(f"fingerprint={fp}"); print(f"key_id={kid}"); return
    if cmd == "--status": node_status(); return
    if cmd == "--request" and len(argv) == 2: make_request(argv[1]); return
    if cmd == "--accept" and len(argv) == 3: node_accept(argv[1], argv[2].lower().replace("sha256:", "SHA256:", 1)); return
    if cmd == "--controller-init": cid, fp = init_controller(); print(f"controller_id={cid}"); print(f"controller_fingerprint={fp}"); return
    if cmd == "--controller-status": controller_status(); return
    if cmd == "--controller-fingerprint":
        _, fp = init_controller(); print(fp); return
    if cmd == "--controller-list": controller_list(); return
    if cmd == "--controller-show" and len(argv) == 2: controller_show(argv[1]); return
    if cmd == "--controller-approve" and len(argv) == 3: controller_approve(argv[1], argv[2], False); return
    if cmd == "--controller-reenroll" and len(argv) == 3: controller_approve(argv[1], argv[2], True); return
    if cmd == "--controller-revoke" and len(argv) in {2, 3}: controller_revoke(argv[1], argv[2] if len(argv) == 3 else ""); return
    if cmd == "--detach": return
    usage()

main(sys.argv[1:])
PY
