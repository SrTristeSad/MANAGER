#!/usr/bin/env python3
from pathlib import Path


def replace_once(path, old, new, label):
    p = Path(path)
    s = p.read_text()
    count = s.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected 1 anchor, found {count}")
    p.write_text(s.replace(old, new, 1))


# ---------------------------------------------------------------------------
# Hive allocation v2: public login bootstrap + direct one-shot node claim.
# ---------------------------------------------------------------------------
p = Path("modules/hive_allocations.sh")
s = p.read_text()

old = """import base64
import fcntl
import json
import os
import re
import secrets
"""
new = """import base64
import fcntl
import hashlib
import hmac
import ipaddress
import json
import os
import re
import secrets
"""
if s.count(old) != 1:
    raise SystemExit("hive imports anchor mismatch")
s = s.replace(old, new, 1)

old = '''CTRL_OUTBOX_DIR = os.path.join(DATA_DIR, "controller", "outbox")
NODE_ACTIVE_DIR = os.path.join(DATA_DIR, "node", "active")
NODE_STATE_DIR = os.path.join(DATA_DIR, "node", "state")
NODE_EPOCH_DIR = os.path.join(DATA_DIR, "node", "epochs")
NODE_PROVISION_DIR = os.path.join(DATA_DIR, "node", "provisioned")
LOCK_FILE = os.path.join(DATA_DIR, ".lock")
AUDIT_FILE = os.environ.get("MANAGER_HIVE_ALLOCATION_AUDIT_FILE", "/var/log/manager/hive-allocation-audit.jsonl")
LEASE_MODULE = os.path.join(MANAGER_HOME, "modules", "hive_leases.sh")
PROVISION_MODULE = os.path.join(MANAGER_HOME, "modules", "provision.sh")
SYSTEMD_DIR = os.environ.get("MANAGER_HIVE_ALLOCATION_SYSTEMD_DIR", "/etc/systemd/system")
'''
new = '''CTRL_OUTBOX_DIR = os.path.join(DATA_DIR, "controller", "outbox")
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
'''
if s.count(old) != 1:
    raise SystemExit("hive dirs anchor mismatch")
s = s.replace(old, new, 1)

old = '''CONTRACT = "manager-hive-vpn-allocation-v1"
STATUS_CONTRACT = "manager-hive-vpn-allocation-status-v1"
VERSION = 1
DEFAULT_TTL = 60
PENDING_TTL = 15
MAX_JSON = 65536
IDENTITY_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,47}$")
NODE_ID_RE = re.compile(r"^node-[a-f0-9]{16}$")
ID_RE = re.compile(r"^[a-f0-9]{32}$")
TOKEN_RE = re.compile(r"^[a-f0-9]{32,64}$")
LABEL_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$")
ALLOWED_PROTOCOLS = {"ssh", "wireguard", "openvpn"}
'''
new = '''CONTRACT = "manager-hive-vpn-allocation-v1"
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
'''
if s.count(old) != 1:
    raise SystemExit("hive constants anchor mismatch")
s = s.replace(old, new, 1)

old = '''    ensure_dir(CTRL_EPOCH_DIR)
    ensure_dir(CTRL_OUTBOX_DIR)
    ensure_dir(NODE_ACTIVE_DIR)
    ensure_dir(NODE_STATE_DIR)
    ensure_dir(NODE_EPOCH_DIR)
    ensure_dir(NODE_PROVISION_DIR)
'''
new = '''    ensure_dir(CTRL_EPOCH_DIR)
    ensure_dir(CTRL_OUTBOX_DIR)
    ensure_dir(CTRL_ENDPOINT_DIR)
    ensure_dir(NODE_ACTIVE_DIR)
    ensure_dir(NODE_STATE_DIR)
    ensure_dir(NODE_EPOCH_DIR)
    ensure_dir(NODE_PROVISION_DIR)
    ensure_dir(NODE_CLAIM_DIR)
'''
if s.count(old) != 1:
    raise SystemExit("hive init dirs anchor mismatch")
s = s.replace(old, new, 1)

anchor = '''def controller_outbox_path(node_id, allocation_id):
'''
if s.count(anchor) != 1:
    raise SystemExit("hive controller outbox insertion anchor mismatch")
