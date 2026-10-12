#!/usr/bin/env python3
from pathlib import Path

WF = Path('.github/workflows/tmp-wire-remote-provisioning.yml')


def need(text, needle, label):
    count = text.count(needle)
    if count != 1:
        raise SystemExit(f'{label}: expected one anchor, found {count}')


def extract_block(text, start_marker, end_marker, label):
    try:
        start = text.index(start_marker) + len(start_marker)
        end = text.index(end_marker, start)
    except ValueError as exc:
        raise SystemExit(f'{label}: source block not found') from exc
    return text[start:end]


wf = WF.read_text()

# Reuse the already-reviewed implementation blocks from the temporary source,
# but apply them with stable function/line anchors instead of brittle whole blocks.
prov_block = extract_block(
    wf,
    "          block = r'''",
    "\n'''\n          s = s.replace(anchor, block + anchor)",
    'provision block',
)
if not prov_block.startswith('rewrite_identity_protocols_local() {'):
    raise SystemExit('provision block: unexpected start')

# Tighten rollback behavior for the new ensure path and populate WG metadata on reuse.
prov_block = prov_block.replace(
    '        unlock_ssh_resource "$id" || return 70\n        created=1',
    '        if ! unlock_ssh_resource "$id"; then\n'
    '          rewrite_identity_binding "$id" ssh "" >/dev/null 2>&1 || true\n'
    '          remove_ssh_resource "$id"\n'
    '          (( expanded == 0 )) || rewrite_identity_protocols_local "$id" "$previous_protocols"\n'
    '          return 70\n'
    '        fi\n'
    '        created=1',
)
prov_block = prov_block.replace(
    '  reconcile_runtime || { err "Falha ao reconciliar política após ensure de $protocol/$id"; return 70; }',
    '  if [[ "$protocol" == wireguard && "$created" == 0 ]]; then\n'
    '    PROV_WG_IP="$(awk -F= \'$1=="ip4" || $1=="ip" {print $2; exit}\' "$WG_CLIENT_DIR/$id.meta")"\n'
    '    PROV_WG_IP6="$(awk -F= \'$1=="ip6" {print $2; exit}\' "$WG_CLIENT_DIR/$id.meta")"\n'
    '  fi\n'
    '  if ! reconcile_runtime; then\n'
    '    if (( created == 1 )); then\n'
    '      case "$protocol" in\n'
    '        ssh) rewrite_identity_binding "$id" ssh "" >/dev/null 2>&1 || true; remove_ssh_resource "$id" ;;\n'
    '        wireguard) rewrite_identity_binding "$id" wireguard "" >/dev/null 2>&1 || true; remove_wireguard_resource "$id" ;;\n'
    '        openvpn) rewrite_identity_binding "$id" openvpn "" >/dev/null 2>&1 || true; revoke_openvpn_resource "$id" 1 ;;\n'
    '      esac\n'
    '    fi\n'
    '    (( expanded == 0 )) || rewrite_identity_protocols_local "$id" "$previous_protocols"\n'
    '    err "Falha ao reconciliar política após ensure de $protocol/$id"\n'
    '    return 70\n'
    '  fi',
)

p = Path('modules/provision.sh')
s = p.read_text()
if 'ensure_protocol_impl() {' not in s:
    anchor = 'clear_identity_bindings() {\n'
    need(s, anchor, 'provision insertion')
    s = s.replace(anchor, prov_block + '\n\n' + anchor)
cli_anchor = '  --create-unlocked) provision_impl "${2:-}" "${3:-}" "${4:-}" "${5:-}"; exit $? ;;\n'
if '--ensure-unlocked)' not in s:
    need(s, cli_anchor, 'ensure CLI')
    s = s.replace(
        cli_anchor,
        cli_anchor
        + '  --ensure) shift; flock -x "$PROVISION_LOCK" "$0" --ensure-unlocked "${1:-}" "${2:-}" "${3:-}"; exit $? ;;\n'
        + '  --ensure-unlocked) ensure_protocol_impl "${2:-}" "${3:-}" "${4:-}"; exit $? ;;\n',
    )
