#!/usr/bin/env bash
set -Eeuo pipefail
set -x

source_url="file://${GITHUB_WORKSPACE}"
sudo env MANAGER_ALLOW_FILE_SOURCE=1 MANAGER_REPO_RAW="$source_url" bash install.sh
test "$(sudo cat /opt/manager/VERSION)" = "$(cat VERSION)"
sudo test -x /opt/manager/modules/telegram_bot.sh
sudo manager telegram bot status >/tmp/bot-status
grep -q '^contract=manager-telegram-bot-ingress-v1$' /tmp/bot-status
grep -q '^ingress=telegram-bot-api-long-polling$' /tmp/bot-status
grep -q '^api_base=https://api.telegram.org$' /tmp/bot-status
grep -q '^public_listener=0$' /tmp/bot-status
grep -q '^webhook_listener=0$' /tmp/bot-status
grep -q '^bot_token_argv=0$' /tmp/bot-status
grep -q '^authorization_authority=automation-v2$' /tmp/bot-status
grep -q '^typed_bot_actions=system.describe,node.usage,connection.status
grep -q '^arbitrary_shell=0$' /tmp/bot-status
manager --help | grep -q 'manager telegram bot status|enable|disable|poll-once'
test "$(sudo stat -c '%a' /etc/manager/telegram/bot)" = 700
test "$(sudo stat -c '%a' /etc/manager/telegram/bot/config.conf)" = 600
test "$(sudo stat -c '%a' /var/lib/manager/telegram-bot/offset)" = 600
test "$(sudo stat -c '%a' /var/log/manager/telegram-bot-audit.jsonl)" = 600
sudo test -f /etc/systemd/system/manager-telegram-bot.service
! sudo systemctl is-enabled --quiet manager-telegram-bot.service

sudo manager automation v2 principal create telegram-bot-admin admin '*'
sudo manager automation v2 principal scope telegram-bot-admin '*' '*' 'system.describe,node.usage,connection.status'
sudo manager telegram identity bind 123456789 telegram-bot-admin
sudo /opt/manager/modules/connection_engine.sh --create bot-ops-user '' 0 2 ssh
sudo /opt/manager/modules/products.sh --create bot-ops-plan 'Bot Operations' 1 30 2 ssh 1048576 monthly warn '*' '*' '*'
sudo /opt/manager/modules/products.sh --assign bot-ops-user bot-ops-plan
sudo manager automation v2 principal create telegram-bot-read-user user bot-ops-user
sudo manager automation v2 principal scope telegram-bot-read-user '*' '*' 'node.usage'
sudo manager telegram identity bind 555444333 telegram-bot-read-user
BOT_ID=123456789
TOKEN_SECRET="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef123456"
BOT_TOKEN="${BOT_ID}:${TOKEN_SECRET}"
umask 077
printf '%s\n' "$BOT_TOKEN" >/tmp/telegram-bot-token
sudo manager telegram auth token install /tmp/telegram-bot-token
rm -f /tmp/telegram-bot-token
sudo manager telegram bot status | grep -q '^token_configured=1$'

cat >/tmp/fake-telegram-api.py <<'PY'
import json,os
from http.server import BaseHTTPRequestHandler,HTTPServer
from urllib.parse import parse_qs
TOKEN=os.environ['FAKE_BOT_TOKEN']
UPDATES=[
  {'update_id':100,'message':{'message_id':1,'from':{'id':123456789,'username':'DoNotTrustMe'},'chat':{'id':123456789,'type':'private'},'text':'/describe'}},
  {'update_id':101,'message':{'message_id':2,'from':{'id':123456789},'chat':{'id':123456789,'type':'private'},'text':'/node'}},
  {'update_id':102,'message':{'message_id':3,'from':{'id':123456789},'chat':{'id':123456789,'type':'private'},'text':'/help'}},
  {'update_id':103,'message':{'message_id':4,'from':{'id':123456789},'chat':{'id':123456789,'type':'private'},'text':'/shell id'}},
  {'update_id':104,'message':{'message_id':5,'from':{'id':987654321},'chat':{'id':987654321,'type':'private'},'text':'/describe'}},
  {'update_id':105,'message':{'message_id':6,'from':{'id':123456789},'chat':{'id':123456789,'type':'private'},'text':'/clients'}},
  {'update_id':106,'message':{'message_id':7,'from':{'id':123456789},'chat':{'id':123456789,'type':'private'},'text':'/products'}},
  {'update_id':107,'message':{'message_id':8,'from':{'id':123456789},'chat':{'id':123456789,'type':'private'},'text':'/sessions'}},
  {'update_id':108,'message':{'message_id':9,'from':{'id':123456789},'chat':{'id':123456789,'type':'private'},'text':'/nodes'}},
  {'update_id':109,'message':{'message_id':10,'from':{'id':123456789},'chat':{'id':123456789,'type':'private'},'text':'/diagnostics'}},
  {'update_id':110,'message':{'message_id':11,'from':{'id':123456789},'chat':{'id':123456789,'type':'private'},'text':'/clients extra'}},
  {'update_id':111,'message':{'message_id':12,'from':{'id':555444333},'chat':{'id':555444333,'type':'private'},'text':'/clients'}},
]
FAIL='/tmp/fake-send-fail-once'
open(FAIL,'w').close()
class H(BaseHTTPRequestHandler):
  def log_message(self,*args): pass
  def reply(self,obj,status=200):
    raw=json.dumps(obj,separators=(',',':')).encode()
    self.send_response(status); self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(raw))); self.end_headers(); self.wfile.write(raw)
  def do_POST(self):
    prefix=f'/bot{TOKEN}/'
    if not self.path.startswith(prefix): return self.reply({'ok':False},404)
    method=self.path[len(prefix):]
    size=int(self.headers.get('Content-Length','0')); form=parse_qs(self.rfile.read(size).decode())
    if method=='getUpdates':
      offset=int(form.get('offset',['0'])[0]); result=[u for u in UPDATES if u['update_id']>=offset][:1]
      return self.reply({'ok':True,'result':result})
    if method=='sendMessage':
      row={'chat_id':form.get('chat_id',[''])[0],'text':form.get('text',[''])[0]}
      with open('/tmp/fake-bot-sends.jsonl','a') as f: f.write(json.dumps(row,separators=(',',':'))+'\n')
      if os.path.exists(FAIL):
        os.unlink(FAIL); return self.reply({'ok':False,'description':'simulated delivery failure'})
      return self.reply({'ok':True,'result':{'message_id':999}})
    return self.reply({'ok':False},404)
