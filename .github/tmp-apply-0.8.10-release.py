from pathlib import Path

BRANCH = "release/0.8.10-final-gate"


def replace_once(path, old, new):
    p = Path(path)
    text = p.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected anchor once, found {count}: {old!r}")
    p.write_text(text.replace(old, new, 1))


# Make install-version assertions future-proof across historical feature gates.
old_install = 'test "$(sudo cat /opt/manager/VERSION)" = 0.8.9'
new_install = 'test "$(sudo cat /opt/manager/VERSION)" = "$(cat VERSION)"'
changed = 0
for p in Path('.github/workflows').glob('*.yml'):
    text = p.read_text()
    n = text.count(old_install)
    if n:
        p.write_text(text.replace(old_install, new_install))
        changed += n
if changed < 10:
    raise SystemExit(f"unexpectedly few install-version assertions updated: {changed}")

# Historical 0.8.9 remote gate remains a feature regression gate, not the current release authority.
replace_once(
    '.github/workflows/hive-remote-final-e2e.yml',
    '      - name: Validate 0.8.9 release boundary\n',
    '      - name: Validate 0.8.9 remote boundary remains documented\n',
)
replace_once(
    '.github/workflows/hive-remote-final-e2e.yml',
    "          ! grep -q '^## \\\[0.8.10\\\]' CHANGELOG.md\n",
    "          test -f docs/HIVE_OBSERVABILITY.md\n",
)
replace_once(
    '.github/workflows/hive-remote-pool-routing.yml',
    '      - name: Keep 0.8.9 unreleased until final release gate\n',
    '      - name: Validate remote pool routing feature boundary\n',
)

# 0.8.10-specific observability gates now validate the released milestone.
for path in [
    '.github/workflows/hive-observability.yml',
    '.github/workflows/hive-observability-export.yml',
    '.github/workflows/hive-observability-timeseries.yml',
]:
    p = Path(path)
    text = p.read_text()
    text = text.replace('test "$(cat VERSION)" = 0.8.9', 'test "$(cat VERSION)" = 0.8.10')
    text = text.replace('^### 0.8.10 — observabilidade distribuída 🚧$', '^### 0.8.10 — observabilidade distribuída ✅$')
    text = text.replace("grep -q 'Ainda pendente para fechar a 0.8.10' docs/ROADMAP.md", "! grep -q 'Ainda pendente para fechar a 0.8.10' docs/ROADMAP.md")
    text = text.replace('Verify 0.8.10 remains in development', 'Verify released 0.8.10 milestone')
    p.write_text(text)

# Current version and README release surface.
Path('VERSION').write_text('0.8.10\n')
replace_once('README.md', 'Versão atual: **0.8.9**.', 'Versão atual: **0.8.10**.')
readme = Path('README.md').read_text()
old_roadmap = '''0.8.4  autoridade de leases globais                                  próximo
0.8.5  VPN allocation / login global
0.8.6  quotas/accounting globais
0.8.7  failover e resiliência operacional
0.8.8  comandos remotos controlados
0.8.9  rotação de chaves / anti-replay distribuído
0.8.10 observabilidade distribuída
'''
new_roadmap = '''0.8.4  autoridade de leases globais                                  ✅
0.8.5  VPN allocation / login global                                 ✅
0.8.6  quotas/accounting globais                                     ✅
0.8.7  failover e resiliência operacional                            ✅
0.8.8  comandos remotos controlados                                  ✅
0.8.9  rotação de chaves / anti-replay distribuído                   ✅
0.8.10 observabilidade distribuída                                   ✅
'''
if readme.count(old_roadmap) != 1:
    raise SystemExit('README roadmap anchor mismatch')
Path('README.md').write_text(readme.replace(old_roadmap, new_roadmap, 1))

# Changelog release entry.
changelog = Path('CHANGELOG.md').read_text()
if '## [0.8.10] - 2026-10-14' in changelog:
    raise SystemExit('0.8.10 changelog already present')
