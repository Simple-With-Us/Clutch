"""Exercise the MiniMax ACP entrypoint with synthetic local credentials."""

import json
import os
import subprocess
import sys
import tempfile
import unittest
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

        process = subprocess.Popen(
            [sys.executable, str(BRIDGE)],
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


if __name__ == "__main__":
    unittest.main()
