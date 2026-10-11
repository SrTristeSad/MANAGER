#!/usr/bin/env python3
import argparse
import base64
import hashlib
import ipaddress
import json
import os
import re
import secrets
import signal
import socket
import ssl
import stat
import struct
import subprocess
import sys
import tempfile
import time
from pathlib import Path

MANAGER_HOME = os.environ.get("MANAGER_HOME", "/opt/manager")
MANAGER_ETC = os.environ.get("MANAGER_ETC", "/etc/manager")
STATE_DIR = os.path.join(MANAGER_ETC, "automation", "v2")
PRINCIPALS_DIR = os.path.join(STATE_DIR, "principals")
CREDENTIALS_DIR = os.path.join(STATE_DIR, "credentials")
REMOTE_CONF = os.path.join(STATE_DIR, "remote.conf")
REMOTE_TLS_DIR = os.path.join(STATE_DIR, "tls")
REMOTE_CERT = os.path.join(REMOTE_TLS_DIR, "server.crt")
REMOTE_KEY = os.path.join(REMOTE_TLS_DIR, "server.key")
DATA_DIR = "/var/lib/manager/automation-v2"
IDEMPOTENCY_DIR = os.path.join(DATA_DIR, "idempotency")
REPLAY_DIR = os.path.join(DATA_DIR, "replay")
AUDIT_FILE = "/var/log/manager/automation-v2-audit.jsonl"
SOCKET_FILE = "/run/manager-automation-v2/manager.sock"
CONNECTION_ACTIONS = os.path.join(MANAGER_HOME, "modules", "connection_actions.sh")
NODE_USAGE = os.path.join(MANAGER_HOME, "modules", "node_usage.sh")
RESELLERS_DIR = os.path.join(MANAGER_ETC, "access", "resellers")
IDENTITY_DIR = os.path.join(MANAGER_ETC, "connection", "identities")
CONTRACT = "manager-automation-v2-local-v1"
VERSION = 1
MAX_REQUEST = 65536
MAX_RESPONSE = 262144
IDEMPOTENCY_TTL = 7 * 24 * 60 * 60
AUTH_SKEW = 120
REPLAY_TTL = 10 * 60
LOCAL_ROOT_ID = "local-root"
REQUEST_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{7,127}$")
PRINCIPAL_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$")
KEY_ID_RE = re.compile(r"^ed25519-[a-f0-9]{16}$")
KEY_RE = re.compile(r"^[A-Za-z0-9_.-]{1,64}$")
NONCE_RE = re.compile(r"^[A-Za-z0-9_-]{32,80}$")
SENSITIVE_RE = re.compile(r"(?i)(password|passwd|secret|private[_-]?key|credential|token)")
ACTIONS = {
    "system.describe",
    "node.usage",
    "connection.preflight",
    "connection.create",
    "connection.status",
    "connection.revoke",
}
READ_ACTIONS = {"system.describe", "node.usage", "connection.status"}
RATE_READ_PER_MIN = 120.0
RATE_READ_BURST = 20.0
RATE_WRITE_PER_MIN = 30.0
RATE_WRITE_BURST = 8.0
RATE_BUCKETS = {}
LAST_REPLAY_PRUNE = 0.0


def line(obj):
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n"


def ensure_dir(path, mode=0o700):
    os.makedirs(path, mode=mode, exist_ok=True)
    os.chmod(path, mode)


def response_error(request_id, action_id, code, message, principal=None, principal_id=None, **extra):
    result = {
        "contract": CONTRACT,
        "version": VERSION,
        "request_id": request_id,
        "action_id": action_id,
        "ok": False,
        "code": int(code),
        "error": str(message)[:4096],
        "cached": False,
    }
    if principal is not None:
        result["principal_id"] = principal["principal_id"]
        result["principal_role"] = principal["role"]
    elif principal_id:
        result["principal_id"] = str(principal_id)[:128]
    result.update(extra)
    return result


def audit(request_id, action_id, uid, response, principal=None, decision="deny", reason="", cached=False,
          auth=None, transport="unix", replay="not-evaluated", rate="not-evaluated", issued_at=None):
    auth = auth or {}
    event = {
        "ts_epoch": int(time.time()),
        "request_id": request_id,
        "action_id": action_id,
        "transport": transport,
        "peer_uid": uid,
        "principal_id": principal["principal_id"] if principal else response.get("principal_id", ""),
        "principal_role": principal["role"] if principal else "",
        "principal_subject": principal["subject"] if principal else "",
        "auth_scheme": auth.get("scheme", ""),
        "auth_key_id": auth.get("key_id", ""),
        "auth_fingerprint": auth.get("fingerprint", ""),
        "auth_decision": auth.get("decision", "not-evaluated"),
        "freshness_decision": auth.get("freshness", "not-evaluated"),
        "replay_decision": replay,
        "rate_limit_decision": rate,
        "rbac_decision": decision,
        "rbac_reason": str(reason)[:256],
        "ok": bool(response.get("ok", False)),
        "code": int(response.get("code", 70)),
        "cached": bool(cached),
    }
    if isinstance(issued_at, int):
        event["request_issued_at"] = issued_at
    ensure_dir(os.path.dirname(AUDIT_FILE), 0o700)
    with open(AUDIT_FILE, "a", encoding="utf-8") as fh:
        fh.write(line(event))
    os.chmod(AUDIT_FILE, 0o600)


