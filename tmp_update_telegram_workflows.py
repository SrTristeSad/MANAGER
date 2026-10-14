from pathlib import Path

for name in ('.github/workflows/telegram-identity.yml', '.github/workflows/telegram-initdata-auth.yml'):
    p=Path(name)
    text=p.read_text()
    old="          grep -q 'gateway Bot/Mini App consumindo apenas ações tipadas/allowlisted' docs/ROADMAP.md\n"
    new=("          grep -q 'manager-telegram-gateway-request-v1' docs/ROADMAP.md\n"
         "          grep -q 'ingresso autenticado do Telegram Bot' docs/ROADMAP.md\n")
    if old not in text:
        raise SystemExit(f'stale Telegram roadmap assertion not found in {name}')
    p.write_text(text.replace(old,new,1))
print('telegram workflow assertions updated')
