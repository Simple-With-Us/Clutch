#!/usr/bin/env bash
# shellcheck shell=bash
# Clutch Infisical backfill for the bash launcher layer.
#
# Sourced by scripts/lib/clutch-env.sh (which every Clutch launcher sources).
# When INFISICAL_TOKEN is present, this pulls the Clutch project's settings
# with the scoped read token (sole source of truth — see
# INFISICAL.md) and exports each managed key that is NOT already set.
# Explicitly-set env vars always win (local override).
#
# Managed keys — keep in sync with src/shared/clutchSettings.ts
# CLUTCH_SETTINGS_SCHEMA and INFISICAL.md "Key inventory".
#
# Never fails the boot: any Infisical error logs a loud warning to stderr
# and leaves the existing environment untouched.  Secret values are never
# printed — key names only.
#
# Requires: python3, which ships with macOS.

CLUTCH_MANAGED_KEYS="MINIMAX_API_KEY DEEPSEEK_API_KEY META_API_KEY CLUTCH_MINIMAX_API_KEY_NAME CLUTCH_MINIMAX_BASE_URL CLUTCH_MINIMAX_MODEL CLUTCH_MINIMAX_PROFILE CLUTCH_WEB_HOST CLUTCH_WEB_PORT CLUTCH_TAILNET_HOST CLUTCH_TAILNET_IPV4 CLUTCH_TRUSTED_HOSTS CLUTCH_SETTINGS_REFRESH_MS CLUTCH_TELEMETRY_ENDPOINT CLUTCH_TELEMETRY_AUTHORIZATION COMETCHAT_APP_ID COMETCHAT_REGION COMETCHAT_AUTH_KEY COMETCHAT_REST_API_KEY COMETCHAT_AGENT_UID CLUTCH_AGENT_PROXY_ENABLED CLUTCH_AGENT_PROXY_ADDRESS CLUTCH_AGENT_PROXY_PROJECT_ID CLUTCH_AGENT_PROXY_ENV CLUTCH_AGENT_PROXY_PATH CLUTCH_AGENT_PROXY_CA_CERT_PATH"
CLUTCH_INFISICAL_PROJECT_ID="077fd6f3-9f9b-438e-9b6f-5c69076cf36c"
# Prod-only guard (owner, 2026-10-10): the dev and staging Infisical environments
# are retired, so a CLUTCH_INFISICAL_ENV override is ignored with a warning.
if [[ -n "${CLUTCH_INFISICAL_ENV:-}" && "${CLUTCH_INFISICAL_ENV}" != "prod" ]]; then
  echo "clutch-infisical-env: CLUTCH_INFISICAL_ENV='${CLUTCH_INFISICAL_ENV}' ignored; Infisical reads only prod (see INFISICAL.md)" >&2
fi
CLUTCH_INFISICAL_ENV="prod"
CLUTCH_INFISICAL_URL="${CLUTCH_INFISICAL_URL:-https://app.infisical.com}"

