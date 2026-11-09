#!/usr/bin/env bash
# Post-sync ensure-tf-ready recheck for hosted ios-ship.yml (OPS-1052).
# Read-only ASC polling; uses the same readiness labels as ship-testflight.sh.
set -euo pipefail

APP_KEY="${1:?app key (clutch)}"
BUILD_NUM="${2:?CFBundleVersion build number}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FLEET_DIR="${IOS_RECHECK_FLEET_DIR:-${ROOT}/scripts/ios-fleet}"
# shellcheck source=scripts/ios-fleet/tf-ready-rc.sh
source "${FLEET_DIR}/tf-ready-rc.sh"

_APP_META_TMP="$(mktemp)"
if ! python3 - "$APP_KEY" "${FLEET_DIR}/apps.json" >"$_APP_META_TMP" <<'PY'
import json, sys
app_key, path = sys.argv[1], sys.argv[2]
try:
    data = json.load(open(path, encoding="utf-8"))
except (OSError, json.JSONDecodeError) as err:
    print(f"::error::recheck-tf-ready: could not read apps.json ({err})", file=sys.stderr)
    sys.exit(2)
apps = data.get("apps")
if not isinstance(apps, dict):
    print("::error::recheck-tf-ready: apps.json has no apps map", file=sys.stderr)
    sys.exit(2)
app = apps.get(app_key)
if not isinstance(app, dict):
    print(f"::error::recheck-tf-ready: unknown app key {app_key!r} in apps.json", file=sys.stderr)
    sys.exit(2)
bundle = app.get("bundleId")
if not bundle or not str(bundle).strip():
    print(f"::error::recheck-tf-ready: apps.json apps.{app_key}.bundleId is missing", file=sys.stderr)
    sys.exit(2)
apple = app.get("appleId")
if apple is None or not str(apple).strip():
    print(f"::error::recheck-tf-ready: apps.json apps.{app_key}.appleId is missing", file=sys.stderr)
    sys.exit(2)
marketing = app.get("fixedMarketingVersion") or app.get("marketingVersionDefault") or "1.0.0"
print(bundle)
print(marketing)
print(apple)
PY
then
  rm -f "$_APP_META_TMP"
  exit 2
fi
BUNDLE_ID=""
MARKETING=""
APPLE_ID=""
{
  IFS= read -r BUNDLE_ID || exit 2
  IFS= read -r MARKETING || exit 2
  IFS= read -r APPLE_ID || exit 2
} <"$_APP_META_TMP"
rm -f "$_APP_META_TMP"
if [[ -z "$BUNDLE_ID" || -z "$APPLE_ID" ]]; then
  echo "::error::recheck-tf-ready: apps.json metadata was incomplete after validation"
  exit 2
fi

[[ "$BUILD_NUM" =~ ^[1-9][0-9]{11}$ ]] || {
  echo "::error::recheck-tf-ready for ${APP_KEY}: build '${BUILD_NUM}' is not a 12-digit merge-stamp build"
  exit 1
}

LOG_DIR="${TMPDIR:-/tmp}/ios-tf-recheck-${APP_KEY}-$$"
mkdir -p "$LOG_DIR"
set +e
node "${FLEET_DIR}/asc-api.mjs" ensure-tf-ready "$BUNDLE_ID" "$BUILD_NUM" "$MARKETING" "$APPLE_ID" \
  >"${LOG_DIR}/ensure-tf-ready.json" 2>"${LOG_DIR}/ensure-tf-ready.err"
rc=$?
set -e

if [[ -s "${LOG_DIR}/ensure-tf-ready.err" ]]; then
  while IFS= read -r line; do log "tf-ready (post-sync): $line"; done <"${LOG_DIR}/ensure-tf-ready.err"
fi

handle_ensure_tf_ready_rc "$rc"
summary="$(tf_ready_rc_summary_label "$rc")"
log "post-sync readiness for ${APP_KEY} (${BUNDLE_ID} build ${BUILD_NUM}): rc=${rc} — ${summary}"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "tf_ready_rc=${rc}"
    echo "tf_ready_summary=${summary}"
    echo "tf_ready_bundle=${BUNDLE_ID}"
    echo "tf_ready_build=${BUILD_NUM}"
  } >>"$GITHUB_OUTPUT"
fi

exit 0
