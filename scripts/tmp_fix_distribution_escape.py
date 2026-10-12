from pathlib import Path

p = Path('modules/hive_allocations.sh')
text = p.read_text()
prefix = '    atomic_write(path, json.dumps(bundle, sort_keys=True, separators=(",", ":")) + "'
suffix = '")\n    return path\n'
start = text.index(prefix) + len(prefix)
end = text.index(suffix, start)
current = text[start:end]
if current != '\n':
    raise SystemExit(f'unexpected queue_bundle newline payload: {current!r}')
text = text[:start] + r'\n' + text[end:]
p.write_text(text)