def parse_kv(text):
    data = {}
    for raw in text.splitlines():
        if "=" not in raw:
            continue
        key, value = raw.split("=", 1)
        if KEY_RE.fullmatch(key):
            data[key] = value
    return data


def read_conf(path, strict=False):
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        return None
    if not stat.S_ISREG(st.st_mode):
        raise RuntimeError("registro não é arquivo regular")
    if strict:
        if st.st_uid != 0:
            raise RuntimeError("registro protegido não pertence a root")
        if stat.S_IMODE(st.st_mode) & 0o077:
            raise RuntimeError("registro protegido possui permissões excessivas")
    data = {}
    with open(path, "r", encoding="utf-8") as fh:
        for raw in fh:
            raw = raw.rstrip("\n")
            if "=" not in raw:
                continue
            key, value = raw.split("=", 1)
            if KEY_RE.fullmatch(key):
                data[key] = value
    return data


def reseller_record(reseller_id):
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,47}", reseller_id or ""):
        return None
    return read_conf(os.path.join(RESELLERS_DIR, reseller_id + ".conf"))


def identity_record(identity_id):
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,47}", identity_id or ""):
        return None
    return read_conf(os.path.join(IDENTITY_DIR, identity_id + ".conf"))


def load_principal(principal_id):
    if not isinstance(principal_id, str) or not PRINCIPAL_RE.fullmatch(principal_id):
        raise PermissionError("principal_id inválido")
    data = read_conf(os.path.join(PRINCIPALS_DIR, principal_id + ".conf"), strict=True)
    if data is None:
        raise PermissionError("principal desconhecido")
    if data.get("principal_id") != principal_id:
        raise PermissionError("registro de principal inconsistente")
    if data.get("version") != "1" or data.get("enabled") != "1":
        raise PermissionError("principal desabilitado")
    role = data.get("role", "")
    subject = data.get("subject", "")
    products = data.get("products", "")
    if role == "admin":
        if subject != "*":
            raise PermissionError("principal admin inválido")
        products = "*"
    elif role in {"reseller", "subreseller"}:
        record = reseller_record(subject)
        if record is None or record.get("role") != role:
            raise PermissionError("subject de revenda inválido")
        if record.get("enabled") != "1":
            raise PermissionError("subject de revenda desabilitado")
        if not products or products == "-":
            raise PermissionError("escopo de produtos inválido")
    elif role == "user":
        if identity_record(subject) is None:
            raise PermissionError("identidade vinculada ao principal não existe")
        products = "-"
    else:
        raise PermissionError("role de principal inválida")
    return {"principal_id": principal_id, "role": role, "subject": subject, "products": products}


def canonical_auth_payload(request):
    payload = {
        "contract": CONTRACT,
        "version": request.get("version"),
        "request_id": request.get("request_id"),
        "principal_id": request.get("principal_id"),
        "action_id": request.get("action_id"),
        "params": request.get("params"),
        "issued_at": request.get("issued_at"),
        "nonce": request.get("nonce"),
    }
    return json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def load_credential(principal_id, key_id):
    if not isinstance(key_id, str) or not KEY_ID_RE.fullmatch(key_id):
        raise PermissionError("key_id inválido")
    base = os.path.join(CREDENTIALS_DIR, principal_id)
    meta_path = os.path.join(base, key_id + ".conf")
    pub_path = os.path.join(base, key_id + ".pub")
    meta = read_conf(meta_path, strict=True)
    if meta is None:
        raise PermissionError("credencial desconhecida")
    if meta.get("version") != "1" or meta.get("principal_id") != principal_id:
        raise PermissionError("metadados de credencial inconsistentes")
    if meta.get("key_id") != key_id or meta.get("algorithm") != "ed25519":
        raise PermissionError("metadados de credencial inválidos")
    if meta.get("enabled") != "1" or meta.get("revoked_epoch", "0") != "0":
        raise PermissionError("credencial revogada")
    try:
        st = os.lstat(pub_path)
    except FileNotFoundError as exc:
        raise PermissionError("chave pública ausente") from exc
    if not stat.S_ISREG(st.st_mode) or st.st_uid != 0 or stat.S_IMODE(st.st_mode) & 0o077:
        raise PermissionError("chave pública insegura")
    proc = subprocess.run(
        ["openssl", "pkey", "-pubin", "-in", pub_path, "-outform", "DER"],
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10, check=False,
    )
    if proc.returncode != 0 or not proc.stdout:
        raise PermissionError("chave pública inválida")
    digest = hashlib.sha256(proc.stdout).digest()
    expected_key_id = "ed25519-" + digest.hex()[:16]
    fingerprint = "SHA256:" + base64.b64encode(digest).decode("ascii").rstrip("=")
    if expected_key_id != key_id or meta.get("fingerprint") != fingerprint:
        raise PermissionError("fingerprint da credencial não confere")
    return pub_path, fingerprint


