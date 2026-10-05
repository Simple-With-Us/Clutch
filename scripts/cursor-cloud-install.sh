#!/usr/bin/env bash
# Clutch — Cursor cloud agent install (Linux / Ubuntu only).
#  Runs during Cursor's Build step; must be idempotent.
#  macOS / iOS / Xcode companion builds are Mac-only and are skipped here
#  with a one-line note.  This script never echoes secret values.

set -euo pipefail

# Two ASCII spaces after periods and colons (fleet copy rule).
REPO_NAME="Clutch"
NODE_MAJOR_MIN=22
ENV_FILE_REL=".cursor/infisical.env"

log() { printf '[cursor-cloud-install] %s\n' "$*" >&2; }

# 1.  Node toolchain — honor repo pin if present, otherwise use the
# minimum major that satisfies package.json's "node" field.
require_node() {
  if command -v node >/dev/null 2>&1; then
    local current_major
    current_major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
    if [[ "${current_major}" =~ ^[0-9]+$ ]] && [[ "${current_major}" -ge "${NODE_MAJOR_MIN}" ]]; then
      log "node $(node -v) present (>= ${NODE_MAJOR_MIN})"
      command -v npm >/dev/null 2>&1 && log "npm $(npm -v) present"
      return 0
    fi
    log "node $(node -v 2>/dev/null || echo missing) below required ${NODE_MAJOR_MIN}"
  fi
  if command -v apt-get >/dev/null 2>&1; then
    log "installing Node ${NODE_MAJOR_MIN}.x via NodeSource"
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR_MIN}.x" | bash - >/dev/null
    apt-get install -y nodejs >/dev/null
    log "node $(node -v) installed; npm $(npm -v)"
  else
    log "WARN: no apt-get and node < ${NODE_MAJOR_MIN} — typecheck/tests may fail"
  fi
}
require_node

# 2.  Install Clutch deps from the committed lockfile.
if [[ -f package-lock.json ]]; then
  log "npm ci (committed lockfile)"
  npm ci --no-audit --no-fund
else
  log "WARN: no package-lock.json at repo root — skipping dependency install"
fi

# 3.  Make the runtime Infisical helper executable so the start script can
#     source it without a chmod round trip.
if [[ -f scripts/lib/clutch-infisical-env.sh ]]; then
  chmod +x scripts/lib/clutch-infisical-env.sh || true
fi

# 4.  macOS / iOS / Xcode companion builds are skipped on Linux.
log "note: iOS companion builds (scripts/build-ios.sh) are macOS-only — skipped"

log "${REPO_NAME} install complete"
