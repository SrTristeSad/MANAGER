from pathlib import Path
workflow = r'''name: Telegram Bot Long Polling Ingress

on:
  pull_request:
    paths:
      - modules/telegram_bot.sh
      - modules/telegram_gateway.sh
      - modules/telegram_identity.sh
      - modules/automation_v2.sh
      - manager
      - install.sh
      - uninstall.sh
      - docs/TELEGRAM.md
      - docs/ROADMAP.md
      - .github/workflows/telegram-bot-ingress.yml
  push:
    branches: [main]
    paths:
      - modules/telegram_bot.sh
      - modules/telegram_gateway.sh
      - modules/telegram_identity.sh
      - modules/automation_v2.sh
      - manager
      - install.sh
      - uninstall.sh
      - docs/TELEGRAM.md
      - docs/ROADMAP.md
      - .github/workflows/telegram-bot-ingress.yml

permissions:
  contents: read

jobs:
  telegram-bot-ingress:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v7
      - name: Install and prepare binding
        shell: bash
        run: |
          set -euxo pipefail
          source_url="file://${GITHUB_WORKSPACE}"
          sudo env MANAGER_ALLOW_FILE_SOURCE=1 MANAGER_REPO_RAW="$source_url" bash install.sh
          test "$(sudo cat /opt/manager/VERSION)" = "$(cat VERSION)"
          sudo manager telegram bot status >/tmp/bot-status
          grep -q '^contract=manager-telegram-bot-ingress-v1$' /tmp/bot-status
          grep -q '^transport=telegram-bot-api-long-polling$' /tmp/bot-status
          grep -q '^authorization_authority=automation-v2$' /tmp/bot-status
          grep -q '^username_is_authority=0$' /tmp/bot-status
          grep -q '^arbitrary_shell=0$' /tmp/bot-status
          sudo manager automation v2 principal create telegram-bot-admin admin '*'
          sudo manager automation v2 principal scope telegram-bot-admin '*' '*' 'system.describe,node.usage'
          sudo manager telegram identity bind 123456789 telegram-bot-admin
          umask 077
          python3 - <<'PY'
          open('/tmp/bot-token','w').write('123456789:' + 'A'*32 + '\n')
          PY
          sudo manager telegram auth token install /tmp/bot-token
          rm -f /tmp/bot-token
          test "$(sudo stat -c '%a' /etc/manager/telegram/bot)" = 700
          test "$(sudo stat -c '%a' /etc/manager/telegram/bot/offset.conf)" = 600

      - name: Prove typed Bot update to Automation v2
        shell: bash
        run: |
          set -euxo pipefail
          cat >/tmp/update.json <<'JSON'
          {"update_id":7001,"message":{"from":{"id":123456789,"first_name":"IgnoredName","username":"IgnoredUser"},"chat":{"id":999999},"text":"/describe"}}
          JSON
          sudo /opt/manager/modules/telegram_bot.sh --process-update /tmp/update.json >/tmp/result.json
          python3 - <<'PY'
          import json
          x=json.load(open('/tmp/result.json'))
          assert x['ok'] is True and x['code']==0
          assert x['principal_id']=='telegram-bot-admin'
          assert x['telegram_user_id']=='123456789'
          assert x['action_id']=='system.describe'
          assert x['telegram_request_id']=='bot-00000000000000007001'
          PY
          sudo grep -q '"principal_id":"telegram-bot-admin"' /var/log/manager/automation-v2-audit.jsonl
          sudo grep -q '"action_id":"system.describe"' /var/log/manager/automation-v2-audit.jsonl

      - name: Reuse idempotency and ignore arbitrary text
        shell: bash
        run: |
          set -euxo pipefail
          sudo /opt/manager/modules/telegram_bot.sh --process-update /tmp/update.json >/tmp/retry.json
          python3 - <<'PY'
          import json
          x=json.load(open('/tmp/retry.json')); assert x['ok'] is True and x['cached'] is True
          PY
          cat >/tmp/unknown.json <<'JSON'
          {"update_id":7002,"message":{"from":{"id":123456789,"username":"admin"},"chat":{"id":1},"text":"/shell id"}}
          JSON
          before="$(sudo wc -l </var/log/manager/telegram-gateway-audit.jsonl)"
          sudo /opt/manager/modules/telegram_bot.sh --process-update /tmp/unknown.json >/tmp/unknown-result
          grep -q '"ignored":1' /tmp/unknown-result
          after="$(sudo wc -l </var/log/manager/telegram-gateway-audit.jsonl)"
          test "$before" = "$after"

      - name: Fail closed for unbound user and disabled binding
        shell: bash
        run: |
          set -euxo pipefail
          cat >/tmp/unbound.json <<'JSON'
          {"update_id":7003,"message":{"from":{"id":987654321,"username":"telegram-bot-admin"},"chat":{"id":123456789},"text":"/describe"}}
          JSON
          if sudo /opt/manager/modules/telegram_bot.sh --process-update /tmp/unbound.json; then exit 1; fi
          sudo manager telegram identity disable 123456789
          if sudo /opt/manager/modules/telegram_bot.sh --process-update /tmp/update.json; then exit 1; fi
          sudo manager telegram identity enable 123456789

      - name: Preserve state and keep audits secret free
        shell: bash
        run: |
          set -euxo pipefail
          printf 'version=1\nnext_update_id=7002\n' | sudo tee /etc/manager/telegram/bot/offset.conf >/dev/null
          sudo chmod 600 /etc/manager/telegram/bot/offset.conf
          before="$(sudo cat /etc/manager/telegram/bot/offset.conf)"
          source_url="file://${GITHUB_WORKSPACE}"
          sudo env MANAGER_ALLOW_FILE_SOURCE=1 MANAGER_REPO_RAW="$source_url" bash install.sh
          test "$before" = "$(sudo cat /etc/manager/telegram/bot/offset.conf)"
          ! sudo grep -Fq 'IgnoredName' /var/log/manager/telegram-bot-audit.jsonl
          ! sudo grep -Fq 'IgnoredUser' /var/log/manager/telegram-bot-audit.jsonl
          ! sudo grep -Eqi 'token|username|chat_id|private_key' /var/log/manager/telegram-bot-audit.jsonl
          grep -q '^## Ingresso do Telegram Bot por long polling$' docs/TELEGRAM.md
          grep -q 'manager-telegram-bot-ingress-v1' docs/TELEGRAM.md
          grep -q 'long polling HTTPS com a Telegram Bot API' docs/ROADMAP.md
          test "$(cat VERSION)" = 0.8.10
          git diff --exit-code
'''
Path('.github/workflows/telegram-bot-ingress.yml').write_text(workflow)
print('telegram bot ingress gate generated')
