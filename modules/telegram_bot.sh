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
CONFIG_FILE="$BOT_DIR/config.conf"
TOKEN_FILE="${MANAGER_TELEGRAM_BOT_TOKEN_FILE:-$STATE_DIR/secrets/bot-token}"
DATA_DIR="${MANAGER_TELEGRAM_BOT_DATA_DIR:-/var/lib/manager/telegram-bot}"
OFFSET_FILE="$DATA_DIR/offset"
AUDIT_FILE="${MANAGER_TELEGRAM_BOT_AUDIT_FILE:-/var/log/manager/telegram-bot-audit.jsonl}"
GATEWAY_MODULE="${MANAGER_TELEGRAM_GATEWAY_MODULE:-$MANAGER_HOME/modules/telegram_gateway.sh}"
OPERATIONS_MODULE="${MANAGER_TELEGRAM_OPERATIONS_MODULE:-$MANAGER_HOME/modules/telegram_operations.sh}"
SERVICE_FILE="/etc/systemd/system/manager-telegram-bot.service"
CONTRACT="manager-telegram-bot-ingress-v1"
OFFICIAL_API_BASE="https://api.telegram.org"
DEFAULT_POLL_TIMEOUT=20

read_field() {
  local file="$1" key="$2"
  awk -F= -v k="$key" '$1==k {sub(/^[^=]*=/,""); print; exit}' "$file" 2>/dev/null || true
}

init_state() {
  install -d -m 0700 "$STATE_DIR" "$BOT_DIR" "$DATA_DIR" "$(dirname "$AUDIT_FILE")"
  if [[ ! -e "$CONFIG_FILE" ]]; then
    local tmp
    tmp="$(mktemp "$BOT_DIR/.config.XXXXXX")"
    {
      printf 'version=1\n'
      printf 'enabled=0\n'
      printf 'poll_timeout_seconds=%s\n' "$DEFAULT_POLL_TIMEOUT"
    } > "$tmp"
    install -m 0600 "$tmp" "$CONFIG_FILE"
    rm -f "$tmp"
  fi
  chmod 0600 "$CONFIG_FILE"
  if [[ ! -e "$OFFSET_FILE" ]]; then
    printf '0\n' > "$OFFSET_FILE"
  fi
  chmod 0600 "$OFFSET_FILE"
  if [[ ! -e "$AUDIT_FILE" ]]; then
    : > "$AUDIT_FILE"
  fi
  chmod 0600 "$AUDIT_FILE"
}

valid_token_file() {
  [[ -f "$TOKEN_FILE" && ! -L "$TOKEN_FILE" ]] || return 1
  [[ "$(stat -c '%u' "$TOKEN_FILE" 2>/dev/null || echo 1)" == 0 ]] || return 1
  local mode token
  mode="$(stat -c '%a' "$TOKEN_FILE" 2>/dev/null || echo 777)"
  [[ "$mode" == 600 ]] || return 1
  IFS= read -r token < "$TOKEN_FILE" || true
  [[ "$token" =~ ^[1-9][0-9]{4,15}:[A-Za-z0-9_-]{20,128}$ ]]
}

write_service() {
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=MANAGER Telegram Bot long-polling ingress
After=network-online.target manager-automation-v2.service
Wants=network-online.target
Requires=manager-automation-v2.service
ConditionPathExists=$MANAGER_HOME/modules/telegram_bot.sh
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
PrivateDevices=true
RestrictSUIDSGID=true

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "$SERVICE_FILE"
  systemctl daemon-reload >/dev/null 2>&1 || true
}

set_enabled() {
  local value="$1" timeout tmp
  init_state
  timeout="$(read_field "$CONFIG_FILE" poll_timeout_seconds)"
  [[ "$timeout" =~ ^[0-9]+$ ]] || timeout="$DEFAULT_POLL_TIMEOUT"
  tmp="$(mktemp "$BOT_DIR/.config.XXXXXX")"
  {
    printf 'version=1\n'
    printf 'enabled=%s\n' "$value"
    printf 'poll_timeout_seconds=%s\n' "$timeout"
  } > "$tmp"
  install -m 0600 "$tmp" "$CONFIG_FILE"
  rm -f "$tmp"
}

