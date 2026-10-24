#!/usr/bin/env bash
# test-ship-seq.sh - Offline tests for ship-testflight.sh's version rules.
#
# Covers:
#   1. ORDERING: a run rejected by the ship gate must NOT resolve or consume
#      a version.  It used to: the gate was evaluated after the counter had
#      already been advanced, so a rate-limited attempt burned a version that
#      shipped nowhere (observed live: skipped at 4392s of a 9000s interval,
#      and the sequence still went 5 -> 6).
#   2. SCHEME (owner directive 2026-10-24, AFC-517):  the marketing version is
#      the NEXT PATCH on the app's train (<prefix>.<P+1>, P from App Store
#      Connect), and the build number is INDEPENDENT of it:  the repo commit
#      count, raised above the App Store Connect floor.  The pair never reads
#      "1.0.N (N)" any more.
#   3. COUNTER: the local build-seq counter is retired.  Nothing writes it and
#      nothing reads it, so a leftover from an older scheme cannot push the
#      build number above the commit count it names.
#
# The App Store Connect answers come from a STUB `node` in FAKE_BIN:  it
# answers `asc-api.mjs latest-marketing-patch` with $FAKE_ASC_PATCH and
# `asc-api.mjs build-floor` with $FAKE_ASC_FLOOR (default 0), and exits 2 for
# anything else -- which is exactly what an unreachable App Store Connect
# looks like to the ship script.  Nothing here reaches the network.
#
# Everything runs offline against scratch state:
#   HOME                -> scratch (so no real home files exist and App Store
#                          Connect is never contacted; also makes it impossible
#                          for a test to touch the real ~/.cache/ios-fleet)
#   IOS_FLEET_STATE_DIR -> scratch last-ship file
#   PATH                -> a fake `xcodebuild` that refuses to archive, a fake
#                          `xcrun` that refuses to upload, and a fake `node`
#                          (passed as IOS_FLEET_NODE) that answers the ASC
#                          queries
# The credential is a THROWAWAY key generated for the run, so the ship
# script reaches its "App Store Connect is reachable" path without a real
# secret and without a network call.
# No network, no Xcode, no credentials. Runs on macOS and Linux.
#
# Usage:
#   bash scripts/ios-fleet/test-ship-seq.sh
#
# Exits 0 when every check passed, 1 otherwise.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SHIP="${HERE}/ship-testflight.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ship-seq-test.XXXXXX")"
FAKE_HOME="${WORK}/home"
FAKE_BIN="${WORK}/bin"
STATE="${WORK}/state"
REPO="${WORK}/repo"
mkdir -p "$FAKE_HOME" "$FAKE_BIN" "$STATE" "$REPO" "${WORK}/tmp"

cleanup() {
  rm -rf "$WORK"
}
trap cleanup EXIT

# The real node:  the ship script stages the credential with asc-key.mjs, so
# the stub node hands that one call to the real binary.
REAL_NODE="$(command -v node || true)"
if [[ -z "$REAL_NODE" ]]; then
  echo "FATAL: node is required to run this test" >&2
  exit 1
fi

# A fake xcodebuild: answers -version, and hard-fails on anything else so a test
# can never start a real archive.
cat >"${FAKE_BIN}/xcodebuild" <<'FAKE'
#!/usr/bin/env bash
if [[ "${1:-}" == "-version" ]]; then
  echo "Xcode 27.0 (fake)"
  exit 0
fi
echo "fake xcodebuild: refusing to archive" >&2
exit 99
FAKE
chmod +x "${FAKE_BIN}/xcodebuild"

# A fake xcrun:  the upload path must never reach Apple from a test.
cat >"${FAKE_BIN}/xcrun" <<'FAKE'
#!/usr/bin/env bash
echo "fake xcrun: refusing to upload" >&2
exit 99
FAKE
chmod +x "${FAKE_BIN}/xcrun"

# A stub `node`:  answers the two App Store Connect version queries from the
# environment and exits 2 for everything else.  Exiting 2 is what the ship
# script sees when App Store Connect cannot be consulted, so a test can drive
# the unreachable-App-Store-Connect path without a network.
#
# asc-key.mjs is the one exception:  the ship script stages the credential with
# it, so that call goes to the real node.
cat >"${FAKE_BIN}/node" <<'FAKE'
#!/usr/bin/env bash
cmd=""
for a in "$@"; do
  case "$a" in
    */asc-api.mjs) cmd="asc-api" ;;
    latest-marketing-patch|build-floor)
      if [[ "$cmd" == "asc-api" ]]; then cmd="${cmd}:${a}"; fi
      ;;
  esac
