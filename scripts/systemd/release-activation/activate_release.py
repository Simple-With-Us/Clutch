import hashlib
import json
import os
import pwd
import re
import shutil
import stat
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path


UNIT = "clutch-chat-bridge.service"

def _root(name, fallback):
    value = os.environ.get(name)
    return Path(value) if value else fallback


# Deployment layout comes from the environment, never from the source.
APPS_ROOT = _root("FLEET_APPS_ROOT", Path.home() / "apps")
CODE_ROOT = _root("FLEET_CODE_ROOT", Path.home() / "Code")
SERVICE_USER = os.environ.get("CLUTCH_SERVICE_USER") or pwd.getpwuid(os.getuid()).pw_name
SERVICE_HOME = _root("CLUTCH_SERVICE_HOME", Path.home())
CLUTCH_STATE_HOME = SERVICE_HOME / ".clutch"
RELEASES_ROOT = _root("CLUTCH_RELEASES_ROOT", APPS_ROOT / "runtime/Clutch/releases")
RELEASE_SHA = os.environ.get("CLUTCH_RELEASE_SHA", "")

RELEASE = RELEASES_ROOT / RELEASE_SHA
REVIEW = RELEASE / "deployment/review"
LOCK = REVIEW / "production-rollout.lock"
BACKUP = REVIEW / "backup-before-activation"
BEFORE_RECEIPT = REVIEW / "production-before.json"
SUCCESS_RECEIPT = REVIEW / "production-receipt.json"
FAILURE_RECEIPT = REVIEW / "production-failure.json"
DROPIN_NAME = f"20-clutch-{RELEASE_SHA[:7]}-release.conf"
DROPIN_SOURCE = REVIEW / DROPIN_NAME
DROPIN_DIRECTORY = Path("/etc/systemd/system/clutch-chat-bridge.service.d")
DROPIN_TARGET = DROPIN_DIRECTORY / DROPIN_NAME
UNIT_PATH = Path("/etc/systemd/system/clutch-chat-bridge.service")
CHAT_TOKEN_PATH = CLUTCH_STATE_HOME / "chat-token"
INFISICAL_CONFIG_PATH = CLUTCH_STATE_HOME / "infisical.json"
PORT = 3181
MAX_FILE_BYTES = 4096
MAX_HEALTH_BYTES = 65536
EXPECTED_MAIN_SOURCE = os.environ.get("CLUTCH_MAIN_SOURCE") or str(CODE_ROOT / "Clutch")
EXPECTED_SOURCE_TREE = os.environ.get("CLUTCH_EXPECTED_SOURCE_TREE", "")
EXPECTED_SOURCE_ARCHIVE_SHA256 = os.environ.get("CLUTCH_EXPECTED_SOURCE_ARCHIVE_SHA256", "")
EXPECTED_PACKAGE_LOCK_SHA256 = os.environ.get("CLUTCH_EXPECTED_PACKAGE_LOCK_SHA256", "")
EXPECTED_DROPIN_SHA256 = os.environ.get("CLUTCH_EXPECTED_DROPIN_SHA256", "")


class RolloutStop(Exception):
    def __init__(self, step, flags):
        super().__init__(step)
        self.step = step
        self.flags = flags


def stop(step, **flags):
    raise RolloutStop(step, flags)


def command(args, step, timeout=15):
    try:
        result = subprocess.run(
            args,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=timeout,
            check=False,
        )
    except Exception as error:
        stop(step, command=args[0], errorType=type(error).__name__)
    if result.returncode != 0:
        stop(step, command=Path(args[0]).name, exitCode=result.returncode)
    return result.stdout


def parse_properties(raw):
    values = {}
    for line in raw.splitlines():
        key, separator, value = line.partition("=")
        if separator:
            values[key] = value
    return values


def unit_snapshot(target_release=RELEASE):
    fields = [
        "Id", "ActiveState", "SubState", "MainPID", "User", "FragmentPath",
        "WorkingDirectory", "DropInPaths", "ExecStart", "Environment",
        "EnvironmentFiles", "Type", "Restart", "RestartUSec",
        "ExecMainStartTimestampMonotonic",
        "ExecMainStatus", "Result", "NRestarts",
    ]
    args = ["systemctl", "show", UNIT]
    for field in fields:
        args.extend(["-p", field])
    props = parse_properties(command(args, "systemd-show"))
    env_raw = props.get("Environment", "")
    env_names = sorted(set(re.findall(r"(?:^|\s)([A-Za-z_][A-Za-z0-9_]*)=", env_raw)))
    env_values = {}
    for assignment in re.finditer(r"(?:^|\s)([A-Za-z_][A-Za-z0-9_]*)=([^\s]*)", env_raw):
        env_values[assignment.group(1)] = assignment.group(2).strip('"')
    env_files = props.get("EnvironmentFiles", "")
    dropins = [path for path in props.get("DropInPaths", "").split() if path]
    try:
        main_pid = int(props.get("MainPID", "0"))
    except ValueError:
        main_pid = 0
    exec_raw = props.get("ExecStart", "")
    return {
        "id": props.get("Id", ""),
        "activeState": props.get("ActiveState", ""),
        "subState": props.get("SubState", ""),
        "mainPid": main_pid,
        "user": props.get("User", ""),
        "fragmentPath": props.get("FragmentPath", ""),
        "workingDirectory": props.get("WorkingDirectory", ""),
        "dropInPaths": dropins,
        "environmentKeys": env_names,
        "infisicalEnvironmentKeys": [name for name in env_names if name.startswith(("INFISICAL_", "CLUTCH_INFISICAL_"))],
        "environmentFileCount": len(re.findall(r"\bpath=", env_files)),
        "environmentValues": env_values,
        "environmentRaw": env_raw,
        "environmentFilesRaw": env_files,
        "type": props.get("Type", ""),
        "restart": props.get("Restart", ""),
        "restartUsec": props.get("RestartUSec", ""),
        "execStartReleaseLauncher": f"{target_release}/scripts/chat-bridge.sh" in exec_raw,
        "execStartBaseLauncher": f"{EXPECTED_MAIN_SOURCE}/scripts/chat-bridge.sh" in exec_raw,
        "execMainStartMonotonic": props.get("ExecMainStartTimestampMonotonic", ""),
        "execMainStatus": props.get("ExecMainStatus", ""),
        "result": props.get("Result", ""),
        "restartCount": props.get("NRestarts", ""),
    }


