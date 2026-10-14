from pathlib import Path


def replace_once(path, old, new):
    p=Path(path); text=p.read_text()
    if old not in text:
        raise SystemExit(f'anchor missing: {path}: {old[:80]!r}')
    p.write_text(text.replace(old,new,1))

# telegram_gateway.sh: permit an internal root-only Bot API path that starts from a
# user.id already authenticated by the Bot API transport, then resolves the same
# binding/RBAC authority before using the existing Ed25519 Automation bridge.
p='modules/telegram_gateway.sh'
replace_once(p,
'AUTH_MODULE="${MANAGER_TELEGRAM_AUTH_MODULE:-$MANAGER_HOME/modules/telegram_auth.sh}"\nAUTOMATION_CREDENTIALS=',
'AUTH_MODULE="${MANAGER_TELEGRAM_AUTH_MODULE:-$MANAGER_HOME/modules/telegram_auth.sh}"\nIDENTITY_MODULE="${MANAGER_TELEGRAM_IDENTITY_MODULE:-$MANAGER_HOME/modules/telegram_identity.sh}"\nAUTOMATION_CREDENTIALS=')
replace_once(p,
'  local initdata="${1:-}" request_file="${2:-}" result rc meta uid principal action request_id code cached decision\n',
'  local initdata="${1:-}" request_file="${2:-}" trusted_uid="${3:-}" result rc meta uid principal action request_id code cached decision\n')
replace_once(p,
'  [[ -x "$AUTH_MODULE" ]] || { err "Módulo de autenticação Telegram indisponível"; return 70; }\n',
'  [[ -x "$AUTH_MODULE" ]] || { err "Módulo de autenticação Telegram indisponível"; return 70; }\n  [[ -x "$IDENTITY_MODULE" ]] || { err "Módulo de identidade Telegram indisponível"; return 70; }\n')
replace_once(p,
'  [[ -n "$initdata" && -f "$initdata" && -r "$initdata" && ! -L "$initdata" ]] || { err "Arquivo initData inválido ou ilegível"; return 66; }\n',
'  if [[ -n "$trusted_uid" ]]; then\n    [[ "$trusted_uid" =~ ^[1-9][0-9]{0,15}$ ]] || { err "Telegram user.id autenticado inválido"; return 64; }\n  else\n    [[ -n "$initdata" && -f "$initdata" && -r "$initdata" && ! -L "$initdata" ]] || { err "Arquivo initData inválido ou ilegível"; return 66; }\n  fi\n')
replace_once(p,
'  python3 - "$CONTRACT" "$REQUEST_CONTRACT" "$AUTH_MODULE" "$AUTOMATION_CREDENTIALS" "$MANAGERCTL" "$CREDENTIALS_DIR" "$initdata" "$request_file" "$meta" > "$result" <<\'PY\'\n',
'  python3 - "$CONTRACT" "$REQUEST_CONTRACT" "$AUTH_MODULE" "$IDENTITY_MODULE" "$AUTOMATION_CREDENTIALS" "$MANAGERCTL" "$CREDENTIALS_DIR" "$initdata" "$request_file" "$meta" "$trusted_uid" > "$result" <<\'PY\'\n')
replace_once(p,
'contract, request_contract, auth_module, credential_module, managerctl, credential_dir, initdata, request_file, meta_file = sys.argv[1:10]\n',
'contract, request_contract, auth_module, identity_module, credential_module, managerctl, credential_dir, initdata, request_file, meta_file, trusted_uid = sys.argv[1:12]\n')
old='''# Authentication is completed before a principal or requested action is trusted.\nauth_rc, auth = run_json([auth_module, "--resolve", initdata])\nif auth_rc != 0 or not auth:\n    fail("autenticação Telegram recusada", auth_rc or 67)\nif auth.get("contract") != "manager-telegram-authenticated-principal-v1":\n    fail("contrato de autenticação Telegram inválido", 70)\nuid = auth.get("telegram_user_id", "")\nprincipal = auth.get("principal_id", "")\nif not isinstance(uid, str) or not uid.isdigit() or not PRINCIPAL_RE.fullmatch(principal or ""):\n    fail("contexto Telegram autenticado inválido", 70)\n'''
new='''# Authentication is completed before a principal or requested action is trusted.\n# Mini App comes from validated initData. Bot ingress may provide only a user.id\n# that was obtained from an authenticated Telegram Bot API HTTPS response.\nif trusted_uid:\n    if not trusted_uid.isdigit():\n        fail("Telegram user.id autenticado inválido", 64)\n    auth_rc, auth = run_json([identity_module, "--resolve", trusted_uid])\n    if auth_rc != 0 or not auth:\n        fail("identidade Telegram do Bot recusada", auth_rc or 67, telegram_user_id=trusted_uid)\n    if auth.get("contract") != "manager-telegram-identity-v1":\n        fail("contrato de identidade Telegram inválido", 70, telegram_user_id=trusted_uid)\n    uid = auth.get("telegram_user_id", "")\n    principal = auth.get("principal_id", "")\nelse:\n    auth_rc, auth = run_json([auth_module, "--resolve", initdata])\n    if auth_rc != 0 or not auth:\n        fail("autenticação Telegram recusada", auth_rc or 67)\n    if auth.get("contract") != "manager-telegram-authenticated-principal-v1":\n        fail("contrato de autenticação Telegram inválido", 70)\n    uid = auth.get("telegram_user_id", "")\n    principal = auth.get("principal_id", "")\nif not isinstance(uid, str) or not uid.isdigit() or uid != (trusted_uid or uid) or not PRINCIPAL_RE.fullmatch(principal or ""):\n    fail("contexto Telegram autenticado inválido", 70)\n'''
replace_once(p,old,new)
replace_once(p,
'  --call-stdin) call_stdin "${2:-}"; exit $? ;;\n',
'  --call-stdin) call_stdin "${2:-}"; exit $? ;;\n  --call-bot-user) call_gateway /dev/null "${3:-}" "${2:-}"; exit $? ;;\n')
replace_once(p,
'  telegram_gateway.sh --call-stdin /CAMINHO/REQUEST.json\n',
'  telegram_gateway.sh --call-stdin /CAMINHO/REQUEST.json\n  telegram_gateway.sh --call-bot-user TELEGRAM_USER_ID /CAMINHO/REQUEST.json  # interno\n')

