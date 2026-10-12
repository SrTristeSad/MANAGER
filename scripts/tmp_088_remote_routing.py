from pathlib import Path


def replace_once(path, old, new):
    p = Path(path)
    s = p.read_text()
    if old not in s:
        raise SystemExit(f"anchor missing in {path}: {old[:140]!r}")
    p.write_text(s.replace(old, new, 1))


# Automation v2: reuse the already trusted Hive controller key as a special remote principal.
p = 'modules/automation_v2.sh'
replace_once(p,
'''NODE_CONF = os.path.join(MANAGER_ETC, "connection", "node", "node.conf")
CONTRACT = "manager-automation-v2-local-v1"
''',
'''NODE_CONF = os.path.join(MANAGER_ETC, "connection", "node", "node.conf")
HIVE_CONTROLLER_ID = "hive-controller"
HIVE_NODE_CONTROLLER_PUB = os.path.join(MANAGER_ETC, "hive", "node", "controller.pub")
HIVE_NODE_ENROLLMENT = os.path.join(MANAGER_ETC, "hive", "node", "enrollment.conf")
HIVE_CONTROLLER_CONF = os.path.join(MANAGER_ETC, "hive", "controller", "controller.conf")
HIVE_CONTROLLER_KEY = os.path.join(MANAGER_ETC, "hive", "controller", "controller.key")
HIVE_CONTROLLER_PUB = os.path.join(MANAGER_ETC, "hive", "controller", "controller.pub")
HIVE_CONTROLLER_POLICY = os.path.join(STATE_DIR, "hive-controller.conf")
CONTRACT = "manager-automation-v2-local-v1"
''')
replace_once(p,
'''def load_principal(principal_id):
    if not isinstance(principal_id, str) or not PRINCIPAL_RE.fullmatch(principal_id):
        raise PermissionError("principal_id inválido")
    data = read_conf(os.path.join(PRINCIPALS_DIR, principal_id + ".conf"), strict=True)
''',
'''def load_principal(principal_id):
    if not isinstance(principal_id, str) or not PRINCIPAL_RE.fullmatch(principal_id):
        raise PermissionError("principal_id inválido")
    if principal_id == HIVE_CONTROLLER_ID:
        return load_hive_controller_principal()
    data = read_conf(os.path.join(PRINCIPALS_DIR, principal_id + ".conf"), strict=True)
''')
replace_once(p,
'''def scope_allows(scope, value):
    return scope == "*" or (bool(value) and value in set(scope.split(",")))


def canonical_auth_payload(request):
''',
'''def scope_allows(scope, value):
    return scope == "*" or (bool(value) and value in set(scope.split(",")))


def load_hive_controller_principal():
    policy = read_conf(HIVE_CONTROLLER_POLICY, strict=True)
    enrollment = read_conf(HIVE_NODE_ENROLLMENT, strict=True)
    if not policy or policy.get("version") != "1" or policy.get("enabled") != "1":
        raise PermissionError("autoridade remota do controlador não está habilitada neste nó")
    if not enrollment or enrollment.get("version") != "1":
        raise PermissionError("nó não possui enrollment válido para autoridade remota")
    ctx = local_node_context()
    node_id = ctx.get("node_id", "")
    if not node_id or policy.get("node_id") != node_id or enrollment.get("node_id") != node_id:
        raise PermissionError("política remota não corresponde ao node_id local")
    controller_id = enrollment.get("controller_id", "")
    if not re.fullmatch(r"controller-[a-f0-9]{16}", controller_id) or policy.get("controller_id") != controller_id:
        raise PermissionError("política remota pertence a outro controlador")
    try:
        policy_epoch = int(policy.get("node_epoch", "0"))
        enrollment_epoch = int(enrollment.get("node_epoch", "0"))
    except ValueError as exc:
        raise PermissionError("node_epoch remoto inválido") from exc
    if policy_epoch < 1 or policy_epoch != enrollment_epoch:
        raise PermissionError("política remota cercada por node_epoch")
    action_scope = policy.get("action_scope", "")
    if not action_scope or action_scope == "*":
        raise PermissionError("controlador Hive exige action_scope explícito")
    validate_scope(action_scope, "action")
    return {"principal_id": HIVE_CONTROLLER_ID, "role": "admin", "subject": "*", "products": "*",
            "node_scope": node_id, "pool_scope": ctx.get("pool", "") or "*", "action_scope": action_scope}


def hive_controller_public(key_id):
    if not isinstance(key_id, str) or not KEY_ID_RE.fullmatch(key_id):
        raise PermissionError("key_id do controlador Hive inválido")
    enrollment = read_conf(HIVE_NODE_ENROLLMENT, strict=True)
    if not enrollment:
        raise PermissionError("enrollment Hive ausente")
    try:
        st = os.lstat(HIVE_NODE_CONTROLLER_PUB)
    except FileNotFoundError as exc:
        raise PermissionError("chave pública do controlador Hive ausente") from exc
    if not stat.S_ISREG(st.st_mode) or st.st_uid != 0 or stat.S_IMODE(st.st_mode) & 0o077:
        raise PermissionError("chave pública do controlador Hive insegura")
    proc = subprocess.run(["openssl", "pkey", "-pubin", "-in", HIVE_NODE_CONTROLLER_PUB, "-outform", "DER"],
                          stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10, check=False)
    if proc.returncode != 0 or not proc.stdout:
        raise PermissionError("chave pública do controlador Hive inválida")
    digest = hashlib.sha256(proc.stdout).digest()
    expected_key_id = "ed25519-" + digest.hex()[:16]
    expected_controller_id = "controller-" + digest.hex()[:16]
    expected_hive_fp = "SHA256:" + digest.hex()
    if key_id != expected_key_id or enrollment.get("controller_id") != expected_controller_id or enrollment.get("controller_fingerprint") != expected_hive_fp:
        raise PermissionError("identidade pública do controlador Hive não confere")
    fingerprint = "SHA256:" + base64.b64encode(digest).decode("ascii").rstrip("=")
    return HIVE_NODE_CONTROLLER_PUB, fingerprint


def canonical_auth_payload(request):
''')
replace_once(p,
'''def load_credential(principal_id, key_id):
    if not isinstance(key_id, str) or not KEY_ID_RE.fullmatch(key_id):
        raise PermissionError("key_id inválido")
''',
'''def load_credential(principal_id, key_id):
    if principal_id == HIVE_CONTROLLER_ID:
        return hive_controller_public(key_id)
    if not isinstance(key_id, str) or not KEY_ID_RE.fullmatch(key_id):
        raise PermissionError("key_id inválido")
''')
replace_once(p,
'''def load_client_credential(path):
    try: st = os.lstat(path)
''',
'''def load_hive_controller_credential():
    conf = read_conf(HIVE_CONTROLLER_CONF, strict=True)
    if not conf or conf.get("version") != "1":
        raise ValueError("controlador Hive não está inicializado")
    for path in (HIVE_CONTROLLER_KEY, HIVE_CONTROLLER_PUB):
        try:
            st = os.lstat(path)
        except FileNotFoundError as exc:
            raise ValueError("material de chave do controlador Hive ausente") from exc
        if not stat.S_ISREG(st.st_mode) or st.st_uid != 0 or stat.S_IMODE(st.st_mode) & 0o077:
            raise PermissionError("material de chave do controlador Hive inseguro")
    pub_proc = subprocess.run(["openssl", "pkey", "-pubin", "-in", HIVE_CONTROLLER_PUB, "-outform", "DER"],
                              stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10, check=False)
    key_proc = subprocess.run(["openssl", "pkey", "-in", HIVE_CONTROLLER_KEY, "-pubout", "-outform", "DER"],
                              stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10, check=False)
    if pub_proc.returncode != 0 or key_proc.returncode != 0 or not pub_proc.stdout or pub_proc.stdout != key_proc.stdout:
        raise PermissionError("par de chaves do controlador Hive inconsistente")
    digest = hashlib.sha256(pub_proc.stdout).digest()
    controller_id = "controller-" + digest.hex()[:16]
    if conf.get("controller_id") != controller_id or conf.get("fingerprint") != "SHA256:" + digest.hex():
        raise PermissionError("identidade do controlador Hive não confere com a chave")
    with open(HIVE_CONTROLLER_KEY, "r", encoding="utf-8") as fh:
        private_pem = fh.read()
    return {"version": 1, "principal_id": HIVE_CONTROLLER_ID,
            "key_id": "ed25519-" + digest.hex()[:16], "algorithm": "ed25519",
            "fingerprint": "SHA256:" + base64.b64encode(digest).decode("ascii").rstrip("="),
            "private_key_pem": private_pem}


def load_client_credential(path):
    try: st = os.lstat(path)
''')
replace_once(p,
'''def call_client(argv):
    principal_id = credential_file = remote = server_fingerprint = None
    args = list(argv)
    while args:
        item = args[0]
        if item in {"--principal", "--credential", "--remote", "--server-fingerprint"}:
''',
'''def call_client(argv):
    principal_id = credential_file = remote = server_fingerprint = None
    hive_controller = False
    args = list(argv)
    while args:
        item = args[0]
        if item == "--hive-controller":
            hive_controller = True
            args = args[1:]
            continue
        if item in {"--principal", "--credential", "--remote", "--server-fingerprint"}:
''')
replace_once(p,
'''    credential = load_client_credential(credential_file) if credential_file else None
    if credential:
        if principal_id is not None and principal_id != credential["principal_id"]: raise ValueError("--principal não corresponde ao principal da credencial")
        principal_id = credential["principal_id"]
''',
'''    if hive_controller and (credential_file is not None or principal_id is not None):
        raise ValueError("--hive-controller não pode ser combinado com --principal/--credential")
    credential = load_hive_controller_credential() if hive_controller else (load_client_credential(credential_file) if credential_file else None)
    if credential:
        if principal_id is not None and principal_id != credential["principal_id"]: raise ValueError("--principal não corresponde ao principal da credencial")
        principal_id = credential["principal_id"]
    if hive_controller and not remote:
        raise ValueError("--hive-controller exige transporte --remote")
''')
replace_once(p,
'''  printf 'remote_scoped_rbac=1\\nremote_node_scope=1\\nremote_pool_scope=1\\nremote_action_scope=1\\n'
''',
'''  printf 'remote_scoped_rbac=1\\nremote_node_scope=1\\nremote_pool_scope=1\\nremote_action_scope=1\\n'
  printf 'hive_controller_remote_auth=1\\nhive_controller_private_key_distribution=0\\n'
''')

