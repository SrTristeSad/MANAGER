from pathlib import Path


def replace_once(path, old, new):
    p = Path(path)
    text = p.read_text()
    if old not in text:
        raise SystemExit(f'anchor not found in {path}: {old[:120]!r}')
    if text.count(old) != 1:
        raise SystemExit(f'anchor not unique in {path}: {text.count(old)} matches')
    p.write_text(text.replace(old, new, 1))


# hive_leases: carry the provision result inside the already authenticated/pinned ACK.
replace_once('modules/hive_leases.sh',
'''ALLOCATION_OUTBOX_DIR = os.environ.get("MANAGER_HIVE_ALLOCATION_OUTBOX_DIR", "/var/lib/manager/hive-allocations/controller/outbox")
SYSTEMD_DIR = os.environ.get("MANAGER_HIVE_LEASE_SYSTEMD_DIR", "/etc/systemd/system")''',
'''ALLOCATION_OUTBOX_DIR = os.environ.get("MANAGER_HIVE_ALLOCATION_OUTBOX_DIR", "/var/lib/manager/hive-allocations/controller/outbox")
ALLOCATION_RESULT_DIR = os.environ.get("MANAGER_HIVE_ALLOCATION_RESULT_DIR", "/var/lib/manager/hive-allocations/controller/results")
SYSTEMD_DIR = os.environ.get("MANAGER_HIVE_LEASE_SYSTEMD_DIR", "/etc/systemd/system")''')

replace_once('modules/hive_leases.sh',
'''    ensure_dir(REPLAY_DIR)
    Path(LOCK_FILE).touch(mode=0o600, exist_ok=True)''',
'''    ensure_dir(REPLAY_DIR)
    ensure_dir(ALLOCATION_RESULT_DIR)
    Path(LOCK_FILE).touch(mode=0o600, exist_ok=True)''')