helpers = r'''def normalize_fp(value):
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


'''
s = s.replace(anchor, helpers + anchor, 1)

anchor = '''def validate_bundle(bundle):
'''
if s.count(anchor) != 1:
    raise SystemExit("hive controller login insertion anchor mismatch")
controller_login = r'''def controller_login(identity_id, protocol, out_path, region="", pool="", sticky="", node_scope="*", ttl=DEFAULT_LOGIN_TTL):
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


'''
s = s.replace(anchor, controller_login + anchor, 1)

start = s.index('def validate_bundle(bundle):\n')
end = s.index('\n\ndef node_enable():', start)
old_block = s[start:end]
new_block = r'''def validate_bundle(bundle):
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
'''
s = s[:start] + new_block + s[end:]

old = '''def provision_bundle(bundle):
    init_dirs(); path=provision_receipt_path(bundle["allocation_id"]); receipt=read_conf(path)
    if receipt:
'''
new = '''def provision_bundle(bundle):
    init_dirs(); validate_local_claim_endpoint(bundle)
    path=provision_receipt_path(bundle["allocation_id"]); receipt=read_conf(path)
    if receipt:
'''
if s.count(old) != 1:
    raise SystemExit("provision bundle endpoint anchor mismatch")
s = s.replace(old, new, 1)

anchor = '''def sync_node(limit=8):
'''
if s.count(anchor) != 1:
    raise SystemExit("claim insertion anchor mismatch")
claim_code = r'''def claim_state_path(allocation_id):
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


'''
s = s.replace(anchor, claim_code + anchor, 1)

old = '''    print("delivery_transport=lease-control-pull"); print("automatic_remote_provisioning=1"); print("controller_in_user_vpn_path=0")
    print(f"provision_receipts={sum(1 for path in Path(NODE_PROVISION_DIR).glob('*.conf') if read_conf(str(path)).get('status')=='ok')}")
'''
new = '''    print("delivery_transport=lease-control-pull"); print("automatic_remote_provisioning=1"); print("controller_in_user_vpn_path=0")
    print("public_login_claim=1"); print("public_login_transport=direct-node-tls1.3"); print("claim_one_shot=1")
    print(f"provision_receipts={sum(1 for path in Path(NODE_PROVISION_DIR).glob('*.conf') if read_conf(str(path)).get('status')=='ok')}")
'''
if s.count(old) != 1:
    raise SystemExit("node status anchor mismatch")
s = s.replace(old, new, 1)

old = '''    print("automatic_distribution=1"); print("delivery_transport=lease-control-pull"); print(f"queued_allocations={queued}")
    print("protocols=ssh,wireguard,openvpn"); print("controller_in_user_vpn_path=0")
'''
new = '''    print("automatic_distribution=1"); print("delivery_transport=lease-control-pull"); print(f"queued_allocations={queued}")
    print("protocols=ssh,wireguard,openvpn"); print("public_login_contract=manager-hive-public-login-v1")
    print("vpn_secret_on_controller=0"); print("controller_in_user_vpn_path=0")
'''
if s.count(old) != 1:
    raise SystemExit("controller status anchor mismatch")
s = s.replace(old, new, 1)

start = s.index('def usage():\n')
end = s.index('\n\ndef main(argv):', start)
old_usage = s[start:end]
new_usage = r'''def usage():
    print("Uso: hive_allocations.sh {--status|--node-enable|--node-disable|--accept BUNDLE|--sync [LIMIT]|--claim ALLOCATION_ID|"
          "--controller-status|--controller-endpoint NODE_ID HOST PORT TLS_FP|"
          "--controller-create ID PROTO OUT [REGION] [POOL] [STICKY] [SCOPE] [TTL]|"
          "--controller-login ID PROTO OUT [REGION] [POOL] [STICKY] [SCOPE] [TTL]|--controller-revoke ID [REASON]|"
          "--reserve ID PROTO|--commit ALLOCATION_ID TOKEN SESSION|--abort ALLOCATION_ID TOKEN|--install|--detach|--purge}",
          file=sys.stderr)
    raise SystemExit(64)
'''
s = s[:start] + new_usage + s[end:]