HTTPServer(('127.0.0.1',18766),H).serve_forever()
PY
FAKE_BOT_TOKEN="$BOT_TOKEN" nohup python3 /tmp/fake-telegram-api.py >/tmp/fake-telegram-api.log 2>&1 &
FAKE_PID=$!
trap 'kill "$FAKE_PID" 2>/dev/null || true' EXIT
for _ in $(seq 1 50); do
  if python3 - <<'PY'
import socket
s=socket.socket(); s.settimeout(.1)
try: s.connect(('127.0.0.1',18766)); ok=True
except OSError: ok=False
finally: s.close()
raise SystemExit(0 if ok else 1)
PY
  then break; fi
  sleep .1
done

set +e
sudo env MANAGER_TELEGRAM_BOT_API_BASE=http://127.0.0.1:18766 manager telegram bot poll-once >/tmp/refused.out 2>/tmp/refused.err
rc=$?
set -e
test "$rc" = 67
grep -q 'telegram-bot-api-base-refused' /tmp/refused.err
! grep -Fq "$TOKEN_SECRET" /tmp/refused.out /tmp/refused.err

set +e
sudo env GITHUB_ACTIONS=true MANAGER_TELEGRAM_ALLOW_TEST_API=1 MANAGER_TELEGRAM_BOT_API_BASE=http://127.0.0.1:18766 manager telegram bot poll-once >/tmp/poll-first.out 2>/tmp/poll-first.err
first_rc=$?
set -e
test "$first_rc" = 70
test "$(sudo cat /var/lib/manager/telegram-bot/offset)" = 0
sudo env GITHUB_ACTIONS=true MANAGER_TELEGRAM_ALLOW_TEST_API=1 MANAGER_TELEGRAM_BOT_API_BASE=http://127.0.0.1:18766 manager telegram bot poll-once >/tmp/poll-retry.out
test "$(sudo cat /var/lib/manager/telegram-bot/offset)" = 101
grep -q '^processed=1$' /tmp/poll-retry.out
sudo cat /var/log/manager/telegram-gateway-audit.jsonl >/tmp/gateway-audit.jsonl
sudo cat /var/log/manager/telegram-bot-audit.jsonl >/tmp/bot-audit.jsonl
python3 - <<'PY'
import json
rows=[json.loads(x) for x in open('/tmp/gateway-audit.jsonl') if 'bot-00000000000000000100' in x]
assert len(rows)>=2
assert any(r.get('cached')==0 for r in rows)
assert any(r.get('cached')==1 for r in rows)
bot=[json.loads(x) for x in open('/tmp/bot-audit.jsonl')]
assert any(r.get('update_id')==100 and r.get('cached')==1 and r.get('action_id')=='system.describe' for r in bot)
PY

sudo env GITHUB_ACTIONS=true MANAGER_TELEGRAM_ALLOW_TEST_API=1 MANAGER_TELEGRAM_BOT_API_BASE=http://127.0.0.1:18766 manager telegram bot poll-once >/tmp/poll-node.out
test "$(sudo cat /var/lib/manager/telegram-bot/offset)" = 102
sudo cat /var/log/manager/telegram-bot-audit.jsonl >/tmp/bot-audit.jsonl
python3 - <<'PY'
import json
rows=[json.loads(x) for x in open('/tmp/bot-audit.jsonl')]
r=[x for x in rows if x.get('update_id')==101][-1]
assert r['telegram_user_id']=='123456789'
assert r['command_id']=='node'
assert r['action_id']=='node.usage'
assert r['decision']=='allow' and r['code']==0
PY
grep -q 'node.usage' /tmp/fake-bot-sends.jsonl

