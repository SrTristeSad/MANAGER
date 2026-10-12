#!/usr/bin/env python3
from pathlib import Path


def replace(path, old, new, count=1):
    p = Path(path)
    text = p.read_text()
    if old not in text:
        raise SystemExit(f"expected block not found in {path}: {old[:120]!r}")
    p.write_text(text.replace(old, new, count))

# 0.8.3 scheduler CI must now expect the 0.8.4 capability markers.
p = Path('.github/workflows/hive-scheduler.yml')
t = p.read_text().replace("^global_lease_authority=0$", "^global_lease_authority=1$")
t = t.replace("grep -q '^global_lease_authority=1$' <<<\"$out\"\n          if sudo manager hive node select invalid-protocol; then",
              "grep -q '^global_lease_authority=1$' <<<\"$out\"\n          grep -q '^global_max_sessions=1$' <<<\"$out\"\n          if sudo manager hive node select invalid-protocol; then")
p.write_text(t)

# Controller/node authority epoch + bounded heartbeat grace.
replace('modules/hive_leases.sh',
'''NODE_CONF = os.path.join(NODE_LEASE_DIR, "node.conf")

DATA_DIR =''',
'''NODE_CONF = os.path.join(NODE_LEASE_DIR, "node.conf")

DATA_DIR =''')
replace('modules/hive_leases.sh',
'''REPLAY_DIR = os.path.join(DATA_DIR, "replay")
LOCK_FILE = os.path.join(DATA_DIR, ".lock")''',
'''REPLAY_DIR = os.path.join(DATA_DIR, "replay")
NODE_AUTH_STATE = os.path.join(DATA_DIR, "node-authority.state")
LOCK_FILE = os.path.join(DATA_DIR, ".lock")''')
replace('modules/hive_leases.sh',
'''                     f"tls_fingerprint={fp}\\ndefault_ttl={DEFAULT_TTL}\\nmax_ttl={DEFAULT_MAX_TTL}\\ncreated_epoch={now}\\nupdated_epoch={now}\\n")''',
'''                     f"tls_fingerprint={fp}\\ndefault_ttl={DEFAULT_TTL}\\nmax_ttl={DEFAULT_MAX_TTL}\\nauthority_epoch=1\\ncreated_epoch={now}\\nupdated_epoch={now}\\n")''')
replace('modules/hive_leases.sh',
'''        "default_ttl": conf.get("default_ttl", str(DEFAULT_TTL)), "max_ttl": conf.get("max_ttl", str(DEFAULT_MAX_TTL)),
    }''',
'''        "default_ttl": conf.get("default_ttl", str(DEFAULT_TTL)), "max_ttl": conf.get("max_ttl", str(DEFAULT_MAX_TTL)),
        "authority_epoch": conf.get("authority_epoch", "1"),
    }''')
replace('modules/hive_leases.sh',
'''                 f"tls_fingerprint={values['tls_fingerprint']}\\ndefault_ttl={values['default_ttl']}\\n"
                 f"max_ttl={values['max_ttl']}\\ncreated_epoch={conf.get('created_epoch',str(now))}\\nupdated_epoch={now}\\n")''',
'''                 f"tls_fingerprint={values['tls_fingerprint']}\\ndefault_ttl={values['default_ttl']}\\n"
                 f"max_ttl={values['max_ttl']}\\nauthority_epoch={values['authority_epoch']}\\n"
                 f"created_epoch={conf.get('created_epoch',str(now))}\\nupdated_epoch={now}\\n")''')
replace('modules/hive_leases.sh',
'''    fp = generate_tls()
    write_controller_conf(conf, enabled=1, bind=bind, port=port, tls_fingerprint=fp)
    write_unit()''',
'''    fp = generate_tls()
    try: authority_epoch = int(conf.get("authority_epoch", "1")) + 1
    except ValueError: authority_epoch = 2
    write_controller_conf(conf, enabled=1, bind=bind, port=port, tls_fingerprint=fp, authority_epoch=authority_epoch)
    write_unit()''')
