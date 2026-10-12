from pathlib import Path


def replace_once(path, old, new):
    p = Path(path)
    text = p.read_text()
    if new in text:
        return
    if old not in text:
        raise SystemExit(f"anchor not found in {path}: {old[:100]!r}")
    p.write_text(text.replace(old, new, 1))


def append_once(path, marker, text):
    p = Path(path)
    cur = p.read_text()
    if marker in cur:
        return
    p.write_text(cur.rstrip() + "\n\n" + text.strip() + "\n")

# ---- modules/hive_leases.sh: reuse the existing signed/TLS control plane ----
p = "modules/hive_leases.sh"
replace_once(p,
'''ALLOCATION_RESULT_DIR = os.environ.get("MANAGER_HIVE_ALLOCATION_RESULT_DIR", "/var/lib/manager/hive-allocations/controller/results")
SYSTEMD_DIR = os.environ.get("MANAGER_HIVE_LEASE_SYSTEMD_DIR", "/etc/systemd/system")''',
'''ALLOCATION_RESULT_DIR = os.environ.get("MANAGER_HIVE_ALLOCATION_RESULT_DIR", "/var/lib/manager/hive-allocations/controller/results")
ACCOUNTING_ETC = os.path.join(CTRL_DIR, "accounting")
ACCOUNTING_QUOTA_DIR = os.path.join(ACCOUNTING_ETC, "quotas")
ACCOUNTING_DATA_DIR = os.environ.get("MANAGER_HIVE_ACCOUNTING_DATA_DIR", "/var/lib/manager/hive-accounting")
ACCOUNTING_CTRL_DIR = os.path.join(ACCOUNTING_DATA_DIR, "controller")
ACCOUNTING_IDENTITY_DIR = os.path.join(ACCOUNTING_CTRL_DIR, "identities")
ACCOUNTING_SOURCE_DIR = os.path.join(ACCOUNTING_CTRL_DIR, "sources")
ACCOUNTING_AUDIT_FILE = os.environ.get("MANAGER_HIVE_ACCOUNTING_AUDIT_FILE", "/var/log/manager/hive-accounting-audit.jsonl")
SYSTEMD_DIR = os.environ.get("MANAGER_HIVE_LEASE_SYSTEMD_DIR", "/etc/systemd/system")''')
replace_once(p,
'''DEVICE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.:@-]{0,95}$")
HOST_RE = re.compile''',
'''DEVICE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.:@-]{0,95}$")
PRODUCT_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,47}$")
SOURCE_EPOCH_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.:-]{0,95}$")
HOST_RE = re.compile''')
replace_once(p,
'''    ensure_dir(ALLOCATION_RESULT_DIR)
    Path(LOCK_FILE).touch''',
'''    ensure_dir(ALLOCATION_RESULT_DIR)
    ensure_dir(ACCOUNTING_ETC)
    ensure_dir(ACCOUNTING_QUOTA_DIR)
    ensure_dir(ACCOUNTING_DATA_DIR)
    ensure_dir(ACCOUNTING_CTRL_DIR)
    ensure_dir(ACCOUNTING_IDENTITY_DIR)
    ensure_dir(ACCOUNTING_SOURCE_DIR)
    Path(LOCK_FILE).touch''')

