#!/usr/bin/env python3
"""Test assisted migration plan without touching system accounts."""
import hashlib
import io
import sys
from pathlib import Path
import tarfile
import tempfile
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tools"))
from migration_plan import plan

with tempfile.TemporaryDirectory() as d:
    folder=Path(d)
    path=folder/"manager-users-test.tar.gz"
    files={"manifest":"format=manager-users-v1\nusers=2\npasswords=shadow-hashes-only\n",
           "users.db":"alice|hash||/bin/bash|1|owner\nbob|hash||/bin/bash|1|owner\n"}
    with tarfile.open(path,"w:gz") as arc:
        for name,contents in files.items():
            raw=contents.encode()
            info=tarfile.TarInfo(name)
            info.size=len(raw)
            arc.addfile(info,io.BytesIO(raw))
    digest=hashlib.sha256(path.read_bytes()).hexdigest()
    Path(str(path)+".sha256").write_text(f"{digest}  {path.name}\n")
    result=plan(path,lambda username: username=="alice")
    assert result["archive_sha256"]==digest
    assert result["blocked_users"]==1 and result["eligible_users"]==1
    assert result["entries"]==[{"username":"alice","decision":"skip-existing"},{"username":"bob","decision":"eligible"}]
    assert result["read_only"] and result["requires_explicit_restore_confirmation"]
    result2=plan(path,lambda username: False)
    assert result2["eligible_users"]==2
    path.write_bytes(b"corrupt")
    try: plan(path,lambda _:False)
    except ValueError: pass
    else: raise AssertionError("corrupt archive accepted")
print("Migration assisted plan tests passed")