replace('modules/hive_leases.sh',
'''    print(f"tls_fingerprint={fp}")
    print("controller_in_user_vpn_path=0")''',
'''    print(f"tls_fingerprint={fp}")
    print(f"authority_epoch={authority_epoch}")
    print("controller_in_user_vpn_path=0")''')

replace('modules/hive_leases.sh',
'''def node_configure(host, port, fingerprint):
    enroll, node_id, node_epoch = node_enrollment()
    host = validate_host(host); port = validate_port(port); fingerprint = validate_fp(fingerprint)
    ensure_dir(NODE_LEASE_DIR)
    now = int(time.time())
    atomic_write(NODE_CONF,
                 f"version=1\\nenabled=1\\nnode_id={node_id}\\nnode_epoch={node_epoch}\\ncontroller_id={enroll.get('controller_id','')}\\n"
                 f"host={host}\\nport={port}\\ntls_fingerprint={fingerprint}\\nupdated_epoch={now}\\n")
    print("global_lease_enforcement=1")
    print(f"host={host}")
    print(f"port={port}")
    print(f"tls_fingerprint={fingerprint}")
    print("failure_mode=fail-closed")''',
'''def node_configure(host, port, fingerprint, grace_seconds=30):
    enroll, node_id, node_epoch = node_enrollment()
    host = validate_host(host); port = validate_port(port); fingerprint = validate_fp(fingerprint)
    try: grace_seconds = int(grace_seconds)
    except (TypeError, ValueError): die("grace_seconds inválido.", 64)
    if grace_seconds < 0 or grace_seconds > 120:
        die("grace_seconds deve ficar entre 0 e 120.", 64)
    ensure_dir(NODE_LEASE_DIR)
    now = int(time.time())
    atomic_write(NODE_CONF,
                 f"version=1\\nenabled=1\\nnode_id={node_id}\\nnode_epoch={node_epoch}\\ncontroller_id={enroll.get('controller_id','')}\\n"
                 f"host={host}\\nport={port}\\ntls_fingerprint={fingerprint}\\ngrace_seconds={grace_seconds}\\nupdated_epoch={now}\\n")
    print("global_lease_enforcement=1")
    print(f"host={host}")
    print(f"port={port}")
    print(f"tls_fingerprint={fingerprint}")
    print(f"grace_seconds={grace_seconds}")
    print("new_grants_failure_mode=fail-closed")''')
replace('modules/hive_leases.sh',
'''                     f"controller_id={conf.get('controller_id','')}\\nhost={conf.get('host','')}\\nport={conf.get('port','')}\\n"
                     f"tls_fingerprint={conf.get('tls_fingerprint','')}\\nupdated_epoch={int(time.time())}\\n")''',
'''                     f"controller_id={conf.get('controller_id','')}\\nhost={conf.get('host','')}\\nport={conf.get('port','')}\\n"
                     f"tls_fingerprint={conf.get('tls_fingerprint','')}\\ngrace_seconds={conf.get('grace_seconds','30')}\\nupdated_epoch={int(time.time())}\\n")''')

# Bind global policy to the assigned product when imported/synced.
replace('modules/hive_leases.sh',
'''def set_limit(identity_id, max_sessions, source="manual"):
    init_dirs(); validate_identity(identity_id)''',
'''def set_limit(identity_id, max_sessions, source="manual", product_id=""):
    init_dirs(); validate_identity(identity_id)''')
replace('modules/hive_leases.sh',
'''    if source not in {"manual", "local-import"}:
        source = "manual"
    now = int(time.time()); current = read_conf(limit_path(identity_id))
    atomic_write(limit_path(identity_id),
                 f"version=1\\nidentity_id={identity_id}\\nmax_sessions_global={maximum}\\nsource={source}\\n"
                 f"created_epoch={current.get('created_epoch',str(now))}\\nupdated_epoch={now}\\n")''',
'''    if source not in {"manual", "local-import"}:
        source = "manual"
    if product_id and not IDENTITY_RE.fullmatch(product_id):
        die("product_id inválido.", 64)
    now = int(time.time()); current = read_conf(limit_path(identity_id))
    atomic_write(limit_path(identity_id),
                 f"version=1\\nidentity_id={identity_id}\\nproduct_id={product_id}\\nmax_sessions_global={maximum}\\nsource={source}\\n"
                 f"created_epoch={current.get('created_epoch',str(now))}\\nupdated_epoch={now}\\n")''')
