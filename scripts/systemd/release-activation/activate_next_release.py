#!/usr/bin/env python3
"""Guarded activation helper for the next Clutch Linux release."""

import argparse
import hashlib
import importlib.util
import json
import os
import shutil
import stat
import sys
import time
from pathlib import Path


HERE = Path(__file__).resolve().parent
BASE_PATH = HERE / "activate_release.py"
spec = importlib.util.spec_from_file_location("clutch_rollout_base", BASE_PATH)
base = importlib.util.module_from_spec(spec)
assert spec and spec.loader
spec.loader.exec_module(base)

UNIT = base.UNIT
PORT = base.PORT
RELEASES = base.RELEASES_ROOT
SERVICE_USER = base.SERVICE_USER
SERVICE_HOME = base.SERVICE_HOME
CLUTCH_STATE_HOME = base.CLUTCH_STATE_HOME
# The release being replaced, which a rollback returns to.
OLD_SHA = os.environ.get("CLUTCH_PREVIOUS_RELEASE_SHA", "")
OLD_RELEASE = RELEASES / OLD_SHA
OLD_DROPIN = Path(f"/etc/systemd/system/clutch-chat-bridge.service.d/20-clutch-{OLD_SHA[:7]}-release.conf")
OLD_DROPIN_SHA256 = os.environ.get("CLUTCH_PREVIOUS_DROPIN_SHA256", "")
STABLE_DROPIN_NAME = "20-clutch-release.conf"
DROPIN_DIR = OLD_DROPIN.parent
STABLE_DROPIN = DROPIN_DIR / STABLE_DROPIN_NAME
UNIT_PATH = Path("/etc/systemd/system/clutch-chat-bridge.service")
# Hashes of the host's runtime CPU drop-ins, as a JSON object of path to sha256.
# They are machine state, so they come from the environment.
CPU_DROPIN_HASHES = json.loads(os.environ.get("CLUTCH_CPU_DROPIN_HASHES", "{}"))


def fail(stage, **flags):
    raise base.RolloutStop(stage, flags)


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def configure(args):
    if len(args.release_sha) != 40 or any(ch not in "0123456789abcdef" for ch in args.release_sha):
        fail("arguments", releaseShaValid=False)
    if len(OLD_SHA) != 40 or not OLD_DROPIN_SHA256:
        fail("arguments", previousReleaseConfigured=False)
    if args.release_sha == OLD_SHA:
        fail("arguments", newReleaseDiffersFromRollbackTarget=False)
    release = RELEASES / args.release_sha
    review = release / "deployment/review"
    candidate = review / STABLE_DROPIN_NAME
    lock = review / "production-rollout.lock"
    before = review / "production-before.json"
    receipt = review / "production-receipt.json"
    failure = review / "production-failure.json"
    backup = review / "backup-before-activation"
    return release, review, candidate, lock, before, receipt, failure, backup


def verify_artifact(args, release, candidate):
    review = release / "deployment/review"
    if not release.is_dir() or (release / ".git").exists():
        fail("release-artifact", nonGitArtifact=False)
    manifest = json.loads((review / "provenance.json").read_text(encoding="utf-8"))
    checks = {
        "sourceCommit": args.release_sha,
        "sourceTree": args.source_tree,
        "sourceArchiveSha256": args.source_archive_sha256,
        "packageLockSha256": args.package_lock_sha256,
    }
    if any(manifest.get(key) != value for key, value in checks.items()):
        fail("release-manifest", pinnedMetadataMatches=False)
    if digest(release / "package-lock.json") != args.package_lock_sha256:
        fail("release-package-lock", packageLockHashMatches=False)
    if digest(candidate) != args.dropin_sha256:
        fail("release-dropin", candidateDropInHashMatches=False)
    expected_content = (
        "# Candidate only; not installed or activated\n"
        "[Service]\n"
        f"WorkingDirectory={release}\n"
        "ExecStart=\n"
        f"ExecStart={release}/scripts/chat-bridge.sh\n"
    ).encode()
    if candidate.read_bytes() != expected_content:
        fail("release-dropin", candidateDropInContentMatchesRelease=False)
    return manifest


