#!/usr/bin/env python3
from pathlib import Path


def replace(path, old, new):
    p = Path(path)
    text = p.read_text()
    if old not in text:
        raise SystemExit(f"expected block not found in {path}: {old[:100]!r}")
    p.write_text(text.replace(old, new, 1))


# Protocol bridge: actual SSH/OpenVPN/WireGuard admissions obtain a global lease
# after the local lease is created, and roll back the local admission if the
# controller refuses it. Heartbeats are fail-closed once global enforcement is enabled.
replace("modules/protocol_leases.sh",
        'SESSION_ENGINE="$MANAGER_HOME/modules/session_engine.sh"\n',
        'SESSION_ENGINE="$MANAGER_HOME/modules/session_engine.sh"\nGLOBAL_LEASE_MODULE="$MANAGER_HOME/modules/hive_leases.sh"\nGLOBAL_LEASE_CONF="$MANAGER_ETC/hive/leases/node.conf"\n')

replace("modules/protocol_leases.sh",
'''token_value() {
  local token="$1" key="$2"
  printf '%s\\n' "$token" | tr '\\t' '\\n' | awk -F= -v k="$key" '$1==k {print $2; exit}'
}

write_map() {''',
'''token_value() {
  local token="$1" key="$2"
  printf '%s\\n' "$token" | tr '\\t' '\\n' | awk -F= -v k="$key" '$1==k {print $2; exit}'
}

global_lease_enabled() {
  [[ -f "$GLOBAL_LEASE_CONF" ]] || return 1
  [[ "$(awk -F= '$1=="enabled" {print $2; exit}' "$GLOBAL_LEASE_CONF" 2>/dev/null || true)" == 1 ]]
}

global_lease_acquire() {
  local identity="$1" protocol="$2" resource="$3" device="$4" session_id="$5"
  global_lease_enabled || return 0
  [[ -x "$GLOBAL_LEASE_MODULE" ]] || { err "Enforcement global está habilitado, mas hive_leases.sh não existe."; return 69; }
  "$GLOBAL_LEASE_MODULE" --acquire-node "$identity" "$protocol" "$resource" "$device" "$session_id" "$LEASE_TTL" >/dev/null
}

global_lease_heartbeat() {
  local identity="$1" session_id="$2"
  global_lease_enabled || return 0
  [[ -x "$GLOBAL_LEASE_MODULE" ]] || return 69
  "$GLOBAL_LEASE_MODULE" --heartbeat-node "$identity" "$session_id" "$LEASE_TTL" >/dev/null
}

global_lease_release() {
  local identity="$1" session_id="$2"
  global_lease_enabled || return 0
  [[ -x "$GLOBAL_LEASE_MODULE" ]] || return 69
  "$GLOBAL_LEASE_MODULE" --release-node "$identity" "$session_id" >/dev/null
}

write_map() {''')

replace("modules/protocol_leases.sh",
'''release_map_file() {
  local file="$1" session_id epoch
  [[ -f "$file" ]] || return 0
  session_id="$(map_read_file "$file" session_id)"
  epoch="$(map_read_file "$file" session_epoch)"
  if [[ "$session_id" =~ ^[a-f0-9]{32}$ && "$epoch" =~ ^[1-9][0-9]*$ ]]; then
    "$SESSION_ENGINE" --release "$session_id" "$epoch" >/dev/null 2>&1 || true
  fi
  rm -f "$file"
}''',
'''release_map_file() {
  local file="$1" session_id epoch identity
  [[ -f "$file" ]] || return 0
  session_id="$(map_read_file "$file" session_id)"
  epoch="$(map_read_file "$file" session_epoch)"
  identity="$(map_read_file "$file" identity_id)"
  if [[ "$session_id" =~ ^[a-f0-9]{32}$ && "$epoch" =~ ^[1-9][0-9]*$ ]]; then
    if [[ -n "$identity" ]]; then
      global_lease_release "$identity" "$session_id" >/dev/null 2>&1 || true
    fi
    "$SESSION_ENGINE" --release "$session_id" "$epoch" >/dev/null 2>&1 || true
  fi
  rm -f "$file"
}''')

