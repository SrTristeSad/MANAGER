from pathlib import Path


def replace_once(path, old, new):
    p = Path(path)
    s = p.read_text()
    if old not in s:
        raise SystemExit(f"anchor missing in {path}: {old[:120]!r}")
    p.write_text(s.replace(old, new, 1))


# automation_principals.sh
p = 'modules/automation_principals.sh'
replace_once(p,
'''normalize_products() {
  local input="${1:-*}" item out="" seen=""
  input="${input// /}"
  [[ -z "$input" || "$input" == "*" ]] && { printf '*\\n'; return 0; }
  [[ "$input" == "-" ]] && { printf '%s\\n' '-'; return 0; }
  IFS=',' read -r -a items <<< "$input"
  for item in "${items[@]}"; do
    [[ "$item" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$ ]] || return 1
    if [[ ",$seen," != *",$item,"* ]]; then
      [[ -n "$out" ]] && out+=","
      out+="$item"
      [[ -n "$seen" ]] && seen+=","
      seen+="$item"
    fi
  done
  [[ -n "$out" ]] || return 1
  printf '%s\\n' "$out"
}
''',
'''normalize_products() {
  local input="${1:-*}" item out="" seen=""
  input="${input// /}"
  [[ -z "$input" || "$input" == "*" ]] && { printf '*\\n'; return 0; }
  [[ "$input" == "-" ]] && { printf '%s\\n' '-'; return 0; }
  IFS=',' read -r -a items <<< "$input"
  for item in "${items[@]}"; do
    [[ "$item" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$ ]] || return 1
    if [[ ",$seen," != *",$item,"* ]]; then
      [[ -n "$out" ]] && out+=","
      out+="$item"
      [[ -n "$seen" ]] && seen+=","
      seen+="$item"
    fi
  done
  [[ -n "$out" ]] || return 1
  printf '%s\\n' "$out"
}

normalize_remote_scope() {
  local input="${1:-*}" kind="${2:-label}" item out="" seen=""
  input="${input// /}"
  [[ -z "$input" || "$input" == "*" ]] && { printf '*\\n'; return 0; }
  IFS=',' read -r -a items <<< "$input"
  for item in "${items[@]}"; do
    case "$kind" in
      node|pool)
        [[ "$item" =~ ^[A-Za-z0-9][A-Za-z0-9_.:-]{0,63}$ ]] || return 1
        ;;
      action)
        case "$item" in
          system.describe|node.usage|connection.preflight|connection.create|connection.status|connection.revoke) ;;
          *) return 1 ;;
        esac
        ;;
      *) return 1 ;;
    esac
    if [[ ",$seen," != *",$item,"* ]]; then
      [[ -n "$out" ]] && out+=","
      out+="$item"
      [[ -n "$seen" ]] && seen+=","
      seen+="$item"
    fi
  done
  [[ -n "$out" ]] || return 1
  printf '%s\\n' "$out"
}
''')

replace_once(p,
'''write_principal() {
  local id="$1" role="$2" subject="$3" products="$4" enabled="$5" created="$6" updated="$7" tmp
''',
'''write_principal() {
  local id="$1" role="$2" subject="$3" products="$4" node_scope="$5" pool_scope="$6" action_scope="$7" enabled="$8" created="$9" updated="${10}" tmp
''')
replace_once(p,
'''    printf 'products=%s\\n' "$products"
    printf 'enabled=%s\\n' "$enabled"
''',
'''    printf 'products=%s\\n' "$products"
    printf 'node_scope=%s\\n' "$node_scope"
    printf 'pool_scope=%s\\n' "$pool_scope"
    printf 'action_scope=%s\\n' "$action_scope"
    printf 'enabled=%s\\n' "$enabled"
''')
replace_once(p, '    write_principal "$LOCAL_ROOT_ID" admin \'*\' \'*\' 1 "$now" "$now"\n',
                '    write_principal "$LOCAL_ROOT_ID" admin \'*\' \'*\' \'*\' \'*\' \'*\' 1 "$now" "$now"\n')
replace_once(p, '  write_principal "$id" "$role" "$subject" "$products" 1 "$now" "$now"\n',
                '  write_principal "$id" "$role" "$subject" "$products" \'*\' \'*\' \'*\' 1 "$now" "$now"\n')