accounting_helpers = r'''
def accounting_audit(event, **fields):
    ensure_dir(os.path.dirname(ACCOUNTING_AUDIT_FILE), 0o750)
    record = {"epoch": int(time.time()), "event": event}
    for key, value in fields.items():
        if isinstance(value, (str, int, float, bool)) or value is None:
            record[key] = value
    fd = os.open(ACCOUNTING_AUDIT_FILE, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    try:
        os.write(fd, (json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8"))
    finally:
        os.close(fd)


def accounting_identity_path(identity_id):
    return os.path.join(ACCOUNTING_IDENTITY_DIR, identity_id + ".json")


def accounting_source_path(node_id, identity_id):
    return os.path.join(ACCOUNTING_SOURCE_DIR, node_id, identity_id + ".json")


def accounting_quota_path(identity_id):
    return os.path.join(ACCOUNTING_QUOTA_DIR, identity_id + ".conf")


def accounting_int(value, name, maximum=(2**63 - 1)):
    try:
        value = int(value)
    except (TypeError, ValueError):
        raise LeaseError(64, f"invalid-{name}")
    if value < 0 or value > maximum:
        raise LeaseError(64, f"invalid-{name}")
    return value


def accounting_state(identity_id):
    state = read_json(accounting_identity_path(identity_id)) or {}
    return {
        "contract": "manager-hive-global-usage-state-v1",
        "identity_id": identity_id,
        "product_id": str(state.get("product_id", "")),
        "download_bytes": accounting_int(state.get("download_bytes", 0), "stored-download"),
        "upload_bytes": accounting_int(state.get("upload_bytes", 0), "stored-upload"),
        "wireguard_download_bytes": accounting_int(state.get("wireguard_download_bytes", 0), "stored-wg-download"),
        "wireguard_upload_bytes": accounting_int(state.get("wireguard_upload_bytes", 0), "stored-wg-upload"),
        "openvpn_download_bytes": accounting_int(state.get("openvpn_download_bytes", 0), "stored-ovpn-download"),
        "openvpn_upload_bytes": accounting_int(state.get("openvpn_upload_bytes", 0), "stored-ovpn-upload"),
        "traffic_complete": 1 if state.get("traffic_complete", 1) in {1, True, "1"} else 0,
        "source_nodes": accounting_int(state.get("source_nodes", 0), "stored-source-nodes"),
        "updated_epoch": accounting_int(state.get("updated_epoch", 0), "stored-updated"),
    }


def accounting_total(identity_id):
    state = accounting_state(identity_id)
    return state["download_bytes"] + state["upload_bytes"]


def accounting_cycle(period, created_epoch=0):
    if period == "monthly":
        return time.strftime("%Y-%m", time.gmtime())
    if period == "lifetime":
        return f"lifetime-{created_epoch}"
    return "none"


def accounting_write_quota(identity_id, conf, *, cycle=None, baseline=None):
    created = accounting_int(conf.get("created_epoch", int(time.time())), "quota-created")
    quota = accounting_int(conf.get("quota_bytes", 0), "quota-bytes")
    product = str(conf.get("product_id", ""))
    period = str(conf.get("quota_period", "none"))
    action = str(conf.get("quota_action", "warn"))
    if not PRODUCT_RE.fullmatch(product) or period not in {"none", "monthly", "lifetime"} or action not in {"warn", "block"}:
        raise LeaseError(70, "invalid-global-quota-policy")
    if quota > 0 and period == "none":
        raise LeaseError(70, "invalid-global-quota-period")
    if cycle is None:
        cycle = str(conf.get("cycle", accounting_cycle(period, created)))
    if baseline is None:
        baseline = accounting_int(conf.get("baseline_total_bytes", 0), "quota-baseline")
    text = (
        "version=1\n"
        f"identity_id={identity_id}\n"
        f"product_id={product}\n"
        f"quota_bytes={quota}\n"
        f"quota_period={period}\n"
        f"quota_action={action}\n"
        f"cycle={cycle}\n"
        f"baseline_total_bytes={baseline}\n"
        f"created_epoch={created}\n"
        f"updated_epoch={int(time.time())}\n"
    )
    atomic_write(accounting_quota_path(identity_id), text)
    return read_conf(accounting_quota_path(identity_id))


def accounting_refresh_quota_locked(identity_id, product_id=""):
    conf = read_conf(accounting_quota_path(identity_id))
    if not conf:
        return None
    expected = conf.get("product_id", "")
    if product_id and expected and product_id != expected:
        raise LeaseError(73, "global-quota-product-mismatch")
    created = accounting_int(conf.get("created_epoch", 0), "quota-created")
    period = conf.get("quota_period", "none")
    wanted = accounting_cycle(period, created)
    if conf.get("cycle", "") != wanted:
        conf = accounting_write_quota(identity_id, conf, cycle=wanted, baseline=accounting_total(identity_id))
        accounting_audit("quota-cycle", identity_id=identity_id, product_id=conf.get("product_id", ""), cycle=wanted,
                         baseline_total_bytes=conf.get("baseline_total_bytes", "0"))
    return conf


def accounting_quota_metrics(identity_id, refresh=False):
    conf = accounting_refresh_quota_locked(identity_id) if refresh else read_conf(accounting_quota_path(identity_id))
    state = accounting_state(identity_id)
    total = state["download_bytes"] + state["upload_bytes"]
    if not conf:
        return {"configured": 0, "quota_bytes": 0, "used_bytes": total, "remaining_bytes": 0,
                "exceeded": 0, "enforceable": state["traffic_complete"], "action": "none", "cycle": "none"}
    quota = accounting_int(conf.get("quota_bytes", 0), "quota-bytes")
    baseline = accounting_int(conf.get("baseline_total_bytes", 0), "quota-baseline")
    used = total - baseline if total >= baseline else total
    exceeded = 1 if quota > 0 and used >= quota else 0
    remaining = 0 if quota == 0 or used >= quota else quota - used
    return {"configured": 1, "quota_bytes": quota, "used_bytes": used, "remaining_bytes": remaining,
            "exceeded": exceeded, "enforceable": state["traffic_complete"],
            "action": conf.get("quota_action", "warn"), "cycle": conf.get("cycle", "none")}


def accounting_quota_blocked(identity_id):
    metrics = accounting_quota_metrics(identity_id, refresh=True)
    return bool(metrics["configured"] and metrics["action"] == "block" and metrics["exceeded"] and metrics["enforceable"])


def accounting_complete_for_identity(identity_id):
    found = 0
    complete = 1
    root = Path(ACCOUNTING_SOURCE_DIR)
    if not root.is_dir():
        return 1, 0
    for node_dir in root.iterdir():
        if not node_dir.is_dir():
            continue
        sample = read_json(str(node_dir / (identity_id + ".json")))
        if not sample:
            continue
        found += 1
        if sample.get("traffic_complete") not in {1, True, "1"}:
            complete = 0
    return complete, found


def usage_ingest_locked(node_id, node_epoch, params):
    allowed = {"identity_id", "product_id", "source_epoch", "download_bytes", "upload_bytes",
               "wireguard_download_bytes", "wireguard_upload_bytes", "openvpn_download_bytes",
               "openvpn_upload_bytes", "traffic_complete", "sample_epoch"}
    if not isinstance(params, dict) or set(params) != allowed:
        raise LeaseError(64, "invalid-usage-ingest-params")
    identity_id = validate_identity(params.get("identity_id"))
    product_id = str(params.get("product_id", ""))
    source_epoch = str(params.get("source_epoch", ""))
    if not PRODUCT_RE.fullmatch(product_id):
        raise LeaseError(64, "invalid-product-id")
    if not SOURCE_EPOCH_RE.fullmatch(source_epoch):
        raise LeaseError(64, "invalid-source-epoch")
    counters = {
        "download_bytes": accounting_int(params.get("download_bytes"), "download-bytes"),
        "upload_bytes": accounting_int(params.get("upload_bytes"), "upload-bytes"),
        "wireguard_download_bytes": accounting_int(params.get("wireguard_download_bytes"), "wg-download-bytes"),
        "wireguard_upload_bytes": accounting_int(params.get("wireguard_upload_bytes"), "wg-upload-bytes"),
        "openvpn_download_bytes": accounting_int(params.get("openvpn_download_bytes"), "ovpn-download-bytes"),
        "openvpn_upload_bytes": accounting_int(params.get("openvpn_upload_bytes"), "ovpn-upload-bytes"),
    }
    traffic_complete = accounting_int(params.get("traffic_complete"), "traffic-complete", 1)
    sample_epoch = accounting_int(params.get("sample_epoch"), "sample-epoch")
    accounting_refresh_quota_locked(identity_id, product_id)

    source_path = accounting_source_path(node_id, identity_id)
    previous = read_json(source_path)
    deltas = {key: 0 for key in counters}
    baseline = previous is None
    reset = False
    if previous:
        previous_epoch = str(previous.get("source_epoch", ""))
        previous_sample = accounting_int(previous.get("sample_epoch", 0), "previous-sample-epoch")
        if previous_epoch == source_epoch:
            if sample_epoch < previous_sample:
                raise LeaseError(73, "stale-usage-sample")
            for key, current in counters.items():
                old = accounting_int(previous.get(key, 0), f"previous-{key}")
                if current < old:
                    raise LeaseError(73, "usage-counter-regression")
                deltas[key] = current - old
        else:
            reset = True
            baseline = True

    sample = {"contract": "manager-hive-global-usage-source-v1", "node_id": node_id, "node_epoch": node_epoch,
              "identity_id": identity_id, "product_id": product_id, "source_epoch": source_epoch,
              "traffic_complete": traffic_complete, "sample_epoch": sample_epoch, "received_epoch": int(time.time()), **counters}
    atomic_write(source_path, json.dumps(sample, sort_keys=True, separators=(",", ":")) + "\n")

    state = accounting_state(identity_id)
    state["product_id"] = product_id
    for key, delta in deltas.items():
        state[key] += delta
    state["total_bytes"] = state["download_bytes"] + state["upload_bytes"]
    state["traffic_complete"], state["source_nodes"] = accounting_complete_for_identity(identity_id)
    state["updated_epoch"] = int(time.time())
    atomic_write(accounting_identity_path(identity_id), json.dumps(state, sort_keys=True, separators=(",", ":")) + "\n")
    metrics = accounting_quota_metrics(identity_id)
    delta_total = deltas["download_bytes"] + deltas["upload_bytes"]
    accounting_audit("usage-ingest", identity_id=identity_id, product_id=product_id, node_id=node_id, node_epoch=node_epoch,
                     source_epoch=source_epoch, delta_bytes=delta_total, global_total_bytes=state["total_bytes"],
                     baseline=bool(baseline), source_reset=bool(reset), traffic_complete=state["traffic_complete"],
                     quota_exceeded=metrics["exceeded"], quota_enforceable=metrics["enforceable"])
    return {"ingested": True, "identity_id": identity_id, "product_id": product_id, "delta_bytes": delta_total,
            "global_total_bytes": state["total_bytes"], "baseline": bool(baseline), "source_reset": bool(reset),
            "traffic_complete": state["traffic_complete"], "source_nodes": state["source_nodes"],
            "quota_configured": metrics["configured"], "quota_bytes": metrics["quota_bytes"],
            "quota_used_bytes": metrics["used_bytes"], "quota_remaining_bytes": metrics["remaining_bytes"],
            "quota_exceeded": metrics["exceeded"], "quota_enforceable": metrics["enforceable"],
            "quota_action": metrics["action"], "quota_cycle": metrics["cycle"]}

'''
replace_once(p, "def allocation_pull_locked(node_id, node_epoch, params):", accounting_helpers + "def allocation_pull_locked(node_id, node_epoch, params):")
replace_once(p,
'''            elif action == "release": result = release_locked(node_id, params)
            elif action == "allocation_pull": result = allocation_pull_locked(node_id, node_epoch, params)''',
'''            elif action == "release": result = release_locked(node_id, params)
            elif action == "usage_ingest": result = usage_ingest_locked(node_id, node_epoch, params)
            elif action == "allocation_pull": result = allocation_pull_locked(node_id, node_epoch, params)''')