replace("modules/protocol_leases.sh",
'''acquire_managed() {
  local protocol="$1" resource="$2" device="$3" source_pid="${4:-0}" remote="${5:--}" tty="${6:--}" identity token session_id epoch
  valid_protocol "$protocol" || return 64
  valid_resource "$resource" || return 64
  valid_device "$device" || return 64
  identity="$(find_identity_by_binding "$protocol" "$resource" 2>/dev/null || true)"
  [[ -n "$identity" ]] || return 0
  token="$("$SESSION_ENGINE" --acquire "$identity" "$protocol" "$resource" "$device" "$LEASE_TTL")" || return $?
  session_id="$(token_value "$token" session_id)"
  epoch="$(token_value "$token" epoch)"
  [[ "$session_id" =~ ^[a-f0-9]{32}$ && "$epoch" =~ ^[1-9][0-9]*$ ]] || return 70
  write_map "$protocol" "$resource" "$device" "$identity" "$session_id" "$epoch" "$source_pid" "$remote" "$tty"
}''',
'''acquire_managed() {
  local protocol="$1" resource="$2" device="$3" source_pid="${4:-0}" remote="${5:--}" tty="${6:--}" identity token session_id epoch rc=0
  valid_protocol "$protocol" || return 64
  valid_resource "$resource" || return 64
  valid_device "$device" || return 64
  identity="$(find_identity_by_binding "$protocol" "$resource" 2>/dev/null || true)"
  [[ -n "$identity" ]] || return 0
  token="$("$SESSION_ENGINE" --acquire "$identity" "$protocol" "$resource" "$device" "$LEASE_TTL")" || return $?
  session_id="$(token_value "$token" session_id)"
  epoch="$(token_value "$token" epoch)"
  [[ "$session_id" =~ ^[a-f0-9]{32}$ && "$epoch" =~ ^[1-9][0-9]*$ ]] || return 70
  global_lease_acquire "$identity" "$protocol" "$resource" "$device" "$session_id" || rc=$?
  if (( rc != 0 )); then
    "$SESSION_ENGINE" --release "$session_id" "$epoch" >/dev/null 2>&1 || true
    return "$rc"
  fi
  write_map "$protocol" "$resource" "$device" "$identity" "$session_id" "$epoch" "$source_pid" "$remote" "$tty"
}''')

replace("modules/protocol_leases.sh",
'''heartbeat_map() {
  local file="$1" session_id epoch token new_epoch
  session_id="$(map_read_file "$file" session_id)"
  epoch="$(map_read_file "$file" session_epoch)"
  [[ "$session_id" =~ ^[a-f0-9]{32}$ && "$epoch" =~ ^[1-9][0-9]*$ ]] || { rm -f "$file"; return 1; }
  if token="$("$SESSION_ENGINE" --heartbeat "$session_id" "$epoch" "$LEASE_TTL" 2>/dev/null)"; then
    new_epoch="$(token_value "$token" epoch)"
    if [[ "$new_epoch" =~ ^[1-9][0-9]*$ ]]; then
      sed -i "s/^session_epoch=.*/session_epoch=$new_epoch/" "$file"
    fi
    return 0
  fi
  rm -f "$file"
  return 1
}''',
'''heartbeat_map() {
  local file="$1" session_id epoch token new_epoch identity
  session_id="$(map_read_file "$file" session_id)"
  epoch="$(map_read_file "$file" session_epoch)"
  identity="$(map_read_file "$file" identity_id)"
  [[ "$session_id" =~ ^[a-f0-9]{32}$ && "$epoch" =~ ^[1-9][0-9]*$ && -n "$identity" ]] || { rm -f "$file"; return 1; }
  if token="$("$SESSION_ENGINE" --heartbeat "$session_id" "$epoch" "$LEASE_TTL" 2>/dev/null)"; then
    if ! global_lease_heartbeat "$identity" "$session_id"; then
      "$SESSION_ENGINE" --release "$session_id" "$epoch" >/dev/null 2>&1 || true
      rm -f "$file"
      return 1
    fi
    new_epoch="$(token_value "$token" epoch)"
    if [[ "$new_epoch" =~ ^[1-9][0-9]*$ ]]; then
      sed -i "s/^session_epoch=.*/session_epoch=$new_epoch/" "$file"
    fi
    return 0
  fi
  global_lease_release "$identity" "$session_id" >/dev/null 2>&1 || true
  rm -f "$file"
  return 1
}''')

