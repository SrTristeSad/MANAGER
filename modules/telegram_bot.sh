#!/usr/bin/env bash
set -Eeuo pipefail
set +x
umask 077

MANAGER_HOME="${MANAGER_HOME:-/opt/manager}"
MANAGER_ETC="${MANAGER_ETC:-/etc/manager}"
# shellcheck source=/dev/null
source "$MANAGER_HOME/lib/common.sh"
require_root

STATE_DIR="${MANAGER_TELEGRAM_STATE_DIR:-$MANAGER_ETC/telegram}"
BOT_DIR="$STATE_DIR/bot"
TOKEN_FILE="${MANAGER_TELEGRAM_BOT_TOKEN_FILE:-$STATE_DIR/secrets/bot-token}"
CONFIG_FILE="$BOT_DIR/config.conf"
OFFSET_FILE="$BOT_DIR/offset.conf"
AUDIT_FILE="${MANAGER_TELEGRAM_BOT_AUDIT_FILE:-/var/log/manager/telegram-bot-audit.jsonl}"
GATEWAY_MODULE="${MANAGER_TELEGRAM_GATEWAY_MODULE:-$MANAGER_HOME/modules/telegram_gateway.sh}"
SERVICE_FILE="/etc/systemd/system/manager-telegram-bot.service"
CONTRACT="manager-telegram-bot-ingress-v1"
GATEWAY_REQUEST_CONTRACT="manager-telegram-gateway-request-v1"
DEFAULT_POLL_TIMEOUT=25
MAX_RESPONSE_BYTES=262144

json_escape() { python3 -c 'import json,sys; print(json.dumps(sys.argv[1],ensure_ascii=False))' "$1"; }

read_field() {
  local file="$1" key="$2"
  awk -F= -v k="$key" '$1==k {sub(/^[^=]*=/,""); print; exit}' "$file" 2>/dev/null || true
}

init_state() {
  install -d -m 0700 "$STATE_DIR" "$BOT_DIR" "$(dirname "$AUDIT_FILE")"
  if [[ ! -e "$CONFIG_FILE" ]]; then
    printf 'version=1\nenabled=0\npoll_timeout=%s\n' "$DEFAULT_POLL_TIMEOUT" > "$CONFIG_FILE"
  fi
  if [[ ! -e "$OFFSET_FILE" ]]; then
    printf 'version=1\nnext_update_id=0\n' > "$OFFSET_FILE"
  fi
  [[ -e "$AUDIT_FILE" ]] || : > "$AUDIT_FILE"
  chmod 0600 "$CONFIG_FILE" "$OFFSET_FILE" "$AUDIT_FILE"
}

write_config() {
  local enabled="$1" timeout="$2" tmp
  tmp="$(mktemp "$BOT_DIR/.config.XXXXXX")"
  printf 'version=1\nenabled=%s\npoll_timeout=%s\n' "$enabled" "$timeout" > "$tmp"
  chmod 0600 "$tmp"
  mv -f "$tmp" "$CONFIG_FILE"
}

write_offset() {
  local value="$1" tmp
  [[ "$value" =~ ^[0-9]+$ ]] || return 64
  tmp="$(mktemp "$BOT_DIR/.offset.XXXXXX")"
  printf 'version=1\nnext_update_id=%s\n' "$value" > "$tmp"
  chmod 0600 "$tmp"
  mv -f "$tmp" "$OFFSET_FILE"
}

audit() {
  local event="$1" update_id="${2:-}" uid="${3:-}" action="${4:-}" decision="${5:-}" code="${6:-70}" now
  now="$(date +%s)"
  [[ "$code" =~ ^[0-9]+$ ]] || code=70
  printf '{"contract":"%s","epoch":%s,"event":%s,"update_id":%s,"telegram_user_id":%s,"action_id":%s,"decision":%s,"code":%s}\n' \
    "$CONTRACT" "$now" "$(json_escape "$event")" "$(json_escape "$update_id")" "$(json_escape "$uid")" \
    "$(json_escape "$action")" "$(json_escape "$decision")" "$code" >> "$AUDIT_FILE"
  chmod 0600 "$AUDIT_FILE"
}