replace_once(p,
'''    if exact_global_id and not SESSION_RE.fullmatch(str(exact_global_id)):
        raise LeaseError(64, "invalid-global-lease-id")
    maximum, policy = get_limit(identity_id)''',
'''    if exact_global_id and not SESSION_RE.fullmatch(str(exact_global_id)):
        raise LeaseError(64, "invalid-global-lease-id")
    if accounting_quota_blocked(identity_id):
        metrics = accounting_quota_metrics(identity_id)
        accounting_audit("quota-deny", identity_id=identity_id, node_id=node_id, node_epoch=node_epoch,
                         quota_bytes=metrics["quota_bytes"], quota_used_bytes=metrics["used_bytes"], action=metrics["action"])
        raise LeaseError(73, "global-traffic-quota-exceeded")
    maximum, policy = get_limit(identity_id)''')
replace_once(p,
'''def controller_grant(identity_id, protocol, region="", pool="", sticky="", node_scope="*", device="grant", ttl=DEFAULT_TTL):
    init_dirs(); identity_id = validate_identity(identity_id)
    if protocol not in ALLOWED_PROTOCOLS:''',
'''def controller_grant(identity_id, protocol, region="", pool="", sticky="", node_scope="*", device="grant", ttl=DEFAULT_TTL):
    init_dirs(); identity_id = validate_identity(identity_id)
    if accounting_quota_blocked(identity_id):
        metrics = accounting_quota_metrics(identity_id)
        accounting_audit("quota-deny-grant", identity_id=identity_id, quota_bytes=metrics["quota_bytes"],
                         quota_used_bytes=metrics["used_bytes"], action=metrics["action"])
        die("Franquia global excedida para esta identidade.", 73)
    if protocol not in ALLOWED_PROTOCOLS:''')

