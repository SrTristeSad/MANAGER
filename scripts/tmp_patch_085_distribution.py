from pathlib import Path


def replace_once(path, old, new):
    p = Path(path)
    text = p.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected exactly one match, got {count}")
    p.write_text(text.replace(old, new, 1))


# modules/hive_leases.sh: expose the existing authenticated TLS lease channel as
# a narrow node-targeted allocation pull/ack control plane.
replace_once(
    "modules/hive_leases.sh",
    '''AUDIT_FILE = os.environ.get("MANAGER_HIVE_LEASE_AUDIT_FILE", "/var/log/manager/hive-lease-audit.jsonl")
SYSTEMD_DIR = os.environ.get("MANAGER_HIVE_LEASE_SYSTEMD_DIR", "/etc/systemd/system")
''',
    '''AUDIT_FILE = os.environ.get("MANAGER_HIVE_LEASE_AUDIT_FILE", "/var/log/manager/hive-lease-audit.jsonl")
ALLOCATION_OUTBOX_DIR = os.environ.get("MANAGER_HIVE_ALLOCATION_OUTBOX_DIR", "/var/lib/manager/hive-allocations/controller/outbox")
SYSTEMD_DIR = os.environ.get("MANAGER_HIVE_LEASE_SYSTEMD_DIR", "/etc/systemd/system")
''')

replace_once(
    "modules/hive_leases.sh",
    '''class LeaseError(Exception):
''',
    '''def allocation_pull_locked(node_id, node_epoch, params):
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


def allocation_ack_locked(node_id, node_epoch, params):
    if not isinstance(params, dict) or set(params) != {"allocation_id"}:
        raise LeaseError(64, "invalid-allocation-ack-params")
    allocation_id = str(params.get("allocation_id", ""))
    if not SESSION_RE.fullmatch(allocation_id):
        raise LeaseError(64, "invalid-allocation-id")
    path = Path(ALLOCATION_OUTBOX_DIR) / node_id / f"{allocation_id}.json"
    if not path.exists():
        return {"acked": True, "idempotent": True, "allocation_id": allocation_id}
    bundle = read_json(str(path))
    if not bundle:
        raise LeaseError(70, "invalid-outbox-bundle")
    try: bundle_node_epoch = int(bundle.get("node_epoch", 0))
    except (TypeError, ValueError): bundle_node_epoch = 0
    if bundle.get("selected_node") != node_id or bundle_node_epoch != int(node_epoch):
        raise LeaseError(67, "allocation-ack-node-mismatch")
    try: path.unlink()
    except FileNotFoundError: pass
    audit("allocation-ack", node_id=node_id, allocation_id=allocation_id,
          identity_id=bundle.get("identity_id"), global_lease_id=bundle.get("global_lease_id"))
    return {"acked": True, "idempotent": False, "allocation_id": allocation_id}


class LeaseError(Exception):
''')

replace_once(
    "modules/hive_leases.sh",
    '''            if action == "acquire": result = acquire_locked(node_id, node_epoch, params)
            elif action == "heartbeat": result = heartbeat_locked(node_id, node_epoch, params)
            elif action == "release": result = release_locked(node_id, params)
            else: raise LeaseError(64, "invalid-action")
''',
    '''            if action == "acquire": result = acquire_locked(node_id, node_epoch, params)
            elif action == "heartbeat": result = heartbeat_locked(node_id, node_epoch, params)
            elif action == "release": result = release_locked(node_id, params)
            elif action == "allocation_pull": result = allocation_pull_locked(node_id, node_epoch, params)
            elif action == "allocation_ack": result = allocation_ack_locked(node_id, node_epoch, params)
            else: raise LeaseError(64, "invalid-action")
''')

replace_once(
    "modules/hive_leases.sh",
    '''def node_release(identity_id, local_session_id):
    node_request("release", {"identity_id": validate_identity(identity_id), "local_session_id": validate_session(local_session_id)})
    print("released=1")


def controller_list(identity_id=""):
''',
    '''def node_release(identity_id, local_session_id):
    node_request("release", {"identity_id": validate_identity(identity_id), "local_session_id": validate_session(local_session_id)})
    print("released=1")


def node_allocation_pull(limit=4):
    try: limit = int(limit)
    except (TypeError, ValueError): die("limit de allocation inválido.", 64)
    if limit < 1 or limit > 8: die("limit de allocation deve ficar entre 1 e 8.", 64)
    result = node_request("allocation_pull", {"limit": limit})
    bundles = result.get("bundles", [])
    if not isinstance(bundles, list): die("Resposta de allocation do controlador inválida.", 70)
    print(json.dumps({"count": len(bundles), "bundles": bundles}, sort_keys=True, separators=(",", ":")))


def node_allocation_ack(allocation_id):
    if not SESSION_RE.fullmatch(str(allocation_id)): die("allocation_id inválido.", 64)
    result = node_request("allocation_ack", {"allocation_id": allocation_id})
    print(f"allocation_acked={1 if result.get('acked') else 0}")
    print(f"idempotent={1 if result.get('idempotent') else 0}")
    print(f"allocation_id={allocation_id}")


def controller_list(identity_id=""):
''')