# Installer/lifecycle.
replace("install.sh", '  "modules/hive_scheduler.sh"\n', '  "modules/hive_scheduler.sh"\n  "modules/hive_leases.sh"\n')
replace("install.sh",
'''"$INSTALL_DIR/modules/hive_scheduler.sh" --install >/dev/null 2>&1 || {
  echo "[AVISO] O scheduler da Colmeia não pôde inicializar seu estado. Use: manager hive node status" >&2
}
''',
'''"$INSTALL_DIR/modules/hive_scheduler.sh" --install >/dev/null 2>&1 || {
  echo "[AVISO] O scheduler da Colmeia não pôde inicializar seu estado. Use: manager hive node status" >&2
}
"$INSTALL_DIR/modules/hive_leases.sh" --install >/dev/null 2>&1 || {
  echo "[AVISO] A autoridade global de leases não pôde ser reanexada. Use: manager hive lease status" >&2
}
''')
replace("install.sh", 'echo "Scheduler:   manager hive node status"\n', 'echo "Scheduler:   manager hive node status"\necho "Leases globais: manager hive lease status"\n')

# Uninstall normal preserves policy/lease state; purge removes it.
replace("uninstall.sh",
'''# Scheduler da Colmeia não possui daemon próprio. No uninstall normal seu estado
# de placement/sticky é preservado; --purge remove estado e auditoria explicitamente.
''',
'''# A autoridade global de leases sai antes dos bridges de protocolo. Configuração,
# limites e leases persistentes sobrevivem ao uninstall normal; --purge remove tudo.
if [[ -x /opt/manager/modules/hive_leases.sh ]]; then
  if $PURGE; then
    /opt/manager/modules/hive_leases.sh --purge >/dev/null 2>&1 || true
  else
    /opt/manager/modules/hive_leases.sh --detach >/dev/null 2>&1 || true
  fi
else
  systemctl disable --now manager-hive-lease-controller.service >/dev/null 2>&1 || true
  if [[ -f /etc/systemd/system/manager-hive-lease-controller.service ]] && grep -Fqx '# MANAGER-HIVE-GLOBAL-LEASE v1' /etc/systemd/system/manager-hive-lease-controller.service 2>/dev/null; then
    rm -f /etc/systemd/system/manager-hive-lease-controller.service
  fi
  if $PURGE; then
    rm -rf /etc/manager/hive/controller/leases /etc/manager/hive/leases /var/lib/manager/hive-leases
    rm -f /var/log/manager/hive-lease-audit.jsonl
  fi
  systemctl daemon-reload >/dev/null 2>&1 || true
fi

# Scheduler da Colmeia não possui daemon próprio. No uninstall normal seu estado
# de placement/sticky é preservado; --purge remove estado e auditoria explicitamente.
''')

