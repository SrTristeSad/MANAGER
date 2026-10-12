from pathlib import Path


def replace_once(path, old, new):
    p = Path(path)
    s = p.read_text()
    if new in s:
        return
    if old not in s:
        raise SystemExit(f"anchor missing in {path}: {old[:120]!r}")
    p.write_text(s.replace(old, new, 1))

# modules/hive_leases.sh
p = Path('modules/hive_leases.sh')
s = p.read_text()
s = s.replace(
    'NODE_AUTH_STATE = os.path.join(DATA_DIR, "node-authority.state")\nLOCK_FILE = os.path.join(DATA_DIR, ".lock")',
    'NODE_AUTH_STATE = os.path.join(DATA_DIR, "node-authority.state")\nNODE_AUTH_LOCK = os.path.join(DATA_DIR, ".node-authority.lock")\nLOCK_FILE = os.path.join(DATA_DIR, ".lock")',
    1,
)
anchor = '''    return conf, node_id, epoch\n\n\ndef controller_node(node_id):\n'''
helpers = '''    return conf, node_id, epoch\n\n\ndef authority_state_snapshot(controller_id=""):\n    raw = read_conf(NODE_AUTH_STATE)\n    stored_controller = raw.get("controller_id", "")\n    if controller_id and stored_controller and stored_controller != controller_id:\n        raw = {}\n    def integer(key):\n        try: return max(0, int(raw.get(key, "0")))\n        except (TypeError, ValueError): return 0\n    state = raw.get("state", "unknown")\n    if state not in {"unknown", "healthy", "outage", "fenced"}:\n        state = "unknown"\n    return {\n        "controller_id": controller_id or stored_controller,\n        "authority_epoch": integer("authority_epoch"),\n        "state": state,\n        "last_success_epoch": integer("last_success_epoch"),\n        "outage_started_epoch": integer("outage_started_epoch"),\n        "last_transport_failure_epoch": integer("last_transport_failure_epoch"),\n        "last_recovery_epoch": integer("last_recovery_epoch"),\n        "recovery_count": integer("recovery_count"),\n        "last_fenced_epoch": integer("last_fenced_epoch"),\n        "returned_authority_epoch": integer("returned_authority_epoch"),\n    }\n\n\ndef write_authority_state_locked(state):\n    now = int(time.time())\n    atomic_write(NODE_AUTH_STATE,\n                 f"version=1\\ncontroller_id={state.get('controller_id','')}\\n"\n                 f"authority_epoch={int(state.get('authority_epoch',0))}\\nstate={state.get('state','unknown')}\\n"\n                 f"last_success_epoch={int(state.get('last_success_epoch',0))}\\n"\n                 f"outage_started_epoch={int(state.get('outage_started_epoch',0))}\\n"\n                 f"last_transport_failure_epoch={int(state.get('last_transport_failure_epoch',0))}\\n"\n                 f"last_recovery_epoch={int(state.get('last_recovery_epoch',0))}\\n"\n                 f"recovery_count={int(state.get('recovery_count',0))}\\n"\n                 f"last_fenced_epoch={int(state.get('last_fenced_epoch',0))}\\n"\n                 f"returned_authority_epoch={int(state.get('returned_authority_epoch',0))}\\n"\n                 f"updated_epoch={now}\\n")\n\n\ndef authority_state_update(controller_id, mutator):\n    ensure_dir(DATA_DIR)\n    Path(NODE_AUTH_LOCK).touch(mode=0o600, exist_ok=True)\n    os.chmod(NODE_AUTH_LOCK, 0o600)\n    with open(NODE_AUTH_LOCK, "r+") as lock:\n        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)\n        state = authority_state_snapshot(controller_id)\n        before = dict(state)\n        mutator(state)\n        write_authority_state_locked(state)\n        fcntl.flock(lock.fileno(), fcntl.LOCK_UN)\n    return before, state\n\n\ndef authority_seen_epoch(controller_id):\n    return int(authority_state_snapshot(controller_id).get("authority_epoch", 0))\n\n\ndef authority_mark_outage(node_id, controller_id):\n    now = int(time.time())\n    def mutate(state):\n        if state.get("state") != "fenced":\n            if int(state.get("outage_started_epoch", 0)) <= 0:\n                state["outage_started_epoch"] = now\n            state["state"] = "outage"\n        state["last_transport_failure_epoch"] = now\n    before, after = authority_state_update(controller_id, mutate)\n    if before.get("state") not in {"outage", "fenced"}:\n        audit("node-authority-outage", node_id=node_id, controller_id=controller_id,\n              authority_epoch=after.get("authority_epoch", 0), outage_started_epoch=after.get("outage_started_epoch", 0))\n\n\ndef authority_mark_success(node_id, controller_id, authority_epoch):\n    now = int(time.time())\n    def mutate(state):\n        previous = state.get("state", "unknown")\n        recovered = previous in {"outage", "fenced"}\n        state["controller_id"] = controller_id\n        state["authority_epoch"] = max(int(state.get("authority_epoch", 0)), int(authority_epoch))\n        state["state"] = "healthy"\n        state["last_success_epoch"] = now\n        state["outage_started_epoch"] = 0\n        state["returned_authority_epoch"] = int(authority_epoch)\n        if recovered:\n            state["last_recovery_epoch"] = now\n            state["recovery_count"] = int(state.get("recovery_count", 0)) + 1\n    before, after = authority_state_update(controller_id, mutate)\n    if before.get("state") in {"outage", "fenced"}:\n        audit("node-authority-recovered", node_id=node_id, controller_id=controller_id,\n              authority_epoch=authority_epoch, previous_state=before.get("state"),\n              recovery_count=after.get("recovery_count", 0))\n\n\ndef authority_mark_fenced(node_id, controller_id, returned_epoch, seen_epoch):\n    now = int(time.time())\n    def mutate(state):\n        state["controller_id"] = controller_id\n        state["authority_epoch"] = max(int(state.get("authority_epoch", 0)), int(seen_epoch))\n        state["state"] = "fenced"\n        state["last_fenced_epoch"] = now\n        state["returned_authority_epoch"] = max(0, int(returned_epoch))\n    before, after = authority_state_update(controller_id, mutate)\n    if before.get("state") != "fenced" or int(before.get("returned_authority_epoch", 0)) != int(returned_epoch):\n        audit("node-authority-fenced", node_id=node_id, controller_id=controller_id,\n              seen_authority_epoch=seen_epoch, returned_authority_epoch=returned_epoch)\n\n\ndef controller_node(node_id):\n'''
if 'def authority_state_snapshot(' not in s:
    if anchor not in s:
        raise SystemExit('authority helper anchor missing')
    s = s.replace(anchor, helpers, 1)

