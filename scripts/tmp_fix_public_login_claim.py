#!/usr/bin/env python3
from pathlib import Path


def replace_once(path, old, new, label):
    p = Path(path)
    text = p.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected 1 anchor, found {count}")
    p.write_text(text.replace(old, new, 1))


replace_once(
    "modules/automation_v2.sh",
    '''        proc = subprocess.run([HIVE_ALLOCATIONS, "--claim", allocation_id], input=token + "\\n", stdin=subprocess.PIPE,\n                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=30, shell=False)\n''',
    '''        proc = subprocess.run([HIVE_ALLOCATIONS, "--claim", allocation_id], input=token + "\\n",\n                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=30, shell=False)\n''',
    "claim stdin",
)

p = Path("modules/hive_allocations.sh")
s = p.read_text()
anchor = '''def provision_bundle(bundle):\n'''
if s.count(anchor) != 1:
    raise SystemExit("recover ssh insertion anchor mismatch")
helper = r'''def recover_ssh_password(bundle, ssh_user):
    if not ssh_user:
        return ""
    candidates = []
    for candidate in Path(NODE_PROVISION_DIR).glob("*.conf"):
        try:
            st = os.lstat(candidate)
        except FileNotFoundError:
            continue
        if not stat.S_ISREG(st.st_mode) or st.st_uid != 0 or stat.S_IMODE(st.st_mode) & 0o077:
            continue
        receipt = read_conf(str(candidate))
        if (receipt.get("status") == "ok" and receipt.get("identity_id") == bundle.get("identity_id") and
                receipt.get("product_id") == bundle.get("product_id") and receipt.get("protocol") == "ssh" and
                receipt.get("ssh_user") == ssh_user and receipt.get("ssh_password")):
            try:
                epoch = int(receipt.get("provisioned_epoch", "0"))
            except ValueError:
                epoch = 0
            candidates.append((epoch, receipt.get("ssh_password", "")))
    if not candidates:
        return ""
    candidates.sort(reverse=True)
    return candidates[0][1]


'''
s = s.replace(anchor, helper + anchor, 1)
old = '''    provisioned_protocols=result.get("protocols","").split(",")\n    if bundle["protocol"] not in provisioned_protocols: die("Provisionamento local não confirmou o protocolo da allocation.",70)\n    lines=["version=1","status=ok",f"allocation_id={bundle['allocation_id']}",f"identity_id={bundle['identity_id']}",\n'''
new = '''    provisioned_protocols=result.get("protocols","").split(",")\n    if bundle["protocol"] not in provisioned_protocols: die("Provisionamento local não confirmou o protocolo da allocation.",70)\n    if bundle["protocol"] == "ssh" and not result.get("ssh_password"):\n        recovered_password = recover_ssh_password(bundle, result.get("ssh_user", ""))\n        if recovered_password:\n            result["ssh_password"] = recovered_password\n            result["credential_recovered"] = "1"\n    lines=["version=1","status=ok",f"allocation_id={bundle['allocation_id']}",f"identity_id={bundle['identity_id']}",\n'''
if s.count(old) != 1:
    raise SystemExit("ssh recovery use anchor mismatch")
s = s.replace(old, new, 1)
p.write_text(s)