old_ack = '''def allocation_ack_locked(node_id, node_epoch, params):
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
'''
new_ack = '''def validate_allocation_result(result, bundle, node_id, node_epoch):
    if not isinstance(result, dict):
        raise LeaseError(64, "invalid-allocation-result")
    expected = {"contract","version","allocation_id","identity_id","product_id","protocol","selected_node","selected_name",
                "node_epoch","expires_epoch","credential_state","credentials"}
    if set(result) != expected or result.get("contract") != "manager-hive-vpn-login-result-v1" or result.get("version") != 1:
        raise LeaseError(64, "invalid-allocation-result-contract")
    if (result.get("allocation_id") != bundle.get("allocation_id") or result.get("identity_id") != bundle.get("identity_id") or
            result.get("product_id") != bundle.get("product_id") or result.get("protocol") != bundle.get("protocol") or
            result.get("selected_node") != node_id or result.get("node_epoch") != int(node_epoch) or
            result.get("expires_epoch") != bundle.get("expires_epoch")):
        raise LeaseError(67, "allocation-result-bundle-mismatch")
    if result.get("credential_state") not in {"issued", "existing"}:
        raise LeaseError(64, "invalid-allocation-credential-state")
    creds = result.get("credentials")
    if not isinstance(creds, dict):
        raise LeaseError(64, "invalid-allocation-credentials")
    protocol = result.get("protocol")
    allowed = {"ssh": {"username","password"},
               "wireguard": {"client","ipv4","ipv6","profile_b64","profile_encoding"},
               "openvpn": {"client","ipv6","profile_b64","profile_encoding"}}.get(protocol)
    if allowed is None or set(creds) - allowed:
        raise LeaseError(64, "invalid-allocation-credential-fields")
    if protocol == "ssh":
        if not creds.get("username") or len(str(creds.get("username"))) > 64:
            raise LeaseError(64, "invalid-ssh-login-result")
        if result.get("credential_state") == "issued" and not creds.get("password"):
            raise LeaseError(64, "missing-issued-ssh-password")
        if "password" in creds and len(str(creds.get("password"))) > 512:
            raise LeaseError(64, "invalid-ssh-password-result")
    else:
        if creds.get("profile_encoding") != "base64" or not creds.get("profile_b64"):
            raise LeaseError(64, "missing-vpn-profile-result")
        try: decoded = base64.b64decode(str(creds.get("profile_b64")).encode("ascii"), validate=True)
        except Exception: raise LeaseError(64, "invalid-vpn-profile-base64")
        if not decoded or len(decoded) > 49152:
            raise LeaseError(64, "invalid-vpn-profile-size")
    encoded = json.dumps(result, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    if len(encoded) > 60000:
        raise LeaseError(64, "allocation-result-too-large")
    return result, encoded


def allocation_ack_locked(node_id, node_epoch, params):
    if not isinstance(params, dict) or set(params) not in ({"allocation_id"}, {"allocation_id", "result"}):
        raise LeaseError(64, "invalid-allocation-ack-params")
    allocation_id = str(params.get("allocation_id", ""))
    if not SESSION_RE.fullmatch(allocation_id):
        raise LeaseError(64, "invalid-allocation-id")
    path = Path(ALLOCATION_OUTBOX_DIR) / node_id / f"{allocation_id}.json"
    result_path = Path(ALLOCATION_RESULT_DIR) / f"{allocation_id}.json"
    if not path.exists():
        if "result" in params and result_path.exists():
            current = read_json(str(result_path))
            incoming = params.get("result")
            if current != incoming:
                raise LeaseError(65, "allocation-result-idempotency-conflict")
        return {"acked": True, "idempotent": True, "allocation_id": allocation_id, "result_stored": result_path.exists()}
    bundle = read_json(str(path))
    if not bundle:
        raise LeaseError(70, "invalid-outbox-bundle")
    try: bundle_node_epoch = int(bundle.get("node_epoch", 0))
    except (TypeError, ValueError): bundle_node_epoch = 0
    if bundle.get("selected_node") != node_id or bundle_node_epoch != int(node_epoch):
        raise LeaseError(67, "allocation-ack-node-mismatch")
    if "result" not in params:
        raise LeaseError(64, "allocation-ack-result-required")
    result, encoded = validate_allocation_result(params.get("result"), bundle, node_id, node_epoch)
    if result_path.exists():
        current = read_json(str(result_path))
        if current != result:
            raise LeaseError(65, "allocation-result-idempotency-conflict")
    else:
        atomic_write(str(result_path), encoded + b"\\n", 0o600)
    try: path.unlink()
    except FileNotFoundError: pass
    audit("allocation-ack", node_id=node_id, allocation_id=allocation_id,
          identity_id=bundle.get("identity_id"), global_lease_id=bundle.get("global_lease_id"), result_stored=1)
    return {"acked": True, "idempotent": False, "allocation_id": allocation_id, "result_stored": True}
'''
replace_once('modules/hive_leases.sh', old_ack, new_ack)

old_node_ack = '''def node_allocation_ack(allocation_id):
    if not SESSION_RE.fullmatch(str(allocation_id)): die("allocation_id inválido.", 64)
    result = node_request("allocation_ack", {"allocation_id": allocation_id})
    print(f"allocation_acked={1 if result.get('acked') else 0}")
    print(f"idempotent={1 if result.get('idempotent') else 0}")
    print(f"allocation_id={allocation_id}")
'''
new_node_ack = '''def node_allocation_ack(allocation_id, result_file=""):
    if not SESSION_RE.fullmatch(str(allocation_id)): die("allocation_id inválido.", 64)
    params = {"allocation_id": allocation_id}
    if result_file:
        result = read_json(result_file)
        if not result: die("Arquivo de resultado da allocation é inválido.", 64)
        params["result"] = result
    answer = node_request("allocation_ack", params)
    print(f"allocation_acked={1 if answer.get('acked') else 0}")
    print(f"idempotent={1 if answer.get('idempotent') else 0}")
    print(f"result_stored={1 if answer.get('result_stored') else 0}")
    print(f"allocation_id={allocation_id}")
'''
replace_once('modules/hive_leases.sh', old_node_ack, new_node_ack)
replace_once('modules/hive_leases.sh', '--allocation-ack-node ALLOCATION_ID|--serve-controller', '--allocation-ack-node ALLOCATION_ID [RESULT_JSON]|--serve-controller')
replace_once('modules/hive_leases.sh',
'''    if cmd == "--allocation-ack-node" and len(argv) == 2: node_allocation_ack(argv[1]); return''',
'''    if cmd == "--allocation-ack-node" and len(argv) in {2,3}: node_allocation_ack(argv[1], argv[2] if len(argv) == 3 else ""); return''')

