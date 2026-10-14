from pathlib import Path

def replace_once(path, old, new):
    p = Path(path)
    s = p.read_text()
    count = s.count(old)
    if count != 1:
        raise SystemExit(f"{path}: anchor count {count} for {old[:100]!r}")
    p.write_text(s.replace(old, new, 1))

path = "modules/hive_observability.sh"

replace_once(
    path,
    '''AUDIT_FILE = os.environ.get("MANAGER_HIVE_OBSERVABILITY_AUDIT_FILE", "/var/log/manager/hive-observability-audit.jsonl")
LOCK_FILE = os.path.join(DATA_DIR, ".lock")''',
    '''AUDIT_FILE = os.environ.get("MANAGER_HIVE_OBSERVABILITY_AUDIT_FILE", "/var/log/manager/hive-observability-audit.jsonl")
AUDIT_ARCHIVE_ROOT = os.path.join(DATA_DIR, "audit-archive")
SCHED_ARCHIVE_DIR = os.path.join(AUDIT_ARCHIVE_ROOT, "scheduler")
LEASE_ARCHIVE_DIR = os.path.join(AUDIT_ARCHIVE_ROOT, "leases")
LOCK_FILE = os.path.join(DATA_DIR, ".lock")'''
)

replace_once(
    path,
    '''DEFAULT_RETENTION = 7 * 24 * 3600
MAX_RETENTION = 90 * 24 * 3600
MAX_LINE = 256 * 1024''',
    '''DEFAULT_RETENTION = 7 * 24 * 3600
DEFAULT_AUDIT_RETENTION = 14 * 24 * 3600
DEFAULT_AUDIT_MAX_BYTES = 4 * 1024 * 1024
MAX_AUDIT_MAX_BYTES = 512 * 1024 * 1024
MAX_RETENTION = 90 * 24 * 3600
MAX_LINE = 256 * 1024'''
)

replace_once(
    path,
    '''    ensure_dir(DATA_DIR, 0o700)
    Path(LOCK_FILE).touch(mode=0o600, exist_ok=True)''',
    '''    ensure_dir(DATA_DIR, 0o700)
    ensure_dir(AUDIT_ARCHIVE_ROOT, 0o700)
    ensure_dir(SCHED_ARCHIVE_DIR, 0o700)
    ensure_dir(LEASE_ARCHIVE_DIR, 0o700)
    Path(LOCK_FILE).touch(mode=0o600, exist_ok=True)'''
)

replace_once(
    path,
    '''def retention_seconds(value=None):
    raw = value if value not in (None, "") else os.environ.get("MANAGER_HIVE_OBSERVABILITY_RETENTION_SECONDS", str(DEFAULT_RETENTION))
    return parse_int(raw, "retention_seconds", 3600, MAX_RETENTION)


def read_json_file(path):
''',
    '''def retention_seconds(value=None):
    raw = value if value not in (None, "") else os.environ.get("MANAGER_HIVE_OBSERVABILITY_RETENTION_SECONDS", str(DEFAULT_RETENTION))
    return parse_int(raw, "retention_seconds", 3600, MAX_RETENTION)


def audit_retention_seconds(value=None):
    raw = value if value not in (None, "") else os.environ.get(
        "MANAGER_HIVE_OBSERVABILITY_AUDIT_RETENTION_SECONDS", str(DEFAULT_AUDIT_RETENTION)
    )
    return parse_int(raw, "audit_retention_seconds", 3600, MAX_RETENTION)


def audit_max_bytes(value=None):
    raw = value if value not in (None, "") else os.environ.get(
        "MANAGER_HIVE_OBSERVABILITY_AUDIT_MAX_BYTES", str(DEFAULT_AUDIT_MAX_BYTES)
    )
    return parse_int(raw, "audit_max_bytes", 1024, MAX_AUDIT_MAX_BYTES)


def read_json_file(path):
'''
)

