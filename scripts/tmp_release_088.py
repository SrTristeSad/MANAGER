from pathlib import Path

ROOT = Path('.')


def replace_once(path, old, new):
    p = ROOT / path
    text = p.read_text()
    if new in text:
        return
    if old not in text:
        raise SystemExit(f'anchor missing in {path}: {old!r}')
    p.write_text(text.replace(old, new, 1))


# Version.
Path('VERSION').write_text('0.8.8\n')

# README release surface.
replace_once('README.md', 'Versão atual: **0.8.7**.', 'Versão atual: **0.8.8**.')
replace_once('README.md', '## Colmeia — 0.8.0 a 0.8.7', '## Colmeia — 0.8.0 a 0.8.8')
replace_once(
    'README.md',
    '- **0.8.7** — resiliência operacional: estado de outage/recovery da autoridade, probe autenticado, fencing de geração e drain sem expulsão desnecessária.\n',
    '- **0.8.7** — resiliência operacional: estado de outage/recovery da autoridade, probe autenticado, fencing de geração e drain sem expulsão desnecessária.\n'
    '- **0.8.8** — operações administrativas remotas tipadas, escopos por nó/pool/ação e roteamento assinado por nó ou pool, sem shell arbitrário.\n',
)

# Changelog.
p = Path('CHANGELOG.md')
text = p.read_text()
marker = '## [0.8.7] - 2026-10-12\n'
section = '''## [0.8.8] - 2026-10-12

### Colmeia — comandos remotos controlados

- Automation v2 continua sendo a única superfície de execução remota e aceita somente ações estruturadas allowlisted; não existe shell, comando ou caminho arbitrário.
- Principals não-locais possuem escopos persistentes `node_scope`, `pool_scope` e `action_scope`; RBAC é reavaliado antes de servir retry idempotente.
- Nós enrolled publicam anúncios de rota assinados por Ed25519 contendo endpoint IP literal, fingerprint TLS, `action_scope`, `node_epoch` e `route_epoch`.
- O controlador aceita somente rotas de nós registrados e ativos e cerca replay/rollback de rota por `route_epoch`.
- `manager hive remote controller call NODE_ID ACTION ...` resolve endpoint e fingerprint exclusivamente pelo registro assinado.
- A identidade Ed25519 do próprio controlador é reutilizada como principal reservado `hive-controller`; a chave privada do controlador não é distribuída aos nós.
- Cada nó revalida `controller_id`, `node_epoch`, escopo de ação, escopo de nó e pool antes do dispatcher da Automation v2.
- `manager hive remote controller select POOL PROTOCOL ACTION [STICKY]` reutiliza o scheduler 0.8.3, sem criar uma segunda autoridade de saúde/carga.
- `manager hive remote controller call-pool ...` seleciona e executa a operação tipada, revalidando rota e geração depois da seleção.
- Seleção por pool respeita HEALTHY, drain, protocolo/serviço, capacidade, weighted least-loaded, RTT secundário e sticky/failover.
- O gate final usa dois gateways TLS distintos e duas identidades enrolled; valida chamadas reais aos dois nós, replay idempotente e failover real para o segundo gateway após drain.
- Revogação de nó remove sua autoridade de roteamento antes de nova chamada, e decisões entram no audit remoto.
- O HEAD funcional da 0.8.8 passou **33/33 workflows** antes do bump formal da release.

### Próxima etapa

- 0.8.9: rotação de chaves e anti-replay distribuído, com transição e fencing explícitos.

'''
if '## [0.8.8] - 2026-10-12' not in text:
    if marker not in text:
        raise SystemExit('CHANGELOG marker missing')
    p.write_text(text.replace(marker, section + marker, 1))

