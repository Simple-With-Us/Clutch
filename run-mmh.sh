#!/usr/bin/env bash
# Run the MiniMax headless agent (dsh --profile mmh-headless) with MINIMAX_API_KEY
# loaded into the process environment from ~/.secrets/global-api-keys.
# The key value is never printed. Keep this file 0700.
set -euo pipefail
KEY_FILE="$HOME/.secrets/global-api-keys"
if [ -z "${MINIMAX_API_KEY:-}" ] && [ -f "$KEY_FILE" ]; then
  RAW="$(grep -E '^MINIMAX_API_KEY=' "$KEY_FILE" | cut -d= -f2- | tr -d '\r\n')"
  # Strip one pair of matching outer quotes (the file stores the value quoted).
  case "$RAW" in
    '"'*'"') RAW="${RAW#\"}"; RAW="${RAW%\"}" ;;
    "'"*"'") RAW="${RAW#\'}"; RAW="${RAW%\'}" ;;
  esac
  # shellcheck disable=SC2155
  export MINIMAX_API_KEY="$RAW"
  unset RAW
fi
if [ -z "${MINIMAX_API_KEY:-}" ]; then
  echo "run-mmh: MINIMAX_API_KEY not found in env or $KEY_FILE" >&2
  exit 1
fi
export DSH_HOME="${DSH_HOME:-$HOME/.dsh}"
export DSH_PERMISSION_MODE="${DSH_PERMISSION_MODE:-danger-full-access}"
# MMH_WORKDIR overrides the starting directory (default: harness checkout).
# Each agent lane should use an isolated target-repo worktree, never shared.
# The dsh binary lives in the harness checkout; use its absolute path because
# the workdir has no node_modules of its own.
HARNESS_DIR="$HOME/workspace/harness"
cd "${MMH_WORKDIR:-$HARNESS_DIR}"
exec "$HARNESS_DIR/node_modules/.bin/dsh" --profile mmh-headless "$@"