install_bot() {
  init_state
  write_service
  if [[ "$(read_field "$CONFIG_FILE" enabled)" == 1 ]] && valid_token_file; then
    systemctl enable --now manager-telegram-bot.service >/dev/null 2>&1 || true
  fi
}

detach_bot() {
  systemctl disable --now manager-telegram-bot.service >/dev/null 2>&1 || true
  rm -f "$SERVICE_FILE"
  systemctl daemon-reload >/dev/null 2>&1 || true
}

purge_bot() {
  detach_bot
  rm -rf "$BOT_DIR" "$DATA_DIR"
  rm -f "$AUDIT_FILE"
}

status() {
  init_state
  local active=0 enabled=0 token=0 timeout
  systemctl is-active --quiet manager-telegram-bot.service 2>/dev/null && active=1
  systemctl is-enabled --quiet manager-telegram-bot.service 2>/dev/null && enabled=1
  valid_token_file && token=1
  timeout="$(read_field "$CONFIG_FILE" poll_timeout_seconds)"
  printf 'contract=%s\n' "$CONTRACT"
  printf 'ingress=telegram-bot-api-long-polling\n'
  printf 'api_base=%s\n' "$OFFICIAL_API_BASE"
  printf 'public_listener=0\n'
  printf 'webhook_listener=0\n'
  printf 'bot_token_argv=0\n'
  printf 'telegram_user_id_source=authenticated-bot-api-update-from-id\n'
  printf 'gateway_contract=manager-telegram-gateway-request-v1\n'
  printf 'authorization_authority=automation-v2\n'
  printf 'typed_bot_actions=system.describe,node.usage,connection.status\n'
  printf 'read_only_bot_operations=identities,products,sessions,nodes,diagnostics\n'
  printf 'confirmed_bot_writes=connection.revoke\n'
  printf 'service_enabled=%s\nservice_active=%s\n' "$enabled" "$active"
  printf 'token_configured=%s\npoll_timeout_seconds=%s\n' "$token" "$timeout"
  printf 'arbitrary_shell=0\n'
}

enable_bot() {
  init_state
  valid_token_file || { err "Bot token Telegram ausente ou inseguro. Use: manager telegram auth token install ARQUIVO"; return 77; }
  [[ -x "$GATEWAY_MODULE" ]] || { err "Gateway Telegram indisponível"; return 70; }
  write_service
  set_enabled 1
  systemctl enable --now manager-telegram-bot.service >/dev/null
  printf 'bot_enabled=1\n'
}

disable_bot() {
  set_enabled 0
  systemctl disable --now manager-telegram-bot.service >/dev/null 2>&1 || true
  printf 'bot_enabled=0\n'
}

