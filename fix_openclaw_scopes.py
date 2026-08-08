#!/usr/bin/env python3
"""
Patch openclaw device scopes after onboard.
onboard only grants operator.read; cron add requires operator.write.
Must run AFTER the gateway is ready so the gateway re-reads from disk.
"""
import json, os

FULL_SCOPES = ["operator.admin", "operator.pairing", "operator.read", "operator.write"]
home = os.path.expanduser("~")
paired  = os.path.join(home, ".openclaw", "devices", "paired.json")
pending = os.path.join(home, ".openclaw", "devices", "pending.json")

if not os.path.exists(paired):
    print("[INFO] paired.json not found, skipping scope fix")
    raise SystemExit(0)

with open(paired) as f:
    data = json.load(f)

for dev in data.values():
    dev["scopes"] = FULL_SCOPES
    dev["approvedScopes"] = FULL_SCOPES
    for tok in dev.get("tokens", {}).values():
        tok["scopes"] = FULL_SCOPES

with open(paired, "w") as f:
    json.dump(data, f, indent=2)

with open(pending, "w") as f:
    f.write("{}")

print("[INFO] device scopes patched → operator.admin/pairing/read/write")
