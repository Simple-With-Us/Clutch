#!/usr/bin/env bash
# Pinned Clutch CLI.  Never npx.  Never exec this file from itself.
#
# `clutch` is the upstream `dsh` engine pinned in this repo's node_modules and
# run against Clutch's own state home ($CLUTCH_HOME/dsh, default
# ~/.clutch/dsh).  The vanilla `dsh` command is separate and keeps ~/.dsh.
#
# 2026-09-16: a PATH wrapper that execs this script was copied *into* this
# script.  bash then exec'd itself until the CPU pegged and nothing bound the
# web port ("Load failed" on every thread).  Refuse that loop.
#
# node_modules resolves relative to CLUTCH_RUNTIME_ROOT (the repo root), so the
# ~/.local/bin/clutch wrapper can exec this file from anywhere.  npm exposes
# this file as the `clutch` bin through a node_modules/.bin symlink, so the
# real path is resolved before lib/ is located.
set -euo pipefail

self="${BASH_SOURCE[0]}"
while [[ -L "$self" ]]; do
  link_dir="$(cd "$(dirname "$self")" && pwd -P)"
  self="$(readlink "$self")"
  [[ "$self" == /* ]] || self="$link_dir/$self"
done
# shellcheck source=lib/clutch-env.sh
source "$(cd "$(dirname "$self")" && pwd -P)/lib/clutch-env.sh"

BIN="$CLUTCH_RUNTIME_ROOT/node_modules/.bin/dsh"

if [[ ! -x "$BIN" ]]; then
  echo "clutch: missing $BIN — run npm ci in $CLUTCH_RUNTIME_ROOT (never npx)" >&2
  exit 127
fi

bin_dir="$(cd "$(dirname "$BIN")" && pwd)"
case "$bin_dir" in
  */node_modules/.bin) ;;
  *)
    echo "clutch: $BIN is not under node_modules/.bin — refuse self-exec" >&2
    exit 127
    ;;
esac

exec "$BIN" "$@"