poll_once() {
  init_state
  valid_token_file || { err "Bot token Telegram ausente ou inseguro"; return 77; }
  [[ -x "$GATEWAY_MODULE" ]] || { err "Gateway Telegram indisponível"; return 70; }
  local timeout
  timeout="$(read_field "$CONFIG_FILE" poll_timeout_seconds)"
  [[ "$timeout" =~ ^[0-9]+$ ]] && (( 10#$timeout >= 1 && 10#$timeout <= 50 )) || timeout="$DEFAULT_POLL_TIMEOUT"
  python3 - "$CONTRACT" "$TOKEN_FILE" "$OFFSET_FILE" "$AUDIT_FILE" "$GATEWAY_MODULE" "$BOT_DIR" "$timeout" "$OFFICIAL_API_BASE" "$OPERATIONS_MODULE" <<'PY'
import json
import os
import re
import secrets
import time
import ssl
import stat
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

contract, token_file, offset_file, audit_file, gateway, bot_dir, timeout_s, official_base, operations_module = sys.argv[1:10]
timeout = int(timeout_s)
MAX_RESPONSE = 1024 * 1024
MAX_REPLY = 3500
ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,47}$")
SENSITIVE_RE = re.compile(r"(?i)(password|passwd|secret|private[_-]?key|credential|token|signature|hash|nonce|query_id|username|first_name|init[_-]?data)")
READ_COMMANDS = {"/nodes": "nodes", "/diagnostics": "diagnostics"}
PENDING_TTL_SECONDS = 120
CONFIRM_RE = re.compile(r'^[a-f0-9]{16}"/clients": "clients", "/products": "products",
                   "/sessions": "sessions", "/quotas": "quotas"}


def die(message, code=70):
    print(message, file=sys.stderr)
    raise SystemExit(code)


def secure_file(path, mode=0o600):
    st=os.lstat(path)
    if not stat.S_ISREG(st.st_mode) or st.st_uid != 0 or stat.S_IMODE(st.st_mode) != mode:
        raise PermissionError(path)

try:
    secure_file(token_file)
    token=Path(token_file).read_text(encoding='ascii').rstrip('\r\n')
except Exception:
    die('telegram-bot-token-invalid',77)
if not re.fullmatch(r'[1-9][0-9]{4,15}:[A-Za-z0-9_-]{20,128}',token):
    die('telegram-bot-token-invalid',77)

api_base=os.environ.get('MANAGER_TELEGRAM_BOT_API_BASE',official_base).rstrip('/')
if api_base != official_base:
    allow=os.environ.get('MANAGER_TELEGRAM_ALLOW_TEST_API') == '1' or os.environ.get('GITHUB_ACTIONS','').lower() == 'true'
    try:
        parsed=urllib.parse.urlparse(api_base)
        host=parsed.hostname
    except Exception:
        die('telegram-bot-api-base-invalid',64)
    if not allow or parsed.scheme not in {'http','https'} or host not in {'127.0.0.1','localhost','::1'}:
        die('telegram-bot-api-base-refused',67)
else:
    parsed=urllib.parse.urlparse(api_base)
    if parsed.scheme != 'https' or parsed.hostname != 'api.telegram.org':
        die('telegram-bot-api-base-invalid',70)


def api(method, payload):
    # Token is composed inside this process and never appears in argv or audit.
    url=f'{api_base}/bot{token}/{method}'
    data=urllib.parse.urlencode(payload).encode('utf-8')
    req=urllib.request.Request(url,data=data,method='POST',headers={'Content-Type':'application/x-www-form-urlencoded','User-Agent':'MANAGER-Telegram-Bot/1'})
    context=ssl.create_default_context() if parsed.scheme == 'https' else None
    try:
        with urllib.request.urlopen(req,timeout=timeout+10,context=context) as resp:
            raw=resp.read(MAX_RESPONSE+1)
    except Exception:
        raise RuntimeError('bot-api-request-failed')
    if len(raw)>MAX_RESPONSE:
        raise RuntimeError('bot-api-response-too-large')
    try:
        obj=json.loads(raw.decode('utf-8'))
    except Exception:
        raise RuntimeError('bot-api-response-invalid')
    if not isinstance(obj,dict) or obj.get('ok') is not True:
        raise RuntimeError('bot-api-response-denied')
    return obj.get('result')


def read_offset():
    try:
        secure_file(offset_file)
        raw=Path(offset_file).read_text(encoding='ascii').strip()
        value=int(raw)
    except Exception:
        raise RuntimeError('offset-invalid')
    if value < 0:
        raise RuntimeError('offset-invalid')
    return value


def write_offset(value):
    os.makedirs(os.path.dirname(offset_file),mode=0o700,exist_ok=True)
    fd,tmp=tempfile.mkstemp(prefix='.offset.',dir=os.path.dirname(offset_file),text=True)
    try:
        os.fchmod(fd,0o600)
        with os.fdopen(fd,'w',encoding='ascii') as fh:
            fh.write(str(value)+'\n'); fh.flush(); os.fsync(fh.fileno())
        os.replace(tmp,offset_file); os.chmod(offset_file,0o600)
    finally:
        try: os.unlink(tmp)
        except FileNotFoundError: pass


def audit(event, update_id=0, uid='', command='', action='', code=70, cached=0, decision='deny'):
    row={'contract':contract,'event':event,'update_id':int(update_id),'telegram_user_id':str(uid)[:32],
         'command_id':str(command)[:32],'action_id':str(action)[:64],'code':int(code),'cached':1 if cached else 0,
         'decision':str(decision)[:32]}
    os.makedirs(os.path.dirname(audit_file),mode=0o700,exist_ok=True)
    with open(audit_file,'a',encoding='utf-8') as fh:
        fh.write(json.dumps(row,sort_keys=True,separators=(',',':'))+'\n')
    os.chmod(audit_file,0o600)


def command_for(text):
    if not isinstance(text,str) or len(text)>4096:
        return ('ignore','',{})
    parts=text.strip().split()
    if not parts:
        return ('ignore','',{})
    cmd=parts[0].split('@',1)[0].lower()
    if cmd in {'/start','/help'} and len(parts)==1:
        return ('help','',{})
    if cmd == '/describe' and len(parts)==1:
        return ('describe','system.describe',{})
    if cmd == '/node' and len(parts)==1:
        return ('node','node.usage',{})
    if cmd == '/revoke' and len(parts)==2 and ID_RE.fullmatch(parts[1]):
        return ('revoke-propose','',{'id':parts[1]})
    if cmd == '/confirm' and len(parts)==2 and CONFIRM_RE.fullmatch(parts[1]):
        return ('revoke-confirm','',{'code':parts[1]})
    if cmd == '/cancel' and len(parts)==1:
        return ('revoke-cancel','',{})
    if cmd == '/status' and len(parts)==2 and ID_RE.fullmatch(parts[1]):
        return ('status','connection.status',{'id':parts[1]})
    if cmd in SCOPED_COMMANDS and len(parts) in (1, 2):
        if len(parts) == 2:
            raw_page = parts[1]
            if not raw_page.isascii() or not raw_page.isdecimal() or len(raw_page) > 6:
                return ('help','',{})
            page = int(raw_page)
            if not (1 <= page <= 100001):
                return ('help','',{})
        else:
            page = 1
        return (cmd.lstrip('/'),'ops.read',
                {'view': SCOPED_COMMANDS[cmd], 'page': str(page - 1), 'limit': '8'})
    if cmd in READ_COMMANDS and len(parts)==1:
        return (cmd.lstrip('/'),'read:'+READ_COMMANDS[cmd],{})
    return ('help','',{})


def pending_path(uid):
    return os.path.join(bot_dir, f'.pending-revoke-{uid}.json')


def write_pending(uid, target):
    code = secrets.token_hex(8)
    record = {'uid': uid, 'id': target, 'code': code, 'expires': int(time.time()) + PENDING_TTL_SECONDS}
    path = pending_path(uid)
    fd, tmp = tempfile.mkstemp(prefix='.pending.', dir=bot_dir, text=True)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, 'w', encoding='utf-8') as fh:
            json.dump(record, fh, separators=(',', ':'))
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)
    finally:
        try: os.unlink(tmp)
        except FileNotFoundError: pass
    return code