replace_once(p,
'''set_enabled() {
  local id="${1:-}" enabled="$2" file role subject products created now
''',
'''set_enabled() {
  local id="${1:-}" enabled="$2" file role subject products node_scope pool_scope action_scope created now
''')
replace_once(p,
'''  products="$(read_field "$file" products)"
  created="$(read_field "$file" created_epoch)"
''',
'''  products="$(read_field "$file" products)"
  node_scope="$(read_field "$file" node_scope)"; node_scope="${node_scope:-*}"
  pool_scope="$(read_field "$file" pool_scope)"; pool_scope="${pool_scope:-*}"
  action_scope="$(read_field "$file" action_scope)"; action_scope="${action_scope:-*}"
  created="$(read_field "$file" created_epoch)"
''')
replace_once(p,
'''  write_principal "$id" "$role" "$subject" "$products" "$enabled" "$created" "$now"
''',
'''  write_principal "$id" "$role" "$subject" "$products" "$node_scope" "$pool_scope" "$action_scope" "$enabled" "$created" "$now"
''')
replace_once(p,
'''set_products() {
  local id="${1:-}" input="${2:-}" file role subject enabled created products now
''',
'''set_products() {
  local id="${1:-}" input="${2:-}" file role subject enabled created products node_scope pool_scope action_scope now
''')
replace_once(p,
'''  subject="$(read_field "$file" subject)"
  enabled="$(read_field "$file" enabled)"
  created="$(read_field "$file" created_epoch)"
''',
'''  subject="$(read_field "$file" subject)"
  enabled="$(read_field "$file" enabled)"
  node_scope="$(read_field "$file" node_scope)"; node_scope="${node_scope:-*}"
  pool_scope="$(read_field "$file" pool_scope)"; pool_scope="${pool_scope:-*}"
  action_scope="$(read_field "$file" action_scope)"; action_scope="${action_scope:-*}"
  created="$(read_field "$file" created_epoch)"
''')
replace_once(p,
'''  write_principal "$id" "$role" "$subject" "$products" "$enabled" "$created" "$now"
  printf 'principal_id=%s\\nproducts=%s\\n' "$id" "$products"
}

show_principal() {
''',
'''  write_principal "$id" "$role" "$subject" "$products" "$node_scope" "$pool_scope" "$action_scope" "$enabled" "$created" "$now"
  printf 'principal_id=%s\\nproducts=%s\\n' "$id" "$products"
}

set_remote_scope() {
  local id="${1:-}" nodes="${2:-*}" pools="${3:-*}" actions="${4:-*}"
  local file role subject products enabled created now node_scope pool_scope action_scope
  init_state
  valid_principal_id "$id" || { err "principal_id inválido"; return 64; }
  file="$(principal_file "$id")"
  [[ -f "$file" ]] || { err "Principal não existe: $id"; return 66; }
  [[ "$id" != "$LOCAL_ROOT_ID" ]] || { err "$LOCAL_ROOT_ID mantém escopo local irrestrito"; return 73; }
  node_scope="$(normalize_remote_scope "$nodes" node)" || { err "Escopo de nós inválido"; return 64; }
  pool_scope="$(normalize_remote_scope "$pools" pool)" || { err "Escopo de pools inválido"; return 64; }
  action_scope="$(normalize_remote_scope "$actions" action)" || { err "Escopo de ações inválido"; return 64; }
  role="$(read_field "$file" role)"
  subject="$(read_field "$file" subject)"
  products="$(read_field "$file" products)"
  enabled="$(read_field "$file" enabled)"
  created="$(read_field "$file" created_epoch)"
  [[ "$created" =~ ^[0-9]+$ ]] || created="$(date +%s)"
  validate_bound_subject "$role" "$subject" || return $?
  now="$(date +%s)"
  write_principal "$id" "$role" "$subject" "$products" "$node_scope" "$pool_scope" "$action_scope" "$enabled" "$created" "$now"
  printf 'principal_id=%s\\nnode_scope=%s\\npool_scope=%s\\naction_scope=%s\\n' "$id" "$node_scope" "$pool_scope" "$action_scope"
}

show_principal() {
''')
replace_once(p,
'''  --set-products) set_products "${2:-}" "${3:-}"; exit $? ;;
''',
'''  --set-products) set_products "${2:-}" "${3:-}"; exit $? ;;
  --set-scope) set_remote_scope "${2:-}" "${3:-*}" "${4:-*}" "${5:-*}"; exit $? ;;
''')
replace_once(p,
'''  say " 5) Alterar escopo de produtos"
  say " 0) Voltar"
''',
'''  say " 5) Alterar escopo de produtos"
  say " 6) Alterar escopo remoto (nó/pool/ação)"
  say " 0) Voltar"
''')
replace_once(p,
'''    5) interactive_products ;;
    0) exit 0 ;;
''',
'''    5) interactive_products ;;
    6)
      header
      read -r -p "Principal ID: " id
      read -r -p "Nós permitidos (* ou CSV): " nodes
      read -r -p "Pools permitidos (* ou CSV): " pools
      read -r -p "Ações permitidas (* ou CSV): " actions
      if set_remote_scope "$id" "${nodes:-*}" "${pools:-*}" "${actions:-*}"; then ok "Escopo remoto atualizado"; fi
      pause
      ;;
    0) exit 0 ;;
''')