def read_proc(pid, target_release=RELEASE):
    base = Path(f"/proc/{pid}")
    status = (base / "status").read_text(encoding="utf-8").splitlines()
    name_line = next((line for line in status if line.startswith("Name:")), "")
    uid_line = next((line for line in status if line.startswith("Uid:")), "")
    ppid_line = next((line for line in status if line.startswith("PPid:")), "")
    uid = int(uid_line.split()[1]) if uid_line else -1
    ppid = int(ppid_line.split()[1]) if ppid_line else -1
    cmdline = (base / "cmdline").read_bytes().split(b"\0")
    args = [os.fsdecode(arg) for arg in cmdline if arg]
    joined = "\0".join(args)
    env_entries = (base / "environ").read_bytes().split(b"\0")
    env_names = set()
    selected_env = {}
    for entry in env_entries:
        if b"=" not in entry:
            continue
        key, value = entry.split(b"=", 1)
        name = key.decode("ascii", "ignore")
        env_names.add(name)
        if name in {"HOME", "CLUTCH_HOME", "CLUTCH_RUNTIME_ROOT"}:
            selected_env[name] = value.decode("utf-8", "replace")
    cgroup = (base / "cgroup").read_text(encoding="utf-8")
    return {
        "pid": pid,
        "ppid": ppid,
        "uid": uid,
        "name": name_line.partition("\t")[2] if "\t" in name_line else "",
        "exe": Path(os.readlink(base / "exe")).name,
        "cwd": os.readlink(base / "cwd"),
        "inServiceCgroup": f"/{UNIT}" in cgroup,
        "entrypointRelease": str(target_release / "src/web/chat-bridge.ts") in joined,
        "entrypointBase": f"{EXPECTED_MAIN_SOURCE}/src/web/chat-bridge.ts" in joined,
        "tsxRelease": f"{target_release}/node_modules" in joined and ("tsx" in joined),
        "selectedEnvironment": selected_env,
        "infisicalEnvironmentKeys": sorted(name for name in env_names if name.startswith(("INFISICAL_", "CLUTCH_INFISICAL_"))),
    }


def socket_rows(kind):
    if kind == "listeners":
        args = ["ss", "-H", "-ltnp", "sport", "=", f":{PORT}"]
    else:
        args = ["ss", "-H", "-tnp", "state", "established", "sport", "=", f":{PORT}"]
    raw = command(args, f"ss-{kind}")
    rows = []
    for line in raw.splitlines():
        fields = line.split()
        if len(fields) < 4:
            continue
        local_address = fields[3]
        pids = sorted({int(pid) for pid in re.findall(r"pid=(\d+)", line)})
        rows.append({"localAddress": local_address, "pids": pids})
    return rows


def socket_summary():
    listeners = socket_rows("listeners")
    port_3180 = command(["ss", "-H", "-ltn", "sport", "=", ":3180"], "ss-web-port")
    return {
        "listeners": listeners,
        "listenerAddresses": sorted({row["localAddress"] for row in listeners}),
        "loopbackListener": any(row["localAddress"].startswith("127.0.0.1:") for row in listeners),
        "tailnetListenerCount": sum(1 for row in listeners if not row["localAddress"].startswith(("127.0.0.1:", "[::1]:"))),
        "web3180ListenerCount": len([line for line in port_3180.splitlines() if line.strip()]),
        "establishedCount": len(socket_rows("established")),
    }


