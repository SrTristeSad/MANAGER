from pathlib import Path


def replace_once(path, old, new):
    p=Path(path); s=p.read_text()
    if old not in s:
        raise SystemExit(f'anchor missing in {path}: {old[:80]!r}')
    p.write_text(s.replace(old,new,1))

# Gateway: add an internal Bot-authenticated entry point. The Bot transport itself
# authenticates updates through Telegram Bot API HTTPS; this path only resolves
# the already-authenticated from.id and then follows the same typed Automation v2 flow.
p='modules/telegram_gateway.sh'
replace_once(p,
'AUTH_MODULE="${MANAGER_TELEGRAM_AUTH_MODULE:-$MANAGER_HOME/modules/telegram_auth.sh}"\nAUTOMATION_CREDENTIALS=',
'AUTH_MODULE="${MANAGER_TELEGRAM_AUTH_MODULE:-$MANAGER_HOME/modules/telegram_auth.sh}"\nIDENTITY_MODULE="${MANAGER_TELEGRAM_IDENTITY_MODULE:-$MANAGER_HOME/modules/telegram_identity.sh}"\nAUTOMATION_CREDENTIALS=')

# Turn call_gateway into a dual auth-source function with the rest of the pipeline unchanged.
replace_once(p,
'''call_gateway() {\n  local initdata="${1:-}" request_file="${2:-}" result rc meta uid principal action request_id code cached decision\n  init_state\n  [[ -x "$AUTH_MODULE" ]] || { err "Módulo de autenticação Telegram indisponível"; return 70; }\n  [[ -x "$AUTOMATION_CREDENTIALS" ]] || { err "Módulo de credenciais Automation v2 indisponível"; return 70; }\n  [[ -x "$MANAGERCTL" ]] || { err "managerctl/Automation v2 indisponível"; return 70; }\n  [[ -n "$initdata" && -f "$initdata" && -r "$initdata" && ! -L "$initdata" ]] || { err "Arquivo initData inválido ou ilegível"; return 66; }\n  [[ -n "$request_file" && -f "$request_file" && -r "$request_file" && ! -L "$request_file" ]] || { err "Arquivo de requisição Telegram inválido ou ilegível"; return 66; }\n''',
'''call_gateway() {\n  local auth_mode="${1:-}" auth_source="${2:-}" request_file="${3:-}" result rc meta uid principal action request_id code cached decision\n  init_state\n  [[ -x "$AUTH_MODULE" ]] || { err "Módulo de autenticação Telegram indisponível"; return 70; }\n  [[ -x "$IDENTITY_MODULE" ]] || { err "Módulo de identidade Telegram indisponível"; return 70; }\n  [[ -x "$AUTOMATION_CREDENTIALS" ]] || { err "Módulo de credenciais Automation v2 indisponível"; return 70; }\n  [[ -x "$MANAGERCTL" ]] || { err "managerctl/Automation v2 indisponível"; return 70; }\n  case "$auth_mode" in\n    miniapp) [[ -n "$auth_source" && -f "$auth_source" && -r "$auth_source" && ! -L "$auth_source" ]] || { err "Arquivo initData inválido ou ilegível"; return 66; } ;;\n    bot) [[ "$auth_source" =~ ^[1-9][0-9]{0,15}$ ]] || { err "Telegram user.id inválido"; return 64; } ;;\n    *) err "Fonte de autenticação Telegram inválida"; return 64 ;;\n  esac\n  [[ -n "$request_file" && -f "$request_file" && -r "$request_file" && ! -L "$request_file" ]] || { err "Arquivo de requisição Telegram inválido ou ilegível"; return 66; }\n''')