def cpu_dropins_current():
    metadata = base.dropin_metadata(list(CPU_DROPIN_HASHES))
    return all(item["present"] and item["sha256"] == CPU_DROPIN_HASHES[item["path"]] for item in metadata), metadata


def current_processes(unit, target):
    infos = base.listener_process_infos(unit, target)
    service_uid = os.stat(SERVICE_HOME).st_uid
    if not infos or any(
        info["uid"] != service_uid or not info["inServiceCgroup"] or info["cwd"] != str(target)
        or not info["entrypointRelease"] or not info["tsxRelease"] or info["entrypointBase"]
        for info in infos
    ):
        fail("process-state", exactReleaseProcesses=False)
    for info in infos:
        env = info["selectedEnvironment"]
        if env.get("HOME") != str(SERVICE_HOME) or env.get("CLUTCH_HOME") != str(CLUTCH_STATE_HOME) or env.get("CLUTCH_RUNTIME_ROOT") != str(target):
            fail("process-environment", homeAndRuntimePreserved=False)
    return infos


def assert_unit(unit, target, expected_dropins):
    if (unit["id"] != UNIT or unit["activeState"] != "active" or unit["subState"] != "running"
            or unit["user"] != SERVICE_USER or unit["workingDirectory"] != str(target)
            or not unit["execStartReleaseLauncher"] or unit["execStartBaseLauncher"]):
        fail("unit-state", exactReleaseUnit=False)
    if set(unit["dropInPaths"]) != set(expected_dropins):
        fail("unit-dropins", exactDropinSet=False)
    if unit["environmentKeys"] != ["CLUTCH_HOME", "HOME"] or unit["environmentFileCount"] != 0:
        fail("unit-environment", preservedEnvironment=False)


def exact_health(token, stage):
    try:
        return base.health(token, require_active_zero=True)
    except base.RolloutStop as error:
        if "activeTurnsReported" in error.flags:
            fail(stage, activeTurnsReported=error.flags.get("activeTurnsReported"), activeTurns=error.flags.get("activeTurns"))
        raise


def retryable_health_failure(error):
    if "activeTurnsReported" in error.flags:
        return False
    return error.step == "authenticated-health" and (
        error.flags.get("errorType") == "URLError" or error.flags.get("httpStatus") in {502, 503, 504}
    )


def verify_current_attempt_paths(config, attempt):
    release, review, candidate, lock, before, receipt, failure, backup = config
    try:
        lock_stat = os.stat(lock, follow_symlinks=False)
        before_stat = os.stat(before, follow_symlinks=False)
        backup_stat = os.stat(backup, follow_symlinks=False)
        dropins_stat = os.stat(backup / "dropins", follow_symlinks=False)
    except OSError:
        fail("last-moment-owned-artifacts", currentAttemptArtifactsPresent=False)
    if (not stat.S_ISDIR(lock_stat.st_mode) or lock_stat.st_uid != os.getuid()
            or stat.S_IMODE(lock_stat.st_mode) != 0o700
            or (lock_stat.st_dev, lock_stat.st_ino) != attempt["lockIdentity"]
            or any(lock.iterdir())):
        fail("last-moment-owned-lock", currentAttemptLockIdentityMatches=False)
    if (not stat.S_ISREG(before_stat.st_mode) or before_stat.st_uid != os.getuid()
            or stat.S_IMODE(before_stat.st_mode) != 0o600 or digest(before) != attempt["beforeSha256"]):
        fail("last-moment-before-receipt", currentAttemptReceiptMatches=False)
    if (not stat.S_ISDIR(backup_stat.st_mode) or backup_stat.st_uid != os.getuid()
            or stat.S_IMODE(backup_stat.st_mode) != 0o700):
        fail("last-moment-backup", currentAttemptBackupDirectoryValid=False)
    if {item.name for item in backup.iterdir()} != {"clutch-chat-bridge.service.before", "dropins"}:
        fail("last-moment-backup", currentAttemptBackupContentsExact=False)
    unit_backup = backup / "clutch-chat-bridge.service.before"
    unit_backup_stat = os.stat(unit_backup, follow_symlinks=False)
    if (not stat.S_ISREG(unit_backup_stat.st_mode) or unit_backup_stat.st_uid != os.getuid()
            or digest(unit_backup) != attempt["unitSha256"] or digest(UNIT_PATH) != attempt["unitSha256"]):
        fail("last-moment-backup", currentAttemptUnitBackupMatches=False)
    expected = {Path(item["backup"]).name: item["sha256"] for item in attempt["dropInBackups"]}
    backup_dropins = backup / "dropins"
    if (not stat.S_ISDIR(dropins_stat.st_mode) or dropins_stat.st_uid != os.getuid()
            or stat.S_IMODE(dropins_stat.st_mode) != 0o700
            or {item.name for item in backup_dropins.iterdir()} != set(expected)):
        fail("last-moment-backup", currentAttemptDropInBackupSetExact=False)
    backup_files_valid = True
    for name, sha in expected.items():
        path = backup_dropins / name
        info = os.stat(path, follow_symlinks=False)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or digest(path) != sha:
            backup_files_valid = False
            break
    if not backup_files_valid:
        fail("last-moment-backup", currentAttemptDropInBackupMatches=False)
    if receipt.exists() or failure.exists():
        fail("last-moment-owned-artifacts", priorTerminalReceiptPresent=True)