old = '''    if cmd=="--sync" and len(argv) in {1,2}: sync_node(argv[1] if len(argv)==2 else 8); return
    if cmd=="--controller-status": controller_status(); return
    if cmd=="--controller-create" and 4<=len(argv)<=9:
        controller_create(argv[1],argv[2],argv[3],argv[4] if len(argv)>4 else "",argv[5] if len(argv)>5 else "",
                          argv[6] if len(argv)>6 else "",argv[7] if len(argv)>7 else "*",
                          argv[8] if len(argv)>8 else DEFAULT_TTL); return
'''
new = '''    if cmd=="--sync" and len(argv) in {1,2}: sync_node(argv[1] if len(argv)==2 else 8); return
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
'''
if s.count(old) != 1:
    raise SystemExit("hive main command anchor mismatch")
s = s.replace(old, new, 1)

p.write_text(s)

# ---------------------------------------------------------------------------
# Automation v2: claim is a special no-cache, direct-node TLS action.
# ---------------------------------------------------------------------------
p = Path("modules/automation_v2.sh")
s = p.read_text()

old = '''CONNECTION_ACTIONS = os.path.join(MANAGER_HOME, "modules", "connection_actions.sh")
NODE_USAGE = os.path.join(MANAGER_HOME, "modules", "node_usage.sh")
'''
new = '''CONNECTION_ACTIONS = os.path.join(MANAGER_HOME, "modules", "connection_actions.sh")
NODE_USAGE = os.path.join(MANAGER_HOME, "modules", "node_usage.sh")
HIVE_ALLOCATIONS = os.path.join(MANAGER_HOME, "modules", "hive_allocations.sh")
'''
if s.count(old) != 1:
    raise SystemExit("automation hive module anchor mismatch")
s = s.replace(old, new, 1)

old = '''ACTIONS = {"system.describe", "node.usage", "connection.preflight", "connection.create", "connection.status", "connection.revoke"}
READ_ACTIONS = {"system.describe", "node.usage", "connection.status"}
'''
new = '''ACTIONS = {"system.describe", "node.usage", "connection.preflight", "connection.create", "connection.status", "connection.revoke"}
CLAIM_ACTION = "allocation.claim"
CLAIM_PRINCIPAL = "hive-claim"
CLAIM_TOKEN_RE = re.compile(r"^[A-Za-z0-9_-]{40,128}$")
ALLOCATION_ID_RE = re.compile(r"^[a-f0-9]{32}$")
READ_ACTIONS = {"system.describe", "node.usage", "connection.status"}
'''
if s.count(old) != 1:
    raise SystemExit("automation actions anchor mismatch")
s = s.replace(old, new, 1)

old = '''  printf 'idempotency=1\\naudit=1\\nsecret_replay=0\\n'
}
'''
new = '''  printf 'idempotency=1\\naudit=1\\nsecret_replay=0\\n'
  printf 'public_login_claim=1\\nclaim_transport=direct-node-tls1.3\\nclaim_one_shot=1\\nclaim_secret_cache=0\\n'
}
'''
if s.count(old) != 1:
    raise SystemExit("automation shell status anchor mismatch")
s = s.replace(old, new, 1)

anchor = '''def execute(request, uid):
'''
if s.count(anchor) != 1:
    raise SystemExit("automation execute insertion anchor mismatch")