node_usage_func = r'''
def node_usage_ingest(identity_id, product_id, source_epoch, download, upload, wg_download, wg_upload,
                      ovpn_download, ovpn_upload, traffic_complete, sample_epoch):
    identity_id = validate_identity(identity_id)
    if not PRODUCT_RE.fullmatch(str(product_id)):
        die("product_id de accounting inválido.", 64)
    if not SOURCE_EPOCH_RE.fullmatch(str(source_epoch)):
        die("source_epoch de accounting inválido.", 64)
    params = {
        "identity_id": identity_id, "product_id": str(product_id), "source_epoch": str(source_epoch),
        "download_bytes": accounting_int(download, "download-bytes"),
        "upload_bytes": accounting_int(upload, "upload-bytes"),
        "wireguard_download_bytes": accounting_int(wg_download, "wg-download-bytes"),
        "wireguard_upload_bytes": accounting_int(wg_upload, "wg-upload-bytes"),
        "openvpn_download_bytes": accounting_int(ovpn_download, "ovpn-download-bytes"),
        "openvpn_upload_bytes": accounting_int(ovpn_upload, "ovpn-upload-bytes"),
        "traffic_complete": accounting_int(traffic_complete, "traffic-complete", 1),
        "sample_epoch": accounting_int(sample_epoch, "sample-epoch"),
    }
    result = node_request("usage_ingest", params)
    for key in ("identity_id", "product_id", "delta_bytes", "global_total_bytes", "baseline", "source_reset",
                "traffic_complete", "source_nodes", "quota_configured", "quota_bytes", "quota_used_bytes",
                "quota_remaining_bytes", "quota_exceeded", "quota_enforceable", "quota_action", "quota_cycle"):
        value = result.get(key, "")
        if isinstance(value, bool): value = 1 if value else 0
        print(f"{key}={value}")

'''
replace_once(p, "def node_allocation_pull(limit=4):", node_usage_func + "def node_allocation_pull(limit=4):")
replace_once(p,
'''    if cmd == "--release-node" and len(argv) == 3: node_release(argv[1], argv[2]); return
    if cmd == "--allocation-pull-node"''',
'''    if cmd == "--release-node" and len(argv) == 3: node_release(argv[1], argv[2]); return
    if cmd == "--usage-ingest-node" and len(argv) == 12:
        node_usage_ingest(*argv[1:]); return
    if cmd == "--allocation-pull-node"''')