replace_once(
    "modules/hive_leases.sh",
    '''    print("Uso: hive_leases.sh {--status|--node-status|--node-configure HOST PORT FP [GRACE]|--node-disable|--controller-init|--controller-status|--controller-enable BIND [PORT]|--controller-disable|--controller-rotate-tls|--controller-grant ID PROTO [REGION] [POOL] [STICKY] [SCOPE] [DEVICE] [TTL]|--limit-set ID MAX [PRODUCT]|--limit-import-local ID|--limit-sync-local|--limit-show ID|--limit-list|--limit-unset ID|--controller-list [ID]|--controller-revoke ID [REASON]|--acquire-node ID PROTO RESOURCE DEVICE SESSION [TTL] [GLOBAL_LEASE_ID]|--heartbeat-node ID SESSION [TTL]|--release-node ID SESSION|--serve-controller|--install|--detach|--purge}", file=sys.stderr)
''',
    '''    print("Uso: hive_leases.sh {--status|--node-status|--node-configure HOST PORT FP [GRACE]|--node-disable|--controller-init|--controller-status|--controller-enable BIND [PORT]|--controller-disable|--controller-rotate-tls|--controller-grant ID PROTO [REGION] [POOL] [STICKY] [SCOPE] [DEVICE] [TTL]|--limit-set ID MAX [PRODUCT]|--limit-import-local ID|--limit-sync-local|--limit-show ID|--limit-list|--limit-unset ID|--controller-list [ID]|--controller-revoke ID [REASON]|--acquire-node ID PROTO RESOURCE DEVICE SESSION [TTL] [GLOBAL_LEASE_ID]|--heartbeat-node ID SESSION [TTL]|--release-node ID SESSION|--allocation-pull-node [LIMIT]|--allocation-ack-node ALLOCATION_ID|--serve-controller|--install|--detach|--purge}", file=sys.stderr)
''')

replace_once(
    "modules/hive_leases.sh",
    '''    if cmd == "--heartbeat-node" and len(argv) in {3,4}: node_heartbeat(argv[1], argv[2], argv[3] if len(argv) == 4 else DEFAULT_TTL); return
    if cmd == "--release-node" and len(argv) == 3: node_release(argv[1], argv[2]); return
    if cmd == "--serve-controller": serve_controller(); return
''',
    '''    if cmd == "--heartbeat-node" and len(argv) in {3,4}: node_heartbeat(argv[1], argv[2], argv[3] if len(argv) == 4 else DEFAULT_TTL); return
    if cmd == "--release-node" and len(argv) == 3: node_release(argv[1], argv[2]); return
    if cmd == "--allocation-pull-node" and len(argv) in {1,2}: node_allocation_pull(argv[1] if len(argv) == 2 else 4); return
    if cmd == "--allocation-ack-node" and len(argv) == 2: node_allocation_ack(argv[1]); return
    if cmd == "--serve-controller": serve_controller(); return
''')

# modules/hive_allocations.sh: durable controller outbox + node sync timer.
replace_once(
    "modules/hive_allocations.sh",
    '''DATA_DIR = os.environ.get("MANAGER_HIVE_ALLOCATION_DATA_DIR", "/var/lib/manager/hive-allocations")
CTRL_EPOCH_DIR = os.path.join(DATA_DIR, "controller", "epochs")
NODE_ACTIVE_DIR = os.path.join(DATA_DIR, "node", "active")
''',
    '''DATA_DIR = os.environ.get("MANAGER_HIVE_ALLOCATION_DATA_DIR", "/var/lib/manager/hive-allocations")
CTRL_EPOCH_DIR = os.path.join(DATA_DIR, "controller", "epochs")
CTRL_OUTBOX_DIR = os.path.join(DATA_DIR, "controller", "outbox")
NODE_ACTIVE_DIR = os.path.join(DATA_DIR, "node", "active")
''')