claim_exec = r'''def execute_claim(request, uid, transport):
    request_id, action_id = request.get("request_id", ""), request.get("action_id", "")
    principal = {"principal_id": CLAIM_PRINCIPAL, "role": "claim", "subject": ""}
    auth_meta = {"scheme": "hive-claim-v1", "key_id": "", "fingerprint": "", "decision": "deny", "freshness": "allocation-expiry"}
    if uid != 0 or transport != "remote-tls-v1":
        result = response_error(request_id, action_id, 67, "claim público exige gateway TLS direto do nó", principal=principal)
        audit(request_id, action_id, uid, result, principal=principal, decision="deny", reason="claim-transport",
              auth=auth_meta, transport=transport); return result
    if request.get("principal_id") != CLAIM_PRINCIPAL:
        result = response_error(request_id, action_id, 67, "principal de claim inválido", principal=principal)
        audit(request_id, action_id, uid, result, principal=principal, decision="deny", reason="claim-principal",
              auth=auth_meta, transport=transport); return result
    forbidden = {"issued_at", "nonce"} & set(request)
    if forbidden:
        result = response_error(request_id, action_id, 64, "envelope de claim contém campos não permitidos", principal=principal)
        audit(request_id, action_id, uid, result, principal=principal, decision="deny", reason="claim-envelope",
              auth=auth_meta, transport=transport); return result
    params, auth = request.get("params"), request.get("auth")
    if not isinstance(params, dict) or set(params) != {"allocation_id"}:
        result = response_error(request_id, action_id, 64, "params de claim inválidos", principal=principal)
        audit(request_id, action_id, uid, result, principal=principal, decision="deny", reason="claim-params",
              auth=auth_meta, transport=transport); return result
    allocation_id = params.get("allocation_id", "")
    if not isinstance(allocation_id, str) or not ALLOCATION_ID_RE.fullmatch(allocation_id):
        result = response_error(request_id, action_id, 64, "allocation_id inválido", principal=principal)
        audit(request_id, action_id, uid, result, principal=principal, decision="deny", reason="claim-allocation",
              auth=auth_meta, transport=transport); return result
    principal["subject"] = allocation_id
    if not isinstance(auth, dict) or set(auth) != {"scheme", "token"} or auth.get("scheme") != "hive-claim-v1":
        result = response_error(request_id, action_id, 67, "autenticação de claim inválida", principal=principal)
        audit(request_id, action_id, uid, result, principal=principal, decision="deny", reason="claim-auth",
              auth=auth_meta, transport=transport); return result
    token = auth.get("token", "")
    if not isinstance(token, str) or not CLAIM_TOKEN_RE.fullmatch(token):
        result = response_error(request_id, action_id, 67, "autenticação de claim inválida", principal=principal)
        audit(request_id, action_id, uid, result, principal=principal, decision="deny", reason="claim-token-format",
              auth=auth_meta, transport=transport); return result
    if not os.path.isfile(HIVE_ALLOCATIONS) or not os.access(HIVE_ALLOCATIONS, os.X_OK):
        result = response_error(request_id, action_id, 69, "módulo de allocation indisponível", principal=principal)
        audit(request_id, action_id, uid, result, principal=principal, decision="deny", reason="claim-module",
              auth=auth_meta, transport=transport); return result
    auth_meta["decision"] = "allow"
    try:
        proc = subprocess.run([HIVE_ALLOCATIONS, "--claim", allocation_id], input=token + "\n", stdin=subprocess.PIPE,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=30, shell=False)
    except subprocess.TimeoutExpired:
        result = response_error(request_id, action_id, 70, "tempo limite do claim excedido", principal=principal)
        audit(request_id, action_id, uid, result, principal=principal, decision="allow", reason="claim-timeout",
              auth=auth_meta, transport=transport); return result
    if proc.returncode != 0:
        message = proc.stderr.strip() or "claim recusado"
        result = response_error(request_id, action_id, int(proc.returncode), message, principal=principal)
        audit(request_id, action_id, uid, result, principal=principal, decision="allow", reason="claim-denied",
              auth=auth_meta, transport=transport); return result
    try:
        payload = json.loads(proc.stdout)
    except json.JSONDecodeError:
        result = response_error(request_id, action_id, 70, "resposta local de claim inválida", principal=principal)
        audit(request_id, action_id, uid, result, principal=principal, decision="allow", reason="claim-response",
              auth=auth_meta, transport=transport); return result
    result = {"contract": CONTRACT, "version": VERSION, "request_id": request_id, "action_id": action_id,
              "principal_id": CLAIM_PRINCIPAL, "principal_role": "claim", "ok": True, "code": 0,
              "result": payload, "cached": False, "secret_replay_available": False, "secret_returned_once": True}
    audit(request_id, action_id, uid, result, principal=principal, decision="allow", reason="claim-one-shot",
          auth=auth_meta, transport=transport); return result


'''
s = s.replace(anchor, claim_exec + anchor, 1)