# ---- manager CLI ----
p = "manager"
replace_once(p,
'''  manager hive login result ALLOCATION_ID OUT
                                  allocation/login global assinado da Colmeia (0.8.5)
  manager automation legacy status''',
'''  manager hive login result ALLOCATION_ID OUT
                                  allocation/login global assinado da Colmeia (0.8.5)
  manager hive accounting status|enable|disable|sync [ID]
  manager hive accounting controller status|list|show ID
  manager hive accounting quota set ID PRODUCT BYTES PERIOD ACTION
  manager hive accounting quota show ID|list|unset ID|import-local ID|sync-local
                                  accounting/franquia global da Colmeia (0.8.6)
  manager automation legacy status''')
accounting_case = r'''      accounting)
        case "${3:-status}" in
          status) exec "$MANAGER_HOME/modules/hive_accounting.sh" --status ;;
          enable) exec "$MANAGER_HOME/modules/hive_accounting.sh" --node-enable ;;
          disable) exec "$MANAGER_HOME/modules/hive_accounting.sh" --node-disable ;;
          sync) exec "$MANAGER_HOME/modules/hive_accounting.sh" --sync "${4:-}" ;;
          controller)
            case "${4:-status}" in
              status) exec "$MANAGER_HOME/modules/hive_accounting.sh" --controller-status ;;
              list) exec "$MANAGER_HOME/modules/hive_accounting.sh" --controller-list ;;
              show) [[ -n "${5:-}" ]] || { err "Uso: manager hive accounting controller show ID"; exit 64; }; exec "$MANAGER_HOME/modules/hive_accounting.sh" --controller-show "$5" ;;
              *) err "Uso: manager hive accounting controller {status|list|show ID}"; exit 64 ;;
            esac
            ;;
          quota)
            case "${4:-list}" in
              set) [[ -n "${5:-}" && -n "${6:-}" && -n "${7:-}" && -n "${8:-}" && -n "${9:-}" ]] || { err "Uso: manager hive accounting quota set ID PRODUCT BYTES PERIOD ACTION"; exit 64; }; exec "$MANAGER_HOME/modules/hive_accounting.sh" --quota-set "$5" "$6" "$7" "$8" "$9" ;;
              show) [[ -n "${5:-}" ]] || { err "Uso: manager hive accounting quota show ID"; exit 64; }; exec "$MANAGER_HOME/modules/hive_accounting.sh" --quota-show "$5" ;;
              list) exec "$MANAGER_HOME/modules/hive_accounting.sh" --quota-list ;;
              unset) [[ -n "${5:-}" ]] || { err "Uso: manager hive accounting quota unset ID"; exit 64; }; exec "$MANAGER_HOME/modules/hive_accounting.sh" --quota-unset "$5" ;;
              import-local) [[ -n "${5:-}" ]] || { err "Uso: manager hive accounting quota import-local ID"; exit 64; }; exec "$MANAGER_HOME/modules/hive_accounting.sh" --quota-import-local "$5" ;;
              sync-local) exec "$MANAGER_HOME/modules/hive_accounting.sh" --quota-sync-local ;;
              *) err "Uso: manager hive accounting quota {set|show|list|unset|import-local|sync-local} ..."; exit 64 ;;
            esac
            ;;
          *) err "Uso: manager hive accounting {status|enable|disable|sync [ID]|controller ...|quota ...}"; exit 64 ;;
        esac
        ;;
'''
replace_once(p, "      node)\n        case \"${3:-status}\" in", accounting_case + "      node)\n        case \"${3:-status}\" in")

