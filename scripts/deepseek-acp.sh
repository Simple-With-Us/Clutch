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

exec /opt/homebrew/bin/python3 "$CLUTCH_RUNTIME_ROOT/bridges/deepseek/deepseek-acp.py" "$@"