replace_once(
    "modules/hive_allocations.sh",
    '''LEASE_MODULE = os.path.join(MANAGER_HOME, "modules", "hive_leases.sh")
CONTRACT = "manager-hive-vpn-allocation-v1"
''',
    '''LEASE_MODULE = os.path.join(MANAGER_HOME, "modules", "hive_leases.sh")
SYSTEMD_DIR = os.environ.get("MANAGER_HIVE_ALLOCATION_SYSTEMD_DIR", "/etc/systemd/system")
SYNC_SERVICE = os.path.join(SYSTEMD_DIR, "manager-hive-allocation-sync.service")
SYNC_TIMER = os.path.join(SYSTEMD_DIR, "manager-hive-allocation-sync.timer")
SYNC_SERVICE_MARKER = "# MANAGER-HIVE-ALLOCATION-SYNC-SERVICE v1"
SYNC_TIMER_MARKER = "# MANAGER-HIVE-ALLOCATION-SYNC-TIMER v1"
CONTRACT = "manager-hive-vpn-allocation-v1"
''')

replace_once(
    "modules/hive_allocations.sh",
    '''    ensure_dir(CTRL_EPOCH_DIR)
    ensure_dir(NODE_ACTIVE_DIR)
''',
    '''    ensure_dir(CTRL_EPOCH_DIR)
    ensure_dir(CTRL_OUTBOX_DIR)
    ensure_dir(NODE_ACTIVE_DIR)
''')

replace_once(
    "modules/hive_allocations.sh",
    '''def write_external_new(path, data):
''',
    '''def systemctl(*args):
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
''')

replace_once(
    "modules/hive_allocations.sh",
    '''def controller_create(identity_id,protocol,out_path,region="",pool="",sticky="",node_scope="*",ttl=DEFAULT_TTL):
''',
    '''def controller_outbox_path(node_id, allocation_id):
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
''')

replace_once(
    "modules/hive_allocations.sh",
    '''    allocation["signature"]=sign(CTRL_KEY,canonical(allocation))
    write_external_new(out_path,json.dumps(allocation,sort_keys=True,separators=(",",":"))+"\n")
    audit("create",identity_id=identity_id,product_id=product_id,protocol=protocol,allocation_id=allocation_id,
          global_lease_id=global_id,node_id=selected_node,node_epoch=node_epoch,session_epoch=session_epoch,
          expires_epoch=expires_i)
''',
    '''    allocation["signature"]=sign(CTRL_KEY,canonical(allocation))
    payload=json.dumps(allocation,sort_keys=True,separators=(",",":"))+"\n"
    write_external_new(out_path,payload)
    queued_path=queue_bundle(allocation)
    audit("create",identity_id=identity_id,product_id=product_id,protocol=protocol,allocation_id=allocation_id,
          global_lease_id=global_id,node_id=selected_node,node_epoch=node_epoch,session_epoch=session_epoch,
          expires_epoch=expires_i,distribution_queued=1)
''')

replace_once(
    "modules/hive_allocations.sh",
    '''    print(f"session_epoch={session_epoch}"); print(f"expires_epoch={expires_i}"); print("lease_state=reserved")
    print("controller_in_user_vpn_path=0")
''',
    '''    print(f"session_epoch={session_epoch}"); print(f"expires_epoch={expires_i}"); print("lease_state=reserved")
    print("distribution_queued=1"); print(f"distribution_queue={queued_path}")
    print("delivery_transport=lease-control-pull"); print("controller_in_user_vpn_path=0")
''')

replace_once(
    "modules/hive_allocations.sh",
    '''def accept_bundle(path):
    init_dirs()
    if not node_enabled(): die("Allocation enforcement está desabilitado neste nó.",67)
    bundle=validate_bundle(read_json(path)); identity_id=bundle["identity_id"]; allocation_id=bundle["allocation_id"]
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
            print("allocation_accepted=1"); print("idempotent=1"); print(f"allocation_id={allocation_id}"); return
        atomic_write(dest,json.dumps(bundle,sort_keys=True,separators=(",",":"))+"\n"); state_write(allocation_id,"ready")
        audit("accept",identity_id=identity_id,product_id=bundle["product_id"],protocol=bundle["protocol"],
              allocation_id=allocation_id,global_lease_id=bundle["global_lease_id"],node_id=bundle["selected_node"],
              session_epoch=incoming)
        fcntl.flock(lock.fileno(),fcntl.LOCK_UN)
    print("allocation_accepted=1"); print("idempotent=0"); print(f"allocation_id={allocation_id}")
    print(f"identity_id={identity_id}"); print(f"product_id={bundle['product_id']}"); print(f"protocol={bundle['protocol']}")
    print(f"global_lease_id={bundle['global_lease_id']}"); print(f"session_epoch={incoming}")
    print(f"expires_epoch={bundle['expires_epoch']}")


def reserve(identity_id,protocol):
''',
    '''def accept_bundle_object(raw_bundle):
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
    accepted=idempotent_count=acked=0
    for raw in bundles:
        bundle,was_idempotent=accept_bundle_object(raw)
        if was_idempotent: idempotent_count+=1
        else: accepted+=1
        ack=subprocess.run([LEASE_MODULE,"--allocation-ack-node",bundle["allocation_id"]],stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE,text=True,timeout=20,check=False)
        if ack.returncode!=0:
            audit("sync-ack-failed",identity_id=bundle.get("identity_id"),allocation_id=bundle.get("allocation_id"))
            die(ack.stderr.strip() or "Allocation foi persistida localmente, mas o ACK ao controlador falhou.",ack.returncode)
        acked+=1
        audit("sync-delivered",identity_id=bundle.get("identity_id"),protocol=bundle.get("protocol"),
              allocation_id=bundle.get("allocation_id"),global_lease_id=bundle.get("global_lease_id"))
    print(f"allocations_pulled={len(bundles)}"); print(f"allocations_accepted={accepted}")
    print(f"allocations_idempotent={idempotent_count}"); print(f"allocations_acked={acked}")
    print("delivery_transport=lease-control-pull")


def reserve(identity_id,protocol):
''')