def preflight(args, config, current_attempt=None):
    release, review, candidate, lock, before, receipt, failure, backup = config
    manifest = verify_artifact(args, release, candidate)
    if current_attempt is None and (lock.exists() or before.exists() or receipt.exists() or failure.exists() or backup.exists()):
        fail("rollout-paths", lockAbsent=not lock.exists(), receiptPathsAbsent=not before.exists() and not receipt.exists() and not failure.exists(), backupAbsent=not backup.exists())
    if current_attempt is not None:
        verify_current_attempt_paths(config, current_attempt)
    # The current drop-in is the stable name once a guarded transition has
    # run, or the per-SHA name the first-time activator used.  Accept either
    # so repeat activations pass preflight; the hash pin is unchanged.
    old_dropin = STABLE_DROPIN if STABLE_DROPIN.is_file() else OLD_DROPIN
    old_dropin_ok = old_dropin.is_file() and digest(old_dropin) == OLD_DROPIN_SHA256
    if not old_dropin_ok:
        fail("current-dropin-cas", oldDropInMatchesExpected=old_dropin_ok, stableDropInAbsent=not STABLE_DROPIN.exists())
    old_unit = base.unit_snapshot(OLD_RELEASE)
    expected_current = set(CPU_DROPIN_HASHES) | {str(old_dropin)}
    assert_unit(old_unit, OLD_RELEASE, expected_current)
    cpu_ok, cpu_metadata = cpu_dropins_current()
    if not cpu_ok:
        fail("cpu-dropins", cpuDropInsMatchVerifiedBaseline=False)
    processes = current_processes(old_unit, OLD_RELEASE)
    token, token_metadata = base.safe_token_file()
    health = exact_health(token, "preflight-health")
    sockets = base.socket_summary()
    if not sockets["loopbackListener"] or sockets["web3180ListenerCount"] or sockets["establishedCount"]:
        fail("preflight-sockets", loopback3181=sockets["loopbackListener"], web3180Absent=sockets["web3180ListenerCount"] == 0, establishedConnections=sockets["establishedCount"])
    if old_unit["environmentValues"].get("HOME") != str(SERVICE_HOME) or old_unit["environmentValues"].get("CLUTCH_HOME") != str(CLUTCH_STATE_HOME):
        fail("preflight-home", homeAndClutchHomePreserved=False)
    return {
        "manifest": manifest,
        "unit": old_unit,
        "processes": processes,
        "health": health,
        "sockets": sockets,
        "token": token,
        "tokenMetadata": token_metadata,
        "cpuDropInMetadata": cpu_metadata,
        "oldDropIn": str(old_dropin),
    }


def preflight_only(args, config):
    release, review, candidate, lock, before, receipt, failure, backup = config
    result = preflight(args, config)
    print(json.dumps({
        "status": "preflight_ready",
        "sourceCommit": args.release_sha,
        "sourceTree": args.source_tree,
        "rollbackRelease": str(OLD_RELEASE),
        "oldDropInSha256": OLD_DROPIN_SHA256,
        "candidateDropInSha256": args.dropin_sha256,
        "activeTurns": result["health"]["activeTurns"],
        "establishedConnections": result["sockets"]["establishedCount"],
        "listenerAddresses": result["sockets"]["listenerAddresses"],
        "processCount": len(result["processes"]),
        "cpuDropInsPreserved": True,
        "stableDropInAbsent": True,
        "lockAbsent": True,
    }, separators=(",", ":")))