def verify_signature(request, principal):
    principal_id = principal["principal_id"]
    if principal_id == LOCAL_ROOT_ID:
        if request.get("auth") not in (None, {}):
            raise PermissionError("local-root não aceita credencial externa")
        return {"scheme": "peercred", "key_id": "", "fingerprint": "", "decision": "allow", "freshness": "peercred"}
    issued_at = request.get("issued_at")
    nonce = request.get("nonce")
    now = int(time.time())
    if isinstance(issued_at, bool) or not isinstance(issued_at, int):
        raise PermissionError("issued_at obrigatório")
    if abs(now - issued_at) > AUTH_SKEW:
        raise PermissionError("timestamp fora da janela aceita")
    if not isinstance(nonce, str) or not NONCE_RE.fullmatch(nonce):
        raise PermissionError("nonce inválido")
    auth = request.get("auth")
    if not isinstance(auth, dict) or set(auth) != {"scheme", "key_id", "signature"}:
        raise PermissionError("assinatura obrigatória")
    if auth.get("scheme") != "ed25519-v2":
        raise PermissionError("esquema de assinatura não suportado")
    key_id = auth.get("key_id")
    signature_text = auth.get("signature")
    if not isinstance(signature_text, str) or len(signature_text) > 512:
        raise PermissionError("assinatura inválida")
    try:
        signature = base64.b64decode(signature_text.encode("ascii"), validate=True)
    except Exception as exc:
        raise PermissionError("assinatura inválida") from exc
    if len(signature) != 64:
        raise PermissionError("assinatura inválida")
    pub_path, fingerprint = load_credential(principal_id, key_id)
    signed = canonical_auth_payload(request)
    data_fd, data_path = tempfile.mkstemp(prefix="manager-auth-data-")
    sig_fd, sig_path = tempfile.mkstemp(prefix="manager-auth-sig-")
    try:
        os.fchmod(data_fd, 0o600)
        os.fchmod(sig_fd, 0o600)
        with os.fdopen(data_fd, "wb") as fh:
            fh.write(signed)
        with os.fdopen(sig_fd, "wb") as fh:
            fh.write(signature)
        proc = subprocess.run(
            ["openssl", "pkeyutl", "-verify", "-pubin", "-inkey", pub_path, "-rawin", "-in", data_path, "-sigfile", sig_path],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10, check=False,
        )
    finally:
        for path in (data_path, sig_path):
            try:
                os.unlink(path)
            except FileNotFoundError:
                pass
    if proc.returncode != 0:
        raise PermissionError("assinatura não confere")
    return {"scheme": "ed25519-v2", "key_id": key_id, "fingerprint": fingerprint, "decision": "allow", "freshness": "allow"}


def replay_path(principal_id, key_id, nonce):
    nonce_hash = hashlib.sha256(nonce.encode("ascii")).hexdigest()
    return os.path.join(REPLAY_DIR, principal_id, key_id, nonce_hash)


def prune_replay(force=False):
    global LAST_REPLAY_PRUNE
    now = time.time()
    if not force and now - LAST_REPLAY_PRUNE < 60:
        return
    LAST_REPLAY_PRUNE = now
    cutoff = now - REPLAY_TTL
    root = Path(REPLAY_DIR)
    if not root.exists():
        return
    for path in root.rglob("*"):
        try:
            if path.is_file() and not path.is_symlink() and path.stat().st_mtime < cutoff:
                path.unlink()
        except OSError:
            pass
    for path in sorted(root.rglob("*"), key=lambda p: len(p.parts), reverse=True):
        try:
            if path.is_dir() and not any(path.iterdir()):
                path.rmdir()
        except OSError:
            pass


def consume_nonce(principal_id, key_id, nonce, issued_at):
    ensure_dir(REPLAY_DIR, 0o700)
    ensure_dir(os.path.join(REPLAY_DIR, principal_id), 0o700)
    base = os.path.join(REPLAY_DIR, principal_id, key_id)
    ensure_dir(base, 0o700)
    path = replay_path(principal_id, key_id, nonce)
    try:
        fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    except FileExistsError as exc:
        raise PermissionError("replay detectado") from exc
    try:
        os.write(fd, f"issued_at={issued_at}\nseen_at={int(time.time())}\n".encode("ascii"))
        os.fsync(fd)
    finally:
        os.close(fd)
    prune_replay()


def rate_limit(principal_id, action_id):
    if principal_id == LOCAL_ROOT_ID:
        return True, 0
    now = time.monotonic()
    if action_id in READ_ACTIONS:
        per_min, burst = RATE_READ_PER_MIN, RATE_READ_BURST
    else:
        per_min, burst = RATE_WRITE_PER_MIN, RATE_WRITE_BURST
    key = (principal_id, action_id)
    tokens, last = RATE_BUCKETS.get(key, (burst, now))
    rate = per_min / 60.0
    tokens = min(burst, tokens + max(0.0, now - last) * rate)
    if tokens < 1.0:
        retry_after = max(1, int((1.0 - tokens) / rate + 0.999))
        RATE_BUCKETS[key] = (tokens, now)
        return False, retry_after
    RATE_BUCKETS[key] = (tokens - 1.0, now)
    return True, 0


def product_allowed(principal, plan):
    if principal["role"] == "admin":
        return True
    if principal["role"] not in {"reseller", "subreseller"}:
        return False
    scope = principal["products"]
    if scope == "*":
        return True
    return plan in {item for item in scope.split(",") if item}


def owner_allowed(principal, owner):
    role = principal["role"]
    subject = principal["subject"]
    if role == "admin":
        return True
    if role == "subreseller":
        return owner == subject
    if role == "reseller":
        if owner == subject:
            return True
        record = reseller_record(owner)
        return bool(record and record.get("role") == "subreseller" and record.get("parent") == subject)
    return False


def identity_allowed(principal, identity_id):
    role = principal["role"]
    if role == "admin":
        return True
    if role == "user":
        return identity_id == principal["subject"]
    record = identity_record(identity_id)
    if record is None:
        return False
    return owner_allowed(principal, record.get("owner", ""))