old_handler = '''            if action == "acquire": result = acquire_locked(node_id, node_epoch, params)\n            elif action == "heartbeat": result = heartbeat_locked(node_id, node_epoch, params)\n            elif action == "release": result = release_locked(node_id, params)\n            elif action == "usage_ingest": result = usage_ingest_locked(node_id, node_epoch, params)\n'''
new_handler = '''            if action == "acquire": result = acquire_locked(node_id, node_epoch, params)\n            elif action == "heartbeat": result = heartbeat_locked(node_id, node_epoch, params)\n            elif action == "release": result = release_locked(node_id, params)\n            elif action == "probe":\n                ctrl = controller_identity()\n                result = {"node_id": node_id, "node_epoch": node_epoch,\n                          "controller_id": ctrl.get("controller_id", ""), "server_epoch": int(time.time())}\n            elif action == "usage_ingest": result = usage_ingest_locked(node_id, node_epoch, params)\n'''
if 'elif action == "probe":' not in s:
    if old_handler not in s:
        raise SystemExit('request handler anchor missing')
    s = s.replace(old_handler, new_handler, 1)

old_except = '''    except (OSError, ssl.SSLError, socket.timeout):\n        die("Autoridade global de leases indisponível; acesso recusado em fail-closed.", 69)\n'''
new_except = '''    except (OSError, ssl.SSLError, socket.timeout):\n        authority_mark_outage(node_id, conf.get("controller_id", enroll.get("controller_id", "")))\n        die("Autoridade global de leases indisponível; acesso recusado em fail-closed.", 69)\n'''
if new_except not in s:
    if old_except not in s:
        raise SystemExit('transport failure anchor missing')
    s = s.replace(old_except, new_except, 1)

old_epoch = '''    state = read_conf(NODE_AUTH_STATE)\n    try: seen_authority = int(state.get("authority_epoch", "0"))\n    except ValueError: seen_authority = 0\n    if authority_epoch < 1 or authority_epoch < seen_authority:\n        die("Autoridade global antiga/fenced tentou retornar.", 70)\n    if authority_epoch > seen_authority:\n        atomic_write(NODE_AUTH_STATE, f"authority_epoch={authority_epoch}\\nupdated_epoch={int(time.time())}\\n")\n    if not answer.get("ok"):\n'''
new_epoch = '''    controller_id = conf.get("controller_id", enroll.get("controller_id", ""))\n    seen_authority = authority_seen_epoch(controller_id)\n    if authority_epoch < 1 or authority_epoch < seen_authority:\n        authority_mark_fenced(node_id, controller_id, authority_epoch, seen_authority)\n        die("Autoridade global antiga/fenced tentou retornar.", 70)\n    authority_mark_success(node_id, controller_id, authority_epoch)\n    if not answer.get("ok"):\n'''
if new_epoch not in s:
    if old_epoch not in s:
        raise SystemExit('authority epoch response anchor missing')
    s = s.replace(old_epoch, new_epoch, 1)