def write_json(path, value):
    Path(path).write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.chmod(path, 0o600)


def backup_state(config, result):
    release, review, candidate, lock, before, receipt, failure, backup = config
    backup.mkdir(mode=0o700)
    unit_backup = backup / "clutch-chat-bridge.service.before"
    shutil.copy2(UNIT_PATH, unit_backup)
    if digest(unit_backup) != digest(UNIT_PATH):
        fail("backup-unit", unitBackupMatches=False)
    dropin_backup_dir = backup / "dropins"
    dropin_backup_dir.mkdir(mode=0o700)
    copied = []
    for path in sorted(set(result["unit"]["dropInPaths"])):
        source = Path(path)
        # Basenames collide across /etc, /run and /usr/lib systemd directories; key the
        # backup by the full source path so a later copy never overwrites an earlier one.
        dest = dropin_backup_dir / (hashlib.sha256(path.encode("utf-8")).hexdigest()[:12] + "-" + source.name)
        shutil.copy2(source, dest)
        if digest(source) != digest(dest):
            fail("backup-dropin", dropInBackupMatches=False)
        copied.append({"path": path, "backup": str(dest), "sha256": digest(dest)})
    return {"unitBackup": str(unit_backup), "dropInBackups": copied}


def activate(args, config):
    release, review, candidate, lock, before, receipt, failure, backup = config
    result = preflight(args, config)
    try:
        lock.mkdir(mode=0o700)
    except FileExistsError:
        fail("deployment-lock", existingLock=True, staleLockBypassed=False)
    lock_stat = os.stat(lock, follow_symlinks=False)
    lock_identity = (lock_stat.st_dev, lock_stat.st_ino)
    lock_held = True
    mutation_started = False
    flags = {"stableDropInInstalled": False, "oldDropInRemoved": False, "daemonReloadCount": 0, "restartAttempted": False}
    try:
        backup_records = backup_state(config, result)
        initial = base.safe_unit_record(result["unit"], result["processes"], result["sockets"], result["health"], result["tokenMetadata"], False)
        initial["unitFileSha256"] = digest(UNIT_PATH)
        initial["dropInMetadata"] = result["cpuDropInMetadata"] + base.dropin_metadata([result["oldDropIn"]])
        initial["backupRecords"] = backup_records
        initial["authoritativeIdleClaimed"] = False
        write_json(before, initial)

        current_attempt = {
            "lockIdentity": lock_identity,
            "beforeSha256": digest(before),
            "unitSha256": initial["unitFileSha256"],
            "dropInBackups": backup_records["dropInBackups"],
        }
        gate = preflight(args, config, current_attempt=current_attempt)
        if gate["unit"]["mainPid"] != result["unit"]["mainPid"] or gate["health"] != result["health"] or gate["sockets"]["listenerAddresses"] != result["sockets"]["listenerAddresses"]:
            fail("last-moment-preflight", serviceOrHealthStateChanged=True)

        mutation_started = True
        base.command(["sudo", "-n", "install", "-D", "-o", "root", "-g", "root", "-m", "0644", str(candidate), str(STABLE_DROPIN)], "install-stable-dropin")
        flags["stableDropInInstalled"] = STABLE_DROPIN.is_file()
        reloaded = base.command(["sudo", "-n", "systemctl", "daemon-reload"], "daemon-reload-after-stable-install")
        flags["daemonReloadCount"] += 1
        stable_unit = base.unit_snapshot(release)
        assert_unit(stable_unit, release, set(result["unit"]["dropInPaths"]) | {str(STABLE_DROPIN)})
        old_dropin = Path(result["oldDropIn"])
        if old_dropin == STABLE_DROPIN:
            # Repeat guarded transition: installing the candidate over the
            # stable name already replaced the old drop-in in place, so
            # there is no separate file to unlink.
            flags["oldDropInRemoved"] = True
        else:
            if digest(old_dropin) != OLD_DROPIN_SHA256:
                fail("old-dropin-cas", oldDropInHashChanged=True)
            base.command(["sudo", "-n", "unlink", str(old_dropin)], "unlink-prior-release-dropin")
            flags["oldDropInRemoved"] = not old_dropin.exists()
        base.command(["sudo", "-n", "systemctl", "daemon-reload"], "daemon-reload-after-old-dropin-removal")
        flags["daemonReloadCount"] += 1
        expected_after_switch = set(CPU_DROPIN_HASHES) | {str(STABLE_DROPIN)}
        new_unit = base.unit_snapshot(release)
        assert_unit(new_unit, release, expected_after_switch)
        if new_unit["mainPid"] != result["unit"]["mainPid"]:
            fail("pre-restart-pid", serviceRestartedBeforeApprovedStep=True)

        flags["restartAttempted"] = True
        base.command(["sudo", "-n", "systemctl", "restart", UNIT], "restart-unit", timeout=45)
        deadline = time.monotonic() + 30
        after_health = None
        last_error = None
        while time.monotonic() < deadline:
            try:
                current = base.unit_snapshot(release)
                if current["activeState"] != "active" or current["subState"] != "running" or current["mainPid"] <= 1:
                    time.sleep(0.25)
                    continue
                after_health = exact_health(result["token"], "post-restart-health")
                break
            except base.RolloutStop as error:
                last_error = {"stage": error.step, "flags": error.flags}
                if not retryable_health_failure(error):
                    raise
                time.sleep(0.25)
        if after_health is None:
            fail("post-restart-readiness-timeout", lastError=last_error)

        final_unit = base.unit_snapshot(release)
        assert_unit(final_unit, release, expected_after_switch)
        if final_unit["mainPid"] == result["unit"]["mainPid"]:
            fail("post-restart-pid", servicePidChanged=False)
        final_processes = current_processes(final_unit, release)
        final_sockets = base.socket_summary()
        if final_sockets["listenerAddresses"] != result["sockets"]["listenerAddresses"] or final_sockets["establishedCount"] or final_sockets["web3180ListenerCount"]:
            fail("post-restart-sockets", listenerSetPreserved=False, establishedConnections=final_sockets["establishedCount"], web3180Listeners=final_sockets["web3180ListenerCount"])
        if base.safe_token_file()[0] != result["token"]:
            fail("post-restart-chat-token", sameTokenBytes=False)

        receipt_value = {
            "status": "complete",
            "sourceCommit": args.release_sha,
            "sourceTree": args.source_tree,
            "releaseDirectory": str(release),
            "previousRelease": str(OLD_RELEASE),
            "dropInPath": str(STABLE_DROPIN),
            "dropInSha256": args.dropin_sha256,
            "oldHashedDropInRemovedAfterCAS": flags["oldDropInRemoved"],
            "cpuDropInsPreserved": True,
            "unitUser": SERVICE_USER,
            "homeAndClutchHomePreserved": True,
            "restartAttemptedOnce": True,
            "postRestartHttpStatus": after_health["httpStatus"],
            "postRestartActiveTurns": after_health["activeTurns"],
            "preRestartActiveTurns": result["health"]["activeTurns"],
            "establishedConnectionsBeforeAndAfter": [result["sockets"]["establishedCount"], final_sockets["establishedCount"]],
            "listenerAddressesUnchanged": True,
            "postRestartProcesses": len(final_processes),
            "pairedTokenFileUnchanged": True,
            "before": initial,
            "after": base.safe_unit_record(final_unit, final_processes, final_sockets, after_health, result["tokenMetadata"], False),
            "backupRecords": backup_records,
            "rollbackRelease": str(OLD_RELEASE),
            "flags": flags,
        }
        write_json(receipt, receipt_value)
        lock.rmdir()
        lock_held = False
        print(json.dumps({"status": "complete", "release": str(release), "stableDropIn": str(STABLE_DROPIN), "activeTurns": after_health["activeTurns"], "lockReleased": True}, separators=(",", ":")))
    except base.RolloutStop as error:
        failure_value = {"status": "failed_after_mutation" if mutation_started else "aborted_before_mutation", "stage": error.step, "flags": {**flags, **error.flags}, "rollbackAttempted": False, "lockRetained": lock_held, "rollbackRelease": str(OLD_RELEASE)}
        if mutation_started:
            write_json(failure, failure_value)
        else:
            if lock_held:
                lock.rmdir()
                lock_held = False
            # No mutation happened, so reclaim this attempt's review artifacts; leftovers
            # otherwise block the next attempt at the backup-path preflight.
            shutil.rmtree(backup, ignore_errors=True)
            Path(before).unlink(missing_ok=True)
        print(json.dumps(failure_value, separators=(",", ":")))
        raise SystemExit(1)
    except Exception as error:
        failure_value = {"status": "failed_after_mutation" if mutation_started else "aborted_before_mutation", "stage": "unexpected", "errorType": type(error).__name__, "flags": flags, "rollbackAttempted": False, "lockRetained": lock_held, "rollbackRelease": str(OLD_RELEASE)}
        if mutation_started:
            write_json(failure, failure_value)
        elif lock_held:
            lock.rmdir()
            lock_held = False
            shutil.rmtree(backup, ignore_errors=True)
            Path(before).unlink(missing_ok=True)
        print(json.dumps(failure_value, separators=(",", ":")))
        raise SystemExit(1)