done
case "$cmd" in
  asc-api:latest-marketing-patch)
    # No stubbed patch = App Store Connect cannot be consulted.
    [[ -n "${FAKE_ASC_PATCH:-}" ]] || exit 2
    printf '%s\n' "$FAKE_ASC_PATCH"
    exit 0
    ;;
  asc-api:build-floor)
    floor="${FAKE_ASC_FLOOR:-0}"
    printf '%s\n' "$floor"
    # The machine-readable note the ship script splits into its two floors.
    printf 'build-floor: train=%s app=%s -> floor=%s\n' \
      "${FAKE_ASC_TRAIN_FLOOR:-$floor}" "${FAKE_ASC_APP_FLOOR:-$floor}" "$floor" >&2
    exit 0
    ;;
esac
for a in "$@"; do
  case "$a" in
    */asc-key.mjs) exec "$CLUTCH_TEST_REAL_NODE" "$@" ;;
  esac
done
exit 2
FAKE
chmod +x "${FAKE_BIN}/node"

# A stub fleet-secrets that always reports "absent", so ASC credentials stay
# unset and no test can reach the real Infisical (the script falls back to
# fleet-secrets on PATH).
printf '#!/usr/bin/env bash\nexit 3\n' >"${FAKE_BIN}/fleet-secrets"
chmod +x "${FAKE_BIN}/fleet-secrets"

# A throwaway credential:  a real PEM, so the ship script reaches its
# "App Store Connect is reachable" path, but a key no Apple account holds.
FAKE_KEY="$("${REAL_NODE}" --input-type=module -e '
import { generateKeyPairSync } from "node:crypto";
const { privateKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
process.stdout.write(privateKey.export({ type: "pkcs8", format: "pem" }));
')"

# The scratch repo:  a git repo with enough commits that the commit count sits
# ABOVE the floor these tests use, so the normal path is exercised:  the build
# number is the commit count and the floor guard does not fire.  With a
# one-commit fixture the floor wins and every version assertion ends up
# testing the guard instead of the scheme.
mkdir -p "${REPO}/ios"
printf 'name: clutch-test\n' >"${REPO}/README"
printf 'DEVELOPMENT_TEAM: ABCDE12345\n' >"${REPO}/ios/project.yml"
git -C "$REPO" init -q
git -C "$REPO" config user.name "seq test"
git -C "$REPO" config user.email "seq@test.invalid"
git -C "$REPO" add README ios/project.yml
git -C "$REPO" -c commit.gpgsign=false commit -qm seed
_seed=2
while [ "$_seed" -le 6 ]; do
  echo "seed ${_seed}" >"${REPO}/seed-${_seed}"
  git -C "$REPO" add "seed-${_seed}"
  git -C "$REPO" -c commit.gpgsign=false commit -qm "seed ${_seed}"
  _seed=$((_seed + 1))
done
HEAD_SHA="$(git -C "$REPO" rev-parse HEAD)"
# Owner directive 2026-10-24 (AFC-517): the build number starts from the commit
# count.  Read the count from the fixture instead of hard-coding it, so adding
# a seed commit to the fixture cannot silently stale the assertions.
COMMIT_COUNT="$(git -C "$REPO" rev-list --count HEAD)"

# The app key this repo's scripts/ios-fleet/apps.json defines.
APP_KEY="clutch"
SEQ_FILE="${STATE}/build-seq-${APP_KEY}.txt"
SHIP_FILE="${STATE}/last-ship-${APP_KEY}.txt"

# The App Store Connect answers the stub gives.  Unset = unreachable.
FAKE_ASC_PATCH=""
FAKE_ASC_FLOOR=""

PASS=0
FAIL=0
OUT=""

# check <name> <0=pass 1=fail>
check() {
  local name="$1" rc="$2"
  if [[ "$rc" -eq 0 ]]; then
    PASS=$((PASS + 1))
    echo "  ok  : ${name}"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: ${name}"
  fi
}

run_ship() {
  OUT=$(env -i \
    HOME="$FAKE_HOME" \
    PATH="${FAKE_BIN}:/usr/bin:/bin:/usr/sbin:/sbin" \
    TMPDIR="${WORK}/tmp" \
    LANG=C \
    IOS_FLEET_STATE_DIR="$STATE" \
    CLUTCH_TEST_REAL_NODE="$REAL_NODE" \
    ASC_KEY_ID=fakekeyid \
    ASC_ISSUER_ID=fakeissuerid \
    ASC_KEY_P8="$FAKE_KEY" \
    IOS_FLEET_NODE="${FAKE_BIN}/node" \
    FAKE_ASC_PATCH="$FAKE_ASC_PATCH" \
    FAKE_ASC_FLOOR="$FAKE_ASC_FLOOR" \
    FAKE_ASC_TRAIN_FLOOR="${FAKE_ASC_TRAIN_FLOOR:-}" \
    FAKE_ASC_APP_FLOOR="${FAKE_ASC_APP_FLOOR:-}" \
    bash "$SHIP" "$APP_KEY" --repo-root "$REPO" "$@" 2>&1)
  RC=$?
  return 0
}

seq_now() { cat "$SEQ_FILE" 2>/dev/null || echo MISSING; }

# contains <needle>:  OUT holds it.  The needles contain '.' / '()'.
contains() { [[ "$OUT" == *"$1"* ]]; }

# The planned pair, read out of the "marketing=<m> build=<b>" log line.
planned_pair() {
  local line
  line="$(printf '%s' "$OUT" | grep -o 'marketing=[^ ]* build=[^ ]*' | head -1)"
  PLANNED_MARKETING="$(printf '%s' "$line" | sed 's/^marketing=//; s/ build=.*$//')"
  PLANNED_BUILD="$(printf '%s' "$line" | sed 's/^.* build=//')"
}

reset_state() {
  rm -f "$SEQ_FILE" "$SHIP_FILE"
  printf '5' >"$SEQ_FILE"
}

# The project file the ship script reads for the agreement NOTICE.  Under the
# 2026-10-24 scheme it is NOT a sequencing input:  the paths below are the
# projectRel entries in this repo's scripts/ios-fleet/apps.json.
project_rel() { # <app key>
  case "$1" in
    clutch) printf '%s' 'ios/Clutch.xcodeproj' ;;
    *) printf '%s' '' ;;
  esac
}