old = '''    if request.get("version") != VERSION: return response_error(str(request_id), str(action_id), 64, "versão de envelope não suportada", principal_id=principal_id)
    if not isinstance(request_id, str) or not REQUEST_RE.fullmatch(request_id): return response_error(str(request_id), str(action_id), 64, "request_id inválido", principal_id=principal_id)
    if not isinstance(action_id, str) or action_id not in ACTIONS: return response_error(request_id, str(action_id), 64, "action_id não permitido", principal_id=principal_id)
    if uid != 0:
'''
new = '''    if request.get("version") != VERSION: return response_error(str(request_id), str(action_id), 64, "versão de envelope não suportada", principal_id=principal_id)
    if not isinstance(request_id, str) or not REQUEST_RE.fullmatch(request_id): return response_error(str(request_id), str(action_id), 64, "request_id inválido", principal_id=principal_id)
    if action_id == CLAIM_ACTION: return execute_claim(request, uid, transport)
    if not isinstance(action_id, str) or action_id not in ACTIONS: return response_error(request_id, str(action_id), 64, "action_id não permitido", principal_id=principal_id)
    if uid != 0:
'''
if s.count(old) != 1:
    raise SystemExit("automation execute dispatch anchor mismatch")
s = s.replace(old, new, 1)

anchor = '''def main():
'''
if s.count(anchor) != 1:
    raise SystemExit("automation claim client insertion anchor mismatch")
claim_client = r'''def claim_client(path):
    try:
        st = os.lstat(path)
    except FileNotFoundError as exc:
        raise ValueError("bundle de public login não encontrado") from exc
    if not stat.S_ISREG(st.st_mode) or stat.S_IMODE(st.st_mode) & 0o077 or st.st_size > 65536:
        raise PermissionError("bundle de public login deve ser arquivo regular privado")
    try:
        with open(path, "r", encoding="utf-8") as fh:
            bundle = json.load(fh)
    except Exception as exc:
        raise ValueError("bundle de public login inválido") from exc
    required = {"contract", "version", "allocation_id", "identity_id", "product_id", "protocol", "selected_node",
                "selected_name", "endpoint", "server_fingerprint", "claim_token", "expires_epoch"}
    if not isinstance(bundle, dict) or set(bundle) != required or bundle.get("contract") != "manager-hive-public-login-v1" or bundle.get("version") != 1:
        raise ValueError("contrato de public login inválido")
    allocation_id, token = bundle.get("allocation_id", ""), bundle.get("claim_token", "")
    if not ALLOCATION_ID_RE.fullmatch(str(allocation_id)) or not CLAIM_TOKEN_RE.fullmatch(str(token)):
        raise ValueError("credencial de claim inválida")
    if not isinstance(bundle.get("expires_epoch"), int) or bundle["expires_epoch"] <= int(time.time()):
        raise PermissionError("public login expirou")
    request = {"version": VERSION, "request_id": secrets.token_hex(16), "principal_id": CLAIM_PRINCIPAL,
               "action_id": CLAIM_ACTION, "params": {"allocation_id": allocation_id},
               "auth": {"scheme": "hive-claim-v1", "token": token}}
    raw = (json.dumps(request, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n").encode("utf-8")
    payload = send_remote(raw, bundle["endpoint"], bundle["server_fingerprint"])
    if not payload:
        raise RuntimeError("resposta vazia do nó selecionado")
    result = json.loads(payload.decode("utf-8")); print(json.dumps(result, sort_keys=True, ensure_ascii=False))
    code = result.get("code", 70); return code if isinstance(code, int) and 0 <= code <= 255 else 70


'''
s = s.replace(anchor, claim_client + anchor, 1)

old = '''def main():
    if len(sys.argv) < 2 or sys.argv[1] not in {"serve-local", "serve-remote", "call"}: return 64
    mode, args = sys.argv[1], sys.argv[2:]
    if mode == "serve-local": serve_local(); return 0
    if mode == "serve-remote": serve_remote(); return 0
    try: return call_client(args)
'''
new = '''def main():
    if len(sys.argv) < 2 or sys.argv[1] not in {"serve-local", "serve-remote", "call", "claim-client"}: return 64
    mode, args = sys.argv[1], sys.argv[2:]
    if mode == "serve-local": serve_local(); return 0
    if mode == "serve-remote": serve_remote(); return 0
    if mode == "claim-client":
        if len(args) != 1: return 64
        try: return claim_client(args[0])
        except PermissionError as exc: print(str(exc), file=sys.stderr); return 67
        except ValueError as exc: print(str(exc), file=sys.stderr); return 64
        except (OSError, ssl.SSLError, RuntimeError, json.JSONDecodeError) as exc: print(str(exc), file=sys.stderr); return 70
    try: return call_client(args)
'''
if s.count(old) != 1:
    raise SystemExit("automation main modes anchor mismatch")