# hive_allocations: build a sanitized public result, push it with ACK, and export it without stdout secrets.
replace_once('modules/hive_allocations.sh',
'''CTRL_OUTBOX_DIR = os.path.join(DATA_DIR, "controller", "outbox")
NODE_ACTIVE_DIR = os.path.join(DATA_DIR, "node", "active")''',
'''CTRL_OUTBOX_DIR = os.path.join(DATA_DIR, "controller", "outbox")
CTRL_RESULT_DIR = os.path.join(DATA_DIR, "controller", "results")
NODE_ACTIVE_DIR = os.path.join(DATA_DIR, "node", "active")''')
replace_once('modules/hive_allocations.sh',
'''    ensure_dir(CTRL_OUTBOX_DIR)
    ensure_dir(NODE_ACTIVE_DIR)''',
'''    ensure_dir(CTRL_OUTBOX_DIR)
    ensure_dir(CTRL_RESULT_DIR)
    ensure_dir(NODE_ACTIVE_DIR)''')

anchor = '''    return receipt,False



def sync_node(limit=8):'''
insert = '''    return receipt,False


def safe_profile_b64(path, expected_root, expected_name):
    if not path: die("Provisionamento não retornou o perfil VPN.",70)
    target=Path(path); root=Path(expected_root)
    try:
        resolved=target.resolve(strict=True); root_resolved=root.resolve(strict=True)
    except (OSError,RuntimeError): die("Perfil VPN provisionado não pôde ser resolvido.",70)
    if resolved.parent != root_resolved or resolved.name != expected_name:
        die("Perfil VPN provisionado saiu do diretório gerenciado esperado.",67)
    st=resolved.stat()
    if not stat.S_ISREG(st.st_mode) or st.st_size < 1 or st.st_size > 49152:
        die("Perfil VPN provisionado tem tipo/tamanho inválido.",70)
    return base64.b64encode(resolved.read_bytes()).decode("ascii")


def public_result(bundle,receipt):
    protocol=bundle["protocol"]; state="issued" if receipt.get("resource_created")=="1" else "existing"; creds={}
    if protocol=="ssh":
        username=receipt.get("ssh_user") or bundle["identity_id"]
        creds["username"]=username
        if receipt.get("ssh_password"):
            creds["password"]=receipt["ssh_password"]; state="issued"
    elif protocol=="wireguard":
        client=receipt.get("wireguard_client") or bundle["identity_id"]
        creds={"client":client,"ipv4":receipt.get("wireguard_ipv4") or receipt.get("wireguard_ip", ""),
               "ipv6":receipt.get("wireguard_ipv6", ""),"profile_encoding":"base64",
               "profile_b64":safe_profile_b64(receipt.get("wireguard_profile", ""),
                                               "/etc/manager/wireguard/clients", client+".conf")}
    elif protocol=="openvpn":
        client=receipt.get("openvpn_client") or bundle["identity_id"]
        creds={"client":client,"ipv6":receipt.get("openvpn_ipv6", ""),"profile_encoding":"base64",
               "profile_b64":safe_profile_b64(receipt.get("openvpn_profile", ""),
                                               "/etc/manager/openvpn/clients", client+".ovpn")}
    else: die("Protocolo inesperado no resultado público.",70)
    return {"contract":"manager-hive-vpn-login-result-v1","version":1,"allocation_id":bundle["allocation_id"],
            "identity_id":bundle["identity_id"],"product_id":bundle["product_id"],"protocol":protocol,
            "selected_node":bundle["selected_node"],"selected_name":bundle.get("selected_name", ""),
            "node_epoch":bundle["node_epoch"],"expires_epoch":bundle["expires_epoch"],
            "credential_state":state,"credentials":creds}


def controller_result(allocation_id,out_path):
    init_dirs(); controller_identity()
    if not ID_RE.fullmatch(str(allocation_id)): die("allocation_id inválido.",64)
    result_path=os.path.join(CTRL_RESULT_DIR,allocation_id+".json")
    result=read_json(result_path)
    if not result:
        print("login_result_status=pending"); print(f"allocation_id={allocation_id}"); return
    if result.get("contract")!="manager-hive-vpn-login-result-v1" or result.get("allocation_id")!=allocation_id:
        die("Resultado armazenado da allocation é inválido.",70)
    payload=json.dumps(result,sort_keys=True,separators=(",",":"))+"\\n"
    write_external_new(out_path,payload)
    print("login_result_status=ready"); print(f"allocation_id={allocation_id}"); print(f"result_file={out_path}")
    print(f"protocol={result.get('protocol','')}"); print(f"selected_node={result.get('selected_node','')}")
    print(f"credential_state={result.get('credential_state','')}")


def sync_node(limit=8):'''
replace_once('modules/hive_allocations.sh', anchor, insert)