replace('modules/hive_leases.sh',
'''    print(f"max_sessions_global={maximum}")
    print(f"source={source}")''',
'''    print(f"product_id={product_id}")
    print(f"max_sessions_global={maximum}")
    print(f"source={source}")''')
replace('modules/hive_leases.sh',
'''    maximum = conf.get("max_sessions", "")
    if not maximum.isdigit() or int(maximum) < 1:
        die("Identidade local não existe ou possui max_sessions inválido.", 66)
    set_limit(identity_id, maximum, "local-import")''',
'''    maximum = conf.get("max_sessions", "")
    if not maximum.isdigit() or int(maximum) < 1:
        die("Identidade local não existe ou possui max_sessions inválido.", 66)
    assignment = read_conf(os.path.join(MANAGER_ETC, "connection", "products", "assignments", identity_id + ".conf"))
    set_limit(identity_id, maximum, "local-import", assignment.get("product_id", ""))''')
replace('modules/hive_leases.sh',
'''                    set_limit(ident, maximum, "local-import"); count += 1''',
'''                    assignment = read_conf(os.path.join(MANAGER_ETC, "connection", "products", "assignments", ident + ".conf"))
                    set_limit(ident, maximum, "local-import", assignment.get("product_id", "")); count += 1''')
replace('modules/hive_leases.sh',
'''    for key in ("identity_id", "max_sessions_global", "source", "created_epoch", "updated_epoch"):
        print(f"{key}={conf.get(key,'')}")''',
'''    for key in ("identity_id", "product_id", "max_sessions_global", "source", "created_epoch", "updated_epoch"):
        print(f"{key}={conf.get(key,'')}")''')
replace('modules/hive_leases.sh',
'''    print("identity_id|max_sessions_global|source|updated_epoch")''',
'''    print("identity_id|product_id|max_sessions_global|source|updated_epoch")''')
replace('modules/hive_leases.sh',
'''            print("|".join([conf.get("identity_id", path.stem), conf.get("max_sessions_global", ""),
                            conf.get("source", ""), conf.get("updated_epoch", "")]))''',
'''            print("|".join([conf.get("identity_id", path.stem), conf.get("product_id", ""), conf.get("max_sessions_global", ""),
                            conf.get("source", ""), conf.get("updated_epoch", "")]))''')

# Reserved grants: scheduler selection + global capacity reservation happen under one controller authority.
replace('modules/hive_leases.sh',
'''def acquire_locked(node_id, node_epoch, params):
    identity_id, local_session_id, protocol, resource, device, ttl = parse_params(params, True)
    maximum, _ = get_limit(identity_id)
    if maximum < 1:
        raise LeaseError(67, "no-global-policy")
    cleanup_locked()
    path, existing = find_local_locked(node_id, local_session_id)
    now = int(time.time())''',
'''def acquire_locked(node_id, node_epoch, params):
    identity_id, local_session_id, protocol, resource, device, ttl = parse_params(params, True)
    maximum, policy = get_limit(identity_id)
    if maximum < 1:
        raise LeaseError(67, "no-global-policy")
    cleanup_locked()
    path, existing = find_local_locked(node_id, local_session_id)
    now = int(time.time())''')
replace('modules/hive_leases.sh',
'''    active = active_count_locked(identity_id)
    if active >= maximum:''',
'''    # A grant reserved by this controller can be claimed only by its selected node/protocol/device.
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
            atomic_write(str(reserved_path), json.dumps(reserved, sort_keys=True, separators=(",", ":")) + "\\n")
            audit("grant-claim", identity_id=identity_id, node_id=node_id, global_lease_id=reserved.get("global_lease_id"),
                  local_session_id=local_session_id)
            return reserved
    active = active_count_locked(identity_id)
    if active >= maximum:''')
replace('modules/hive_leases.sh',
'''        "max_sessions_global": maximum,
    }''',
'''        "max_sessions_global": maximum, "product_id": policy.get("product_id", ""), "lease_state": "active",
    }''')