before="$(sudo grep -c 'gateway-call' /var/log/manager/telegram-gateway-audit.jsonl || true)"
sudo env GITHUB_ACTIONS=true MANAGER_TELEGRAM_ALLOW_TEST_API=1 MANAGER_TELEGRAM_BOT_API_BASE=http://127.0.0.1:18766 manager telegram bot poll-once >/dev/null
test "$(sudo cat /var/lib/manager/telegram-bot/offset)" = 103
sudo env GITHUB_ACTIONS=true MANAGER_TELEGRAM_ALLOW_TEST_API=1 MANAGER_TELEGRAM_BOT_API_BASE=http://127.0.0.1:18766 manager telegram bot poll-once >/dev/null
test "$(sudo cat /var/lib/manager/telegram-bot/offset)" = 104
after="$(sudo grep -c 'gateway-call' /var/log/manager/telegram-gateway-audit.jsonl || true)"
test "$before" = "$after"
! sudo grep -Fq 'shell.exec' /var/log/manager/telegram-gateway-audit.jsonl
! sudo grep -Fq '/shell id' /var/log/manager/telegram-bot-audit.jsonl
grep -q 'Comandos: /describe, /node, /status ID' /tmp/fake-bot-sends.jsonl

sudo env GITHUB_ACTIONS=true MANAGER_TELEGRAM_ALLOW_TEST_API=1 MANAGER_TELEGRAM_BOT_API_BASE=http://127.0.0.1:18766 manager telegram bot poll-once >/dev/null
test "$(sudo cat /var/lib/manager/telegram-bot/offset)" = 105
sudo cat /var/log/manager/telegram-bot-audit.jsonl >/tmp/bot-audit.jsonl
python3 - <<'PY'
import json
rows=[json.loads(x) for x in open('/tmp/bot-audit.jsonl')]
r=[x for x in rows if x.get('update_id')==104][-1]
assert r['telegram_user_id']=='987654321'
assert r['decision']=='deny'
assert r['code'] != 0
PY

# All operational reads reuse the admin-only Telegram operations gateway.
for next_offset in 106 107 108 109 110; do
  sudo env GITHUB_ACTIONS=true MANAGER_TELEGRAM_ALLOW_TEST_API=1 MANAGER_TELEGRAM_BOT_API_BASE=http://127.0.0.1:18766 manager telegram bot poll-once >/dev/null
  test "$(sudo cat /var/lib/manager/telegram-bot/offset)" = "$next_offset"
done
sudo cat /var/log/manager/telegram-bot-audit.jsonl >/tmp/bot-audit.jsonl
python3 - <<'PY'
import json
rows=[json.loads(x) for x in open('/tmp/bot-audit.jsonl')]
names={105:'identities',106:'products',107:'sessions',108:'nodes',109:'diagnostics'}
for update_id, op in names.items():
    matches=[x for x in rows if x.get('update_id')==update_id]
    assert matches, (update_id, op)
    entry=matches[-1]
    assert entry['action_id']=='read:'+op and entry['decision']=='allow' and entry['code']==0, entry
sends=[json.loads(line)['text'] for line in open('/tmp/fake-bot-sends.jsonl')]
for title in ('Clientes', 'Produtos', 'Sessões', 'Nós', 'Diagnóstico do nó'):
    assert any(title in sent for sent in sends), title
assert any('bot-ops-user' in sent for sent in sends)
assert any('bot-ops-plan' in sent for sent in sends)
assert not any('private_key' in sent or 'bot_token' in sent for sent in sends)
PY

# Extra parameters are never dispatched; non-admin cannot read global collections.
before="$(sudo grep -c 'gateway-call' /var/log/manager/telegram-gateway-audit.jsonl || true)"
sudo env GITHUB_ACTIONS=true MANAGER_TELEGRAM_ALLOW_TEST_API=1 MANAGER_TELEGRAM_BOT_API_BASE=http://127.0.0.1:18766 manager telegram bot poll-once >/dev/null
test "$(sudo cat /var/lib/manager/telegram-bot/offset)" = 111
after="$(sudo grep -c 'gateway-call' /var/log/manager/telegram-gateway-audit.jsonl || true)"
test "$before" = "$after"
sudo env GITHUB_ACTIONS=true MANAGER_TELEGRAM_ALLOW_TEST_API=1 MANAGER_TELEGRAM_BOT_API_BASE=http://127.0.0.1:18766 manager telegram bot poll-once >/dev/null
test "$(sudo cat /var/lib/manager/telegram-bot/offset)" = 112
sudo cat /var/log/manager/telegram-bot-audit.jsonl >/tmp/bot-audit.jsonl
python3 - <<'PY'
import json
rows=[json.loads(x) for x in open('/tmp/bot-audit.jsonl')]
r=[x for x in rows if x.get('update_id')==111][-1]
assert r['telegram_user_id']=='555444333'
assert r['action_id']=='read:identities' and r['decision']=='deny' and r['code']==67
sends=[json.loads(x)['text'] for x in open('/tmp/fake-bot-sends.jsonl')]
assert any('Ação recusada pela política' in x for x in sends)
PY