probe_anchor = '''    return answer.get("result", {})\n\n\ndef node_acquire(identity_id, protocol, resource, device, local_session_id, ttl, global_lease_id=""):\n'''
probe_code = '''    return answer.get("result", {})\n\n\ndef node_probe():\n    result = node_request("probe", {})\n    conf = read_conf(NODE_CONF)\n    state = authority_state_snapshot(conf.get("controller_id", ""))\n    print("contract=manager-hive-authority-recovery-v1")\n    print("authority_reachable=1")\n    print(f"authority_state={state.get('state','unknown')}")\n    print(f"seen_authority_epoch={state.get('authority_epoch',0)}")\n    print(f"last_success_epoch={state.get('last_success_epoch',0)}")\n    print(f"last_recovery_epoch={state.get('last_recovery_epoch',0)}")\n    print(f"recovery_count={state.get('recovery_count',0)}")\n    print(f"controller_id={result.get('controller_id','')}")\n    print(f"node_id={result.get('node_id','')}")\n\n\ndef node_acquire(identity_id, protocol, resource, device, local_session_id, ttl, global_lease_id=""):\n'''
if 'def node_probe():' not in s:
    if probe_anchor not in s:
        raise SystemExit('node probe anchor missing')
    s = s.replace(probe_anchor, probe_code, 1)

status_old = '''    print(f"tls_fingerprint={conf.get('tls_fingerprint','')}")\n    print(f"grace_seconds={conf.get('grace_seconds','30')}")\n    print("new_grants_failure_mode=fail-closed")\n\n\ndef install():\n'''
status_new = '''    print(f"tls_fingerprint={conf.get('tls_fingerprint','')}")\n    print(f"grace_seconds={conf.get('grace_seconds','30')}")\n    state = authority_state_snapshot(conf.get("controller_id", ""))\n    print(f"authority_state={state.get('state','unknown')}")\n    print(f"seen_authority_epoch={state.get('authority_epoch',0)}")\n    print(f"last_success_epoch={state.get('last_success_epoch',0)}")\n    print(f"outage_started_epoch={state.get('outage_started_epoch',0)}")\n    print(f"last_transport_failure_epoch={state.get('last_transport_failure_epoch',0)}")\n    print(f"last_recovery_epoch={state.get('last_recovery_epoch',0)}")\n    print(f"recovery_count={state.get('recovery_count',0)}")\n    print(f"last_fenced_epoch={state.get('last_fenced_epoch',0)}")\n    print(f"returned_authority_epoch={state.get('returned_authority_epoch',0)}")\n    print("new_grants_failure_mode=fail-closed")\n    print("existing_session_outage_policy=bounded-grace")\n    print("recovery_fencing=authority-epoch")\n\n\ndef install():\n'''
if 'existing_session_outage_policy=bounded-grace' not in s:
    if status_old not in s:
        raise SystemExit('node status anchor missing')
    s = s.replace(status_old, status_new, 1)

s = s.replace(
    '--status|--node-status|--node-configure HOST PORT FP [GRACE]|--node-disable|',
    '--status|--node-status|--node-probe|--node-configure HOST PORT FP [GRACE]|--node-disable|',
    1,
)
main_old = '''    if cmd == "--node-status": node_status(); return\n    if cmd == "--node-configure" and len(argv) in {4,5}: node_configure(argv[1], argv[2], argv[3], argv[4] if len(argv) == 5 else 30); return\n'''
main_new = '''    if cmd == "--node-status": node_status(); return\n    if cmd == "--node-probe" and len(argv) == 1: node_probe(); return\n    if cmd == "--node-configure" and len(argv) in {4,5}: node_configure(argv[1], argv[2], argv[3], argv[4] if len(argv) == 5 else 30); return\n'''
if 'if cmd == "--node-probe"' not in s:
    if main_old not in s:
        raise SystemExit('main node probe anchor missing')
    s = s.replace(main_old, main_new, 1)
p.write_text(s)