# telegram_bot.sh lifecycle persistence.
p='modules/telegram_bot.sh'
replace_once(p,
"      printf 'version=1\\n'\n      printf 'poll_timeout_seconds=%s\\n' \"$DEFAULT_POLL_TIMEOUT\"\n",
"      printf 'version=1\\n'\n      printf 'enabled=0\\n'\n      printf 'poll_timeout_seconds=%s\\n' \"$DEFAULT_POLL_TIMEOUT\"\n")
insert='''\nset_enabled() {\n  local value="$1" timeout tmp\n  init_state\n  timeout="$(read_field "$CONFIG_FILE" poll_timeout_seconds)"\n  [[ "$timeout" =~ ^[0-9]+$ ]] || timeout="$DEFAULT_POLL_TIMEOUT"\n  tmp="$(mktemp "$BOT_DIR/.config.XXXXXX")"\n  {\n    printf 'version=1\\n'\n    printf 'enabled=%s\\n' "$value"\n    printf 'poll_timeout_seconds=%s\\n' "$timeout"\n  } > "$tmp"\n  install -m 0600 "$tmp" "$CONFIG_FILE"\n  rm -f "$tmp"\n}\n\ninstall_bot() {\n  init_state\n  write_service\n  if [[ "$(read_field "$CONFIG_FILE" enabled)" == 1 ]] && valid_token_file; then\n    systemctl enable --now manager-telegram-bot.service >/dev/null 2>&1 || true\n  fi\n}\n\ndetach_bot() {\n  systemctl disable --now manager-telegram-bot.service >/dev/null 2>&1 || true\n  rm -f "$SERVICE_FILE"\n  systemctl daemon-reload >/dev/null 2>&1 || true\n}\n\npurge_bot() {\n  detach_bot\n  rm -rf "$BOT_DIR" "$DATA_DIR"\n  rm -f "$AUDIT_FILE"\n}\n'''
replace_once(p,'\nstatus() {\n',insert+'\nstatus() {\n')
replace_once(p,
'  write_service\n  systemctl enable --now manager-telegram-bot.service >/dev/null\n',
'  write_service\n  set_enabled 1\n  systemctl enable --now manager-telegram-bot.service >/dev/null\n')
replace_once(p,
'disable_bot() {\n  systemctl disable --now manager-telegram-bot.service >/dev/null 2>&1 || true\n',
'disable_bot() {\n  set_enabled 0\n  systemctl disable --now manager-telegram-bot.service >/dev/null 2>&1 || true\n')
replace_once(p,
'  --install|--init) init_state; write_service; exit 0 ;;\n',
'  --install|--init) install_bot; exit 0 ;;\n  --detach) detach_bot; exit 0 ;;\n  --purge) purge_bot; exit 0 ;;\n')