write_record() { # <app key> <record N>
  local app="$1" n="$2" dir
  dir="${REPO}/$(project_rel "$app")"
  mkdir -p "$dir"
  {
    echo "// !$*"
    echo "MARKETING_VERSION = 1.0.${n};"
    echo "CURRENT_PROJECT_VERSION = ${n};"
  } >"${dir}/project.pbxproj"
}

clear_record() { # <app key>
  rm -f "${REPO}/$(project_rel "$1")/project.pbxproj"
  rmdir "${REPO}/$(project_rel "$1")" 2>/dev/null || true
}

echo "ship-testflight.sh version tests"
echo "state=${STATE}"
echo

# --- 1. Rate-limited run must not resolve a version --------------------------
echo "1. ship gate: rate-limited run does not resolve a version"
reset_state
printf '%s %s\n' "$(date +%s)" "0000000000000000000000000000000000000000" >"$SHIP_FILE"
run_ship --allow-unverified-seq
check "exits 0" "$([[ $RC -eq 0 ]] && echo 0 || echo 1)"
check "names the skip" "$(contains 'ship-gate: skip' && echo 0 || echo 1)"
check "names the override (IOS_TF_MIN_INTERVAL_SEC / --force-ship)" \
  "$(contains 'IOS_TF_MIN_INTERVAL_SEC' && contains '--force-ship' && echo 0 || echo 1)"
check "names the 3600s default and where it lives" \
  "$(contains '3600s' && contains 'DEFAULT_MIN_INTERVAL_SEC' && echo 0 || echo 1)"
check "skips the App Store Connect round trip entirely" \
  "$(contains 'version plan:' && echo 1 || echo 0)"
check "does not consume the local counter" "$([[ "$(seq_now)" == "5" ]] && echo 0 || echo 1)"
echo

