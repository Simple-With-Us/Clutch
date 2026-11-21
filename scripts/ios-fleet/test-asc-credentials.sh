#!/usr/bin/env bash
# Exercise the real ship credential functions with disposable producer outputs.
# Keys are generated here; no host store, provider, or signing service is used.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="${here}/ship-testflight.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export HOME="${tmp}/home" TMPDIR="${tmp}/tmp"
mkdir -p "$HOME" "$TMPDIR"
unset ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_P8 ASC_KEY_PATH
unset APPLE_API_KEY_ID APPLE_API_ISSUER_ID APPLE_API_KEY_P8_BASE64 SENTRY_AUTH_TOKEN
fail() { echo "FAIL: $*" >&2; exit 1; }

gen_pem() {
  node -e 'process.stdout.write(require("crypto").generateKeyPairSync("ec", { namedCurve: "prime256v1" }).privateKey.export({ type: "pkcs8", format: "pem" }))'
}
gen_pem > "${tmp}/raw.p8"
gen_pem > "${tmp}/producer.p8"
chmod 600 "${tmp}/raw.p8" "${tmp}/producer.p8"
export ASC_TEST_LOG="${tmp}/ship.log" ASC_FIXTURE_DIR="$tmp"

# Extract the actual functions, without running the ship/build/provider entry.
funcs="${tmp}/funcs.sh"
{
  echo 'log() { printf "%s\n" "$*" >> "$ASC_TEST_LOG"; }'
  echo 'logerr() { printf "%s\n" "$*" >> "$ASC_TEST_LOG"; }'
  echo 'ASC_TMP_DIR=""'
  printf 'FLEET_DIR=%q\n' "$here"
  awk '
    /^load_secrets\(\) \{/ || /^asc_cleanup\(\) \{/ || /^asc_credential_available\(\) \{/ || /^load_sentry_auth\(\) \{/ { grab = 1 }
    grab { print }
    grab && /^\}/ { grab = 0 }
  ' "$script"
} > "$funcs"
export ASC_FUNCTIONS="$funcs"
grep -q '^load_secrets()' "$funcs" || fail "actual credential function absent"

cat > "${tmp}/compare.cjs" <<'JS'
const fs = require('fs');
const expected = fs.readFileSync(process.argv[2], 'utf8').trim();
const actual = process.argv[3] ? fs.readFileSync(process.argv[3], 'utf8').trim() : String(process.env.ASC_KEY_P8 || '').trim();
if (actual !== expected) process.exit(1);
if (fs.readFileSync(process.env.ASC_TEST_LOG, 'utf8').includes(expected)) process.exit(2);
JS

# A complete direct tuple remains supported and a supplied path is ignored.
: > "$ASC_TEST_LOG"
ASC_KEY_ID=RAWKEY01 ASC_ISSUER_ID=raw-issuer ASC_KEY_P8="$(<"${tmp}/raw.p8")" \
  ASC_KEY_PATH="${tmp}/not-a-source.p8" bash -c '
  set -euo pipefail
  source "$ASC_FUNCTIONS"
  asc_credential_available
  load_secrets
  [[ "$AUTH_MODE" == api_key && "$ASC_KEY_ID" == RAWKEY01 && "$ASC_ISSUER_ID" == raw-issuer ]]
  [[ "$(stat -c %a "$ASC_KEY_PATH" 2>/dev/null || stat -f %Lp "$ASC_KEY_PATH")" == 600 ]]
  [[ "$(stat -c %a "$ASC_TMP_DIR" 2>/dev/null || stat -f %Lp "$ASC_TMP_DIR")" == 700 ]]
  node "$ASC_FIXTURE_DIR/compare.cjs" "$ASC_FIXTURE_DIR/raw.p8" "$ASC_KEY_PATH"
  node "$ASC_FIXTURE_DIR/compare.cjs" "$ASC_FIXTURE_DIR/raw.p8"
  path="$ASC_KEY_PATH"
  asc_cleanup
  [[ ! -e "$path" ]]
' || fail "complete direct tuple or cleanup"
grep -q 'ASC_KEY_PATH is not a credential source' "$ASC_TEST_LOG" || fail "named path ignored silently"

# The complete producer tuple wins as a unit over a different complete raw tuple.
: > "$ASC_TEST_LOG"
APPLE_API_KEY_ID=CIKEY01 APPLE_API_ISSUER_ID=ci-issuer \
  APPLE_API_KEY_P8_BASE64="$(base64 < "${tmp}/producer.p8" | tr -d '\n')" \
  ASC_KEY_ID=RAWKEY01 ASC_ISSUER_ID=raw-issuer ASC_KEY_P8="$(<"${tmp}/raw.p8")" bash -c '
  set -euo pipefail
  source "$ASC_FUNCTIONS"
  load_secrets
  [[ "$AUTH_MODE" == api_key && "$ASC_KEY_ID" == CIKEY01 && "$ASC_ISSUER_ID" == ci-issuer ]]
  node "$ASC_FIXTURE_DIR/compare.cjs" "$ASC_FIXTURE_DIR/producer.p8" "$ASC_KEY_PATH"
  node "$ASC_FIXTURE_DIR/compare.cjs" "$ASC_FIXTURE_DIR/producer.p8"
  path="$ASC_KEY_PATH"
  asc_cleanup
  [[ ! -e "$path" ]]
' || fail "producer tuple precedence"

for kind in absent raw-id raw-key apple-id mixed path-only malformed invalid-id; do
  : > "$ASC_TEST_LOG"
  bash -c '
    set -euo pipefail
    source "$ASC_FUNCTIONS"
    case "$1" in
      raw-id) export ASC_KEY_ID=RAWKEY01 ;;
      raw-key) export ASC_KEY_P8="$(<"$ASC_FIXTURE_DIR/raw.p8")" ;;
      apple-id) export APPLE_API_KEY_ID=CIKEY01 ;;
      mixed) export ASC_KEY_ID=RAWKEY01 APPLE_API_ISSUER_ID=ci-issuer ASC_KEY_P8="$(<"$ASC_FIXTURE_DIR/raw.p8")" ;;
      path-only) export ASC_KEY_ID=RAWKEY01 ASC_ISSUER_ID=raw-issuer ASC_KEY_PATH="$ASC_FIXTURE_DIR/raw.p8" ;;
      malformed) export ASC_KEY_ID=RAWKEY01 ASC_ISSUER_ID=raw-issuer ASC_KEY_P8="not a private key" ;;
      invalid-id) export ASC_KEY_ID=../wrong ASC_ISSUER_ID=raw-issuer ASC_KEY_P8="$(<"$ASC_FIXTURE_DIR/raw.p8")" ;;
    esac
    if load_secrets; then exit 1; fi
    [[ "$AUTH_MODE" == none && -z "$ASC_TMP_DIR" ]]
    [[ ! -e "$HOME/.appstoreconnect" && ! -e "$HOME/.secrets" ]]
  ' _ "$kind" || fail "refusal before staging: $kind"
  grep -Eq 'ASC_KEY_ID|APPLE_API_KEY_ID|ASC_KEY_P8' "$ASC_TEST_LOG" || fail "missing exact binding diagnostic: $kind"
