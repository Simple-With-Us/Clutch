#!/usr/bin/env bash
# Prepare a GitHub-hosted macOS runner to archive for TestFlight.
# Maps the existing Infisical-synced exports onto the fleet ASC_* names (exported
# through $GITHUB_ENV for later steps), then imports the iOS Distribution
# identity.  Staging is runner temp only;  nothing is written to the home dir.
# Never prints secret values.  Fail closed on a beta macOS host.
# Canonical siblings: Congress.Trade / DealDex / Socratic.Trade
# scripts/ios-appstore-gm-prepare.sh
set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }
log() { echo "[ios-gm] $*"; }

os=$(sw_vers -productVersion)
build=$(sw_vers -buildVersion)
log "macOS ${os} (${build})"
# Apple seed trains stamp a lowercase letter after the build number
# (26A5406e).  GM builds end in digits (25F84, 24G720).
if echo "$build" | grep -Eq '[0-9][a-z]$'; then
  die "beta macOS host ${os} (${build}).  App Store review rejects these as INVALID_BINARY.  Use GitHub-hosted macos-latest (GM)."
fi

# Complete Infisical-synced tuples only; no field borrows from another source.
KEY_PEM=""
if [[ -n "${APPLE_API_KEY_ID:-}" && -n "${APPLE_API_ISSUER_ID:-}" && -n "${APPLE_API_KEY_P8_BASE64:-}" ]]; then
  ASC_KEY_ID="$APPLE_API_KEY_ID"
  ASC_ISSUER_ID="$APPLE_API_ISSUER_ID"
  case "$APPLE_API_KEY_P8_BASE64" in
    *BEGIN*) KEY_PEM="$APPLE_API_KEY_P8_BASE64" ;;
    *) KEY_PEM="$(printf '%s' "$APPLE_API_KEY_P8_BASE64" | base64 --decode 2>/dev/null)" \
      || die "APPLE_API_KEY_P8_BASE64 must encode a PEM private key" ;;
  esac
elif [[ -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER_ID:-}" && -n "${ASC_KEY_P8:-}" ]]; then
  KEY_PEM="$ASC_KEY_P8"
else
  die "require complete APPLE_API_KEY_ID, APPLE_API_ISSUER_ID, APPLE_API_KEY_P8_BASE64 or ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_P8 from the signing export"
fi
[[ "$ASC_KEY_ID" =~ ^[A-Za-z0-9]+$ && "$ASC_ISSUER_ID" =~ [^[:space:]] ]] \
  || die "require alphanumeric ASC_KEY_ID or APPLE_API_KEY_ID and a nonempty ASC_ISSUER_ID or APPLE_API_ISSUER_ID"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
node "${SCRIPT_DIR}/ios-fleet/asc-key.mjs" validate >/dev/null 2>&1 <<< "$KEY_PEM" \
  || die "ASC_KEY_P8 or APPLE_API_KEY_P8_BASE64 must hold a PEM private key"

if [[ -n "${IOS_DIST_P12_BASE64:-}" && -n "${IOS_DIST_P12_PASSWORD:-}" ]]; then
  : # Existing complete direct certificate tuple.
elif [[ -n "${IOS_CERT_P12_BASE64:-}" && -n "${IOS_CERT_PASSWORD:-}" ]]; then
  IOS_DIST_P12_BASE64="$IOS_CERT_P12_BASE64"
  IOS_DIST_P12_PASSWORD="$IOS_CERT_PASSWORD"
else
  die "require complete IOS_CERT_P12_BASE64, IOS_CERT_PASSWORD or IOS_DIST_P12_BASE64, IOS_DIST_P12_PASSWORD from the signing export"
fi

umask 077
# Runner temp (a throwaway VM on hosted CI).  Both files stay for the later
# ship step;  the runner is discarded after the job.
STAGE_DIR="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/ios-signing"
mkdir -p "$STAGE_DIR"
chmod 700 "$STAGE_DIR"

KEY_PATH="${STAGE_DIR}/AuthKey_${ASC_KEY_ID}.p8"
# Write the validated p8 without echoing and restore its trailing newline.
printf '%s\n' "$KEY_PEM" > "$KEY_PATH"
KEY_PEM=""
chmod 600 "$KEY_PATH"
if ! grep -q "BEGIN " "$KEY_PATH"; then
  die "ASC p8 did not decode to a PEM private key"
fi

# Later steps (scripts/ios-ship-testflight.sh) read the ASC_* trio from the
# environment.
if [[ -n "${GITHUB_ENV:-}" ]]; then
  {
    echo "ASC_KEY_ID=${ASC_KEY_ID}"
    echo "ASC_ISSUER_ID=${ASC_ISSUER_ID}"
    echo "ASC_KEY_PATH=${KEY_PATH}"
  } >> "$GITHUB_ENV"
fi

P12_PATH="${STAGE_DIR}/ios-distribution.p12"
printf '%s' "$IOS_DIST_P12_BASE64" | base64 --decode > "$P12_PATH"
chmod 600 "$P12_PATH"

KC_DIR="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
KC_PATH="${KC_DIR}/app-signing.keychain-db"
KC_PASS_FILE="${KC_DIR}/app-signing-kc-pass"
openssl rand -base64 24 > "$KC_PASS_FILE"
chmod 600 "$KC_PASS_FILE"
KC_PASS=$(cat "$KC_PASS_FILE")

security delete-keychain "$KC_PATH" >/dev/null 2>&1 || true
security create-keychain -p "$KC_PASS" "$KC_PATH"
security set-keychain-settings -lut 21600 "$KC_PATH"
security unlock-keychain -p "$KC_PASS" "$KC_PATH"
security import "$P12_PATH" -k "$KC_PATH" -P "$IOS_DIST_P12_PASSWORD" \
  -T /usr/bin/codesign -T /usr/bin/security -T /usr/bin/xcodebuild >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k "$KC_PASS" "$KC_PATH" >/dev/null
security list-keychain -d user -s "$KC_PATH" login.keychain-db

# Identity names only -- never dump the p12.
if ! security find-identity -v -p codesigning "$KC_PATH" | grep -q 'Apple Distribution'; then
  die "imported keychain has no Apple Distribution identity"
fi
log "Apple Distribution identity imported"
log "ASC key staged (key id length ${#ASC_KEY_ID})"