anchor = '## [0.8.9] - 2026-10-14\n'
entry = '''## [0.8.10] - 2026-10-14

### Colmeia — observabilidade distribuída

- Heartbeats aceitos passam a alimentar histórico sanitizado de saúde/capacidade por nó sem transformar observabilidade em autoridade e sem colocar o controlador no caminho de dados VPN.
- O histórico root-only preserva apenas campos operacionais allowlisted; endereço de origem, interface, assinatura, nonce, chave, token, senha e credencial VPN continuam fora da retenção.
- `manager hive observe summary` agrega saúde, RTT, scheduler, drain/failover, leases e eventos de outage/recovery/fencing dentro de uma janela limitada.
- Scheduler e autoridade global continuam donos dos próprios audits; a observabilidade consulta segmentos ativo/arquivados e coordena rotação por rename atômico sem truncar writers em andamento.
- `manager hive observe export` fornece JSON versionado e sanitizado para integrações controladas sem abrir listener, endpoint HTTP ou segunda superfície remota.
- `manager hive observe metrics` agrega CPU/RAM/RTT/load, sessões, utilização, deltas/rates de rede e taxas operacionais usando a janela completa.
- `manager hive observe series` produz buckets temporais limitados e filtráveis por nó; reset/reboot ou mudança de `node_epoch` cria nova baseline e nunca gera delta negativo artificial.
- Retenção de health e audits possui limites temporais/tamanho, ownership root-only e consultas bounded; falha da camada diagnóstica não invalida um heartbeat já aceito.
- Gate final integrado usa dois nós enrolled, heartbeats Ed25519 reais sobre TLS 1.3 com pin SHA-256, histórico automático, fencing de nó revogado e consultas multi-nó dos contratos de observabilidade.
- Os gates históricos deixaram de fixar a string da versão corrente e agora conferem a instalação contra o arquivo `VERSION`, evitando quebra artificial no próximo bump.

### Próxima etapa

- 0.9.x: Telegram Bot + Mini App consumindo somente contratos estruturados e autoridades já existentes.

'''
if changelog.count(anchor) != 1:
    raise SystemExit('CHANGELOG anchor mismatch')
Path('CHANGELOG.md').write_text(changelog.replace(anchor, entry + anchor, 1))

# Roadmap: close 0.8.10 without claiming a CI count before the PR actually runs.
roadmap = Path('docs/ROADMAP.md').read_text()
roadmap = roadmap.replace('### 0.8.10 — observabilidade distribuída 🚧', '### 0.8.10 — observabilidade distribuída ✅', 1)
old_pending = '''Ainda pendente para fechar a 0.8.10:

- gate final multi-nó e regressão completa da release.
'''
new_pending = '''Fechamento da fase:

- gate final multi-nó permanente com duas identidades enrolled, heartbeats Ed25519 reais, TLS 1.3 pinado e histórico automático de observabilidade;
- fencing comprova que heartbeat de nó revogado não entra no histórico após a revogação;
- summary, metrics, series e export são validados em conjunto sobre dados de múltiplos nós e eventos do control plane;
- regressão completa do repositório permanece requisito para merge da release;
- nenhum listener adicional foi criado pela observabilidade e o controlador continua fora do caminho de dados VPN.
'''
if roadmap.count(old_pending) != 1:
    raise SystemExit('ROADMAP pending anchor mismatch')
Path('docs/ROADMAP.md').write_text(roadmap.replace(old_pending, new_pending, 1))

# Dedicated observability doc now describes the closed release boundary.
obsdoc = Path('docs/HIVE_OBSERVABILITY.md').read_text()
old_scope = '''## Escopo desta fatia

A quarta fatia adiciona séries temporais e métricas operacionais derivadas das mesmas fontes autenticadas e sanitizadas. A 0.8.10 ainda não está fechada: permanece o gate final multi-nó com regressão completa e o bump formal da release.
'''
new_scope = '''## Fechamento da 0.8.10

A release 0.8.10 fecha a observabilidade distribuída sem criar uma nova autoridade. O gate final usa dois nós enrolled de verdade, envia heartbeats assinados por Ed25519 através do listener TLS 1.3 pinado, confirma a criação automática do histórico sanitizado e consulta `summary`, `metrics`, `series` e `export` sobre a mesma janela multi-nó.

O gate também cerca a fronteira de autoridade: um heartbeat preparado antes da revogação do segundo nó é recusado depois do `node_epoch`/estado autoritativo mudar e não aumenta o histórico. A observabilidade continua diagnóstica, root-only e fora do caminho de dados VPN.
'''
if obsdoc.count(old_scope) != 1:
    raise SystemExit('observability scope anchor mismatch')