replace_once(
    path,
    '''def tail_records(path, limit, predicate=None, sanitizer=None, since=0):
    out = deque(maxlen=limit)
    for obj in iter_jsonl(path) or ():
        try:
            epoch = int(obj.get("epoch", obj.get("received_at", 0)))
        except (TypeError, ValueError):
            continue
        if epoch < since:
            continue
        if predicate and not predicate(obj):
            continue
        if sanitizer:
            obj = sanitizer(obj)
            if obj is None:
                continue
        out.append(obj)
    return list(out)
''',
    '''def tail_records_many(paths, limit, predicate=None, sanitizer=None, since=0):
    out = deque(maxlen=limit)
    for path in paths:
        for obj in iter_jsonl(path) or ():
            try:
                epoch = int(obj.get("epoch", obj.get("received_at", 0)))
            except (TypeError, ValueError):
                continue
            if epoch < since:
                continue
            if predicate and not predicate(obj):
                continue
            if sanitizer:
                obj = sanitizer(obj)
                if obj is None:
                    continue
            out.append(obj)
    return list(out)


def tail_records(path, limit, predicate=None, sanitizer=None, since=0):
    return tail_records_many([path], limit, predicate, sanitizer, since)


def audit_archive_files(kind):
    archive_dir = SCHED_ARCHIVE_DIR if kind == "scheduler" else LEASE_ARCHIVE_DIR
    if not os.path.isdir(archive_dir):
        return []
    return [str(path) for path in sorted(Path(archive_dir).glob("*.jsonl")) if strict_regular(str(path))]


def audit_source_paths(kind):
    if kind == "scheduler":
        active = SCHED_AUDIT
    elif kind == "leases":
        active = LEASE_AUDIT
    else:
        die("Fonte de audit inválida.", 64)
    paths = audit_archive_files(kind)
    if strict_regular(active):
        paths.append(active)
    return paths


def next_archive_path(kind, archive_dir):
    ensure_dir(archive_dir, 0o700)
    epoch = int(time.time())
    for seq in range(1000):
        path = os.path.join(archive_dir, f"{kind}-{epoch}-{seq:03d}.jsonl")
        if not os.path.lexists(path):
            return path
    die("Não foi possível reservar nome para segmento de audit.", 70)


def rotate_audit_locked(kind, active, archive_dir, max_bytes, force=False):
    if not strict_regular(active):
        return 0, ""
    try:
        size = os.path.getsize(active)
    except OSError:
        return 0, ""
    if size <= 0 or (not force and size < max_bytes):
        return 0, ""
    target = next_archive_path(kind, archive_dir)
    os.replace(active, target)
    os.chmod(target, 0o600)
    try:
        fd = os.open(active, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        os.close(fd)
    except FileExistsError:
        pass
    if os.path.exists(active):
        os.chmod(active, 0o600)
    return 1, target


def prune_audit_archives_locked(retention):
    cutoff = int(time.time()) - retention
    removed = {"scheduler": 0, "leases": 0}
    for kind, archive_dir in (("scheduler", SCHED_ARCHIVE_DIR), ("leases", LEASE_ARCHIVE_DIR)):
        if not os.path.isdir(archive_dir):
            continue
        for path in Path(archive_dir).glob("*.jsonl"):
            try:
                st = path.lstat()
            except FileNotFoundError:
                continue
            if not stat.S_ISREG(st.st_mode):
                continue
            if int(st.st_mtime) < cutoff:
                try:
                    path.unlink()
                    removed[kind] += 1
                except FileNotFoundError:
                    pass
    return removed


def audit_storage_stats(kind):
    active = SCHED_AUDIT if kind == "scheduler" else LEASE_AUDIT
    archives = audit_archive_files(kind)
    active_bytes = os.path.getsize(active) if strict_regular(active) else 0
    archive_bytes = 0
    for path in archives:
        try:
            archive_bytes += os.path.getsize(path)
        except OSError:
            pass
    return active_bytes, len(archives), archive_bytes


def audit_maintain(retention_value=None, max_bytes_value=None, force=False):
    init_dirs()
    retention = audit_retention_seconds(retention_value)
    max_bytes = audit_max_bytes(max_bytes_value)
    with open(LOCK_FILE, "r+", encoding="utf-8") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        sched_rotated, sched_path = rotate_audit_locked(
            "scheduler", SCHED_AUDIT, SCHED_ARCHIVE_DIR, max_bytes, force
        )
        lease_rotated, lease_path = rotate_audit_locked(
            "leases", LEASE_AUDIT, LEASE_ARCHIVE_DIR, max_bytes, force
        )
        removed = prune_audit_archives_locked(retention)
        fcntl.flock(lock.fileno(), fcntl.LOCK_UN)
    audit(
        "audit-maintain",
        retention_seconds=retention,
        max_bytes=max_bytes,
        scheduler_rotated=sched_rotated,
        leases_rotated=lease_rotated,
        scheduler_pruned=removed["scheduler"],
        leases_pruned=removed["leases"],
    )
    print(f"audit_retention_seconds={retention}")
    print(f"audit_max_bytes={max_bytes}")
    print(f"scheduler_rotated={sched_rotated}")
    print(f"leases_rotated={lease_rotated}")
    print(f"scheduler_pruned={removed['scheduler']}")
    print(f"leases_pruned={removed['leases']}")
    if sched_path:
        print(f"scheduler_archive={sched_path}")
    if lease_path:
        print(f"leases_archive={lease_path}")


def audit_status():
    init_dirs()
    retention = audit_retention_seconds()
    max_bytes = audit_max_bytes()
    sched_active, sched_segments, sched_archive = audit_storage_stats("scheduler")
    lease_active, lease_segments, lease_archive = audit_storage_stats("leases")
    print(f"contract={CONTRACT}")
    print(f"audit_retention_seconds={retention}")
    print(f"audit_max_bytes={max_bytes}")
    print(f"scheduler_active_bytes={sched_active}")
    print(f"scheduler_archive_segments={sched_segments}")
    print(f"scheduler_archive_bytes={sched_archive}")
    print(f"leases_active_bytes={lease_active}")
    print(f"leases_archive_segments={lease_segments}")
    print(f"leases_archive_bytes={lease_archive}")
    print("rotation_strategy=atomic-rename")
    print("archive_compression=0")
    print("controller_in_user_vpn_path=0")
'''
)

