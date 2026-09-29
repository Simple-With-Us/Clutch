#!/usr/bin/env bash
# Live-install shim.  Canonical implementation is scripts/harness.sh.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
export HARNESS_RUNTIME_ROOT="${HARNESS_RUNTIME_ROOT:-$HERE}"
exec "$HERE/scripts/harness.sh" "$@"
