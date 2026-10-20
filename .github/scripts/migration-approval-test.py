#!/usr/bin/env python3
"""Hermetic migration plan approval tests."""
import hashlib
import io
import sys
import tarfile
import tempfile
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tools"))
from migration_approval import create_approval

with tempfile.TemporaryDirectory() as temp:
    archive = Path(temp) / "manager-users-approval.tar.gz"
    files = {"manifest":"format=manager-users-v1\nusers=1\npasswords=shadow-hashes-only\n",
             "users.db":"alice|hash||/bin/bash|1|owner\n"}
    with tarfile.open(archive,"w:gz") as handle:
        for name, content in files.items():
            data=content.encode()
            item=tarfile.TarInfo(name)
            item.size=len(data)
            handle.addfile(item,io.BytesIO(data))
    digest=hashlib.sha256(archive.read_bytes()).hexdigest()
    Path(str(archive)+".sha256").write_text(f"{digest}  {archive.name}\n")
    def denied(action):
        try: action()
        except ValueError: pass
        else: raise AssertionError("unsafe approval accepted")
    denied(lambda: create_approval(archive,digest,"",lambda name:False))
    denied(lambda: create_approval(archive,"0"*64,"APROVAR "+"0"*64,lambda name:False))
    denied(lambda: create_approval(archive,digest,"APROVAR "+digest,lambda name:True))
    valid=create_approval(archive,digest,"APROVAR "+digest,lambda name:False)
    assert valid["approved"] and valid["eligible_users"]==1
    assert valid["read_only"] and valid["restoration_executed"] is False
    archive.write_bytes(b"corrupt")
    denied(lambda: create_approval(archive,digest,"APROVAR "+digest,lambda name:False))
print("Migration approval gate tests passed")
