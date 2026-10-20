#!/usr/bin/env python3
"""Fail-closed approval of a read-only MANAGER SSH migration proposal.

Approval does not restore accounts. It binds a human confirmation to the current
archive digest and to the current NSS collision snapshot.
"""
import argparse
import hmac
import json
from pathlib import Path
import pwd
import sys
from migration_plan import plan


def create_approval(archive, expected_sha256, confirmation, exists):
    if len(expected_sha256) != 64 or any(c not in "0123456789abcdef" for c in expected_sha256):
        raise ValueError("invalid-fingerprint")
    current = plan(archive, exists)
    if not hmac.compare_digest(current["archive_sha256"], expected_sha256):
        raise ValueError("archive-changed")
    if current["blocked_users"]:
        raise ValueError("destination-conflicts")
    expected_confirmation = "APROVAR " + expected_sha256
    if confirmation != expected_confirmation:
        raise ValueError("confirmation-required")
    return {
        "contract": "manager-migration-approval-v1",
        "approved": True,
        "archive_sha256": expected_sha256,
        "eligible_users": current["eligible_users"],
        "read_only": True,
        "restoration_executed": False,
    }


def main():
    parser = argparse.ArgumentParser(description="Authorize a migration plan without applying it")
    parser.add_argument("archive", type=Path)
    parser.add_argument("--expected-sha256", required=True)
    args = parser.parse_args()
    # Read confirmation from stdin, not argv, to avoid exposing it in process listings.
    phrase = sys.stdin.readline(128).rstrip("\r\n")
    def exists(username):
        try:
            pwd.getpwnam(username)
            return True
        except KeyError:
            return False
    try:
        result = create_approval(args.archive, args.expected_sha256, phrase, exists)
    except (OSError, ValueError, UnicodeError) as exc:
        print(json.dumps({"contract":"manager-migration-approval-v1", "approved":False,
                          "error":str(exc) if isinstance(exc, ValueError) else "preflight-failed"}))
        return 1
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