# Installer.
p='install.sh'
replace_once(p,
'  "modules/telegram_gateway.sh"\n  "modules/policy_engine.sh"',
'  "modules/telegram_gateway.sh"\n  "modules/telegram_bot.sh"\n  "modules/policy_engine.sh"')
replace_once(p,
'''"$INSTALL_DIR/modules/telegram_gateway.sh" --install >/dev/null 2>&1 || {\n  echo "[AVISO] O gateway Telegram 0.9.0 não pôde inicializar seu estado. Use: manager telegram gateway status" >&2\n}\n''',
'''"$INSTALL_DIR/modules/telegram_gateway.sh" --install >/dev/null 2>&1 || {\n  echo "[AVISO] O gateway Telegram 0.9.0 não pôde inicializar seu estado. Use: manager telegram gateway status" >&2\n}\n"$INSTALL_DIR/modules/telegram_bot.sh" --install >/dev/null 2>&1 || {\n  echo "[AVISO] O ingresso Telegram Bot não pôde inicializar seu estado. Use: manager telegram bot status" >&2\n}\n''')

# CLI.
p='manager'
replace_once(p,
'''  manager telegram gateway call-stdin /CAMINHO/REQUEST.json\n                                  executa ações tipadas via Automation v2 sem shell arbitrário (0.9.0)\n''',
'''  manager telegram gateway call-stdin /CAMINHO/REQUEST.json\n                                  executa ações tipadas via Automation v2 sem shell arbitrário (0.9.0)\n  manager telegram bot status|enable|disable|poll-once\n                                  ingresso Bot API por long polling, sem listener público (0.9.0)\n''')
replace_once(p,
'''      gateway)\n        case "${3:-status}" in\n          status) exec "$MANAGER_HOME/modules/telegram_gateway.sh" --status ;;\n          call) [[ -n "${4:-}" && -n "${5:-}" ]] || { err "Uso: manager telegram gateway call /CAMINHO/INITDATA /CAMINHO/REQUEST.json"; exit 64; }; exec "$MANAGER_HOME/modules/telegram_gateway.sh" --call "$4" "$5" ;;\n          call-stdin) [[ -n "${4:-}" ]] || { err "Uso: manager telegram gateway call-stdin /CAMINHO/REQUEST.json"; exit 64; }; exec "$MANAGER_HOME/modules/telegram_gateway.sh" --call-stdin "$4" ;;\n          *) err "Uso: manager telegram gateway {status|call|call-stdin} ..."; exit 64 ;;\n        esac\n        ;;\n      *) err "Uso: manager telegram {identity|auth|gateway} ..."; exit 64 ;;\n''',
'''      gateway)\n        case "${3:-status}" in\n          status) exec "$MANAGER_HOME/modules/telegram_gateway.sh" --status ;;\n          call) [[ -n "${4:-}" && -n "${5:-}" ]] || { err "Uso: manager telegram gateway call /CAMINHO/INITDATA /CAMINHO/REQUEST.json"; exit 64; }; exec "$MANAGER_HOME/modules/telegram_gateway.sh" --call "$4" "$5" ;;\n          call-stdin) [[ -n "${4:-}" ]] || { err "Uso: manager telegram gateway call-stdin /CAMINHO/REQUEST.json"; exit 64; }; exec "$MANAGER_HOME/modules/telegram_gateway.sh" --call-stdin "$4" ;;\n          *) err "Uso: manager telegram gateway {status|call|call-stdin} ..."; exit 64 ;;\n        esac\n        ;;\n      bot)\n        case "${3:-status}" in\n          status) exec "$MANAGER_HOME/modules/telegram_bot.sh" --status ;;\n          enable) exec "$MANAGER_HOME/modules/telegram_bot.sh" --enable ;;\n          disable) exec "$MANAGER_HOME/modules/telegram_bot.sh" --disable ;;\n          poll-once) exec "$MANAGER_HOME/modules/telegram_bot.sh" --poll-once ;;\n          *) err "Uso: manager telegram bot {status|enable|disable|poll-once}"; exit 64 ;;\n        esac\n        ;;\n      *) err "Uso: manager telegram {identity|auth|gateway|bot} ..."; exit 64 ;;\n''')
replace_once(p,
'      say "${C_WHITE}TELEGRAM — IDENTIDADE / AUTENTICAÇÃO / RBAC${C_RESET}\\n"\n',
'      say "${C_WHITE}TELEGRAM — IDENTIDADE / AUTENTICAÇÃO / GATEWAY / BOT${C_RESET}\\n"\n')
replace_once(p,
'      "$MANAGER_HOME/modules/telegram_auth.sh" --status 2>/dev/null || true\n',
'      "$MANAGER_HOME/modules/telegram_auth.sh" --status 2>/dev/null || true\n      say ""\n      "$MANAGER_HOME/modules/telegram_bot.sh" --status 2>/dev/null || true\n')
replace_once(p,
'      say " manager telegram auth resolve /root/initdata.txt"\n',
'      say " manager telegram auth resolve /root/initdata.txt"\n      say " manager telegram bot enable"\n')