# Hive lifecycle reattaches/detaches the new control-plane authority too.
replace("modules/hive_lifecycle.sh",
'''HEALTH_MODULE="$MANAGER_HOME/modules/hive_health.sh"
DROPIN_FILE=''',
'''HEALTH_MODULE="$MANAGER_HOME/modules/hive_health.sh"
LEASE_MODULE="$MANAGER_HOME/modules/hive_leases.sh"
DROPIN_FILE=''')
replace("modules/hive_lifecycle.sh",
'''HEALTH_MARKER="# MANAGER-HIVE-HEALTH v1"
''',
'''HEALTH_MARKER="# MANAGER-HIVE-HEALTH v1"
LEASE_MARKER="# MANAGER-HIVE-GLOBAL-LEASE v1"
''')
replace("modules/hive_lifecycle.sh",
'''fallback_health_detach() {
  local file
  systemctl disable --now manager-hive-heartbeat.timer >/dev/null 2>&1 || true
  systemctl stop manager-hive-heartbeat.service >/dev/null 2>&1 || true
  systemctl disable --now manager-hive-health-controller.service >/dev/null 2>&1 || true
  for file in \\
    /etc/systemd/system/manager-hive-heartbeat.service \\
    /etc/systemd/system/manager-hive-heartbeat.timer \\
    /etc/systemd/system/manager-hive-health-controller.service; do
    owned_health_unit "$file" && rm -f "$file"
  done
  systemctl daemon-reload >/dev/null 2>&1 || true
}
''',
'''fallback_health_detach() {
  local file
  systemctl disable --now manager-hive-heartbeat.timer >/dev/null 2>&1 || true
  systemctl stop manager-hive-heartbeat.service >/dev/null 2>&1 || true
  systemctl disable --now manager-hive-health-controller.service >/dev/null 2>&1 || true
  for file in \\
    /etc/systemd/system/manager-hive-heartbeat.service \\
    /etc/systemd/system/manager-hive-heartbeat.timer \\
    /etc/systemd/system/manager-hive-health-controller.service; do
    owned_health_unit "$file" && rm -f "$file"
  done
  systemctl daemon-reload >/dev/null 2>&1 || true
}

fallback_lease_detach() {
  local file=/etc/systemd/system/manager-hive-lease-controller.service first=""
  systemctl disable --now manager-hive-lease-controller.service >/dev/null 2>&1 || true
  if [[ -f "$file" && ! -L "$file" ]]; then
    IFS= read -r first < "$file" || true
    [[ "$first" == "$LEASE_MARKER" ]] && rm -f "$file"
  fi
  systemctl daemon-reload >/dev/null 2>&1 || true
}
''')
replace("modules/hive_lifecycle.sh",
'''    if [[ -x "$HEALTH_MODULE" ]]; then
      "$HEALTH_MODULE" --install >/dev/null 2>&1 || true
    fi
    ;;
  stop)
    if [[ -x "$HEALTH_MODULE" ]]; then
''',
'''    if [[ -x "$HEALTH_MODULE" ]]; then
      "$HEALTH_MODULE" --install >/dev/null 2>&1 || true
    fi
    if [[ -x "$LEASE_MODULE" ]]; then
      "$LEASE_MODULE" --install >/dev/null 2>&1 || true
    fi
    ;;
  stop)
    if [[ -x "$LEASE_MODULE" ]]; then
      "$LEASE_MODULE" --detach >/dev/null 2>&1 || fallback_lease_detach
    else
      fallback_lease_detach
    fi
    if [[ -x "$HEALTH_MODULE" ]]; then
''')
replace("modules/hive_lifecycle.sh",
'''status_lifecycle() {
  local dropin="0" helper="0" health="0"
''',
'''status_lifecycle() {
  local dropin="0" helper="0" health="0" leases="0"
''')
replace("modules/hive_lifecycle.sh",
'''  if [[ -x "$MANAGER_HOME/modules/hive_health.sh" ]]; then
    health="1"
  fi
  printf 'contract=manager-hive-lifecycle-v1\\ndropin=%s\\nhelper=%s\\nhealth_module=%s\\nautomation_service=manager-automation-v2.service\\n' "$dropin" "$helper" "$health"
}''',
'''  if [[ -x "$MANAGER_HOME/modules/hive_health.sh" ]]; then
    health="1"
  fi
  if [[ -x "$MANAGER_HOME/modules/hive_leases.sh" ]]; then
    leases="1"
  fi
  printf 'contract=manager-hive-lifecycle-v1\\ndropin=%s\\nhelper=%s\\nhealth_module=%s\\nglobal_lease_module=%s\\nautomation_service=manager-automation-v2.service\\n' "$dropin" "$helper" "$health" "$leases"
}''')

