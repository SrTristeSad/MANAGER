import ast
from pathlib import Path

# Normalize only the two legacy anchors that embed Python string escapes.
src_path = Path('scripts/tmp_patch_085_distribution.py')
source = src_path.read_text()
tree = ast.parse(source)
calls = [
    node for node in tree.body
    if isinstance(node, ast.Expr)
    and isinstance(node.value, ast.Call)
    and isinstance(node.value.func, ast.Name)
    and node.value.func.id == 'replace_once'
]
if len(calls) != 28:
    raise SystemExit(f'unexpected replace_once count: {len(calls)}')

lines = source.splitlines(True)
for ordinal in (14, 12):
    node = calls[ordinal - 1]
    start, end = node.lineno - 1, node.end_lineno
    block = ''.join(lines[start:end])
    block = block.replace(r'\n', r'\\n')
    lines[start:end] = [block]

fixed = ''.join(lines)
Path('/tmp/fixed_patch_085_distribution.py').write_text(fixed)

fixed_tree = ast.parse(fixed)
index = 0
failed = 0
for node in fixed_tree.body:
    if not (isinstance(node, ast.Expr) and isinstance(node.value, ast.Call)
            and isinstance(node.value.func, ast.Name) and node.value.func.id == 'replace_once'):
        continue
    index += 1
    call = node.value
    path = ast.literal_eval(call.args[0])
    old = ast.literal_eval(call.args[1])
    count = Path(path).read_text().count(old)
    print(f'{index:02d} {path}: {count}')
    if count != 1:
        failed += 1
if failed:
    raise SystemExit(f'{failed} normalized patch anchor(s) invalid')