replace_once(
    path,
    '''def show_scheduler(limit):
    for obj in tail_records(SCHED_AUDIT, limit, sanitizer=sanitize_scheduler):
        print(json_line(obj))


def show_leases(identity_id, limit):
    if identity_id not in ("", "*") and not IDENTITY_RE.fullmatch(identity_id):
        die("identity_id inválido.", 64)
    pred = None if identity_id in ("", "*") else lambda o: o.get("identity_id") == identity_id
    for obj in tail_records(LEASE_AUDIT, limit, pred, sanitize_lease):
        print(json_line(obj))
''',
    '''def show_scheduler(limit):
    for obj in tail_records_many(audit_source_paths("scheduler"), limit, sanitizer=sanitize_scheduler):
        print(json_line(obj))


def show_leases(identity_id, limit):
    if identity_id not in ("", "*") and not IDENTITY_RE.fullmatch(identity_id):
        die("identity_id inválido.", 64)
    pred = None if identity_id in ("", "*") else lambda o: o.get("identity_id") == identity_id
    for obj in tail_records_many(audit_source_paths("leases"), limit, pred, sanitize_lease):
        print(json_line(obj))
'''
)

replace_once(
    path,
    '''    sched = tail_records(SCHED_AUDIT, MAX_LIMIT, sanitizer=sanitize_scheduler, since=since)
    leases = tail_records(LEASE_AUDIT, MAX_LIMIT, sanitizer=sanitize_lease, since=since)
''',
    '''    sched = tail_records_many(audit_source_paths("scheduler"), MAX_LIMIT, sanitizer=sanitize_scheduler, since=since)
    leases = tail_records_many(audit_source_paths("leases"), MAX_LIMIT, sanitizer=sanitize_lease, since=since)
'''
)