before_offset="$(sudo cat /var/lib/manager/telegram-bot/offset)"
sudo env MANAGER_ALLOW_FILE_SOURCE=1 MANAGER_REPO_RAW="$source_url" bash install.sh
test "$(sudo cat /var/lib/manager/telegram-bot/offset)" = "$before_offset"
test "$(sudo stat -c '%a' /var/lib/manager/telegram-bot/offset)" = 600
sudo /opt/manager/modules/telegram_bot.sh --detach
sudo test ! -e /etc/systemd/system/manager-telegram-bot.service
test "$(sudo cat /var/lib/manager/telegram-bot/offset)" = "$before_offset"
sudo /opt/manager/modules/telegram_bot.sh --install
sudo test -f /etc/systemd/system/manager-telegram-bot.service
! sudo systemctl is-enabled --quiet manager-telegram-bot.service

! sudo grep -Fq "$TOKEN_SECRET" /var/log/manager/telegram-bot-audit.jsonl
! sudo grep -Fq 'DoNotTrustMe' /var/log/manager/telegram-bot-audit.jsonl
! sudo grep -Eqi 'bot_token|private_key|signature|hash|nonce|query_id|username|first_name|init[_-]?data' /var/log/manager/telegram-bot-audit.jsonl
! grep -Fq "$TOKEN_SECRET" /tmp/poll-first.out /tmp/poll-first.err /tmp/poll-retry.out /tmp/poll-node.out
grep -q '^## Ingresso do Telegram Bot por long polling$' docs/TELEGRAM.md
grep -q 'manager-telegram-bot-ingress-v1' docs/ROADMAP.md
grep -q 'sem listener público' docs/ROADMAP.md
grep -q 'long polling' docs/TELEGRAM.md
test "$(cat VERSION)" = 0.8.10
bash -n modules/telegram_bot.sh
bash -n modules/telegram_gateway.sh
git diff --exit-code
 /tmp/bot-status
grep -q '^read_only_bot_operations=identities,products,sessions,nodes,diagnostics
grep -q '^arbitrary_shell=0$' /tmp/bot-status
manager --help | grep -q 'manager telegram bot status|enable|disable|poll-once'
test "$(sudo stat -c '%a' /etc/manager/telegram/bot)" = 700
test "$(sudo stat -c '%a' /etc/manager/telegram/bot/config.conf)" = 600
test "$(sudo stat -c '%a' /var/lib/manager/telegram-bot/offset)" = 600
test "$(sudo stat -c '%a' /var/log/manager/telegram-bot-audit.jsonl)" = 600
sudo test -f /etc/systemd/system/manager-telegram-bot.service
! sudo systemctl is-enabled --quiet manager-telegram-bot.service

sudo manager automation v2 principal create telegram-bot-admin admin '*'
sudo manager automation v2 principal scope telegram-bot-admin '*' '*' 'system.describe,node.usage,connection.status'
sudo manager telegram identity bind 123456789 telegram-bot-admin
BOT_ID=123456789
TOKEN_SECRET="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef123456"
BOT_TOKEN="${BOT_ID}:${TOKEN_SECRET}"
umask 077
printf '%s\n' "$BOT_TOKEN" >/tmp/telegram-bot-token
sudo manager telegram auth token install /tmp/telegram-bot-token
rm -f /tmp/telegram-bot-token
sudo manager telegram bot status | grep -q '^token_configured=1$'

cat >/tmp/fake-telegram-api.py <<'PY'
import json,os
from http.server import BaseHTTPRequestHandler,HTTPServer
from urllib.parse import parse_qs
TOKEN=os.environ['FAKE_BOT_TOKEN']
UPDATES=[
  {'update_id':100,'message':{'message_id':1,'from':{'id':123456789,'username':'DoNotTrustMe'},'chat':{'id':123456789,'type':'private'},'text':'/describe'}},
  {'update_id':101,'message':{'message_id':2,'from':{'id':123456789},'chat':{'id':123456789,'type':'private'},'text':'/node'}},
  {'update_id':102,'message':{'message_id':3,'from':{'id':123456789},'chat':{'id':123456789,'type':'private'},'text':'/help'}},
  {'update_id':103,'message':{'message_id':4,'from':{'id':123456789},'chat':{'id':123456789,'type':'private'},'text':'/shell id'}},
  {'update_id':104,'message':{'message_id':5,'from':{'id':987654321},'chat':{'id':987654321,'type':'private'},'text':'/describe'}},
]
FAIL='/tmp/fake-send-fail-once'
open(FAIL,'w').close()
class H(BaseHTTPRequestHandler):
  def log_message(self,*args): pass
  def reply(self,obj,status=200):
    raw=json.dumps(obj,separators=(',',':')).encode()
    self.send_response(status); self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(raw))); self.end_headers(); self.wfile.write(raw)
  def do_POST(self):
    prefix=f'/bot{TOKEN}/'
    if not self.path.startswith(prefix): return self.reply({'ok':False},404)
    method=self.path[len(prefix):]
    size=int(self.headers.get('Content-Length','0')); form=parse_qs(self.rfile.read(size).decode())
    if method=='getUpdates':
      offset=int(form.get('offset',['0'])[0]); result=[u for u in UPDATES if u['update_id']>=offset][:1]
      return self.reply({'ok':True,'result':result})
    if method=='sendMessage':
      row={'chat_id':form.get('chat_id',[''])[0],'text':form.get('text',[''])[0]}
      with open('/tmp/fake-bot-sends.jsonl','a') as f: f.write(json.dumps(row,separators=(',',':'))+'\n')
      if os.path.exists(FAIL):
        os.unlink(FAIL); return self.reply({'ok':False,'description':'simulated delivery failure'})
      return self.reply({'ok':True,'result':{'message_id':999}})
    return self.reply({'ok':False},404)