Path('docs/HIVE_OBSERVABILITY.md').write_text(obsdoc.replace(old_scope, new_scope, 1))

# Replace stale release-metadata workflow with the current release contract.
old_release = Path('.github/workflows/0-8-4-release-docs.yml')
new_release = Path('.github/workflows/0-8-10-release.yml')
new_release.write_text(r'''name: Validate MANAGER 0.8.10 Release Metadata

on:
  push:
    branches: [main]
  pull_request:

permissions:
  contents: read

jobs:
  release-metadata:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v7

      - name: Verify 0.8.10 version and release documentation
        shell: bash
        run: |
          set -euxo pipefail
          test "$(cat VERSION)" = "0.8.10"
          grep -q 'Versão atual: \*\*0.8.10\*\*' README.md
          grep -q '^## \[0.8.10\] - 2026-10-14$' CHANGELOG.md
          grep -q '^### 0\.8\.10 — observabilidade distribuída ✅$' docs/ROADMAP.md
          grep -q '^## Fechamento da 0\.8\.10$' docs/HIVE_OBSERVABILITY.md
          grep -q 'manager-hive-observability-metrics-v1' docs/HIVE_OBSERVABILITY.md
          grep -q 'manager-hive-observability-series-v1' docs/HIVE_OBSERVABILITY.md
          grep -q '^name: Hive Observability 0.8.10 Final Gate$' .github/workflows/hive-observability-final-gate.yml
          grep -q '^name: Hive Distributed Observability Foundation$' .github/workflows/hive-observability.yml
          grep -q '^name: Hive Observability Structured Export$' .github/workflows/hive-observability-export.yml
          grep -q '^name: Hive Observability Operational Timeseries$' .github/workflows/hive-observability-timeseries.yml

      - name: Verify release boundary is closed
        shell: bash
        run: |
          set -euxo pipefail
          ! grep -q '^### 0\.8\.10 — observabilidade distribuída 🚧$' docs/ROADMAP.md
          ! grep -q 'Ainda pendente para fechar a 0.8.10' docs/ROADMAP.md
          grep -q '^## 0\.9\.x — Telegram Bot + Mini App$' docs/ROADMAP.md
          grep -q 'controlador continua fora do caminho de dados VPN' docs/ROADMAP.md
          git diff --exit-code
''')
old_release.unlink()