replace_once(
    "modules/hive_allocations.sh",
    '''    atomic_write(NODE_CONF,f"version=1\\nenabled=1\\nnode_id={node_id}\\nnode_epoch={node_epoch}\\n"
                           f"controller_id={enrollment.get('controller_id','')}\\nupdated_epoch={int(time.time())}\\n")
    print("vpn_allocation_enforcement=1"); print(f"node_id={node_id}"); print(f"node_epoch={node_epoch}")
    print("failure_mode=fail-closed")
''',
    '''    atomic_write(NODE_CONF,f"version=1\\nenabled=1\\nnode_id={node_id}\\nnode_epoch={node_epoch}\\n"
                           f"controller_id={enrollment.get('controller_id','')}\\nupdated_epoch={int(time.time())}\\n")
    enable_sync_timer()
    print("vpn_allocation_enforcement=1"); print(f"node_id={node_id}"); print(f"node_epoch={node_epoch}")
    print("automatic_distribution=1"); print("sync_interval_seconds=3"); print("failure_mode=fail-closed")
''')

replace_once(
    "modules/hive_allocations.sh",
    '''def node_disable():
    init_dirs(); conf=read_conf(NODE_CONF)
''',
    '''def node_disable():
    init_dirs(); disable_sync_timer(False); conf=read_conf(NODE_CONF)
''')

replace_once(
    "modules/hive_allocations.sh",
    '''def controller_revoke(identity_id,reason="admin"):
    init_dirs(); identity_id=validate_identity(identity_id)
    if not re.fullmatch(r"[A-Za-z0-9_.:-]{1,64}",reason): die("Motivo inválido.",64)
    new_epoch=bump_epoch(CTRL_EPOCH_DIR,identity_id)
''',
    '''def controller_revoke(identity_id,reason="admin"):
    init_dirs(); identity_id=validate_identity(identity_id)
    if not re.fullmatch(r"[A-Za-z0-9_.:-]{1,64}",reason): die("Motivo inválido.",64)
    new_epoch=bump_epoch(CTRL_EPOCH_DIR,identity_id); queued_removed=purge_controller_outbox_identity(identity_id)
''')

replace_once(
    "modules/hive_allocations.sh",
    '''    print(f"identity_id={identity_id}"); print(f"session_epoch={new_epoch}"); print(f"global_epoch={result.get('global_epoch','')}")
    print(f"leases_revoked={result.get('leases_revoked','')}")
''',
    '''    print(f"identity_id={identity_id}"); print(f"session_epoch={new_epoch}"); print(f"global_epoch={result.get('global_epoch','')}")
    print(f"leases_revoked={result.get('leases_revoked','')}"); print(f"queued_allocations_revoked={queued_removed}")
''')

replace_once(
    "modules/hive_allocations.sh",
    '''    print(f"controller_id={conf.get('controller_id','')}"); print("signed_allocation_bundle=1")
    print("exact_global_grant_required_when_enabled=1"); print("controller_in_user_vpn_path=0")
''',
    '''    print(f"controller_id={conf.get('controller_id','')}"); print("signed_allocation_bundle=1")
    print("exact_global_grant_required_when_enabled=1"); print("automatic_distribution=1"); print("sync_interval_seconds=3")
    print(f"sync_timer_active={1 if systemctl('is-active','--quiet','manager-hive-allocation-sync.timer')==0 else 0}")
    print("delivery_transport=lease-control-pull"); print("controller_in_user_vpn_path=0")
''')

