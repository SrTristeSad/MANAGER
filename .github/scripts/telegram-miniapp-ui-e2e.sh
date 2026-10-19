#!/usr/bin/env bash
set -Eeuo pipefail

source_url="file://${GITHUB_WORKSPACE}"
sudo env MANAGER_ALLOW_FILE_SOURCE=1 MANAGER_REPO_RAW="$source_url" bash install.sh
sudo test -f /opt/manager/web/telegram/index.html
sudo test -f /opt/manager/web/telegram/app.css
sudo test -f /opt/manager/web/telegram/app.js
sudo test -f /opt/manager/modules/telegram_miniapp_server.py
sudo test -x /opt/manager/modules/telegram_miniapp.sh
sudo manager telegram miniapp status | grep -q '^enabled=0$'
sudo manager telegram miniapp status | grep -q '^bind_address=127.0.0.1$'
if sudo manager telegram miniapp configure http://invalid.example; then
  echo "Mini App must require HTTPS" >&2; exit 1
fi
sudo manager telegram miniapp configure https://mini.example.invalid 18769
sudo manager telegram miniapp status | grep -q '^origin=https://mini.example.invalid$'

sudo /opt/manager/modules/resellers.sh --create-reseller resellerA reseller '' 10 1
sudo /opt/manager/modules/resellers.sh --create-reseller resellerB reseller '' 10 1
sudo manager automation v2 principal create app-admin admin '*'
sudo manager automation v2 principal scope app-admin '*' '*' ops.read
sudo manager telegram identity bind 123456789 app-admin
sudo manager automation v2 principal create app-reseller reseller resellerA PLAN_A
sudo manager automation v2 principal scope app-reseller '*' '*' ops.read
sudo manager telegram identity bind 223456789 app-reseller
sudo manager automation v2 principal create app-denied admin '*'
sudo manager automation v2 principal scope app-denied '*' '*' system.describe
sudo manager telegram identity bind 323456789 app-denied

sudo python3 - <<'PY'
import os
from pathlib import Path
root=Path('/etc/manager/connection')
def save(rel, data):
    path=root/rel
    path.parent.mkdir(parents=True, mode=0o700, exist_ok=True)
    with open(path,'x') as f: f.write(data)
    os.chmod(path,0o600)
for plan in ('PLAN_A','PLAN_B'):
    save(f'products/catalog/{plan}.conf',f'id={plan}\nname=Plano {plan}\nenabled=1\nmax_sessions=2\n')
for ident,owner,plan in (('clientA','resellerA','PLAN_A'),('clientB','resellerB','PLAN_A'),('clientC','resellerA','PLAN_B')):
    save(f'identities/{ident}.conf',f'id={ident}\nowner={owner}\nenabled=1\nmax_sessions=2\nprotocols=ssh\n')
    save(f'products/assignments/{ident}.conf',f'identity_id={ident}\nproduct_id={plan}\n')
    save(f'product-usage/identities/{ident}.state',f'identity_id={ident}\nproduct_id={plan}\nquota_bytes=1048576\nused_bytes=10000\n')
PY

umask 077
printf '%s\n' '123456789:ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef123456' >/tmp/miniapp-bot-token
sudo manager telegram auth token install /tmp/miniapp-bot-token
rm -f /tmp/miniapp-bot-token
sudo manager telegram miniapp enable
sudo manager telegram miniapp status | grep -q '^enabled=1$'
sudo manager telegram miniapp status | grep -q '^active=1$'

python3 - <<'PY'
import hashlib
import hmac
import http.client
import json
import time
import urllib.parse

TOKEN="123456789:ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef123456"
HOST="mini.example.invalid"
ORIGIN="https://"+HOST

def init_data(uid):
    data={'auth_date':str(int(time.time())),
          'user':json.dumps({'id':uid,'first_name':'Test Runner'},separators=(',',':'))}
    check='\n'.join(f'{k}={data[k]}' for k in sorted(data))
    key=hmac.new(b'WebAppData',TOKEN.encode(),hashlib.sha256).digest()
    data['hash']=hmac.new(key,check.encode(),hashlib.sha256).hexdigest()
    return urllib.parse.urlencode(data,quote_via=urllib.parse.quote)