# --- 2. Same-HEAD run must not resolve a version ----------------------------
echo "2. ship gate: already-shipped HEAD does not resolve a version"
reset_state
printf '%s %s\n' "1" "$HEAD_SHA" >"$SHIP_FILE"
run_ship --allow-unverified-seq
check "exits 0" "$([[ $RC -eq 0 ]] && echo 0 || echo 1)"
check "names the skip" "$(contains 'ship-gate: skip' && echo 0 || echo 1)"
check "does not resolve a version" "$(contains 'version plan:' && echo 1 || echo 0)"
check "does not consume the local counter" "$([[ "$(seq_now)" == "5" ]] && echo 0 || echo 1)"
echo

# --- 3. An unverified App Store Connect is loud ------------------------------
echo "3. an unreachable App Store Connect is loud under --allow-unverified-seq"
reset_state
run_ship --allow-unverified-seq --dry-run
check "exits 0" "$([[ $RC -eq 0 ]] && echo 0 || echo 1)"
check "the planned build number is the commit count" \
  "$(contains "build=${COMMIT_COUNT}" && echo 0 || echo 1)"
check "an unverified patch plans the first patch of the train" \
  "$(contains 'marketing=1.0.1 build=' && echo 0 || echo 1)"
check "says loudly that the patch was unverified" \
  "$(contains 'UNVERIFIED' && echo 0 || echo 1)"
check "the local counter is not advanced" "$([[ "$(seq_now)" == "5" ]] && echo 0 || echo 1)"
clear_record "$APP_KEY"
echo

# --- 4. --dry-run must not ship anything -------------------------------------
echo "4. --dry-run does not ship anything"
reset_state
FAKE_ASC_PATCH=236
FAKE_ASC_FLOOR=0
run_ship --dry-run
check "exits 0" "$([[ $RC -eq 0 ]] && echo 0 || echo 1)"
check "the counter is still 5" "$([[ "$(seq_now)" == "5" ]] && echo 0 || echo 1)"
check "plans the build number without shipping it" \
  "$(contains "build=${COMMIT_COUNT}" && echo 0 || echo 1)"
check "says it would archive + ship" \
  "$(contains 'dry-run: would archive + ship' && echo 0 || echo 1)"
echo

# --- 5. --dry-run reports a gated run without resolving a version ------------
echo "5. --dry-run reports a gated run without resolving a version"
reset_state
printf '%s %s\n' "$(date +%s)" "0000000000000000000000000000000000000000" >"$SHIP_FILE"
run_ship --dry-run
check "exits 0" "$([[ $RC -eq 0 ]] && echo 0 || echo 1)"
check "reports the skip" "$(contains 'would SKIP this run' && echo 0 || echo 1)"
# A dry-run PEERS at the version to report the plan next to the gate outcome;
# what it must not do is ship anything or consume a number.
check "reports the plan it would have shipped" \
  "$(contains 'version plan:' && echo 0 || echo 1)"
check "does not consume the local counter" "$([[ "$(seq_now)" == "5" ]] && echo 0 || echo 1)"
echo

# --- 6. --upload-only must not resolve a version ----------------------------
echo "6. --upload-only does not resolve a version"
reset_state
: >"${WORK}/fake.ipa"
run_ship --upload-only "${WORK}/fake.ipa"
check "does not resolve a version" "$(contains 'version plan:' && echo 1 || echo 0)"
check "takes the version from the IPA" "$(contains '(from IPA)' && echo 0 || echo 1)"
check "the local counter is still not advanced" \
  "$([[ "$(seq_now)" == "5" ]] && echo 0 || echo 1)"
echo

# --- 7. The version scheme (owner directive 2026-10-24, AFC-517) -----------
echo "7. version scheme: next patch on the train, independent build number"
FAKE_ASC_PATCH=236
FAKE_ASC_FLOOR=0
FAKE_ASC_TRAIN_FLOOR=0
FAKE_ASC_APP_FLOOR=0
rm -f "${SEQ_FILE}" "${SHIP_FILE}"
write_record "$APP_KEY" 5
run_ship --dry-run
planned_pair
mk="$PLANNED_MARKETING"
bn="$PLANNED_BUILD"

check "${APP_KEY}: the marketing version is the next patch on the train (got '${mk}')" \
  "$([[ "$mk" == "1.0.237" ]] && echo 0 || echo 1)"
