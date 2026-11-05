#!/usr/bin/env bash
# Shellular ACP spawn for the DeepSeek agent (id `deepseek`).  Stdout is
# JSON-RPC only.  Live: ~/apps/clutch-runtime/scripts/deepseek-acp.sh.
set -euo pipefail

# shellcheck source=lib/clutch-env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib/clutch-env.sh"

# DSH_PERMISSION_MODE keeps its upstream name: the shipped dsh-base
# cordis.patch.yml reads it.  The phone cannot answer approval prompts.
export DSH_PERMISSION_MODE="${DSH_PERMISSION_MODE:-danger-full-access}"
export CLUTCH_DEEPSEEK_PROFILE="${CLUTCH_DEEPSEEK_PROFILE:-deepseek-headless}"

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
  printf '%s\n' "clutch: no python3 found to run the DeepSeek ACP bridge" >&2
  exit 127
fi

exec "$PY" "$CLUTCH_RUNTIME_ROOT/bridges/deepseek/deepseek-acp.py" "$@"