# Per-host service tokens live in $CLUTCH_HOME/infisical.json. Environment
# values override each file field. File-backed tokens are loaded only in the
# short-lived backfill subprocess and never exported by the launcher shell.
CLUTCH_INFISICAL_CREDENTIALS_TMP=""
_clutch_infisical_credentials() {
  if [[ -n "${INFISICAL_TOKEN:-}" && -n "${INFISICAL_WRITE_TOKEN:-}" && -n "${INFISICAL_PROJECT_ID:-}" ]]; then return 0; fi
  command -v python3 >/dev/null 2>&1 || return 0
  local credentials_file="${CLUTCH_HOME:-$HOME/.clutch}/infisical.json"
  [[ -r "$credentials_file" ]] || return 0

  local tmp
  tmp="$(mktemp -t clutch-infisical-credentials.XXXXXX)" || return 0
  chmod 600 "$tmp"
  if CLUTCH_INFISICAL_CREDENTIALS_OUTPUT="$tmp" python3 - "$credentials_file" <<'PY'
import json, os, shlex, stat, sys

try:
    nofollow = getattr(os, "O_NOFOLLOW", None)
    if nofollow is None:
        sys.exit(2)
    fd = os.open(sys.argv[1], os.O_RDONLY | nofollow)
    file_stat = os.fstat(fd)
    if not stat.S_ISREG(file_stat.st_mode) or stat.S_IMODE(file_stat.st_mode) & 0o077:
        os.close(fd)
        sys.exit(2)
    with os.fdopen(fd, encoding="utf-8") as fh:
        data = json.load(fh)
except Exception:
    sys.exit(2)
if not isinstance(data, dict):
    sys.exit(2)
if not set(data).issubset({"projectId", "serviceToken", "writeServiceToken"}):
    sys.exit(2)

def valid(token):
    return token.startswith("st.") and 20 <= len(token) <= 2048 and not any(ch.isspace() for ch in token)

read_value = data.get("serviceToken")
if not isinstance(read_value, str):
    sys.exit(2)
read_token = read_value.strip()
if not valid(read_token):
    sys.exit(2)

project_value = data.get("projectId")
if "projectId" in data and not isinstance(project_value, str):
    sys.exit(2)
project_id = (project_value or "").strip()

write_value = data.get("writeServiceToken")
write_token = write_value.strip() if isinstance(write_value, str) else ""
if write_token and not valid(write_token):
    write_token = ""

exports = []
for value, name in ((read_token, "INFISICAL_TOKEN"), (write_token, "INFISICAL_WRITE_TOKEN")):
    if value and not os.environ.get(name) and valid(value):
        exports.append("export " + shlex.quote(name) + "=" + shlex.quote(value) + "\n")
if project_id and not os.environ.get("INFISICAL_PROJECT_ID"):
    exports.append("export INFISICAL_PROJECT_ID=" + shlex.quote(project_id) + "\n")
with open(os.environ["CLUTCH_INFISICAL_CREDENTIALS_OUTPUT"], "w", encoding="utf-8") as output:
    output.writelines(exports)
PY
  then
    CLUTCH_INFISICAL_CREDENTIALS_TMP="$tmp"
  else
    rm -f "$tmp"
  fi
  return 0
}

_clutch_infisical_backfill() {
  local credentials_tmp="${CLUTCH_INFISICAL_CREDENTIALS_TMP:-}"
  if [[ -z "${INFISICAL_TOKEN:-}" && -z "$credentials_tmp" ]]; then
    return 0
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    echo "clutch-infisical-env: python3 missing — skipping Infisical backfill" >&2
    [[ -z "$credentials_tmp" ]] || rm -f "$credentials_tmp"
    return 0
  fi

  local tmp helper_dir
  # The helper writes shell exports into an owner-only file, never stdout.
  tmp="$(mktemp -t clutch-infisical-env.XXXXXX)" || {
    [[ -z "$credentials_tmp" ]] || rm -f "$credentials_tmp"
    return 0
  }
  chmod 600 "$tmp"
  helper_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if (
    if [[ -n "$credentials_tmp" ]]; then
      # shellcheck disable=SC1090
      source "$credentials_tmp"
    fi
    CLUTCH_MANAGED_KEYS="$CLUTCH_MANAGED_KEYS" \
      CLUTCH_INFISICAL_PROJECT_ID="$CLUTCH_INFISICAL_PROJECT_ID" \
      CLUTCH_INFISICAL_URL="$CLUTCH_INFISICAL_URL" \
      CLUTCH_INFISICAL_OUTPUT_FILE="$tmp" \
      python3 "$helper_dir/infisical-backfill.py"
  ); then
    # shellcheck disable=SC1090
    source "$tmp"
  fi
  rm -f "$tmp"
  [[ -z "$credentials_tmp" ]] || rm -f "$credentials_tmp"
  return 0
}

_clutch_infisical_credentials
_clutch_infisical_backfill
unset -f _clutch_infisical_credentials _clutch_infisical_backfill
unset CLUTCH_INFISICAL_CREDENTIALS_TMP