replace('modules/hive_leases.sh',
'''def controller_revoke(identity_id, reason="admin"):
''',
'''def controller_grant(identity_id, protocol, region="", pool="", sticky="", node_scope="*", device="grant", ttl=DEFAULT_TTL):
    init_dirs(); identity_id = validate_identity(identity_id)
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
        atomic_write(lease_path(global_id), json.dumps(lease, sort_keys=True, separators=(",", ":")) + "\\n")
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
''')

# Authority epoch travels in every response and nodes fence an older returned authority.
replace('modules/hive_leases.sh',
'''def response(ok, code, result=None, error=None):
    return {"contract": RESP_CONTRACT, "version": VERSION, "ok": bool(ok), "code": int(code),
            "result": result if isinstance(result, dict) else {}, "error": error or ""}''',
'''def response(ok, code, result=None, error=None):
    conf = read_conf(CTRL_LEASE_CONF)
    try: authority_epoch = int(conf.get("authority_epoch", "1"))
    except ValueError: authority_epoch = 1
    return {"contract": RESP_CONTRACT, "version": VERSION, "authority_epoch": authority_epoch,
            "ok": bool(ok), "code": int(code), "result": result if isinstance(result, dict) else {}, "error": error or ""}''')
replace('modules/hive_leases.sh',
'''    if answer.get("contract") != RESP_CONTRACT or answer.get("version") != VERSION:
        die("Contrato de resposta da autoridade global inválido.", 70)
    if not answer.get("ok"):
''',
'''    if answer.get("contract") != RESP_CONTRACT or answer.get("version") != VERSION:
        die("Contrato de resposta da autoridade global inválido.", 70)
    try: authority_epoch = int(answer.get("authority_epoch", 0))
    except (TypeError, ValueError): authority_epoch = 0
    state = read_conf(NODE_AUTH_STATE)
    try: seen_authority = int(state.get("authority_epoch", "0"))
    except ValueError: seen_authority = 0
    if authority_epoch < 1 or authority_epoch < seen_authority:
        die("Autoridade global antiga/fenced tentou retornar.", 70)
    if authority_epoch > seen_authority:
        atomic_write(NODE_AUTH_STATE, f"authority_epoch={authority_epoch}\\nupdated_epoch={int(time.time())}\\n")
    if not answer.get("ok"):
''')

replace('modules/hive_leases.sh',
'''    print("authority_auth=ed25519-enrolled-node")
    print("transport=tls1.3-pinned")''',
'''    print("authority_auth=ed25519-enrolled-node")
    print("transport=tls1.3-pinned")
    print("global_grant_capability=1")
    print("authority_epoch_fencing=1")
    print("bounded_existing_session_grace=1")''')
replace('modules/hive_leases.sh',
'''    print(f"tls_fingerprint={conf.get('tls_fingerprint','')}")
    print("global_lease_authority=1")''',
'''    print(f"tls_fingerprint={conf.get('tls_fingerprint','')}")
    print(f"authority_epoch={conf.get('authority_epoch','1')}")
    print("global_lease_authority=1")''')
replace('modules/hive_leases.sh',
'''    print(f"tls_fingerprint={conf.get('tls_fingerprint','')}")
    print("failure_mode=fail-closed")''',
'''    print(f"tls_fingerprint={conf.get('tls_fingerprint','')}")
    print(f"grace_seconds={conf.get('grace_seconds','30')}")
    print("new_grants_failure_mode=fail-closed")''')

