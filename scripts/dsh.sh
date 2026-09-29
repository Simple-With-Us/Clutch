#!/usr/bin/env bash
# Legacy name for the pinned Harness CLI.  Retained so anything still
# configured against `dsh` keeps working; new configuration should use
# `harness`.
#
# The implementation moved to scripts/harness.sh.  Delegating rather than
# duplicating matters here: this script is the one the 2026-09-16 self-exec
# incident happened in, and a second copy of the loop guard is a second place
# for it to rot.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TARGET="$HERE/harness.sh"

if [[ ! -x "$TARGET" ]]; then
  echo "harness: missing $TARGET — the pinned CLI wrapper is not installed" >&2
  exit 127
fi

exec "$TARGET" "$@"
