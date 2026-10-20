#!/usr/bin/env python3
"""Prepare a read-only, fingerprinted SSH migration proposal.

This tool never creates users or executes restoration.
"""
import argparse
import hashlib
import json
from pathlib import Path
import pwd
import sys
import tarfile

from migration_preflight import inspect


def plan(archive, exists):
    if not inspect(archive)["ok"]:
        raise ValueError("archive-invalid")
    with tarfile.open(archive, "r:gz") as handle:
        names = [row.split("|", 1)[0] for row in handle.extractfile("users.db").read().decode("utf-8").splitlines()]
    entries = []
    for name in sorted(names):
        entries.append({"username": name, "decision": "skip-existing" if exists(name) else "eligible"})
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    blocked = sum(entry["decision"] == "skip-existing" for entry in entries)
    return {"contract": "manager-migration-plan-v1", "archive_sha256": digest,
            "source_users": len(entries), "eligible_users": len(entries) - blocked,
            "blocked_users": blocked, "entries": entries, "read_only": True,
            "requires_explicit_restore_confirmation": True}


def main():
    parser = argparse.ArgumentParser(description="Create read-only SSH migration proposal")
    parser.add_argument("archive", type=Path)
    args = parser.parse_args()
    def exists(name):
        try:
            pwd.getpwnam(name)
            return True
        except KeyError:
            return False
    try:
        result = plan(args.archive, exists)
    except (OSError, ValueError, UnicodeError, tarfile.TarError):
        print(json.dumps({"contract":"manager-migration-plan-v1", "ok": False, "error":"preflight-failed"}))
        return 1
    print(json.dumps({"ok":True, **result}, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
