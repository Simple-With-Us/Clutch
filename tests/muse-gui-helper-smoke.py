#!/usr/bin/env python3
"""Account-free macOS smoke tests for the compiled Muse GUI supervisor."""
import argparse
import json
import os
import pathlib
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unittest


STUB = r'''#!{python}
import os, signal, sys, time
assert sys.argv[1] == "acp"
assert os.environ["MUSE_EXPERIMENTAL_ACP"] == "on"
mode = sys.argv[2] if len(sys.argv) > 2 else "echo"
if mode == "exit":
    os.write(1, b"final\\x00bytes\\xff".decode("unicode_escape").encode("latin1"))
    sys.exit(0)
if mode == "exit-large":
    view = memoryview(bytes(range(256)) * 1024)
    while view:
        count = os.write(1, view)
        view = view[count:]
    with open(sys.argv[3], "w") as marker: marker.write("written")
    sys.exit(0)
if mode in ("grandchild", "exit-with-grandchild"):
    child = os.fork()
    if child == 0:
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        while True: time.sleep(1)
    with open(sys.argv[3], "w") as marker: marker.write(str(child))
    if mode == "exit-with-grandchild":
        os.write(1, b"finished")
        sys.exit(0)
while True:
    chunk = os.read(0, 8192)
    if not chunk: break
    view = memoryview(chunk)
    while view:
        count = os.write(1, view)
        view = view[count:]
'''


def receive_exact(connection, count):
    result = bytearray()
    while len(result) < count:
        chunk = connection.recv(count - len(result))
        if not chunk:
            raise EOFError("helper connection closed")
        result.extend(chunk)
    return bytes(result)


def receive_frame(connection):
    length = struct.unpack(">I", receive_exact(connection, 4))[0]
    if length > 65536:
        raise AssertionError("oversized acknowledgement")
    return json.loads(receive_exact(connection, length))


def gone(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return True
    return False


def wait_until(predicate, timeout=4):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.025)
    return predicate()