# automation_v2.sh
p = 'modules/automation_v2.sh'
replace_once(p,
'''IDENTITY_DIR = os.path.join(MANAGER_ETC, "connection", "identities")
CONTRACT = "manager-automation-v2-local-v1"
''',
'''IDENTITY_DIR = os.path.join(MANAGER_ETC, "connection", "identities")
NODE_CONF = os.path.join(MANAGER_ETC, "connection", "node", "node.conf")
CONTRACT = "manager-automation-v2-local-v1"
''')
replace_once(p,
'''    return {"principal_id": principal_id, "role": role, "subject": subject, "products": products}


def canonical_auth_payload(request):
''',
'''    node_scope = data.get("node_scope", "*") or "*"
    pool_scope = data.get("pool_scope", "*") or "*"
    action_scope = data.get("action_scope", "*") or "*"
    validate_scope(node_scope, "node")
    validate_scope(pool_scope, "pool")
    validate_scope(action_scope, "action")
    return {"principal_id": principal_id, "role": role, "subject": subject, "products": products,
            "node_scope": node_scope, "pool_scope": pool_scope, "action_scope": action_scope}


def validate_scope(value, kind):
    if value == "*":
        return
    if not isinstance(value, str) or not value:
        raise PermissionError(f"escopo {kind} inválido")
    items = value.split(",")
    if len(items) > 128 or len(set(items)) != len(items):
        raise PermissionError(f"escopo {kind} inválido")
    for item in items:
        if kind in {"node", "pool"}:
            if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.:-]{0,63}", item):
                raise PermissionError(f"escopo {kind} inválido")
        elif kind == "action":
            if item not in ACTIONS:
                raise PermissionError("escopo action inválido")
        else:
            raise PermissionError("tipo de escopo inválido")


def local_node_context():
    try:
        data = read_conf(NODE_CONF, strict=True)
    except RuntimeError:
        data = None
    if not data or data.get("version") != "1":
        return {"node_id": "", "pool": ""}
    return {"node_id": data.get("node_id", ""), "pool": data.get("pool", "")}


def scope_allows(scope, value):
    return scope == "*" or (bool(value) and value in set(scope.split(",")))


def canonical_auth_payload(request):
''')
# Python functions are resolved at runtime; validate_scope is defined by the time requests are handled.
replace_once(p,
'''def authorize(principal, action_id, params):
    role, normalized = principal["role"], dict(params)
    if action_id == "system.describe": return True, normalized, "system-describe"
''',
'''def authorize(principal, action_id, params):
    role, normalized = principal["role"], dict(params)
    if principal["principal_id"] != LOCAL_ROOT_ID:
        if not scope_allows(principal.get("action_scope", "*"), action_id):
            return False, normalized, "action-out-of-scope"
        ctx = local_node_context()
        if not scope_allows(principal.get("node_scope", "*"), ctx["node_id"]):
            return False, normalized, "node-out-of-scope"
        if not scope_allows(principal.get("pool_scope", "*"), ctx["pool"]):
            return False, normalized, "pool-out-of-scope"
    if action_id == "system.describe": return True, normalized, "system-describe"
''')
replace_once(p,
'''             "rate_limit_decision": rate, "rbac_decision": decision, "rbac_reason": str(reason)[:256],
             "ok": bool(response.get("ok", False)), "code": int(response.get("code", 70)), "cached": bool(cached)}
''',
'''             "rate_limit_decision": rate, "rbac_decision": decision, "rbac_reason": str(reason)[:256],
             "principal_node_scope": principal.get("node_scope", "") if principal else "",
             "principal_pool_scope": principal.get("pool_scope", "") if principal else "",
             "principal_action_scope": principal.get("action_scope", "") if principal else "",
             "local_node_id": local_node_context().get("node_id", ""), "local_pool": local_node_context().get("pool", ""),
             "ok": bool(response.get("ok", False)), "code": int(response.get("code", 70)), "cached": bool(cached)}
''')
replace_once(p,
'''  printf 'idempotency=1\\naudit=1\\nsecret_replay=0\\n'
''',
'''  printf 'idempotency=1\\naudit=1\\nsecret_replay=0\\n'
  printf 'remote_scoped_rbac=1\\nremote_node_scope=1\\nremote_pool_scope=1\\nremote_action_scope=1\\n'
''')