def read_pending(uid, code):
    path = pending_path(uid)
    try:
        secure_file(path)
        record = json.loads(Path(path).read_text(encoding='utf-8'))
    except (OSError, ValueError, PermissionError):
        return None
    if not isinstance(record, dict) or set(record) != {'uid','id','code','expires'}:
        return None
    if record['uid'] != uid or not isinstance(record['code'], str) or not secrets.compare_digest(record['code'], code):
        return None
    if type(record['expires']) is not int or record['expires'] < int(time.time()):
        return None
    if not isinstance(record['id'], str) or not ID_RE.fullmatch(record['id']):
        return None
    return record['id']


def clear_pending(uid):
    try: os.unlink(pending_path(uid))
    except FileNotFoundError: pass


def safe_clone(value):
    if isinstance(value,dict):
        out={}
        for k,v in value.items():
            if SENSITIVE_RE.search(str(k)):
                continue
            out[str(k)[:64]]=safe_clone(v)
        return out
    if isinstance(value,list):
        return [safe_clone(x) for x in value[:50]]
    if isinstance(value,str):
        return value[:1000]
    if value is None or isinstance(value,(bool,int,float)):
        return value
    return str(value)[:1000]


def concise(value, limit=90):
    if not isinstance(value, (str, int, float, bool)):
        return ""
    return re.sub(r"[\x00-\x1f\x7f-\x9f]", " ", str(value))[:limit]


