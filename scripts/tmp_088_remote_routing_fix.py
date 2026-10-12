from pathlib import Path

# Fix CLI argument preservation after the staged patch is applied.
p = Path('manager')
s = p.read_text()
old = '''              call) [[ -n "${5:-}" && -n "${6:-}" ]] || { err "Uso: manager hive remote controller call NODE_ID ACTION [ARGS...]"; exit 64; }; shift 6; exec "$MANAGER_HOME/modules/hive_remote.sh" --controller-call "$5" "$6" "$@" ;;'''
new = '''              call)
                [[ -n "${5:-}" && -n "${6:-}" ]] || { err "Uso: manager hive remote controller call NODE_ID ACTION [ARGS...]"; exit 64; }
                remote_node="$5"; remote_action="$6"; shift 6
                exec "$MANAGER_HOME/modules/hive_remote.sh" --controller-call "$remote_node" "$remote_action" "$@"
                ;;'''
if old not in s:
    raise SystemExit('manager remote-call anchor missing')
p.write_text(s.replace(old, new, 1))

# Move the new HIVE section after the existing 0.8.7 resilience section and number it 23.
p = Path('docs/HIVE.md')
s = p.read_text()
start = s.find('## 22. Roteamento remoto tipado — fundação 0.8.8\n')
next_heading = s.find('## 21. Accounting global — fundação 0.8.6\n', start)
if start < 0 or next_heading < 0:
    raise SystemExit('staged remote routing section not found before accounting')
section = s[start:next_heading]
s = s[:start] + s[next_heading:]
section = section.replace('## 22. Roteamento remoto tipado — fundação 0.8.8',
                          '## 23. Roteamento remoto tipado — fundação 0.8.8', 1)
s = s.rstrip() + '\n\n' + section.strip() + '\n'
p.write_text(s)