# Installer downloads and initializes the new persistent route registry.
p = 'install.sh'
replace_once(p,
'''  "modules/hive_accounting.sh"
  "modules/hive_lifecycle.sh"
''',
'''  "modules/hive_accounting.sh"
  "modules/hive_remote.sh"
  "modules/hive_lifecycle.sh"
''')
replace_once(p,
'''"$INSTALL_DIR/modules/hive_accounting.sh" --install >/dev/null 2>&1 || {
  echo "[AVISO] O accounting global 0.8.6 não pôde ser reanexado. Use: manager hive accounting status" >&2
}
''',
'''"$INSTALL_DIR/modules/hive_accounting.sh" --install >/dev/null 2>&1 || {
  echo "[AVISO] O accounting global 0.8.6 não pôde ser reanexado. Use: manager hive accounting status" >&2
}
"$INSTALL_DIR/modules/hive_remote.sh" --install >/dev/null 2>&1 || {
  echo "[AVISO] O registro de roteamento remoto da Colmeia não pôde ser inicializado. Use: manager hive remote controller status" >&2
}
''')

# Uninstall preserves routing policy/state normally and purges it explicitly.
p = 'uninstall.sh'
replace_once(p,
'''# Automation v2 possui o socket Unix local e pode possuir o gateway TLS remoto.
''',
'''# Roteamento remoto 0.8.8 não possui daemon próprio. Rotas assinadas e política
# do controlador sobrevivem ao uninstall normal e são removidas apenas no purge.
if [[ -x /opt/manager/modules/hive_remote.sh ]]; then
  if $PURGE; then
    /opt/manager/modules/hive_remote.sh --purge >/dev/null 2>&1 || true
  else
    /opt/manager/modules/hive_remote.sh --detach >/dev/null 2>&1 || true
  fi
elif $PURGE; then
  rm -rf /etc/manager/hive/controller/remote
  rm -f /etc/manager/automation/v2/hive-controller.conf /var/log/manager/hive-remote-audit.jsonl
fi

# Automation v2 possui o socket Unix local e pode possuir o gateway TLS remoto.
''')