s = s.replace(old, new, 1)

old = '''call_v2() {
  ensure_dependencies || exit 69
  ensure_dirs
  run_backend call "$@"
}

case "${1:-}" in
'''
new = '''call_v2() {
  ensure_dependencies || exit 69
  ensure_dirs
  run_backend call "$@"
}

claim_v2() {
  ensure_dependencies || exit 69
  ensure_dirs
  run_backend claim-client "$1"
}

case "${1:-}" in
'''
if s.count(old) != 1:
    raise SystemExit("automation shell claim function anchor mismatch")
s = s.replace(old, new, 1)

old = '''  --remote-rotate-certificate) remote_rotate_certificate ;;
  --call)
    shift
    call_v2 "$@"
    ;;
  "") show_status ;;
  *)
    err "Uso: automation_v2.sh {--install|--detach|--purge|--status|--serve|--serve-remote|--remote-enable IP [PORT]|--remote-disable|--remote-status|--remote-rotate-certificate|--call ...}"
'''
new = '''  --remote-rotate-certificate) remote_rotate_certificate ;;
  --claim-bundle) [[ -n "${2:-}" ]] || { err "Uso: automation_v2.sh --claim-bundle /CAMINHO/login.json"; exit 64; }; claim_v2 "$2" ;;
  --call)
    shift
    call_v2 "$@"
    ;;
  "") show_status ;;
  *)
    err "Uso: automation_v2.sh {--install|--detach|--purge|--status|--serve|--serve-remote|--remote-enable IP [PORT]|--remote-disable|--remote-status|--remote-rotate-certificate|--claim-bundle FILE|--call ...}"
'''
if s.count(old) != 1:
    raise SystemExit("automation shell case anchor mismatch")
s = s.replace(old, new, 1)

p.write_text(s)

# ---------------------------------------------------------------------------
# CLI wiring.
# ---------------------------------------------------------------------------
p = Path("manager")
s = p.read_text()
old = '''  manager hive allocation accept BUNDLE
  manager hive allocation controller status
  manager hive allocation controller create ID PROTO OUT [REGION] [POOL] [STICKY] [SCOPE] [TTL]
  manager hive allocation controller revoke ID [REASON]
                                  allocation/login global assinado da Colmeia (0.8.5)
'''
new = '''  manager hive allocation accept BUNDLE
  manager hive allocation claim LOGIN_BUNDLE
                                  faz claim one-shot direto no nó selecionado via TLS 1.3 pinado
  manager hive allocation controller status
  manager hive allocation controller endpoint NODE_ID HOST PORT TLS_FP
                                  registra endpoint público TLS do nó para public login
  manager hive allocation controller create ID PROTO OUT [REGION] [POOL] [STICKY] [SCOPE] [TTL]
  manager hive allocation controller login ID PROTO OUT [REGION] [POOL] [STICKY] [SCOPE] [TTL]
                                  cria bundle público temporário sem trazer segredo VPN ao controlador
  manager hive allocation controller revoke ID [REASON]
                                  allocation/login global assinado da Colmeia (0.8.5)
'''
if s.count(old) != 1:
    raise SystemExit("manager help allocation anchor mismatch")
s = s.replace(old, new, 1)