old_sync = '''        _,was_provisioned=provision_bundle(bundle)
        if was_provisioned: provision_idempotent+=1
        else: provisioned+=1
        ack=subprocess.run([LEASE_MODULE,"--allocation-ack-node",bundle["allocation_id"]],stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE,text=True,timeout=20,check=False)
        if ack.returncode!=0:
            audit("sync-ack-failed",identity_id=bundle.get("identity_id"),allocation_id=bundle.get("allocation_id"))
            die(ack.stderr.strip() or "Allocation foi persistida localmente, mas o ACK ao controlador falhou.",ack.returncode)
        acked+=1'''
new_sync = '''        receipt,was_provisioned=provision_bundle(bundle)
        if was_provisioned: provision_idempotent+=1
        else: provisioned+=1
        result=public_result(bundle,receipt)
        fd,result_path=tempfile.mkstemp(prefix=".login-result-",dir=NODE_PROVISION_DIR); os.close(fd)
        try:
            atomic_write(result_path,json.dumps(result,sort_keys=True,separators=(",",":"))+"\\n")
            ack=subprocess.run([LEASE_MODULE,"--allocation-ack-node",bundle["allocation_id"],result_path],stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE,text=True,timeout=20,check=False)
        finally:
            try: os.unlink(result_path)
            except FileNotFoundError: pass
        if ack.returncode!=0:
            audit("sync-ack-failed",identity_id=bundle.get("identity_id"),allocation_id=bundle.get("allocation_id"))
            die(ack.stderr.strip() or "Allocation foi persistida localmente, mas o ACK ao controlador falhou.",ack.returncode)
        acked+=1'''
replace_once('modules/hive_allocations.sh', old_sync, new_sync)
replace_once('modules/hive_allocations.sh',
'''          "--controller-create ID PROTO OUT [REGION] [POOL] [STICKY] [SCOPE] [TTL]|--controller-revoke ID [REASON]|"''',
'''          "--controller-create ID PROTO OUT [REGION] [POOL] [STICKY] [SCOPE] [TTL]|--controller-result ALLOCATION_ID OUT|--controller-revoke ID [REASON]|"''')
replace_once('modules/hive_allocations.sh',
'''    if cmd=="--controller-revoke" and len(argv) in {2,3}:
        controller_revoke(argv[1],argv[2] if len(argv)==3 else "admin"); return''',
'''    if cmd=="--controller-result" and len(argv)==3: controller_result(argv[1],argv[2]); return
    if cmd=="--controller-revoke" and len(argv) in {2,3}:
        controller_revoke(argv[1],argv[2] if len(argv)==3 else "admin"); return''')

# CLI: expose a public operational login/result flow without printing secrets.
replace_once('manager',
'''  manager hive allocation controller revoke ID [REASON]
                                  allocation/login global assinado da Colmeia (0.8.5)''',
'''  manager hive allocation controller result ALLOCATION_ID OUT
  manager hive allocation controller revoke ID [REASON]
  manager hive login create ID PROTO OUT [REGION] [POOL] [STICKY] [SCOPE] [TTL]
  manager hive login result ALLOCATION_ID OUT
                                  allocation/login global assinado da Colmeia (0.8.5)''')
replace_once('manager',
'''              revoke) [[ -n "${5:-}" ]] || { err "Uso: manager hive allocation controller revoke ID [REASON]"; exit 64; }; exec "$MANAGER_HOME/modules/hive_allocations.sh" --controller-revoke "$5" "${6:-admin}" ;;
              *) err "Uso: manager hive allocation controller {status|create|revoke} ..."; exit 64 ;;''',
'''              result) [[ -n "${5:-}" && -n "${6:-}" ]] || { err "Uso: manager hive allocation controller result ALLOCATION_ID OUT"; exit 64; }; exec "$MANAGER_HOME/modules/hive_allocations.sh" --controller-result "$5" "$6" ;;
              revoke) [[ -n "${5:-}" ]] || { err "Uso: manager hive allocation controller revoke ID [REASON]"; exit 64; }; exec "$MANAGER_HOME/modules/hive_allocations.sh" --controller-revoke "$5" "${6:-admin}" ;;
              *) err "Uso: manager hive allocation controller {status|create|result|revoke} ..."; exit 64 ;;''')