# CLI surface.
p = 'manager'
replace_once(p,
'''  manager hive accounting quota show ID|list|unset ID|import-local ID|sync-local
                                  accounting/franquia global da Colmeia (0.8.6)
''',
'''  manager hive accounting quota show ID|list|unset ID|import-local ID|sync-local
                                  accounting/franquia global da Colmeia (0.8.6)
  manager hive remote status
  manager hive remote node enable ENDPOINT ACTIONS OUT
  manager hive remote node disable OUT
  manager hive remote controller status|list
  manager hive remote controller show NODE_ID
  manager hive remote controller accept ADVERTISEMENT
  manager hive remote controller call NODE_ID ACTION [KEY=VALUE ...] [--request-id ID]
                                  roteamento remoto tipado e assinado da Colmeia (0.8.8)
''')
replace_once(p,
'''      controller)
        case "${3:-status}" in
''',
'''      remote)
        case "${3:-status}" in
          status) exec "$MANAGER_HOME/modules/hive_remote.sh" --status ;;
          node)
            case "${4:-status}" in
              status) exec "$MANAGER_HOME/modules/hive_remote.sh" --status ;;
              enable) [[ -n "${5:-}" && -n "${6:-}" && -n "${7:-}" ]] || { err "Uso: manager hive remote node enable ENDPOINT ACTIONS OUT"; exit 64; }; exec "$MANAGER_HOME/modules/hive_remote.sh" --node-enable "$5" "$6" "$7" ;;
              disable) [[ -n "${5:-}" ]] || { err "Uso: manager hive remote node disable OUT"; exit 64; }; exec "$MANAGER_HOME/modules/hive_remote.sh" --node-disable "$5" ;;
              *) err "Uso: manager hive remote node {status|enable|disable} ..."; exit 64 ;;
            esac
            ;;
          controller)
            case "${4:-status}" in
              status) exec "$MANAGER_HOME/modules/hive_remote.sh" --controller-status ;;
              list) exec "$MANAGER_HOME/modules/hive_remote.sh" --controller-list ;;
              show) [[ -n "${5:-}" ]] || { err "Uso: manager hive remote controller show NODE_ID"; exit 64; }; exec "$MANAGER_HOME/modules/hive_remote.sh" --controller-show "$5" ;;
              accept) [[ -n "${5:-}" ]] || { err "Uso: manager hive remote controller accept ADVERTISEMENT"; exit 64; }; exec "$MANAGER_HOME/modules/hive_remote.sh" --controller-accept "$5" ;;
              call) [[ -n "${5:-}" && -n "${6:-}" ]] || { err "Uso: manager hive remote controller call NODE_ID ACTION [ARGS...]"; exit 64; }; shift 6; exec "$MANAGER_HOME/modules/hive_remote.sh" --controller-call "$5" "$6" "$@" ;;
              *) err "Uso: manager hive remote controller {status|list|show|accept|call} ..."; exit 64 ;;
            esac
            ;;
          *) err "Uso: manager hive remote {status|node ...|controller ...}"; exit 64 ;;
        esac
        ;;
      controller)
        case "${3:-status}" in
''')
replace_once(p,
'''      *) err "Uso: manager hive {status|request|accept|network ...|health ...|node ...|lease ...|allocation ...|login ...|controller ...}"; exit 64 ;;
''',
'''      *) err "Uso: manager hive {status|request|accept|network ...|health ...|node ...|lease ...|allocation ...|login ...|remote ...|controller ...}"; exit 64 ;;
''')