replace_once(
    "modules/hive_allocations.sh",
    '''def controller_status():
    init_dirs(); ctrl=controller_identity()
    print(f"contract={STATUS_CONTRACT}"); print("role=controller"); print(f"controller_id={ctrl.get('controller_id','')}")
    print("signed_allocation_bundle=1"); print("global_grant_binding=1"); print("session_epoch_fencing=1")
    print("protocols=ssh,wireguard,openvpn"); print("controller_in_user_vpn_path=0")
''',
    '''def controller_status():
    init_dirs(); ctrl=controller_identity()
    queued=sum(1 for path in Path(CTRL_OUTBOX_DIR).glob("node-*/*.json") if read_json(str(path)))
    print(f"contract={STATUS_CONTRACT}"); print("role=controller"); print(f"controller_id={ctrl.get('controller_id','')}")
    print("signed_allocation_bundle=1"); print("global_grant_binding=1"); print("session_epoch_fencing=1")
    print("automatic_distribution=1"); print("delivery_transport=lease-control-pull"); print(f"queued_allocations={queued}")
    print("protocols=ssh,wireguard,openvpn"); print("controller_in_user_vpn_path=0")
''')

replace_once(
    "modules/hive_allocations.sh",
    '''def install(): init_dirs()
def detach(): return


def purge():
    shutil.rmtree(ALLOC_ETC,ignore_errors=True); shutil.rmtree(DATA_DIR,ignore_errors=True)
''',
    '''def install():
    init_dirs()
    if read_conf(NODE_CONF).get("enabled")=="1" and node_enabled(): enable_sync_timer()


def detach():
    disable_sync_timer(True)


def purge():
    detach(); shutil.rmtree(ALLOC_ETC,ignore_errors=True); shutil.rmtree(DATA_DIR,ignore_errors=True)
''')

replace_once(
    "modules/hive_allocations.sh",
    '''    print("Uso: hive_allocations.sh {--status|--node-enable|--node-disable|--accept BUNDLE|--controller-status|"
          "--controller-create ID PROTO OUT [REGION] [POOL] [STICKY] [SCOPE] [TTL]|--controller-revoke ID [REASON]|"
          "--reserve ID PROTO|--commit ALLOCATION_ID TOKEN SESSION|--abort ALLOCATION_ID TOKEN|--install|--detach|--purge}",
''',
    '''    print("Uso: hive_allocations.sh {--status|--node-enable|--node-disable|--accept BUNDLE|--sync [LIMIT]|--controller-status|"
          "--controller-create ID PROTO OUT [REGION] [POOL] [STICKY] [SCOPE] [TTL]|--controller-revoke ID [REASON]|"
          "--reserve ID PROTO|--commit ALLOCATION_ID TOKEN SESSION|--abort ALLOCATION_ID TOKEN|--install|--detach|--purge}",
''')

replace_once(
    "modules/hive_allocations.sh",
    '''    if cmd=="--accept" and len(argv)==2: accept_bundle(argv[1]); return
    if cmd=="--controller-status": controller_status(); return
''',
    '''    if cmd=="--accept" and len(argv)==2: accept_bundle(argv[1]); return
    if cmd=="--sync" and len(argv) in {1,2}: sync_node(argv[1] if len(argv)==2 else 8); return
    if cmd=="--controller-status": controller_status(); return
''')

# Public CLI exposes a manual sync for diagnostics/recovery; automatic timer is default when enabled.
replace_once(
    "manager",
    '''          accept) [[ -n "${4:-}" ]] || { err "Uso: manager hive allocation accept BUNDLE"; exit 64; }; exec "$MANAGER_HOME/modules/hive_allocations.sh" --accept "$4" ;;
          controller)
''',
    '''          accept) [[ -n "${4:-}" ]] || { err "Uso: manager hive allocation accept BUNDLE"; exit 64; }; exec "$MANAGER_HOME/modules/hive_allocations.sh" --accept "$4" ;;
          sync) exec "$MANAGER_HOME/modules/hive_allocations.sh" --sync "${4:-8}" ;;
          controller)
''')
replace_once(
    "manager",
    '''          *) err "Uso: manager hive allocation {status|enable|disable|accept|controller ...}"; exit 64 ;;
''',
    '''          *) err "Uso: manager hive allocation {status|enable|disable|accept|sync [LIMIT]|controller ...}"; exit 64 ;;
''')

