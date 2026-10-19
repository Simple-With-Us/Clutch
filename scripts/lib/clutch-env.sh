# shellcheck shell=bash
# Shared environment for every Clutch launcher that runs the DSH engine.
# Sourced, never executed.
#
# Sourced by: scripts/clutch.sh, start-web.sh, ensure-web.sh,
# serve-tailscale.sh, dsh-acp.sh and minimax-acp.sh.  grok-acp.sh deliberately
# does not source it: Grok is not the DSH engine and has no use for an engine
# home.
#
# State isolation: Clutch keeps its engine state in $CLUTCH_HOME/dsh
# (default ~/.clutch/dsh).  DSH_HOME is set unconditionally, never
# `${DSH_HOME:-...}`, because vanilla `dsh` and BotFleet own ~/.dsh and an
# inherited DSH_HOME would silently point Clutch back at their state.

_clutch_env_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
export CLUTCH_RUNTIME_ROOT="${CLUTCH_RUNTIME_ROOT:-$_clutch_env_root}"
unset _clutch_env_root

# Infisical backfill FIRST: managed app settings come from the Clutch
# Infisical project (sole source of truth — see INFISICAL.md).  Keys already
# set in the environment keep winning; the defaults below only fill the rest.
# shellcheck source=lib/clutch-infisical-env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/clutch-infisical-env.sh"

export CLUTCH_HOME="${CLUTCH_HOME:-$HOME/.clutch}"
export DSH_HOME="$CLUTCH_HOME/dsh"
export CLUTCH_WEB_HOST="${CLUTCH_WEB_HOST:-127.0.0.1}"
export CLUTCH_WEB_PORT="${CLUTCH_WEB_PORT:-3180}"

# Credentials live under DSH_HOME, so both directories are owner-only.
(umask 077 && mkdir -p "$DSH_HOME")