HTTPServer(('127.0.0.1',18766),H).serve_forever()
PY
FAKE_BOT_TOKEN="$BOT_TOKEN" nohup python3 /tmp/fake-telegram-api.py >/tmp/fake-telegram-api.log 2>&1 &
FAKE_PID=$!
trap 'kill "$FAKE_PID" 2>/dev/null || true' EXIT
for _ in $(seq 1 50); do
  if python3 - <<'PY'
import socket
s=socket.socket(); s.settimeout(.1)
try: s.connect(('127.0.0.1',18766)); ok=True
except OSError: ok=False
finally: s.close()
raise SystemExit(0 if ok else 1)
PY
  then break; fi
  sleep .1
done

set +e
sudo env MANAGER_TELEGRAM_BOT_API_BASE=http://127.0.0.1:18766 manager telegram bot poll-once >/tmp/refused.out 2>/tmp/refused.err
rc=$?
set -e
test "$rc" = 67
grep -q 'telegram-bot-api-base-refused' /tmp/refused.err
! grep -Fq "$TOKEN_SECRET" /tmp/refused.out /tmp/refused.err

set +e
sudo env GITHUB_ACTIONS=true MANAGER_TELEGRAM_ALLOW_TEST_API=1 MANAGER_TELEGRAM_BOT_API_BASE=http://127.0.0.1:18766 manager telegram bot poll-once >/tmp/poll-first.out 2>/tmp/poll-first.err
first_rc=$?
set -e
test "$first_rc" = 70
test "$(sudo cat /var/lib/manager/telegram-bot/offset)" = 0
sudo env GITHUB_ACTIONS=true MANAGER_TELEGRAM_ALLOW_TEST_API=1 MANAGER_TELEGRAM_BOT_API_BASE=http://127.0.0.1:18766 manager telegram bot poll-once >/tmp/poll-retry.out
test "$(sudo cat /var/lib/manager/telegram-bot/offset)" = 101
grep -q '^processed=1$' /tmp/poll-retry.out
sudo cat /var/log/manager/telegram-gateway-audit.jsonl >/tmp/gateway-audit.jsonl
sudo cat /var/log/manager/telegram-bot-audit.jsonl >/tmp/bot-audit.jsonl
python3 - <<'PY'
import json
rows=[json.loads(x) for x in open('/tmp/gateway-audit.jsonl') if 'bot-00000000000000000100' in x]
assert len(rows)>=2
assert any(r.get('cached')==0 for r in rows)
assert any(r.get('cached')==1 for r in rows)
bot=[json.loads(x) for x in open('/tmp/bot-audit.jsonl')]
assert any(r.get('update_id')==100 and r.get('cached')==1 and r.get('action_id')=='system.describe' for r in bot)
PY

sudo env GITHUB_ACTIONS=true MANAGER_TELEGRAM_ALLOW_TEST_API=1 MANAGER_TELEGRAM_BOT_API_BASE=http://127.0.0.1:18766 manager telegram bot poll-once >/tmp/poll-node.out
test "$(sudo cat /var/lib/manager/telegram-bot/offset)" = 102
sudo cat /var/log/manager/telegram-bot-audit.jsonl >/tmp/bot-audit.jsonl
python3 - <<'PY'
import json
rows=[json.loads(x) for x in open('/tmp/bot-audit.jsonl')]
r=[x for x in rows if x.get('update_id')==101][-1]
assert r['telegram_user_id']=='123456789'
assert r['command_id']=='node'
assert r['action_id']=='node.usage'
assert r['decision']=='allow' and r['code']==0
PY
grep -q 'node.usage' /tmp/fake-bot-sends.jsonl

