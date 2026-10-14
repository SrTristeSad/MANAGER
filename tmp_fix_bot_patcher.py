from pathlib import Path
p=Path('tmp_patch_telegram_bot_ingress.py')
s=p.read_text()
old=' | call-stdin /CAMINHO/REQUEST.json\\n                                  gateway tipado Telegram -> Automation v2 (0.9.0)'
new='\\n  manager telegram gateway call-stdin /CAMINHO/REQUEST.json\\n                                  executa ações tipadas via Automation v2 sem shell arbitrário (0.9.0)'
if old not in s:
    raise SystemExit('help anchor fragment missing')
p.write_text(s.replace(old,new,1))
