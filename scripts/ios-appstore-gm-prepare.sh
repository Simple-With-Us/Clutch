#!/usr/bin/env bash
# Prepare a GitHub-hosted macOS runner to archive BotFleet for TestFlight.
# Maps the existing BotFleet Actions secret names onto the fleet ASC env
# file, then imports the iOS Distribution identity.
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

# Fleet names (ASC_*) if a sibling copy is ever mapped; otherwise the
# six Plumber-set BotFleet names.  APPLE_API_KEY_P8_BASE64 is base64 of
# the p8 body (the retired ios-testflight.yml decoded it the same way).
if [[ -z "${ASC_KEY_ID:-}" && -n "${APPLE_API_KEY_ID:-}" ]]; then
  ASC_KEY_ID="$APPLE_API_KEY_ID"
fi
if [[ -z "${ASC_ISSUER_ID:-}" && -n "${APPLE_API_ISSUER_ID:-}" ]]; then
  ASC_ISSUER_ID="$APPLE_API_ISSUER_ID"
fi
if [[ -z "${IOS_DIST_P12_BASE64:-}" && -n "${IOS_CERT_P12_BASE64:-}" ]]; then
  IOS_DIST_P12_BASE64="$IOS_CERT_P12_BASE64"
fi
if [[ -z "${IOS_DIST_P12_PASSWORD:-}" && -n "${IOS_CERT_PASSWORD:-}" ]]; then
  IOS_DIST_P12_PASSWORD="$IOS_CERT_PASSWORD"
fi

: "${ASC_KEY_ID:?APPLE_API_KEY_ID (or ASC_KEY_ID) required}"
: "${ASC_ISSUER_ID:?APPLE_API_ISSUER_ID (or ASC_ISSUER_ID) required}"
: "${IOS_DIST_P12_BASE64:?IOS_CERT_P12_BASE64 (or IOS_DIST_P12_BASE64) required}"
: "${IOS_DIST_P12_PASSWORD:?IOS_CERT_PASSWORD (or IOS_DIST_P12_PASSWORD) required}"

SECRETS_DIR="${HOME}/.secrets"
mkdir -p "$SECRETS_DIR"
chmod 700 "$SECRETS_DIR"

KEY_PATH="${SECRETS_DIR}/AuthKey.p8"
# Write the p8 without echoing.  Command substitution would strip the
# trailing newline PEM files need, so decode straight to disk.
if [[ -n "${ASC_KEY_P8:-}" ]]; then
  printf '%s\n' "$ASC_KEY_P8" > "$KEY_PATH"
elif [[ -n "${APPLE_API_KEY_P8_BASE64:-}" ]]; then
  case "$APPLE_API_KEY_P8_BASE64" in
    *BEGIN*)
      printf '%s\n' "$APPLE_API_KEY_P8_BASE64" > "$KEY_PATH"
      ;;
    *)
      printf '%s' "$APPLE_API_KEY_P8_BASE64" | base64 --decode > "$KEY_PATH"
      ;;
  esac
else
  die "APPLE_API_KEY_P8_BASE64 (or ASC_KEY_P8) required"
fi
chmod 600 "$KEY_PATH"
if ! grep -q "BEGIN " "$KEY_PATH"; then
  die "ASC p8 did not decode to a PEM private key"
fi

ENV_PATH="${SECRETS_DIR}/appstore-connect.env"
{
  printf 'ASC_KEY_ID=%s\n' "$ASC_KEY_ID"
  printf 'ASC_ISSUER_ID=%s\n' "$ASC_ISSUER_ID"
  printf 'ASC_KEY_PATH=%s\n' "$KEY_PATH"
} > "$ENV_PATH"
chmod 600 "$ENV_PATH"

P12_PATH="${SECRETS_DIR}/ios-distribution.p12"
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

# Identity names only — never dump the p12.
if ! security find-identity -v -p codesigning "$KC_PATH" | grep -q 'Apple Distribution'; then
  die "imported keychain has no Apple Distribution identity"
fi
log "Apple Distribution identity imported"
log "ASC env written (key id length ${#ASC_KEY_ID})"
