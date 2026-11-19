import argparse
import json
import os
import secrets
import shutil
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path


# The node binary comes from CLUTCH_NODE, else PATH.
NODE = Path(os.environ.get("CLUTCH_NODE") or shutil.which("node") or "node")


def free_loopback_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--release", type=Path, required=True)
    args = parser.parse_args()
    release = args.release.resolve()
    tsx = release / "node_modules/tsx/dist/cli.mjs"
    entry = release / "src/web/chat-bridge.ts"
    if not NODE.is_file() or not tsx.is_file() or not entry.is_file():
        raise RuntimeError("staged runtime prerequisites missing")

    with tempfile.TemporaryDirectory(prefix="clutch-health-", dir=os.environ.get("CLUTCH_HEALTH_SCRATCH") or None) as scratch:
        home = Path(scratch) / "home"
        clutch_home = home / ".clutch"
        clutch_home.mkdir(parents=True, mode=0o700)
        token = secrets.token_hex(32)
        token_path = clutch_home / "chat-token"
        token_path.write_text(token + "\n", encoding="utf-8")
        os.chmod(token_path, 0o600)

        port = free_loopback_port()
        environment = {
            "PATH": "/usr/bin:/bin",
            "HOME": str(home),
            "CLUTCH_HOME": str(clutch_home),
            "CLUTCH_CHAT_TOKEN_FILE": str(token_path),
            "CLUTCH_CHAT_PORT": str(port),
            "CLUTCH_TAILNET_HOST": "localhost",
            "CLUTCH_TAILNET_WAIT_SECONDS": "0",
            "CLUTCH_TELEMETRY_ENDPOINT": "",
            "CLUTCH_TELEMETRY_AUTHORIZATION": "",
            "DSH_TELEMETRY_DISABLED": "1",
            "CLUTCH_CHAT_LAUNCHER_DEEPSEEK": "/clutch-health-test/no-provider",
            "CLUTCH_CHAT_LAUNCHER_MINIMAX": "/clutch-health-test/no-provider",
            "CLUTCH_CHAT_LAUNCHER_MUSE": "/clutch-health-test/no-provider",
            "CLUTCH_CHAT_LAUNCHER_MCODE": "/clutch-health-test/no-provider",
        }
        command = [str(NODE), str(tsx), str(entry)]
        child = subprocess.Popen(
            command,
            cwd=release,
            env=environment,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        try:
            opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
            request = urllib.request.Request(
                f"http://127.0.0.1:{port}/clutch/v1/health",
                headers={"Authorization": f"Bearer {token}", "Accept": "application/json"},
            )
            payload = None
            status = None
            for _ in range(100):
                if child.poll() is not None:
                    raise RuntimeError(f"health sidecar exited before response ({child.returncode})")
                try:
                    with opener.open(request, timeout=0.25) as response:
                        status = response.status
                        payload = json.loads(response.read(16_385).decode("utf-8"))
                    break
                except (OSError, urllib.error.URLError):
                    time.sleep(0.05)

            if status != 200 or not isinstance(payload, dict) or payload.get("ok") is not True:
                raise RuntimeError("loopback health response did not pass")
            if payload.get("activeTurns") != 0:
                raise RuntimeError("isolated health process reported an active turn")
            diagnostics = payload.get("diagnostics")
            if not isinstance(diagnostics, dict) or diagnostics.get("configured") is not False:
                raise RuntimeError("telemetry diagnostics were unexpectedly configured")

            print(json.dumps({
                "httpStatus": status,
                "ok": True,
                "activeTurns": 0,
                "telemetryConfigured": False,
                "infisicalTokenPresent": False,
                "providerLaunchersStubbed": True,
                "boundAddress": "127.0.0.1",
            }, separators=(",", ":")))
        finally:
            if child.poll() is None:
                child.terminate()
                try:
                    child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait(timeout=5)


if __name__ == "__main__":
    main()