# Lifecycle: Bot must stop before Automation v2 because it depends on managerd.
p='uninstall.sh'
anchor='# Automation v2 possui o socket Unix local e pode possuir o gateway TLS remoto.\n'
block='''# Telegram Bot long polling não abre listener, mas depende da Automation v2.\n# A unidade sai antes do managerd; estado/offset sobrevivem ao uninstall normal.\nif [[ -x /opt/manager/modules/telegram_bot.sh ]]; then\n  if $PURGE; then\n    /opt/manager/modules/telegram_bot.sh --purge >/dev/null 2>&1 || true\n  else\n    /opt/manager/modules/telegram_bot.sh --detach >/dev/null 2>&1 || true\n  fi\nelse\n  systemctl disable --now manager-telegram-bot.service >/dev/null 2>&1 || true\n  rm -f /etc/systemd/system/manager-telegram-bot.service\n  if $PURGE; then\n    rm -rf /etc/manager/telegram/bot /var/lib/manager/telegram-bot\n    rm -f /var/log/manager/telegram-bot-audit.jsonl\n  fi\n  systemctl daemon-reload >/dev/null 2>&1 || true\nfi\n\n'''
replace_once(p,anchor,block+anchor)

p='rollback.sh'
anchor='# Unidades/hooks externos ao /opt precisam ser retirados pelo código que os\n# criou antes da troca. Estados persistentes permanecem em /etc/manager e /var/lib.\n'
replace_once(p,anchor,anchor+'''if [[ -x "$INSTALL_DIR/modules/telegram_bot.sh" ]]; then\n  "$INSTALL_DIR/modules/telegram_bot.sh" --detach >/dev/null 2>&1 || true\nelse\n  systemctl disable --now manager-telegram-bot.service >/dev/null 2>&1 || true\n  rm -f /etc/systemd/system/manager-telegram-bot.service\n  systemctl daemon-reload >/dev/null 2>&1 || true\nfi\n''')
anchor='''# Reaplica apenas os componentes disponíveis na versão que acabou de voltar.\n# Isso permite rollback para uma versão anterior sem deixar units/hooks\n# apontando para módulos ausentes.\n'''
replace_once(p,anchor,anchor+'''if [[ -x "$INSTALL_DIR/modules/telegram_bot.sh" ]]; then\n  "$INSTALL_DIR/modules/telegram_bot.sh" --install >/dev/null 2>&1 || true\nelse\n  systemctl disable --now manager-telegram-bot.service >/dev/null 2>&1 || true\n  rm -f /etc/systemd/system/manager-telegram-bot.service\n  systemctl daemon-reload >/dev/null 2>&1 || true\nfi\n''')

