from pathlib import Path


def replace_once(path, old, new):
    p=Path(path); s=p.read_text()
    if old not in s:
        raise SystemExit(f'anchor missing: {path}')
    p.write_text(s.replace(old,new,1))

# Honor the documented optional polling timeout and refuse manual --serve while disabled.
p='modules/telegram_bot.sh'
s=Path(p).read_text()
s=s.replace('''set_enabled() {\n  local value="$1" timeout tmp\n  init_state\n  timeout="$(read_field "$CONFIG_FILE" poll_timeout_seconds)"\n  [[ "$timeout" =~ ^[0-9]+$ ]] || timeout="$DEFAULT_POLL_TIMEOUT"\n''','''set_enabled() {\n  local value="$1" timeout="${2:-}" tmp\n  init_state\n  if [[ -z "$timeout" ]]; then\n    timeout="$(read_field "$CONFIG_FILE" poll_timeout_seconds)"\n  fi\n  [[ "$timeout" =~ ^[0-9]+$ ]] && (( 10#$timeout >= 1 && 10#$timeout <= 50 )) || { err "poll timeout inválido (1..50)"; return 64; }\n  timeout="$((10#$timeout))"\n''',1)
s=s.replace('''enable_bot() {\n  init_state\n''','''enable_bot() {\n  local timeout="${1:-}"\n  init_state\n''',1)
s=s.replace('''  write_service\n  set_enabled 1\n  systemctl enable --now manager-telegram-bot.service >/dev/null\n  printf 'bot_enabled=1\\n'\n''','''  write_service\n  set_enabled 1 "$timeout"\n  systemctl enable --now manager-telegram-bot.service >/dev/null\n  printf 'bot_enabled=1\\npoll_timeout_seconds=%s\\n' "$(read_field "$CONFIG_FILE" poll_timeout_seconds)"\n''',1)
s=s.replace('''serve_bot() {\n  init_state\n  while true; do\n''','''serve_bot() {\n  init_state\n  [[ "$(read_field "$CONFIG_FILE" enabled)" == 1 ]] || { err "Bot long polling desabilitado"; return 77; }\n  while true; do\n''',1)
s=s.replace('''  --enable) enable_bot; exit $? ;;''','''  --enable) enable_bot "${2:-}"; exit $? ;;''',1)
Path(p).write_text(s)

# Correct uninstall lifecycle: detach the unit on normal uninstall; purge all Telegram state only on --purge.
p='uninstall.sh'; s=Path(p).read_text()
old='''# Telegram Bot long polling nunca deve continuar depois que o código/gateway sai.\n# Configuração, offset, bindings e token sobrevivem ao uninstall normal; purge remove.\nif [[ -x /opt/manager/modules/telegram_bot.sh ]]; then\n  /opt/manager/modules/telegram_bot.sh --disable >/dev/null 2>&1 || true\nelse\n  systemctl disable --now manager-telegram-bot.service >/dev/null 2>&1 || true\n  rm -f /etc/systemd/system/manager-telegram-bot.service\n  systemctl daemon-reload >/dev/null 2>&1 || true\nfi\nif $PURGE; then\n  rm -rf /etc/manager/telegram\n  rm -f /var/log/manager/telegram-bot-audit.jsonl /var/log/manager/telegram-gateway-audit.jsonl \\\n    /var/log/manager/telegram-auth-audit.jsonl /var/log/manager/telegram-identity-audit.jsonl\nfi\n'''
new='''# Telegram Bot long polling não abre listener, mas depende da Automation v2.\n# A unidade sai antes do managerd; todo estado Telegram sobrevive ao uninstall normal.\nif [[ -x /opt/manager/modules/telegram_bot.sh ]]; then\n  if $PURGE; then\n    /opt/manager/modules/telegram_bot.sh --purge >/dev/null 2>&1 || true\n  else\n    /opt/manager/modules/telegram_bot.sh --detach >/dev/null 2>&1 || true\n  fi\nelse\n  systemctl disable --now manager-telegram-bot.service >/dev/null 2>&1 || true\n  rm -f /etc/systemd/system/manager-telegram-bot.service\n  systemctl daemon-reload >/dev/null 2>&1 || true\nfi\nif $PURGE; then\n  rm -rf /etc/manager/telegram /var/lib/manager/telegram-bot\n  rm -f /var/log/manager/telegram-bot-audit.jsonl /var/log/manager/telegram-gateway-audit.jsonl \\\n    /var/log/manager/telegram-auth-audit.jsonl /var/log/manager/telegram-identity-audit.jsonl\nfi\n'''
if old not in s: raise SystemExit('uninstall anchor missing')
Path(p).write_text(s.replace(old,new,1))

# Documentation: Bot ingress is deliberately read-only in this first public command surface.
p='docs/TELEGRAM.md'; s=Path(p).read_text()
s=s.replace('''manager telegram bot enable 25''','''manager telegram bot enable [POLL_TIMEOUT]''',1)
s=s.replace('''Comandos Bot inicialmente allowlisted: `/describe`, `/node`, `/status ID`, `/revoke ID`, `/preflight ID PLAN [OWNER] [PROTOCOLS]` e `/create ID PLAN [OWNER] [PROTOCOLS]`. Username, nome, chat id e texto livre não concedem autoridade. O `from.id` só escolhe o binding existente; a Automation v2 continua revalidando principal, scopes, rate limit e idempotência antes do dispatcher.''','''Comandos Bot inicialmente allowlisted: `/describe`, `/node` e `/status ID`. O ingresso conversacional permanece somente leitura nesta fatia; operações de escrita continuam disponíveis no gateway/Mini App e ganharão confirmação explícita na UX antes de serem expostas no Bot. Username, nome, chat id e texto livre não concedem autoridade. O `from.id` só escolhe o binding existente; a Automation v2 continua revalidando principal, scopes, rate limit e idempotência antes do dispatcher.''',1)
s=s.replace('''O serviço persiste `next_update_id` root-only para não executar novamente updates já consumidos.''','''O serviço responde pelo método `sendMessage` e só avança o `update_id` depois que a resposta foi aceita pela Bot API. Se a entrega falhar, o mesmo update é tentado novamente com o mesmo `request_id`; a Automation v2 devolve o resultado idempotente em cache em vez de executar a ação novamente. O offset fica root-only.''',1)
Path(p).write_text(s)

p='docs/ROADMAP.md'; s=Path(p).read_text()
s=s.replace('''- comandos Bot são mapeados para o mesmo contrato `manager-telegram-gateway-request-v1`;''','''- comandos Bot de leitura (`/describe`, `/node`, `/status ID`) são mapeados para o mesmo contrato `manager-telegram-gateway-request-v1`;''',1)
s=s.replace('''- offset de `update_id` é persistente/root-only para impedir reexecução de update consumido;''','''- resposta usa `sendMessage`; o offset de `update_id` só avança após entrega aceita, e retry reutiliza o mesmo `request_id` idempotente sem reexecutar a ação;\n- ingresso conversacional permanece read-only nesta fatia; escrita exige fluxo/UX com confirmação explícita;''',1)
Path(p).write_text(s)

# Syntax/static cleanliness.