def authorize(principal, action_id, params):
    role = principal["role"]
    normalized = dict(params)
    if action_id == "system.describe":
        return True, normalized, "system-describe"
    if action_id == "node.usage":
        return role == "admin", normalized, "node-usage-admin-only"
    if action_id in {"connection.preflight", "connection.create"}:
        if role not in {"admin", "reseller", "subreseller"}:
            return False, normalized, "role-cannot-create"
        plan = normalized.get("plan", "")
        if isinstance(plan, str) and plan and not product_allowed(principal, plan):
            return False, normalized, "product-out-of-scope"
        if role in {"reseller", "subreseller"}:
            owner = normalized.get("owner", "")
            if not isinstance(owner, str):
                return True, normalized, "parameter-validation-pending"
            if not owner:
                owner = principal["subject"]
                normalized["owner"] = owner
            if not owner_allowed(principal, owner):
                return False, normalized, "owner-out-of-scope"
        return True, normalized, "create-scope-allowed"
    if action_id == "connection.status":
        identity_id = normalized.get("id", "")
        if not isinstance(identity_id, str) or not identity_id:
            return True, normalized, "parameter-validation-pending"
        return identity_allowed(principal, identity_id), normalized, "identity-scope"
    if action_id == "connection.revoke":
        if role == "user":
            return False, normalized, "user-cannot-revoke"
        identity_id = normalized.get("id", "")
        if not isinstance(identity_id, str) or not identity_id:
            return True, normalized, "parameter-validation-pending"
        return identity_allowed(principal, identity_id), normalized, "identity-scope"
    return False, normalized, "action-not-authorized"


def string_param(params, key, required=True):
    value = params.get(key, "")
    if value is None:
        value = ""
    if not isinstance(value, str):
        raise ValueError(f"{key} deve ser string")
    if required and not value:
        raise ValueError(f"campo obrigatório ausente: {key}")
    if len(value) > 512:
        raise ValueError(f"{key} excede o limite")
    return value


def command_for(action_id, params):
    if not isinstance(params, dict):
        raise ValueError("params deve ser objeto")
    if action_id == "system.describe":
        if params:
            raise ValueError("system.describe não aceita parâmetros")
        return [CONNECTION_ACTIONS, "--describe"]
    if action_id == "node.usage":
        if params:
            raise ValueError("node.usage não aceita parâmetros")
        return [NODE_USAGE, "--show"]
    if action_id in {"connection.status", "connection.revoke"}:
        if set(params) != {"id"}:
            raise ValueError("parâmetro não permitido")
        ident = string_param(params, "id")
        flag = "--status" if action_id.endswith("status") else "--revoke"
        return [CONNECTION_ACTIONS, flag, ident]
    if action_id in {"connection.preflight", "connection.create"}:
        allowed = {"id", "plan", "owner", "protocols"}
        if set(params) - allowed:
            raise ValueError("parâmetro não permitido")
        ident = string_param(params, "id")
        plan = string_param(params, "plan")
        owner = string_param(params, "owner", required=False)
        protocols = string_param(params, "protocols", required=False)
        flag = "--preflight" if action_id.endswith("preflight") else "--create"
        return [CONNECTION_ACTIONS, flag, ident, plan, owner, protocols]
    raise ValueError("ação não permitida")


def request_hash(principal_id, action_id, params):
    raw = json.dumps(
        {"version": VERSION, "principal_id": principal_id, "action_id": action_id, "params": params},
        sort_keys=True, separators=(",", ":"), ensure_ascii=False,
    ).encode("utf-8")
    return hashlib.sha256(raw).hexdigest()


def cache_path(request_id):
    return os.path.join(IDEMPOTENCY_DIR, request_id + ".json")


def sanitize_stdout(text):
    kept = []
    for raw in text.splitlines():
        if "=" in raw:
            key = raw.split("=", 1)[0]
            if SENSITIVE_RE.search(key):
                continue
        kept.append(raw)
    if not kept:
        return ""
    return "\n".join(kept) + ("\n" if text.endswith("\n") else "")


def cacheable_response(response):
    safe = json.loads(json.dumps(response))
    redacted = False
    result = safe.get("result")
    if isinstance(result, dict):
        data = result.get("data")
        if isinstance(data, dict):
            for key in list(data):
                if SENSITIVE_RE.search(key):
                    data.pop(key, None)
                    redacted = True
        stdout = result.get("stdout")
        if isinstance(stdout, str):
            sanitized = sanitize_stdout(stdout)
            if sanitized != stdout:
                redacted = True
                result["stdout"] = sanitized
    if redacted:
        safe["secret_replay_available"] = False
        safe["secret_returned_once"] = True
    return safe


def load_cache(request_id, req_hash):
    path = cache_path(request_id)
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        return None
    if not stat.S_ISREG(st.st_mode) or st.st_uid != 0:
        raise RuntimeError("entrada de idempotência inválida")
    with open(path, "r", encoding="utf-8") as fh:
        saved = json.load(fh)
    if saved.get("request_hash") != req_hash:
        return "conflict"
    saved_response = saved.get("response")
    if not isinstance(saved_response, dict):
        raise RuntimeError("cache de idempotência corrompido")
    cached = dict(saved_response)
    cached["cached"] = True
    return cached


