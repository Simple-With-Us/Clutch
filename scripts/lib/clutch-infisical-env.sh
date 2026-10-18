#!/usr/bin/env bash
# shellcheck shell=bash
# Clutch Infisical backfill for the bash launcher layer.
#
# Sourced by scripts/lib/clutch-env.sh (which every Clutch launcher sources).
# When INFISICAL_CLIENT_ID / INFISICAL_CLIENT_SECRET are present, this pulls
# the Clutch Infisical project's settings (sole source of truth — see
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
# Requires: curl, python3.  Both ship with macOS.

CLUTCH_MANAGED_KEYS="MINIMAX_API_KEY DEEPSEEK_API_KEY META_API_KEY CLUTCH_MINIMAX_API_KEY_NAME CLUTCH_MINIMAX_BASE_URL CLUTCH_MINIMAX_MODEL CLUTCH_MINIMAX_PROFILE CLUTCH_WEB_HOST CLUTCH_WEB_PORT CLUTCH_TAILNET_HOST CLUTCH_TAILNET_IPV4 CLUTCH_TRUSTED_HOSTS CLUTCH_SETTINGS_REFRESH_MS COMETCHAT_APP_ID COMETCHAT_REGION COMETCHAT_AUTH_KEY COMETCHAT_REST_API_KEY COMETCHAT_AGENT_UID CLUTCH_AGENT_PROXY_ENABLED CLUTCH_AGENT_PROXY_ADDRESS CLUTCH_AGENT_PROXY_PROJECT_ID CLUTCH_AGENT_PROXY_ENV CLUTCH_AGENT_PROXY_PATH CLUTCH_AGENT_PROXY_CA_CERT_PATH"
CLUTCH_INFISICAL_PROJECT_ID="077fd6f3-9f9b-438e-9b6f-5c69076cf36c"
# Prod-only guard (owner, 2026-10-10): the dev and staging Infisical environments
# are retired, so a CLUTCH_INFISICAL_ENV override is ignored with a warning.
if [[ -n "${CLUTCH_INFISICAL_ENV:-}" && "${CLUTCH_INFISICAL_ENV}" != "prod" ]]; then
  echo "clutch-infisical-env: CLUTCH_INFISICAL_ENV='${CLUTCH_INFISICAL_ENV}' ignored; Infisical reads only prod (see INFISICAL.md)" >&2
fi
CLUTCH_INFISICAL_ENV="prod"
CLUTCH_INFISICAL_URL="${CLUTCH_INFISICAL_URL:-https://app.infisical.com}"

# Local machine identity: $CLUTCH_HOME/infisical.json.
#
# These three values cannot live in Infisical — they are what authenticate the
# read of it — so they come from one owner-only local file, beside chat-token.
# An explicitly-set environment variable always wins, matching the managed-key
# rule below.  Keeping the bash layer in step with src/shared/clutchSettings.ts
# matters: this file runs BEFORE Node starts, so without it a credential saved
# from the settings panel would never reach the pm2-spawned web server.
# Never prints a value.
_clutch_infisical_identity() {
  if [[ -n "${INFISICAL_CLIENT_ID:-}" && -n "${INFISICAL_CLIENT_SECRET:-}" ]]; then
    return 0
  fi
  command -v python3 >/dev/null 2>&1 || return 0
  local identity_file="${CLUTCH_HOME:-$HOME/.clutch}/infisical.json"
  [[ -r "$identity_file" ]] || return 0

  # Warn on a loosened mode; the file holds a machine secret.  Ask python3
  # rather than parsing `ls -l`, so a path with spaces still works.
  local mode
  mode="$(python3 -c 'import os,stat,sys
try:
    print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode))[2:])
except OSError:
    print("")' "$identity_file" 2>/dev/null)" || mode=""
  if [[ -n "$mode" && "$mode" != "600" ]]; then
    echo "clutch-infisical-env: $identity_file holds a machine secret but is mode $mode — run: chmod 600 $identity_file" >&2
  fi

  local tmp
  tmp="$(mktemp -t clutch-infisical-identity.XXXXXX)" || return 0
  if python3 - "$identity_file" >"$tmp" <<'PY'
