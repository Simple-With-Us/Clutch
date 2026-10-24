#!/usr/bin/env bash
# Install the Clutch chat bridge as an always-on systemd service on a Linux
# MiniMax Code server host: a machine with `mcode` installed and signed in
# that phones and Macs should reach over Tailscale.  The sidecar binds
# loopback only; `scripts/chat-bridge.sh` publishes it through
# `tailscale serve` (tailnet-only), and every request still needs the
# sidecar's Bearer token.
#
#   bash scripts/install-server-bridge.sh [--user <name>]
#
# Run as root (or with sudo) on the server.  Prerequisites: node 22+,
# `npm ci` already run in this checkout, tailscale signed in, and
# `mcode login` completed as the service user.  See
# docs/minimax-code-server.md.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SERVICE_USER="${SUDO_USER:-$(id -un)}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --user) SERVICE_USER="$2"; shift 2 ;;
    *) echo "install-server-bridge: unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ "$(id -u)" != "0" ]]; then
  echo "install-server-bridge: run as root (it writes /etc/systemd/system)." >&2
  exit 1
fi
SERVICE_HOME="$(getent passwd "$SERVICE_USER" | cut -d: -f6)"
if [[ -z "$SERVICE_HOME" || ! -d "$SERVICE_HOME" ]]; then
  echo "install-server-bridge: no home directory for user $SERVICE_USER." >&2
  exit 1
fi
if [[ ! -x "$ROOT/node_modules/.bin/tsx" ]]; then
  echo "install-server-bridge: missing $ROOT/node_modules/.bin/tsx — run npm ci in $ROOT first." >&2
  exit 127
fi

UNIT=/etc/systemd/system/clutch-chat-bridge.service
sed -e "s|__ROOT__|$ROOT|g" -e "s|__USER__|$SERVICE_USER|g" -e "s|__HOME__|$SERVICE_HOME|g" \
  "$ROOT/scripts/systemd/clutch-chat-bridge.service" > "$UNIT"

systemctl daemon-reload
systemctl enable --now clutch-chat-bridge.service

echo "install-server-bridge: clutch-chat-bridge running as $SERVICE_USER from $ROOT" >&2
echo "install-server-bridge: check it with: systemctl status clutch-chat-bridge" >&2
echo "install-server-bridge: pair a phone or Mac with: node $ROOT/src/web/pair-ios.ts --server" >&2