replace_once(
    path,
    '''    print(f"retention_seconds={retention_seconds()}")
    print("contains_private_keys=0")
''',
    '''    print(f"retention_seconds={retention_seconds()}")
    print(f"audit_retention_seconds={audit_retention_seconds()}")
    print(f"audit_max_bytes={audit_max_bytes()}")
    sched_active, sched_segments, sched_archive = audit_storage_stats("scheduler")
    lease_active, lease_segments, lease_archive = audit_storage_stats("leases")
    print(f"scheduler_active_bytes={sched_active}")
    print(f"scheduler_archive_segments={sched_segments}")
    print(f"scheduler_archive_bytes={sched_archive}")
    print(f"leases_active_bytes={lease_active}")
    print(f"leases_archive_segments={lease_segments}")
    print(f"leases_archive_bytes={lease_archive}")
    print("contains_private_keys=0")
'''
)

replace_once(
    path,
    '''    print("Uso: hive_observability.sh --status|--summary [WINDOW]|--health [NODE|*] [LIMIT]|--scheduler [LIMIT]|--leases [IDENTITY|*] [LIMIT]|--prune [SECONDS]", file=sys.stderr)''',
    '''    print("Uso: hive_observability.sh --status|--summary [WINDOW]|--health [NODE|*] [LIMIT]|--scheduler [LIMIT]|--leases [IDENTITY|*] [LIMIT]|--prune [SECONDS]|--audit-status|--audit-maintain [RETENTION] [MAX_BYTES] [force]", file=sys.stderr)'''
)

replace_once(
    path,
    '''elif cmd == "--prune":
    prune(args[1] if len(args) > 1 else None)
else:
    usage()
''',
    '''elif cmd == "--prune":
    prune(args[1] if len(args) > 1 else None)
elif cmd == "--audit-status":
    audit_status()
elif cmd == "--audit-maintain":
    if len(args) > 4:
        usage()
    force = len(args) > 3 and args[3].lower() in {"1", "true", "yes", "force"}
    if len(args) > 3 and not force:
        die("Terceiro argumento deve ser 'force' quando informado.", 64)
    audit_maintain(args[1] if len(args) > 1 else None, args[2] if len(args) > 2 else None, force)
else:
    usage()
'''
)

replace_once(
    "manager",
    '''  manager hive observe leases [IDENTITY_ID|*] [LIMIT]
  manager hive observe prune [RETENTION_SECONDS]
                                  histórico/summary sanitizado do control plane (0.8.10)
''',
    '''  manager hive observe leases [IDENTITY_ID|*] [LIMIT]
  manager hive observe prune [RETENTION_SECONDS]
  manager hive observe audit-status
  manager hive observe audit-maintain [RETENTION_SECONDS] [MAX_BYTES] [force]
                                  histórico/summary e retenção sanitizada do control plane (0.8.10)
'''
)

replace_once(
    "manager",
    '''          prune) if [[ -n "${4:-}" ]]; then exec "$MANAGER_HOME/modules/hive_observability.sh" --prune "$4"; else exec "$MANAGER_HOME/modules/hive_observability.sh" --prune; fi ;;
          *) err "Uso: manager hive observe {status|summary [WINDOW]|health [NODE|*] [LIMIT]|scheduler [LIMIT]|leases [ID|*] [LIMIT]|prune [SECONDS]}"; exit 64 ;;
''',
    '''          prune) if [[ -n "${4:-}" ]]; then exec "$MANAGER_HOME/modules/hive_observability.sh" --prune "$4"; else exec "$MANAGER_HOME/modules/hive_observability.sh" --prune; fi ;;
          audit-status) exec "$MANAGER_HOME/modules/hive_observability.sh" --audit-status ;;
          audit-maintain) exec "$MANAGER_HOME/modules/hive_observability.sh" --audit-maintain "${4:-}" "${5:-}" "${6:-}" ;;
          *) err "Uso: manager hive observe {status|summary [WINDOW]|health [NODE|*] [LIMIT]|scheduler [LIMIT]|leases [ID|*] [LIMIT]|prune [SECONDS]|audit-status|audit-maintain [RETENTION] [MAX_BYTES] [force]}"; exit 64 ;;
'''
)