# manager CLI
p = Path('manager')
s = p.read_text()
s = s.replace(
    'manager hive lease node status|configure HOST PORT TLS_FP [GRACE]|disable',
    'manager hive lease node status|probe|configure HOST PORT TLS_FP [GRACE]|disable',
    1,
)
old = '''              status) exec "$MANAGER_HOME/modules/hive_leases.sh" --node-status ;;\n              configure) [[ -n "${5:-}" && -n "${6:-}" && -n "${7:-}" ]] || { err "Uso: manager hive lease node configure HOST PORT TLS_FP [GRACE]"; exit 64; }; exec "$MANAGER_HOME/modules/hive_leases.sh" --node-configure "$5" "$6" "$7" "${8:-30}" ;;\n              disable) exec "$MANAGER_HOME/modules/hive_leases.sh" --node-disable ;;\n              *) err "Uso: manager hive lease node {status|configure|disable}"; exit 64 ;;\n'''
new = '''              status) exec "$MANAGER_HOME/modules/hive_leases.sh" --node-status ;;\n              probe) exec "$MANAGER_HOME/modules/hive_leases.sh" --node-probe ;;\n              configure) [[ -n "${5:-}" && -n "${6:-}" && -n "${7:-}" ]] || { err "Uso: manager hive lease node configure HOST PORT TLS_FP [GRACE]"; exit 64; }; exec "$MANAGER_HOME/modules/hive_leases.sh" --node-configure "$5" "$6" "$7" "${8:-30}" ;;\n              disable) exec "$MANAGER_HOME/modules/hive_leases.sh" --node-disable ;;\n              *) err "Uso: manager hive lease node {status|probe|configure|disable}"; exit 64 ;;\n'''
if 'probe) exec "$MANAGER_HOME/modules/hive_leases.sh" --node-probe' not in s:
    if old not in s:
        raise SystemExit('manager lease node CLI anchor missing')
    s = s.replace(old, new, 1)
p.write_text(s)

# docs/ROADMAP.md
p = Path('docs/ROADMAP.md')
s = p.read_text()
header = '''### 0.8.7 — failover e resiliência operacional\n\n- controlador fora do caminho de dados VPN;\n'''
replacement = '''### 0.8.7 — failover e resiliência operacional\n\nFundação implementada nesta fase:\n\n- estado operacional persistente da autoridade no nó (`healthy`, `outage`, `fenced`) sem transformar o controlador em caminho de dados;\n- `last_success_epoch`, início da outage, última falha de transporte e contadores de recovery preservados em estado root-only;\n- `manager hive lease node probe` reutiliza o mesmo envelope Ed25519 + TLS 1.3 pinado para testar autoridade e fechar recovery;\n- falha de transporte marca outage e mantém novos grants fail-closed; resposta autoritativa válida fecha a outage e registra recovery;\n- retorno de `authority_epoch` menor que o maior já observado marca o nó como `fenced` e continua fail-closed;\n- estado de recovery é diagnóstico/controle e não carrega tráfego VPN de usuário.\n\nCritérios da fase:\n\n- controlador fora do caminho de dados VPN;\n'''
if 'Fundação implementada nesta fase:' not in s:
    if header not in s:
        raise SystemExit('ROADMAP 0.8.7 anchor missing')
    s = s.replace(header, replacement, 1)
p.write_text(s)

# docs/HIVE.md
p = Path('docs/HIVE.md')
s = p.read_text()
section = '''\n\n## 22. Resiliência operacional — fundação 0.8.7\n\nA autoridade global continua fora do caminho de dados VPN. A 0.8.7 torna explícito no nó o estado operacional do control plane sem criar uma segunda autoridade.\n\n```bash\nmanager hive lease node status\nmanager hive lease node probe\n```\n\nO probe usa o mesmo contrato autenticado das leases: identidade Ed25519 enrolled do nó, `node_epoch`, timestamp/nonce, TLS 1.3 e pin SHA-256. Ele não abre nova porta e não envia tráfego VPN pelo controlador.\n\nO estado persistente em `/var/lib/manager/hive-leases/node-authority.state` registra o maior `authority_epoch` aceito, último sucesso, início da outage, última falha de transporte, último recovery e eventos de fencing. O arquivo permanece root-only e é preservado em uninstall/reinstall normal.\n\nSemântica operacional:\n\n- falha de transporte: `authority_state=outage`; novas admissões continuam fail-closed;\n- sessão já válida: o Protocol Lease Bridge mantém apenas o grace configurado e limitado, ancorado no último heartbeat global daquela sessão;\n- resposta válida após outage: `authority_state=healthy`, recovery é contabilizado e a sessão volta a ser revalidada normalmente;\n- resposta com `authority_epoch` inferior ao maior já observado: `authority_state=fenced`, sem grace para deny/fencing;\n- drain do scheduler continua impedindo novas alocações sem revogar lease/sessão saudável já existente;\n- sticky affinity continua sendo usada enquanto o nó permanecer elegível.\n\nEventos `node-authority-outage`, `node-authority-recovered` e `node-authority-fenced` entram no audit de leases sem persistir segredos.\n'''
if '## 22. Resiliência operacional — fundação 0.8.7' not in s:
    p.write_text(s.rstrip() + section + '\n')

# Static verification
for path in ['modules/hive_leases.sh', 'manager']:
    data = Path(path).read_text()
    if '\r' in data:
        raise SystemExit(f'CRLF introduced in {path}')