# ---- installer / uninstall / lifecycle ----
p = "install.sh"
replace_once(p, '  "modules/hive_allocations.sh"\n  "modules/hive_lifecycle.sh"', '  "modules/hive_allocations.sh"\n  "modules/hive_accounting.sh"\n  "modules/hive_lifecycle.sh"')
replace_once(p,
'''"$INSTALL_DIR/modules/hive_allocations.sh" --install >/dev/null 2>&1 || {
  echo "[AVISO] O estado de allocation 0.8.5 não pôde ser inicializado. Use: manager hive allocation status" >&2
}
"$INSTALL_DIR/modules/resellers.sh"''',
'''"$INSTALL_DIR/modules/hive_allocations.sh" --install >/dev/null 2>&1 || {
  echo "[AVISO] O estado de allocation 0.8.5 não pôde ser inicializado. Use: manager hive allocation status" >&2
}
"$INSTALL_DIR/modules/hive_accounting.sh" --install >/dev/null 2>&1 || {
  echo "[AVISO] O accounting global 0.8.6 não pôde ser reanexado. Use: manager hive accounting status" >&2
}
"$INSTALL_DIR/modules/resellers.sh"''')
replace_once(p, 'echo "Leases globais: manager hive lease status"', 'echo "Leases globais: manager hive lease status"\necho "Accounting global: manager hive accounting status"')