done

# The optional upload stays optional and cannot acquire a root credential.
: > "$ASC_TEST_LOG"
bash -c 'set -euo pipefail; source "$ASC_FUNCTIONS"; load_sentry_auth; [[ -z "${SENTRY_AUTH_TOKEN:-}" ]]'
grep -q 'SENTRY_AUTH_TOKEN missing' "$ASC_TEST_LOG" || fail "optional binding not named"

# Version queries must not stage keys in a command-substitution subshell.
for fn in asc_next_shared_build asc_released_store_version; do
  body="$(awk -v f="$fn" '$0 ~ "^"f"\\(\\) \\{" {g=1} g {print} g && /^}/ {exit}' "$script")"
  [[ -n "$body" ]] || fail "could not read ${fn}"
  if grep -v '^[[:space:]]*#' <<<"$body" | grep -q 'load_secrets'; then
    fail "${fn} stages a key in a command substitution"
  fi
  grep -q 'asc_credential_available' <<<"$body" || fail "${fn} skips credential availability"
done
body="$(awk '/^asc_released_store_version\(\) \{/ {g=1} g {print} g && /^}/ {exit}' "$script")"
if grep -v '^[[:space:]]*#' <<<"$body" | grep -q '2>/dev/null'; then
  fail "released-version diagnostic discarded"
fi
grep -q 'return 4' <<<"$body" || fail "released-version auth status lost"

echo "ok: complete signing tuples, provenance, safe refusal, private staging and cleanup"