replace_once(
    "docs/HIVE_OBSERVABILITY.md",
    '''## Retenção

O histórico de health usa retenção temporal. O padrão inicial é 7 dias e pode ser ajustado por `MANAGER_HIVE_OBSERVABILITY_RETENTION_SECONDS`, limitado a 90 dias nesta fase.

O scheduler e a autoridade de leases continuam donos dos próprios audits. A observabilidade apenas sanitiza e consulta esses arquivos; não os copia.
''',
    '''## Retenção e rotação dos audits

O histórico de health usa retenção temporal. O padrão inicial é 7 dias e pode ser ajustado por `MANAGER_HIVE_OBSERVABILITY_RETENTION_SECONDS`, limitado a 90 dias nesta fase.

Scheduler e autoridade de leases continuam sendo os escritores dos próprios audits. A observabilidade agora coordena apenas a **rotação operacional** desses dois JSONL:

- o arquivo ativo é movido por `rename` atômico para um segmento root-only;
- a rotação nunca trunca o audit em lugar;
- um writer que já abriu o descritor antigo termina de escrever no segmento renomeado;
- writers seguintes continuam no arquivo ativo recriado;
- segmentos não são comprimidos nesta fase, evitando corrida entre compressão e writer ainda aberto;
- consultas `scheduler`, `leases` e `summary` leem segmentos arquivados + arquivo ativo como uma única linha do tempo;
- retenção remove somente segmentos arquivados fora da janela, nunca o arquivo ativo.

O padrão de retenção dos audits é 14 dias (`MANAGER_HIVE_OBSERVABILITY_AUDIT_RETENTION_SECONDS`) e o limiar padrão de rotação é 4 MiB (`MANAGER_HIVE_OBSERVABILITY_AUDIT_MAX_BYTES`). A janela continua limitada a 90 dias e o limiar a 512 MiB.
'''
)

replace_once(
    "docs/HIVE_OBSERVABILITY.md",
    '''manager hive observe leases [IDENTITY_ID|*] [LIMIT]
manager hive observe prune [RETENTION_SECONDS]
```
''',
    '''manager hive observe leases [IDENTITY_ID|*] [LIMIT]
manager hive observe prune [RETENTION_SECONDS]
manager hive observe audit-status
manager hive observe audit-maintain [RETENTION_SECONDS] [MAX_BYTES] [force]
```
'''
)

replace_once(
    "docs/HIVE_OBSERVABILITY.md",
    '''## Escopo desta fatia

Esta fundação não fecha a 0.8.10 inteira. Ainda ficam para as próximas fatias: retenção/rotação coordenada dos audits existentes, export estruturado para integração externa, métricas temporais mais completas e gate final multi-nó da release.
''',
    '''## Escopo desta fatia

A segunda fatia fecha a retenção/rotação coordenada dos audits de scheduler e leases sem mudar quem escreve ou decide no control plane. A 0.8.10 ainda não está fechada: permanecem export estruturado para integração externa, séries temporais/métricas adicionais e o gate final multi-nó da release.
'''
)

replace_once(
    "docs/ROADMAP.md",
    '''- observabilidade failure-isolated: erro no histórico não invalida heartbeat aceito;
- controlador continua fora do caminho de dados VPN.

Ainda pendente para fechar a 0.8.10:

- retenção/rotação coordenada dos audits existentes;
- export estruturado/integração externa;
''',
    '''- observabilidade failure-isolated: erro no histórico não invalida heartbeat aceito;
- rotação coordenada dos audits de scheduler/leases por rename atômico, sem truncar em lugar;
- consultas sanitizadas continuam atravessando segmentos arquivados + arquivo ativo;
- retenção temporal remove somente segmentos antigos, com armazenamento root-only e sem compressão concorrente;
- controlador continua fora do caminho de dados VPN.

Ainda pendente para fechar a 0.8.10:

- export estruturado/integração externa;
'''
)

for name in (path, "manager", "docs/HIVE_OBSERVABILITY.md", "docs/ROADMAP.md"):
    p = Path(name)
    p.write_text(p.read_text().rstrip() + "\n")