status() {
  init_state
  printf 'contract=%s\n' "$CONTRACT"
  printf 'transport=telegram-bot-api-long-polling\n'
  printf 'api_origin=https://api.telegram.org\n'
  printf 'enabled=%s\n' "$(read_field "$CONFIG_FILE" enabled)"
  printf 'poll_timeout=%s\n' "$(read_field "$CONFIG_FILE" poll_timeout)"
  printf 'next_update_id=%s\n' "$(read_field "$OFFSET_FILE" next_update_id)"
  printf 'identity_source=telegram_from_user_id\n'
  printf 'gateway_request_contract=%s\n' "$GATEWAY_REQUEST_CONTRACT"
  printf 'authorization_authority=automation-v2\n'
  printf 'rate_limit_authority=automation-v2-principal-action\n'
  printf 'idempotency_authority=automation-v2-request-id\n'
  printf 'username_is_authority=0\n'
  printf 'arbitrary_shell=0\n'
}

write_service() {
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=MANAGER Telegram Bot long-polling ingress
After=network-online.target manager-automation-v2.service
Wants=network-online.target
Requires=manager-automation-v2.service
ConditionPathExists=$TOKEN_FILE

[Service]
Type=simple
ExecStart=$MANAGER_HOME/modules/telegram_bot.sh --serve
Restart=on-failure
RestartSec=3s
UMask=0077
PrivateTmp=true
NoNewPrivileges=true
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "$SERVICE_FILE"
  systemctl daemon-reload
}