def rollback(args, config):
    release, review, candidate, lock, before, receipt, failure, backup = config
    manifest = verify_artifact(args, release, candidate)
    rollback_receipt = review / "production-rollback-receipt.json"
    # The backup records the old drop-in under the name it actually had:
    # the stable name after a guarded transition, or the per-SHA name from
    # the first-time activator.
    stable_backup = backup / "dropins" / STABLE_DROPIN_NAME
    per_sha_backup = backup / "dropins" / OLD_DROPIN.name
    old_dropin_backup = stable_backup if stable_backup.is_file() else per_sha_backup
    restore_target = DROPIN_DIR / old_dropin_backup.name
    if (not lock.is_dir() or lock.is_symlink() or not failure.is_file() or not before.is_file()
            or not old_dropin_backup.is_file() or rollback_receipt.exists()):
        fail("rollback-preflight", ownedLockFailureAndBackupPresent=False)
    lock_stat = os.stat(lock, follow_symlinks=False)
    if lock_stat.st_uid != os.getuid() or stat.S_IMODE(lock_stat.st_mode) != 0o700 or any(lock.iterdir()):
        fail("rollback-lock", lockOwnedPrivateAndEmpty=False)
    if digest(old_dropin_backup) != OLD_DROPIN_SHA256 or digest(STABLE_DROPIN) != args.dropin_sha256:
        fail("rollback-cas", rollbackBackupAndStableDropInMatch=False)
    current = base.unit_snapshot(release)
    assert_unit(current, release, set(CPU_DROPIN_HASHES) | {str(STABLE_DROPIN)})
    current_processes(current, release)
    token, token_metadata = base.safe_token_file()
    pre_health = exact_health(token, "rollback-preflight-health")
    sockets = base.socket_summary()
    if sockets["establishedCount"] or sockets["web3180ListenerCount"]:
        fail("rollback-sockets", establishedConnections=sockets["establishedCount"], web3180Listeners=sockets["web3180ListenerCount"])
    flags = {"oldDropInRestored": False, "stableDropInRemoved": False, "daemonReloaded": False, "restartAttempted": False}
    try:
        if restore_target == STABLE_DROPIN:
            # Repeat transition: the failed candidate owns the stable name,
            # so restore the verified backup over it in place instead of
            # unlinking it.
            base.command(["sudo", "-n", "install", "-D", "-o", "root", "-g", "root", "-m", "0644", str(old_dropin_backup), str(STABLE_DROPIN)], "restore-old-dropin")
        elif OLD_DROPIN.exists():
            if digest(OLD_DROPIN) != OLD_DROPIN_SHA256:
                fail("rollback-old-dropin-cas", existingOldDropInMatches=False)
        else:
            base.command(["sudo", "-n", "install", "-D", "-o", "root", "-g", "root", "-m", "0644", str(old_dropin_backup), str(OLD_DROPIN)], "restore-old-dropin")
        flags["oldDropInRestored"] = restore_target.is_file() and digest(restore_target) == OLD_DROPIN_SHA256
        if restore_target != STABLE_DROPIN:
            if digest(STABLE_DROPIN) != args.dropin_sha256:
                fail("rollback-stable-dropin-cas", stableDropInHashChanged=True)
            base.command(["sudo", "-n", "unlink", str(STABLE_DROPIN)], "remove-stable-dropin")
        flags["stableDropInRemoved"] = restore_target == STABLE_DROPIN or not STABLE_DROPIN.exists()
        base.command(["sudo", "-n", "systemctl", "daemon-reload"], "rollback-daemon-reload")
        flags["daemonReloaded"] = True
        expected_old = set(CPU_DROPIN_HASHES) | {str(restore_target)}
        old_unit = base.unit_snapshot(OLD_RELEASE)
        assert_unit(old_unit, OLD_RELEASE, expected_old)
        flags["restartAttempted"] = True
        base.command(["sudo", "-n", "systemctl", "restart", UNIT], "rollback-restart", timeout=45)
        deadline = time.monotonic() + 30
        after_health = None
        while time.monotonic() < deadline:
            try:
                old_unit = base.unit_snapshot(OLD_RELEASE)
                if old_unit["activeState"] != "active" or old_unit["subState"] != "running" or old_unit["mainPid"] <= 1:
                    time.sleep(0.25)
                    continue
                after_health = exact_health(token, "rollback-post-health")
                break
            except base.RolloutStop as error:
                if not retryable_health_failure(error):
                    raise
                time.sleep(0.25)
        if after_health is None:
            fail("rollback-readiness-timeout", authenticatedHealth=False)
        old_unit = base.unit_snapshot(OLD_RELEASE)
        assert_unit(old_unit, OLD_RELEASE, expected_old)
        processes = current_processes(old_unit, OLD_RELEASE)
        after_sockets = base.socket_summary()
        if after_sockets["listenerAddresses"] != sockets["listenerAddresses"] or after_sockets["establishedCount"] or after_sockets["web3180ListenerCount"]:
            fail("rollback-final-sockets", listenerSetPreserved=False, establishedConnections=after_sockets["establishedCount"], web3180Listeners=after_sockets["web3180ListenerCount"])
        if base.safe_token_file()[0] != token:
            fail("rollback-token-check", tokenFileChangedDuringRollback=True)
        write_json(rollback_receipt, {
            "status": "complete",
            "action": "rollback_to_known_release",
            "failedCandidateCommit": args.release_sha,
            "rollbackRelease": str(OLD_RELEASE),
            "rollbackDropIn": str(restore_target),
            "stableDropInRemoved": True,
            "oldDropInRestoredFromVerifiedBackup": True,
            "cpuDropInsPreserved": True,
            "preRollbackHealth": pre_health,
            "postRollbackHealth": after_health,
            "listenerAddressesUnchanged": True,
            "processCount": len(processes),
            "pairedTokenFileUnchanged": True,
            "flags": flags,
        })
        lock.rmdir()
        print(json.dumps({"status": "rollback_complete", "release": str(OLD_RELEASE), "activeTurns": after_health["activeTurns"], "lockReleased": True}, separators=(",", ":")))
    except base.RolloutStop as error:
        failure_value = {"status": "rollback_failed_after_mutation", "stage": error.step, "flags": {**flags, **error.flags}, "lockRetained": True}
        write_json(review / "production-rollback-failure.json", failure_value)
        print(json.dumps(failure_value, separators=(",", ":")))
        raise SystemExit(1)
    except Exception as error:
        # An unexpected failure (for example a missing stable drop-in
        # raising from digest) must still leave the machine-readable
        # failure receipt and say the lock is retained, not escape as a
        # bare traceback with the host partially rolled back.
        failure_value = {"status": "rollback_failed_after_mutation", "stage": "unexpected", "errorType": type(error).__name__, "flags": flags, "lockRetained": True}
        write_json(review / "production-rollback-failure.json", failure_value)
        print(json.dumps(failure_value, separators=(",", ":")))
        raise SystemExit(1)