before="$(sudo grep -c 'gateway-call' /var/log/manager/telegram-gateway-audit.jsonl || true)"
sudo env GITHUB_ACTIONS=true MANAGER_TELEGRAM_ALLOW_TEST_API=1 MANAGER_TELEGRAM_BOT_API_BASE=http://127.0.0.1:18766 manager telegram bot poll-once >/dev/null
test "$(sudo cat /var/lib/manager/telegram-bot/offset)" = 103
sudo env GITHUB_ACTIONS=true MANAGER_TELEGRAM_ALLOW_TEST_API=1 MANAGER_TELEGRAM_BOT_API_BASE=http://127.0.0.1:18766 manager telegram bot poll-once >/dev/null
test "$(sudo cat /var/lib/manager/telegram-bot/offset)" = 104
after="$(sudo grep -c 'gateway-call' /var/log/manager/telegram-gateway-audit.jsonl || true)"
test "$before" = "$after"
! sudo grep -Fq 'shell.exec' /var/log/manager/telegram-gateway-audit.jsonl
! sudo grep -Fq '/shell id' /var/log/manager/telegram-bot-audit.jsonl
grep -q 'Comandos: /describe, /node, /status ID' /tmp/fake-bot-sends.jsonl

sudo env GITHUB_ACTIONS=true MANAGER_TELEGRAM_ALLOW_TEST_API=1 MANAGER_TELEGRAM_BOT_API_BASE=http://127.0.0.1:18766 manager telegram bot poll-once >/dev/null
test "$(sudo cat /var/lib/manager/telegram-bot/offset)" = 105
sudo cat /var/log/manager/telegram-bot-audit.jsonl >/tmp/bot-audit.jsonl
python3 - <<'PY'
import json
rows=[json.loads(x) for x in open('/tmp/bot-audit.jsonl')]
r=[x for x in rows if x.get('update_id')==104][-1]
assert r['telegram_user_id']=='987654321'
assert r['decision']=='deny'
assert r['code'] != 0
PY

before_offset="$(sudo cat /var/lib/manager/telegram-bot/offset)"
sudo env MANAGER_ALLOW_FILE_SOURCE=1 MANAGER_REPO_RAW="$source_url" bash install.sh
test "$(sudo cat /var/lib/manager/telegram-bot/offset)" = "$before_offset"
test "$(sudo stat -c '%a' /var/lib/manager/telegram-bot/offset)" = 600
sudo /opt/manager/modules/telegram_bot.sh --detach
sudo test ! -e /etc/systemd/system/manager-telegram-bot.service
test "$(sudo cat /var/lib/manager/telegram-bot/offset)" = "$before_offset"
sudo /opt/manager/modules/telegram_bot.sh --install
sudo test -f /etc/systemd/system/manager-telegram-bot.service
! sudo systemctl is-enabled --quiet manager-telegram-bot.service

! sudo grep -Fq "$TOKEN_SECRET" /var/log/manager/telegram-bot-audit.jsonl
! sudo grep -Fq 'DoNotTrustMe' /var/log/manager/telegram-bot-audit.jsonl
! sudo grep -Eqi 'bot_token|private_key|signature|hash|nonce|query_id|username|first_name|init[_-]?data' /var/log/manager/telegram-bot-audit.jsonl
! grep -Fq "$TOKEN_SECRET" /tmp/poll-first.out /tmp/poll-first.err /tmp/poll-retry.out /tmp/poll-node.out
grep -q '^## Ingresso do Telegram Bot por long polling$' docs/TELEGRAM.md
grep -q 'manager-telegram-bot-ingress-v1' docs/ROADMAP.md
grep -q 'sem listener público' docs/ROADMAP.md
grep -q 'long polling' docs/TELEGRAM.md
test "$(cat VERSION)" = 0.8.10
bash -n modules/telegram_bot.sh
bash -n modules/telegram_gateway.sh
git diff --exit-code
 /tmp/bot-status
grep -q '^arbitrary_shell=0$' /tmp/bot-status
manager --help | grep -q 'manager telegram bot status|enable|disable|poll-once'
test "$(sudo stat -c '%a' /etc/manager/telegram/bot)" = 700
test "$(sudo stat -c '%a' /etc/manager/telegram/bot/config.conf)" = 600
test "$(sudo stat -c '%a' /var/lib/manager/telegram-bot/offset)" = 600
test "$(sudo stat -c '%a' /var/log/manager/telegram-bot-audit.jsonl)" = 600
sudo test -f /etc/systemd/system/manager-telegram-bot.service
! sudo systemctl is-enabled --quiet manager-telegram-bot.service

sudo manager automation v2 principal create telegram-bot-admin admin '*'
sudo manager automation v2 principal scope telegram-bot-admin '*' '*' 'system.describe,node.usage,connection.status'
sudo manager telegram identity bind 123456789 telegram-bot-admin
BOT_ID=123456789
TOKEN_SECRET="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef123456"
BOT_TOKEN="${BOT_ID}:${TOKEN_SECRET}"
umask 077
printf '%s\n' "$BOT_TOKEN" >/tmp/telegram-bot-token
sudo manager telegram auth token install /tmp/telegram-bot-token
rm -f /tmp/telegram-bot-token
sudo manager telegram bot status | grep -q '^token_configured=1$'