def save_cache(request_id, req_hash, response):
    ensure_dir(IDEMPOTENCY_DIR, 0o700)
    fd, tmp = tempfile.mkstemp(prefix=".idem-", dir=IDEMPOTENCY_DIR, text=True)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump({"request_hash": req_hash, "response": cacheable_response(response)}, fh,
                      sort_keys=True, separators=(",", ":"), ensure_ascii=False)
            fh.write("\n")
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, cache_path(request_id))
    finally:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass


def prune_cache():
    cutoff = time.time() - IDEMPOTENCY_TTL
    try:
        names = os.listdir(IDEMPOTENCY_DIR)
    except FileNotFoundError:
        return
    for name in names:
        if not name.endswith(".json"):
            continue
        path = os.path.join(IDEMPOTENCY_DIR, name)
        try:
            st = os.lstat(path)
            if stat.S_ISREG(st.st_mode) and st.st_mtime < cutoff:
                os.unlink(path)
        except (FileNotFoundError, OSError):
            pass


def execute(request, uid):
    request_id = request.get("request_id", "")
    action_id = request.get("action_id", "")
    principal_id = request.get("principal_id", LOCAL_ROOT_ID)
    params = request.get("params", {})
    transport = request.get("_transport", "unix")
    if transport not in {"unix", "remote-tls-v1"}:
        transport = "unix"
    allowed_keys = {"version", "request_id", "principal_id", "action_id", "params", "auth", "issued_at", "nonce", "_transport"}
    if set(request) - allowed_keys:
        return response_error(str(request_id), str(action_id), 64, "campo de envelope não permitido", principal_id=principal_id)
    if request.get("version") != VERSION:
        return response_error(str(request_id), str(action_id), 64, "versão de envelope não suportada", principal_id=principal_id)
    if not isinstance(request_id, str) or not REQUEST_RE.fullmatch(request_id):
        return response_error(str(request_id), str(action_id), 64, "request_id inválido", principal_id=principal_id)
    if not isinstance(action_id, str) or action_id not in ACTIONS:
        return response_error(request_id, str(action_id), 64, "action_id não permitido", principal_id=principal_id)
    if uid != 0:
        result = response_error(request_id, action_id, 67, "peer não autorizado", principal_id=principal_id)
        audit(request_id, action_id, uid, result, decision="not-evaluated", reason="peer-uid", transport=transport)
        return result
    if not isinstance(params, dict):
        return response_error(request_id, action_id, 64, "params deve ser objeto", principal_id=principal_id)
    if transport == "remote-tls-v1" and principal_id == LOCAL_ROOT_ID:
        result = response_error(request_id, action_id, 67, "local-root não é permitido no transporte remoto", principal_id=principal_id)
        audit(request_id, action_id, uid, result, decision="not-evaluated", reason="remote-local-root", transport=transport)
        return result
    try:
        principal = load_principal(principal_id)
    except (PermissionError, RuntimeError) as exc:
        result = response_error(request_id, action_id, 67, str(exc), principal_id=principal_id)
        audit(request_id, action_id, uid, result, decision="not-evaluated", reason="principal-invalid", transport=transport)
        return result
    try:
        auth_meta = verify_signature(request, principal)
    except (PermissionError, RuntimeError, subprocess.SubprocessError) as exc:
        auth_meta = {
            "scheme": "ed25519-v2" if principal_id != LOCAL_ROOT_ID else "peercred",
            "key_id": request.get("auth", {}).get("key_id", "") if isinstance(request.get("auth"), dict) else "",
            "fingerprint": "", "decision": "deny", "freshness": "deny",
        }
        result = response_error(request_id, action_id, 67, "autenticação criptográfica inválida", principal=principal)
        audit(request_id, action_id, uid, result, principal=principal, decision="not-evaluated", reason=str(exc),
              auth=auth_meta, transport=transport, issued_at=request.get("issued_at"))
        return result
    rate_ok, retry_after = rate_limit(principal_id, action_id)
    if not rate_ok:
        result = response_error(request_id, action_id, 75, "limite temporário de requisições excedido", principal=principal,
                                retry_after_seconds=retry_after)
        audit(request_id, action_id, uid, result, principal=principal, decision="not-evaluated", reason="rate-limit",
              auth=auth_meta, transport=transport, rate="deny", issued_at=request.get("issued_at"))
        return result
    replay_decision = "peercred"
    if principal_id != LOCAL_ROOT_ID:
        try:
            consume_nonce(principal_id, auth_meta["key_id"], request["nonce"], request["issued_at"])
            replay_decision = "allow"
        except PermissionError as exc:
            result = response_error(request_id, action_id, 67, "replay de requisição detectado", principal=principal)
            audit(request_id, action_id, uid, result, principal=principal, decision="not-evaluated", reason=str(exc),
                  auth=auth_meta, transport=transport, replay="deny", rate="allow", issued_at=request.get("issued_at"))
            return result
    allowed, params, rbac_reason = authorize(principal, action_id, params)
    if not allowed:
        result = response_error(request_id, action_id, 67, "ação fora do escopo RBAC", principal=principal)
        audit(request_id, action_id, uid, result, principal=principal, decision="deny", reason=rbac_reason,
              auth=auth_meta, transport=transport, replay=replay_decision, rate="allow", issued_at=request.get("issued_at"))
        return result
    req_hash = request_hash(principal["principal_id"], action_id, params)
    cached = load_cache(request_id, req_hash)
    if cached == "conflict":
        result = response_error(request_id, action_id, 65, "request_id reutilizado com payload/principal diferente", principal=principal)
        audit(request_id, action_id, uid, result, principal=principal, decision="allow", reason=rbac_reason,
              auth=auth_meta, transport=transport, replay=replay_decision, rate="allow", issued_at=request.get("issued_at"))
        return result
    if isinstance(cached, dict):
        audit(request_id, action_id, uid, cached, principal=principal, decision="allow", reason=rbac_reason, cached=True,
              auth=auth_meta, transport=transport, replay=replay_decision, rate="allow", issued_at=request.get("issued_at"))
        return cached
    try:
        cmd = command_for(action_id, params)
    except ValueError as exc:
        result = response_error(request_id, action_id, 64, str(exc), principal=principal)
        save_cache(request_id, req_hash, result)
        audit(request_id, action_id, uid, result, principal=principal, decision="allow", reason=rbac_reason,
              auth=auth_meta, transport=transport, replay=replay_decision, rate="allow", issued_at=request.get("issued_at"))
        return result
    env = os.environ.copy()
    env["LC_ALL"] = "C.UTF-8"
    try:
        proc = subprocess.run(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              text=True, timeout=180, shell=False, env=env)
        result = {
            "contract": CONTRACT, "version": VERSION, "request_id": request_id, "action_id": action_id,
            "principal_id": principal["principal_id"], "principal_role": principal["role"],
            "ok": proc.returncode == 0, "code": int(proc.returncode),
            "result": {"data": parse_kv(proc.stdout), "stdout": proc.stdout[:65536]}, "cached": False,
        }
        if proc.stderr:
            result["stderr"] = proc.stderr[:8192]
    except subprocess.TimeoutExpired:
        result = response_error(request_id, action_id, 70, "tempo limite da operação excedido", principal=principal)
    save_cache(request_id, req_hash, result)
    audit(request_id, action_id, uid, result, principal=principal, decision="allow", reason=rbac_reason,
          auth=auth_meta, transport=transport, replay=replay_decision, rate="allow", issued_at=request.get("issued_at"))
    return result