def call(path='/', obj=None, *, origin=ORIGIN, host=HOST, method=None, content_type='application/json'):
    connection=http.client.HTTPConnection('127.0.0.1',18769,timeout=30)
    verb=method or ('GET' if obj is None else 'POST')
    body=b'' if obj is None else json.dumps(obj).encode()
    headers={'Host':host}
    if verb=='POST':
        headers.update({'Origin':origin, 'Content-Type':content_type})
    connection.request(verb,path,body=body,headers=headers)
    response=connection.getresponse()
    raw=response.read()
    meta={'status':response.status,'headers':dict(response.getheaders()),'body':raw}
    connection.close()
    return meta

def scoped(uid,view='clients',page=0,limit=8, init=None):
    response=call('/api/read',{'init_data':init if init is not None else init_data(uid),
                               'view':view,'page':page,'limit':limit})
    try: parsed=json.loads(response['body'])
    except ValueError: raise AssertionError('Not JSON')
    return response['status'],parsed

for path,mime in (('/','text/html'),('/app.css','text/css'),('/app.js','application/javascript')):
    result=call(path)
    assert result['status']==200
    assert mime in result['headers']['Content-Type']
    assert result['headers']['Cache-Control'].startswith('no-store')
    assert b'initDataUnsafe' not in result['body']
    assert result['body']
assert b'/app.js' in call('/')['body']
assert call('/api/anything')['status']==404
assert call('/api/read',{'init_data':'x','view':'clients','page':0,'limit':8},origin='https://evil.test')['status']==403
assert call('/api/read',{'init_data':'x','view':'clients','page':0,'limit':8},host='evil.test')['status']==403
assert call('/api/read',{'init_data':'x','view':'clients','page':0,'limit':8},content_type='text/plain')['status']==415
assert call('/some-hidden-file')['status']==404

status,full=scoped(123456789)
assert status==200 and full['ok'] is True, full
ids={x['identity_id'] for x in full['data']['items']}
assert ids=={'clientA','clientB','clientC'},ids
for kind in ('sessions','products','quotas'):
    status,payload=scoped(123456789,kind)
    assert status==200 and payload['ok'] is True, (kind,payload)
status,reseller=scoped(223456789)
assert status==200 and {x['identity_id'] for x in reseller['data']['items']}=={'clientA'},reseller
status,plans=scoped(223456789,'products')
assert status==200 and {x['product_id'] for x in plans['data']['items']}=={'PLAN_A'},plans
status,quotas=scoped(223456789,'quotas')
assert status==200 and {x['identity_id'] for x in quotas['data']['items']}=={'clientA'},quotas

status,p0=scoped(123456789,page=0,limit=1)
status2,p1=scoped(123456789,page=1,limit=1)
assert status==status2==200
assert p0['data']['has_more'] is True and p0['data']['next_page']==1
assert p1['data']['items'][0]['identity_id']!=p0['data']['items'][0]['identity_id']

deny_status,deny_payload=scoped(323456789)
assert deny_status==403,(deny_status,deny_payload)
assert scoped(123456789,init='tampered')[0]==403
assert scoped(123456789,view='nodes')[0]==400
assert scoped(123456789,limit=999)[0]==400
assert call('/api/read',{'init_data':init_data(123456789),'view':'clients','page':0,'limit':8,'owner':'resellerB'})['status']==400
assert call('/api/read',{'init_data':init_data(123456789),'view':'clients','page':0,'limit':8},method='PUT')['status']==405

# No replay of owner access after revocation; backend must recheck scope.
print('miniapp-http-e2e=passed')
PY

sudo manager telegram miniapp disable
sudo manager telegram miniapp status | grep -q '^enabled=0$'
sudo /opt/manager/modules/telegram_miniapp.sh --detach
sudo test ! -f /etc/systemd/system/manager-telegram-miniapp.service
sudo /opt/manager/modules/telegram_miniapp.sh --install
sudo test -f /etc/systemd/system/manager-telegram-miniapp.service
sudo manager telegram miniapp status | grep -q '^enabled=0$'

test "$(cat VERSION)" = 0.8.10
bash -n modules/telegram_miniapp.sh install.sh rollback.sh uninstall.sh manager
python3 - <<'PY'
import ast,pathlib
ast.parse(pathlib.Path('modules/telegram_miniapp_server.py').read_text())
PY
git diff --exit-code