replace_once('manager',
'''        ;;
      node)
        case "${3:-status}" in''',
'''        ;;
      login)
        case "${3:-}" in
          create)
            [[ -n "${4:-}" && -n "${5:-}" && -n "${6:-}" ]] || { err "Uso: manager hive login create ID PROTO OUT [REGION] [POOL] [STICKY] [SCOPE] [TTL]"; exit 64; }
            exec "$MANAGER_HOME/modules/hive_allocations.sh" --controller-create "$4" "$5" "$6" "${7:-}" "${8:-}" "${9:-}" "${10:-*}" "${11:-60}"
            ;;
          result) [[ -n "${4:-}" && -n "${5:-}" ]] || { err "Uso: manager hive login result ALLOCATION_ID OUT"; exit 64; }; exec "$MANAGER_HOME/modules/hive_allocations.sh" --controller-result "$4" "$5" ;;
          *) err "Uso: manager hive login {create|result} ..."; exit 64 ;;
        esac
        ;;
      node)
        case "${3:-status}" in''')
replace_once('manager', 'hive {status|request|accept|network ...|health ...|node ...|lease ...|allocation ...|controller ...}',
             'hive {status|request|accept|network ...|health ...|node ...|lease ...|allocation ...|login ...|controller ...}')

# Docs: close the remaining design gap while keeping VERSION unchanged until final CI is green.
roadmap = Path('docs/ROADMAP.md').read_text()
roadmap = roadmap.replace('''Ainda pendente para fechar a 0.8.5:\n\n- devolver ao fluxo público o resultado/credencial criada no nó sem expor segredo em logs ou no audit;\n- fechar o endpoint/contrato público de login/provisionamento de ponta a ponta e seus gates finais antes de alterar `VERSION`.''',
'''Adicionado no fechamento da fase:\n\n- ACK autenticado do nó carrega um `manager-hive-vpn-login-result-v1` sanitizado, sem segredo em argv, log ou audit;\n- controlador persiste resultados sensíveis em `0600` e a CLI pública exporta para arquivo novo `0600`, nunca para stdout;\n- `manager hive login create ...` inicia a allocation e `manager hive login result ALLOCATION_ID OUT` consulta/exporta o resultado;\n- SSH distingue credencial recém-emitida de credencial já existente, sem tornar senhas antigas recuperáveis;\n- WireGuard/OpenVPN devolvem o perfil gerenciado em base64 dentro do contrato;\n- `VERSION` continua 0.8.4 até os gates finais desta PR passarem.''')
Path('docs/ROADMAP.md').write_text(roadmap)

hive = Path('docs/HIVE.md').read_text()
marker = '## '
addition = '''\n### Resultado público de login/provisionamento — fechamento 0.8.5\n\nO nó selecionado envia o resultado do provisionamento somente dentro do ACK de allocation autenticado por Ed25519 e protegido pelo mesmo TLS 1.3 com fingerprint pinado da autoridade de leases. O controlador armazena o contrato `manager-hive-vpn-login-result-v1` em arquivo `0600`; senha SSH e perfis VPN não entram no audit e não são impressos no stdout.\n\nFluxo operacional:\n\n```bash\nmanager hive login create maria wireguard /root/maria.alloc.json BR-SP PREMIUM maria '*' 120\n# após o nó selecionado executar o sync/provisionamento\nmanager hive login result ALLOCATION_ID /root/maria-login.json\n```\n\nO comando de resultado informa apenas estado/metadados no terminal. O segredo fica no arquivo de saída criado com `0600` e o comando recusa sobrescrever um caminho existente. Para SSH já existente, o contrato retorna `credential_state=existing` e não tenta recuperar uma senha antiga; para WireGuard/OpenVPN, o perfil gerenciado é transportado em `credentials.profile_b64` com `profile_encoding=base64`.\n\n'''
needle = '## Allocation / login global'
if needle in hive:
    idx = hive.index(needle)
    next_idx = hive.find('\n## ', idx + len(needle))
    if next_idx == -1: hive += addition
    else: hive = hive[:next_idx] + addition + hive[next_idx:]