replace_once(p,
'''  python3 - "$CONTRACT" "$REQUEST_CONTRACT" "$AUTH_MODULE" "$AUTOMATION_CREDENTIALS" "$MANAGERCTL" "$CREDENTIALS_DIR" "$initdata" "$request_file" "$meta" > "$result" <<'PY'\n''',
'''  python3 - "$CONTRACT" "$REQUEST_CONTRACT" "$AUTH_MODULE" "$IDENTITY_MODULE" "$AUTOMATION_CREDENTIALS" "$MANAGERCTL" "$CREDENTIALS_DIR" "$auth_mode" "$auth_source" "$request_file" "$meta" > "$result" <<'PY'\n''')
replace_once(p,
'''contract, request_contract, auth_module, credential_module, managerctl, credential_dir, initdata, request_file, meta_file = sys.argv[1:10]\n''',
'''contract, request_contract, auth_module, identity_module, credential_module, managerctl, credential_dir, auth_mode, auth_source, request_file, meta_file = sys.argv[1:12]\n''')
replace_once(p,
'''# Authentication is completed before a principal or requested action is trusted.\nauth_rc, auth = run_json([auth_module, "--resolve", initdata])\nif auth_rc != 0 or not auth:\n    fail("autenticação Telegram recusada", auth_rc or 67)\nif auth.get("contract") != "manager-telegram-authenticated-principal-v1":\n    fail("contrato de autenticação Telegram inválido", 70)\nuid = auth.get("telegram_user_id", "")\nprincipal = auth.get("principal_id", "")\n''',
'''# Authentication is completed before a principal or requested action is trusted.\nif auth_mode == "miniapp":\n    auth_rc, auth = run_json([auth_module, "--resolve", auth_source])\n    if auth_rc != 0 or not auth:\n        fail("autenticação Telegram recusada", auth_rc or 67)\n    if auth.get("contract") != "manager-telegram-authenticated-principal-v1":\n        fail("contrato de autenticação Telegram inválido", 70)\n    uid = auth.get("telegram_user_id", "")\n    principal = auth.get("principal_id", "")\nelif auth_mode == "bot":\n    auth_rc, identity = run_json([identity_module, "--resolve", auth_source])\n    if auth_rc != 0 or not identity:\n        fail("identidade Telegram Bot recusada", auth_rc or 67)\n    if identity.get("contract") != "manager-telegram-identity-v1":\n        fail("contrato de identidade Telegram inválido", 70)\n    uid = identity.get("telegram_user_id", "")\n    principal = identity.get("principal_id", "")\nelse:\n    fail("fonte de autenticação Telegram inválida", 64)\n''')
replace_once(p,
'''  call_gateway "$input" "$request_file"\n''',
'''  call_gateway miniapp "$input" "$request_file"\n''')
replace_once(p,
'''  --call) call_gateway "${2:-}" "${3:-}"; exit $? ;;\n  --call-stdin) call_stdin "${2:-}"; exit $? ;;\n''',
'''  --call) call_gateway miniapp "${2:-}" "${3:-}"; exit $? ;;\n  --call-stdin) call_stdin "${2:-}"; exit $? ;;\n  --call-bot-user) call_gateway bot "${2:-}" "${3:-}"; exit $? ;;\n''')
replace_once(p,
'''  telegram_gateway.sh --call-stdin /CAMINHO/REQUEST.json\n''',
'''  telegram_gateway.sh --call-stdin /CAMINHO/REQUEST.json\n  telegram_gateway.sh --call-bot-user TELEGRAM_USER_ID /CAMINHO/REQUEST.json   # uso interno do Bot\n''')

# Installer
p='install.sh'
replace_once(p,
'  "modules/telegram_gateway.sh"\n',
'  "modules/telegram_gateway.sh"\n  "modules/telegram_bot.sh"\n')
replace_once(p,
'''"$INSTALL_DIR/modules/telegram_gateway.sh" --install >/dev/null 2>&1 || {\n  echo "[AVISO] O gateway Telegram 0.9.0 não pôde inicializar seu estado. Use: manager telegram gateway status" >&2\n}\n''',
'''"$INSTALL_DIR/modules/telegram_gateway.sh" --install >/dev/null 2>&1 || {\n  echo "[AVISO] O gateway Telegram 0.9.0 não pôde inicializar seu estado. Use: manager telegram gateway status" >&2\n}\n"$INSTALL_DIR/modules/telegram_bot.sh" --install >/dev/null 2>&1 || {\n  echo "[AVISO] O ingresso Telegram Bot não pôde reanexar seu estado. Use: manager telegram bot status" >&2\n}\n''')

