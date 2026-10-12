from pathlib import Path


def replace_once(path, old, new):
    p=Path(path); s=p.read_text()
    if new in s:
        return
    if old not in s:
        raise SystemExit(f'anchor missing in {path}: {old!r}')
    p.write_text(s.replace(old,new,1))

# VERSION
Path('VERSION').write_text('0.8.6\n')

# README
replace_once('README.md', 'Versão atual: **0.8.5**.', 'Versão atual: **0.8.6**.')
replace_once('README.md', '## Colmeia — 0.8.0 a 0.8.5', '## Colmeia — 0.8.0 a 0.8.6')
replace_once('README.md',
'- **0.8.5** — VPN allocation / login global, entrega/provisionamento automático no nó selecionado e retorno seguro de credenciais/perfis.\n',
'- **0.8.5** — VPN allocation / login global, entrega/provisionamento automático no nó selecionado e retorno seguro de credenciais/perfis.\n- **0.8.6** — accounting global idempotente por nó, deduplicação de deltas e franquia global separada de `max_sessions_global`.\n')
replace_once('README.md',
'/var/lib/manager/hive-leases/                  leases, epochs e anti-replay globais\n/var/log/manager/hive-scheduler-audit.jsonl',
'/var/lib/manager/hive-leases/                  leases, epochs e anti-replay globais\n/var/lib/manager/hive-accounting/               snapshots/deltas e agregado global de uso\n/etc/manager/hive/controller/accounting/         políticas de franquia global\n/var/log/manager/hive-scheduler-audit.jsonl')

# CHANGELOG
p=Path('CHANGELOG.md'); s=p.read_text()
marker='## [0.8.5] - 2026-10-12\n'
section='''## [0.8.6] - 2026-10-12

### Colmeia — quotas e accounting globais

- Novo `modules/hive_accounting.sh` agrega uso de identidades entre múltiplos nós sem colocar o controlador no caminho de dados VPN.
- Nós enviam snapshots cumulativos pelo mesmo control plane Ed25519 enrolled + freshness/nonce + `node_epoch` + TLS 1.3 com pin SHA-256 usado pelas leases globais.
- O controlador deriva deltas por `(node_id, identity_id, source_epoch)`: retry/redelivery idêntico vira delta zero e regressão dentro da mesma geração é recusada.
- Mudança explícita de `source_epoch` cria baseline novo sem somar novamente o snapshot inicial, protegendo contra double counting após reset/reconnect.
- Uso de múltiplas VPS é consolidado em estado global root-only por identidade, com audit separado de ingestão e decisões de quota.
- Franquia global suporta `monthly` e `lifetime`, com ações `warn` e `block`, mantendo política e estado separados de `max_sessions_global`.
- Quota `block` impede novos grants/acquires somente quando o agregado ultrapassa a franquia e a cobertura de bytes é completa.
- Como a telemetria atual mede bytes de WireGuard/OpenVPN mas não de SSH, identidades com SSH ficam `quota_enforceable=0` para evitar bloqueio incorreto por consumo parcial.
- Timer de nó sincroniza accounting periodicamente; uninstall/detach preservam snapshots, baselines e políticas, enquanto purge remove apenas o estado da 0.8.6.
- A sandbox `ProtectSystem=full` da autoridade de leases permanece ativa; somente o diretório de accounting foi incluído em `ReadWritePaths`.
- Gate permanente `Hive Global Accounting and Quotas` valida dois nós, deduplicação, counter fencing, reset de geração, quota, independência de sessões, cobertura SSH parcial e lifecycle.
- O HEAD funcional passou **28/28 workflows** antes do bump da release.

### Próxima etapa

- 0.8.7: failover e resiliência operacional da Colmeia.

'''
if '## [0.8.6] - 2026-10-12' not in s:
    if marker not in s: raise SystemExit('CHANGELOG 0.8.5 marker missing')
    p.write_text(s.replace(marker, section+marker,1))

# ROADMAP
replace_once('docs/ROADMAP.md', '### 0.8.6 — quotas e accounting globais 🚧', '### 0.8.6 — quotas e accounting globais ✅')
# Only the 0.8.6 wording directly after its header.
p=Path('docs/ROADMAP.md'); s=p.read_text()
needle='### 0.8.6 — quotas e accounting globais ✅\n\nImplementado na fundação desta fase:'
if needle in s:
    p.write_text(s.replace(needle, '### 0.8.6 — quotas e accounting globais ✅\n\nImplementado:',1))

# Release metadata gate
Path('.github/workflows/0-8-4-release-docs.yml').write_text('''name: Validate MANAGER 0.8.6 Release Metadata

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

      - name: Verify 0.8.6 version and release documentation
        shell: bash
        run: |
          set -euxo pipefail
          test "$(cat VERSION)" = "0.8.6"
          grep -q 'Versão atual: \\*\\*0.8.6\\*\\*' README.md
          grep -q '0.8.6.*accounting global' README.md
          grep -q '^## \\[0.8.6\\] - 2026-10-12$' CHANGELOG.md
          grep -q '^### 0\\.8\\.6 — quotas e accounting globais ✅$' docs/ROADMAP.md
          grep -q '^## 21\\. Accounting global — fundação 0\\.8\\.6$' docs/HIVE.md
          grep -q 'manager hive accounting quota set' docs/HIVE.md
          grep -q 'usage-counter-regression' modules/hive_leases.sh
          grep -q 'global-traffic-quota-exceeded' modules/hive_leases.sh

      - name: Keep 0.8.7 outside the 0.8.6 release
        shell: bash
        run: |
          set -euxo pipefail
          grep -q '^### 0\\.8\\.7 — failover e resiliência operacional$' docs/ROADMAP.md
          ! grep -q '^## \\[0.8.7\\]' CHANGELOG.md
          test "$(cat VERSION)" = "0.8.6"
''')

# Functional gates should validate the released version without weakening behavior.
for path in [
    '.github/workflows/hive-vpn-allocation.yml',
    '.github/workflows/hive-vpn-allocation-distribution.yml',
    '.github/workflows/hive-vpn-remote-provisioning.yml',
    '.github/workflows/hive-vpn-public-login.yml',
    '.github/workflows/hive-global-accounting.yml',
]:
    p=Path(path); s=p.read_text()
    old='test "$(sudo cat /opt/manager/VERSION)" = 0.8.5'
    new='test "$(sudo cat /opt/manager/VERSION)" = 0.8.6'
    if old in s:
        p.write_text(s.replace(old,new))
    elif new not in s:
        raise SystemExit(f'version assertion missing in {path}')