class HelperSmoke(unittest.TestCase):
    helper = None

    def setUp(self):
        # /tmp is resolved because Darwin's /var spelling can consume most of
        # sockaddr_un's small path limit on CI runners.
        self.scratch = tempfile.TemporaryDirectory(prefix="clutch-muse-gui-", dir="/tmp")
        self.root = pathlib.Path(self.scratch.name)
        os.chmod(self.root, 0o700)
        self.endpoint = self.root / "s"
        self.listener = socket.socket(socket.AF_UNIX)
        self.listener.bind(str(self.endpoint))
        os.chmod(self.endpoint, 0o600)
        self.listener.listen(1)
        self.listener.settimeout(4)
        self.stub = self.root / "muse-stub"
        self.stub.write_text(STUB.format(python=sys.executable))
        self.stub.chmod(0o700)
        self.process = None
        self.connection = None
        self.child = None

    def tearDown(self):
        if self.connection is not None:
            self.connection.close()
        self.listener.close()
        if self.process is not None:
            try:
                self.process.wait(timeout=4)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
                if self.child:
                    try:
                        os.killpg(self.child, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                self.fail("supervisor failed to stop")
        self.scratch.cleanup()

    def launch(self):
        self.process = subprocess.Popen([self.helper, "--socket", str(self.endpoint)],
                                        stdin=subprocess.DEVNULL,
                                        stdout=subprocess.DEVNULL,
                                        stderr=subprocess.DEVNULL)
        self.connection, _ = self.listener.accept()
        self.connection.settimeout(5)

    def configure(self, arguments=None, **overrides):
        self.launch()
        config = dict(version=1, executable=str(self.stub), cwd=str(self.root),
                      arguments=arguments or [], path=os.environ.get("PATH", "/usr/bin:/bin"))
        config.update(overrides)
        payload = json.dumps(config).encode()
        self.connection.sendall(struct.pack(">I", len(payload)) + payload)
        acknowledgement = receive_frame(self.connection)
        if acknowledgement.get("ready"):
            self.child = acknowledgement["pid"]
            self.assertEqual(acknowledgement["pgid"], self.child)
            self.assertEqual(os.getpgid(self.child), self.child)
        return acknowledgement

    def disconnect(self):
        self.connection.close()
        self.connection = None
        self.assertTrue(wait_until(lambda: self.process.poll() is not None))
        self.assertTrue(wait_until(lambda: gone(self.child)))

    def test_opaque_bytes_backpressure_and_disconnect(self):
        self.assertTrue(self.configure()["ready"])
        payload = bytes(range(256)) * 8192
        errors = []

        def send():
            try:
                for index in range(0, len(payload), 997):
                    self.connection.sendall(payload[index:index + 997])
            except Exception as error:
                errors.append(error)

        sender = threading.Thread(target=send, daemon=True)
        sender.start()
        self.assertEqual(receive_exact(self.connection, len(payload)), payload)
        sender.join(5)
        self.assertFalse(sender.is_alive())
        self.assertEqual(errors, [])
        self.disconnect()

    def test_immediate_child_exit_drains_final_output(self):
        self.assertTrue(self.configure(["exit"])["ready"])
        self.assertEqual(receive_exact(self.connection, 12), b"final\x00bytes\xff")
        self.assertEqual(self.connection.recv(1), b"")
        self.assertEqual(self.process.wait(timeout=4), 0)

    def test_slow_consumer_keeps_final_output_after_child_exit(self):
        marker = self.root / "final-written"
        self.assertTrue(self.configure(["exit-large", str(marker)])["ready"])
        self.assertTrue(wait_until(marker.exists))
        # Keep final bytes queued beyond the descendant termination deadline.
        time.sleep(2)
        self.assertEqual(receive_exact(self.connection, 262144), bytes(range(256)) * 1024)
        self.assertEqual(self.connection.recv(1), b"")
        self.assertEqual(self.process.wait(timeout=4), 0)

    def test_disconnect_kills_term_ignoring_grandchild(self):
        marker = self.root / "grandchild-pid"
        self.assertTrue(self.configure(["grandchild", str(marker)])["ready"])
        self.assertTrue(wait_until(marker.exists))
        grandchild = int(marker.read_text())
        self.disconnect()
        self.assertTrue(wait_until(lambda: gone(grandchild)))

    def test_child_exit_stops_descendant_holding_stdout_open(self):
        marker = self.root / "grandchild-pid"
        started = time.monotonic()
        self.assertTrue(self.configure(["exit-with-grandchild", str(marker)])["ready"])
        self.assertTrue(wait_until(marker.exists))
        grandchild = int(marker.read_text())
        self.assertEqual(receive_exact(self.connection, 8), b"finished")
        self.assertEqual(self.connection.recv(1), b"")
        self.assertEqual(self.process.wait(timeout=4), 0)
        self.assertTrue(wait_until(lambda: gone(grandchild)))
        self.assertLess(time.monotonic() - started, 3)

    def test_supervisor_term_cleans_child(self):
        self.assertTrue(self.configure()["ready"])
        self.process.terminate()
        self.assertEqual(self.process.wait(timeout=4), 0)
        self.assertTrue(wait_until(lambda: gone(self.child)))

    def test_bad_configuration_ack_has_only_safe_category(self):
        for value in (True, "1", None):
            with self.subTest(version=value):
                acknowledgement = self.configure(version=value)
                self.assertEqual(acknowledgement, dict(version=1, ready=False, stage="configuration"))
                self.connection.close()
                self.connection = None
                self.process.wait(timeout=4)

    def test_oversized_configuration_rejected_before_read(self):
        self.launch()
        self.connection.sendall(struct.pack(">I", 65537))
        self.assertEqual(receive_frame(self.connection),
                         dict(version=1, ready=False, stage="configuration"))

    def test_nonexecutable_rejected(self):
        self.stub.chmod(0o600)
        self.assertEqual(self.configure(), dict(version=1, ready=False, stage="executable"))

    def test_unsafe_socket_permissions_rejected_without_connection(self):
        self.endpoint.chmod(0o666)
        self.process = subprocess.Popen([self.helper, "--socket", str(self.endpoint)],
                                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.assertEqual(self.process.wait(timeout=4), 1)

    def test_symlink_socket_rejected_without_connection(self):
        alias = self.root / "alias"
        alias.symlink_to(self.endpoint)
        self.process = subprocess.Popen([self.helper, "--socket", str(alias)],
                                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.assertEqual(self.process.wait(timeout=4), 1)

    def test_unsafe_directory_rejected_without_connection(self):
        self.root.chmod(0o755)
        self.process = subprocess.Popen([self.helper, "--socket", str(self.endpoint)],
                                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.assertEqual(self.process.wait(timeout=4), 1)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--helper", required=True)
    arguments, remaining = parser.parse_known_args()
    HelperSmoke.helper = str(pathlib.Path(arguments.helper).resolve())
    unittest.main(argv=[sys.argv[0]] + remaining)
