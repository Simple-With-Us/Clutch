#!/usr/bin/env python3
import argparse
import json
import os
from pathlib import Path


HOME = os.environ.get("CLUTCH_SERVICE_HOME") or str(Path.home())
CODE_ROOT = os.environ.get("FLEET_CODE_ROOT") or str(Path.home() / "Code")
MAIN_SOURCE = os.environ.get("CLUTCH_MAIN_SOURCE") or str(Path(CODE_ROOT) / "Clutch")


def facts(pid, release):
    proc = Path(f"/proc/{pid}")
    status = (proc / "status").read_text(encoding="utf-8").splitlines()
    uid_line = next((line for line in status if line.startswith("Uid:")), "")
    uid = int(uid_line.split()[1]) if uid_line else -1
    argv = [os.fsdecode(arg) for arg in (proc / "cmdline").read_bytes().split(b"\0") if arg]
    joined = "\0".join(argv)
    cgroup = (proc / "cgroup").read_text(encoding="utf-8")
    env = {}
    infisical_present = False
    for item in (proc / "environ").read_bytes().split(b"\0"):
        if b"=" not in item:
            continue
        key, value = item.split(b"=", 1)
        name = key.decode("ascii", "ignore")
        if name.startswith(("INFISICAL_", "CLUTCH_INFISICAL_")):
            infisical_present = True
        if name in {"HOME", "CLUTCH_HOME", "CLUTCH_RUNTIME_ROOT"}:
            env[name] = value.decode("utf-8", "replace")
    try:
        cwd = os.readlink(proc / "cwd")
    except OSError:
        cwd = None
    return {
        "pid": pid,
        "uid": uid,
        "cgroupMatchesClutchUnit": f"/{'clutch-chat-bridge.service'}" in cgroup,
        "cwd": cwd,
        "entrypointRelease": f"{release}/src/web/chat-bridge.ts" in joined,
        "tsxRelease": f"{release}/node_modules" in joined and "tsx" in joined,
        "entrypointBase": f"{MAIN_SOURCE}/src/web/chat-bridge.ts" in joined,
        "homeExpectedForClutch": env.get("HOME") == HOME,
        "clutchHomeExpected": env.get("CLUTCH_HOME") == f"{HOME}/.clutch",
        "runtimeRootMatchesRelease": env.get("CLUTCH_RUNTIME_ROOT") == release,
        "infisicalVariablesPresent": infisical_present,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--release", required=True)
    parser.add_argument("--pid", action="append", type=int, required=True)
    args = parser.parse_args()
    values = []
    for pid in sorted(set(args.pid)):
        try:
            values.append(facts(pid, args.release))
        except Exception as error:
            values.append({"pid": pid, "readErrorType": type(error).__name__})
    print(json.dumps(values, separators=(",", ":")))


if __name__ == "__main__":
    main()
