#!/usr/bin/env python3
"""Launch the GUI Muse ACP helper and relay its byte stream."""

from __future__ import annotations

import ctypes
import json
import os
import selectors
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Callable, NamedTuple

MAX_FRAME_BYTES = 65_536
MAX_PENDING_BYTES = 1_048_576
IO_CHUNK_BYTES = 65_536
STARTUP_TIMEOUT_SECONDS = 30.0
HELPER_WAIT_SECONDS = 5.0
GROUP_TERM_SECONDS = 1.0
SAFE_FAILURE_STAGES = {
    "launch-failed",
    "config-failed",
    "muse-spawn-failed",
    "muse-exited",
    "invalid-ack",
    "helper-timeout",
    "helper-disconnected",
    "helper-startup-failed",
    "peer-identity-unavailable",
    "peer-identity-rejected",
    "socket-path-too-long",
    "socket-setup-failed",
    "output-disconnected",
    "broker-failed",
    "arguments",
    "socket",
    "configuration",
    "executable",
    "directory",
    "spawn",
    "transport",
}


class BrokerFailure(Exception):
    def __init__(self, stage: str):
        super().__init__(stage)
        self.stage = stage if stage in SAFE_FAILURE_STAGES else "broker-failed"


class BrokerInterrupted(Exception):
    def __init__(self, signum: int):
        super().__init__()
        self.signum = signum


class MuseProcessIdentity(NamedTuple):
    pid: int
    uid: int
    pgid: int
    birth: str


def _frame(value: object) -> bytes:
    payload = json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    if not payload or len(payload) > MAX_FRAME_BYTES:
        raise BrokerFailure("config-failed")
    return struct.pack(">I", len(payload)) + payload


def _read_exact(sock: socket.socket, size: int, deadline: float) -> bytes:
    chunks = bytearray()
    while len(chunks) < size:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise BrokerFailure("helper-timeout")
        sock.settimeout(remaining)
        try:
            chunk = sock.recv(size - len(chunks))
        except OSError as exc:
            if isinstance(exc, TimeoutError):
                raise BrokerFailure("helper-timeout") from None
            raise BrokerFailure("helper-disconnected") from None
        if not chunk:
            raise BrokerFailure("helper-disconnected")
        chunks.extend(chunk)
    return bytes(chunks)


def _receive_frame(sock: socket.socket, deadline: float) -> object:
    header = _read_exact(sock, 4, deadline)
    length = struct.unpack(">I", header)[0]
    if length == 0 or length > MAX_FRAME_BYTES:
        raise BrokerFailure("invalid-ack")
    payload = _read_exact(sock, length, deadline)
    try:
        return json.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        raise BrokerFailure("invalid-ack") from None


def _peer_credentials(sock: socket.socket) -> tuple[int, int]:
    if sys.platform == "darwin":
        getpeereid = getattr(ctypes.CDLL(None, use_errno=True), "getpeereid", None)
        if getpeereid is None:
            raise BrokerFailure("peer-identity-unavailable")
        uid = ctypes.c_uint()
        gid = ctypes.c_uint()
        getpeereid.argtypes = [ctypes.c_int, ctypes.POINTER(ctypes.c_uint), ctypes.POINTER(ctypes.c_uint)]
        getpeereid.restype = ctypes.c_int
        if getpeereid(sock.fileno(), ctypes.byref(uid), ctypes.byref(gid)) != 0:
            raise BrokerFailure("peer-identity-unavailable")
        try:
            level = getattr(socket, "SOL_LOCAL", 0)
            peer_pid_option = getattr(socket, "LOCAL_PEERPID", 0x002)
            peer_pid = struct.unpack("i", sock.getsockopt(level, peer_pid_option, struct.calcsize("i")))[0]
        except (OSError, struct.error):
            raise BrokerFailure("peer-identity-unavailable") from None
        return peer_pid, int(uid.value)
    if hasattr(socket, "SO_PEERCRED"):
        credentials = sock.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i"))
        peer_pid, uid, _ = struct.unpack("3i", credentials)
        return peer_pid, uid
    raise BrokerFailure("peer-identity-unavailable")


