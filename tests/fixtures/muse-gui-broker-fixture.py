#!/usr/bin/env python3
from __future__ import annotations

import json
import importlib.util
import os
import plistlib
import signal
import socket
import stat
import struct
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace
from pathlib import Path


def recv_exact(sock: socket.socket, length: int) -> bytes:
    value = bytearray()
    while len(value) < length:
        chunk = sock.recv(length - len(value))
        if not chunk:
            raise RuntimeError("fixture socket closed early")
        value.extend(chunk)
    return bytes(value)


def recv_frame(sock: socket.socket) -> dict[str, object]:
    size = struct.unpack(">I", recv_exact(sock, 4))[0]
    if size > 65_536:
        raise RuntimeError("oversized fixture config")
    return json.loads(recv_exact(sock, size).decode("utf-8"))


def send_frame(sock: socket.socket, value: dict[str, object]) -> None:
    payload = json.dumps(value, separators=(",", ":")).encode("utf-8")
    sock.sendall(struct.pack(">I", len(payload)) + payload)


def fake_muse(marker_path: str) -> int:
    Path(marker_path + ".started").write_text("started", encoding="utf-8")

    def record_term(_signum: int, _frame: object) -> None:
        Path(marker_path).write_text("terminated", encoding="utf-8")
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, record_term)
    while True:
        time.sleep(1)


def helper(socket_path: str, record_path: str, scenario: str) -> int:
    def record_helper_term(_signum: int, _frame: object) -> None:
        Path(record_path + ".helper-terminated").write_text("terminated", encoding="utf-8")
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, record_helper_term)
    deadline = time.monotonic() + 10
    connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    while True:
        try:
            connection.connect(socket_path)
            break
        except OSError:
            if time.monotonic() >= deadline:
                return 4
            time.sleep(0.01)
    config = recv_frame(connection)
    metadata = {
        "config": config,
        "brokerDirectory": str(Path(socket_path).parent),
        "directoryMode": stat.S_IMODE(os.stat(Path(socket_path).parent).st_mode),
        "socketMode": stat.S_IMODE(os.stat(socket_path).st_mode),
        "helperPid": os.getpid(),
    }
    if scenario == "startup-failure":
        with open(record_path, "w", encoding="utf-8") as target:
            json.dump(metadata, target)
        send_frame(connection, {"version": 1, "ready": False, "stage": "spawn"})
        connection.close()
        return 0
    if scenario == "bad-ack":
        metadata["musePid"] = os.getpid()
        metadata["musePgid"] = os.getpgrp()
        with open(record_path, "w", encoding="utf-8") as target:
            json.dump(metadata, target)
        send_frame(connection, {"version": 1, "ready": True, "pid": os.getpid(), "pgid": os.getpgrp()})
        connection.close()
        return 0

    marker_path = record_path + ".terminated"
    muse = subprocess.Popen(
        [sys.executable, "-S", __file__, "--muse", marker_path],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        close_fds=True,
        start_new_session=True,
    )
    ready_deadline = time.monotonic() + 5
    while not Path(marker_path + ".started").exists() and time.monotonic() < ready_deadline:
        time.sleep(0.01)
    if not Path(marker_path + ".started").exists():
        muse.kill()
        muse.wait()
        connection.close()
        return 5
    metadata["musePid"] = muse.pid
    metadata["musePgid"] = os.getpgid(muse.pid)
    with open(record_path, "w", encoding="utf-8") as target:
        json.dump(metadata, target)

    send_frame(connection, {"version": 1, "ready": True, "pid": muse.pid, "pgid": os.getpgid(muse.pid)})
    if scenario == "helper-loss":
        connection.close()
        # Keep the helper alive briefly so the broker can authenticate the ACK
        # while Muse is still its child, then exercise fallback cleanup.
        time.sleep(0.5)
        return 0
    if scenario == "helper-hung":
        connection.close()
        while True:
            time.sleep(1)
    while True:
        chunk = connection.recv(65_536)
        if not chunk:
            break
        # Deliberately split the byte stream to exercise arbitrary framing.
        sizes = (1, 37, 4093, 8191, 113)
        position = 0
        index = 0
        while position < len(chunk):
            end = min(len(chunk), position + sizes[index % len(sizes)])
            connection.sendall(chunk[position:end])
            position = end
            index += 1
    try:
        os.killpg(os.getpgid(muse.pid), signal.SIGTERM)
    except ProcessLookupError:
        pass
    muse.wait(timeout=3)
    connection.close()
    return 0


