from pathlib import Path
p=Path('docs/ROADMAP.md')
s=p.read_text()
old='Ingresso Telegram Bot implementado nesta fatia:\n\n- long polling HTTPS com a Telegram Bot API sem listener público adicional;'
new='Ingresso Telegram Bot implementado nesta fatia:\n\n- ingresso autenticado do Telegram Bot por long polling HTTPS, reutilizando o gateway tipado;\n- long polling HTTPS com a Telegram Bot API sem listener público adicional;'
if old not in s:
    raise SystemExit('roadmap anchor missing')
p.write_text(s.replace(old,new,1))
