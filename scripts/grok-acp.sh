#!/usr/bin/env bash
# Shellular ACP spawn for Grok Build (leader stdio).  Stdout is JSON-RPC only.
# Strips authMethods so Shellular iOS 0.0.43 does not block session/new.
# Canonical: this repo.  Live phone path may also use ~/apps/grok-acp-runtime/.
#
# Deliberately does not source lib/clutch-env.sh: Grok is not the DSH engine,
# so it has no use for Clutch's engine home.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
export CLUTCH_RUNTIME_ROOT="${CLUTCH_RUNTIME_ROOT:-$ROOT}"
export GROK_DISABLE_AUTOUPDATER="${GROK_DISABLE_AUTOUPDATER:-1}"
export GROK_BIN="${GROK_BIN:-$HOME/.grok/bin/grok}"

PY="${PYTHON:-}"
if [ -z "$PY" ]; then
  if [ -x /opt/homebrew/bin/python3 ]; then
    PY=/opt/homebrew/bin/python3
  else
    PY="$(command -v python3)"
  fi
fi

exec "$PY" "$ROOT/bridges/grok/grok-acp.py" "$@"
