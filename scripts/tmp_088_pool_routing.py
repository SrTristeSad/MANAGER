from pathlib import Path


def replace_once(path, old, new):
    p=Path(path); s=p.read_text()
    if old not in s:
        raise SystemExit(f'anchor missing in {path}: {old[:140]!r}')
    p.write_text(s.replace(old,new,1))

p='modules/hive_remote.sh'
replace_once(p,
'''AUTOMATION = os.path.join(MANAGER_HOME, "modules", "automation_v2.sh")
AUDIT = "/var/log/manager/hive-remote-audit.jsonl"
CONTRACT = "manager-hive-remote-route-v1"
''',
'''AUTOMATION = os.path.join(MANAGER_HOME, "modules", "automation_v2.sh")
SCHEDULER = os.path.join(MANAGER_HOME, "modules", "hive_scheduler.sh")
AUDIT = "/var/log/manager/hive-remote-audit.jsonl"
CONTRACT = "manager-hive-remote-route-v1"
POOL_RESULT_CONTRACT = "manager-hive-remote-pool-selection-v1"
''')

replace_once(p,
'''def controller_call(argv):
    if len(argv) < 2:
        die("Uso: hive_remote.sh --controller-call NODE_ID ACTION [KEY=VALUE|--request-id ID]", 64)
''',
'''def route_candidates_for_action(action):
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
''')

replace_once(p,
'''    print("request_auth=hive-controller-ed25519")
    print(f"routes_registered={total}")
''',
'''    print("request_auth=hive-controller-ed25519")
    print("pool_routing=1")
    print("pool_selector=hive-scheduler-weighted-least-loaded")
    print("pool_health_required=HEALTHY")
    print("pool_drain_respected=1")
    print(f"routes_registered={total}")
''')

replace_once(p,
'''    print("Uso: hive_remote.sh {--status|--node-enable ENDPOINT ACTIONS OUT|--node-disable OUT|--controller-status|--controller-accept AD|--controller-list|--controller-show NODE|--controller-call NODE ACTION [ARGS...]|--install|--detach|--purge}", file=sys.stderr)
''',
'''    print("Uso: hive_remote.sh {--status|--node-enable ENDPOINT ACTIONS OUT|--node-disable OUT|--controller-status|--controller-accept AD|--controller-list|--controller-show NODE|--controller-call NODE ACTION [ARGS...]|--controller-select-pool POOL PROTOCOL ACTION [STICKY]|--controller-call-pool POOL PROTOCOL ACTION [ARGS...]|--install|--detach|--purge}", file=sys.stderr)
''')

replace_once(p,
'''    if cmd == "--controller-show" and len(argv) == 2: controller_show(argv[1]); return
    if cmd == "--controller-call" and len(argv) >= 3: controller_call(argv[1:]); return
''',
'''    if cmd == "--controller-show" and len(argv) == 2: controller_show(argv[1]); return
    if cmd == "--controller-call" and len(argv) >= 3: controller_call(argv[1:]); return
    if cmd == "--controller-select-pool" and len(argv) in {4,5}: controller_select_pool(argv[1:]); return
    if cmd == "--controller-call-pool" and len(argv) >= 4: controller_call_pool(argv[1:]); return
''')