def format_operational_reply(payload):
    operation = payload.get('operation')
    data = payload.get('result')
    if not isinstance(data, dict) or data.get('contract') != 'manager-automation-read-ops-v1' or data.get('kind') != operation:
        return 'Resposta operacional indisponível.'
    if operation == 'diagnostics':
        summary = data.get('summary')
        if not isinstance(summary, dict):
            return 'Resposta operacional indisponível.'
        fields = ('load1', 'memory_used_percent', 'root_disk_used_percent',
                  'ssh', 'wireguard', 'openvpn', 'automation_v2', 'telegram_bot')
        lines = ['Diagnóstico do nó']
        lines += [f'{key}: {concise(summary[key])}' for key in fields if key in summary]
        return '\n'.join(lines)[:MAX_REPLY]
    headings = {
        'identities': ('Clientes', ('id', 'state', 'owner', 'product_id', 'quota_used_bytes', 'quota_bytes')),
        'products': ('Produtos', ('id', 'name', 'enabled', 'max_sessions', 'traffic_quota_bytes')),
        'sessions': ('Sessões', ('identity_id', 'session_id', 'protocol', 'remaining_seconds')),
        'nodes': ('Nós', ('node_id', 'state', 'sessions', 'capacity', 'cpu_percent')),
    }
    if operation not in headings or not isinstance(data.get('items'), list):
        return 'Resposta operacional indisponível.'
    title, fields = headings[operation]
    items = data['items']
    lines = [f'{title} — {len(items)} resultado(s) nesta consulta (máximo 100).']
    for item in items[:8]:
        if isinstance(item, dict):
            summary = ' | '.join(f'{key}: {concise(item[key])}' for key in fields if key in item)
            if summary:
                lines.append('- ' + summary)
    if len(items) > 8:
        lines.append(f'... mais {len(items)-8} resultado(s) não exibidos.')
    return '\n'.join(lines)[:MAX_REPLY]


def format_scoped_reply(result):
    if not isinstance(result, dict):
        return 'Resposta operacional inválida.'
    view = result.get('view')
    if not isinstance(view, dict) or view.get('contract') != 'manager-automation-scoped-reads-v1':
        return 'Resposta operacional inválida.'
    kind = view.get('view')
    configs = {
        'clients': ('Clientes', ('identity_id', 'state', 'owner', 'product_id')),
        'products': ('Produtos', ('product_id', 'name', 'enabled', 'max_sessions')),
        'sessions': ('Sessões', ('identity_id', 'session_id', 'protocol', 'remaining_seconds')),
        'quotas': ('Cotas', ('identity_id', 'product_id', 'used_bytes', 'quota_bytes', 'remaining_bytes')),
    }
    if kind not in configs:
        return 'Resposta operacional inválida.'
    rows = view.get('items')
    page = view.get('page')
    if not isinstance(rows, list) or type(page) is not int or not (0 <= page <= 100000):
        return 'Resposta operacional inválida.'
    title, fields = configs[kind]
    lines = [f'{title} — página {page+1} ({len(rows)} registros).']
    for row in rows[:8]:
        if isinstance(row, dict):
            line = ' | '.join(f'{key}: {concise(row[key])}' for key in fields if key in row)
            if line:
                lines.append('- ' + line)
    if view.get('has_more') is True:
        lines.append(f'Próxima página: /{kind} {page+2}')
    return '\n'.join(lines)[:MAX_REPLY]


