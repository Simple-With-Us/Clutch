#!/usr/bin/env bash
# Pinned Harness CLI.  Never npx.  Never exec this file.
#
# This is the canonical entry point.  `scripts/dsh.sh` is a compat shim that
# execs this one, so the engine keeps its old name for anything still
# configured against it while everything new is called `harness`.
#
# 2026-09-16: a PATH wrapper that execs this script was copied *into* this
# script.  bash then exec'd itself until the CPU pegged and nothing bound
# :3080 (Harness "Load failed" on every thread).  Refuse that loop.
#
# Resolves node_modules relative to HARNESS_RUNTIME_ROOT (the repo root)
# rather than this file's directory, so a symlinked install under
# ~/apps/harness-runtime/scripts/ still finds node_modules at the
# symlink target's root.
set -euo pipefail

if [[ -n "${HARNESS_RUNTIME_ROOT:-}" ]]; then
  ROOT="$HARNESS_RUNTIME_ROOT"
else
  ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fi
BIN="$ROOT/node_modules/.bin/dsh"

if [[ ! -x "$BIN" ]]; then
  echo "harness: missing $BIN — run npm ci in $ROOT (never npx)" >&2
  exit 127
fi

bin_dir="$(cd "$(dirname "$BIN")" && pwd)"
case "$bin_dir" in
  */node_modules/.bin) ;;
  *)
    echo "harness: $BIN is not under node_modules/.bin — refuse self-exec" >&2
    exit 127
    ;;
esac

exec "$BIN" "$@"