def peer_uid(conn):
    raw = conn.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i"))
    _pid, uid, _gid = struct.unpack("3i", raw)
    return uid


def read_line_socket(conn, limit):
    chunks = []
    total = 0
    while True:
        data = conn.recv(4096)
        if not data:
            break
        total += len(data)
        if total > limit:
            raise ValueError("requisição excede limite")
        chunks.append(data)
        if b"\n" in data:
            break
    raw = b"".join(chunks).split(b"\n", 1)[0]
    if not raw:
        raise ValueError("requisição vazia")
    return raw


def parse_request(raw):
    request = json.loads(raw.decode("utf-8"))
    if not isinstance(request, dict):
        raise ValueError("envelope deve ser objeto JSON")
    return request


def serve_local():
    ensure_dir(os.path.dirname(SOCKET_FILE), 0o700)
    ensure_dir(IDEMPOTENCY_DIR, 0o700)
    ensure_dir(REPLAY_DIR, 0o700)
    ensure_dir(os.path.dirname(AUDIT_FILE), 0o700)
    Path(AUDIT_FILE).touch(exist_ok=True)
    os.chmod(AUDIT_FILE, 0o600)
    prune_cache()
    prune_replay(force=True)
    if os.path.lexists(SOCKET_FILE):
        st = os.lstat(SOCKET_FILE)
        if not stat.S_ISSOCK(st.st_mode):
            raise SystemExit("socket path ocupado por objeto que não é socket")
        os.unlink(SOCKET_FILE)
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(SOCKET_FILE)
    os.chmod(SOCKET_FILE, 0o600)
    server.listen(32)

    def cleanup(*_args):
        try:
            server.close()
        except OSError:
            pass
        try:
            os.unlink(SOCKET_FILE)
        except FileNotFoundError:
            pass
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, cleanup)
    signal.signal(signal.SIGINT, cleanup)
    while True:
        conn, _ = server.accept()
        with conn:
            conn.settimeout(190)
            try:
                raw = read_line_socket(conn, MAX_REQUEST)
                request = parse_request(raw)
                request.setdefault("_transport", "unix")
                result = execute(request, peer_uid(conn))
            except Exception as exc:
                result = response_error("unknown", "unknown", 64, str(exc))
            conn.sendall(line(result).encode("utf-8"))


def read_remote_config():
    data = read_conf(REMOTE_CONF, strict=True)
    if not data or data.get("enabled") != "1":
        raise RuntimeError("transporte remoto não está habilitado")
    bind = data.get("bind", "")
    try:
        ipaddress.ip_address(bind)
    except ValueError as exc:
        raise RuntimeError("bind remoto inválido") from exc
    try:
        port = int(data.get("port", "0"))
    except ValueError as exc:
        raise RuntimeError("porta remota inválida") from exc
    if not 1024 <= port <= 65535:
        raise RuntimeError("porta remota deve estar entre 1024 e 65535")
    return bind, port


def source_rate_limit(buckets, source):
    now = time.monotonic()
    rate = 120.0 / 60.0
    burst = 30.0
    tokens, last = buckets.get(source, (burst, now))
    tokens = min(burst, tokens + max(0.0, now - last) * rate)
    if tokens < 1.0:
        buckets[source] = (tokens, now)
        return False
    buckets[source] = (tokens - 1.0, now)
    return True


