from pathlib import Path
p=Path('manager'); s=p.read_text()
old='  manager telegram gateway call /CAMINHO/INITDATA /CAMINHO/REQUEST.json | call-stdin /CAMINHO/REQUEST.json\n                                  gateway tipado Telegram -> Automation v2 (0.9.0)\n'
new='  manager telegram gateway call /CAMINHO/INITDATA /CAMINHO/REQUEST.json\n  manager telegram gateway call-stdin /CAMINHO/REQUEST.json\n                                  gateway tipado Telegram -> Automation v2 (0.9.0)\n'
if old not in s: raise SystemExit('manager help anchor missing')
p.write_text(s.replace(old,new,1))
