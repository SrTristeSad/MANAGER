#!/usr/bin/env python3
"""Read-only destination username conflict report for MANAGER SSH migration."""
import argparse
import json
from pathlib import Path
import pwd
import sys
import tarfile
from migration_preflight import inspect


def conflicts(archive, destination_users):
    validation = inspect(archive)
    if not validation["ok"]:
        raise ValueError("archive-invalid")
    with tarfile.open(archive, "r:gz") as handle:
        rows = handle.extractfile("users.db").read().decode("utf-8").splitlines()
    names = [row.split("|", 1)[0] for row in rows]
    existing = set(destination_users)
    collisions = sorted(set(names) & existing)
    return {"contract": "manager-migration-conflicts-v1",
            "ok": not bool(collisions),
            "source_users": len(names),
            "conflicts": collisions,
            "ready_users": len(names) - len(collisions),
            "read_only": True}


def main():
    parser = argparse.ArgumentParser(description="Check SSH username collisions without restoring accounts")
    parser.add_argument("archive", type=Path)
    args = parser.parse_args()
    try:
        # Use NSS to include system and network-backed account names.
        output = conflicts(args.archive, (entry.pw_name for entry in pwd.getpwall()))
    except (OSError, ValueError, UnicodeError, tarfile.TarError):
        print(json.dumps({"contract": "manager-migration-conflicts-v1",
                          "ok": False, "error": "preflight-failed", "read_only": True}))
        return 1
    print(json.dumps(output, sort_keys=True))
    return 0 if output["ok"] else 2


if __name__ == "__main__":
    sys.exit(main())