p.write_text(s)

# Extract only the receipt/provision functions from the reviewed source.
hive_marker = "          block = r'''def provision_receipt_path(allocation_id):\n"
hive_end = "\n'''\n          s = s.replace(anchor, block + anchor)"
hive_block = extract_block(wf, hive_marker, hive_end, 'hive provision block')
hive_block = 'def provision_receipt_path(allocation_id):\n' + hive_block

p = Path('modules/hive_allocations.sh')
s = p.read_text()
if 'NODE_PROVISION_DIR = ' not in s:
    anchor = 'NODE_EPOCH_DIR = os.path.join(DATA_DIR, "node", "epochs")\n'
    need(s, anchor, 'node provision dir')
    s = s.replace(anchor, anchor + 'NODE_PROVISION_DIR = os.path.join(DATA_DIR, "node", "provisioned")\n')
if 'PROVISION_MODULE = ' not in s:
    anchor = 'LEASE_MODULE = os.path.join(MANAGER_HOME, "modules", "hive_leases.sh")\n'
    need(s, anchor, 'provision module')
    s = s.replace(anchor, anchor + 'PROVISION_MODULE = os.path.join(MANAGER_HOME, "modules", "provision.sh")\n')
if 'ensure_dir(NODE_PROVISION_DIR)' not in s:
    anchor = '    ensure_dir(NODE_EPOCH_DIR)\n'
    need(s, anchor, 'provision directory init')
    s = s.replace(anchor, anchor + '    ensure_dir(NODE_PROVISION_DIR)\n')
if 'def provision_bundle(bundle):' not in s:
    anchor = 'def sync_node(limit=8):\n'
    need(s, anchor, 'provision functions')
    s = s.replace(anchor, hive_block + '\n\n' + anchor)

old = '    accepted=idempotent_count=acked=0\n'
new = '    accepted=idempotent_count=acked=provisioned=provision_idempotent=0\n'
if new not in s:
    need(s, old, 'sync counters')
    s = s.replace(old, new)

anchor = '        else: accepted+=1\n'
provision_lines = (
    '        _,was_provisioned=provision_bundle(bundle)\n'
    '        if was_provisioned: provision_idempotent+=1\n'
    '        else: provisioned+=1\n'
)
if provision_lines not in s:
    need(s, anchor, 'sync provision call')
    s = s.replace(anchor, anchor + provision_lines)

old = '    print(f"allocations_idempotent={idempotent_count}"); print(f"allocations_acked={acked}")\n    print("delivery_transport=lease-control-pull")\n'
new = ('    print(f"allocations_idempotent={idempotent_count}"); print(f"allocations_provisioned={provisioned}")\n'
       '    print(f"allocations_provision_idempotent={provision_idempotent}"); print(f"allocations_acked={acked}")\n'
       '    print("delivery_transport=lease-control-pull"); print("automatic_remote_provisioning=1")\n')
if 'allocations_provisioned=' not in s:
    need(s, old, 'sync result')
    s = s.replace(old, new)

old = '    print("automatic_distribution=1"); print("sync_interval_seconds=3"); print("failure_mode=fail-closed")\n'
new = '    print("automatic_distribution=1"); print("automatic_remote_provisioning=1"); print("sync_interval_seconds=3"); print("failure_mode=fail-closed")\n'
if 'print("automatic_distribution=1"); print("automatic_remote_provisioning=1")' not in s:
    need(s, old, 'node enable status')
    s = s.replace(old, new)

old = '    print("delivery_transport=lease-control-pull"); print("controller_in_user_vpn_path=0")\n    ready=pending=consumed=0\n'
new = ('    print("delivery_transport=lease-control-pull"); print("automatic_remote_provisioning=1"); print("controller_in_user_vpn_path=0")\n'
       '    print(f"provision_receipts={sum(1 for path in Path(NODE_PROVISION_DIR).glob(\'*.conf\') if read_conf(str(path)).get(\'status\')==\'ok\')}")\n'
       '    ready=pending=consumed=0\n')
