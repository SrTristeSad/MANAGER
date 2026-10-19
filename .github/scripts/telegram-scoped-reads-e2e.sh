#!/usr/bin/env bash
set -Eeuo pipefail

source_url="file://$GITHUB_WORKSPACE"
sudo env MANAGER_ALLOW_FILE_SOURCE=1 MANAGER_REPO_RAW="$source_url" bash install.sh
test "$(sudo cat /opt/manager/VERSION)" = "$(cat VERSION)"
sudo test -x /opt/manager/modules/automation_scoped_reads.sh
sudo manager telegram gateway status | grep -q 'ops.read'
bash -n modules/automation_scoped_reads.sh modules/automation_v2.sh modules/telegram_gateway.sh modules/telegram_bot.sh
sudo systemctl disable --now manager-session-cleanup.timer manager-session-reconcile.path >/dev/null 2>&1 || true
sudo systemctl stop manager-session-cleanup.service >/dev/null 2>&1 || true
sudo /opt/manager/modules/resellers.sh --create-reseller resellerA reseller '' 100 1
sudo /opt/manager/modules/resellers.sh --create-reseller subA subreseller resellerA 100 1
sudo /opt/manager/modules/resellers.sh --create-reseller resellerB reseller '' 100 1

sudo python3 - <<'PY'
import os,time
from pathlib import Path
root=Path('/etc/manager/connection')
now=int(time.time())
def save(path, content):
    path.parent.mkdir(mode=0o700,parents=True,exist_ok=True)
    fd=os.open(str(path),os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
    with os.fdopen(fd,'w') as f: f.write(content)
for plan in ('PLAN_A','PLAN_B'):
    save(root/'products'/'catalog'/f'{plan}.conf',
         f'id={plan}\nname={plan}\nenabled=1\nduration_days=30\nmax_sessions=2\nprotocols=ssh\ntraffic_quota_bytes=1000000\nquota_period=monthly\nquota_action=warn\n')
for name,owner,plan in (('alpha1','resellerA','PLAN_A'),('alpha2','resellerA','PLAN_B'),
                        ('sub1','subA','PLAN_A'),('beta1','resellerB','PLAN_A'),
                        ('public1','','PLAN_B')):
    save(root/'identities'/f'{name}.conf',
         f'id={name}\nowner={owner}\nenabled=1\nexpires_epoch={now+7200}\nmax_sessions=2\nprotocols=ssh\n')
    save(root/'products'/'assignments'/f'{name}.conf',
         f'identity_id={name}\nproduct_id={plan}\nassigned_epoch={now}\n')
    save(root/'product-usage'/'identities'/f'{name}.state',
         f'identity_id={name}\nproduct_id={plan}\nquota_bytes=1000000\nused_bytes=2000\nenforceable=1\ncycle=2026-10\n')
    save(Path('/run/manager-session-leases/active')/f'{name}.lease',
         f'identity_id={name}\nprotocol=ssh\nsession_epoch=1\nexpires_epoch={now+7200}\nresource=DO_NOT_EXPOSE\ndevice_id=DO_NOT_EXPOSE\n')
PY

sudo manager automation v2 principal create testadmin admin '*'
sudo manager automation v2 principal scope testadmin '*' '*' 'ops.read'
sudo manager telegram identity bind 301111111 testadmin
sudo manager automation v2 principal create testreseller reseller resellerA PLAN_A
sudo manager automation v2 principal scope testreseller '*' '*' 'ops.read'
sudo manager telegram identity bind 302222222 testreseller
sudo manager automation v2 principal create testsub subreseller subA PLAN_A
sudo manager automation v2 principal scope testsub '*' '*' 'ops.read'
sudo manager telegram identity bind 303333333 testsub
sudo manager automation v2 principal create testuser user alpha1
sudo manager automation v2 principal scope testuser '*' '*' 'ops.read'
sudo manager telegram identity bind 304444444 testuser
sudo manager automation v2 principal create testdenied reseller resellerA PLAN_A
sudo manager automation v2 principal scope testdenied '*' '*' 'system.describe'
sudo manager telegram identity bind 305555555 testdenied

python3 - <<'PY'
import json
for who in ('admin','reseller','sub','user','denied'):
    for view in ('clients','products','sessions','quotas'):
        for page,limit in ((0,25),(0,1),(1,1),(2,1)):
            key=f'{who}-{view}-{page}-{limit}'
            request={'contract':'manager-telegram-gateway-request-v1',
                     'request_id':f'scoped-{key}-0001','action_id':'ops.read',
                     'params':{'view':view,'page':str(page),'limit':str(limit)}}
            open(f'/tmp/{key}.json','w').write(json.dumps(request)+'\n')
for key,params in (('owner',{'view':'clients','owner':'resellerB'}),
                   ('view',{'view':'nodes'}),('overflow',{'view':'clients','page':'100001'}),
                   ('limit',{'view':'clients','limit':'26'})):
    request={'contract':'manager-telegram-gateway-request-v1',
             'request_id':'scoped-bad-'+key+'-0001','action_id':'ops.read','params':params}
    open(f'/tmp/scoped-bad-{key}.json','w').write(json.dumps(request)+'\n')
PY

for who_and_id in admin:301111111 reseller:302222222 sub:303333333 user:304444444; do
  who="$(cut -d: -f1 <<<"$who_and_id")"
  uid="$(cut -d: -f2 <<<"$who_and_id")"
  for view in clients products sessions quotas; do
    for pair in 0:25 0:1 1:1 2:1; do
      page="$(cut -d: -f1 <<<"$pair")"; limit="$(cut -d: -f2 <<<"$pair")"
      sudo /opt/manager/modules/telegram_gateway.sh --call-bot-user "$uid" "/tmp/$who-$view-$page-$limit.json" >"/tmp/result-$who-$view-$page-$limit.json"
    done
  done
done
python3 - <<'PY'
import json
def view(who,name,page=0,limit=25):
    payload=json.load(open(f'/tmp/result-{who}-{name}-{page}-{limit}.json'))
    assert payload['ok'] is True and payload['action_id']=='ops.read' and payload['cached'] is False, payload
    v=payload['result']['view']
    assert v['contract']=='manager-automation-scoped-reads-v1'
    assert v['view']==name and v['page']==page and v['limit']==limit
    assert v['count']==len(v['items'])<=limit
    for row in v['items']:
        assert not ({'resource','device_id','password','token','private_key'} & set(row))
    return v
def ids(who,name,key):
    return {item[key] for item in view(who,name)['items']}
assert ids('admin','clients','identity_id') == {'alpha1','alpha2','sub1','beta1','public1'}
assert ids('reseller','clients','identity_id') == {'alpha1','sub1'}
assert ids('sub','clients','identity_id') == {'sub1'}
assert ids('user','clients','identity_id') == {'alpha1'}
assert ids('reseller','products','product_id') == {'PLAN_A'}
assert ids('sub','products','product_id') == {'PLAN_A'}
assert ids('user','products','product_id') == {'PLAN_A'}
for collection in ('sessions','quotas'):
    assert ids('reseller',collection,'identity_id') == {'alpha1','sub1'}, (collection, view('reseller',collection))
    assert ids('sub',collection,'identity_id') == {'sub1'}, (collection, view('sub',collection))
    assert ids('user',collection,'identity_id') == {'alpha1'}, (collection, view('user',collection))
for name in ('clients','sessions','quotas'):
    p0=view('reseller',name,0,1)
    p1=view('reseller',name,1,1)
    p2=view('reseller',name,2,1)
    assert p0['has_more'] is True and p0['next_page']==1
    assert p1['has_more'] is False and p1['next_page'] is None
    assert p2['items']==[] and p2['has_more'] is False
    assert p0['items'][0]['identity_id'] != p1['items'][0]['identity_id']
for name in ('clients','products','sessions','quotas'):
    assert view('reseller',name,0,1)['items'] != view('reseller',name,1,1)['items'] or len(view('reseller',name)['items'])==1
PY

# The exact same request ID must reflect a changed owner; no cached stale list.
sudo sed -i 's/^owner=resellerA$/owner=resellerB/' /etc/manager/connection/identities/alpha1.conf
sudo chmod 0600 /etc/manager/connection/identities/alpha1.conf
sudo /opt/manager/modules/telegram_gateway.sh --call-bot-user 302222222 /tmp/reseller-clients-0-25.json > /tmp/after-owner-revocation.json
python3 - <<'PY'
import json
x=json.load(open('/tmp/after-owner-revocation.json'))
assert x['ok'] and x['cached'] is False
assert [r['identity_id'] for r in x['result']['view']['items']]==['sub1']
PY

# A removed action_scope and client-supplied scoping never receive data.
set +e
sudo /opt/manager/modules/telegram_gateway.sh --call-bot-user 305555555 /tmp/denied-clients-0-25.json >/tmp/deny-scope.json
scope_rc=$?
for variant in owner view overflow limit; do
  sudo /opt/manager/modules/telegram_gateway.sh --call-bot-user 301111111 "/tmp/scoped-bad-$variant.json" >"/tmp/rejected-$variant.json"
  echo "$?">"/tmp/rc-$variant"
done
set -e
test "$scope_rc" = 67
python3 - <<'PY'
import json
assert json.load(open('/tmp/deny-scope.json'))['code']==67
for variant in ('owner','view','overflow','limit'):
    assert int(open('/tmp/rc-'+variant).read())==64,variant
    x=json.load(open('/tmp/rejected-'+variant+'.json'))
    assert not x['ok'] and x['code']==64
PY
! sudo grep -Eqi 'DO_NOT_EXPOSE|private_key|bot_token|credential' /var/log/manager/automation-v2-audit.jsonl /var/log/manager/telegram-gateway-audit.jsonl
git diff --exit-code
