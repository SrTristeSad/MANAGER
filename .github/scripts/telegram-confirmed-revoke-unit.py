#!/usr/bin/env python3
"""Hermetic security regression tests for Telegram revoke confirmation."""
import ast
import json
import os
from pathlib import Path
import re
import secrets
import stat
import tempfile
import time

SOURCE = Path(__file__).resolve().parents[2] / "modules" / "telegram_bot.sh"
script = SOURCE.read_text(encoding="utf-8")
marker = "<<'PY'\n"
assert script.count(marker) >= 1
start = script.index(marker, script.index("poll_once()")) + len(marker)
end = script.index("\nPY\n", start)
python_source = script[start:end]
tree = ast.parse(python_source)
names = {"command_for", "pending_path", "write_pending", "read_pending", "clear_pending", "secure_file"}
selected = [node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name in names]
assert {node.name for node in selected} == names
with tempfile.TemporaryDirectory() as folder:
    env = {
        "os": os, "json": json, "stat": stat, "Path": Path,
        "re": re, "secrets": secrets, "tempfile": tempfile, "time": time,
        "bot_dir": folder,
        "ID_RE": re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,47}$"),
        "CONFIRM_RE": re.compile(r"^[a-f0-9]{16}$"),
        "PENDING_TTL_SECONDS": 120,
        "READ_COMMANDS": {"/nodes":"nodes","/diagnostics":"diagnostics"},
        "SCOPED_COMMANDS": {"/clients":"clients","/products":"products","/sessions":"sessions","/quotas":"quotas"},
    }
    exec(compile(ast.Module(body=selected, type_ignores=[]), str(SOURCE), "exec"), env)
    parse = env["command_for"]
    assert parse("/revoke alice") == ("revoke-propose", "", {"id":"alice"})
    assert parse("/revoke alice;reboot")[0] == "help"
    assert parse("/confirm bad")[0] == "help"
    assert parse("/cancel") == ("revoke-cancel", "", {})
    assert parse("/status alice") == ("status", "connection.status", {"id":"alice"})
    uid_a, uid_b = 123456789, 987654321
    code = env["write_pending"](uid_a, "alice")
    assert re.fullmatch(r"[a-f0-9]{16}", code)
    assert parse("/confirm " + code) == ("revoke-confirm", "", {"code":code})
    path = Path(env["pending_path"](uid_a))
    assert stat.S_IMODE(path.stat().st_mode) == 0o600
    assert env["read_pending"](uid_a, code) == "alice"
    assert env["read_pending"](uid_b, code) is None
    assert env["read_pending"](uid_a, "0"*16) is None
    record = json.loads(path.read_text())
    record["expires"] = int(time.time()) - 1
    path.write_text(json.dumps(record))
    assert env["read_pending"](uid_a, code) is None
    code2 = env["write_pending"](uid_a, "bob")
    assert env["read_pending"](uid_a, code) is None
    assert env["read_pending"](uid_a, code2) == "bob"
    env["clear_pending"](uid_a)
    assert env["read_pending"](uid_a, code2) is None
    # Tampering with mode must fail closed.
    code3 = env["write_pending"](uid_a, "alice")
    path.chmod(0o644)
    assert env["read_pending"](uid_a, code3) is None
    env["clear_pending"](uid_a)
print("Telegram revoke confirmation security unit tests passed")