old = '''          accept) [[ -n "${4:-}" ]] || { err "Uso: manager hive allocation accept BUNDLE"; exit 64; }; exec "$MANAGER_HOME/modules/hive_allocations.sh" --accept "$4" ;;
          sync) exec "$MANAGER_HOME/modules/hive_allocations.sh" --sync "${4:-8}" ;;
          controller)
            case "${4:-status}" in
              status) exec "$MANAGER_HOME/modules/hive_allocations.sh" --controller-status ;;
              create)
                [[ -n "${5:-}" && -n "${6:-}" && -n "${7:-}" ]] || { err "Uso: manager hive allocation controller create ID PROTO OUT [REGION] [POOL] [STICKY] [SCOPE] [TTL]"; exit 64; }
                exec "$MANAGER_HOME/modules/hive_allocations.sh" --controller-create "$5" "$6" "$7" "${8:-}" "${9:-}" "${10:-}" "${11:-*}" "${12:-60}"
                ;;
              revoke) [[ -n "${5:-}" ]] || { err "Uso: manager hive allocation controller revoke ID [REASON]"; exit 64; }; exec "$MANAGER_HOME/modules/hive_allocations.sh" --controller-revoke "$5" "${6:-admin}" ;;
              *) err "Uso: manager hive allocation controller {status|create|revoke} ..."; exit 64 ;;
'''
new = '''          accept) [[ -n "${4:-}" ]] || { err "Uso: manager hive allocation accept BUNDLE"; exit 64; }; exec "$MANAGER_HOME/modules/hive_allocations.sh" --accept "$4" ;;
          claim) [[ -n "${4:-}" ]] || { err "Uso: manager hive allocation claim LOGIN_BUNDLE"; exit 64; }; exec "$MANAGER_HOME/modules/automation_v2.sh" --claim-bundle "$4" ;;
          sync) exec "$MANAGER_HOME/modules/hive_allocations.sh" --sync "${4:-8}" ;;
          controller)
            case "${4:-status}" in
              status) exec "$MANAGER_HOME/modules/hive_allocations.sh" --controller-status ;;
              endpoint)
                [[ -n "${5:-}" && -n "${6:-}" && -n "${7:-}" && -n "${8:-}" ]] || { err "Uso: manager hive allocation controller endpoint NODE_ID HOST PORT TLS_FP"; exit 64; }
                exec "$MANAGER_HOME/modules/hive_allocations.sh" --controller-endpoint "$5" "$6" "$7" "$8"
                ;;
              create)
                [[ -n "${5:-}" && -n "${6:-}" && -n "${7:-}" ]] || { err "Uso: manager hive allocation controller create ID PROTO OUT [REGION] [POOL] [STICKY] [SCOPE] [TTL]"; exit 64; }
                exec "$MANAGER_HOME/modules/hive_allocations.sh" --controller-create "$5" "$6" "$7" "${8:-}" "${9:-}" "${10:-}" "${11:-*}" "${12:-60}"
                ;;
              login)
                [[ -n "${5:-}" && -n "${6:-}" && -n "${7:-}" ]] || { err "Uso: manager hive allocation controller login ID PROTO OUT [REGION] [POOL] [STICKY] [SCOPE] [TTL]"; exit 64; }
                exec "$MANAGER_HOME/modules/hive_allocations.sh" --controller-login "$5" "$6" "$7" "${8:-}" "${9:-}" "${10:-}" "${11:-*}" "${12:-180}"
                ;;
              revoke) [[ -n "${5:-}" ]] || { err "Uso: manager hive allocation controller revoke ID [REASON]"; exit 64; }; exec "$MANAGER_HOME/modules/hive_allocations.sh" --controller-revoke "$5" "${6:-admin}" ;;
              *) err "Uso: manager hive allocation controller {status|endpoint|create|login|revoke} ..."; exit 64 ;;
'''
if s.count(old) != 1:
    raise SystemExit("manager allocation dispatch anchor mismatch")
s = s.replace(old, new, 1)

old = '''          *) err "Uso: manager hive allocation {status|enable|disable|accept|sync [LIMIT]|controller ...}"; exit 64 ;;
'''
new = '''          *) err "Uso: manager hive allocation {status|enable|disable|accept|claim|sync [LIMIT]|controller ...}"; exit 64 ;;
'''
if s.count(old) != 1:
    raise SystemExit("manager allocation usage anchor mismatch")
s = s.replace(old, new, 1)
p.write_text(s)