def _process_snapshot(pid: int) -> tuple[int, int, int, str] | None:
    try:
        result = subprocess.run(
            ["/bin/ps", "-p", str(pid), "-o", "ppid=", "-o", "uid=", "-o", "pgid=", "-o", "lstart="],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            close_fds=True,
            check=False,
            text=True,
            timeout=1.0,
            env={"PATH": "/usr/bin:/bin", "LC_ALL": "C"},
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if result.returncode != 0:
        return None
    fields = result.stdout.strip().split()
    if len(fields) < 4:
        return None
    try:
        ppid, uid, pgid = (int(field) for field in fields[:3])
    except ValueError:
        return None
    birth = " ".join(fields[3:])
    return ppid, uid, pgid, birth


def _helper_executable(helper_app: str) -> str:
    if not os.path.isabs(helper_app):
        raise BrokerFailure("launch-failed")
    app = Path(helper_app)
    executable = app / "Contents" / "MacOS" / "ClutchMuseACP"
    if not app.is_dir() or not executable.is_file() or not os.access(executable, os.X_OK):
        raise BrokerFailure("launch-failed")
    return os.path.realpath(app)


def _launch_helper(helper_app: str, socket_path: str) -> subprocess.Popen[bytes]:
    if sys.platform != "darwin":
        raise BrokerFailure("launch-failed")
    app_path = _helper_executable(helper_app)
    try:
        return subprocess.Popen(
            ["/usr/bin/open", "-g", "-n", "-a", app_path, "--args", "--socket", socket_path],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            close_fds=True,
        )
    except OSError:
        raise BrokerFailure("launch-failed") from None


def _decode_ack(value: object, peer_pid: int, peer_uid: int) -> MuseProcessIdentity:
    if not isinstance(value, dict) or value.get("version") != 1 or type(value.get("ready")) is not bool:
        raise BrokerFailure("invalid-ack")
    if value["ready"] is False:
        stage = value.get("stage")
        if isinstance(stage, str) and stage in SAFE_FAILURE_STAGES:
            raise BrokerFailure(stage)
        raise BrokerFailure("helper-startup-failed")
    pid = value.get("pid")
    pgid = value.get("pgid")
    if type(pid) is not int or type(pgid) is not int or pid <= 1 or pgid <= 1 or pid != pgid:
        raise BrokerFailure("invalid-ack")
    process = _process_snapshot(pid)
    if process is None:
        raise BrokerFailure("invalid-ack") from None
    ppid, uid, actual_pgid, birth = process
    if ppid != peer_pid or uid != peer_uid or uid != os.getuid() or actual_pgid != pgid or not birth:
        raise BrokerFailure("invalid-ack")
    if pgid == os.getpgrp():
        raise BrokerFailure("invalid-ack")
    return MuseProcessIdentity(pid=pid, uid=uid, pgid=pgid, birth=birth)


def _group_matches(identity: MuseProcessIdentity) -> bool:
    process = _process_snapshot(identity.pid)
    return bool(
        process
        and process[1] == identity.uid
        and process[2] == identity.pgid
        and process[3] == identity.birth
        and identity.pgid == identity.pid
        and identity.pgid != os.getpgrp()
    )


def _terminate_group(identity: MuseProcessIdentity | None) -> None:
    if identity is None or not _group_matches(identity):
        return
    try:
        os.killpg(identity.pgid, signal.SIGTERM)
    except (ProcessLookupError, PermissionError):
        return
    time.sleep(GROUP_TERM_SECONDS)
    if _group_matches(identity):
        try:
            os.killpg(identity.pgid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass


def _relay(sock: socket.socket) -> None:
    sock.setblocking(False)
    input_fd = sys.stdin.fileno()
    output_fd = sys.stdout.fileno()
    os.set_blocking(input_fd, False)
    os.set_blocking(output_fd, False)
    selector = selectors.DefaultSelector()
    to_peer = bytearray()
    to_output = bytearray()
    input_open = True
    peer_read_open = True
    peer_write_open = True
    registered: dict[int, object] = {}

    def update(fd: int, fileobj: object, events: int) -> None:
        if events == 0:
            if fd in registered:
                selector.unregister(fileobj)
                registered.pop(fd, None)
        elif fd in registered:
            selector.modify(fileobj, events)
        else:
            selector.register(fileobj, events)
            registered[fd] = fileobj

    try:
        while True:
            if not peer_write_open and not to_peer:
                input_open = False
            if not input_open and not to_peer and peer_write_open:
                try:
                    sock.shutdown(socket.SHUT_WR)
                except OSError:
                    pass
                peer_write_open = False
            if not peer_read_open and not to_output:
                break

            input_events = selectors.EVENT_READ if input_open and len(to_peer) < MAX_PENDING_BYTES and peer_write_open else 0
            peer_events = 0
            if peer_read_open and len(to_output) < MAX_PENDING_BYTES:
                peer_events |= selectors.EVENT_READ
            if peer_write_open and to_peer:
                peer_events |= selectors.EVENT_WRITE
            output_events = selectors.EVENT_WRITE if to_output else 0
            update(input_fd, input_fd, input_events)
            update(sock.fileno(), sock, peer_events)
            update(output_fd, output_fd, output_events)
            if not registered:
                break

            for key, mask in selector.select():
                if key.fd == input_fd and mask & selectors.EVENT_READ:
                    try:
                        chunk = os.read(input_fd, min(IO_CHUNK_BYTES, MAX_PENDING_BYTES - len(to_peer)))
                    except BlockingIOError:
                        continue
                    if chunk:
                        to_peer.extend(chunk)
                    else:
                        input_open = False
                elif key.fd == sock.fileno():
                    if mask & selectors.EVENT_READ:
                        try:
                            chunk = sock.recv(min(IO_CHUNK_BYTES, MAX_PENDING_BYTES - len(to_output)))
                        except BlockingIOError:
                            chunk = None
                        if chunk == b"":
                            peer_read_open = False
                            peer_write_open = False
                            to_peer.clear()
                        elif chunk:
                            to_output.extend(chunk)
                    if mask & selectors.EVENT_WRITE and to_peer:
                        try:
                            sent = sock.send(to_peer)
                        except BlockingIOError:
                            sent = 0
                        if sent:
                            del to_peer[:sent]
                elif key.fd == output_fd and mask & selectors.EVENT_WRITE and to_output:
                    try:
                        sent = os.write(output_fd, to_output)
                    except BlockingIOError:
                        sent = 0
                    except OSError:
                        raise BrokerFailure("output-disconnected") from None
                    if sent:
                        del to_output[:sent]
    finally:
        selector.close()
        os.set_blocking(input_fd, True)
        os.set_blocking(output_fd, True)


class GuiAcpBroker:
    def __init__(
        self,
        helper_app: str,
        executable: str,
        arguments: list[str],
        *,
        open_helper: Callable[[str, str], subprocess.Popen[bytes]] = _launch_helper,
    ):
        if not os.path.isabs(executable):
            raise BrokerFailure("config-failed")
        self.helper_app = helper_app
        self.executable = os.path.abspath(executable)
        self.arguments = arguments
        self.cwd = os.path.abspath(os.getcwd())
        self.path = os.environ.get("PATH", "")
        self.open_helper = open_helper
        self.directory: str | None = None
        self.socket_path: str | None = None
        self.listener: socket.socket | None = None
        self.open_process: subprocess.Popen[bytes] | None = None
        self.muse_identity: MuseProcessIdentity | None = None

    def _prepare(self) -> None:
        try:
            temp_root = os.path.realpath(tempfile.gettempdir())
            self.directory = tempfile.mkdtemp(prefix="clutch-muse-gui-", dir=temp_root)
            os.chmod(self.directory, 0o700)
            self.directory = os.path.realpath(self.directory)
            self.socket_path = os.path.join(self.directory, "acp.sock")
            if len(os.fsencode(self.socket_path)) >= 104:
                raise BrokerFailure("socket-path-too-long")
            listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            self.listener = listener
            listener.bind(self.socket_path)
            os.chmod(self.socket_path, 0o600)
            listener.listen(1)
            listener.settimeout(0.2)
        except BrokerFailure:
            raise
        except OSError:
            raise BrokerFailure("socket-setup-failed") from None

    def _handshake(self) -> socket.socket:
        assert self.listener is not None and self.socket_path is not None and self.directory is not None
        try:
            self.open_process = self.open_helper(self.helper_app, self.socket_path)
        except BrokerFailure:
            raise
        except Exception:
            raise BrokerFailure("launch-failed") from None

        deadline = time.monotonic() + STARTUP_TIMEOUT_SECONDS
        conn: socket.socket | None = None
        while time.monotonic() < deadline:
            if self.open_process.poll() not in (None, 0):
                raise BrokerFailure("launch-failed")
            try:
                conn, _ = self.listener.accept()
                break
            except socket.timeout:
                continue
            except OSError:
                raise BrokerFailure("helper-disconnected") from None
        if conn is None:
            raise BrokerFailure("helper-timeout")
        try:
            peer_pid, peer_uid = _peer_credentials(conn)
            if peer_pid <= 1 or peer_uid != os.getuid():
                raise BrokerFailure("peer-identity-rejected")
            config = {
                "version": 1,
                "executable": self.executable,
                "cwd": self.cwd,
                "arguments": self.arguments,
                "path": self.path,
            }
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise BrokerFailure("helper-timeout")
            conn.settimeout(remaining)
            conn.sendall(_frame(config))
            ack = _receive_frame(conn, deadline)
            self.muse_identity = _decode_ack(ack, peer_pid, peer_uid)
            return conn
        except Exception:
            conn.close()
            raise

    def _cleanup(self) -> None:
        for signum in (signal.SIGINT, signal.SIGTERM):
            try:
                signal.signal(signum, signal.SIG_IGN)
            except (OSError, ValueError):
                pass
        if self.listener is not None:
            try:
                self.listener.close()
            except OSError:
                pass
            self.listener = None
        if self.open_process is not None and self.open_process.poll() is None:
            try:
                self.open_process.wait(timeout=HELPER_WAIT_SECONDS)
            except subprocess.TimeoutExpired:
                try:
                    self.open_process.terminate()
                    self.open_process.wait(timeout=0.5)
                except (OSError, subprocess.TimeoutExpired):
                    try:
                        self.open_process.kill()
                    except OSError:
                        pass
        _terminate_group(self.muse_identity)
        if self.socket_path is not None:
            try:
                os.unlink(self.socket_path)
            except FileNotFoundError:
                pass
            except OSError:
                pass
        if self.directory is not None:
            try:
                os.rmdir(self.directory)
            except OSError:
                pass

    def run(self) -> None:
        conn: socket.socket | None = None
        try:
            self._prepare()
            conn = self._handshake()
            if self.listener is not None:
                self.listener.close()
                self.listener = None
            _relay(conn)
        finally:
            if conn is not None:
                try:
                    conn.close()
                except OSError:
                    pass
            self._cleanup()


def main(
    argv: list[str],
    *,
    open_helper: Callable[[str, str], subprocess.Popen[bytes]] = _launch_helper,
) -> int:
    def interrupt(signum: int, _frame: object) -> None:
        raise BrokerInterrupted(signum)

    signal.signal(signal.SIGINT, interrupt)
    if hasattr(signal, "SIGTERM"):
        signal.signal(signal.SIGTERM, interrupt)
    if len(argv) < 2:
        print("muse-gui-acp: invalid broker arguments", file=sys.stderr)
        return 2
    helper_app, executable, *arguments = argv
    try:
        broker = GuiAcpBroker(helper_app, executable, arguments, open_helper=open_helper)
        broker.run()
        return 0
    except BrokerFailure as failure:
        print(f"muse-gui-acp: {failure.stage}", file=sys.stderr)
        return 1
    except BrokerInterrupted as interruption:
        print("muse-gui-acp: interrupted", file=sys.stderr)
        return 128 + interruption.signum
    except Exception:
        print("muse-gui-acp: broker-failed", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