replace('modules/hive_leases.sh',
'''    print("Uso: hive_leases.sh {--status|--node-status|--node-configure HOST PORT FP|--node-disable|--controller-init|--controller-status|--controller-enable BIND [PORT]|--controller-disable|--controller-rotate-tls|--limit-set ID MAX|--limit-import-local ID|--limit-sync-local|--limit-show ID|--limit-list|--limit-unset ID|--controller-list [ID]|--controller-revoke ID [REASON]|--acquire-node ID PROTO RESOURCE DEVICE SESSION [TTL]|--heartbeat-node ID SESSION [TTL]|--release-node ID SESSION|--serve-controller|--install|--detach|--purge}", file=sys.stderr)''',
'''    print("Uso: hive_leases.sh {--status|--node-status|--node-configure HOST PORT FP [GRACE]|--node-disable|--controller-init|--controller-status|--controller-enable BIND [PORT]|--controller-disable|--controller-rotate-tls|--controller-grant ID PROTO [REGION] [POOL] [STICKY] [SCOPE] [DEVICE] [TTL]|--limit-set ID MAX [PRODUCT]|--limit-import-local ID|--limit-sync-local|--limit-show ID|--limit-list|--limit-unset ID|--controller-list [ID]|--controller-revoke ID [REASON]|--acquire-node ID PROTO RESOURCE DEVICE SESSION [TTL]|--heartbeat-node ID SESSION [TTL]|--release-node ID SESSION|--serve-controller|--install|--detach|--purge}", file=sys.stderr)''')
replace('modules/hive_leases.sh',
'''    if cmd == "--node-configure" and len(argv) == 4: node_configure(argv[1], argv[2], argv[3]); return''',
'''    if cmd == "--node-configure" and len(argv) in {4,5}: node_configure(argv[1], argv[2], argv[3], argv[4] if len(argv) == 5 else 30); return''')
replace('modules/hive_leases.sh',
'''    if cmd == "--controller-rotate-tls": controller_rotate_tls(); return
    if cmd == "--limit-set" and len(argv) == 3: set_limit(argv[1], argv[2]); return''',
'''    if cmd == "--controller-rotate-tls": controller_rotate_tls(); return
    if cmd == "--controller-grant" and 3 <= len(argv) <= 9:
        controller_grant(argv[1], argv[2], argv[3] if len(argv)>3 else "", argv[4] if len(argv)>4 else "",
                         argv[5] if len(argv)>5 else "", argv[6] if len(argv)>6 else "*",
                         argv[7] if len(argv)>7 else "grant", argv[8] if len(argv)>8 else DEFAULT_TTL); return
    if cmd == "--limit-set" and len(argv) in {3,4}: set_limit(argv[1], argv[2], "manual", argv[3] if len(argv)==4 else ""); return''')

# Protocol bridge: only availability failure gets bounded grace; explicit denial/fencing terminates immediately.
replace('modules/protocol_leases.sh',
'''global_lease_heartbeat() {
  local identity="$1" session_id="$2"
  global_lease_enabled || return 0
  [[ -x "$GLOBAL_LEASE_MODULE" ]] || return 69
  "$GLOBAL_LEASE_MODULE" --heartbeat-node "$identity" "$session_id" "$LEASE_TTL" >/dev/null
}
''',
'''global_lease_grace_seconds() {
  local grace
  grace="$(awk -F= '$1=="grace_seconds" {print $2; exit}' "$GLOBAL_LEASE_CONF" 2>/dev/null || true)"
  [[ "$grace" =~ ^[0-9]+$ ]] || grace=30
  (( grace <= 120 )) || grace=120
  printf '%s\\n' "$grace"
}

global_lease_heartbeat() {
  local identity="$1" session_id="$2"
  global_lease_enabled || return 0
  [[ -x "$GLOBAL_LEASE_MODULE" ]] || return 69
  "$GLOBAL_LEASE_MODULE" --heartbeat-node "$identity" "$session_id" "$LEASE_TTL" >/dev/null
}
''')
replace('modules/protocol_leases.sh',
'''    printf 'created_epoch=%s\\n' "$now"
    printf 'source_pid=%s\\n' "$source_pid"''',
'''    printf 'created_epoch=%s\\n' "$now"
    printf 'global_heartbeat_epoch=%s\\n' "$now"
    printf 'source_pid=%s\\n' "$source_pid"''')