def diagnose(args):
    target = RELEASES / args.release_sha
    try:
        unit = base.unit_snapshot(target)
        listeners = base.socket_rows("listeners")
        listener_pids = sorted({pid for row in listeners for pid in row["pids"]})
        all_pids = sorted(set(listener_pids + ([unit["mainPid"]] if unit["mainPid"] > 1 else [])))
        service_uid = os.stat(SERVICE_HOME).st_uid
        process_report = []
        for pid in all_pids:
            try:
                info = base.read_proc(pid, target)
                env = info["selectedEnvironment"]
                process_report.append({
                    "pid": pid,
                    "uidMatchesServiceUser": info["uid"] == service_uid,
                    "inServiceCgroup": info["inServiceCgroup"],
                    "cwd": info["cwd"],
                    "entrypointRelease": info["entrypointRelease"],
                    "tsxRelease": info["tsxRelease"],
                    "entrypointBase": info["entrypointBase"],
                    "homeExpected": env.get("HOME") == str(SERVICE_HOME),
                    "clutchHomeExpected": env.get("CLUTCH_HOME") == str(CLUTCH_STATE_HOME),
                    "runtimeRootMatchesRelease": env.get("CLUTCH_RUNTIME_ROOT") == str(target),
                    "infisicalEnvironmentKeys": info["infisicalEnvironmentKeys"],
                })
            except Exception as error:
                process_report.append({"pid": pid, "readErrorType": type(error).__name__})
        listener_report = [{"address": row["localAddress"], "pids": row["pids"]} for row in listeners]
    except base.RolloutStop as error:
        unit = None
        process_report = {"errorStage": error.step, "flags": error.flags}
        listener_report = []
    try:
        sockets = base.socket_summary()
        socket_report = {key: value for key, value in sockets.items() if key != "listeners"}
    except base.RolloutStop as error:
        socket_report = {"errorStage": error.step, "flags": error.flags}
    try:
        token, _ = base.safe_token_file()
        health = base.health(token)
    except base.RolloutStop as error:
        health = {"errorStage": error.step, "flags": error.flags}
    unit_report = None if unit is None else {key: value for key, value in unit.items() if key not in {"environmentRaw", "environmentFilesRaw", "environmentValues"}}
    dropins = [] if unit is None else base.dropin_metadata(unit["dropInPaths"])
    print(json.dumps({"status": "read_only_diagnostic", "unit": unit_report, "listeners": listener_report, "processes": process_report, "dropInMetadata": dropins, "sockets": socket_report, "health": health}, separators=(",", ":")))