# Documentation.
p = 'docs/AUTOMATION_V2.md'
replace_once(p,
'''A validação acontece **antes da idempotência e antes do dispatcher**. Assim, um `request_id` anteriormente autorizado não pode servir resultado em cache depois que o principal perde acesso à ação, ao nó ou ao pool. `local-root` continua reservado ao socket Unix local e não recebe escopo remoto configurável.
''',
'''A validação acontece **antes da idempotência e antes do dispatcher**. Assim, um `request_id` anteriormente autorizado não pode servir resultado em cache depois que o principal perde acesso à ação, ao nó ou ao pool. `local-root` continua reservado ao socket Unix local e não recebe escopo remoto configurável.

O roteamento da Colmeia pode usar o principal reservado `hive-controller`. Ele não possui uma chave privada própria da Automation: o controlador assina com a identidade Ed25519 da Colmeia já confiada pelo enrollment, e cada nó verifica contra `/etc/manager/hive/node/controller.pub`. A política é opt-in por nó, exige `action_scope` explícito e é cercada por `node_epoch`; a chave privada do controlador nunca é distribuída aos nós.
''')
replace_once(p,
'''remote_action_scope=1
```
''',
'''remote_action_scope=1
hive_controller_remote_auth=1
hive_controller_private_key_distribution=0
```
''')