p = "uninstall.sh"
accounting_uninstall = r'''# Accounting global 0.8.6 usa timer apenas no nó. Estado agregado, snapshots e
# políticas de franquia sobrevivem ao uninstall normal; --purge remove tudo.
if [[ -x /opt/manager/modules/hive_accounting.sh ]]; then
  if $PURGE; then
    /opt/manager/modules/hive_accounting.sh --purge >/dev/null 2>&1 || true
  else
    /opt/manager/modules/hive_accounting.sh --detach >/dev/null 2>&1 || true
  fi
else
  systemctl disable --now manager-hive-accounting-sync.timer >/dev/null 2>&1 || true
  systemctl stop manager-hive-accounting-sync.service >/dev/null 2>&1 || true
  for unit in /etc/systemd/system/manager-hive-accounting-sync.service /etc/systemd/system/manager-hive-accounting-sync.timer; do
    if [[ -f "$unit" ]] && grep -Fqx '# MANAGER-HIVE-GLOBAL-ACCOUNTING v1' "$unit" 2>/dev/null; then rm -f "$unit"; fi
  done
  if $PURGE; then
    rm -rf /etc/manager/hive/accounting /etc/manager/hive/controller/accounting /var/lib/manager/hive-accounting
    rm -f /var/log/manager/hive-accounting-audit.jsonl
  fi
  systemctl daemon-reload >/dev/null 2>&1 || true
fi

'''
replace_once(p, '# Allocation 0.8.5 não possui daemon.', accounting_uninstall + '# Allocation 0.8.5 não possui daemon.')

p = "modules/hive_lifecycle.sh"
replace_once(p,
'''LEASE_MODULE="$MANAGER_HOME/modules/hive_leases.sh"
DROPIN_FILE=''',
'''LEASE_MODULE="$MANAGER_HOME/modules/hive_leases.sh"
ACCOUNTING_MODULE="$MANAGER_HOME/modules/hive_accounting.sh"
DROPIN_FILE=''')
replace_once(p,
'''    if [[ -x "$LEASE_MODULE" ]]; then
      "$LEASE_MODULE" --install >/dev/null 2>&1 || true
    fi
    ;;''',
'''    if [[ -x "$LEASE_MODULE" ]]; then
      "$LEASE_MODULE" --install >/dev/null 2>&1 || true
    fi
    if [[ -x "$ACCOUNTING_MODULE" ]]; then
      "$ACCOUNTING_MODULE" --install >/dev/null 2>&1 || true
    fi
    ;;''')
replace_once(p,
'''  stop)
    if [[ -x "$LEASE_MODULE" ]]; then''',
'''  stop)
    if [[ -x "$ACCOUNTING_MODULE" ]]; then
      "$ACCOUNTING_MODULE" --detach >/dev/null 2>&1 || true
    else
      systemctl disable --now manager-hive-accounting-sync.timer >/dev/null 2>&1 || true
      systemctl stop manager-hive-accounting-sync.service >/dev/null 2>&1 || true
    fi
    if [[ -x "$LEASE_MODULE" ]]; then''')
replace_once(p,
'''  local dropin="0" helper="0" health="0" leases="0"''',
'''  local dropin="0" helper="0" health="0" leases="0" accounting="0"''')
replace_once(p,
'''  if [[ -x "$MANAGER_HOME/modules/hive_leases.sh" ]]; then
    leases="1"
  fi
  printf 'contract=manager-hive-lifecycle-v1\\ndropin=%s\\nhelper=%s\\nhealth_module=%s\\nglobal_lease_module=%s\\nautomation_service=manager-automation-v2.service\\n' "$dropin" "$helper" "$health" "$leases"''',
'''  if [[ -x "$MANAGER_HOME/modules/hive_leases.sh" ]]; then
    leases="1"
  fi
  if [[ -x "$MANAGER_HOME/modules/hive_accounting.sh" ]]; then
    accounting="1"
  fi
  printf 'contract=manager-hive-lifecycle-v1\\ndropin=%s\\nhelper=%s\\nhealth_module=%s\\nglobal_lease_module=%s\\nglobal_accounting_module=%s\\nautomation_service=manager-automation-v2.service\\n' "$dropin" "$helper" "$health" "$leases" "$accounting"''')

