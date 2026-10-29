#!/usr/bin/env bash
# Shellular ACP spawn for Muse Code.  Stdout is JSON-RPC only — every
# diagnostic below goes to stderr.
#
# Current Muse Code builds expose experimental ACP v1 directly as `muse acp`.
# Older builds still work through the community `@bex-co/muse-code-acp`
# MSP-to-ACP adapter.  Auto mode probes the installed Muse binary and prefers
# the native route when it proves support; the adapter remains a compatibility
# backend and the fallback for older hosts.
#
# Deliberately does not source lib/clutch-env.sh: Muse Code is not the DSH
# engine, so it has no use for Clutch's engine home.  Same rule as grok.
set -euo pipefail

die() { printf 'muse-code-acp: %s\n' "$1" >&2; exit 1; }

BACKEND="${MUSE_CODE_ACP_BACKEND:-auto}"
case "$BACKEND" in
  auto|native|adapter) ;;
  *) die "MUSE_CODE_ACP_BACKEND must be auto, native, or adapter" ;;
esac

# 1. The adapter.  An explicit MUSE_CODE_ACP_BIN wins, then PATH, then the
#    usual global-install prefixes (a GUI app's PATH is often thinner than an
#    interactive shell's).
#
#    MUSE_CODE_ACP_SEARCH_PATHS replaces that list with colon-separated
#    directories, so a machine that keeps the adapter outside the global
#    npm prefix (the fleet runtime does) can point at it exactly, and a
#    machine that must not find a stray global copy can point somewhere
#    empty.
find_adapter() {
  if [ -n "${MUSE_CODE_ACP_BIN:-}" ] && [ -x "$MUSE_CODE_ACP_BIN" ]; then
    printf '%s' "$MUSE_CODE_ACP_BIN"; return 0
  fi
  local found
  if found="$(command -v muse-code-acp 2>/dev/null)"; then printf '%s' "$found"; return 0; fi
  local candidates=""
  if [ -n "${MUSE_CODE_ACP_SEARCH_PATHS:-}" ]; then
    candidates="${MUSE_CODE_ACP_SEARCH_PATHS}"
  else
    candidates="${HOME}/.local/bin:$(npm prefix -g 2>/dev/null)/bin:/opt/homebrew/bin:/usr/local/bin"
  fi
  local dir
  local saved_ifs="$IFS"
  IFS=':'
  for dir in $candidates; do
    IFS="$saved_ifs"
    [ -n "$dir" ] || continue
    if [ -x "$dir/muse-code-acp" ]; then printf '%s' "$dir/muse-code-acp"; return 0; fi
    IFS=':'
  done
  IFS="$saved_ifs"
  return 1
}

# 2. The Muse host.  The adapter defaults to PATH discovery, but a GUI-launched
#    client does not inherit the shell PATH, so point it at the `muse`
#    launcher explicitly.  The launcher — not a versioned `muse-bin-*` — is the
#    durable target: the adapter's own docs note that pinning an old launcher
#    cache does not survive the launcher's update-and-prune cycle.
find_muse() {
  if [ -n "${MUSE_CODE_EXECUTABLE:-}" ] && [ -x "$MUSE_CODE_EXECUTABLE" ]; then
    printf '%s' "$MUSE_CODE_EXECUTABLE"; return 0
  fi
  local found
  if found="$(command -v muse 2>/dev/null)"; then printf '%s' "$found"; return 0; fi
  if [ -x "$HOME/.local/bin/muse" ]; then printf '%s' "$HOME/.local/bin/muse"; return 0; fi
  return 1
}

if ! MUSE_HOST="$(find_muse)"; then
  printf 'muse-code-acp: muse not found on PATH — install Muse Code, or set MUSE_CODE_EXECUTABLE\n' >&2
  exit 1
fi
export MUSE_CODE_EXECUTABLE="$MUSE_HOST"

native_supported() {
  local gate="${MUSE_EXPERIMENTAL_ACP:-on}"
  MUSE_EXPERIMENTAL_ACP="$gate" "$MUSE_HOST" acp --help >/dev/null 2>&1 &
  local probe_pid=$!
  local ticks=0
  while kill -0 "$probe_pid" >/dev/null 2>&1; do
    if (( ticks >= 50 )); then
      kill "$probe_pid" >/dev/null 2>&1 || true
      wait "$probe_pid" 2>/dev/null || true
      return 1
    fi
    sleep 0.1
    ((ticks += 1))
  done
  if wait "$probe_pid"; then
    return 0
  fi
  return 1
}

if [ "$BACKEND" != "adapter" ]; then
  if native_supported; then
    export MUSE_EXPERIMENTAL_ACP="${MUSE_EXPERIMENTAL_ACP:-on}"
    exec "$MUSE_HOST" acp "$@"
  fi
  if [ "$BACKEND" = "native" ]; then
    die "native ACP is unavailable — update Muse Code, set MUSE_EXPERIMENTAL_ACP=on, or use MUSE_CODE_ACP_BACKEND=adapter"
  fi
fi

ADAPTER="$(find_adapter)" || die "native ACP is unavailable and muse-code-acp was not found — update Muse Code or install the fallback with: npm install -g @bex-co/muse-code-acp"
exec "$ADAPTER" "$@"
