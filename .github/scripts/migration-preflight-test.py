#!/usr/bin/env python3
"""Regression tests for read-only MANAGER archive preflight."""
import hashlib
import io
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile

SCRIPT = Path(__file__).resolve().parents[2] / "tools/migration_preflight.py"


def archive_at(folder, entries):
    path = folder / "manager-users-test.tar.gz"
    with tarfile.open(path, "w:gz") as tar:
        for name, contents in entries.items():
            data = contents.encode()
            info = tarfile.TarInfo(name)
            info.size = len(data)
            tar.addfile(info, io.BytesIO(data))
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    Path(str(path) + ".sha256").write_text(f"{digest}  {path.name}\n")
    return path


def check(path, expected):
    run = subprocess.run([sys.executable, str(SCRIPT), str(path)],
                         capture_output=True, text=True, check=False)
    import json
    data = json.loads(run.stdout)
    assert data["ok"] is expected, (run.returncode, data)
    assert (run.returncode == 0) is expected


manifest = "format=manager-users-v1\nusers=1\npasswords=shadow-hashes-only\n"
with tempfile.TemporaryDirectory() as temp:
    folder = Path(temp)
    safe = archive_at(folder, {"manifest": manifest, "users.db": "alice|hash||/bin/bash|1|owner\n"})
    check(safe, True)
    digest = hashlib.sha256(safe.read_bytes()).hexdigest()
    Path(str(safe) + ".sha256").write_text(f"{digest}  {safe.resolve()}\\n")
    check(safe, True)
    Path(str(safe) + ".sha256").write_text("0" * 64 + f"  {safe.name}\n")
    check(safe, False)
    safe = archive_at(folder, {"manifest": manifest, "users.db": "root|hash||/bin/bash|1|owner\n"})
    check(safe, False)
    safe = archive_at(folder, {"manifest": manifest, "users.db": "alice|hash||/bin/bash|1|owner\n",
                               "../escape": "evil"})
    check(safe, False)
    safe = archive_at(folder, {"manifest": manifest.replace("users=1", "users=2"),
                               "users.db": "alice|hash||/bin/bash|1|owner\n"})
    check(safe, False)
print("Migration preflight archive tests passed")