enable_bot() {
  local timeout="${1:-$DEFAULT_POLL_TIMEOUT}"
  init_state
  if [[ ! "$timeout" =~ ^[0-9]+$ ]] || (( 10#$timeout < 1 || 10#$timeout > 50 )); then
    err "poll timeout inválido (1..50)"
    return 64
  fi
  [[ -r "$TOKEN_FILE" ]] || { err "Bot token não configurado"; return 77; }
  [[ -x "$GATEWAY_MODULE" ]] || { err "Gateway Telegram indisponível"; return 70; }
  write_config 1 "$((10#$timeout))"
  write_service
  systemctl enable --now manager-telegram-bot.service >/dev/null
  printf 'enabled=1\npoll_timeout=%s\n' "$((10#$timeout))"
}

disable_bot() {
  local timeout
  init_state
  timeout="$(read_field "$CONFIG_FILE" poll_timeout)"; timeout="${timeout:-$DEFAULT_POLL_TIMEOUT}"
  write_config 0 "$timeout"
  systemctl disable --now manager-telegram-bot.service >/dev/null 2>&1 || true
  printf 'enabled=0\n'
}

fetch_updates() {
  local timeout="$1" offset="$2"
  python3 - "$TOKEN_FILE" "$timeout" "$offset" "$MAX_RESPONSE_BYTES" <<'PY'
import json, os, re, ssl, sys, urllib.parse, urllib.request

token_file, timeout, offset, max_bytes=sys.argv[1:5]
timeout=int(timeout); offset=int(offset); max_bytes=int(max_bytes)
token=open(token_file,encoding='ascii').read().strip()
if not re.fullmatch(r'[1-9][0-9]{4,15}:[A-Za-z0-9_-]{20,128}',token): raise SystemExit(77)
base=os.environ.get('MANAGER_TELEGRAM_BOT_API_BASE','https://api.telegram.org')
if base != 'https://api.telegram.org':
    if os.environ.get('GITHUB_ACTIONS')!='true' or not base.startswith('https://127.0.0.1:'):
        raise SystemExit('API base override recusado')
query=urllib.parse.urlencode({'offset':offset,'timeout':timeout,'allowed_updates':json.dumps(['message','callback_query'],separators=(',',':'))})
url=f'{base}/bot{token}/getUpdates?{query}'
ctx=ssl.create_default_context()
cafile=os.environ.get('MANAGER_TELEGRAM_BOT_TEST_CA','')
if cafile:
    if os.environ.get('GITHUB_ACTIONS')!='true': raise SystemExit('CA override recusada')
    ctx=ssl.create_default_context(cafile=cafile)
req=urllib.request.Request(url,headers={'User-Agent':'MANAGER-TelegramBot/1'})
with urllib.request.urlopen(req,timeout=timeout+10,context=ctx) as r:
    raw=r.read(max_bytes+1)
if len(raw)>max_bytes: raise SystemExit('resposta Telegram excede limite')
obj=json.loads(raw)
if not isinstance(obj,dict) or obj.get('ok') is not True or not isinstance(obj.get('result'),list): raise SystemExit('resposta Telegram inválida')
print(json.dumps(obj['result'],separators=(',',':'),ensure_ascii=False))
PY
}

process_update() {
  local update_file="$1" result meta rc update_id uid action code decision
  result="$(mktemp "$BOT_DIR/.result.XXXXXX")"
  meta="$(mktemp "$BOT_DIR/.meta.XXXXXX")"
  set +e
  python3 - "$GATEWAY_MODULE" "$GATEWAY_REQUEST_CONTRACT" "$update_file" "$meta" > "$result" <<'PY'
import json, os, re, subprocess, sys, tempfile

gateway, contract, path, meta_path=sys.argv[1:5]
ID_RE=re.compile(r'^[A-Za-z0-9][A-Za-z0-9_.-]{0,47}$')
PLAN_RE=re.compile(r'^[A-Za-z0-9][A-Za-z0-9_.-]{0,47}$')

def meta(**kw):
    safe={'update_id':str(kw.get('update_id',''))[:32],'telegram_user_id':str(kw.get('telegram_user_id',''))[:32],
          'action_id':str(kw.get('action_id',''))[:64],'code':int(kw.get('code',70)),'decision':str(kw.get('decision','deny'))[:16]}
    with open(meta_path,'w',encoding='utf-8') as f: json.dump(safe,f,separators=(',',':')); f.write('\n')

def fail(msg,code=64,**kw):
    meta(code=code,decision='deny',**kw)
    print(json.dumps({'contract':'manager-telegram-bot-ingress-v1','ok':False,'code':code,'error':msg},separators=(',',':')))
    raise SystemExit(code)

try: update=json.load(open(path,encoding='utf-8'))
except Exception: fail('update Telegram inválido',64)
if not isinstance(update,dict): fail('update Telegram inválido',64)
update_id=update.get('update_id')
if isinstance(update_id,bool) or not isinstance(update_id,int) or update_id<0: fail('update_id inválido',64)
source=None; text=''
if isinstance(update.get('message'),dict):
    source=update['message'].get('from'); text=update['message'].get('text','')
elif isinstance(update.get('callback_query'),dict):
    source=update['callback_query'].get('from'); text=update['callback_query'].get('data','')
else:
    meta(update_id=update_id,code=0,decision='ignore')
    print(json.dumps({'contract':'manager-telegram-bot-ingress-v1','update_id':update_id,'ignored':1},separators=(',',':'))); raise SystemExit(0)
if not isinstance(source,dict): fail('from ausente',64,update_id=update_id)
uid=source.get('id')
if isinstance(uid,bool) or not isinstance(uid,int) or not (0 < uid <= 2**52-1): fail('from.id inválido',64,update_id=update_id)
if not isinstance(text,str) or len(text)>2048: fail('texto Telegram inválido',64,update_id=update_id,telegram_user_id=uid)
parts=text.strip().split()
if not parts:
    meta(update_id=update_id,telegram_user_id=uid,code=0,decision='ignore'); print(json.dumps({'contract':'manager-telegram-bot-ingress-v1','update_id':update_id,'telegram_user_id':str(uid),'ignored':1},separators=(',',':'))); raise SystemExit(0)
cmd=parts[0].split('@',1)[0].lower(); args=parts[1:]; action=None; params={}
if cmd in {'/describe','describe'} and not args: action='system.describe'
elif cmd in {'/node','/node_usage','node'} and not args: action='node.usage'
elif cmd in {'/status','status'} and len(args)==1: action='connection.status'; params={'id':args[0]}
elif cmd in {'/revoke','revoke'} and len(args)==1: action='connection.revoke'; params={'id':args[0]}
elif cmd in {'/preflight','preflight'} and 2 <= len(args) <= 4:
    action='connection.preflight'; params={'id':args[0],'plan':args[1]}
    if len(args)>2: params['owner']=args[2]
    if len(args)>3: params['protocols']=args[3]
elif cmd in {'/create','create'} and 2 <= len(args) <= 4:
    action='connection.create'; params={'id':args[0],'plan':args[1]}
    if len(args)>2: params['owner']=args[2]
    if len(args)>3: params['protocols']=args[3]
else:
    meta(update_id=update_id,telegram_user_id=uid,code=0,decision='ignore'); print(json.dumps({'contract':'manager-telegram-bot-ingress-v1','update_id':update_id,'telegram_user_id':str(uid),'ignored':1},separators=(',',':'))); raise SystemExit(0)
for key,value in params.items():
    if not isinstance(value,str) or len(value)>128 or '\x00' in value: fail('parâmetro Telegram inválido',64,update_id=update_id,telegram_user_id=uid,action_id=action)
    if key in {'id','owner'} and value and not ID_RE.fullmatch(value): fail('identificador inválido',64,update_id=update_id,telegram_user_id=uid,action_id=action)
    if key=='plan' and not PLAN_RE.fullmatch(value): fail('plano inválido',64,update_id=update_id,telegram_user_id=uid,action_id=action)
request={'contract':contract,'request_id':f'bot-{update_id:020d}','action_id':action,'params':params}
fd,tmp=tempfile.mkstemp(prefix='.bot-request-',suffix='.json')
try:
    os.fchmod(fd,0o600)
    with os.fdopen(fd,'w',encoding='utf-8') as f: json.dump(request,f,separators=(',',':')); f.write('\n')
    proc=subprocess.run([gateway,'--call-bot-user',str(uid),tmp],stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True,timeout=210,check=False)
finally:
    try: os.unlink(tmp)
    except FileNotFoundError: pass
try: out=json.loads(proc.stdout)
except Exception: fail('resposta inválida do gateway',70,update_id=update_id,telegram_user_id=uid,action_id=action)
if not isinstance(out,dict): fail('resposta inválida do gateway',70,update_id=update_id,telegram_user_id=uid,action_id=action)
out['bot_update_id']=update_id
code=out.get('code',proc.returncode)
if isinstance(code,bool) or not isinstance(code,int) or not 0 <= code <= 255: code=70
meta(update_id=update_id,telegram_user_id=uid,action_id=action,code=code,decision='allow' if code==0 else 'deny')
print(json.dumps(out,separators=(',',':'),ensure_ascii=False)); raise SystemExit(code)
PY
  rc=$?
  set -e
  update_id="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("update_id",""))' "$meta" 2>/dev/null || true)"
  uid="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("telegram_user_id",""))' "$meta" 2>/dev/null || true)"
  action="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("action_id",""))' "$meta" 2>/dev/null || true)"
  code="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("code",70))' "$meta" 2>/dev/null || echo 70)"
  decision="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("decision","deny"))' "$meta" 2>/dev/null || echo deny)"
  audit update "$update_id" "$uid" "$action" "$decision" "$code"
  cat "$result"
  rm -f "$result" "$meta"
  return "$rc"
}

poll_once() {
  local timeout offset updates paths path update_id max_id=-1
  init_state
  [[ -r "$TOKEN_FILE" ]] || { err "Bot token não configurado"; return 77; }
  [[ -x "$GATEWAY_MODULE" ]] || { err "Gateway Telegram indisponível"; return 70; }
  timeout="$(read_field "$CONFIG_FILE" poll_timeout)"; timeout="${timeout:-$DEFAULT_POLL_TIMEOUT}"
  offset="$(read_field "$OFFSET_FILE" next_update_id)"; offset="${offset:-0}"
  updates="$(mktemp "$BOT_DIR/.updates.XXXXXX")"
  fetch_updates "$timeout" "$offset" > "$updates"
  paths="$(mktemp "$BOT_DIR/.paths.XXXXXX")"
  python3 - "$updates" "$BOT_DIR" > "$paths" <<'PY'
import json,os,sys
updates=json.load(open(sys.argv[1])); outdir=sys.argv[2]
if not isinstance(updates,list): raise SystemExit(70)
for u in updates:
    i=u.get('update_id') if isinstance(u,dict) else None
    if isinstance(i,bool) or not isinstance(i,int) or i<0: continue
    path=os.path.join(outdir,f'.update-{i}.json')
    fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
    with os.fdopen(fd,'w',encoding='utf-8') as f: json.dump(u,f,separators=(',',':')); f.write('\n')
    print(path)
PY
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    update_id="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["update_id"])' "$path")"
    process_update "$path" >/dev/null || true
    rm -f "$path"
    (( update_id > max_id )) && max_id="$update_id"
  done < "$paths"
  rm -f "$updates" "$paths"
  if (( max_id >= 0 )); then write_offset "$((max_id+1))"; fi
  printf 'processed_until=%s\nnext_update_id=%s\n' "$max_id" "$(read_field "$OFFSET_FILE" next_update_id)"
}

serve() {
  init_state
  [[ "$(read_field "$CONFIG_FILE" enabled)" == 1 ]] || { err "Bot long polling desabilitado"; return 77; }
  while true; do
    poll_once || { audit transport '' '' '' deny 70; sleep 3; }
  done
}

case "${1:-}" in
  --install)
    init_state
    if [[ "$(read_field "$CONFIG_FILE" enabled)" == 1 ]]; then
      write_service
    fi
    ;;
  --status) status ;;
  --enable) enable_bot "${2:-$DEFAULT_POLL_TIMEOUT}" ;;
  --disable) disable_bot ;;
  --serve) serve ;;
  --poll-once) poll_once ;;
  --process-update) process_update "${2:-}" ;;
  *) err "Uso: telegram_bot.sh {--status|--enable [TIMEOUT]|--disable|--serve|--poll-once|--process-update FILE}"; exit 64 ;;
esac
