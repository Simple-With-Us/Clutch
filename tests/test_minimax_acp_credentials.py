"""Exercise the MiniMax ACP entrypoint with synthetic local credentials."""

import http.server
import json
import os
import subprocess
import sys
import tempfile
import threading
import unittest
import urllib.parse
import uuid
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
BRIDGE = ROOT / "bridges" / "minimax" / "minimax-acp.py"


class MiniMaxBridgeCredentialTests(unittest.TestCase):
    def _run_bridge(
        self,
        *,
        environment_key: str = "",
        key_name: str = "MINIMAX_API_KEY",
        dsh_file_text: str | None = None,
        expected_key: str = "",
        managed_secret_path: str | None = None,
        request_paths: list[str] | None = None,
    ) -> tuple[str, str, str, Path]:
        temp = tempfile.TemporaryDirectory(prefix="clutch-minimax-bridge-")
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        home = root / "home"
        dsh_home = home / ".clutch" / "dsh"
        dsh_home.mkdir(parents=True)
        marker = root / "child-result"
        stub = root / "dsh-stub.py"
        stub.write_text(
            "#!/usr/bin/env python3\n"
            "import os\n"
            "expected = os.environ['EXPECTED_MINIMAX_KEY']\n"
            "result = 'match' if os.environ.get('MINIMAX_API_KEY') == expected else 'mismatch'\n"
            "with open(os.environ['CHILD_MARKER'], 'w', encoding='utf-8') as output:\n"
            "    output.write(result)\n"
            "print('synthetic dsh turn')\n",
            encoding="utf-8",
        )
        stub.chmod(0o700)
        if dsh_file_text is not None:
            (dsh_home / ".credentials.yaml").write_text(dsh_file_text, encoding="utf-8")
            (dsh_home / ".credentials.yaml").chmod(0o600)

        key = environment_key or expected_key
        env = {
            "PATH": os.environ.get("PATH", ""),
            "HOME": str(home),
            "CLUTCH_HOME": str(home / ".clutch"),
            "CLUTCH_BIN": str(stub),
            "EXPECTED_MINIMAX_KEY": key,
            "CHILD_MARKER": str(marker),
            "CLUTCH_MINIMAX_ACP_HEARTBEAT_SEC": "0.5",
            "CLUTCH_MINIMAX_ACP_TIMEOUT_SEC": "10",
        }
        env.pop("MINIMAX_API_KEY", None)
        env["CLUTCH_MINIMAX_API_KEY_NAME"] = key_name
        if environment_key:
            env[key_name] = environment_key

        command = [sys.executable, str(BRIDGE)]
        if managed_secret_path is not None:
            project = str(uuid.uuid4())
            token = f"st.{uuid.uuid4().hex}"

            class FixtureInfisical(http.server.BaseHTTPRequestHandler):
                def do_GET(self) -> None:
                    if request_paths is not None:
                        request_paths.append(self.path)
                    if self.headers.get("Authorization") != f"Bearer {token}":
                        self.send_error(401)
                        return
                    path = urllib.parse.urlsplit(self.path).path
                    if path == "/api/v2/service-token":
                        payload = {
                            "projectId": project,
                            "workspace": project,
                            "permissions": ["read"],
                            "scopes": [{"environment": "prod", "secretPath": managed_secret_path}],
                            "expiresAt": "2099-01-01T00:00:00Z",
                        }
                    elif path == "/api/v3/secrets/raw":
                        payload = {"secrets": [{"secretKey": "MINIMAX_API_KEY", "secretValue": expected_key}]}
                    else:
                        self.send_error(404)
                        return
                    body = json.dumps(payload).encode()
                    self.send_response(200)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)

                def log_message(self, *_args: object) -> None:
                    pass

            server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), FixtureInfisical)
            self.addCleanup(server.server_close)
            self.addCleanup(server.shutdown)
            threading.Thread(target=server.serve_forever, daemon=True).start()
            credentials = home / ".clutch" / "infisical.json"
            credentials.write_text(json.dumps({"projectId": project, "serviceToken": token}), encoding="utf-8")
            credentials.chmod(0o600)
            env["CLUTCH_INFISICAL_URL"] = f"http://127.0.0.1:{server.server_port}"
            env["PYTHON"] = sys.executable
            command = ["/bin/bash", str(ROOT / "scripts" / "minimax-acp.sh")]

        process = subprocess.Popen(
            command,
            cwd=ROOT,
            env=env,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        assert process.stdin is not None
        assert process.stdout is not None
        requests = [
            {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": 1}},
            {"jsonrpc": "2.0", "id": 2, "method": "session/load", "params": {"sessionId": "session-test", "cwd": str(root)}},
            {"jsonrpc": "2.0", "id": 3, "method": "session/prompt", "params": {"sessionId": "session-test", "prompt": [{"type": "text", "text": "fixture prompt"}]}},
        ]
        process.stdin.write("".join(json.dumps(request) + "\n" for request in requests))
        process.stdin.flush()
        lines: list[str] = []
        prompt_reply: dict[str, object] | None = None
        while line := process.stdout.readline():
            lines.append(line)
            try:
                frame = json.loads(line)
            except json.JSONDecodeError:
                continue
            if frame.get("id") == 3:
                prompt_reply = frame
                break
        process.stdin.close()
        stdout_tail, stderr = process.communicate(timeout=10)
        lines.append(stdout_tail)
        self.assertEqual(process.returncode, 0)
        self.assertIsNotNone(prompt_reply)
        return "".join(lines), stderr, json.dumps(prompt_reply), marker

    def test_environment_key_reaches_the_child_and_overrides_dsh_store(self) -> None:
        key = "synthetic-env-key-do-not-print"
        stdout, stderr, reply, marker = self._run_bridge(
            environment_key=key,
            key_name="CUSTOM_MINIMAX_KEY",
            dsh_file_text="export CUSTOM_MINIMAX_KEY: 'fixture-dsh'\n",
        )
        self.assertEqual(marker.read_text(encoding="utf-8"), "match")
        self.assertIn('"stopReason": "endTurn"', reply)
        self.assertNotIn(key, stdout + stderr)

    def test_dsh_credential_file_reaches_the_child(self) -> None:
        key = "synthetic:dsh=key-do-not-print"
        stdout, stderr, reply, marker = self._run_bridge(
            dsh_file_text=f'export MINIMAX_API_KEY = "{key}"\n',
            expected_key=key,
        )
        self.assertEqual(marker.read_text(encoding="utf-8"), "match")
        self.assertIn('"stopReason": "endTurn"', reply)
        self.assertNotIn(key, stdout + stderr)

    def test_alternate_dsh_assignment_reaches_the_child(self) -> None:
        key = "synthetic:alternate=key-do-not-print"
        stdout, stderr, reply, marker = self._run_bridge(
            key_name="CUSTOM_MINIMAX_KEY",
            dsh_file_text=f'export CUSTOM_MINIMAX_KEY: "{key}"\n',
            expected_key=key,
        )
        self.assertEqual(marker.read_text(encoding="utf-8"), "match")
        self.assertIn('"stopReason": "endTurn"', reply)
        self.assertNotIn(key, stdout + stderr)

    def test_missing_key_rejects_prompt_without_starting_child(self) -> None:
        unusable_files = (
            "# comment only\n",
            "OTHER_MINIMAX_API_KEY: fixture-other\n",
            'MINIMAX_API_KEY: ""\n',
            "DEEPSEEK_API_KEY=fixture-other\n",
        )
        for contents in unusable_files:
            with self.subTest(contents=contents):
                stdout, stderr, reply, marker = self._run_bridge(dsh_file_text=contents)
                self.assertFalse(marker.exists())
                self.assertIn("MINIMAX_API_KEY is not configured", reply)
                self.assertNotIn("fleet-secrets", stdout + stderr)

    def test_alternate_missing_key_names_the_native_variable(self) -> None:
        _stdout, _stderr, reply, marker = self._run_bridge(
            key_name="CUSTOM_MINIMAX_KEY",
            dsh_file_text="OTHER_PROVIDER_KEY: unrelated\n",
        )
        self.assertFalse(marker.exists())
        self.assertIn("MINIMAX_API_KEY is not configured", reply)

    def test_supported_launcher_loads_its_own_infisical_binding_before_prompt(self) -> None:
        key = "fixture-managed"
        requests: list[str] = []
        stdout, stderr, reply, marker = self._run_bridge(
            expected_key=key,
            managed_secret_path="/",
            request_paths=requests,
        )
        self.assertEqual(marker.read_text(encoding="utf-8"), "match")
        self.assertIn('"stopReason": "endTurn"', reply)
        self.assertEqual(len(requests), 2)
        self.assertEqual(requests[0], "/api/v2/service-token")
        query = urllib.parse.parse_qs(urllib.parse.urlsplit(requests[1]).query)
        self.assertEqual(query["environment"], ["prod"])
        self.assertEqual(query["secretPath"], ["/"])
        for flag in ("recursive", "include_imports", "expandSecretReferences"):
            self.assertEqual(query[flag], ["false"])
        self.assertNotIn(key, stdout + stderr)

    def test_supported_launcher_refuses_wrong_scope_before_values_or_child(self) -> None:
        requests: list[str] = []
        stdout, stderr, reply, marker = self._run_bridge(
            expected_key="fixture-managed",
            managed_secret_path="/other",
            request_paths=requests,
        )
        self.assertEqual(requests, ["/api/v2/service-token"])
        self.assertFalse(marker.exists())
        self.assertIn("MINIMAX_API_KEY is not configured", reply)
        self.assertNotIn("fixture-managed", stdout + stderr)


if __name__ == "__main__":
    unittest.main()