p = 'docs/HIVE.md'
s = Path(p).read_text()
anchor = '''## 21. Accounting global — fundação 0.8.6'''
if anchor not in s:
    raise SystemExit('HIVE accounting anchor missing')
section = '''## 22. Roteamento remoto tipado — fundação 0.8.8\n\nO roteamento administrativo reutiliza a Automation v2 e a identidade criptográfica já enrolled da Colmeia; não cria shell remoto nem uma segunda autoridade.\n\nFluxo explícito por nó:\n\n```text\nnó habilita o gateway Automation v2 TLS 1.3\n        ↓\nnó cria anúncio de rota assinado com endpoint IP literal, fingerprint TLS e action_scope\n        ↓\ncontrolador valida assinatura, node_epoch e route_epoch e persiste a rota por node_id\n        ↓\nmanager hive remote controller call NODE ACTION ...\n        ↓\ncontrolador assina a requisição tipada com sua chave Ed25519 da Colmeia\n        ↓\nnó valida controller.pub + policy local + node_epoch + action_scope\n        ↓\nAutomation v2 executa somente a ação allowlisted\n```\n\n```bash\n# no nó (gateway remoto já habilitado)\nmanager hive remote node enable 203.0.113.20:9443 'system.describe,node.usage' /root/node.route.json\n\n# no controlador\nmanager hive remote controller accept /root/node.route.json\nmanager hive remote controller list\nmanager hive remote controller call node-0123456789abcdef system.describe\n```\n\nFronteiras de segurança:\n\n- o `call` recebe `node_id`, nunca host/porta arbitrários;\n- endpoint/fingerprint entram no controlador somente por anúncio assinado do nó enrolled;\n- `route_epoch` monotônico impede reativar anúncio antigo após disable/update;\n- `node_epoch` cerca rota após revoke/re-enrollment;\n- a ação precisa existir na allowlist da Automation v2 e no `action_scope` anunciado;\n- o nó revalida a mesma política antes do dispatcher e antes de replay idempotente;\n- TLS permanece 1.3 com fingerprint SHA-256 pinado;\n- a chave privada Ed25519 do controlador permanece apenas no controlador;\n- esta fundação roteia por `node_id`; seleção por pool continua pendente para fechar a 0.8.8.\n\n'''
if '## 22. Roteamento remoto tipado — fundação 0.8.8' not in s:
    Path(p).write_text(s.replace(anchor, section + anchor, 1))

p = 'docs/ROADMAP.md'
replace_once(p,
'''Ainda pendente para fechar 0.8.8:\n\n- superfície de roteamento/controlador para selecionar um nó/pool e encaminhar uma operação tipada sem distribuir shell;\n- gate end-to-end de roteamento entre controlador e múltiplos nós;\n- integração futura com Telegram sem criar uma segunda autoridade paralela.\n''',
'''Nova fundação de roteamento explícito por nó:\n\n- nó enrolled publica anúncio assinado contendo endpoint IP literal, fingerprint TLS, `action_scope`, `node_epoch` e `route_epoch`;\n- controlador aceita rota somente para node_id registrado/ativo e cerca replay/rollback pelo `route_epoch`;\n- `manager hive remote controller call NODE_ID ACTION ...` resolve endpoint/fingerprint apenas pelo registro assinado, nunca pela linha de comando;\n- requisição remota reutiliza a chave Ed25519 do próprio controlador da Colmeia como principal reservado `hive-controller`; a chave privada não é distribuída;\n- nó revalida controller_id, node_epoch e action_scope antes da idempotência/dispatcher da Automation v2.\n\nAinda pendente para fechar 0.8.8:\n\n- seleção/roteamento por pool sobre múltiplos nós enrolled/saudáveis;\n- gate end-to-end de roteamento entre controlador e múltiplos nós;\n- fechamento formal da release 0.8.8;\n- integração futura com Telegram sem criar uma segunda autoridade paralela.\n''')