# CLI help and dispatch
p='manager'
replace_once(p,
'''  manager telegram gateway call /CAMINHO/INITDATA /CAMINHO/REQUEST.json | call-stdin /CAMINHO/REQUEST.json\n                                  gateway tipado Telegram -> Automation v2 (0.9.0)\n''',
'''  manager telegram gateway call /CAMINHO/INITDATA /CAMINHO/REQUEST.json | call-stdin /CAMINHO/REQUEST.json\n                                  gateway tipado Telegram -> Automation v2 (0.9.0)\n  manager telegram bot status|enable [POLL_TIMEOUT]|disable|poll-once\n                                  ingresso Telegram Bot por long polling HTTPS (0.9.x)\n''')
replace_once(p,
'''      gateway)\n        case "${3:-status}" in\n          status) exec "$MANAGER_HOME/modules/telegram_gateway.sh" --status ;;\n          call) [[ -n "${4:-}" && -n "${5:-}" ]] || { err "Uso: manager telegram gateway call /CAMINHO/INITDATA /CAMINHO/REQUEST.json"; exit 64; }; exec "$MANAGER_HOME/modules/telegram_gateway.sh" --call "$4" "$5" ;;\n          call-stdin) [[ -n "${4:-}" ]] || { err "Uso: manager telegram gateway call-stdin /CAMINHO/REQUEST.json"; exit 64; }; exec "$MANAGER_HOME/modules/telegram_gateway.sh" --call-stdin "$4" ;;\n          *) err "Uso: manager telegram gateway {status|call|call-stdin} ..."; exit 64 ;;\n        esac\n        ;;\n      *) err "Uso: manager telegram {identity|auth|gateway} ..."; exit 64 ;;\n''',
'''      gateway)\n        case "${3:-status}" in\n          status) exec "$MANAGER_HOME/modules/telegram_gateway.sh" --status ;;\n          call) [[ -n "${4:-}" && -n "${5:-}" ]] || { err "Uso: manager telegram gateway call /CAMINHO/INITDATA /CAMINHO/REQUEST.json"; exit 64; }; exec "$MANAGER_HOME/modules/telegram_gateway.sh" --call "$4" "$5" ;;\n          call-stdin) [[ -n "${4:-}" ]] || { err "Uso: manager telegram gateway call-stdin /CAMINHO/REQUEST.json"; exit 64; }; exec "$MANAGER_HOME/modules/telegram_gateway.sh" --call-stdin "$4" ;;\n          *) err "Uso: manager telegram gateway {status|call|call-stdin} ..."; exit 64 ;;\n        esac\n        ;;\n      bot)\n        case "${3:-status}" in\n          status) exec "$MANAGER_HOME/modules/telegram_bot.sh" --status ;;\n          enable) exec "$MANAGER_HOME/modules/telegram_bot.sh" --enable "${4:-25}" ;;\n          disable) exec "$MANAGER_HOME/modules/telegram_bot.sh" --disable ;;\n          poll-once) exec "$MANAGER_HOME/modules/telegram_bot.sh" --poll-once ;;\n          *) err "Uso: manager telegram bot {status|enable [POLL_TIMEOUT]|disable|poll-once}"; exit 64 ;;\n        esac\n        ;;\n      *) err "Uso: manager telegram {identity|auth|gateway|bot} ..."; exit 64 ;;\n''')
replace_once(p,
'''      "$MANAGER_HOME/modules/telegram_gateway.sh" --status 2>/dev/null || true\n''',
'''      "$MANAGER_HOME/modules/telegram_gateway.sh" --status 2>/dev/null || true\n      say ""\n      "$MANAGER_HOME/modules/telegram_bot.sh" --status 2>/dev/null || true\n''')

# uninstall lifecycle: stop daemon before Automation v2 and preserve state unless purge.
p='uninstall.sh'
anchor='# Automation v2 possui o socket Unix local e pode possuir o gateway TLS remoto.\n'
block='''# Telegram Bot long polling nunca deve continuar depois que o código/gateway sai.\n# Configuração, offset, bindings e token sobrevivem ao uninstall normal; purge remove.\nif [[ -x /opt/manager/modules/telegram_bot.sh ]]; then\n  /opt/manager/modules/telegram_bot.sh --disable >/dev/null 2>&1 || true\nelse\n  systemctl disable --now manager-telegram-bot.service >/dev/null 2>&1 || true\n  rm -f /etc/systemd/system/manager-telegram-bot.service\n  systemctl daemon-reload >/dev/null 2>&1 || true\nfi\nif $PURGE; then\n  rm -rf /etc/manager/telegram\n  rm -f /var/log/manager/telegram-bot-audit.jsonl /var/log/manager/telegram-gateway-audit.jsonl \\\n    /var/log/manager/telegram-auth-audit.jsonl /var/log/manager/telegram-identity-audit.jsonl\nfi\n\n'''
replace_once(p,anchor,block+anchor)

