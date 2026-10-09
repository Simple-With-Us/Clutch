#!/usr/bin/env bash
# Shellular ACP spawn for Muse Code.  Stdout is JSON-RPC only — every
# diagnostic below goes to stderr.
#
# Muse Code is not itself an ACP agent: `muse serve` speaks MSP, and the
# community adapter `@bex-co/muse-code-acp` translates MSP to ACP on stdio.
# So this wrapper execs the adapter directly and there is no Python bridge —
# the first engine in the repo whose launcher is pure pass-through.
#
# Deliberately does not source lib/clutch-env.sh: Muse Code is not the DSH
# engine, so it has no use for Clutch's engine home.  Same rule as grok.
set -euo pipefail

die() { printf 'muse-code-acp: %s\n' "$1" >&2; exit 1; }

# 1. The adapter.  An explicit MUSE_CODE_ACP_BIN wins, then PATH, then the
#    usual global-install prefixes (a GUI app's PATH is often thinner than an
#    interactive shell's).
find_adapter() {
  if [ -n "${MUSE_CODE_ACP_BIN:-}" ] && [ -x "$MUSE_CODE_ACP_BIN" ]; then
    printf '%s' "$MUSE_CODE_ACP_BIN"; return 0
  fi
  local found
  if found="$(command -v muse-code-acp 2>/dev/null)"; then printf '%s' "$found"; return 0; fi
  for candidate in \
    "$HOME/.local/bin/muse-code-acp" \
    "$(npm prefix -g 2>/dev/null)/bin/muse-code-acp" \
    "/opt/homebrew/bin/muse-code-acp" \
    "/usr/local/bin/muse-code-acp"; do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then printf '%s' "$candidate"; return 0; fi
  done
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

ADAPTER="$(find_adapter)" || die "muse-code-acp not found — install it with: npm install -g @bex-co/muse-code-acp"

if ! MUSE_HOST="$(find_muse)"; then
  printf 'muse-code-acp: muse not found on PATH — install Muse Code, or set MUSE_CODE_EXECUTABLE\n' >&2
  exit 1
fi
export MUSE_CODE_EXECUTABLE="$MUSE_HOST"

exec "$ADAPTER" "$@"