check "${APP_KEY}: the build number is the repo commit count (got '${bn}')" \
  "$([[ "$bn" == "$COMMIT_COUNT" ]] && echo 0 || echo 1)"
check "${APP_KEY}: the build number is not the patch number (no '1.0.N (N)')" \
  "$([[ "$bn" != "237" ]] && echo 0 || echo 1)"
check "${APP_KEY}: the marketing version is not 1.0.<build> (got '${mk}' / '${bn}')" \
  "$([[ "$mk" != "1.0.${bn}" ]] && echo 0 || echo 1)"
check "${APP_KEY}: reports the App Store Connect rendering" \
  "$(contains "will show this as: ${mk} (${bn})" && echo 0 || echo 1)"
check "${APP_KEY}: prints the version plan line" \
  "$(contains 'version plan: asc_patch=236 -> marketing=1.0.237' && echo 0 || echo 1)"
check "${APP_KEY}: the version plan line names the two floors and the commit count" \
  "$(contains 'build floors: train=0 app=0 commit_count=' && echo 0 || echo 1)"
clear_record "$APP_KEY"
echo

# The floor above the commit count:  the build number moves to floor + 1 and
# the marketing version stays the next patch.  The two numbers are independent,
# so the floor never moves the version.
FLOOR_HIGH=202610180036
rm -f "${SEQ_FILE}" "${SHIP_FILE}"
write_record "$APP_KEY" 5
FAKE_ASC_FLOOR="$FLOOR_HIGH"
FAKE_ASC_TRAIN_FLOOR="$FLOOR_HIGH"
FAKE_ASC_APP_FLOOR=0
run_ship --dry-run
planned_pair
mk="$PLANNED_MARKETING"
bn="$PLANNED_BUILD"

check "${APP_KEY}: a floor above the commit count raises the build to floor + 1 (got '${bn}')" \
  "$([[ "$bn" == "$((FLOOR_HIGH + 1))" ]] && echo 0 || echo 1)"
check "${APP_KEY}: the floor does not move the marketing version (got '${mk}')" \
  "$([[ "$mk" == "1.0.237" ]] && echo 0 || echo 1)"
check "${APP_KEY}: the marketing version is not 1.0.<build> (got '${mk}' / '${bn}')" \
  "$([[ "$mk" != "1.0.${bn}" ]] && echo 0 || echo 1)"
clear_record "$APP_KEY"
FAKE_ASC_FLOOR=0
FAKE_ASC_TRAIN_FLOOR=0
echo

# --version pins the marketing version exactly, and the build number is then
# floored against THAT train.
rm -f "${SEQ_FILE}" "${SHIP_FILE}"
write_record "$APP_KEY" 5
FAKE_ASC_FLOOR=202610180036
FAKE_ASC_TRAIN_FLOOR=202610180036
run_ship --dry-run --version 1.0.236
planned_pair
mk="$PLANNED_MARKETING"
bn="$PLANNED_BUILD"

check "${APP_KEY}: --version is honoured exactly (got '${mk}')" \
  "$([[ "$mk" == "1.0.236" ]] && echo 0 || echo 1)"
check "${APP_KEY}: the build is floored against the pinned train (got '${bn}')" \
  "$([[ "$bn" == "202610180037" ]] && echo 0 || echo 1)"
check "${APP_KEY}: the marketing version is not 1.0.<build> (got '${mk}' / '${bn}')" \
  "$([[ "$mk" != "1.0.${bn}" ]] && echo 0 || echo 1)"
clear_record "$APP_KEY"
FAKE_ASC_FLOOR=0
FAKE_ASC_TRAIN_FLOOR=0
echo

# --build pins the build number exactly, and the marketing version is still
# the automatic next patch.
rm -f "${SEQ_FILE}" "${SHIP_FILE}"
write_record "$APP_KEY" 5
run_ship --dry-run --build 999
planned_pair
mk="$PLANNED_MARKETING"
bn="$PLANNED_BUILD"

check "${APP_KEY}: --build is honoured exactly (got '${bn}')" \
  "$([[ "$bn" == "999" ]] && echo 0 || echo 1)"