# CLI additions.
p='manager'
replace_once(p,
'''  manager hive remote controller call NODE_ID ACTION [KEY=VALUE ...] [--request-id ID]
                                  roteamento remoto tipado e assinado da Colmeia (0.8.8)
''',
'''  manager hive remote controller call NODE_ID ACTION [KEY=VALUE ...] [--request-id ID]
  manager hive remote controller select POOL PROTOCOL ACTION [STICKY]
  manager hive remote controller call-pool POOL PROTOCOL ACTION [--sticky KEY] [KEY=VALUE ...] [--request-id ID]
                                  roteamento remoto tipado e assinado da Colmeia (0.8.8)
''')
replace_once(p,
'''              call)
                [[ -n "${5:-}" && -n "${6:-}" ]] || { err "Uso: manager hive remote controller call NODE_ID ACTION [ARGS...]"; exit 64; }
                remote_node="$5"; remote_action="$6"; shift 6
                exec "$MANAGER_HOME/modules/hive_remote.sh" --controller-call "$remote_node" "$remote_action" "$@"
                ;;
              *) err "Uso: manager hive remote controller {status|list|show|accept|call} ..."; exit 64 ;;
''',
'''              call)
                [[ -n "${5:-}" && -n "${6:-}" ]] || { err "Uso: manager hive remote controller call NODE_ID ACTION [ARGS...]"; exit 64; }
                remote_node="$5"; remote_action="$6"; shift 6
                exec "$MANAGER_HOME/modules/hive_remote.sh" --controller-call "$remote_node" "$remote_action" "$@"
                ;;
              select)
                [[ -n "${5:-}" && -n "${6:-}" && -n "${7:-}" ]] || { err "Uso: manager hive remote controller select POOL PROTOCOL ACTION [STICKY]"; exit 64; }
                exec "$MANAGER_HOME/modules/hive_remote.sh" --controller-select-pool "$5" "$6" "$7" "${8:-}"
                ;;
              call-pool)
                [[ -n "${5:-}" && -n "${6:-}" && -n "${7:-}" ]] || { err "Uso: manager hive remote controller call-pool POOL PROTOCOL ACTION [ARGS...]"; exit 64; }
                remote_pool="$5"; remote_protocol="$6"; remote_action="$7"; shift 7
                exec "$MANAGER_HOME/modules/hive_remote.sh" --controller-call-pool "$remote_pool" "$remote_protocol" "$remote_action" "$@"
                ;;
              *) err "Uso: manager hive remote controller {status|list|show|accept|call|select|call-pool} ..."; exit 64 ;;
''')

# Docs: mark pool routing as implemented but leave release closure pending.
p='docs/HIVE.md'
replace_once(p,
'''- esta fundação roteia por `node_id`; seleção por pool continua pendente para fechar a 0.8.8.
''',
'''- `controller select POOL PROTOCOL ACTION [STICKY]` filtra primeiro pelas rotas assinadas que permitem a ação e entrega esse `node_scope` ao scheduler 0.8.3;
- `controller call-pool` usa exatamente a seleção `HEALTHY`, weighted least-loaded, drain e sticky do scheduler antes de executar a mesma chamada tipada;
- o scheduler nunca pode devolver um nó fora do conjunto de rotas válidas para a ação; a rota/node_epoch são revalidados depois da seleção para fechar corridas;
- nenhum algoritmo paralelo de saúde/carga foi criado para o roteamento remoto.
''')

p='docs/ROADMAP.md'
replace_once(p,
'''Ainda pendente para fechar 0.8.8:

- seleção/roteamento por pool sobre múltiplos nós enrolled/saudáveis;
- gate end-to-end de roteamento entre controlador e múltiplos nós;
- fechamento formal da release 0.8.8;
- integração futura com Telegram sem criar uma segunda autoridade paralela.
''',
'''Roteamento por pool implementado:

- o controlador filtra rotas assinadas por `action_scope` e passa apenas esses node_ids como `node_scope` ao scheduler 0.8.3;
- seleção por pool exige nó enrolled, `HEALTHY`, fora de drain, com protocolo/serviço ativo e capacidade disponível;
- weighted least-loaded, RTT secundário e sticky/failover continuam sendo calculados por uma única autoridade de scheduler;
- `manager hive remote controller select POOL PROTOCOL ACTION [STICKY]` expõe a decisão sem executar ação;
- `manager hive remote controller call-pool POOL PROTOCOL ACTION ...` seleciona e executa a mesma operação tipada, revalidando rota/node_epoch após a seleção;
- nós sem rota ou sem permissão para a ação nunca entram no conjunto de candidatos.

Ainda pendente para fechar 0.8.8:

- gate end-to-end final de múltiplos nós/pool + regressão completa;
- fechamento formal da release 0.8.8;
- integração futura com Telegram sem criar uma segunda autoridade paralela.
''')
