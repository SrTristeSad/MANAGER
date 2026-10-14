from pathlib import Path
p=Path('modules/telegram_bot.sh')
s=p.read_text()
old='''  [[ "$timeout" =~ ^[0-9]+$ ]] && (( 10#$timeout >= 1 && 10#$timeout <= 50 )) || { err "poll timeout inválido (1..50)"; return 64; }\n'''
new='''  if [[ ! "$timeout" =~ ^[0-9]+$ ]] || (( 10#$timeout < 1 || 10#$timeout > 50 )); then\n    err "poll timeout inválido (1..50)"\n    return 64\n  fi\n'''
if old not in s: raise SystemExit('timeout anchor missing')
s=s.replace(old,new,1)
old='''  --install) init_state; [[ "$(read_field "$CONFIG_FILE" enabled)" == 1 ]] && write_service || true ;;\n'''
new='''  --install)\n    init_state\n    if [[ "$(read_field "$CONFIG_FILE" enabled)" == 1 ]]; then\n      write_service\n    fi\n    ;;\n'''
if old not in s: raise SystemExit('install anchor missing')
s=s.replace(old,new,1)
p.write_text(s)