# manager CLI
p = 'manager'
replace_once(p,
'''              products) [[ -n "${5:-}" && -n "${6:-}" ]] || { err "Uso: manager automation v2 principal products ID SCOPE"; exit 64; }; exec "$MANAGER_HOME/modules/automation_principals.sh" --set-products "$5" "$6" ;;
              *) err "Ação de principal inválida: ${4:-}"; exit 64 ;;
''',
'''              products) [[ -n "${5:-}" && -n "${6:-}" ]] || { err "Uso: manager automation v2 principal products ID SCOPE"; exit 64; }; exec "$MANAGER_HOME/modules/automation_principals.sh" --set-products "$5" "$6" ;;
              scope) [[ -n "${5:-}" && -n "${6:-}" && -n "${7:-}" && -n "${8:-}" ]] || { err "Uso: manager automation v2 principal scope ID NODES POOLS ACTIONS"; exit 64; }; exec "$MANAGER_HOME/modules/automation_principals.sh" --set-scope "$5" "$6" "$7" "$8" ;;
              *) err "Ação de principal inválida: ${4:-}"; exit 64 ;;
''')

# docs
p = 'docs/AUTOMATION_V2.md'
replace_once(p,
'''| `connection.revoke` | sim | escopo | próprio owner | não |

Revendedor atua na própria árvore e em subrevendedores filhos diretos. Subrevendedor não sobe para o pai. Usuário só consulta a identidade vinculada.
''',
'''| `connection.revoke` | sim | escopo | próprio owner | não |

Revendedor atua na própria árvore e em subrevendedores filhos diretos. Subrevendedor não sobe para o pai. Usuário só consulta a identidade vinculada.

### Escopo remoto por nó, pool e ação — fundação 0.8.8

Principals não-locais também podem ser restringidos ao contexto do nó que recebe a chamada. Os campos persistidos são `node_scope`, `pool_scope` e `action_scope`; arquivos antigos sem esses campos mantêm `*` por compatibilidade.

```bash
manager automation v2 principal scope loja01 'node-a,node-b' 'BR-SP,BR-RJ' 'system.describe,connection.status'
```

A validação acontece **antes da idempotência e antes do dispatcher**. Assim, um `request_id` anteriormente autorizado não pode servir resultado em cache depois que o principal perde acesso à ação, ao nó ou ao pool. `local-root` continua reservado ao socket Unix local e não recebe escopo remoto configurável.
''')
replace_once(p,
'''idempotency=1
audit=1
secret_replay=0
```
''',
'''idempotency=1
audit=1
secret_replay=0
remote_scoped_rbac=1
remote_node_scope=1
remote_pool_scope=1
remote_action_scope=1
```
''')

p = 'docs/ROADMAP.md'
replace_once(p,
'''### 0.8.8 — comandos remotos controlados

- operações remotas tipadas sobre contratos existentes;
- nenhuma execução arbitrária de shell;
- escopo/RBAC por nó, pool e ação;
- audit e idempotência;
- integração futura com Telegram sem criar uma segunda autoridade paralela.
''',
'''### 0.8.8 — comandos remotos controlados

Fundação implementada nesta fase:

- operações remotas continuam usando exclusivamente os contratos tipados já allowlisted da Automation v2; não existe shell/comando/caminho arbitrário;
- principals não-locais passam a ter escopos persistentes `node_scope`, `pool_scope` e `action_scope`, com `*` como compatibilidade para registros antigos;
- o `managerd` valida ação, `node_id` local e pool local antes da idempotência e antes do dispatcher;
- alteração de escopo invalida efetivamente retries que antes seriam servidos do cache, pois RBAC é reavaliado primeiro;
- audit registra os escopos do principal e o contexto local usados na decisão;
- `local-root` permanece apenas local/Unix e não pode ser convertido em autoridade remota.

Ainda pendente para fechar 0.8.8:

- superfície de roteamento/controlador para selecionar um nó/pool e encaminhar uma operação tipada sem distribuir shell;
- gate end-to-end de roteamento entre controlador e múltiplos nós;
- integração futura com Telegram sem criar uma segunda autoridade paralela.
''')
