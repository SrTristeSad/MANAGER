#!/usr/bin/env python3
"""Read-only preflight for MANAGER SSH user migration archives."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import tarfile

LIMIT = 64 * 1024 * 1024
ALLOWED = {"manifest", "users.db"}
USERNAME = re.compile(r"^[a-z_][a-z0-9_-]{0,31}$")


def inspect(path):
    result = {"contract": "manager-migration-preflight-v1", "ok": False,
              "format": "manager-users-v1", "users": 0}
    if path.is_symlink() or not path.is_file():
        raise ValueError("archive-not-regular")
    size = path.stat().st_size
    if not (0 < size <= LIMIT):
        raise ValueError("archive-size-invalid")
    sidecar = Path(str(path) + ".sha256")
    if sidecar.is_symlink() or not sidecar.is_file():
        raise ValueError("checksum-missing")
    checksum = sidecar.read_text(encoding="ascii")
    match = re.fullmatch(r"([a-fA-F0-9]{64})  ([^/\\\r\n]+)\n?", checksum)
    if not match or match.group(2) != path.name:
        raise ValueError("checksum-format-invalid")
    h = hashlib.sha256()
    with path.open("rb") as file:
        for block in iter(lambda: file.read(1024 * 1024), b""):
            h.update(block)
    if h.hexdigest() != match.group(1).lower():
        raise ValueError("checksum-mismatch")
    try:
        with tarfile.open(path, "r:gz") as archive:
            members = archive.getmembers()
            if len(members) != 2 or {m.name for m in members} != ALLOWED:
                raise ValueError("archive-entries-invalid")
            if any(not m.isfile() or m.size < 0 or m.size > LIMIT for m in members):
                raise ValueError("archive-type-invalid")
            manifest = archive.extractfile("manifest").read(8193)
            database = archive.extractfile("users.db").read(LIMIT + 1)
    except (tarfile.TarError, OSError, EOFError) as exc:
        raise ValueError("archive-invalid") from exc
    if len(manifest) > 8192 or len(database) > LIMIT:
        raise ValueError("archive-uncompressed-size-invalid")
    try:
        fields = dict(line.split("=", 1) for line in manifest.decode("utf-8").splitlines())
        lines = database.decode("utf-8").splitlines()
    except (UnicodeDecodeError, ValueError) as exc:
        raise ValueError("archive-data-invalid") from exc
    if fields.get("format") != "manager-users-v1" or fields.get("passwords") != "shadow-hashes-only":
        raise ValueError("manifest-invalid")
    if not fields.get("users", "").isdigit() or int(fields["users"]) != len(lines):
        raise ValueError("user-count-invalid")
    seen = set()
    for line in lines:
        parts = line.split("|")
        if len(parts) != 6 or not USERNAME.fullmatch(parts[0]) or parts[0] == "root":
            raise ValueError("user-entry-invalid")
        if parts[0] in seen or any("\x00" in part or "\n" in part for part in parts):
            raise ValueError("user-entry-invalid")
        seen.add(parts[0])
    result.update(ok=True, users=len(lines))
    return result


def main():
    parser = argparse.ArgumentParser(description="Validate SSH migration archive without restoring users")
    parser.add_argument("archive", type=Path)
    args = parser.parse_args()
    try:
        response = inspect(args.archive)
    except (OSError, ValueError) as exc:
        response = {"contract": "manager-migration-preflight-v1", "ok": False,
                    "error": str(exc) if isinstance(exc, ValueError) else "io-error"}
    print(json.dumps(response, separators=(",", ":"), sort_keys=True))
    return 0 if response["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