else:
    hive += addition
Path('docs/HIVE.md').write_text(hive)

# Permanent focused gate. It reuses the real controller/node/TLS path and verifies that secrets never hit stdout/audit.
workflow = r'''name: Hive VPN Public Login Result

on:
  push:
    branches: [main]
  pull_request:

permissions:
  contents: read

jobs:
  hive-vpn-public-login-result:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v7

      - name: Install current MANAGER tree
        shell: bash
        run: |
          set -euxo pipefail
          sudo env MANAGER_ALLOW_FILE_SOURCE=1 MANAGER_REPO_RAW="file://${GITHUB_WORKSPACE}" bash install.sh
          test "$(sudo cat /opt/manager/VERSION)" = 0.8.4

      - name: Initialize controller, node and scheduler
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
          printf '%s\n' "$node" >/tmp/node.id
          sudo manager hive node placement "$node" BR-SP-A BR BR-SP PREMIUM >/dev/null
          sudo mkdir -p /etc/manager/hive/controller/health /var/lib/manager/hive-health/nodes
          printf 'version=1\ndegraded_after_seconds=75\noffline_after_seconds=180\n' | sudo tee /etc/manager/hive/controller/health/controller.conf >/dev/null
          now="$(date +%s)"
          sudo python3 - "$now" "$node" <<'PY'
          import json,sys
          now=int(sys.argv[1]); node=sys.argv[2]; conf={}
          for line in open(f'/etc/manager/hive/controller/nodes/{node}.conf'):
              if '=' in line:
                  k,v=line.rstrip().split('=',1); conf[k]=v
          obs={'version':1,'node_id':node,'node_epoch':int(conf['node_epoch']),'issued_at':now,'received_at':now,'source':'ci',
               'base_state':'HEALTHY','base_reason':'ok','metrics':{'sessions':0,'max_sessions':100,'capacity':10,'weight':1,
               'previous_rtt_ms':10,'protocols':['ssh','wireguard','openvpn'],'service_ssh':'active','service_wireguard':'active','service_openvpn':'active'}}
          open(f'/var/lib/manager/hive-health/nodes/{node}.json','w').write(json.dumps(obs,sort_keys=True,separators=(',',':')))
          PY
          sudo chmod 600 /var/lib/manager/hive-health/nodes/*.json
          sudo /opt/manager/modules/products.sh --create PREMIUM 'CI Premium' 1 0 1 'ssh,wireguard,openvpn' 0 none warn '*' '*' '*'
          sudo manager hive allocation enable >/dev/null
          sudo systemctl stop manager-hive-allocation-sync.timer manager-hive-allocation-sync.service

      - name: Public SSH login result is file-only and secret-safe
        shell: bash
        run: |
          set -euxo pipefail
          sudo manager hive lease limit set public-ssh 1 PREMIUM >/dev/null
          created="$(sudo manager hive login create public-ssh ssh /tmp/public-ssh.alloc BR-SP PREMIUM public-ssh '*' 120)"
          allocation_id="$(awk -F= '$1=="allocation_id"{print $2}' <<<"$created")"
          test -n "$allocation_id"
          pending="$(sudo manager hive login result "$allocation_id" /tmp/public-ssh.result)"
          grep -q '^login_result_status=pending$' <<<"$pending"
          test ! -e /tmp/public-ssh.result
          sync_out="$(sudo manager hive allocation sync)"
          grep -q '^allocations_acked=1$' <<<"$sync_out"
          result_out="$(sudo manager hive login result "$allocation_id" /tmp/public-ssh.result)"
          grep -q '^login_result_status=ready$' <<<"$result_out"
          test "$(stat -c '%a' /tmp/public-ssh.result)" = 600
          password="$(sudo python3 - <<'PY'
          import json
          d=json.load(open('/tmp/public-ssh.result'))
          assert d['contract']=='manager-hive-vpn-login-result-v1'
          assert d['protocol']=='ssh'
          assert d['credential_state']=='issued'
          assert d['credentials']['username']=='public-ssh'
          print(d['credentials']['password'])
          PY
          )"
          test -n "$password"
          ! grep -Fq "$password" <<<"$created$pending$sync_out$result_out"
          ! sudo grep -Fq "$password" /var/log/manager/hive-allocation-audit.jsonl
          ! sudo grep -Fq "$password" /var/log/manager/hive-lease-audit.jsonl
          controller_result="/var/lib/manager/hive-allocations/controller/results/$allocation_id.json"
          sudo test -f "$controller_result"
          test "$(sudo stat -c '%a' "$controller_result")" = 600
          if sudo manager hive login result "$allocation_id" /tmp/public-ssh.result >/dev/null 2>&1; then
            echo 'result export unexpectedly overwrote an existing file' >&2
            exit 1
          fi

      - name: VPN profile result contract uses base64 and no argv secret
        shell: bash
        run: |
          set -euxo pipefail
          sudo mkdir -p /etc/manager/wireguard/clients /etc/manager/openvpn/clients
          sudo cp /opt/manager/modules/provision.sh /opt/manager/modules/provision.real
          cat <<'EOF' | sudo tee /opt/manager/modules/provision.sh >/dev/null
          #!/usr/bin/env bash
          set -euo pipefail
          [[ "${1:-}" == --ensure ]]
          id="$2"; product="$3"; protocol="$4"
          case "$protocol" in
            wireguard)
              printf '[Interface]\nPrivateKey = CI-WG-SECRET\n' >"/etc/manager/wireguard/clients/$id.conf"
              chmod 600 "/etc/manager/wireguard/clients/$id.conf"
              printf 'status=ok\nidentity_id=%s\nproduct_id=%s\nprotocols=wireguard\nresource_created=1\nprovision_action=created\nwireguard_client=%s\nwireguard_ipv4=10.66.66.2\nwireguard_ipv6=\nwireguard_profile=%s\n' "$id" "$product" "$id" "/etc/manager/wireguard/clients/$id.conf"
              ;;
            openvpn)
              printf 'client\n<key>CI-OVPN-SECRET</key>\n' >"/etc/manager/openvpn/clients/$id.ovpn"
              chmod 600 "/etc/manager/openvpn/clients/$id.ovpn"
              printf 'status=ok\nidentity_id=%s\nproduct_id=%s\nprotocols=openvpn\nresource_created=1\nprovision_action=created\nopenvpn_client=%s\nopenvpn_ipv6=0\nopenvpn_profile=%s\n' "$id" "$product" "$id" "/etc/manager/openvpn/clients/$id.ovpn"
              ;;
            *) exit 64 ;;
          esac
          EOF
          sudo chmod 755 /opt/manager/modules/provision.sh
          for proto in wireguard openvpn; do
            id="public-$proto"
            sudo manager hive lease limit set "$id" 1 PREMIUM >/dev/null
            created="$(sudo manager hive login create "$id" "$proto" "/tmp/$id.alloc" BR-SP PREMIUM "$id" '*' 120)"
            allocation_id="$(awk -F= '$1=="allocation_id"{print $2}' <<<"$created")"
            sudo manager hive allocation sync >/tmp/sync.out
            sudo manager hive login result "$allocation_id" "/tmp/$id.result" >/tmp/result.out
            sudo python3 - "$proto" "/tmp/$id.result" <<'PY'
          import base64,json,sys
          proto,path=sys.argv[1:]
          d=json.load(open(path)); c=d['credentials']
          assert d['protocol']==proto and c['profile_encoding']=='base64'
          raw=base64.b64decode(c['profile_b64']).decode()
          assert ('CI-WG-SECRET' in raw) if proto=='wireguard' else ('CI-OVPN-SECRET' in raw)
          PY
            secret="CI-WG-SECRET"; [[ "$proto" == openvpn ]] && secret="CI-OVPN-SECRET"
            ! grep -Fq "$secret" /tmp/sync.out
            ! grep -Fq "$secret" /tmp/result.out
            ! sudo grep -Fq "$secret" /var/log/manager/hive-allocation-audit.jsonl
            ! sudo grep -Fq "$secret" /var/log/manager/hive-lease-audit.jsonl
          done
          sudo mv /opt/manager/modules/provision.real /opt/manager/modules/provision.sh
'''
Path('.github/workflows/hive-vpn-public-login.yml').write_text(workflow)