# Scheduler advertises the 0.8.4 capability; whether the controller service is
# enabled is exposed separately.
replace("modules/hive_scheduler.sh",
'''AUDIT_FILE = os.environ.get("MANAGER_HIVE_SCHEDULER_AUDIT_FILE", "/var/log/manager/hive-scheduler-audit.jsonl")
''',
'''AUDIT_FILE = os.environ.get("MANAGER_HIVE_SCHEDULER_AUDIT_FILE", "/var/log/manager/hive-scheduler-audit.jsonl")
GLOBAL_LEASE_CONF = os.path.join(CTRL_DIR, "leases", "controller.conf")
''')
replace("modules/hive_scheduler.sh",
'''def status():
    init_scheduler()
''',
'''def global_lease_controller_enabled():
    return 1 if read_conf(GLOBAL_LEASE_CONF).get("enabled") == "1" else 0


def status():
    init_scheduler()
''')
replace("modules/hive_scheduler.sh", '    print("global_lease_authority=0")\n    print("global_max_sessions=0")\n',
        '    print("global_lease_authority=1")\n    print(f"global_lease_controller_enabled={global_lease_controller_enabled()}")\n    print("global_max_sessions=1")\n')
# There are two old authority markers (selection + status); update any remaining selection marker.
p = Path("modules/hive_scheduler.sh")
text = p.read_text().replace('    print("global_lease_authority=0")\n', '    print("global_lease_authority=1")\n')
p.write_text(text)

# Public CLI and interactive menu.
replace("manager",
'''  manager hive node select PROTOCOL [REGION] [POOL] [STICKY] [NODE_SCOPE]
                                  scheduler weighted least-loaded / drain / failover
''',
'''  manager hive node select PROTOCOL [REGION] [POOL] [STICKY] [NODE_SCOPE]
                                  scheduler weighted least-loaded / drain / failover
  manager hive lease status
  manager hive lease node status|configure HOST PORT TLS_FP|disable
  manager hive lease controller init|status|enable BIND_IP [PORT]|disable|rotate-tls
  manager hive lease controller list [ID]
  manager hive lease controller revoke ID [REASON]
  manager hive lease limit set ID MAX|import-local ID|sync-local|show ID|list|unset ID
                                  autoridade global de sessões entre nós da Colmeia
''')
replace("manager",
'''      node)
        case "${3:-status}" in
''',
'''      lease)
        case "${3:-status}" in
          status) exec "$MANAGER_HOME/modules/hive_leases.sh" --status ;;
          node)
            case "${4:-status}" in
              status) exec "$MANAGER_HOME/modules/hive_leases.sh" --node-status ;;
              configure) [[ -n "${5:-}" && -n "${6:-}" && -n "${7:-}" ]] || { err "Uso: manager hive lease node configure HOST PORT TLS_FP"; exit 64; }; exec "$MANAGER_HOME/modules/hive_leases.sh" --node-configure "$5" "$6" "$7" ;;
              disable) exec "$MANAGER_HOME/modules/hive_leases.sh" --node-disable ;;
              *) err "Uso: manager hive lease node {status|configure|disable}"; exit 64 ;;
            esac
            ;;
          controller)
            case "${4:-status}" in
              init) exec "$MANAGER_HOME/modules/hive_leases.sh" --controller-init ;;
              status) exec "$MANAGER_HOME/modules/hive_leases.sh" --controller-status ;;
              enable) [[ -n "${5:-}" ]] || { err "Uso: manager hive lease controller enable BIND_IP [PORT]"; exit 64; }; exec "$MANAGER_HOME/modules/hive_leases.sh" --controller-enable "$5" "${6:-9445}" ;;
              disable) exec "$MANAGER_HOME/modules/hive_leases.sh" --controller-disable ;;
              rotate-tls) exec "$MANAGER_HOME/modules/hive_leases.sh" --controller-rotate-tls ;;
              list) exec "$MANAGER_HOME/modules/hive_leases.sh" --controller-list "${5:-}" ;;
              revoke) [[ -n "${5:-}" ]] || { err "Uso: manager hive lease controller revoke ID [REASON]"; exit 64; }; exec "$MANAGER_HOME/modules/hive_leases.sh" --controller-revoke "$5" "${6:-admin}" ;;
              *) err "Ação de lease global do controlador inválida: ${4:-}"; exit 64 ;;
            esac
            ;;
          limit)
            case "${4:-list}" in
              set) [[ -n "${5:-}" && -n "${6:-}" ]] || { err "Uso: manager hive lease limit set ID MAX"; exit 64; }; exec "$MANAGER_HOME/modules/hive_leases.sh" --limit-set "$5" "$6" ;;
              import-local) [[ -n "${5:-}" ]] || { err "Uso: manager hive lease limit import-local ID"; exit 64; }; exec "$MANAGER_HOME/modules/hive_leases.sh" --limit-import-local "$5" ;;
              sync-local) exec "$MANAGER_HOME/modules/hive_leases.sh" --limit-sync-local ;;
              show) [[ -n "${5:-}" ]] || { err "Uso: manager hive lease limit show ID"; exit 64; }; exec "$MANAGER_HOME/modules/hive_leases.sh" --limit-show "$5" ;;
              list) exec "$MANAGER_HOME/modules/hive_leases.sh" --limit-list ;;
              unset) [[ -n "${5:-}" ]] || { err "Uso: manager hive lease limit unset ID"; exit 64; }; exec "$MANAGER_HOME/modules/hive_leases.sh" --limit-unset "$5" ;;
              *) err "Ação de limite global inválida: ${4:-}"; exit 64 ;;
            esac
            ;;
          *) err "Uso: manager hive lease {status|node ...|controller ...|limit ...}"; exit 64 ;;
        esac
        ;;
      node)
        case "${3:-status}" in
''')
replace("manager", '      *) err "Uso: manager hive {status|request|accept|network ...|health ...|node ...|controller ...}"; exit 64 ;;\n',
        '      *) err "Uso: manager hive {status|request|accept|network ...|health ...|node ...|lease ...|controller ...}"; exit 64 ;;\n')