# Permanent multi-node integrated release gate.
Path('.github/workflows/hive-observability-final-gate.yml').write_text(r'''name: Hive Observability 0.8.10 Final Gate

on:
  push:
    branches: [main]
  pull_request:

permissions:
  contents: read

jobs:
  observability-final-gate:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v7

      - name: Install 0.8.10 release candidate
        shell: bash
        run: |
          set -euxo pipefail
          test "$(cat VERSION)" = 0.8.10
          sudo env MANAGER_ALLOW_FILE_SOURCE=1 MANAGER_REPO_RAW="file://${GITHUB_WORKSPACE}" bash install.sh
          test "$(sudo cat /opt/manager/VERSION)" = "$(cat VERSION)"
          sudo test -x /opt/manager/modules/hive_health.sh
          sudo test -x /opt/manager/modules/hive_observability.sh
          sudo manager hive observe status | grep -q '^controller_in_user_vpn_path=0$'

      - name: Enroll two isolated Hive nodes
        shell: bash
        run: |
          set -euxo pipefail
          sudo rm -rf /tmp/hive-0810-node1 /tmp/hive-0810-node2 /tmp/hive-0810-node1-data /tmp/hive-0810-node2-data \
            /tmp/hive-0810-health /tmp/hive-0810-observe /tmp/hive-0810-systemd /tmp/hive-0810-logs
          sudo mkdir -m 700 /tmp/hive-0810-node1 /tmp/hive-0810-node2 /tmp/hive-0810-node1-data /tmp/hive-0810-node2-data \
            /tmp/hive-0810-health /tmp/hive-0810-observe /tmp/hive-0810-logs
          sudo mkdir -m 755 /tmp/hive-0810-systemd
          sudo manager hive controller init >/dev/null
          controller_fp="$(sudo manager hive controller fingerprint)"
          printf '%s\n' "$controller_fp" >"${RUNNER_TEMP}/hive-0810-controller.fp"

          for idx in 1 2; do
            etc="/tmp/hive-0810-node${idx}"
            req="/tmp/hive-0810-node${idx}.request.json"
            bundle="/tmp/hive-0810-node${idx}.bundle.json"
            sudo env MANAGER_ETC="$etc" /opt/manager/modules/node_metadata.sh --init >/dev/null
            sudo env MANAGER_ETC="$etc" /opt/manager/modules/hive_identity.sh --request "$req" >/dev/null
            approve="$(sudo manager hive controller approve "$req" "$bundle")"
            node_id="$(awk -F= '$1=="node_id"{print $2}' <<<"$approve")"
            test -n "$node_id"
            sudo env MANAGER_ETC="$etc" /opt/manager/modules/hive_identity.sh --accept "$bundle" "$controller_fp" >/dev/null
            printf '%s\n' "$node_id" >"${RUNNER_TEMP}/hive-0810-node${idx}.id"
          done
          test "$(cat "${RUNNER_TEMP}/hive-0810-node1.id")" != "$(cat "${RUNNER_TEMP}/hive-0810-node2.id")"

      - name: Start pinned TLS 1.3 health authority
        shell: bash
        run: |
          set -euxo pipefail
          port="$(python3 - <<'PY'
          import socket
          s=socket.socket(); s.bind(('127.0.0.1',0)); print(s.getsockname()[1]); s.close()
          PY
          )"
          printf '%s\n' "$port" >"${RUNNER_TEMP}/hive-0810-health.port"
          common=(
            GITHUB_ACTIONS=true
            MANAGER_HIVE_HEALTH_SKIP_SYSTEMD=1
            MANAGER_HIVE_HEALTH_SYSTEMD_DIR=/tmp/hive-0810-systemd
            MANAGER_HIVE_HEALTH_DATA_DIR=/tmp/hive-0810-health
            MANAGER_HIVE_HEALTH_AUDIT_FILE=/tmp/hive-0810-logs/health.jsonl
            MANAGER_HIVE_OBSERVABILITY_DATA_DIR=/tmp/hive-0810-observe
            MANAGER_HIVE_OBSERVABILITY_AUDIT_FILE=/tmp/hive-0810-logs/observe.jsonl
          )
          enable="$(sudo env "${common[@]}" /opt/manager/modules/hive_health.sh --controller-enable 127.0.0.1 "$port")"
          grep -q '^controller_health_enabled=1$' <<<"$enable"
          grep -q '^tls=TLSv1.3$' <<<"$enable"
          grep -q '^firewall_auto_open=0$' <<<"$enable"
          status="$(sudo env "${common[@]}" /opt/manager/modules/hive_health.sh --controller-status)"
          tls_fp="$(awk -F= '$1=="tls_fingerprint"{print $2}' <<<"$status")"
          [[ "$tls_fp" =~ ^SHA256:[a-f0-9]{64}$ ]]
          printf '%s\n' "$tls_fp" >"${RUNNER_TEMP}/hive-0810-health.tls-fp"
          sudo env "${common[@]}" /opt/manager/modules/hive_health.sh --serve-controller >"${RUNNER_TEMP}/hive-0810-health.log" 2>&1 &
          echo $! >"${RUNNER_TEMP}/hive-0810-health.pid"
          for _ in $(seq 1 60); do
            if python3 - "$port" <<'PY'
          import socket,sys
          try:
              s=socket.create_connection(('127.0.0.1',int(sys.argv[1])),timeout=.2); s.close()
          except OSError:
              raise SystemExit(1)
          PY
            then break; fi
            sleep .1
          done
          kill -0 "$(cat "${RUNNER_TEMP}/hive-0810-health.pid")"

      - name: Send signed heartbeats from both nodes and build history automatically
        shell: bash
        run: |
          set -euxo pipefail
          port="$(cat "${RUNNER_TEMP}/hive-0810-health.port")"
          tls_fp="$(cat "${RUNNER_TEMP}/hive-0810-health.tls-fp")"
          for idx in 1 2; do
            etc="/tmp/hive-0810-node${idx}"
            data="/tmp/hive-0810-node${idx}-data"
            sudo env GITHUB_ACTIONS=true MANAGER_ETC="$etc" MANAGER_HIVE_HEALTH_SKIP_SYSTEMD=1 \
              MANAGER_HIVE_HEALTH_SYSTEMD_DIR=/tmp/hive-0810-systemd MANAGER_HIVE_HEALTH_DATA_DIR="$data" \
              /opt/manager/modules/hive_health.sh --configure 127.0.0.1 "$port" "$tls_fp" 30 >/dev/null
            sent="$(sudo env GITHUB_ACTIONS=true MANAGER_ETC="$etc" MANAGER_HIVE_HEALTH_SKIP_SYSTEMD=1 \
              MANAGER_HIVE_HEALTH_SYSTEMD_DIR=/tmp/hive-0810-systemd MANAGER_HIVE_HEALTH_DATA_DIR="$data" \
              /opt/manager/modules/hive_health.sh --send)"
            grep -q '^heartbeat_accepted=1$' <<<"$sent"
          done

          sudo env MANAGER_ETC=/tmp/hive-0810-node2 /opt/manager/modules/node_metadata.sh --set enabled 0 >/dev/null
          for idx in 1 2; do
            etc="/tmp/hive-0810-node${idx}"
            data="/tmp/hive-0810-node${idx}-data"
            sent="$(sudo env GITHUB_ACTIONS=true MANAGER_ETC="$etc" MANAGER_HIVE_HEALTH_SKIP_SYSTEMD=1 \
              MANAGER_HIVE_HEALTH_SYSTEMD_DIR=/tmp/hive-0810-systemd MANAGER_HIVE_HEALTH_DATA_DIR="$data" \
              /opt/manager/modules/hive_health.sh --send)"
            grep -q '^heartbeat_accepted=1$' <<<"$sent"
          done
          node2="$(cat "${RUNNER_TEMP}/hive-0810-node2.id")"
          show2="$(sudo env GITHUB_ACTIONS=true MANAGER_HIVE_HEALTH_SKIP_SYSTEMD=1 MANAGER_HIVE_HEALTH_SYSTEMD_DIR=/tmp/hive-0810-systemd \
            MANAGER_HIVE_HEALTH_DATA_DIR=/tmp/hive-0810-health MANAGER_HIVE_HEALTH_AUDIT_FILE=/tmp/hive-0810-logs/health.jsonl \
            /opt/manager/modules/hive_health.sh --controller-show "$node2")"
          grep -q '^state=DRAINING$' <<<"$show2"

          sudo test -f /tmp/hive-0810-observe/health-history.jsonl
          test "$(sudo wc -l /tmp/hive-0810-observe/health-history.jsonl | awk '{print $1}')" -ge 4
          test "$(sudo stat -c '%a' /tmp/hive-0810-observe/health-history.jsonl)" = 600
          ! sudo grep -Eq 'signature|nonce|private_key|password|token|network_interface|source' /tmp/hive-0810-observe/health-history.jsonl

      - name: Add control-plane events and query all observability contracts
        shell: bash
        run: |
          set -euxo pipefail
          now="$(date +%s)"
          node1="$(cat "${RUNNER_TEMP}/hive-0810-node1.id")"
          node2="$(cat "${RUNNER_TEMP}/hive-0810-node2.id")"
          sudo tee /tmp/hive-0810-logs/scheduler.jsonl >/dev/null <<EOF
          {"epoch":$((now-40)),"event":"select","node_id":"$node1","protocol":"ssh","reason":"weighted-least-loaded","secret":"must-not-leak"}
          {"epoch":$((now-30)),"event":"select","node_id":"$node2","protocol":"ssh","reason":"sticky-failover","token":"must-not-leak"}
          {"epoch":$((now-20)),"event":"drain","node_id":"$node2","reason":"release-gate"}
          {"epoch":$((now-10)),"event":"undrain","node_id":"$node2"}
          EOF
          sudo tee /tmp/hive-0810-logs/lease.jsonl >/dev/null <<EOF
          {"epoch":$((now-35)),"event":"grant","identity_id":"release-gate","node_id":"$node1","password":"must-not-leak"}
          {"epoch":$((now-25)),"event":"deny","identity_id":"release-gate","node_id":"$node2","reason":"global-session-limit","token":"must-not-leak"}
          {"epoch":$((now-15)),"event":"node-authority-outage","node_id":"$node2","authority_epoch":9,"private_key":"must-not-leak"}
          EOF
          sudo chmod 600 /tmp/hive-0810-logs/scheduler.jsonl /tmp/hive-0810-logs/lease.jsonl
          common=(
            MANAGER_HIVE_OBSERVABILITY_DATA_DIR=/tmp/hive-0810-observe
            MANAGER_HIVE_HEALTH_DATA_DIR=/tmp/hive-0810-health
            MANAGER_HIVE_SCHEDULER_AUDIT_FILE=/tmp/hive-0810-logs/scheduler.jsonl
            MANAGER_HIVE_LEASE_AUDIT_FILE=/tmp/hive-0810-logs/lease.jsonl
            MANAGER_HIVE_OBSERVABILITY_AUDIT_FILE=/tmp/hive-0810-logs/observe.jsonl
          )
          sudo env "${common[@]}" /opt/manager/manager hive observe summary 3600 >/tmp/hive-0810-summary.json
          sudo env "${common[@]}" /opt/manager/manager hive observe metrics 3600 >/tmp/hive-0810-metrics.json
          sudo env "${common[@]}" /opt/manager/manager hive observe series '*' 3600 300 >/tmp/hive-0810-series.json
          sudo env "${common[@]}" /opt/manager/manager hive observe export 3600 50 >/tmp/hive-0810-export.json
          sudo env "${common[@]}" /opt/manager/manager hive observe health '*' 20 >/tmp/hive-0810-health-history.out
          python3 - <<'PY'
          import json
          summary=json.load(open('/tmp/hive-0810-summary.json'))
          metrics=json.load(open('/tmp/hive-0810-metrics.json'))
          series=json.load(open('/tmp/hive-0810-series.json'))
          export=json.load(open('/tmp/hive-0810-export.json'))
          assert summary['contract']=='manager-hive-observability-v1'
          assert summary['nodes_observed']==2 and summary['health_samples'] >= 4
          assert summary['scheduler_selections']==2 and summary['scheduler_failovers']==1
          assert summary['drains']==1 and summary['undrains']==1
          assert summary['lease_grants']==1 and summary['lease_denies']==1
          assert metrics['contract']=='manager-hive-observability-metrics-v1'
          assert metrics['nodes_observed']==2 and metrics['health_samples'] >= 4
          assert metrics['scheduler_failover_percent']==50.0
          assert metrics['lease_deny_percent']==50.0
          assert metrics['authority_outages']==1
          assert metrics['network_rx_delta_bytes'] >= 0 and metrics['network_tx_delta_bytes'] >= 0
          assert series['contract']=='manager-hive-observability-series-v1'
          assert series['nodes_observed']==2 and series['samples'] >= 4
          assert 1 <= series['returned_buckets'] <= series['max_buckets']
          assert export['contract']=='manager-hive-observability-export-v1'
          assert export['summary']['nodes_observed']==2
          assert export['security']['contains_private_keys']==0
          assert export['security']['contains_credentials']==0
          for path in ('/tmp/hive-0810-summary.json','/tmp/hive-0810-metrics.json','/tmp/hive-0810-series.json','/tmp/hive-0810-export.json','/tmp/hive-0810-health-history.out'):
              raw=open(path).read()
              assert 'must-not-leak' not in raw
              assert 'private_key' not in raw or 'contains_private_keys' in raw
              assert 'password' not in raw and 'token' not in raw
          PY

      - name: Fence a revoked node before it can extend observability history
        shell: bash
        run: |
          set -euxo pipefail
          node2="$(cat "${RUNNER_TEMP}/hive-0810-node2.id")"
          sudo env MANAGER_ETC=/tmp/hive-0810-node2 MANAGER_HIVE_HEALTH_DATA_DIR=/tmp/hive-0810-node2-data \
            /opt/manager/modules/hive_health.sh --heartbeat /tmp/hive-0810-node2-stale.json >/dev/null
          before="$(sudo wc -l /tmp/hive-0810-observe/health-history.jsonl | awk '{print $1}')"
          sudo manager hive controller revoke "$node2" release-gate-fence >/dev/null
          if sudo env GITHUB_ACTIONS=true MANAGER_ETC=/tmp/hive-0810-node2 MANAGER_HIVE_HEALTH_SKIP_SYSTEMD=1 \
            MANAGER_HIVE_HEALTH_SYSTEMD_DIR=/tmp/hive-0810-systemd MANAGER_HIVE_HEALTH_DATA_DIR=/tmp/hive-0810-node2-data \
            /opt/manager/modules/hive_health.sh --send-file /tmp/hive-0810-node2-stale.json; then
            echo 'revoked node extended health/observability history' >&2
            exit 1
          fi
          after="$(sudo wc -l /tmp/hive-0810-observe/health-history.jsonl | awk '{print $1}')"
          test "$after" = "$before"
          sudo grep -q '"event":"reject"' /tmp/hive-0810-logs/health.jsonl

      - name: Rotate audits and keep bounded multi-node queries readable
        shell: bash
        run: |
          set -euxo pipefail
          common=(
            MANAGER_HIVE_OBSERVABILITY_DATA_DIR=/tmp/hive-0810-observe
            MANAGER_HIVE_HEALTH_DATA_DIR=/tmp/hive-0810-health
            MANAGER_HIVE_SCHEDULER_AUDIT_FILE=/tmp/hive-0810-logs/scheduler.jsonl
            MANAGER_HIVE_LEASE_AUDIT_FILE=/tmp/hive-0810-logs/lease.jsonl
            MANAGER_HIVE_OBSERVABILITY_AUDIT_FILE=/tmp/hive-0810-logs/observe.jsonl
          )
          sudo env "${common[@]}" /opt/manager/manager hive observe audit-maintain 3600 1024 force >/tmp/hive-0810-maintain.out
          grep -q '^scheduler_rotated=1$' /tmp/hive-0810-maintain.out
          grep -q '^leases_rotated=1$' /tmp/hive-0810-maintain.out
          sudo env "${common[@]}" /opt/manager/manager hive observe summary 3600 >/tmp/hive-0810-summary-after.json
          python3 - <<'PY'
          import json
          x=json.load(open('/tmp/hive-0810-summary-after.json'))
          assert x['scheduler_selections']==2
          assert x['lease_grants']==1 and x['lease_denies']==1
          PY
          sudo env "${common[@]}" /opt/manager/manager hive observe prune 3600 >/tmp/hive-0810-prune.out
          test "$(sudo stat -c '%a' /tmp/hive-0810-observe/health-history.jsonl)" = 600

      - name: Validate closed 0.8.10 release boundary
        shell: bash
        run: |
          set -euxo pipefail
          test "$(cat VERSION)" = 0.8.10
          grep -q 'Versão atual: \*\*0.8.10\*\*' README.md
          grep -q '^## \[0.8.10\] - 2026-10-14$' CHANGELOG.md
          grep -q '^### 0\.8\.10 — observabilidade distribuída ✅$' docs/ROADMAP.md
          grep -q '^## Fechamento da 0\.8\.10$' docs/HIVE_OBSERVABILITY.md
          ! grep -q 'Ainda pendente para fechar a 0.8.10' docs/ROADMAP.md

      - name: Stop health authority
        if: always()
        shell: bash
        run: |
          if [[ -f "${RUNNER_TEMP}/hive-0810-health.pid" ]]; then
            sudo kill "$(cat "${RUNNER_TEMP}/hive-0810-health.pid")" 2>/dev/null || true
          fi
''')

print('release patch prepared')