# Documentation: automatic distribution uses the existing lease authority control channel.
replace_once(
    "docs/HIVE.md",
    '''No nó selecionado:

```bash
manager hive allocation accept /root/maria.alloc.json
```

Quando o enforcement de allocation está ativo, o Protocol Lease Bridge exige um ticket local atual e reclama **exatamente** o `global_lease_id` vinculado. Não existe fallback para acquire global genérico apenas porque ainda há capacidade. SSH/OpenVPN continuam com admissão síncrona; WireGuard passa a poder receber autorização antes do primeiro uso quando a allocation é entregue ao nó.
''',
    '''A criação também coloca o bundle assinado em um outbox durável do controlador para o `selected_node`. Com `manager hive allocation enable`, o nó instala um timer de sync que consulta o **mesmo canal TLS 1.3 pinado da autoridade global de leases**. O pull é assinado pela identidade Ed25519 enrolled do nó, inclui freshness/nonce/`node_epoch` e só recebe bundles destinados ao próprio nó/epoch.

Entrega normal:

```bash
manager hive allocation enable
manager hive allocation sync        # diagnóstico/forçar sync; o timer faz isso automaticamente
```

O nó valida novamente assinatura Ed25519, destino, expiração e `session_epoch` antes de persistir o ticket. Só depois do aceite durável envia ACK ao controlador. Se o ACK se perder, o mesmo bundle pode ser puxado novamente e o aceite local é idempotente; o outbox só é removido após ACK válido do nó destinatário. Não é aberta uma nova porta: a distribuição reutiliza o control plane de leases já configurado.

O aceite manual continua disponível como recuperação/diagnóstico:

```bash
manager hive allocation accept /root/maria.alloc.json
```

Quando o enforcement de allocation está ativo, o Protocol Lease Bridge exige um ticket local atual e reclama **exatamente** o `global_lease_id` vinculado. Não existe fallback para acquire global genérico apenas porque ainda há capacidade. SSH/OpenVPN continuam com admissão síncrona; WireGuard passa a poder receber autorização antes do primeiro uso quando a allocation é entregue ao nó.
''')
replace_once(
    "docs/HIVE.md",
    '''Revogação avança o `session_epoch` da allocation e também revoga grants/leases globais:
''',
    '''Revogação avança o `session_epoch` da allocation, remove allocations ainda não entregues do outbox e também revoga grants/leases globais:
''')

replace_once(
    "docs/ROADMAP.md",
    '''### 0.8.5 — VPN allocation / login global 🚧

- login/provisionamento capaz de escolher um nó elegível;
- vínculo entre produto, região/pool, protocolo e lease global;
- sessão criada somente no nó autorizado pelo grant atual;
- `session_epoch`/fencing impedindo nó stale de aceitar retorno antigo;
- suporte a SSH, WireGuard e OpenVPN conforme capacidades do nó.
''',
    '''### 0.8.5 — VPN allocation / login global 🚧

Implementado nesta fase:

- ticket de allocation Ed25519 vinculado a produto, região/pool, protocolo, nó/`node_epoch`, lease global e `session_epoch`;
- exact-grant: sessão só pode reclamar o `global_lease_id` autorizado pelo ticket atual;
- suporte do contrato a SSH, WireGuard e OpenVPN;
- outbox durável no controlador e distribuição automática por pull no mesmo TLS 1.3 pinado da autoridade de leases;
- pull autenticado pela identidade Ed25519 enrolled do nó, com freshness, nonce e fencing de `node_epoch`;
- ACK somente depois do aceite local durável; redelivery é idempotente e não exige nova porta/listener no nó;
- timer de sync no nó e comando manual `manager hive allocation sync` para diagnóstico/recuperação;
- revogação remove bundles ainda não entregues e mantém o controlador fora do caminho de dados VPN.

Ainda pendente para fechar a 0.8.5:

- integrar o provisionamento remoto de recursos/credenciais necessários no nó escolhido quando eles ainda não existirem;
- fechar o fluxo público de login/provisionamento de ponta a ponta e seus gates finais antes de alterar `VERSION`.
''')