if 'provision_receipts=' not in s:
    need(s, old, 'node receipt status')
    s = s.replace(old, new)
p.write_text(s)

# Documentation updates.
p = Path('docs/ROADMAP.md')
s = p.read_text()
old = ('- revogação remove bundles ainda não entregues e mantém o controlador fora do caminho de dados VPN.\n\n'
       'Ainda pendente para fechar a 0.8.5:\n\n'
       '- integrar o provisionamento remoto de recursos/credenciais necessários no nó escolhido quando eles ainda não existirem;\n'
       '- fechar o fluxo público de login/provisionamento de ponta a ponta e seus gates finais antes de alterar `VERSION`.\n')
new = ('- revogação remove bundles ainda não entregues e mantém o controlador fora do caminho de dados VPN;\n'
       '- nó selecionado executa provisionamento remoto idempotente antes do ACK da allocation;\n'
       '- SSH, WireGuard e OpenVPN reutilizam o provisionamento transacional local, sem shell remoto arbitrário;\n'
       '- redelivery após perda de ACK reutiliza o recurso já criado e um receipt root-only vinculado à allocation;\n'
       '- falha de produto/protocolo/preflight no nó impede ACK e mantém o fluxo fail-closed.\n\n'
       'Ainda pendente para fechar a 0.8.5:\n\n'
       '- devolver ao fluxo público o resultado/credencial criada no nó sem expor segredo em logs ou no audit;\n'
       '- fechar o endpoint/contrato público de login/provisionamento de ponta a ponta e seus gates finais antes de alterar `VERSION`.\n')
if 'nó selecionado executa provisionamento remoto idempotente' not in s:
    need(s, old, 'roadmap 0.8.5')
    s = s.replace(old, new)
p.write_text(s)

p = Path('docs/HIVE.md')
s = p.read_text()
heading = '### Distribuição automática da allocation (0.8.5)'
if '#### Provisionamento remoto no nó selecionado (0.8.5)' not in s:
    need(s, heading, 'HIVE distribution heading')
    insertion = ('#### Provisionamento remoto no nó selecionado (0.8.5)\n\n'
                 'Após validar e persistir uma allocation recebida por pull, o nó executa `provision.sh --ensure` para a identidade, produto e protocolo assinados no ticket. A operação é tipada e idempotente: cria o recurso somente quando necessário, reutiliza binding compatível e recusa conflito de identidade/produto/recurso local. O ACK ao controlador só acontece depois do provisionamento e da gravação de um receipt `0600` em `/var/lib/manager/hive-allocations/node/provisioned`.\n\n'
                 'Se o provisionamento falhar (produto ausente/desativado, protocolo não permitido, serviço VPN não configurado ou conflito local), a allocation **não recebe ACK**. Em redelivery, o mesmo ticket é aceito idempotentemente e o provisionamento é tentado novamente. Segredos não entram no audit JSONL; quando uma credencial nasce nesta etapa, o material necessário fica somente no receipt root-only até o fluxo público seguro de entrega ser fechado. O controlador continua fora do caminho de dados VPN.\n\n')
    s = s.replace(heading, insertion + heading)
p.write_text(s)

# Fail closed if any intended product marker is absent.
checks = {
    'modules/provision.sh': ['ensure_protocol_impl() {', '--ensure-unlocked)', 'provision_action='],
    'modules/hive_allocations.sh': ['NODE_PROVISION_DIR =', 'def provision_bundle(bundle):', 'allocations_provisioned=', 'automatic_remote_provisioning=1'],
    'docs/ROADMAP.md': ['nó selecionado executa provisionamento remoto idempotente'],
    'docs/HIVE.md': ['Provisionamento remoto no nó selecionado (0.8.5)'],
}
for name, markers in checks.items():
    text = Path(name).read_text()
    for marker in markers:
        if marker not in text:
            raise SystemExit(f'{name}: missing final marker {marker}')