# Documentation.
p='docs/TELEGRAM.md'
old='''## Próximas fatias da 0.9\n\nA camada Telegram ainda precisa:\n\n1. adicionar ingresso autenticado do Telegram Bot (webhook/long polling) para alimentar o mesmo gateway tipado sem confiar em username/chat;\n2. implementar telas e fluxos de sessões, clientes, produtos, cotas, nós e diagnósticos;\n3. expandir o E2E para o transporte real do Bot quando esse ingresso existir.\n\nO Mini App já possui E2E do `initData` até a Automation v2. O Telegram permanece apenas uma interface do control plane existente, não uma nova autoridade paralela.\n'''
new='''## Ingresso do Telegram Bot por long polling\n\nO Bot usa `getUpdates` por HTTPS contra `https://api.telegram.org`, portanto não abre porta pública, não exige webhook e não altera firewall. O bot token é lido do mesmo arquivo root-only usado pela autenticação do Mini App e nunca aparece em argv, audit ou mensagens de erro.\n\nSomente mensagens privadas com `message.from.id == message.chat.id` entram no parser. O `user.id` vem da resposta autenticada da Bot API e é resolvido no mesmo binding `telegram_user_id -> principal_id`; username, nome, texto livre e `chat.id` não concedem autoridade. O ingresso inicial expõe somente comandos fixos de leitura:\n\n- `/describe` -> `system.describe`;\n- `/node` -> `node.usage`;\n- `/status ID` -> `connection.status`;\n- `/help` e `/start` retornam a ajuda local.\n\nTexto desconhecido nunca vira `action_id`, shell ou comando do sistema. Cada `update_id` vira um `request_id` estável do gateway, de modo que falha ao entregar a resposta ao Telegram pode repetir a ação sem duplicar mutação; a Automation v2 devolve o resultado idempotente após revalidar RBAC. O offset só avança depois que o update é tratado e, quando há resposta, depois que `sendMessage` é aceito.\n\nCLI:\n\n```bash\nmanager telegram bot status\nmanager telegram bot enable\nmanager telegram bot disable\nmanager telegram bot poll-once\n```\n\nA unidade `manager-telegram-bot.service` é opcional e usa long polling. Estado e offset ficam root-only em `/etc/manager/telegram/bot` e `/var/lib/manager/telegram-bot`; o audit sanitizado fica em `/var/log/manager/telegram-bot-audit.jsonl`. O uninstall normal para a unidade e preserva estado; reinstalação/rollback reanexam somente quando aplicável.\n\n## Próximas fatias da 0.9\n\nA fundação de ingresso Bot + Mini App da 0.9.0 fica funcionalmente completa com o long polling. As fases seguintes expandem telas e fluxos de sessões, clientes, produtos, cotas, nós e diagnósticos. Webhook pode ser adicionado como transporte alternativo futuro sem mudar a autoridade do gateway.\n\nO Telegram permanece apenas uma interface do control plane existente, não uma nova autoridade paralela.\n'''
replace_once(p,old,new)

p='docs/ROADMAP.md'
old='''Ainda pendente para fechar toda a integração Bot/Mini App da série 0.9:\n\n- ingresso autenticado do Telegram Bot por webhook/long polling reutilizando o mesmo gateway tipado;\n- telas/fluxos de produto posteriores.\n'''
new='''Ingresso do Bot implementado nesta fatia:\n\n- `manager-telegram-bot-ingress-v1` usa long polling HTTPS oficial da Bot API, sem listener público ou regra de firewall;\n- `message.from.id` de update privado autenticado é a única identidade do Bot; username/nome/chat não concedem autoridade;\n- comandos Bot são mapeados por allowlist fixa para ações tipadas e entram pelo mesmo gateway/Automation v2;\n- `update_id` gera `request_id` estável para retry idempotente e o offset só avança depois do tratamento seguro;\n- bot token não entra em argv/audit/erro e estado/offset são root-only;\n- lifecycle de enable/disable/reinstall/rollback/uninstall preserva intenção sem deixar unidade órfã.\n\nPendências da série 0.9 após a fundação 0.9.0:\n\n- telas/fluxos de produto posteriores;\n- webhook opcional como transporte alternativo ao long polling, sem nova autoridade.\n'''
replace_once(p,old,new)

print('telegram bot integration patch applied')