check "${APP_KEY}: --build does not move the marketing version (got '${mk}')" \
  "$([[ "$mk" == "1.0.237" ]] && echo 0 || echo 1)"
clear_record "$APP_KEY"
echo

# Without --allow-unverified-seq, an unreachable App Store Connect is fatal:
# the marketing version and the build floor both come from it.
rm -f "${SEQ_FILE}" "${SHIP_FILE}"
write_record "$APP_KEY" 5
FAKE_ASC_PATCH=""
run_ship --dry-run
check "${APP_KEY}: an unreachable App Store Connect fails the run (rc=${RC})" \
  "$([[ $RC -ne 0 ]] && echo 0 || echo 1)"
check "${APP_KEY}: says what could not be determined" \
  "$(contains 'cannot determine the next marketing version' && echo 0 || echo 1)"
check "${APP_KEY}: does not ship a version it could not verify" \
  "$(contains 'marketing=1.0.' && echo 1 || echo 0)"
clear_record "$APP_KEY"
FAKE_ASC_PATCH=236
echo

# --- 8. The counter no longer decides the version ---------------------------
echo "8. the counter stays put; the version comes from App Store Connect"
rm -f "$SEQ_FILE" "$SHIP_FILE"
printf '5' >"$SEQ_FILE"
seen=""
for i in 1 2 3; do
  run_ship --dry-run
  seen="${seen} $(seq_now)"
done
check "three allowed runs leave the counter at 5 (got:${seen})" \
  "$([[ "$seen" == " 5 5 5" ]] && echo 0 || echo 1)"
check "the run planned the next patch on the train" \
  "$(contains 'marketing=1.0.237' && echo 0 || echo 1)"
check "a leftover counter does not lift the build number" \
  "$(contains "build=${COMMIT_COUNT}" && echo 0 || echo 1)"
echo

# --- 9. Standing 1-hour gate: just-under skips, at-or-over proceeds ---------
echo "9. standing 1-hour gate: just-under skips, at-or-over proceeds"
reset_state
now="$(date +%s)"
# The ship script reads its OWN clock, a moment after this one, so the
# elapsed time it computes is always at least what is written here.  A
# "just under" case written as now-3599 therefore races the second boundary:
# if the clock ticks once between the two reads the elapsed time lands on
# 3600 and the run proceeds, which is the OTHER case.  Ten seconds of slack
# keeps the case under the limit without making it a coin flip.
printf '%s %s\n' "$((now - 3590))" "0000000000000000000000000000000000000000" >"$SHIP_FILE"
run_ship --dry-run
check "3590s since the last ship skips" \
  "$(contains 'ship-gate: skip' && echo 0 || echo 1)"
# The other side of the boundary races the other way: the script's clock is
# never earlier than this one, so the elapsed time is always >= 3600.
reset_state
printf '%s %s\n' "$((now - 3600))" "0000000000000000000000000000000000000000" >"$SHIP_FILE"
run_ship --dry-run
check "3600s since the last ship proceeds" \
  "$(contains 'ship-gate: ok' && echo 0 || echo 1)"
echo

# --- 10. The ship script itself still carries the new rule -------------------
echo "10. the ship script carries the new rule"
check "the ASC client goes through the node seam" \
  "$(grep -q 'ASC_NODE="${IOS_FLEET_NODE:-node}"' "$SHIP" && echo 0 || echo 1)"
check "the retired local_seq counter is gone" \
  "$(grep -q 'local_seq()' "$SHIP" && echo 1 || echo 0)"
check "the retired resolve_seq_floor is gone" \
  "$(grep -q 'resolve_seq_floor()' "$SHIP" && echo 1 || echo 0)"
check "the retired next_build_seq is gone" \
  "$(grep -q 'next_build_seq()' "$SHIP" && echo 1 || echo 0)"
check "the marketing patch query is asked for" \
  "$(grep -q 'latest-marketing-patch' "$SHIP" && echo 0 || echo 1)"
check "the build floor query is asked for" \
  "$(grep -q 'build-floor' "$SHIP" && echo 0 || echo 1)"
echo

echo "passed=${PASS} failed=${FAIL}"
if [[ "$FAIL" -gt 0 ]]; then
  echo "test-ship-seq: ${FAIL} check(s) FAILED"
  exit 1
fi
echo "test-ship-seq: all checks passed"
exit 0
