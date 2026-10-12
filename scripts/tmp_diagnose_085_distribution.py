import ast
from pathlib import Path

source = Path('scripts/tmp_patch_085_distribution.py').read_text()
tree = ast.parse(source)
failed = 0
index = 0
for node in ast.walk(tree):
    if not isinstance(node, ast.Call):
        continue
    if not isinstance(node.func, ast.Name) or node.func.id != 'replace_once' or len(node.args) < 3:
        continue
    index += 1
    path = ast.literal_eval(node.args[0])
    old = ast.literal_eval(node.args[1])
    count = Path(path).read_text().count(old)
    print(f'{index:02d} {path}: {count}')
    if count != 1:
        failed += 1
if failed:
    raise SystemExit(f'{failed} patch anchor(s) invalid')