import json, shlex, sys

try:
    with open(sys.argv[1]) as fh:
        data = json.load(fh)
except Exception:
    sys.exit(2)
if not isinstance(data, dict):
    sys.exit(2)

client_id = str(data.get("clientId") or "").strip()
client_secret = str(data.get("clientSecret") or "").strip()
project_id = str(data.get("projectId") or "").strip()
# A file with no usable credentials is not an identity: leave the environment
# untouched so the caller falls back to its existing behaviour.
if not client_id or not client_secret:
    sys.exit(2)

for name, value in (
    ("INFISICAL_CLIENT_ID", client_id),
    ("INFISICAL_CLIENT_SECRET", client_secret),
    ("CLUTCH_INFISICAL_PROJECT_ID", project_id),
):
    if value:
        print("export " + shlex.quote(name) + "=" + shlex.quote(value))
PY
  then
    # shellcheck disable=SC1090
    source "$tmp"
  fi
  rm -f "$tmp"
  return 0
}

_clutch_infisical_backfill() {
  # Only when universal-auth credentials are present.
  if [[ -z "${INFISICAL_CLIENT_ID:-}" || -z "${INFISICAL_CLIENT_SECRET:-}" ]]; then
    return 0
  fi
  if ! command -v curl >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
    echo "clutch-infisical-env: curl or python3 missing — skipping Infisical backfill" >&2
    return 0
  fi

  local token secrets_json tmp
  token="$(curl -s --max-time 15 -X POST "$CLUTCH_INFISICAL_URL/api/v1/auth/universal-auth/login" \
    -H 'Content-Type: application/json' \
    -d "{\"clientId\":\"$INFISICAL_CLIENT_ID\",\"clientSecret\":\"$INFISICAL_CLIENT_SECRET\"}" 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("accessToken",""))' 2>/dev/null)" || token=""
  if [[ -z "$token" ]]; then
    echo "clutch-infisical-env: universal-auth login failed — keeping process environment (see INFISICAL.md)" >&2
    return 0
  fi

  secrets_json="$(curl -s --max-time 20 "$CLUTCH_INFISICAL_URL/api/v3/secrets/raw?workspaceId=$CLUTCH_INFISICAL_PROJECT_ID&environment=$CLUTCH_INFISICAL_ENV&secretPath=/" \
    -H "Authorization: Bearer $token" 2>/dev/null)" || secrets_json=""
  token=""
  if [[ -z "$secrets_json" ]]; then
    echo "clutch-infisical-env: secrets fetch failed — keeping process environment (see INFISICAL.md)" >&2
    return 0
  fi

  # Generate `export 'KEY'='value'` lines (shell-quoted) for managed keys with
  # an Infisical value that are not already set, then source them.  The temp
  # file is mode 600 (mktemp default) and removed immediately after.
  tmp="$(mktemp -t clutch-infisical-env.XXXXXX)" || return 0
  if printf '%s' "$secrets_json" | CLUTCH_MANAGED_KEYS="$CLUTCH_MANAGED_KEYS" python3 -c '
import json, os, shlex, sys
try:
    data = json.loads(sys.stdin.read())
except Exception:
    sys.exit(2)
managed = os.environ.get("CLUTCH_MANAGED_KEYS", "").split()
values = {s.get("secretKey"): s.get("secretValue", "") for s in data.get("secrets", []) if s.get("secretKey")}
filled = []
for key in managed:
    if os.environ.get(key):
        continue  # explicitly-set env wins
    v = values.get(key)
    if v:
        print("export " + shlex.quote(key) + "=" + shlex.quote(v))
        filled.append(key)
if filled:
    print("echo " + shlex.quote("clutch-infisical-env: backfilled from Infisical: " + " ".join(filled)) + " >&2")
' > "$tmp"; then
    # shellcheck disable=SC1090
    source "$tmp"
  else
    echo "clutch-infisical-env: secrets response unparseable — keeping process environment" >&2
  fi
  rm -f "$tmp"
  return 0
}

_clutch_infisical_identity
_clutch_infisical_backfill
unset -f _clutch_infisical_identity _clutch_infisical_backfill
