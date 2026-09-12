#!/usr/bin/env python3
"""Print `<runtime-id> <devicetype-id> <name>` for an App Store screenshot
simulator compatible with the newest available iOS runtime.

  pick_ipad_sim.py [ipad|iphone]     (default: ipad)

ipad   → iPad Pro 12.9"/13"  (2048x2732 / 2064x2752, covers all iPads)
iphone → iPhone … Pro Max    (1320x2868 / 1290x2796, the 6.9"/6.7" slot)

Picking a device type by name alone can match the ancient "iPad Pro (12.9-inch)"
that can't run iOS 26 ("Incompatible device"). Selecting from the chosen
runtime's own supportedDeviceTypes guarantees the pairing boots.
"""
import json
import subprocess
import sys


def _is_ipad(name: str) -> bool:
    return "iPad Pro" in name and ("13-inch" in name or "12.9" in name)


def _is_iphone(name: str) -> bool:
    return name.startswith("iPhone") and "Pro Max" in name


def main() -> int:
    kind = (sys.argv[1] if len(sys.argv) > 1 else "ipad").lower()
    match = {"ipad": _is_ipad, "iphone": _is_iphone}.get(kind)
    if match is None:
        sys.exit("usage: pick_ipad_sim.py [ipad|iphone]")
    rts = json.loads(
        subprocess.check_output(["xcrun", "simctl", "list", "runtimes", "-j"])
    )["runtimes"]
    ios = [r for r in rts if r.get("platform") == "iOS" and r.get("isAvailable")]
    if not ios:
        sys.exit("no available iOS runtime")
    r = sorted(ios, key=lambda x: x.get("version", ""))[-1]
    cands = [d for d in r.get("supportedDeviceTypes", []) if match(d["name"])]
    if not cands:
        sys.exit(f"no compatible {kind} device type for " + r["identifier"])
    d = cands[-1]
    print(r["identifier"], d["identifier"], d["name"].replace(" ", "_"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