workflow = r'''name: Hive VPN Allocation Distribution

on:
  push:
    branches: [main]
  pull_request:

permissions:
  contents: read

jobs:
  hive-vpn-allocation-distribution:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v7

      - name: Install current MANAGER tree
        shell: bash
        run: |
          set -euxo pipefail
          source_url="file://${GITHUB_WORKSPACE}"
          sudo env MANAGER_ALLOW_FILE_SOURCE=1 MANAGER_REPO_RAW="$source_url" bash install.sh
          test "$(sudo cat /opt/manager/VERSION)" = 0.8.4
          sudo test -x /opt/manager/modules/hive_allocations.sh

      - name: Initialize controller and enrolled local node
        shell: bash
        run: |
          set -euxo pipefail
          sudo manager hive controller init >/dev/null
          sudo manager hive lease controller init >/dev/null
          sudo manager hive lease controller enable 127.0.0.1 19445 >/dev/null
          lease_fp="$(sudo manager hive lease controller status | awk -F= '$1=="tls_fingerprint"{print $2}')"
          controller_fp="$(sudo manager hive controller fingerprint)"
          sudo manager hive request /tmp/node.request.json >/dev/null
          sudo manager hive controller approve /tmp/node.request.json /tmp/node.bundle.json >/dev/null
          sudo manager hive accept /tmp/node.bundle.json "$controller_fp" >/dev/null
          sudo manager hive lease node configure 127.0.0.1 19445 "$lease_fp" 30 >/dev/null
          node="$(sudo manager hive status | awk -F= '$1=="node_id"{print $2}')"
          test -n "$node"
          printf '%s\n' "$node" >/tmp/node.id
          sudo manager hive node placement "$node" BR-SP-A BR BR-SP PREMIUM >/dev/null
          sudo mkdir -p /etc/manager/hive/controller/health /var/lib/manager/hive-health/nodes
          cat <<'EOF' | sudo tee /etc/manager/hive/controller/health/controller.conf >/dev/null
          version=1
          degraded_after_seconds=75
          offline_after_seconds=180
          EOF
          now="$(date +%s)"
          sudo python3 - "$now" "$node" <<'PY'
          import json,sys
          now=int(sys.argv[1]); node=sys.argv[2]; conf={}
          with open(f'/etc/manager/hive/controller/nodes/{node}.conf') as f:
              for line in f:
                  if '=' in line:
                      k,v=line.rstrip().split('=',1); conf[k]=v
          obs={'version':1,'node_id':node,'node_epoch':int(conf['node_epoch']),'issued_at':now,'received_at':now,
               'source':'ci','base_state':'HEALTHY','base_reason':'ok',
               'metrics':{'sessions':0,'max_sessions':100,'capacity':10,'weight':1,'previous_rtt_ms':10,
                          'protocols':['ssh','wireguard','openvpn'],'service_ssh':'active',
                          'service_wireguard':'active','service_openvpn':'active'}}
          with open(f'/var/lib/manager/hive-health/nodes/{node}.json','w') as f:
              json.dump(obs,f,sort_keys=True,separators=(',',':'))
          PY
          sudo chmod 600 /var/lib/manager/hive-health/nodes/*.json

      - name: Enable automatic allocation delivery
        shell: bash
        run: |
          set -euxo pipefail
          sudo manager hive allocation enable >/tmp/alloc-enable
          grep -q '^automatic_distribution=1$' /tmp/alloc-enable
          sudo systemctl is-enabled --quiet manager-hive-allocation-sync.timer
          sudo systemctl is-active --quiet manager-hive-allocation-sync.timer
          sudo manager hive allocation status | grep -q '^delivery_transport=lease-control-pull$'
          sudo manager hive allocation controller status | grep -q '^automatic_distribution=1$'
          # Stop (do not disable) for deterministic explicit-pull assertions below.
          sudo systemctl stop manager-hive-allocation-sync.timer

      - name: Queue, pull, validate and ack a signed allocation
        shell: bash
        run: |
          set -euxo pipefail
          id alloc-dist-ssh >/dev/null 2>&1 || sudo useradd -M -s /usr/sbin/nologin alloc-dist-ssh
          sudo /opt/manager/modules/connection_engine.sh --create allocdist '' 0 10 ssh >/dev/null
          sudo /opt/manager/modules/connection_engine.sh --bind allocdist ssh alloc-dist-ssh >/dev/null
          sudo manager hive lease limit set allocdist 1 PREMIUM >/dev/null
          created="$(sudo manager hive allocation controller create allocdist ssh /tmp/allocdist.json BR-SP PREMIUM allocdist '*' 120)"
          grep -q '^distribution_queued=1$' <<<"$created"
          grep -q '^delivery_transport=lease-control-pull$' <<<"$created"
          allocation_id="$(awk -F= '$1=="allocation_id"{print $2}' <<<"$created")"
          node="$(cat /tmp/node.id)"
          test -f "/var/lib/manager/hive-allocations/controller/outbox/$node/$allocation_id.json"
          sync="$(sudo manager hive allocation sync)"
          grep -q '^allocations_pulled=1$' <<<"$sync"
          grep -q '^allocations_accepted=1$' <<<"$sync"
          grep -q '^allocations_acked=1$' <<<"$sync"
          test ! -e "/var/lib/manager/hive-allocations/controller/outbox/$node/$allocation_id.json"
          sudo test -f "/var/lib/manager/hive-allocations/node/active/$allocation_id.json"
          sudo manager hive allocation sync | grep -q '^allocations_pulled=0$'

      - name: Reject tampered controller outbox before ACK
        shell: bash
        run: |
          set -euxo pipefail
          # Release the exact grant used above through a real protocol session first.
          sudo /opt/manager/modules/protocol_leases.sh --observe-connect ssh alloc-dist-ssh dist-device-a 0 ci notty
          sudo /opt/manager/modules/protocol_leases.sh --observe-disconnect ssh dist-device-a
          created="$(sudo manager hive allocation controller create allocdist ssh /tmp/tamper.json BR-SP PREMIUM tamper '*' 120)"
          allocation_id="$(awk -F= '$1=="allocation_id"{print $2}' <<<"$created")"
          node="$(cat /tmp/node.id)"
          outbox="/var/lib/manager/hive-allocations/controller/outbox/$node/$allocation_id.json"
          sudo cp "$outbox" /tmp/tamper.valid.json
          sudo python3 - "$outbox" <<'PY'
          import json,sys
          p=sys.argv[1]; d=json.load(open(p)); d['product_id']='EVIL'
          json.dump(d,open(p,'w'),sort_keys=True,separators=(',',':'))
          PY
          if sudo manager hive allocation sync; then
            echo 'tampered queued allocation was accepted' >&2
            exit 1
          fi
          sudo test -f "$outbox"
          sudo cp /tmp/tamper.valid.json "$outbox"
          sudo chmod 600 "$outbox"
          sudo manager hive allocation sync | grep -q '^allocations_acked=1$'
          test ! -e "$outbox"

      - name: Deliver automatically through the timer
        shell: bash
        run: |
          set -euxo pipefail
          # Consume/release the second allocation so the global slot becomes available again.
          sudo /opt/manager/modules/protocol_leases.sh --observe-connect ssh alloc-dist-ssh dist-device-b 0 ci notty
          sudo /opt/manager/modules/protocol_leases.sh --observe-disconnect ssh dist-device-b
          created="$(sudo manager hive allocation controller create allocdist ssh /tmp/auto.json BR-SP PREMIUM auto '*' 120)"
          allocation_id="$(awk -F= '$1=="allocation_id"{print $2}' <<<"$created")"
          node="$(cat /tmp/node.id)"
          outbox="/var/lib/manager/hive-allocations/controller/outbox/$node/$allocation_id.json"
          sudo test -f "$outbox"
          sudo systemctl start manager-hive-allocation-sync.timer
          for _ in $(seq 1 20); do
            [[ ! -e "$outbox" ]] && break
            sleep 1
          done
          test ! -e "$outbox"
          sudo test -f "/var/lib/manager/hive-allocations/node/active/$allocation_id.json"
          sudo systemctl is-active --quiet manager-hive-allocation-sync.timer

      - name: Revoke undelivered queue and preserve lifecycle state
        shell: bash
        run: |
          set -euxo pipefail
          sudo systemctl stop manager-hive-allocation-sync.timer
          sudo /opt/manager/modules/protocol_leases.sh --observe-connect ssh alloc-dist-ssh dist-device-c 0 ci notty
          sudo /opt/manager/modules/protocol_leases.sh --observe-disconnect ssh dist-device-c
          created="$(sudo manager hive allocation controller create allocdist ssh /tmp/revoke.json BR-SP PREMIUM revoke '*' 120)"
          allocation_id="$(awk -F= '$1=="allocation_id"{print $2}' <<<"$created")"
          node="$(cat /tmp/node.id)"
          outbox="/var/lib/manager/hive-allocations/controller/outbox/$node/$allocation_id.json"
          sudo test -f "$outbox"
          revoke="$(sudo manager hive allocation controller revoke allocdist distribution-revoke)"
          grep -q '^queued_allocations_revoked=1$' <<<"$revoke"
          test ! -e "$outbox"
          sudo /opt/manager/modules/hive_allocations.sh --detach
          sudo test -f /etc/manager/hive/allocations/node.conf
          test ! -e /etc/systemd/system/manager-hive-allocation-sync.timer
          sudo /opt/manager/modules/hive_allocations.sh --install
          sudo systemctl is-enabled --quiet manager-hive-allocation-sync.timer
          sudo systemctl is-active --quiet manager-hive-allocation-sync.timer
'''
Path('.github/workflows/hive-vpn-allocation-distribution.yml').write_text(workflow)