# ---------------------------------------------------------------------------
# Documentation: document the security boundary without marking 0.8.5 released.
# ---------------------------------------------------------------------------
p = Path("docs/ROADMAP.md")
s = p.read_text()
old = '''- falha de produto/protocolo/preflight no nó impede ACK e mantém o fluxo fail-closed.

Ainda pendente para fechar a 0.8.5:

- devolver ao fluxo público o resultado/credencial criada no nó sem expor segredo em logs ou no audit;
- fechar o endpoint/contrato público de login/provisionamento de ponta a ponta e seus gates finais antes de alterar `VERSION`.
'''
new = '''- falha de produto/protocolo/preflight no nó impede ACK e mantém o fluxo fail-closed;
- public login v1 gera token bootstrap de alta entropia, mas somente seu SHA-256 entra no ticket assinado/outbox;
- endpoint público do nó usa o gateway Automation v2 existente com TLS 1.3 e pin SHA-256;
- claim é one-shot e validado no `managerd` do nó, sem passar pelo controlador e sem cache idempotente de segredo;
- SSH devolve usuário/senha somente quando a senha foi realmente criada pela allocation; binding legado sem senha recuperável falha fechado;
- WireGuard/OpenVPN devolvem o conteúdo do profile diretamente do nó, nunca um caminho local e nunca através do controlador;
- token, senha e profiles não entram no audit da Automation/Colmeia.

Ainda pendente para fechar a 0.8.5:

- fechar os gates finais do public login/claim e a revisão de release antes de alterar `VERSION`.
'''
if s.count(old) != 1:
    raise SystemExit("roadmap 0.8.5 anchor mismatch")
s = s.replace(old, new, 1)
p.write_text(s)

p = Path("docs/HIVE.md")
s = p.read_text()
anchor = '''## 17. Audit global
'''
if s.count(anchor) != 1:
    raise SystemExit("HIVE public login insertion anchor mismatch")
section = r'''### Public login / claim direto no nó (0.8.5)

O fluxo público não transporta a credencial VPN pelo controlador. O controlador conhece somente um **token bootstrap temporário** durante a criação do login; no ticket assinado e no outbox entra apenas `SHA-256(token)`.

Cada nó elegível para public login precisa anunciar administrativamente o endpoint TLS que o cliente alcança:

```bash
manager automation v2 remote enable 203.0.113.20 9443
manager hive allocation controller endpoint NODE_ID 203.0.113.20 9443 SHA256:<64-hex>
```

O fingerprint configurado no controlador é incorporado ao ticket assinado. Antes do ACK, o nó confirma que sua Automation v2 remota está habilitada em TLS 1.3, usa a mesma porta e apresenta exatamente o certificado pinado. Divergência falha fechado.

Criação do login:

```bash
manager hive allocation controller login maria wireguard /root/maria.login.json BR-SP PREMIUM maria '*' 180
```

O arquivo `maria.login.json` é criado como `0600` e usa o contrato `manager-hive-public-login-v1`. Ele contém somente o bootstrap necessário para o cliente: allocation, nó, endpoint, fingerprint TLS, protocolo, expiração e o token one-shot. Senha SSH, chave/profile WireGuard e profile OpenVPN **não existem no controlador**.

Depois que o nó recebeu, validou e provisionou a allocation, o cliente faz claim diretamente no nó:

```bash
manager hive allocation claim /root/maria.login.json
```

O helper acima é apenas uma implementação de referência do contrato. O fluxo de rede é:

```text
cliente
  └─ TLS 1.3 + pin SHA-256 ──> gateway Automation v2 do nó selecionado
                                  └─ Unix socket local ──> managerd
                                                           └─ claim one-shot
                                                              └─ receipt/profile local
```

A ação pública é tipada como `allocation.claim`; o gateway continua sem autoridade lógica. O `managerd` valida transporte, allocation, token, expiração, `session_epoch`, receipt de provisionamento e consumo único. O token é enviado ao módulo local por stdin, nunca em argv. A resposta de segredo não passa pelo cache de idempotência e audit nenhum persiste token, senha ou profile.

Semântica por protocolo:

- **SSH:** retorna `username` + `password` somente quando a própria allocation gerou uma senha recuperável. Um binding SSH legado reutilizado sem senha disponível é recusado; não há rotação silenciosa.
- **WireGuard:** retorna o conteúdo do profile root-only criado no nó, não o caminho do arquivo.
- **OpenVPN:** retorna o conteúdo do profile root-only criado no nó, não o caminho do arquivo.

Após um claim bem-sucedido, a allocation fica marcada como consumida para esse bootstrap. Repetir o mesmo token não devolve o segredo novamente. O controlador continua fora do caminho de dados VPN e também fora do caminho da credencial VPN final.

'''
s = s.replace(anchor, section + anchor, 1)
p.write_text(s)
