from pathlib import Path


def replace_once(path, old, new):
    p = Path(path)
    s = p.read_text()
    if old not in s:
        raise SystemExit(f"anchor missing: {path}: {old[:80]!r}")
    if s.count(old) != 1:
        raise SystemExit(f"anchor not unique: {path}: {s.count(old)}")
    p.write_text(s.replace(old, new, 1))


replace_once(
    "install.sh",
    '  "modules/automation_v2.sh"\n  "modules/policy_engine.sh"',
    '  "modules/automation_v2.sh"\n  "modules/telegram_identity.sh"\n  "modules/policy_engine.sh"',
)

replace_once(
    "install.sh",
    '"$INSTALL_DIR/modules/automation_v2.sh" --install >/dev/null 2>&1 || {\n  echo "[AVISO] O Automation v2 local não pôde iniciar. Revise: systemctl status manager-automation-v2" >&2\n}\n"$INSTALL_DIR/modules/hive_lifecycle.sh" --install',
    '"$INSTALL_DIR/modules/automation_v2.sh" --install >/dev/null 2>&1 || {\n  echo "[AVISO] O Automation v2 local não pôde iniciar. Revise: systemctl status manager-automation-v2" >&2\n}\n"$INSTALL_DIR/modules/telegram_identity.sh" --install >/dev/null 2>&1 || {\n  echo "[AVISO] A identidade Telegram 0.9.0 não pôde inicializar seu estado. Use: manager telegram identity status" >&2\n}\n"$INSTALL_DIR/modules/hive_lifecycle.sh" --install',
)

replace_once(
    "manager",
    "  manager automation v2 remote rotate-certificate\n                                  controla o gateway remoto TLS 1.3 (desligado por padrão)\n  manager --diagnostics",
    "  manager automation v2 remote rotate-certificate\n                                  controla o gateway remoto TLS 1.3 (desligado por padrão)\n  manager telegram identity status|list\n  manager telegram identity show TELEGRAM_USER_ID\n  manager telegram identity bind TELEGRAM_USER_ID PRINCIPAL_ID\n  manager telegram identity enable|disable TELEGRAM_USER_ID\n  manager telegram identity resolve TELEGRAM_USER_ID\n                                  vínculo Telegram user.id -> principal Automation v2 (0.9.0)\n  manager --diagnostics",
)

replace_once(
    "manager",
    '      *) err "Uso: manager automation {legacy|v2} ..."; exit 64 ;;\n    esac\n    ;;\n  --diagnostics)',
    '''      *) err "Uso: manager automation {legacy|v2} ..."; exit 64 ;;
    esac
    ;;
  telegram)
    case "${2:-}" in
      identity)
        case "${3:-status}" in
          status) exec "$MANAGER_HOME/modules/telegram_identity.sh" --status ;;
          list) exec "$MANAGER_HOME/modules/telegram_identity.sh" --list ;;
          show) [[ -n "${4:-}" ]] || { err "Uso: manager telegram identity show TELEGRAM_USER_ID"; exit 64; }; exec "$MANAGER_HOME/modules/telegram_identity.sh" --show "$4" ;;
          bind) [[ -n "${4:-}" && -n "${5:-}" ]] || { err "Uso: manager telegram identity bind TELEGRAM_USER_ID PRINCIPAL_ID"; exit 64; }; exec "$MANAGER_HOME/modules/telegram_identity.sh" --bind "$4" "$5" ;;
          enable) [[ -n "${4:-}" ]] || { err "Uso: manager telegram identity enable TELEGRAM_USER_ID"; exit 64; }; exec "$MANAGER_HOME/modules/telegram_identity.sh" --enable "$4" ;;
          disable) [[ -n "${4:-}" ]] || { err "Uso: manager telegram identity disable TELEGRAM_USER_ID"; exit 64; }; exec "$MANAGER_HOME/modules/telegram_identity.sh" --disable "$4" ;;
          resolve) [[ -n "${4:-}" ]] || { err "Uso: manager telegram identity resolve TELEGRAM_USER_ID"; exit 64; }; exec "$MANAGER_HOME/modules/telegram_identity.sh" --resolve "$4" ;;
          *) err "Uso: manager telegram identity {status|list|show|bind|enable|disable|resolve} ..."; exit 64 ;;
        esac
        ;;
      *) err "Uso: manager telegram identity ..."; exit 64 ;;
    esac
    ;;
  --diagnostics)''',
)

replace_once(
    "manager",
    '  say " ${C_CYAN}38${C_RESET}) Automation v2 / RBAC, credenciais e transporte"\n  say ""\n  say " ${C_WHITE}COLMEIA${C_RESET}"',
    '  say " ${C_CYAN}38${C_RESET}) Automation v2 / RBAC, credenciais e transporte"\n  say " ${C_CYAN}43${C_RESET}) Telegram / identidade e RBAC"\n  say ""\n  say " ${C_WHITE}COLMEIA${C_RESET}"',
)

replace_once(
    "manager",
    '    42)\n      header\n      say "${C_WHITE}COLMEIA — LEASES GLOBAIS${C_RESET}\\n"',
    '''    43)
      header
      say "${C_WHITE}TELEGRAM — IDENTIDADE / RBAC${C_RESET}\\n"
      "$MANAGER_HOME/modules/telegram_identity.sh" --status || true
      say ""
      "$MANAGER_HOME/modules/telegram_identity.sh" --list 2>/dev/null || true
      say ""
      say "Fluxo via CLI:"
      say " manager automation v2 principal create telegram-admin admin '*'"
      say " manager telegram identity bind TELEGRAM_USER_ID telegram-admin"
      say " manager telegram identity resolve TELEGRAM_USER_ID"
      pause
      ;;
    42)
      header
      say "${C_WHITE}COLMEIA — LEASES GLOBAIS${C_RESET}\\n"''',
)

old = '''## 0.9.x — Telegram Bot + Mini App

- identidade pelo `user.id` numérico imutável do Telegram;
- admin, revendedor, subrevendedor e usuário;
- Bot + Mini App consumindo ações estruturadas;
- sessões, clientes, produtos, cotas, nós e diagnósticos;
- nenhuma execução arbitrária de shell.
'''
new = '''## 0.9.x — Telegram Bot + Mini App 🚧

### 0.9.0 — identidade Telegram + ponte RBAC 🚧

Fundação implementada nesta primeira fatia:

- `user.id` numérico do Telegram é a identidade externa estável; username/nome/chat não concedem autoridade;
- binding root-only `telegram_user_id -> principal_id` sem duplicar roles ou ACL;
- role, subject, products, node/pool/action scopes continuam vindo exclusivamente da Automation v2;
- um principal e um `user.id` formam vínculo 1:1 nesta fundação;
- binding ou principal desabilitado falham fechado;
- resolve estruturado `manager-telegram-identity-v1` sem segredo e sem shell arbitrário;
- audit local de bind/enable/disable/resolve/deny sem bot token ou credencial privada;
- CLI `manager telegram identity ...` e documentação em `docs/TELEGRAM.md`.

Ainda pendente para fechar 0.9.0:

- validação criptográfica do Telegram Bot/WebApp `initData` antes de aceitar o `user.id` remoto;
- gateway Bot/Mini App consumindo apenas ações tipadas/allowlisted;
- freshness, rate limit, idempotência e audit de requisições Telegram;
- gate end-to-end da autenticação Telegram.

Fases seguintes da série 0.9:

- Bot + Mini App consumindo ações estruturadas;
- sessões, clientes, produtos, cotas, nós e diagnósticos;
- nenhuma execução arbitrária de shell.
'''
replace_once("docs/ROADMAP.md", old, new)
