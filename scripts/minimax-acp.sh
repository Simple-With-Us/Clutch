#!/usr/bin/env bash
# Shellular ACP spawn for the MiniMax agent (id `minimax`): the Clutch MiniMax
# bridge runs the dsh engine with MiniMax as the model provider.  Stdout is
# JSON-RPC only.  Live: ~/apps/clutch-runtime/scripts/minimax-acp.sh.
set -euo pipefail

# shellcheck source=lib/clutch-env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib/clutch-env.sh"

# DSH_PERMISSION_MODE keeps its upstream name: the shipped dsh-base
# cordis.patch.yml reads it.  The phone cannot answer approval prompts.
export DSH_PERMISSION_MODE="${DSH_PERMISSION_MODE:-danger-full-access}"
export CLUTCH_MINIMAX_PROFILE="${CLUTCH_MINIMAX_PROFILE:-minimax-headless}"
export CLUTCH_MINIMAX_API_KEY_NAME="${CLUTCH_MINIMAX_API_KEY_NAME:-MINIMAX_API_KEY}"
export CLUTCH_MINIMAX_ACP_TIMEOUT_SEC="${CLUTCH_MINIMAX_ACP_TIMEOUT_SEC:-900}"
export CLUTCH_MINIMAX_ACP_HEARTBEAT_SEC="${CLUTCH_MINIMAX_ACP_HEARTBEAT_SEC:-5}"

# The interpreter is found, not assumed: /opt/homebrew is the Mac's path only,
# and this launcher also runs on the Linux server, where a bridge that cannot
# start answers every turn with "bridge exited".
PY="${PYTHON:-}"
if [ -z "$PY" ]; then
  if [ -x /opt/homebrew/bin/python3 ]; then
    PY=/opt/homebrew/bin/python3
  else
    PY="$(command -v python3 || true)"
  fi
fi
if [ -z "$PY" ]; then
  printf '%s\n' "clutch: no python3 found to run the MiniMax ACP bridge" >&2
  exit 127
fi

exec "$PY" "$CLUTCH_RUNTIME_ROOT/bridges/minimax/minimax-acp.py" "$@"