# Roadmap closure.
replace_once(
    'docs/ROADMAP.md',
    '### 0.8.8 — comandos remotos controlados\n\nFundação implementada nesta fase:',
    '### 0.8.8 — comandos remotos controlados ✅\n\nImplementado:',
)
replace_once(
    'docs/ROADMAP.md',
    'Ainda pendente para fechar 0.8.8:\n\n- gate end-to-end final de múltiplos nós/pool + regressão completa;\n- fechamento formal da release 0.8.8;\n- integração futura com Telegram sem criar uma segunda autoridade paralela.\n',
    'Fechamento da fase:\n\n- gate end-to-end com dois gateways TLS distintos, múltiplos nós e pool validado;\n- regressão completa de 33 workflows concluída antes do bump formal;\n- integração com Telegram permanece futura e consumirá estes contratos sem criar uma segunda autoridade paralela.\n',
)

# Metadata gate is intentionally specific rather than a blind version replacement.
Path('.github/workflows/0-8-4-release-docs.yml').write_text('''name: Validate MANAGER 0.8.8 Release Metadata

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

      - name: Verify 0.8.8 version and release documentation
        shell: bash
        run: |
          set -euxo pipefail
          test "$(cat VERSION)" = "0.8.8"
          grep -q 'Versão atual: \\*\\*0.8.8\\*\\*' README.md
          grep -q '0.8.8.*operações administrativas remotas tipadas' README.md
          grep -q '^## \\[0.8.8\\] - 2026-10-12$' CHANGELOG.md
          grep -q '^### 0\\.8\\.8 — comandos remotos controlados ✅$' docs/ROADMAP.md
          grep -q '^## 23\\. Roteamento remoto tipado — fundação 0\\.8\\.8$' docs/HIVE.md
          grep -q 'manager hive remote controller call-pool' docs/HIVE.md
          grep -q 'hive_controller_remote_auth=1' modules/automation_v2.sh
          grep -q 'controller-call-pool' modules/hive_remote.sh

      - name: Keep 0.8.9 outside the 0.8.8 release
        shell: bash
        run: |
          set -euxo pipefail
          grep -q '^### 0\\.8\\.9 — rotação de chaves e anti-replay distribuído$' docs/ROADMAP.md
          ! grep -q '^## \\[0.8.9\\]' CHANGELOG.md
          test "$(cat VERSION)" = "0.8.8"
''')

# Workflows that assert the installed/current version should follow the release,
# without changing functional test logic. Metadata and final E2E are handled separately.
for p in Path('.github/workflows').glob('*.yml'):
    if p.name in {'0-8-4-release-docs.yml', 'hive-remote-final-e2e.yml'}:
        continue
    s = p.read_text()
    s = s.replace('test "$(sudo cat /opt/manager/VERSION)" = 0.8.7', 'test "$(sudo cat /opt/manager/VERSION)" = 0.8.8')
    s = s.replace('test "$(sudo cat /opt/manager/VERSION)" = "0.8.7"', 'test "$(sudo cat /opt/manager/VERSION)" = "0.8.8"')
    s = s.replace('test "$(cat VERSION)" = 0.8.7', 'test "$(cat VERSION)" = 0.8.8')
    s = s.replace('test "$(cat VERSION)" = "0.8.7"', 'test "$(cat VERSION)" = "0.8.8"')
    p.write_text(s)

# Final E2E becomes a release regression gate instead of an unreleased-boundary gate.
p = Path('.github/workflows/hive-remote-final-e2e.yml')
s = p.read_text()
s = s.replace('test "$(sudo cat /opt/manager/VERSION)" = 0.8.7', 'test "$(sudo cat /opt/manager/VERSION)" = 0.8.8')
s = s.replace('      - name: Keep release boundary intact\n', '      - name: Validate 0.8.8 release boundary\n')
s = s.replace('          ! grep -q \'^## \\\\[0.8.8\\\\]\' CHANGELOG.md\n', "          grep -q '^## \\\\[0.8.8\\\\] - 2026-10-12$' CHANGELOG.md\n          ! grep -q '^## \\\\[0.8.9\\\\]' CHANGELOG.md\n")
p.write_text(s)
