from pathlib import Path

# Fix the release boundary in the existing remote E2E gate.
p = Path('.github/workflows/hive-remote-final-e2e.yml')
s = p.read_text()
old = '''          grep -q '^## \\[0.8.9\\] - 2026-10-12$' CHANGELOG.md
          ! grep -q '^## \\[0.8.9\\]' CHANGELOG.md
'''
new = '''          grep -q '^## \\[0.8.9\\] - 2026-10-14$' CHANGELOG.md
          grep -q '^### 0\\.8\\.9 — rotação de chaves e anti-replay distribuído ✅$' docs/ROADMAP.md
          ! grep -q '^## \\[0.8.10\\]' CHANGELOG.md
'''
if old not in s:
    raise SystemExit('remote-final-e2e release boundary anchor missing')
p.write_text(s.replace(old, new, 1))

# The idempotent activation API intentionally requires an already-existing
# absolute output directory, just like the first activation. Create the retry
# destination before exercising cached_activation=1.
p = Path('.github/workflows/hive-security-final-gate.yml')
s = p.read_text()
old = '''          sudo manager hive network controller rotate activate "$rotation_id" /tmp/final-wg-rotated-retry >/tmp/final.wg.activate.retry.log
          grep -q '^cached_activation=1$' /tmp/final.wg.activate.retry.log
'''
new = '''          sudo mkdir -m 700 /tmp/final-wg-rotated-retry
          sudo manager hive network controller rotate activate "$rotation_id" /tmp/final-wg-rotated-retry >/tmp/final.wg.activate.retry.log
          grep -q '^cached_activation=1$' /tmp/final.wg.activate.retry.log
'''
if old not in s:
    raise SystemExit('security final retry anchor missing')
p.write_text(s.replace(old, new, 1))
