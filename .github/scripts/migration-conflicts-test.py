#!/usr/bin/env python3
"""Tests for read-only destination SSH username conflict checking."""
import hashlib
import io
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile

TOOLS = Path(__file__).resolve().parents[2] / "tools"
sys.path.insert(0, str(TOOLS))
from migration_conflicts import conflicts

MANIFEST = "format=manager-users-v1\nusers=2\npasswords=shadow-hashes-only\n"


def create_archive(folder):
    target = folder / "manager-users-fixture.tar.gz"
    with tarfile.open(target, "w:gz") as tf:
        for name, raw in (
            ("manifest", MANIFEST),
            ("users.db", "alice|hash||/bin/bash|1|owner\nbob|hash||/bin/bash|1|owner\n"),
        ):
            encoded = raw.encode("utf-8")
            info = tarfile.TarInfo(name)
            info.size = len(encoded)
            tf.addfile(info, io.BytesIO(encoded))
    digest = hashlib.sha256(target.read_bytes()).hexdigest()
    Path(str(target) + ".sha256").write_text(f"{digest}  {target.name}\n")
    return target


with tempfile.TemporaryDirectory() as temp:
    path = create_archive(Path(temp))
    safe = conflicts(path, set())
    assert safe == {"contract": "manager-migration-conflicts-v1", "ok": True,
                    "source_users": 2, "conflicts": [], "ready_users": 2, "read_only": True}
    collision = conflicts(path, {"alice", "system"})
    assert collision["ok"] is False and collision["conflicts"] == ["alice"]
    assert collision["ready_users"] == 1
    both = conflicts(path, {"bob", "alice"})
    assert both["conflicts"] == ["alice", "bob"] and both["ready_users"] == 0
    checksum = Path(str(path) + ".sha256")
    checksum.write_text("0" * 64 + f"  {path.name}\n")
    try:
        conflicts(path, set())
    except ValueError:
        pass
    else:
        raise AssertionError("corrupted archive accepted")
print("Migration destination conflicts tests passed")