cat >/tmp/fake-telegram-api.py <<'PY'
import json,os
from http.server import BaseHTTPRequestHandler,HTTPServer
from urllib.parse import parse_qs
TOKEN=os.environ['FAKE_BOT_TOKEN']
UPDATES=[
  {'update_id':100,'message':{'message_id':1,'from':{'id':123456789,'username':'DoNotTrustMe'},'chat':{'id':123456789,'type':'private'},'text':'/describe'}},
  {'update_id':101,'message':{'message_id':2,'from':{'id':123456789},'chat':{'id':123456789,'type':'private'},'text':'/node'}},
  {'update_id':102,'message':{'message_id':3,'from':{'id':123456789},'chat':{'id':123456789,'type':'private'},'text':'/help'}},
  {'update_id':103,'message':{'message_id':4,'from':{'id':123456789},'chat':{'id':123456789,'type':'private'},'text':'/shell id'}},
  {'update_id':104,'message':{'message_id':5,'from':{'id':987654321},'chat':{'id':987654321,'type':'private'},'text':'/describe'}},
]
FAIL='/tmp/fake-send-fail-once'
open(FAIL,'w').close()
class H(BaseHTTPRequestHandler):
  def log_message(self,*args): pass
  def reply(self,obj,status=200):
    raw=json.dumps(obj,separators=(',',':')).encode()
    self.send_response(status); self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(raw))); self.end_headers(); self.wfile.write(raw)
  def do_POST(self):
    prefix=f'/bot{TOKEN}/'
    if not self.path.startswith(prefix): return self.reply({'ok':False},404)
    method=self.path[len(prefix):]
    size=int(self.headers.get('Content-Length','0')); form=parse_qs(self.rfile.read(size).decode())
    if method=='getUpdates':
      offset=int(form.get('offset',['0'])[0]); result=[u for u in UPDATES if u['update_id']>=offset][:1]
      return self.reply({'ok':True,'result':result})
    if method=='sendMessage':
      row={'chat_id':form.get('chat_id',[''])[0],'text':form.get('text',[''])[0]}
      with open('/tmp/fake-bot-sends.jsonl','a') as f: f.write(json.dumps(row,separators=(',',':'))+'\n')
      if os.path.exists(FAIL):
        os.unlink(FAIL); return self.reply({'ok':False,'description':'simulated delivery failure'})
      return self.reply({'ok':True,'result':{'message_id':999}})
    return self.reply({'ok':False},404)
HTTPServer(('127.0.0.1',18766),H).serve_forever()
PY
FAKE_BOT_TOKEN="$BOT_TOKEN" nohup python3 /tmp/fake-telegram-api.py >/tmp/fake-telegram-api.log 2>&1 &
FAKE_PID=$!
trap 'kill "$FAKE_PID" 2>/dev/null || true' EXIT
for _ in $(seq 1 50); do
  if python3 - <<'PY'
import socket
s=socket.socket(); s.settimeout(.1)
try: s.connect(('127.0.0.1',18766)); ok=True
except OSError: ok=False
finally: s.close()
raise SystemExit(0 if ok else 1)
PY
  then break; fi
  sleep .1
done

set +e
sudo env MANAGER_TELEGRAM_BOT_API_BASE=http://127.0.0.1:18766 manager telegram bot poll-once >/tmp/refused.out 2>/tmp/refused.err
rc=$?
set -e
test "$rc" = 67
grep -q 'telegram-bot-api-base-refused' /tmp/refused.err
! grep -Fq "$TOKEN_SECRET" /tmp/refused.out /tmp/refused.err

set +e
sudo env GITHUB_ACTIONS=true MANAGER_TELEGRAM_ALLOW_TEST_API=1 MANAGER_TELEGRAM_BOT_API_BASE=http://127.0.0.1:18766 manager telegram bot poll-once >/tmp/poll-first.out 2>/tmp/poll-first.err
first_rc=$?
set -e
test "$first_rc" = 70
test "$(sudo cat /var/lib/manager/telegram-bot/offset)" = 0
sudo env GITHUB_ACTIONS=true MANAGER_TELEGRAM_ALLOW_TEST_API=1 MANAGER_TELEGRAM_BOT_API_BASE=http://127.0.0.1:18766 manager telegram bot poll-once >/tmp/poll-retry.out
test "$(sudo cat /var/lib/manager/telegram-bot/offset)" = 101
grep -q '^processed=1$' /tmp/poll-retry.out
sudo cat /var/log/manager/telegram-gateway-audit.jsonl >/tmp/gateway-audit.jsonl
sudo cat /var/log/manager/telegram-bot-audit.jsonl >/tmp/bot-audit.jsonl
python3 - <<'PY'
import json
rows=[json.loads(x) for x in open('/tmp/gateway-audit.jsonl') if 'bot-00000000000000000100' in x]
assert len(rows)>=2
assert any(r.get('cached')==0 for r in rows)
assert any(r.get('cached')==1 for r in rows)
bot=[json.loads(x) for x in open('/tmp/bot-audit.jsonl')]
assert any(r.get('update_id')==100 and r.get('cached')==1 and r.get('action_id')=='system.describe' for r in bot)
PY