def format_reply(command, gateway_result=None):
    if command == 'help':
        return 'Comandos: /describe, /node, /status ID, /clients [PÁGINA], /products [PÁGINA], /sessions [PÁGINA], /quotas [PÁGINA], /nodes, /diagnostics, /revoke ID, /confirm CÓDIGO, /cancel'
    if not isinstance(gateway_result,dict):
        return 'MANAGER indisponível. Tente novamente.'
    code=gateway_result.get('code',70)
    if not gateway_result.get('ok'):
        if code == 75:
            retry=gateway_result.get('retry_after_seconds',1)
            return f'Limite temporário atingido. Tente novamente em {retry}s.'
        if code == 67:
            return 'Ação recusada pela política de acesso.'
        if code == 64:
            return 'Comando ou parâmetros recusados.'
        return 'MANAGER indisponível. Tente novamente.'
    if gateway_result.get('contract') == 'manager-telegram-operations-v1':
        return format_operational_reply(gateway_result)
    if gateway_result.get('action_id') == 'ops.read':
        payload = gateway_result.get('result')
        return format_scoped_reply(payload if isinstance(payload, dict) else None)
    payload={'action_id':gateway_result.get('action_id'),'cached':bool(gateway_result.get('cached',False))}
    if isinstance(gateway_result.get('result'),dict):
        payload['result']=safe_clone(gateway_result['result'])
    text=json.dumps(payload,ensure_ascii=False,sort_keys=True,separators=(',',':'))
    if len(text)>MAX_REPLY:
        text=text[:MAX_REPLY-16]+'...[truncado]'
    return text


def dispatch(uid, update_id, action, params):
    is_read = action.startswith('read:')
    if is_read:
        operation = action[5:]
        if operation not in READ_COMMANDS.values() or params:
            raise RuntimeError('bot-operation-invalid')
        request = {'contract':'manager-telegram-operations-request-v1',
                   'request_id':f'bot-ops-{update_id:020d}', 'operation':operation, 'params':{}}
    else:
        request={'contract':'manager-telegram-gateway-request-v1','request_id':f'bot-{update_id:020d}','action_id':action,'params':params}
    fd,path=tempfile.mkstemp(prefix='.bot-request.',suffix='.json',dir=bot_dir,text=True)
    try:
        os.fchmod(fd,0o600)
        with os.fdopen(fd,'w',encoding='utf-8') as fh:
            json.dump(request,fh,sort_keys=True,separators=(',',':'),ensure_ascii=False); fh.write('\n')
        target = operations_module if is_read else gateway
        if is_read and not (os.path.isfile(target) and os.access(target, os.X_OK)):
            raise RuntimeError('bot-operations-unavailable')
        proc=subprocess.run([target,'--call-bot-user',str(uid),path],stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL,text=True,timeout=280 if is_read else 210,check=False)
        try:
            obj=json.loads(proc.stdout)
        except Exception:
            raise RuntimeError('gateway-response-invalid')
        if not isinstance(obj,dict):
            raise RuntimeError('gateway-response-invalid')
        code=obj.get('code',proc.returncode)
        if isinstance(code,bool) or not isinstance(code,int): code=70
        return code,obj
    finally:
        try: os.unlink(path)
        except FileNotFoundError: pass


def send(chat_id,text):
    api('sendMessage',{'chat_id':str(chat_id),'text':text,'disable_web_page_preview':'true'})