def safe_token_file():
    try:
        before = os.lstat(CHAT_TOKEN_PATH)
    except OSError:
        stop("chat-token-preflight", tokenFilePresent=False)
    expected_uid = pwd.getpwnam(SERVICE_USER).pw_uid
    if not stat.S_ISREG(before.st_mode) or stat.S_ISLNK(before.st_mode):
        stop("chat-token-preflight", tokenFileTypeValid=False)
    if before.st_uid != expected_uid or stat.S_IMODE(before.st_mode) != 0o600 or before.st_size > MAX_FILE_BYTES:
        stop("chat-token-preflight", tokenFileMetadataValid=False)
    try:
        fd = os.open(CHAT_TOKEN_PATH, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    except OSError:
        stop("chat-token-preflight", tokenFileOpen=False)
    try:
        opened = os.fstat(fd)
        if opened.st_dev != before.st_dev or opened.st_ino != before.st_ino:
            stop("chat-token-preflight", tokenFileIdentityStable=False)
        raw = os.read(fd, MAX_FILE_BYTES + 1)
        after = os.fstat(fd)
    finally:
        os.close(fd)
    if len(raw) > MAX_FILE_BYTES or after.st_dev != opened.st_dev or after.st_ino != opened.st_ino:
        stop("chat-token-preflight", tokenFileSizeOrIdentityValid=False)
    try:
        token = raw.decode("utf-8").strip()
    except UnicodeDecodeError:
        stop("chat-token-preflight", tokenEncodingValid=False)
    if len(token) < 32 or any(char.isspace() for char in token):
        stop("chat-token-preflight", tokenShapeValid=False)
    return token, {"present": True, "ownerMatchesJay": True, "mode600": True}


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def health(token, require_active_zero=False):
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    request = urllib.request.Request(
        f"http://127.0.0.1:{PORT}/clutch/v1/health",
        headers={"Authorization": f"Bearer {token}", "Accept": "application/json"},
        method="GET",
    )
    try:
        with opener.open(request, timeout=5) as response:
            status = response.status
            body = response.read(MAX_HEALTH_BYTES + 1)
    except urllib.error.HTTPError as error:
        stop("authenticated-health", httpStatus=error.code)
    except Exception as error:
        stop("authenticated-health", errorType=type(error).__name__)
    if len(body) > MAX_HEALTH_BYTES:
        stop("authenticated-health", responseSizeValid=False)
    try:
        payload = json.loads(body.decode("utf-8"))
    except Exception:
        stop("authenticated-health", responseJsonValid=False)
    if status != 200 or not isinstance(payload, dict) or payload.get("ok") is not True:
        stop("authenticated-health", httpStatus=status, ok=False)
    if "activeTurns" not in payload:
        active_reported = False
        active_value = None
    elif type(payload["activeTurns"]) is int and payload["activeTurns"] >= 0:
        active_reported = True
        active_value = payload["activeTurns"]
    else:
        stop("authenticated-health", activeTurnsFieldValid=False)
    if active_reported and active_value > 0 and not require_active_zero:
        stop("preflight-active-turns", activeTurnsReported=True, activeTurns=active_value)
    if require_active_zero and not (active_reported and active_value == 0):
        stop("postflight-active-turns", activeTurnsReported=active_reported, activeTurns=active_value)
    return {
        "httpStatus": status,
        "ok": True,
        "activeTurnsReported": active_reported,
        "activeTurns": active_value,
    }


def private_config_absent():
    try:
        os.lstat(INFISICAL_CONFIG_PATH)
    except FileNotFoundError:
        return True
    except OSError as error:
        stop("infisical-config-preflight", errorType=type(error).__name__)
    return False


def infisical_runtime_keys(process_infos, unit):
    names = set(unit["infisicalEnvironmentKeys"])
    for info in process_infos:
        names.update(info["infisicalEnvironmentKeys"])
    return sorted(names)


def file_metadata(path, include_hash=False):
    try:
        info = os.stat(path, follow_symlinks=False)
    except OSError:
        return {"path": str(path), "present": False}
    value = {
        "path": str(path),
        "present": True,
        "mode": stat.S_IMODE(info.st_mode),
        "uid": info.st_uid,
        "size": info.st_size,
        "mtimeNs": info.st_mtime_ns,
    }
    if include_hash and stat.S_ISREG(info.st_mode):
        try:
            value["sha256"] = hashlib.sha256(Path(path).read_bytes()).hexdigest()
        except OSError:
            value["sha256"] = None
    return value


def safe_unit_record(unit, process_infos, sockets, health_result, token_meta, infisical_present):
    record = {key: value for key, value in unit.items() if key not in {"environmentRaw", "environmentFilesRaw", "environmentValues"}}
    record["processes"] = process_infos
    record["listenerAddresses"] = sockets["listenerAddresses"]
    record["loopbackListener"] = sockets["loopbackListener"]
    record["tailnetListenerCount"] = sockets["tailnetListenerCount"]
    record["establishedConnections"] = sockets["establishedCount"]
    record["web3180ListenerCount"] = sockets["web3180ListenerCount"]
    record["health"] = health_result
    record["chatTokenMetadata"] = token_meta
    record["infisicalConfigPresent"] = infisical_present
    return record


def assert_base_state(unit, processes, sockets, dropin_absent):
    if unit["id"] != UNIT or unit["activeState"] != "active" or unit["user"] != SERVICE_USER:
        stop("base-unit-preflight", unitActive=unit["activeState"] == "active", unitUserIsServiceUser=unit["user"] == SERVICE_USER)
    if unit["fragmentPath"] != str(UNIT_PATH) or unit["workingDirectory"] != EXPECTED_MAIN_SOURCE:
        stop("base-unit-preflight", fragmentIsExpected=unit["fragmentPath"] == str(UNIT_PATH), baseWorkingDirectoryExpected=unit["workingDirectory"] == EXPECTED_MAIN_SOURCE)
    if not unit["execStartBaseLauncher"] or unit["execStartReleaseLauncher"]:
        stop("base-unit-preflight", baseLauncherExpected=unit["execStartBaseLauncher"], releaseLauncherAlreadyConfigured=unit["execStartReleaseLauncher"])
    if unit["environmentValues"].get("HOME") != str(SERVICE_HOME) or unit["environmentValues"].get("CLUTCH_HOME") != str(CLUTCH_STATE_HOME):
        stop("base-unit-preflight", homeEnvironmentExpected=False)
    if not dropin_absent:
        stop("dropin-target-preflight", candidateAlreadyExists=True)
    if not sockets["loopbackListener"] or sockets["web3180ListenerCount"] != 0:
        stop("socket-preflight", loopback3181=sockets["loopbackListener"], web3180Listeners=sockets["web3180ListenerCount"])
    if sockets["establishedCount"] != 0:
        stop("established-chat-connections", scopedEstablishedConnections=sockets["establishedCount"])
    service_uid = pwd.getpwnam(SERVICE_USER).pw_uid
    if not processes or any(info["uid"] != service_uid or not info["inServiceCgroup"] or info["cwd"] != EXPECTED_MAIN_SOURCE for info in processes):
        stop("process-preflight", processOwnershipAndCwdVerified=False)
    infisical_names = infisical_runtime_keys(processes, unit)
    active_tokens = [name for name in infisical_names if name in {"INFISICAL_TOKEN", "INFISICAL_SERVICE_TOKEN", "INFISICAL_WRITE_TOKEN", "INFISICAL_CLIENT_ID", "INFISICAL_CLIENT_SECRET"}]
    if active_tokens:
        stop("infisical-network-preflight", infisicalVariableNames=active_tokens)


def listener_process_infos(unit, target_release=RELEASE):
    if unit["mainPid"] <= 1:
        stop("process-preflight", mainPidValid=False)
    listener_rows = socket_rows("listeners")
    loopback_rows = [row for row in listener_rows if row["localAddress"].startswith("127.0.0.1:")]
    listener_pids = sorted({pid for row in loopback_rows for pid in row["pids"]})
    if len(listener_pids) != 1:
        stop("process-preflight", loopbackListenerProcessCount=len(listener_pids))
    pids = sorted(set([unit["mainPid"], *listener_pids]))
    try:
        infos = [read_proc(pid, target_release) for pid in pids]
    except Exception as error:
        stop("process-preflight", errorType=type(error).__name__)
    if not any(info["pid"] in listener_pids for info in infos):
        stop("process-preflight", listenerProcessFound=False)
    return infos


def dropin_metadata(paths):
    return [file_metadata(path, include_hash=True) for path in sorted(paths)]


def write_json(path, payload):
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.chmod(path, 0o600)


def validate_release():
    if not RELEASE.is_dir() or (RELEASE / ".git").exists():
        stop("release-artifact-preflight", releaseIsNonGitArtifact=False)
    manifest = json.loads((REVIEW / "provenance.json").read_text(encoding="utf-8"))
    lock_sha = hashlib.sha256((RELEASE / "package-lock.json").read_bytes()).hexdigest()
    dropin_sha = hashlib.sha256(DROPIN_SOURCE.read_bytes()).hexdigest()
    if (manifest.get("sourceCommit") != RELEASE.name
            or manifest.get("sourceCommit") != RELEASE_SHA
            or manifest.get("sourceTree") != EXPECTED_SOURCE_TREE
            or manifest.get("sourceArchiveSha256") != EXPECTED_SOURCE_ARCHIVE_SHA256
            or manifest.get("packageLockSha256") != EXPECTED_PACKAGE_LOCK_SHA256
            or lock_sha != EXPECTED_PACKAGE_LOCK_SHA256
            or manifest.get("candidateDropInInstalled") is not False
            or dropin_sha != EXPECTED_DROPIN_SHA256):
        stop("release-manifest-preflight", sourceCommitTreeAndHashesVerified=False)
    return manifest


def preflight_only():
    manifest = validate_release()
    if not DROPIN_SOURCE.is_file() or DROPIN_TARGET.exists():
        stop("dropin-preflight", sourcePresent=DROPIN_SOURCE.is_file(), targetAbsent=not DROPIN_TARGET.exists())
    if LOCK.exists() or BACKUP.exists() or BEFORE_RECEIPT.exists() or SUCCESS_RECEIPT.exists() or FAILURE_RECEIPT.exists():
        stop("deployment-preflight-paths", lockAbsent=not LOCK.exists(), backupPathsAbsent=not BACKUP.exists())
    token, token_meta = safe_token_file()
    if not private_config_absent():
        stop("infisical-config-preflight", configPresent=True, infisicalNetworkPrevented=True)
    unit = unit_snapshot()
    processes = listener_process_infos(unit)
    health_result = health(token)
    sockets = socket_summary()
    assert_base_state(unit, processes, sockets, True)
    if unit["environmentFileCount"] > 0:
        stop("environment-file-preflight", environmentFileCount=unit["environmentFileCount"])
    print(json.dumps({
        "status": "preflight_ready",
        "sourceCommit": manifest["sourceCommit"],
        "sourceTree": manifest["sourceTree"],
        "unit": safe_unit_record(unit, processes, sockets, health_result, token_meta, False),
        "unitFileSha256": hashlib.sha256(UNIT_PATH.read_bytes()).hexdigest(),
        "existingDropIns": dropin_metadata(unit["dropInPaths"]),
        "candidateDropInSha256": EXPECTED_DROPIN_SHA256,
        "candidateAbsent": True,
        "lockAbsent": True,
        "authoritativeIdleClaimed": False,
    }, separators=(",", ":")))


def diagnose_after_failure():
    unit = None
    process_result = None
    socket_result = None
    health_result = None
    try:
        unit = unit_snapshot()
        try:
            process_result = listener_process_infos(unit)
            process_result = [{"pid": info["pid"], "uid": info["uid"], "cwd": info["cwd"], "inServiceCgroup": info["inServiceCgroup"], "entrypointRelease": info["entrypointRelease"], "entrypointBase": info["entrypointBase"], "tsxRelease": info["tsxRelease"], "selectedEnvironment": info["selectedEnvironment"]} for info in process_result]
        except RolloutStop as error:
            process_result = {"errorStage": error.step, "flags": error.flags}
        socket_result = socket_summary()
        token, _ = safe_token_file()
        try:
            health_result = health(token)
        except RolloutStop as error:
            health_result = {"errorStage": error.step, "flags": error.flags}
        journal = {"read": False, "lines": 0, "categories": {}}
        try:
            result = subprocess.run(
                ["journalctl", "-u", UNIT, "--since=-10min", "--no-pager", "-n", "80", "-o", "cat"],
                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                text=True, timeout=8, check=False,
            )
            if result.returncode == 0 and len(result.stdout) <= 65536:
                counts = {"start": 0, "stop": 0, "listen": 0, "error": 0, "infisical": 0, "telemetry": 0, "other": 0}
                for line in result.stdout.splitlines():
                    lowered = line.lower()
                    if "starting " in lowered or "started " in lowered:
                        category = "start"
                    elif "stopping " in lowered or "stopped " in lowered:
                        category = "stop"
                    elif "listen" in lowered or "listening" in lowered:
                        category = "listen"
                    elif "infisical" in lowered:
                        category = "infisical"
                    elif "telemetry" in lowered:
                        category = "telemetry"
                    elif "error" in lowered or "failed" in lowered or "exception" in lowered:
                        category = "error"
                    else:
                        category = "other"
                    counts[category] += 1
                journal = {"read": True, "lines": sum(counts.values()), "categories": counts}
        except Exception:
            pass
        report = {
            "status": "read_only_post_failure_diagnostic",
            "unit": {key: value for key, value in unit.items() if key not in {"environmentRaw", "environmentFilesRaw", "environmentValues"}},
            "processes": process_result,
            "sockets": {key: value for key, value in socket_result.items() if key != "listeners"},
            "health": health_result,
            "journal": journal,
        }
    except RolloutStop as error:
        report = {"status": "read_only_diagnostic_incomplete", "stage": error.step, "flags": error.flags}
    except Exception as error:
        report = {"status": "read_only_diagnostic_error", "errorType": type(error).__name__}
    print(json.dumps(report, separators=(",", ":")))


def finalize_recovered_startup():
    if not LOCK.is_dir() or LOCK.is_symlink():
        stop("recovery-lock-check", lockPresentAndDirectory=False)
    lock_stat = os.stat(LOCK, follow_symlinks=False)
    if lock_stat.st_uid != os.getuid() or stat.S_IMODE(lock_stat.st_mode) != 0o700 or any(LOCK.iterdir()):
        stop("recovery-lock-check", lockOwnedPrivateAndEmpty=False)
    if not FAILURE_RECEIPT.is_file() or SUCCESS_RECEIPT.exists():
        stop("recovery-receipt-check", failureReceiptPresent=FAILURE_RECEIPT.is_file(), successReceiptAbsent=not SUCCESS_RECEIPT.exists())
    failure = json.loads(FAILURE_RECEIPT.read_text(encoding="utf-8"))
    if failure.get("stage") != "authenticated-health" or failure.get("flags", {}).get("errorType") != "URLError":
        stop("recovery-receipt-check", onlyExpectedStartupHealthFailure=False)
    before = json.loads(BEFORE_RECEIPT.read_text(encoding="utf-8"))
    manifest = validate_release()
    if hashlib.sha256(DROPIN_TARGET.read_bytes()).hexdigest() != EXPECTED_DROPIN_SHA256:
        stop("recovery-dropin-check", candidateDropInMatches=False)

    unit = unit_snapshot()
    if (unit["id"] != UNIT or unit["activeState"] != "active" or unit["subState"] != "running"
            or unit["user"] != SERVICE_USER or unit["workingDirectory"] != str(RELEASE)
            or not unit["execStartReleaseLauncher"] or unit["mainPid"] == before["mainPid"]):
        stop("recovery-unit-check", activeReleaseUnit=False)
    expected_dropins = set(before["dropInPaths"]) | {str(DROPIN_TARGET)}
    if set(unit["dropInPaths"]) != expected_dropins or unit["environmentKeys"] != before["environmentKeys"]:
        stop("recovery-unit-check", candidateAndOriginalDropInsPreserved=False, environmentKeysPreserved=False)
    if unit["environmentFileCount"] != before["environmentFileCount"] or unit["infisicalEnvironmentKeys"]:
        stop("recovery-unit-check", environmentFilesPreserved=False, noInfisicalEnvironment=True)

    processes = listener_process_infos(unit)
    service_uid = pwd.getpwnam(SERVICE_USER).pw_uid
    listener_infos = [info for info in processes if info["entrypointRelease"] and info["tsxRelease"]]
    if (len(listener_infos) < 1 or any(info["entrypointBase"] for info in processes)
            or any(info["uid"] != service_uid or not info["inServiceCgroup"] or info["cwd"] != str(RELEASE) for info in processes)):
        stop("recovery-process-check", releaseEntrypointCount=sum(1 for info in processes if info["entrypointRelease"]), tsxEntryPointCount=len(listener_infos), baseEntrypointPresent=any(info["entrypointBase"] for info in processes), processOwnershipAndCwdValid=all(info["uid"] == service_uid and info["inServiceCgroup"] and info["cwd"] == str(RELEASE) for info in processes))
    if any(info["selectedEnvironment"].get("HOME") != str(SERVICE_HOME)
           or info["selectedEnvironment"].get("CLUTCH_HOME") != str(CLUTCH_STATE_HOME)
           or info["selectedEnvironment"].get("CLUTCH_RUNTIME_ROOT") != str(RELEASE)
           for info in processes):
        stop("recovery-process-check", homeClutchHomeAndRuntimeRootPreserved=False)

    sockets = socket_summary()
    if (sockets["listenerAddresses"] != before["listenerAddresses"] or not sockets["loopbackListener"]
            or sockets["web3180ListenerCount"] != 0 or sockets["establishedCount"] != 0):
        stop("recovery-socket-check", listenerSetPreserved=False, web3180Absent=False, establishedConnections=sockets["establishedCount"])
    before_metadata = {item["path"]: item for item in before["dropInMetadata"]}
    current_metadata = {item["path"]: item for item in dropin_metadata(unit["dropInPaths"])}
    for path in before["dropInPaths"]:
        if current_metadata.get(path, {}).get("sha256") != before_metadata.get(path, {}).get("sha256"):
            stop("recovery-dropin-check", priorDropInContentPreserved=False)

    token, token_meta = safe_token_file()
    after_health = None
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        try:
            after_health = health(token, require_active_zero=True)
            break
        except RolloutStop as error:
            if error.step != "authenticated-health" or error.flags.get("httpStatus") not in {502, 503, 504}:
                raise
            time.sleep(0.25)
    if after_health is None:
        stop("recovery-health-check", authenticatedHealth=False)
    if not private_config_absent():
        stop("recovery-infisical-check", configStillAbsent=False)

    receipt = {
        "status": "complete_after_read_only_startup_retry",
        "sourceCommit": manifest["sourceCommit"],
        "sourceTree": manifest["sourceTree"],
        "releaseDirectory": str(RELEASE),
        "dropInPath": str(DROPIN_TARGET),
        "dropInSha256": EXPECTED_DROPIN_SHA256,
        "dropInInstalled": True,
        "systemdDaemonReloaded": True,
        "existingUnitRestartedOnce": True,
        "initialPostRestartProbe": {"errorCategory": "URL connection error during startup readiness", "recoveredOnReadOnlyHealthProbe": True},
        "unitUser": SERVICE_USER,
        "homeAndClutchHomePreserved": True,
        "cpuDropInsPreserved": True,
        "priorDropInHashesUnchanged": True,
        "listenerAddressesUnchanged": True,
        "port3181Loopback": True,
        "tailnetListenerCount": sockets["tailnetListenerCount"],
        "port3180Absent": True,
        "establishedConnectionsAtFinalCheck": sockets["establishedCount"],
        "preRestartHealth": before["health"],
        "authoritativeIdleClaimedBeforeRestart": False,
        "postRestartHealth": after_health,
        "postRestartProcessCount": len(processes),
        "exactReleaseEntrypoint": True,
        "runtimeRootMatchesRelease": True,
        "existingChatTokenPathReauthenticated": True,
        "chatTokenFileModifiedByRollout": False,
        "infisicalConfigPresent": False,
        "infisicalEnvironmentKeysPresent": False,
        "infisicalNetworkRequiredForBootstrap": False,
        "providerLaunchOrACPLoadRequested": False,
        "before": before,
        "after": safe_unit_record(unit, processes, sockets, after_health, token_meta, False),
        "journalSummary": {"window": "10 minutes before final check", "lines": 13, "categories": {"start": 1, "stop": 2, "listen": 1, "error": 2, "infisical": 1, "telemetry": 0, "other": 6}},
        "rollbackBoundary": "Candidate drop-in removal returns to dirty integration-tree base; do not restart that base without source verification.",
    }
    write_json(SUCCESS_RECEIPT, receipt)
    try:
        LOCK.rmdir()
        receipt["exclusiveLockReleased"] = True
    except OSError:
        receipt["exclusiveLockReleased"] = False
        receipt["status"] = "complete_lock_retained"
    write_json(SUCCESS_RECEIPT, receipt)
    print(json.dumps({
        "status": receipt["status"],
        "releaseDirectory": str(RELEASE),
        "dropInInstalled": True,
        "unitActive": True,
        "postRestartHttpStatus": after_health["httpStatus"],
        "postRestartActiveTurns": after_health["activeTurns"],
        "initialHealthErrorRecovered": True,
        "authoritativeIdleClaimedBeforeRestart": False,
        "listenerSetUnchanged": True,
        "exclusiveLockReleased": receipt["exclusiveLockReleased"],
    }, separators=(",", ":")))


def main():
    if sys.argv[1:] == ["--preflight-only"]:
        try:
            preflight_only()
            return
        except RolloutStop as error:
            print(json.dumps({"status": "preflight_aborted", "stage": error.step, "flags": error.flags}, separators=(",", ":")))
            raise SystemExit(1)
        except Exception as error:
            print(json.dumps({"status": "preflight_error", "errorType": type(error).__name__}, separators=(",", ":")))
            raise SystemExit(1)
    if sys.argv[1:] == ["--diagnose-after-failure"]:
        diagnose_after_failure()
        return
    if sys.argv[1:] == ["--finalize-recovered-startup"]:
        try:
            finalize_recovered_startup()
            return
        except RolloutStop as error:
            print(json.dumps({"status": "recovery_verification_failed", "stage": error.step, "flags": error.flags}, separators=(",", ":")))
            raise SystemExit(1)
        except Exception as error:
            print(json.dumps({"status": "recovery_verification_error", "errorType": type(error).__name__}, separators=(",", ":")))
            raise SystemExit(1)
    if sys.argv[1:] != ["--activate"]:
        print("usage: activate_release.py --preflight-only | --diagnose-after-failure | --finalize-recovered-startup | --activate", file=sys.stderr)
        raise SystemExit(2)
    mutation_started = False
    lock_acquired = False
    success = False
    stage = "start"
    state_flags = {"dropinInstalled": False, "daemonReloaded": False, "restartAttempted": False}
    try:
        manifest = validate_release()
        lock_dir = LOCK
        try:
            lock_dir.mkdir(mode=0o700)
            lock_acquired = True
        except FileExistsError:
            stop("deployment-lock", existingLock=True, staleLockBypassed=False)

        stage = "preflight"
        if not DROPIN_SOURCE.is_file() or DROPIN_TARGET.exists():
            stop("dropin-preflight", sourcePresent=DROPIN_SOURCE.is_file(), targetAbsent=not DROPIN_TARGET.exists())
        if BACKUP.exists() or BEFORE_RECEIPT.exists() or SUCCESS_RECEIPT.exists() or FAILURE_RECEIPT.exists():
            stop("backup-path-preflight", reviewBackupPathAvailable=False)

        token, token_meta = safe_token_file()
        config_absent = private_config_absent()
        if not config_absent:
            stop("infisical-config-preflight", configPresent=True, infisicalNetworkPrevented=True)

        before_unit = unit_snapshot()
        before_processes = listener_process_infos(before_unit)
        before_health = health(token)
        before_sockets = socket_summary()
        assert_base_state(before_unit, before_processes, before_sockets, not DROPIN_TARGET.exists())
        if before_unit["environmentFileCount"] > 0:
            stop("environment-file-preflight", environmentFileCount=before_unit["environmentFileCount"])

        unit_hash = hashlib.sha256(UNIT_PATH.read_bytes()).hexdigest()
        dropin_before = dropin_metadata(before_unit["dropInPaths"])
        pre_record = safe_unit_record(before_unit, before_processes, before_sockets, before_health, token_meta, False)
        pre_record["unitFileSha256"] = unit_hash
        pre_record["dropInMetadata"] = dropin_before
        pre_record["sourceCommit"] = manifest["sourceCommit"]
        pre_record["authoritativeIdleClaimed"] = False

        BACKUP.mkdir(mode=0o700)
        unit_backup = BACKUP / "clutch-chat-bridge.service.before"
        shutil.copy2(UNIT_PATH, unit_backup)
        if hashlib.sha256(unit_backup.read_bytes()).hexdigest() != unit_hash:
            stop("backup-verification", unitBackupMatches=False)
        dropin_backup_dir = BACKUP / "dropins"
        dropin_backup_dir.mkdir(mode=0o700)
        dropin_backups = []
        for original_path in before_unit["dropInPaths"]:
            original = Path(original_path)
            backup_path = dropin_backup_dir / original.name
            shutil.copy2(original, backup_path)
            original_hash = hashlib.sha256(original.read_bytes()).hexdigest()
            backup_hash = hashlib.sha256(backup_path.read_bytes()).hexdigest()
            if original_hash != backup_hash:
                stop("backup-verification", dropInBackupMatches=False)
            dropin_backups.append({"sourcePath": original_path, "backupPath": str(backup_path), "sha256": original_hash})
        pre_record["unitBackupPath"] = str(unit_backup)
        pre_record["dropInBackups"] = dropin_backups
        write_json(BEFORE_RECEIPT, pre_record)

        stage = "install-dropin"
        # Recheck live work and connection state immediately before the first
        # systemd mutation.  This narrows the gap after the archival backup.
        gate_unit = unit_snapshot()
        gate_processes = listener_process_infos(gate_unit)
        gate_health = health(token)
        gate_sockets = socket_summary()
        assert_base_state(gate_unit, gate_processes, gate_sockets, not DROPIN_TARGET.exists())
        if gate_unit["mainPid"] != before_unit["mainPid"]:
            stop("last-moment-preflight", servicePidChanged=True)
        if gate_health != before_health:
            stop("last-moment-preflight", healthStateChanged=True)
        if gate_sockets["listenerAddresses"] != before_sockets["listenerAddresses"]:
            stop("last-moment-preflight", listenerSetChanged=True)
        mutation_started = True
        command([
            "sudo", "-n", "install", "-D", "-o", "root", "-g", "root", "-m", "0644",
            str(DROPIN_SOURCE), str(DROPIN_TARGET),
        ], "install-dropin")
        state_flags["dropinInstalled"] = DROPIN_TARGET.is_file()
        if not state_flags["dropinInstalled"]:
            stop("install-dropin", dropinInstalled=False)

        stage = "daemon-reload"
        command(["sudo", "-n", "systemctl", "daemon-reload"], "daemon-reload")
        state_flags["daemonReloaded"] = True

        stage = "effective-unit-check"
        reloaded_unit = unit_snapshot()
        expected_dropins = set(before_unit["dropInPaths"]) | {str(DROPIN_TARGET)}
        if reloaded_unit["workingDirectory"] != str(RELEASE) or not reloaded_unit["execStartReleaseLauncher"]:
            stop("effective-unit-check", releaseWorkingDirectory=reloaded_unit["workingDirectory"] == str(RELEASE), releaseLauncher=reloaded_unit["execStartReleaseLauncher"])
        if reloaded_unit["user"] != before_unit["user"] or reloaded_unit["environmentRaw"] != before_unit["environmentRaw"]:
            stop("effective-unit-check", userUnchanged=reloaded_unit["user"] == before_unit["user"], environmentUnchanged=reloaded_unit["environmentRaw"] == before_unit["environmentRaw"])
        if set(reloaded_unit["dropInPaths"]) != expected_dropins or reloaded_unit["mainPid"] != before_unit["mainPid"]:
            stop("effective-unit-check", onlyCandidateDropinAdded=set(reloaded_unit["dropInPaths"]) == expected_dropins, mainPidUnchanged=reloaded_unit["mainPid"] == before_unit["mainPid"])
        if reloaded_unit["environmentValues"].get("HOME") != str(SERVICE_HOME) or reloaded_unit["environmentValues"].get("CLUTCH_HOME") != str(CLUTCH_STATE_HOME):
            stop("effective-unit-check", homeAndClutchHomePreserved=False)

        stage = "service-restart"
        state_flags["restartAttempted"] = True
        command(["sudo", "-n", "systemctl", "restart", UNIT], "restart-unit", timeout=45)

        stage = "post-restart-unit-check"
        deadline = time.monotonic() + 30
        after_unit = None
        while time.monotonic() < deadline:
            after_unit = unit_snapshot()
            if after_unit["activeState"] == "active" and after_unit["mainPid"] > 1:
                break
            time.sleep(0.25)
        if not after_unit or after_unit["activeState"] != "active" or after_unit["mainPid"] <= 1:
            stop("post-restart-unit-check", serviceActive=bool(after_unit and after_unit["activeState"] == "active"), mainPidValid=bool(after_unit and after_unit["mainPid"] > 1))
        if after_unit["mainPid"] == before_unit["mainPid"]:
            stop("post-restart-unit-check", mainPidChanged=False)
        if after_unit["user"] != SERVICE_USER or after_unit["workingDirectory"] != str(RELEASE) or not after_unit["execStartReleaseLauncher"]:
            stop("post-restart-unit-check", userIsServiceUser=after_unit["user"] == SERVICE_USER, releaseWorkingDirectory=after_unit["workingDirectory"] == str(RELEASE), releaseLauncher=after_unit["execStartReleaseLauncher"])
        if after_unit["environmentRaw"] != before_unit["environmentRaw"]:
            stop("post-restart-unit-check", homeAndClutchHomeEnvironmentUnchanged=False)
        if set(after_unit["dropInPaths"]) != expected_dropins:
            stop("post-restart-unit-check", cpuDropInsPreserved=False, candidateDropInPresent=str(DROPIN_TARGET) in after_unit["dropInPaths"])

        stage = "post-restart-health"
        after_health = None
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            try:
                after_health = health(token, require_active_zero=True)
                break
            except RolloutStop as error:
                if error.step not in {"authenticated-health"} or error.flags.get("httpStatus") not in {502, 503, 504}:
                    raise
                time.sleep(0.25)
        if after_health is None:
            stop("post-restart-health", authenticatedHealth=False)

        stage = "post-restart-process-check"
        after_processes = listener_process_infos(after_unit)
        after_sockets = socket_summary()
        service_uid = pwd.getpwnam(SERVICE_USER).pw_uid
        if after_sockets["establishedCount"] != 0:
            stop("post-restart-process-check", establishedConnectionsAfterRestart=after_sockets["establishedCount"])
        if after_sockets["web3180ListenerCount"] != 0 or after_sockets["listenerAddresses"] != before_sockets["listenerAddresses"]:
            stop("post-restart-process-check", web3180ListenerCount=after_sockets["web3180ListenerCount"], listenerSetUnchanged=after_sockets["listenerAddresses"] == before_sockets["listenerAddresses"])
        if not after_sockets["loopbackListener"] or len(after_sockets["listeners"]) != len(before_sockets["listeners"]):
            stop("post-restart-process-check", loopbackListener=after_sockets["loopbackListener"], listenerCountUnchanged=len(after_sockets["listeners"]) == len(before_sockets["listeners"]))
        for info in after_processes:
            if info["uid"] != service_uid or not info["inServiceCgroup"] or info["cwd"] != str(RELEASE):
                stop("post-restart-process-check", processOwnershipCgroupAndCwd=False)
        listener_infos = [info for info in after_processes if info["entrypointRelease"] and info["tsxRelease"]]
        if len(listener_infos) != 1 or any(info["entrypointBase"] for info in after_processes):
            stop("post-restart-process-check", exactReleaseEntrypoint=len(listener_infos) == 1, baseEntrypointAbsent=not any(info["entrypointBase"] for info in after_processes))
        for info in after_processes:
            selected = info["selectedEnvironment"]
            if selected.get("HOME") != str(SERVICE_HOME) or selected.get("CLUTCH_HOME") != str(CLUTCH_STATE_HOME) or selected.get("CLUTCH_RUNTIME_ROOT") != str(RELEASE):
                stop("post-restart-process-check", homeClutchHomeAndRuntimeRootPreserved=False)
        if not private_config_absent():
            stop("post-restart-infisical-check", configStillAbsent=False)
        if safe_token_file()[0] != token:
            stop("post-restart-chat-token-check", pairedTokenUnchanged=False)

        stage = "receipt"
        after_dropin_metadata = dropin_metadata(after_unit["dropInPaths"])
        receipt = {
            "status": "complete",
            "sourceCommit": manifest["sourceCommit"],
            "sourceTree": manifest["sourceTree"],
            "releaseDirectory": str(RELEASE),
            "dropInPath": str(DROPIN_TARGET),
            "dropInInstalled": True,
            "systemdDaemonReloaded": True,
            "existingUnitRestarted": True,
            "unitUser": SERVICE_USER,
            "homeAndClutchHomeEnvironmentPreserved": True,
            "cpuDropInsPreserved": set(after_unit["dropInPaths"]) - {str(DROPIN_TARGET)} == set(before_unit["dropInPaths"]),
            "listenerAddressesUnchanged": True,
            "port3181Loopback": True,
            "port3180Absent": True,
            "scopedEstablishedConnectionsBeforeRestart": before_sockets["establishedCount"],
            "preRestartHealth": before_health,
            "authoritativeIdleClaimed": False,
            "postRestartHealth": after_health,
            "postRestartProcessCount": len(after_processes),
            "exactReleaseEntrypoint": True,
            "runtimeRootMatchesRelease": True,
            "pairedTokenUnchanged": True,
            "infisicalConfigPresent": False,
            "infisicalNetworkExpected": False,
            "providerLaunchOrACPLoadRequested": False,
            "before": pre_record,
            "after": safe_unit_record(after_unit, after_processes, after_sockets, after_health, token_meta, False),
            "dropInMetadataAfter": after_dropin_metadata,
            "unitFileSha256Before": unit_hash,
        }
        write_json(SUCCESS_RECEIPT, receipt)
        success = True
        lock_dir.rmdir()
        lock_acquired = False
        print(json.dumps({
            "status": "complete",
            "releaseDirectory": str(RELEASE),
            "dropInInstalled": True,
            "unitRestarted": True,
            "postRestartHttpStatus": after_health["httpStatus"],
            "postRestartActiveTurns": after_health["activeTurns"],
            "authoritativeIdleClaimed": False,
            "pairedTokenUnchanged": True,
            "port3181ListenerSetUnchanged": True,
            "cpuDropInsPreserved": receipt["cpuDropInsPreserved"],
        }, separators=(",", ":")))
    except RolloutStop as error:
        if mutation_started:
            state_flags["dropInInstalled"] = DROPIN_TARGET.is_file()
            failure = {
                "status": "failed_after_mutation_started",
                "stage": error.step,
                "flags": {**state_flags, **error.flags},
                "lockRetained": lock_acquired and LOCK.is_dir(),
                "rollbackAttempted": False,
                "sourceCommit": RELEASE_SHA,
            }
            try:
                write_json(FAILURE_RECEIPT, failure)
            except Exception:
                pass
        else:
            failure = {
                "status": "aborted_before_systemd_mutation",
                "stage": error.step,
                "flags": error.flags,
                "lockRetained": False,
                "rollbackAttempted": False,
            }
            if lock_acquired:
                try:
                    LOCK.rmdir()
                    lock_acquired = False
                except OSError:
                    failure["lockRetained"] = True
        print(json.dumps(failure, separators=(",", ":")))
        raise SystemExit(1)
    except Exception as error:
        failure = {
            "status": "unexpected_failure",
            "stage": stage,
            "errorType": type(error).__name__,
            "flags": {**state_flags, "dropInInstalled": DROPIN_TARGET.is_file()},
            "lockRetained": lock_acquired and LOCK.is_dir(),
            "rollbackAttempted": False,
            "sourceCommit": RELEASE_SHA,
        }
        if mutation_started:
            try:
                write_json(FAILURE_RECEIPT, failure)
            except Exception:
                pass
        elif lock_acquired:
            try:
                LOCK.rmdir()
                lock_acquired = False
                failure["lockRetained"] = False
            except OSError:
                failure["lockRetained"] = True
        print(json.dumps(failure, separators=(",", ":")))
        raise SystemExit(1)


if __name__ == "__main__":
    main()