def serve_remote():
    bind, port = read_remote_config()
    for path in (REMOTE_CERT, REMOTE_KEY):
        st = os.lstat(path)
        if not stat.S_ISREG(st.st_mode) or st.st_uid != 0 or stat.S_IMODE(st.st_mode) & 0o077:
            raise SystemExit(f"material TLS inseguro: {path}")
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_3
    context.maximum_version = ssl.TLSVersion.TLSv1_3
    context.load_cert_chain(REMOTE_CERT, REMOTE_KEY)
    family = socket.AF_INET6 if ":" in bind else socket.AF_INET
    server = socket.socket(family, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((bind, port))
    server.listen(32)
    buckets = {}

    def cleanup(*_args):
        try:
            server.close()
        except OSError:
            pass
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, cleanup)
    signal.signal(signal.SIGINT, cleanup)
    while True:
        raw_conn, addr = server.accept()
        source = str(addr[0]) if isinstance(addr, tuple) and addr else "unknown"
        with raw_conn:
            raw_conn.settimeout(8)
            if not source_rate_limit(buckets, source):
                continue
            try:
                with context.wrap_socket(raw_conn, server_side=True) as tls_conn:
                    raw = read_line_socket(tls_conn, MAX_REQUEST)
                    request = parse_request(raw)
                    request["_transport"] = "remote-tls-v1"
                    forwarded = (json.dumps(request, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n").encode("utf-8")
                    local = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                    local.settimeout(190)
                    try:
                        local.connect(SOCKET_FILE)
                        local.sendall(forwarded)
                        response = read_line_socket(local, MAX_RESPONSE)
                    finally:
                        local.close()
                    tls_conn.sendall(response + b"\n")
            except (ssl.SSLError, ValueError, OSError, json.JSONDecodeError):
                continue


def load_client_credential(path):
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        raise ValueError(f"credencial não encontrada: {path}")
    if not stat.S_ISREG(st.st_mode) or stat.S_IMODE(st.st_mode) & 0o077:
        raise PermissionError("arquivo de credencial deve ser regular e sem permissões para group/other")
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except Exception as exc:
        raise ValueError("arquivo de credencial inválido") from exc
    required = {"version", "principal_id", "key_id", "algorithm", "fingerprint", "private_key_pem"}
    if set(data) != required or data.get("version") != 1 or data.get("algorithm") != "ed25519":
        raise ValueError("formato de credencial não suportado")
    if not PRINCIPAL_RE.fullmatch(data.get("principal_id", "")):
        raise ValueError("principal da credencial inválido")
    if not KEY_ID_RE.fullmatch(data.get("key_id", "")):
        raise ValueError("key_id da credencial inválido")
    if not isinstance(data.get("private_key_pem"), str) or "BEGIN PRIVATE KEY" not in data["private_key_pem"]:
        raise ValueError("chave privada da credencial inválida")
    return data


def sign_request(request, credential):
    signed = canonical_auth_payload(request)
    key_fd, key_path = tempfile.mkstemp(prefix="manager-credential-key-")
    data_fd, data_path = tempfile.mkstemp(prefix="manager-credential-data-")
    sig_fd, sig_path = tempfile.mkstemp(prefix="manager-credential-sig-")
    os.close(sig_fd)
    try:
        os.fchmod(key_fd, 0o600)
        os.fchmod(data_fd, 0o600)
        with os.fdopen(key_fd, "w", encoding="utf-8") as fh:
            fh.write(credential["private_key_pem"])
        with os.fdopen(data_fd, "wb") as fh:
            fh.write(signed)
        proc = subprocess.run(
            ["openssl", "pkeyutl", "-sign", "-inkey", key_path, "-rawin", "-in", data_path, "-out", sig_path],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=10, check=False,
        )
        if proc.returncode != 0:
            raise RuntimeError("falha ao assinar requisição com a credencial")
        with open(sig_path, "rb") as fh:
            signature = fh.read()
    finally:
        for path in (key_path, data_path, sig_path):
            try:
                os.unlink(path)
            except FileNotFoundError:
                pass
    if len(signature) != 64:
        raise RuntimeError("assinatura Ed25519 com tamanho inesperado")
    request["auth"] = {
        "scheme": "ed25519-v2",
        "key_id": credential["key_id"],
        "signature": base64.b64encode(signature).decode("ascii"),
    }


def parse_remote_endpoint(value):
    if value.startswith("["):
        end = value.find("]")
        if end < 0 or end + 2 > len(value) or value[end + 1] != ":":
            raise ValueError("endpoint remoto IPv6 inválido; use [IP]:PORT")
        host = value[1:end]
        port_text = value[end + 2:]
    else:
        if value.count(":") != 1:
            raise ValueError("endpoint remoto inválido; use IP:PORT")
        host, port_text = value.rsplit(":", 1)
    try:
        ipaddress.ip_address(host)
        port = int(port_text)
    except ValueError as exc:
        raise ValueError("endpoint remoto inválido") from exc
    if not 1024 <= port <= 65535:
        raise ValueError("porta remota deve estar entre 1024 e 65535")
    return host, port


def normalize_server_fingerprint(value):
    if not isinstance(value, str):
        raise ValueError("fingerprint TLS ausente")
    value = value.strip()
    if not re.fullmatch(r"SHA256:[a-fA-F0-9]{64}", value):
        raise ValueError("fingerprint TLS inválido; esperado SHA256:<64 hex>")
    return "SHA256:" + value.split(":", 1)[1].lower()


def send_local(raw):
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(190)
    try:
        client.connect(SOCKET_FILE)
        client.sendall(raw)
        return read_line_socket(client, MAX_RESPONSE)
    finally:
        client.close()


def send_remote(raw, endpoint, expected_fp):
    host, port = parse_remote_endpoint(endpoint)
    expected_fp = normalize_server_fingerprint(expected_fp)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.minimum_version = ssl.TLSVersion.TLSv1_3
    context.maximum_version = ssl.TLSVersion.TLSv1_3
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    family = socket.AF_INET6 if ":" in host else socket.AF_INET
    raw_sock = socket.socket(family, socket.SOCK_STREAM)
    raw_sock.settimeout(190)
    try:
        raw_sock.connect((host, port))
        with context.wrap_socket(raw_sock, server_hostname=None) as tls_sock:
            cert_der = tls_sock.getpeercert(binary_form=True)
            actual = "SHA256:" + hashlib.sha256(cert_der).hexdigest()
            if actual != expected_fp:
                raise PermissionError("fingerprint TLS do servidor não confere")
            tls_sock.sendall(raw)
            return read_line_socket(tls_sock, MAX_RESPONSE)
    except Exception:
        try:
            raw_sock.close()
        except OSError:
            pass
        raise


def call_client(argv):
    principal_id = None
    credential_file = None
    remote = None
    server_fingerprint = None
    args = list(argv)
    while args:
        item = args[0]
        if item == "--principal":
            if len(args) < 2:
                raise ValueError("--principal exige ID")
            principal_id, args = args[1], args[2:]
            continue
        if item.startswith("--principal="):
            principal_id, args = item.split("=", 1)[1], args[1:]
            continue
        if item == "--credential":
            if len(args) < 2:
                raise ValueError("--credential exige FILE")
            credential_file, args = args[1], args[2:]
            continue
        if item.startswith("--credential="):
            credential_file, args = item.split("=", 1)[1], args[1:]
            continue
        if item == "--remote":
            if len(args) < 2:
                raise ValueError("--remote exige IP:PORT")
            remote, args = args[1], args[2:]
            continue
        if item.startswith("--remote="):
            remote, args = item.split("=", 1)[1], args[1:]
            continue
        if item == "--server-fingerprint":
            if len(args) < 2:
                raise ValueError("--server-fingerprint exige SHA256:<hex>")
            server_fingerprint, args = args[1], args[2:]
            continue
        if item.startswith("--server-fingerprint="):
            server_fingerprint, args = item.split("=", 1)[1], args[1:]
            continue
        break
    credential = load_client_credential(credential_file) if credential_file else None
    if credential:
        if principal_id is not None and principal_id != credential["principal_id"]:
            raise ValueError("--principal não corresponde ao principal da credencial")
        principal_id = credential["principal_id"]
    if principal_id is None:
        principal_id = LOCAL_ROOT_ID
    if not PRINCIPAL_RE.fullmatch(principal_id):
        raise ValueError("principal_id inválido")
    if principal_id == LOCAL_ROOT_ID and credential is not None:
        raise ValueError("local-root usa SO_PEERCRED e não aceita --credential")
    if remote and principal_id == LOCAL_ROOT_ID:
        raise PermissionError("transporte remoto exige --credential de principal não-local")
    if remote and credential is None:
        raise PermissionError("transporte remoto exige --credential")
    if remote and not server_fingerprint:
        raise ValueError("transporte remoto exige --server-fingerprint")
    if not args:
        raise ValueError("ACTION ausente")
    action = "system.describe" if args[0] == "describe" else args[0]
    request_id = None
    params = {}
    i = 1
    while i < len(args):
        item = args[i]
        if item == "--request-id":
            if i + 1 >= len(args):
                raise ValueError("--request-id exige valor")
            request_id = args[i + 1]
            i += 2
            continue
        if "=" not in item:
            raise ValueError(f"argumento inválido: {item}")
        key, value = item.split("=", 1)
        if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_.-]{0,63}", key):
            raise ValueError(f"chave inválida: {key}")
        params[key] = value
        i += 1
    request = {
        "version": VERSION,
        "request_id": request_id or secrets.token_hex(16),
        "principal_id": principal_id,
        "action_id": action,
        "params": params,
    }
    if credential is not None:
        request["issued_at"] = int(time.time())
        request["nonce"] = secrets.token_urlsafe(24)
        sign_request(request, credential)
    raw = (json.dumps(request, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n").encode("utf-8")
    payload = send_remote(raw, remote, server_fingerprint) if remote else send_local(raw)
    if not payload:
        raise RuntimeError("resposta vazia do managerd")
    result = json.loads(payload.decode("utf-8"))
    print(json.dumps(result, sort_keys=True, ensure_ascii=False))
    code = result.get("code", 70)
    return code if isinstance(code, int) and 0 <= code <= 255 else 70


def main():
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("mode", choices=["serve-local", "serve-remote", "call"])
    parser.add_argument("args", nargs=argparse.REMAINDER)
    ns = parser.parse_args()
    if ns.mode == "serve-local":
        serve_local()
        return 0
    if ns.mode == "serve-remote":
        serve_remote()
        return 0
    try:
        return call_client(ns.args)
    except PermissionError as exc:
        print(str(exc), file=sys.stderr)
        return 67
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 64
    except (OSError, ssl.SSLError, RuntimeError, json.JSONDecodeError) as exc:
        print(str(exc), file=sys.stderr)
        return 70


if __name__ == "__main__":
    raise SystemExit(main())