try:
    offset=read_offset()
    result=api('getUpdates',{'offset':str(offset),'timeout':str(timeout),'limit':'20','allowed_updates':json.dumps(['message'],separators=(',',':'))})
    if not isinstance(result,list):
        raise RuntimeError('bot-api-result-invalid')
    processed=0
    for update in result[:20]:
        if not isinstance(update,dict) or isinstance(update.get('update_id'),bool) or not isinstance(update.get('update_id'),int) or update['update_id'] < 0:
            raise RuntimeError('update-invalid')
        update_id=update['update_id']
        if update_id < offset:
            continue
        message=update.get('message')
        if not isinstance(message,dict):
            write_offset(update_id+1); offset=update_id+1; continue
        sender=message.get('from'); chat=message.get('chat')
        if not isinstance(sender,dict) or not isinstance(chat,dict):
            write_offset(update_id+1); offset=update_id+1; continue
        uid=sender.get('id'); chat_id=chat.get('id'); chat_type=chat.get('type')
        if isinstance(uid,bool) or not isinstance(uid,int) or uid<=0 or isinstance(chat_id,bool) or not isinstance(chat_id,int):
            write_offset(update_id+1); offset=update_id+1; continue
        if chat_type != 'private' or chat_id != uid:
            audit('skip-non-private',update_id,uid,decision='skip',code=0)
            write_offset(update_id+1); offset=update_id+1; continue
        command,action,params=command_for(message.get('text',''))
        if command == 'ignore':
            write_offset(update_id+1); offset=update_id+1; continue
        if command == 'help':
            send(chat_id,format_reply('help'))
            audit('reply-help',update_id,uid,command,decision='allow',code=0)
            write_offset(update_id+1); offset=update_id+1; processed+=1; continue
        if command == 'revoke-propose':
            confirmation = write_pending(uid, params['id'])
            send(chat_id, f'REVOGAÇÃO de {params["id"]}. Confirme em até 120 segundos com /confirm {confirmation} ou cancele com /cancel. A confirmação é definitiva.')
            audit('revoke-pending',update_id,uid,command,'connection.revoke',0,decision='pending')
            write_offset(update_id+1); offset=update_id+1; processed+=1; continue
        if command == 'revoke-cancel':
            clear_pending(uid)
            send(chat_id, 'Operação pendente cancelada.')
            audit('revoke-cancel',update_id,uid,command,decision='cancel',code=0)
            write_offset(update_id+1); offset=update_id+1; processed+=1; continue
        if command == 'revoke-confirm':
            target = read_pending(uid,params['code'])
            if target is None:
                send(chat_id,'Confirmação inexistente, inválida ou expirada. Use /revoke ID para iniciar novamente.')
                audit('revoke-confirm-denied',update_id,uid,command,'connection.revoke',67,decision='deny')
                write_offset(update_id+1); offset=update_id+1; processed+=1; continue
            action,params = 'connection.revoke', {'id':target}
        code,obj=dispatch(uid,update_id,action,params)
        if code == 70:
            audit('gateway-temporary-failure',update_id,uid,command,action,code,decision='retry')
            raise RuntimeError('gateway-temporary-failure')
        reply=format_reply(command,obj)
        send(chat_id,reply)
        if command == 'revoke-confirm':
            clear_pending(uid)
        cached=1 if obj.get('cached') or obj.get('authorization_cached') else 0
        audit('gateway-reply',update_id,uid,command,action,code,cached,'allow' if code==0 else 'deny')
        write_offset(update_id+1); offset=update_id+1; processed+=1
    print(f'processed={processed}')
    print(f'offset={offset}')
except RuntimeError as exc:
    # Error labels are fixed and never contain the Bot API URL or token.
    print(str(exc),file=sys.stderr)
    raise SystemExit(70)
except Exception:
    print('telegram-bot-poll-failed',file=sys.stderr)
    raise SystemExit(70)
PY
}

serve_bot() {
  init_state
  while true; do
    if ! poll_once >/dev/null; then
      sleep 3
    fi
  done
}

case "${1:-}" in
  --install|--init) install_bot; exit 0 ;;
  --detach) detach_bot; exit 0 ;;
  --purge) purge_bot; exit 0 ;;
  --status) status; exit $? ;;
  --enable) enable_bot; exit $? ;;
  --disable) disable_bot; exit $? ;;
  --poll-once) poll_once; exit $? ;;
  --serve) serve_bot; exit $? ;;
  *)
    cat >&2 <<'USAGE'
Uso:
  telegram_bot.sh --status
  telegram_bot.sh --enable
  telegram_bot.sh --disable
  telegram_bot.sh --poll-once
USAGE
    exit 64
    ;;
esac