# Documentation
p='docs/TELEGRAM.md'
s=Path(p).read_text()
marker='## Próximas fatias da 0.9\n'
if marker not in s: raise SystemExit('telegram docs marker missing')
section='''## Ingresso do Telegram Bot por long polling\n\nO Bot usa o mesmo `bot-token` root-only já configurado pela autenticação do Mini App. Por padrão não abre nenhuma porta: o serviço consulta `https://api.telegram.org` por HTTPS com `getUpdates`, guarda apenas o próximo `update_id` e converte comandos conhecidos em `manager-telegram-gateway-request-v1`.\n\n```bash\nmanager telegram bot status\nmanager telegram bot enable 25\nmanager telegram bot disable\nmanager telegram bot poll-once\n```\n\nComandos Bot inicialmente allowlisted: `/describe`, `/node`, `/status ID`, `/revoke ID`, `/preflight ID PLAN [OWNER] [PROTOCOLS]` e `/create ID PLAN [OWNER] [PROTOCOLS]`. Username, nome, chat id e texto livre não concedem autoridade. O `from.id` só escolhe o binding existente; a Automation v2 continua revalidando principal, scopes, rate limit e idempotência antes do dispatcher.\n\nA autenticidade de uma atualização em long polling deriva da conexão HTTPS do MANAGER com a Telegram Bot API usando o token secreto; não existe assinatura individual de cada update. O token nunca é colocado em argv, audit ou resposta pública. O serviço persiste `next_update_id` root-only para não executar novamente updates já consumidos.\n\nContrato do ingresso:\n\n```text\nmanager-telegram-bot-ingress-v1\n```\n\nWebhook permanece uma alternativa futura; ele deverá exigir `X-Telegram-Bot-Api-Secret-Token` e alimentar o mesmo gateway tipado, sem criar outra ACL.\n\n'''
s=s.replace(marker,section+marker,1)
s=s.replace('1. criar o gateway Bot/Mini App consumindo somente ações tipadas e allowlisted da Automation v2;\n2. aplicar rate limit e idempotência por requisição no gateway;\n3. implementar telas e fluxos de sessões, clientes, produtos, cotas, nós e diagnósticos;\n4. adicionar gate end-to-end do gateway real, mantendo o bot token fora de argv, logs e respostas públicas.',
'''1. adicionar webhook autenticado como alternativa ao long polling, reutilizando o mesmo gateway;\n2. implementar telas e fluxos de sessões, clientes, produtos, cotas, nós e diagnósticos;\n3. manter gate end-to-end dos ingressos sem bot token em argv, logs ou respostas públicas.''')
Path(p).write_text(s)

p='docs/ROADMAP.md'
s=Path(p).read_text()
s=s.replace('''Ainda pendente para fechar toda a integração Bot/Mini App da série 0.9:\n\n- ingresso autenticado do Telegram Bot por webhook/long polling reutilizando o mesmo gateway tipado;\n- telas/fluxos de produto posteriores.\n''',
'''Ingresso Telegram Bot implementado nesta fatia:\n\n- long polling HTTPS com a Telegram Bot API sem listener público adicional;\n- `from.id` numérico é resolvido no binding existente e nunca substituído por username/chat/nome;\n- comandos Bot são mapeados para o mesmo contrato `manager-telegram-gateway-request-v1`;\n- Automation v2 continua autoridade única para RBAC, scopes, rate limit, idempotência e dispatcher;\n- offset de `update_id` é persistente/root-only para impedir reexecução de update consumido;\n- bot token permanece fora de argv/audits/respostas.\n\nAinda pendente para fechar toda a integração Bot/Mini App da série 0.9:\n\n- webhook autenticado como transporte alternativo ao long polling;\n- telas/fluxos de produto posteriores.\n''')
Path(p).write_text(s)

for path in ['modules/telegram_gateway.sh','modules/telegram_bot.sh','manager','install.sh','uninstall.sh']:
    import subprocess
    subprocess.run(['bash','-n',path],check=True)
print('telegram bot ingress integration patched')