def parse_args():
    parser = argparse.ArgumentParser(
        description="Prepare or activate one pinned Clutch Linux release",
        epilog="Rollback requires a healthy candidate with exact activeTurns=0 and no established connections.",
    )
    parser.add_argument("mode", choices=("preflight", "activate", "rollback", "diagnose"))
    parser.add_argument("--release-sha", required=True)
    parser.add_argument("--source-tree", required=True)
    parser.add_argument("--source-archive-sha256", required=True)
    parser.add_argument("--package-lock-sha256", required=True)
    parser.add_argument("--dropin-sha256", required=True)
    parser.add_argument("--validate-arguments-only", action="store_true")
    return parser.parse_args()


def main():
    args = parse_args()
    if args.validate_arguments_only:
        valid = len(args.release_sha) == 40 and all(ch in "0123456789abcdef" for ch in args.release_sha)
        print(json.dumps({"status": "arguments_valid" if valid else "arguments_invalid", "mode": args.mode, "releaseShaValid": valid}, separators=(",", ":")))
        raise SystemExit(0 if valid else 1)
    try:
        # Read-only diagnose needs no rollback-target pins; the mutating
        # modes configure inside the handler so a bad --release-sha or
        # missing CLUTCH_PREVIOUS_RELEASE_SHA reports preflight_aborted
        # JSON instead of a traceback.
        if args.mode == "diagnose":
            diagnose(args)
            return
        config = configure(args)
        if args.mode == "preflight":
            preflight_only(args, config)
        elif args.mode == "activate":
            activate(args, config)
        else:
            rollback(args, config)
    except base.RolloutStop as error:
        print(json.dumps({"status": "preflight_aborted", "stage": error.step, "flags": error.flags}, separators=(",", ":")))
        raise SystemExit(1)


if __name__ == "__main__":
    main()