def driver(broker_path: str, record_path: str, scenario: str) -> int:
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location("muse_gui_acp", broker_path)
    if spec is None or spec.loader is None:
        return 3
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    GuiAcpBroker = module.GuiAcpBroker
    BrokerFailure = module.BrokerFailure

    if scenario.startswith("bundle-"):
        with tempfile.TemporaryDirectory(prefix="muse-bundle-fixture-") as outer:
            app = Path(outer) / ("Renamed.app" if scenario == "bundle-renamed" else "Clutch.app")
            helper_app = app / "Contents" / "Helpers" / "ClutchMuseACP.app"
            executable = helper_app / "Contents" / "MacOS" / "ClutchMuseACP"
            executable.parent.mkdir(parents=True)
            executable.write_text("fixture executable", encoding="utf-8")
            executable.chmod(0o700)
            (app / "Contents" / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "codes.clutch.macos"}))
            helper_bundle_id = "wrong.id" if scenario == "bundle-bad-id" else "codes.clutch.muse-acp"
            helper_executable = "WrongExecutable" if scenario == "bundle-bad-executable" else "ClutchMuseACP"
            (helper_app / "Contents" / "Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": helper_bundle_id,
                "CFBundleExecutable": helper_executable,
            }))
            if scenario == "bundle-writable":
                helper_app.chmod(0o777)
            verified: list[str] = []
            verifier_result = scenario != "bundle-bad-signature"
            original_lstat = Path.lstat
            if scenario == "bundle-wrong-owner":
                def foreign_owner(path: Path) -> SimpleNamespace:
                    metadata = original_lstat(path)
                    return SimpleNamespace(st_mode=metadata.st_mode, st_uid=99_999)
                Path.lstat = foreign_owner
            try:
                valid_path = module._validate_helper_bundle(
                    str(helper_app),
                    verify_integrity=lambda path: verified.append(path) is None and verifier_result,
                )
                result = {"valid": True, "pathMatches": valid_path == str(helper_app)}
            except BrokerFailure as failure:
                result = {"valid": False, "stage": failure.stage}
            finally:
                Path.lstat = original_lstat
            result["integrityChecks"] = len(verified)
            result["integrityOuterApp"] = bool(verified and verified[0] == str(app))
            with open(record_path, "w", encoding="utf-8") as target:
                json.dump(result, target)
        return 0

    if scenario == "open-environment":
        source = {
            "PATH": "/safe/path",
            "HOME": "/safe/home",
            "USER": "fixture-user",
            "LOGNAME": "fixture-user",
            "TMPDIR": "/safe/tmp",
            "LANG": "C",
            "LC_ALL": "C",
            "LC_CTYPE": "C.UTF-8",
            "META_API_KEY": "fixture-secret-marker",
            "AGENT_SEAT": "fixture-seat",
            "SSH_AUTH_SOCK": "/tmp/fixture-sock",
        }
        value = module._gui_open_environment(source)
        with open(record_path, "w", encoding="utf-8") as target:
            json.dump({"keys": sorted(value), "containsForbidden": any(key in value for key in ("META_API_KEY", "AGENT_SEAT", "SSH_AUTH_SOCK"))}, target)
        return 0

    if scenario == "codesign-command":
        calls: list[tuple[list[str], set[str], float]] = []
        original_run = module.subprocess.run

        def fake_run(command: list[str], **kwargs: object) -> SimpleNamespace:
            calls.append((command, set(kwargs), kwargs.get("timeout", 0)))
            return SimpleNamespace(returncode=0)

        module.subprocess.run = fake_run
        try:
            verified = module._verify_code_integrity("/safe/Clutch.app")
        finally:
            module.subprocess.run = original_run
        command, options, timeout = calls[0]
        with open(record_path, "w", encoding="utf-8") as target:
            json.dump({
                "verified": verified,
                "fixedCommand": command == ["/usr/bin/codesign", "--verify", "--deep", "--strict", "/safe/Clutch.app"],
                "bounded": timeout == 15.0,
                "captured": {"stdout": "stdout" in options, "stderr": "stderr" in options},
            }, target)
        return 0

    with tempfile.TemporaryDirectory(prefix="muse-gui-helper-fixture-") as outer:
        app = Path(outer) / "Fixture.app"
        executable = app / "Contents" / "MacOS" / "ClutchMuseACP"
        executable.parent.mkdir(parents=True)
        executable.write_text("fixture app marker", encoding="utf-8")
        executable.chmod(0o700)

        def open_helper(helper_app: str, socket_path: str) -> subprocess.Popen[bytes]:
            if helper_app != str(app):
                raise RuntimeError("unexpected helper path")
            return subprocess.Popen(
                [sys.executable, "-S", __file__, "--helper", socket_path, record_path, scenario],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                close_fds=True,
                start_new_session=True,
            )

        broker = None
        if scenario == "cli-no-args":
            code = module.main([str(app), sys.executable], open_helper=open_helper)
        else:
            broker = GuiAcpBroker(str(app), sys.executable, ["--fixture-argument"], open_helper=open_helper)
            try:
                broker.run()
            except BrokerFailure as failure:
                print(f"muse-gui-acp: {failure.stage}", file=sys.stderr)
                code = 1
            else:
                code = 0
        if Path(record_path).exists():
            value = json.loads(Path(record_path).read_text(encoding="utf-8"))
            value["brokerDirectoryRemoved"] = not Path(value["brokerDirectory"]).exists()
            value["fallbackSignalObserved"] = Path(record_path + ".terminated").exists()
            value["fakeMuseStarted"] = Path(record_path + ".terminated.started").exists()
            value["helperTerminatedBySignal"] = Path(record_path + ".helper-terminated").exists()
            if value.get("musePid"):
                value["processSnapshotAfter"] = module._process_snapshot(value["musePid"])
            if broker is not None and broker.muse_identity is not None:
                value["brokerIdentity"] = broker.muse_identity._asdict()
            if broker is not None and broker.helper_identity is not None:
                value["helperIdentity"] = broker.helper_identity._asdict()
            Path(record_path).write_text(json.dumps(value), encoding="utf-8")
        return code


if __name__ == "__main__":
    if len(sys.argv) == 5 and sys.argv[1] == "--helper":
        raise SystemExit(helper(sys.argv[2], sys.argv[3], sys.argv[4]))
    if len(sys.argv) == 3 and sys.argv[1] == "--muse":
        raise SystemExit(fake_muse(sys.argv[2]))
    if len(sys.argv) == 5 and sys.argv[1] == "--driver":
        raise SystemExit(driver(sys.argv[2], sys.argv[3], sys.argv[4]))
    raise SystemExit(2)
