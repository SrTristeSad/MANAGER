from pathlib import Path


def replace_once(path, old, new):
    p = Path(path)
    s = p.read_text(encoding="utf-8")
    if old not in s:
        raise SystemExit(f"anchor not found in {path}: {old[:80]!r}")
    if s.count(old) != 1:
        raise SystemExit(f"anchor not unique in {path}: {old[:80]!r}")
    p.write_text(s.replace(old, new, 1), encoding="utf-8")


# Health: after a heartbeat is durably accepted, mirror only the sanitized observation.
# Observability is explicitly failure-isolated and must never reject an otherwise valid heartbeat.
replace_once(
    "modules/hive_health.sh",
    '''            state, reason, received_at = store_observation(node_id, node_epoch, obj["issued_at"], metrics, source)\n            ack = make_ack(node_id, node_epoch, state, reason, received_at)\n''',
    '''            state, reason, received_at = store_observation(node_id, node_epoch, obj["issued_at"], metrics, source)\n            obs_module = os.path.join(MANAGER_HOME, "modules", "hive_observability.sh")\n            if os.path.isfile(obs_module) and os.access(obs_module, os.X_OK):\n                try:\n                    subprocess.run([obs_module, "--record-health", observation_path(node_id)],\n                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5, check=False)\n                except (OSError, subprocess.SubprocessError):\n                    pass\n            ack = make_ack(node_id, node_epoch, state, reason, received_at)\n'''
)

# Installer: ship/init the new module and expose its diagnostic entry point after install.
replace_once(
    "install.sh",
    '  "modules/hive_health.sh"\n  "modules/hive_scheduler.sh"\n',
    '  "modules/hive_health.sh"\n  "modules/hive_observability.sh"\n  "modules/hive_scheduler.sh"\n'
)
replace_once(
    "install.sh",
    '''"$INSTALL_DIR/modules/hive_health.sh" --install >/dev/null 2>&1 || {\n  echo "[AVISO] O heartbeat/saúde da Colmeia não pôde ser reanexado. Use: manager hive health status" >&2\n}\n"$INSTALL_DIR/modules/hive_scheduler.sh" --install >/dev/null 2>&1 || {\n''',
    '''"$INSTALL_DIR/modules/hive_health.sh" --install >/dev/null 2>&1 || {\n  echo "[AVISO] O heartbeat/saúde da Colmeia não pôde ser reanexado. Use: manager hive health status" >&2\n}\n"$INSTALL_DIR/modules/hive_observability.sh" --install >/dev/null 2>&1 || {\n  echo "[AVISO] A observabilidade da Colmeia não pôde inicializar seu histórico. Use: manager hive observe status" >&2\n}\n"$INSTALL_DIR/modules/hive_scheduler.sh" --install >/dev/null 2>&1 || {\n'''
)
replace_once(
    "install.sh",
    'echo "Saúde Colmeia: manager hive health status"\necho "Scheduler:   manager hive node status"\n',
    'echo "Saúde Colmeia: manager hive health status"\necho "Observabilidade: manager hive observe summary"\necho "Scheduler:   manager hive node status"\n'
)

# Public CLI help.
replace_once(
    "manager",
    '''  manager hive health controller rotate-tls\n                                  heartbeat assinado e saúde distribuída dos nós\n  manager hive node status|list\n''',
    '''  manager hive health controller rotate-tls\n                                  heartbeat assinado e saúde distribuída dos nós\n  manager hive observe status\n  manager hive observe summary [WINDOW_SECONDS]\n  manager hive observe health [NODE_ID|*] [LIMIT]\n  manager hive observe scheduler [LIMIT]\n  manager hive observe leases [IDENTITY_ID|*] [LIMIT]\n  manager hive observe prune [RETENTION_SECONDS]\n                                  histórico/summary sanitizado do control plane (0.8.10)\n  manager hive node status|list\n'''
)

observe_case = '''      observe|observability)\n        case "${3:-status}" in\n          status) exec "$MANAGER_HOME/modules/hive_observability.sh" --status ;;\n          summary) exec "$MANAGER_HOME/modules/hive_observability.sh" --summary "${4:-3600}" ;;\n          health) exec "$MANAGER_HOME/modules/hive_observability.sh" --health "${4:-*}" "${5:-50}" ;;\n          scheduler) exec "$MANAGER_HOME/modules/hive_observability.sh" --scheduler "${4:-50}" ;;\n          leases) exec "$MANAGER_HOME/modules/hive_observability.sh" --leases "${4:-*}" "${5:-50}" ;;\n          prune) if [[ -n "${4:-}" ]]; then exec "$MANAGER_HOME/modules/hive_observability.sh" --prune "$4"; else exec "$MANAGER_HOME/modules/hive_observability.sh" --prune; fi ;;\n          *) err "Uso: manager hive observe {status|summary [WINDOW]|health [NODE|*] [LIMIT]|scheduler [LIMIT]|leases [ID|*] [LIMIT]|prune [SECONDS]}"; exit 64 ;;\n        esac\n        ;;\n'''
replace_once(
    "manager",
    '      node)\n        case "${3:-status}" in\n',
    observe_case + '      node)\n        case "${3:-status}" in\n'
)

# Roadmap: record this as the first 0.8.10 slice, not as a completed release.
p = Path("docs/ROADMAP.md")
s = p.read_text(encoding="utf-8")
anchor = '''### 0.8.10 — observabilidade distribuída\n\n- visão histórica de saúde/capacidade por nó;\n- histórico de decisões do scheduler;\n- leases/grants globais auditáveis;\n- métricas de failover, drain e latência;\n'''
if anchor not in s:
    raise SystemExit("0.8.10 roadmap anchor not found")
replacement = '''### 0.8.10 — observabilidade distribuída 🚧\n\nFundação implementada nesta primeira fatia:\n\n- histórico sanitizado de saúde/capacidade por nó a partir de heartbeat aceito;\n- consulta ao histórico de decisões já auditadas pelo scheduler, sem duplicar autoridade;\n- consulta sanitizada a grants/leases e eventos de recovery/fencing já auditados;\n- summary por janela com failover sticky, drain/undrain, RTT médio/p95, grants/denies/releases e estado de autoridade;\n- retenção temporal do histórico de health, root-only, sem chaves/credenciais/assinaturas/nonces;\n- observabilidade failure-isolated: erro no histórico não invalida heartbeat aceito;\n- controlador continua fora do caminho de dados VPN.\n\nAinda pendente para fechar a 0.8.10:\n\n- retenção/rotação coordenada dos audits existentes;\n- export estruturado/integração externa;\n- séries temporais e métricas operacionais adicionais;\n- gate final multi-nó e regressão completa da release.\n'''
p.write_text(s.replace(anchor, replacement, 1), encoding="utf-8")