replace("manager", '  say " ${C_CYAN}41${C_RESET}) Heartbeat / saúde dos nós"\n',
        '  say " ${C_CYAN}41${C_RESET}) Heartbeat / saúde dos nós"\n  say " ${C_CYAN}42${C_RESET}) Leases globais / limite entre nós"\n')
replace("manager",
'''    41)
      header
      say "${C_WHITE}COLMEIA — HEARTBEAT / SAÚDE${C_RESET}\\n"
      "$MANAGER_HOME/modules/hive_health.sh" --status || true
      say ""
      "$MANAGER_HOME/modules/hive_health.sh" --controller-status 2>/dev/null || true
      say ""
      say "Fluxo via CLI:"
      say " manager hive health controller enable BIND_IP [PORT]"
      say " manager hive health configure HOST PORT SHA256:<tls-fingerprint> [INTERVAL]"
      say " manager hive health send"
      say " manager hive health controller list"
      pause
      ;;
    90) self_update ;;
''',
'''    41)
      header
      say "${C_WHITE}COLMEIA — HEARTBEAT / SAÚDE${C_RESET}\\n"
      "$MANAGER_HOME/modules/hive_health.sh" --status || true
      say ""
      "$MANAGER_HOME/modules/hive_health.sh" --controller-status 2>/dev/null || true
      say ""
      say "Fluxo via CLI:"
      say " manager hive health controller enable BIND_IP [PORT]"
      say " manager hive health configure HOST PORT SHA256:<tls-fingerprint> [INTERVAL]"
      say " manager hive health send"
      say " manager hive health controller list"
      pause
      ;;
    42)
      header
      say "${C_WHITE}COLMEIA — LEASES GLOBAIS${C_RESET}\\n"
      "$MANAGER_HOME/modules/hive_leases.sh" --status || true
      say ""
      "$MANAGER_HOME/modules/hive_leases.sh" --controller-status 2>/dev/null || true
      say ""
      say "Fluxo via CLI:"
      say " manager hive lease controller enable BIND_IP [PORT]"
      say " manager hive lease limit set maria 1"
      say " manager hive lease node configure HOST PORT SHA256:<tls-fingerprint>"
      say " manager hive lease controller list [ID]"
      pause
      ;;
    90) self_update ;;
''')

print("0.8.4 integration patch applied")