# ---- roadmap / HIVE docs ----
p = "docs/ROADMAP.md"
replace_once(p,
'''### 0.8.6 — quotas e accounting globais

- ingestão idempotente de deltas por nó;
- deduplicação;
- franquia global;
- telemetria local 0.6.11 continua não autoritativa sozinha;
- proteção contra double counting após failover/reconnect;
- quota e `max_sessions` permanecem autoridades distintas.''',
'''### 0.8.6 — quotas e accounting globais 🚧

Implementado na fundação desta fase:

- cada nó envia snapshot cumulativo de uso por identidade pelo mesmo canal Ed25519 + TLS 1.3 pinado da autoridade de leases;
- o controlador deriva deltas por `(node_id, identity_id, source_epoch)`, tornando redelivery/reconnect idempotente;
- contador menor na mesma geração é recusado em vez de ser reinterpretado e contado novamente;
- mudança explícita de geração cria novo baseline sem somar o snapshot inicial, protegendo contra double counting após reset;
- uso de múltiplos nós é agregado em estado global root-only por identidade;
- franquia global possui política própria por identidade/produto, com `monthly`/`lifetime` e ação `warn`/`block`;
- grant/acquire global recusam novas sessões quando a franquia global `block` está excedida e a cobertura de bytes é completa;
- identidade com SSH continua marcada como cobertura parcial (`ssh_bytes_supported=0`), portanto não recebe bloqueio incorreto por bytes não medidos;
- telemetria local 0.6.11 continua não autoritativa sozinha: somente o estado agregado aceito pelo controlador é global;
- quota global e `max_sessions_global` permanecem autoridades e estados distintos.''')

append_once("docs/HIVE.md", "## 21. Accounting global — fundação 0.8.6", r'''
## 21. Accounting global — fundação 0.8.6

A 0.8.6 adiciona uma autoridade global de **uso medido**, separada da autoridade de sessões. O nó continua coletando WireGuard/OpenVPN localmente com `identity_usage.sh`, mas esse estado isolado não é billing global. Quando o accounting da Colmeia está habilitado, cada nó enrolled envia snapshots cumulativos assinados pelo mesmo canal Ed25519 + TLS 1.3 pinado usado pelas leases.

```bash
manager hive accounting enable
manager hive accounting status
manager hive accounting sync        # opcional; timer executa periodicamente
```

O controlador mantém uma origem por `(node_id, identity_id)`. Dentro da mesma `source_epoch`, somente a diferença positiva entre o snapshot novo e o anterior entra no agregado. Reenvio idêntico produz delta zero; amostra stale ou regressão de contador é recusada. Se a geração do medidor mudar, o primeiro snapshot vira baseline e não é somado novamente.

Estado persistente:

```text
/etc/manager/hive/controller/accounting/quotas/     políticas globais de franquia
/var/lib/manager/hive-accounting/controller/sources/ snapshots aceitos por nó/identidade
/var/lib/manager/hive-accounting/controller/identities/ agregado global
/var/log/manager/hive-accounting-audit.jsonl        ingest/dedup/quota deny
```

### Franquia global

A política é intencionalmente separada de `max_sessions_global`:

```bash
manager hive accounting quota set maria PREMIUM 107374182400 monthly block
manager hive accounting quota show maria
manager hive accounting quota list
```

Também é possível importar a franquia do produto local do controlador:

```bash
manager hive accounting quota import-local maria
manager hive accounting quota sync-local
```

Quando uma política `block` está excedida **e** `traffic_complete=1`, novos grants/acquires são recusados com `global-traffic-quota-exceeded`. Isso não altera `max_sessions_global`, não revoga automaticamente uma sessão existente e não reutiliza o contador de sessões como contador de bytes.

### Limite conhecido de SSH

A coleta 0.6.11 mede bytes de WireGuard e OpenVPN. SSH registra sessão/atividade, mas não bytes (`ssh_bytes_supported=0`). Por isso uma identidade que ainda possui binding SSH é marcada como cobertura parcial e a franquia global não é usada para bloquear por bytes incompletos. O total agregado continua visível, mas `quota_enforceable=0` evita um falso positivo de billing.

### Lifecycle

O timer `manager-hive-accounting-sync.timer` é apenas um produtor de telemetria do nó. Uninstall normal o destaca e preserva configuração, snapshots globais, baselines e audit. `manager-uninstall --purge` remove o estado persistente da 0.8.6. O controlador continua fora do caminho de dados VPN.
''')