replace('modules/protocol_leases.sh',
'''  local file="$1" session_id epoch token new_epoch identity
''',
'''  local file="$1" session_id epoch token new_epoch identity rc=0 last_global=0 now grace=0
''')
replace('modules/protocol_leases.sh',
'''    if ! global_lease_heartbeat "$identity" "$session_id"; then
      "$SESSION_ENGINE" --release "$session_id" "$epoch" >/dev/null 2>&1 || true
      rm -f "$file"
      return 1
    fi
    new_epoch="$(token_value "$token" epoch)"''',
'''    global_lease_heartbeat "$identity" "$session_id" || rc=$?
    if (( rc != 0 )); then
      if (( rc == 69 )); then
        last_global="$(map_read_file "$file" global_heartbeat_epoch)"
        [[ "$last_global" =~ ^[0-9]+$ ]] || last_global=0
        now="$(date +%s)"; grace="$(global_lease_grace_seconds)"
        if (( grace > 0 && last_global > 0 && now - last_global <= grace )); then
          return 0
        fi
      fi
      "$SESSION_ENGINE" --release "$session_id" "$epoch" >/dev/null 2>&1 || true
      rm -f "$file"
      return 1
    fi
    sed -i "s/^global_heartbeat_epoch=.*/global_heartbeat_epoch=$(date +%s)/" "$file"
    new_epoch="$(token_value "$token" epoch)"''')

# Public CLI for grace, grants and product-bound policies.
replace('manager',
'''  manager hive lease node status|configure HOST PORT TLS_FP|disable
  manager hive lease controller init|status|enable BIND_IP [PORT]|disable|rotate-tls
  manager hive lease controller list [ID]
  manager hive lease controller revoke ID [REASON]
  manager hive lease limit set ID MAX|import-local ID|sync-local|show ID|list|unset ID
''',
'''  manager hive lease node status|configure HOST PORT TLS_FP [GRACE]|disable
  manager hive lease controller init|status|enable BIND_IP [PORT]|disable|rotate-tls
  manager hive lease controller grant ID PROTO [REGION] [POOL] [STICKY] [SCOPE] [DEVICE] [TTL]
  manager hive lease controller list [ID]
  manager hive lease controller revoke ID [REASON]
  manager hive lease limit set ID MAX [PRODUCT]|import-local ID|sync-local|show ID|list|unset ID
''')
replace('manager',
'''              configure) [[ -n "${5:-}" && -n "${6:-}" && -n "${7:-}" ]] || { err "Uso: manager hive lease node configure HOST PORT TLS_FP"; exit 64; }; exec "$MANAGER_HOME/modules/hive_leases.sh" --node-configure "$5" "$6" "$7" ;;''',
'''              configure) [[ -n "${5:-}" && -n "${6:-}" && -n "${7:-}" ]] || { err "Uso: manager hive lease node configure HOST PORT TLS_FP [GRACE]"; exit 64; }; exec "$MANAGER_HOME/modules/hive_leases.sh" --node-configure "$5" "$6" "$7" "${8:-30}" ;;''')
replace('manager',
'''              rotate-tls) exec "$MANAGER_HOME/modules/hive_leases.sh" --controller-rotate-tls ;;
              list) exec "$MANAGER_HOME/modules/hive_leases.sh" --controller-list "${5:-}" ;;''',
'''              rotate-tls) exec "$MANAGER_HOME/modules/hive_leases.sh" --controller-rotate-tls ;;
              grant) [[ -n "${5:-}" && -n "${6:-}" ]] || { err "Uso: manager hive lease controller grant ID PROTO [REGION] [POOL] [STICKY] [SCOPE] [DEVICE] [TTL]"; exit 64; }; exec "$MANAGER_HOME/modules/hive_leases.sh" --controller-grant "$5" "$6" "${7:-}" "${8:-}" "${9:-}" "${10:-*}" "${11:-grant}" "${12:-60}" ;;
              list) exec "$MANAGER_HOME/modules/hive_leases.sh" --controller-list "${5:-}" ;;''')
replace('manager',
'''              set) [[ -n "${5:-}" && -n "${6:-}" ]] || { err "Uso: manager hive lease limit set ID MAX"; exit 64; }; exec "$MANAGER_HOME/modules/hive_leases.sh" --limit-set "$5" "$6" ;;''',
'''              set) [[ -n "${5:-}" && -n "${6:-}" ]] || { err "Uso: manager hive lease limit set ID MAX [PRODUCT]"; exit 64; }; exec "$MANAGER_HOME/modules/hive_leases.sh" --limit-set "$5" "$6" "${7:-}" ;;''')

print('0.8.4 authority completion patch applied')