sudo env GITHUB_ACTIONS=true MANAGER_TELEGRAM_ALLOW_TEST_API=1 MANAGER_TELEGRAM_BOT_API_BASE=http://127.0.0.1:18766 manager telegram bot poll-once >/tmp/poll-node.out
test "$(sudo cat /var/lib/manager/telegram-bot/offset)" = 102
sudo cat /var/log/manager/telegram-bot-audit.jsonl >/tmp/bot-audit.jsonl
python3 - <<'PY'
import json
rows=[json.loads(x) for x in open('/tmp/bot-audit.jsonl')]
r=[x for x in rows if x.get('update_id')==101][-1]
assert r['telegram_user_id']=='123456789'
assert r['command_id']=='node'
assert r['action_id']=='node.usage'
assert r['decision']=='allow' and r['code']==0
PY
grep -q 'node.usage' /tmp/fake-bot-sends.jsonl

before="$(sudo grep -c 'gateway-call' /var/log/manager/telegram-gateway-audit.jsonl || true)"
sudo env GITHUB_ACTIONS=true MANAGER_TELEGRAM_ALLOW_TEST_API=1 MANAGER_TELEGRAM_BOT_API_BASE=http://127.0.0.1:18766 manager telegram bot poll-once >/dev/null
test "$(sudo cat /var/lib/manager/telegram-bot/offset)" = 103
sudo env GITHUB_ACTIONS=true MANAGER_TELEGRAM_ALLOW_TEST_API=1 MANAGER_TELEGRAM_BOT_API_BASE=http://127.0.0.1:18766 manager telegram bot poll-once >/dev/null
test "$(sudo cat /var/lib/manager/telegram-bot/offset)" = 104
after="$(sudo grep -c 'gateway-call' /var/log/manager/telegram-gateway-audit.jsonl || true)"
test "$before" = "$after"
! sudo grep -Fq 'shell.exec' /var/log/manager/telegram-gateway-audit.jsonl
! sudo grep -Fq '/shell id' /var/log/manager/telegram-bot-audit.jsonl
grep -q 'Comandos: /describe, /node, /status ID' /tmp/fake-bot-sends.jsonl

sudo env GITHUB_ACTIONS=true MANAGER_TELEGRAM_ALLOW_TEST_API=1 MANAGER_TELEGRAM_BOT_API_BASE=http://127.0.0.1:18766 manager telegram bot poll-once >/dev/null
test "$(sudo cat /var/lib/manager/telegram-bot/offset)" = 105
sudo cat /var/log/manager/telegram-bot-audit.jsonl >/tmp/bot-audit.jsonl
python3 - <<'PY'
import json
rows=[json.loads(x) for x in open('/tmp/bot-audit.jsonl')]
r=[x for x in rows if x.get('update_id')==104][-1]
assert r['telegram_user_id']=='987654321'
assert r['decision']=='deny'
assert r['code'] != 0
PY

before_offset="$(sudo cat /var/lib/manager/telegram-bot/offset)"
sudo env MANAGER_ALLOW_FILE_SOURCE=1 MANAGER_REPO_RAW="$source_url" bash install.sh
test "$(sudo cat /var/lib/manager/telegram-bot/offset)" = "$before_offset"
test "$(sudo stat -c '%a' /var/lib/manager/telegram-bot/offset)" = 600
sudo /opt/manager/modules/telegram_bot.sh --detach
sudo test ! -e /etc/systemd/system/manager-telegram-bot.service
test "$(sudo cat /var/lib/manager/telegram-bot/offset)" = "$before_offset"
sudo /opt/manager/modules/telegram_bot.sh --install
sudo test -f /etc/systemd/system/manager-telegram-bot.service
! sudo systemctl is-enabled --quiet manager-telegram-bot.service

! sudo grep -Fq "$TOKEN_SECRET" /var/log/manager/telegram-bot-audit.jsonl
! sudo grep -Fq 'DoNotTrustMe' /var/log/manager/telegram-bot-audit.jsonl
! sudo grep -Eqi 'bot_token|private_key|signature|hash|nonce|query_id|username|first_name|init[_-]?data' /var/log/manager/telegram-bot-audit.jsonl
! grep -Fq "$TOKEN_SECRET" /tmp/poll-first.out /tmp/poll-first.err /tmp/poll-retry.out /tmp/poll-node.out
grep -q '^## Ingresso do Telegram Bot por long polling$' docs/TELEGRAM.md
grep -q 'manager-telegram-bot-ingress-v1' docs/ROADMAP.md
grep -q 'sem listener público' docs/ROADMAP.md
grep -q 'long polling' docs/TELEGRAM.md
test "$(cat VERSION)" = 0.8.10
bash -n modules/telegram_bot.sh
bash -n modules/telegram_gateway.sh
git diff --exit-code
