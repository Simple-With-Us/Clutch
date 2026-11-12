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
# Sections before 12 test the unchanged next-patch behaviour, so they run a copy
# of the fleet dir whose apps.json carries no fixed-version keys.
LEGACY_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ios-fleet-legacy.XXXXXX")"
cp -R "$HERE/." "$LEGACY_DIR/"
python3 - "$LEGACY_DIR/apps.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
for a in d["apps"].values():
    a.pop("fixedMarketingVersion", None)
    a.pop("buildCountSeed", None)
    a.pop("macBundleId", None)
    a.pop("pairedBundleId", None)
    a.pop("pairedBuildFeed", None)
json.dump(d, open(p, "w"), indent=2)
PY
SHIP="${LEGACY_DIR}/ship-testflight.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ship-seq-test.XXXXXX")"
FAKE_HOME="${WORK}/home"
FAKE_BIN="${WORK}/bin"
STATE="${WORK}/state"
REPO="${WORK}/repo"
mkdir -p "$FAKE_HOME" "$FAKE_BIN" "$STATE" "$REPO" "${WORK}/tmp"

cleanup() {
  rm -rf "$WORK" "$LEGACY_DIR"
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
    latest-marketing-patch|build-floor|released-store-version|next-shared-build|plan-release-build|platform-max-build)
      if [[ "$cmd" == "asc-api" ]]; then cmd="${cmd}:${a}"; fi
      ;;
  esac
done
case "$cmd" in
  asc-api:latest-marketing-patch)
    # No stubbed patch = App Store Connect cannot be consulted.
    # "auth" = App Store Connect rejected the key (asc-api exits 4).
    [[ "${FAKE_ASC_PATCH:-}" == "auth" ]] && exit 4
    [[ -n "${FAKE_ASC_PATCH:-}" ]] || exit 2
    printf '%s\n' "$FAKE_ASC_PATCH"
    exit 0
    ;;
  asc-api:released-store-version)
    [[ "${FAKE_RELEASED:-}" == "fail" ]] && exit 2
    printf '%s\n' "${FAKE_RELEASED:-}"
    exit 0
    ;;
  asc-api:next-shared-build|asc-api:plan-release-build)
    if [[ -n "${FAKE_ASC_ARGS_LOG:-}" ]]; then
      printf '%s\n' "$*" >>"$FAKE_ASC_ARGS_LOG"
    fi
    [[ "${FAKE_SHARED:-}" == "fail" ]] && exit 3
    [[ -n "${FAKE_SHARED:-}" ]] || exit 2
    printf '%s\n' "$FAKE_SHARED"
    exit 0
    ;;
  asc-api:platform-max-build)
    if [[ -n "${FAKE_ASC_ARGS_LOG:-}" ]]; then
      printf '%s\n' "$*" >>"$FAKE_ASC_ARGS_LOG"
    fi
    [[ "${FAKE_PLATFORM_MAX:-}" == "fail" ]] && exit 2
    [[ -n "${FAKE_PLATFORM_MAX:-}" ]] || exit 2
    printf '%s\n' "$FAKE_PLATFORM_MAX"
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
# Fixed committer dates, so the merge stamp S (the HEAD committer date in
# America/Chicago as YYYYMMDDHHMM) is deterministic: 202610290930.
FIXTURE_DATE="2026-10-29T09:30:00-05:00"
S_STAMP="202610290930"
mkdir -p "${REPO}/ios"
printf 'name: clutch-test\n' >"${REPO}/README"
printf 'DEVELOPMENT_TEAM: ABCDE12345\n' >"${REPO}/ios/project.yml"
git -C "$REPO" init -q
git -C "$REPO" config user.name "seq test"
git -C "$REPO" config user.email "seq@test.invalid"
git -C "$REPO" add README ios/project.yml
GIT_COMMITTER_DATE="$FIXTURE_DATE" git -C "$REPO" -c commit.gpgsign=false commit -qm seed
_seed=2
while [ "$_seed" -le 6 ]; do
  echo "seed ${_seed}" >"${REPO}/seed-${_seed}"
  git -C "$REPO" add "seed-${_seed}"
  GIT_COMMITTER_DATE="$FIXTURE_DATE" git -C "$REPO" -c commit.gpgsign=false commit -qm "seed ${_seed}"
  _seed=$((_seed + 1))
done
HEAD_SHA="$(git -C "$REPO" rev-parse HEAD)"
# The exact command the ship script uses for S, against the fixture.
FIXTURE_STAMP="$(cd "$REPO" && TZ=America/Chicago git show -s --format=%cd --date=format-local:%Y%m%d%H%M HEAD)"
if [[ "$FIXTURE_STAMP" != "$S_STAMP" ]]; then
  echo "FATAL: fixture stamp is ${FIXTURE_STAMP}, want ${S_STAMP}" >&2
  exit 1
fi
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
    FAKE_RELEASED="${FAKE_RELEASED:-}" \
    FAKE_SHARED="${FAKE_SHARED:-}" \
    FAKE_PLATFORM_MAX="${FAKE_PLATFORM_MAX:-}" \
    FAKE_ASC_TRAIN_FLOOR="${FAKE_ASC_TRAIN_FLOOR:-}" \
    FAKE_ASC_APP_FLOOR="${FAKE_ASC_APP_FLOOR:-}" \
    FAKE_ASC_ARGS_LOG="${FAKE_ASC_ARGS_LOG:-}" \
    FAKE_CURL_ARGS_LOG="${FAKE_CURL_ARGS_LOG:-}" \
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
check "the merge-stamp build is planned through plan-release-build" \
  "$(grep -q 'plan-release-build' "$SHIP" && echo 0 || echo 1)"
check "an explicit fixed --build is checked against platform-max-build" \
  "$(grep -q 'platform-max-build' "$SHIP" && echo 0 || echo 1)"
check "the merge stamp comes from the exact HEAD committer-date command" \
  "$(grep -q -F 'TZ=America/Chicago git show -s --format=%cd --date=format-local:%Y%m%d%H%M HEAD' "$SHIP" && echo 0 || echo 1)"
check "the fixed build accepts only 12-digit stamps" \
  "$(grep -q -F '^[1-9][0-9]{11}$' "$SHIP" && echo 0 || echo 1)"
check "no four-digit counter wording survives in the ship script" \
  "$(grep -q 'four-digit' "$SHIP" && echo 1 || echo 0)"
echo

# --- rejected API key -----------------------------------------------------
# A 401/403 from App Store Connect is not "unreachable":  even
# --allow-unverified-seq must not plan a version around a key Apple rejects.
echo "rejected API key: fatal even with --allow-unverified-seq"
reset_state 2>/dev/null || true
FAKE_ASC_PATCH=auth
run_ship --allow-unverified-seq --dry-run
check "a rejected key fails the run (rc=${RC})" "$([[ $RC -ne 0 ]] && echo 0 || echo 1)"
check "says the key was rejected" "$(contains 'rejected the API key' && echo 0 || echo 1)"
check "plans no version around it" "$(contains 'UNVERIFIED patch' && echo 1 || echo 0)"
FAKE_ASC_PATCH=236
echo

echo "12. fixed marketing version + shared merge-stamp build (apps.json fixedMarketingVersion)"
FIXDIR="${WORK}/fleet-fixed"
rm -rf "$FIXDIR"; cp -R "$HERE" "$FIXDIR"
python3 - "$FIXDIR/apps.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
a = d["apps"]
for k in list(a)[:1]:
    a[k]["fixedMarketingVersion"] = "1.1.2"
    a[k].pop("buildCountSeed", None)
    a[k].pop("macBundleId", None)
    a[k].pop("pairedBundleId", None)
    a[k].pop("pairedBuildFeed", None)
json.dump(d, open(p, "w"), indent=2)
PY
FIXAPP="$APP_KEY"
SHIP_REAL="$SHIP"; SHIP="${FIXDIR}/ship-testflight.sh"
rm -f "$SEQ_FILE" "$SHIP_FILE"
write_record "$FIXAPP" 5
FAKE_ASC_PATCH=239; FAKE_ASC_FLOOR=2383; FAKE_RELEASED=""; FAKE_SHARED="$S_STAMP"
run_ship --dry-run
planned_pair
check "fixed: marketing stays 1.1.2 even though ASC holds patch 239 (got '${PLANNED_MARKETING}')" \
  "$([[ "$PLANNED_MARKETING" == "1.1.2" ]] && echo 0 || echo 1)"
check "fixed: a fresh inventory plans the merge stamp itself (got '${PLANNED_BUILD}')" \
  "$([[ "$PLANNED_BUILD" == "$S_STAMP" ]] && echo 0 || echo 1)"
check "fixed: the integer floor and commit count play no part" \
  "$(contains "merge-stamp build ${S_STAMP} for fixed version 1.1.2" && echo 0 || echo 1)"
ABOVE_STAMP="202610291200"
FAKE_SHARED="$ABOVE_STAMP"
run_ship --dry-run
planned_pair
check "fixed: an inventory above the stamp plans above it (got '${PLANNED_BUILD}')" \
  "$([[ "$PLANNED_BUILD" == "$ABOVE_STAMP" ]] && echo 0 || echo 1)"
FAKE_SHARED="fail"
run_ship --dry-run
check "fixed: an unreadable or exhausted inventory stops the run, nothing guessed" \
  "$(contains 'cannot work out the next merge-stamp build' && echo 0 || echo 1)"
FAKE_SHARED=""
run_ship --dry-run
check "fixed: an unreadable inventory stops the run" \
  "$(contains 'cannot work out the next merge-stamp build' && echo 0 || echo 1)"
FAKE_SHARED="$S_STAMP"; FAKE_RELEASED="1.1.2"
run_ship --dry-run
check "fixed: a version at the released App Store version is refused, not bumped" \
  "$(contains 'at or below the released App Store version 1.1.2' && echo 0 || echo 1)"
FAKE_RELEASED="fail"
run_ship --dry-run
check "fixed: an unreadable released App Store version stops the run (fail closed)" \
  "$(contains 'cannot read the released App Store version' && echo 0 || echo 1)"
FAKE_SHARED="$S_STAMP"; FAKE_RELEASED=""; FAKE_PLATFORM_MAX="0"
run_ship --dry-run --build 7
check "fixed: a one-digit --build is refused" \
  "$(contains 'fixed mode requires a 12-digit' && echo 0 || echo 1)"
run_ship --dry-run --build 999
check "fixed: a three-digit --build is refused" \
  "$(contains 'fixed mode requires a 12-digit' && echo 0 || echo 1)"
run_ship --dry-run --build 20261029093
check "fixed: an 11-digit --build is refused" \
  "$(contains 'fixed mode requires a 12-digit' && echo 0 || echo 1)"
run_ship --dry-run --build 2026102909301
check "fixed: a 13-digit --build is refused" \
  "$(contains 'fixed mode requires a 12-digit' && echo 0 || echo 1)"
run_ship --dry-run --build 022610290930
check "fixed: a leading-zero --build is refused" \
  "$(contains 'fixed mode requires a 12-digit' && echo 0 || echo 1)"
run_ship --dry-run --build 1.1.9
check "fixed: a dotted --build is refused" \
  "$(contains 'fixed mode requires a 12-digit' && echo 0 || echo 1)"
FAKE_PLATFORM_MAX="202610290929"
run_ship --dry-run --build "$S_STAMP"
planned_pair
check "fixed: a 12-digit --build above this platform's max is honoured (got '${PLANNED_BUILD}')" \
  "$([[ "$PLANNED_BUILD" == "$S_STAMP" ]] && echo 0 || echo 1)"
FAKE_PLATFORM_MAX="$S_STAMP"
run_ship --dry-run --build "$S_STAMP"
check "fixed: a --build at this platform's max is refused" \
  "$(contains "at or below this platform's highest build ${S_STAMP}" && echo 0 || echo 1)"
FAKE_PLATFORM_MAX="202610290931"
run_ship --dry-run --build "$S_STAMP"
check "fixed: a --build below this platform's max is refused" \
  "$(contains "at or below this platform's highest build 202610290931" && echo 0 || echo 1)"
# The --build path never consults the shared (paired-inclusive) plan: even
# though FAKE_SHARED sits above this --build, the value is honoured because
# it clears THIS platform's max.  That is what lets the paired platform of
# one release carry the same build number.
FAKE_SHARED="202610290935"; FAKE_PLATFORM_MAX="$S_STAMP"
run_ship --dry-run --build 202610290931
planned_pair
check "fixed: a --build equal to the paired platform's build is honoured (got '${PLANNED_BUILD}')" \
  "$([[ "$PLANNED_BUILD" == "202610290931" ]] && echo 0 || echo 1)"
FAKE_PLATFORM_MAX=""
run_ship --dry-run --build 202610290931
check "fixed: a --build with an unreadable this-platform floor stops the run" \
  "$(contains "cannot verify this platform's build floor" && echo 0 || echo 1)"
FAKE_SHARED="$S_STAMP"; FAKE_PLATFORM_MAX="0"
run_ship --dry-run --version 1.1.2
planned_pair
check "fixed: --version equal to the fixed version stays in fixed mode (got '${PLANNED_BUILD}')" \
  "$([[ "$PLANNED_BUILD" == "$S_STAMP" ]] && echo 0 || echo 1)"
python3 - "$FIXDIR/apps.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["apps"]["fixmac"] = {
  "displayName": "Fixed Mac",
  "fixedMarketingVersion": "1.1.2",
  "bundleId": "trade.example.fixmac",
  "scheme": "FixMac",
  "projectRel": "mac/FixMac.xcodeproj",
  "platform": "macOS",
  "marketingVersionDefault": "1.0.0"
}
json.dump(d, open(p, "w"), indent=2)
PY
FAKE_SHARED="$S_STAMP"; FAKE_RELEASED=""
rm -f "${STATE}/build-seq-fixmac.txt" "${STATE}/last-ship-fixmac.txt"
APP_KEY_SAVED="$APP_KEY"; APP_KEY="fixmac"
run_ship --dry-run
planned_pair
check "fixed macOS: marketing stays 1.1.2 (got '${PLANNED_MARKETING}')" \
  "$([[ "$PLANNED_MARKETING" == "1.1.2" ]] && echo 0 || echo 1)"
check "fixed macOS: plans the merge-stamp build instead of refusing (got '${PLANNED_BUILD}')" \
  "$([[ "$PLANNED_BUILD" == "$S_STAMP" ]] && echo 0 || echo 1)"
check "fixed macOS: logs the shared build line" \
  "$(contains "merge-stamp build ${S_STAMP} for fixed version 1.1.2" && echo 0 || echo 1)"
APP_KEY="$APP_KEY_SAVED"
# The HEAD stamp reaches plan-release-build exactly as --merge-stamp, and
# --plan-build-only prints the bare planned build for the CI plan step.
FAKE_ASC_ARGS_LOG="${WORK}/asc-args12.log"
: >"$FAKE_ASC_ARGS_LOG"
FAKE_SHARED="$S_STAMP"; FAKE_RELEASED=""; FAKE_PLATFORM_MAX="0"
rm -f "$SEQ_FILE" "$SHIP_FILE"
run_ship --dry-run
check "the HEAD stamp is passed to plan-release-build as --merge-stamp" \
  "$(grep -q -- '--merge-stamp' "$FAKE_ASC_ARGS_LOG" && grep -q "$S_STAMP" "$FAKE_ASC_ARGS_LOG" && echo 0 || echo 1)"
check "plan-release-build is the fixed-mode planner" \
  "$(grep -q 'plan-release-build' "$FAKE_ASC_ARGS_LOG" && echo 0 || echo 1)"
run_ship --plan-build-only
check "plan-build-only exits 0" "$([[ $RC -eq 0 ]] && echo 0 || echo 1)"
check "plan-build-only reports the planned build" \
  "$(contains "plan-build-only: marketing=1.1.2 build=${S_STAMP}" && echo 0 || echo 1)"
check "plan-build-only never reaches the archive" \
  "$(contains 'fake xcodebuild' && echo 1 || echo 0)"
OUT_PLAN="$(env -i \
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
  FAKE_SHARED="$S_STAMP" \
  FAKE_RELEASED="" \
  bash "$SHIP" "$APP_KEY" --repo-root "$REPO" --plan-build-only 2>"${WORK}/plan-err.log")"
PLAN_RC=$?
check "plan-build-only prints the bare planned build on stdout (got '${OUT_PLAN}')" \
  "$([[ "$PLAN_RC" -eq 0 && "$OUT_PLAN" == "$S_STAMP" ]] && echo 0 || echo 1)"
# The CI plan step captures the WRAPPER's stdout, so the wrapper keeps its own
# status lines on stderr: only the fleet script's bare build may reach stdout.
WRAPPER="${HERE}/../ios-ship-testflight.sh"
OUT_WRAP="$(env -i \
  HOME="$FAKE_HOME" \
  PATH="${FAKE_BIN}:/usr/bin:/bin:/usr/sbin:/sbin" \
  TMPDIR="${WORK}/tmp" \
  LANG=C \
  DEVELOPER_DIR="${WORK}/tmp/Xcode.app/Contents/Developer" \
  bash "$WRAPPER" --bogus-flag-for-stdout-test 2>"${WORK}/wrap-err.log")"
check "the wrapper prints no stdout chatter ahead of the fleet script (got '${OUT_WRAP}')" \
  "$([[ -z "$OUT_WRAP" ]] && echo 0 || echo 1)"
check "the wrapper still reports its status lines on stderr" \
  "$([[ -s "${WORK}/wrap-err.log" ]] && echo 0 || echo 1)"
FAKE_SHARED="fail"
run_ship --plan-build-only
check "plan-build-only fails closed on an unreadable inventory (rc=${RC})" \
  "$([[ $RC -ne 0 ]] && echo 0 || echo 1)"
check "plan-build-only names the failure" \
  "$(contains 'cannot work out the next merge-stamp build' && echo 0 || echo 1)"
FAKE_SHARED="$S_STAMP"
run_ship --plan-build-only --build "$S_STAMP"
check "plan-build-only refuses --build" \
  "$(contains 'cannot be combined with --build' && echo 0 || echo 1)"
SHIP_SAVED_PLAN="$SHIP"; SHIP="${LEGACY_DIR}/ship-testflight.sh"
run_ship --plan-build-only
check "plan-build-only refuses an app with no fixed version" \
  "$(contains 'needs a fixed marketing version' && echo 0 || echo 1)"
SHIP="$SHIP_SAVED_PLAN"
SHIP="$SHIP_REAL"; FAKE_ASC_FLOOR=0; FAKE_RELEASED=""; FAKE_SHARED=""; FAKE_ASC_PATCH=236; FAKE_PLATFORM_MAX=""; FAKE_ASC_ARGS_LOG=""
echo

echo "13. paired feed timeout/failure fails closed; paired-bundle passthrough"
PAIRDIR="${WORK}/fleet-paired"
rm -rf "$PAIRDIR"; cp -R "$HERE" "$PAIRDIR"
python3 - "$PAIRDIR/apps.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
a = d["apps"]["clutch"]
a["fixedMarketingVersion"] = "1.1.2"
a.pop("pairedBundleId", None)
a.pop("macBundleId", None)
a.pop("pairedBuildFeed", None)
d["apps"]["pairmac"] = {
  "displayName": "Paired Mac",
  "fixedMarketingVersion": "1.1.2",
  "bundleId": "trade.example.pairmac",
  "scheme": "PairMac",
  "projectRel": "mac/PairMac.xcodeproj",
  "platform": "macOS",
  "marketingVersionDefault": "1.0.0",
  "pairedBundleId": "codes.clutch.ios"
}
json.dump(d, open(p, "w"), indent=2)
PY
SHIP_SAVED_13="$SHIP"; SHIP="${PAIRDIR}/ship-testflight.sh"
FEED_URL="https://example.invalid/appcast.xml"
FAKE_ASC_ARGS_LOG="${WORK}/asc-args.log"
FAKE_CURL_ARGS_LOG="${WORK}/curl-args.log"
: >"$FAKE_ASC_ARGS_LOG"; : >"$FAKE_CURL_ARGS_LOG"
write_record "$APP_KEY" 5
python3 - "$PAIRDIR/apps.json" "$FEED_URL" <<'PY'
import json, sys
p, url = sys.argv[1], sys.argv[2]
d = json.load(open(p))
d["apps"]["clutch"]["pairedBuildFeed"] = url
json.dump(d, open(p, "w"), indent=2)
PY
cat >"${FAKE_BIN}/curl" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${FAKE_CURL_ARGS_LOG:-/dev/null}"
echo "curl: (28) Operation timed out after 30001 ms" >&2
exit 28
FAKE
chmod +x "${FAKE_BIN}/curl"
rm -f "$SEQ_FILE" "$SHIP_FILE"
: >"$FAKE_CURL_ARGS_LOG"; : >"$FAKE_ASC_ARGS_LOG"
FAKE_SHARED="$S_STAMP"; FAKE_RELEASED=""; FAKE_ASC_PATCH=239; FAKE_ASC_FLOOR=0
run_ship --dry-run
check "feed timeout fails closed (rc=${RC})" "$([[ $RC -ne 0 ]] && echo 0 || echo 1)"
check "feed timeout names the shared-build failure" "$(contains 'cannot work out the next merge-stamp build' && echo 0 || echo 1)"
check "feed timeout logs the feed URL" "$(contains "$FEED_URL" && echo 0 || echo 1)"
check "feed timeout logs curl stderr, not an ASC failure" "$(contains 'timed out' && echo 0 || echo 1)"
check "feed curl is bounded with connect/max timeouts" "$(grep -q -- '--connect-timeout 10' "$FAKE_CURL_ARGS_LOG" && grep -q -- '--max-time 30' "$FAKE_CURL_ARGS_LOG" && echo 0 || echo 1)"
check "feed failure never reaches plan-release-build" "$([[ ! -s "$FAKE_ASC_ARGS_LOG" ]] && echo 0 || echo 1)"
cat >"${FAKE_BIN}/curl" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${FAKE_CURL_ARGS_LOG:-/dev/null}"
printf '%s' '<rss><channel><item><title>no versions here</title></item></channel></rss>'
exit 0
FAKE
chmod +x "${FAKE_BIN}/curl"
rm -f "$SEQ_FILE" "$SHIP_FILE"
: >"$FAKE_CURL_ARGS_LOG"; : >"$FAKE_ASC_ARGS_LOG"
run_ship --dry-run
check "feed with no numeric version fails closed (rc=${RC})" "$([[ $RC -ne 0 ]] && echo 0 || echo 1)"
check "feed with no numeric version logs the URL" "$(contains "$FEED_URL" && echo 0 || echo 1)"
check "feed with no numeric version says so" "$(contains 'holds no numeric' && echo 0 || echo 1)"
cat >"${FAKE_BIN}/curl" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${FAKE_CURL_ARGS_LOG:-/dev/null}"
printf '%s' '<rss><channel><item><sparkle:version>1400</sparkle:version></item><item><sparkle:version>1500</sparkle:version></item></channel></rss>'
exit 0
FAKE
chmod +x "${FAKE_BIN}/curl"
TRIPLE_HIGH="$("$REAL_NODE" --input-type=module -e "
import {nextSharedBuild} from 'file://${HERE}/shared-build.mjs';
const r = nextSharedBuild({iosBuilds: ['202610190645'], macBuilds: ['1200'], extraFloors: [1500], complete: true, mergeStamp: '202501010000'});
process.stdout.write(r.build);
")"
check "stub-ASC contract: planner triple iOS 202610190645 + mac 1200 + floor 1500 under stamp 202501010000 is 202610190646 (got '${TRIPLE_HIGH}')" "$([[ "$TRIPLE_HIGH" == "202610190646" ]] && echo 0 || echo 1)"
TRIPLE_STAMP="$("$REAL_NODE" --input-type=module -e "
import {nextSharedBuild} from 'file://${HERE}/shared-build.mjs';
const r = nextSharedBuild({iosBuilds: ['1100'], macBuilds: ['1200'], extraFloors: [1500], complete: true, mergeStamp: '202610290930'});
process.stdout.write(r.build);
")"
check "stub-ASC contract: planner triple iOS 1100 + mac 1200 + floor 1500 under stamp 202610290930 is the stamp (got '${TRIPLE_STAMP}')" "$([[ "$TRIPLE_STAMP" == "202610290930" ]] && echo 0 || echo 1)"
rm -f "$SEQ_FILE" "$SHIP_FILE"
: >"$FAKE_CURL_ARGS_LOG"; : >"$FAKE_ASC_ARGS_LOG"
FAKE_SHARED="$TRIPLE_HIGH"
run_ship --dry-run
planned_pair
check "feed max is passed as the floor to plan-release-build" "$(grep -q '1500' "$FAKE_ASC_ARGS_LOG" && echo 0 || echo 1)"
check "feed floor plans the planner result (got '${PLANNED_BUILD}')" "$([[ "$PLANNED_BUILD" == "$TRIPLE_HIGH" ]] && echo 0 || echo 1)"
python3 - "$PAIRDIR/apps.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["apps"]["clutch"].pop("pairedBuildFeed", None)
d["apps"]["clutch"]["pairedBundleId"] = "codes.clutch.mac"
d["apps"]["clutch"].pop("macBundleId", None)
json.dump(d, open(p, "w"), indent=2)
PY
rm -f "${FAKE_BIN}/curl"
rm -f "$SEQ_FILE" "$SHIP_FILE"
: >"$FAKE_ASC_ARGS_LOG"
FAKE_SHARED="$S_STAMP"
run_ship --dry-run
check "pairedBundleId is passed to plan-release-build" "$(grep -q 'codes.clutch.mac' "$FAKE_ASC_ARGS_LOG" && echo 0 || echo 1)"
python3 - "$PAIRDIR/apps.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["apps"]["clutch"].pop("pairedBundleId", None)
d["apps"]["clutch"]["macBundleId"] = "codes.clutch.mac-legacy"
json.dump(d, open(p, "w"), indent=2)
PY
rm -f "$SEQ_FILE" "$SHIP_FILE"
: >"$FAKE_ASC_ARGS_LOG"
run_ship --dry-run
check "macBundleId alias is passed to plan-release-build" "$(grep -q 'codes.clutch.mac-legacy' "$FAKE_ASC_ARGS_LOG" && echo 0 || echo 1)"
python3 - "$PAIRDIR/apps.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["apps"]["clutch"]["pairedBundleId"] = "codes.clutch.mac"
d["apps"]["clutch"]["macBundleId"] = "codes.clutch.mac-legacy"
json.dump(d, open(p, "w"), indent=2)
PY
rm -f "$SEQ_FILE" "$SHIP_FILE"
: >"$FAKE_ASC_ARGS_LOG"
run_ship --dry-run
check "pairedBundleId wins over macBundleId" "$(grep -q 'codes.clutch.mac' "$FAKE_ASC_ARGS_LOG" && ! grep -q 'codes.clutch.mac-legacy' "$FAKE_ASC_ARGS_LOG" && echo 0 || echo 1)"
APP_KEY_SAVED_13="$APP_KEY"; APP_KEY="pairmac"
rm -f "${STATE}/build-seq-pairmac.txt" "${STATE}/last-ship-pairmac.txt"
: >"$FAKE_ASC_ARGS_LOG"
FAKE_SHARED="$S_STAMP"; FAKE_RELEASED=""
run_ship --dry-run
planned_pair
check "macOS paired id is the iOS bundle id" "$(grep -q 'codes.clutch.ios' "$FAKE_ASC_ARGS_LOG" && echo 0 || echo 1)"
check "macOS paired entry plans the shared build (got '${PLANNED_BUILD}')" "$([[ "$PLANNED_BUILD" == "$S_STAMP" ]] && echo 0 || echo 1)"
APP_KEY="$APP_KEY_SAVED_13"
clear_record "clutch"
SHIP="$SHIP_SAVED_13"; FAKE_ASC_ARGS_LOG=""; FAKE_CURL_ARGS_LOG=""
FAKE_ASC_FLOOR=0; FAKE_RELEASED=""; FAKE_SHARED=""; FAKE_ASC_PATCH=236
echo

echo "14. feed hardening, floor range, macOS reverse lookup"
ROUND2DIR="${WORK}/fleet-round2"
rm -rf "$ROUND2DIR"; cp -R "$HERE" "$ROUND2DIR"
python3 - "$ROUND2DIR/apps.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
a = d["apps"]["clutch"]
a["fixedMarketingVersion"] = "1.1.2"
a.pop("pairedBundleId", None)
a.pop("macBundleId", None)
a.pop("pairedBuildFeed", None)
d["apps"]["lonelymac"] = {
  "displayName": "Lonely Mac",
  "fixedMarketingVersion": "1.1.2",
  "bundleId": "trade.example.lonelymac",
  "scheme": "LonelyMac",
  "projectRel": "mac/LonelyMac.xcodeproj",
  "platform": "macOS",
  "marketingVersionDefault": "1.0.0"
}
json.dump(d, open(p, "w"), indent=2)
PY
SHIP_SAVED_14="$SHIP"; SHIP="${ROUND2DIR}/ship-testflight.sh"
FAKE_ASC_ARGS_LOG="${WORK}/asc-args14.log"
FAKE_CURL_ARGS_LOG="${WORK}/curl-args14.log"
: >"$FAKE_ASC_ARGS_LOG"; : >"$FAKE_CURL_ARGS_LOG"
write_record "$APP_KEY" 5
python3 - "$ROUND2DIR/apps.json" "$FEED_URL" <<'PY'
import json, sys
p, url = sys.argv[1], sys.argv[2]
d = json.load(open(p))
d["apps"]["clutch"]["pairedBuildFeed"] = url
json.dump(d, open(p, "w"), indent=2)
PY
cat >"${FAKE_BIN}/curl" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${FAKE_CURL_ARGS_LOG:-/dev/null}"
printf '%s' '<rss><channel><item><sparkle:version>  1400 </sparkle:version></item><item><sparkle:version>   1500   </sparkle:version></item></channel></rss>'
exit 0
FAKE
chmod +x "${FAKE_BIN}/curl"
rm -f "$SEQ_FILE" "$SHIP_FILE"
: >"$FAKE_CURL_ARGS_LOG"; : >"$FAKE_ASC_ARGS_LOG"
FAKE_SHARED="$S_STAMP"; FAKE_RELEASED=""; FAKE_ASC_PATCH=239; FAKE_ASC_FLOOR=0
run_ship --dry-run
planned_pair
check "whitespace-padded sparkle versions still yield the max floor" "$(grep -q '1500' "$FAKE_ASC_ARGS_LOG" && echo 0 || echo 1)"
check "whitespace-padded feed plans the shared build (got '${PLANNED_BUILD}')" "$([[ "$PLANNED_BUILD" == "$S_STAMP" ]] && echo 0 || echo 1)"
check "feed curl pins https and its redirects" "$(grep -q -- '--proto =https' "$FAKE_CURL_ARGS_LOG" && grep -q -- '--proto-redir =https' "$FAKE_CURL_ARGS_LOG" && echo 0 || echo 1)"
check "feed curl bounds size and time" "$(grep -q -- '--max-filesize 5000000' "$FAKE_CURL_ARGS_LOG" && grep -q -- '--connect-timeout 10' "$FAKE_CURL_ARGS_LOG" && grep -q -- '--max-time 30' "$FAKE_CURL_ARGS_LOG" && echo 0 || echo 1)"
cat >"${FAKE_BIN}/curl" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${FAKE_CURL_ARGS_LOG:-/dev/null}"
printf '%s' '<rss><channel><item><title>no versions here</title></item></channel></rss>'
exit 0
FAKE
chmod +x "${FAKE_BIN}/curl"
rm -f "$SEQ_FILE" "$SHIP_FILE"
: >"$FAKE_CURL_ARGS_LOG"; : >"$FAKE_ASC_ARGS_LOG"
FAKE_SHARED="$S_STAMP"
run_ship --dry-run
check "empty feed fails closed (rc=${RC})" "$([[ $RC -ne 0 ]] && echo 0 || echo 1)"
check "empty feed message names the tag it looked for" "$(contains 'holds no numeric <sparkle:version>' && echo 0 || echo 1)"
check "empty feed message names the URL" "$(contains "$FEED_URL" && echo 0 || echo 1)"
check "empty feed never reaches plan-release-build" "$([[ ! -s "$FAKE_ASC_ARGS_LOG" ]] && echo 0 || echo 1)"
HTTP_FEED_URL="http://example.invalid/appcast.xml"
python3 - "$ROUND2DIR/apps.json" "$HTTP_FEED_URL" <<'PY'
import json, sys
p, url = sys.argv[1], sys.argv[2]
d = json.load(open(p))
d["apps"]["clutch"]["pairedBuildFeed"] = url
json.dump(d, open(p, "w"), indent=2)
PY
cat >"${FAKE_BIN}/curl" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${FAKE_CURL_ARGS_LOG:-/dev/null}"
printf '%s' '<rss><channel><item><sparkle:version>1500</sparkle:version></item></channel></rss>'
exit 0
FAKE
chmod +x "${FAKE_BIN}/curl"
rm -f "$SEQ_FILE" "$SHIP_FILE"
: >"$FAKE_CURL_ARGS_LOG"; : >"$FAKE_ASC_ARGS_LOG"
FAKE_SHARED="$S_STAMP"
run_ship --dry-run
check "non-https feed fails closed (rc=${RC})" "$([[ $RC -ne 0 ]] && echo 0 || echo 1)"
check "non-https feed names the URL" "$(contains "$HTTP_FEED_URL" && echo 0 || echo 1)"
check "non-https feed says https is required" "$(contains 'must start with https://' && echo 0 || echo 1)"
check "non-https feed never reaches curl" "$([[ ! -s "$FAKE_CURL_ARGS_LOG" ]] && echo 0 || echo 1)"
check "non-https feed never reaches plan-release-build" "$([[ ! -s "$FAKE_ASC_ARGS_LOG" ]] && echo 0 || echo 1)"
python3 - "$ROUND2DIR/apps.json" "$FEED_URL" <<'PY'
import json, sys
p, url = sys.argv[1], sys.argv[2]
d = json.load(open(p))
d["apps"]["clutch"]["pairedBuildFeed"] = url
json.dump(d, open(p, "w"), indent=2)
PY
cat >"${FAKE_BIN}/curl" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${FAKE_CURL_ARGS_LOG:-/dev/null}"
printf '%s' '<rss><channel><item><sparkle:version>9999</sparkle:version></item></channel></rss>'
exit 0
FAKE
chmod +x "${FAKE_BIN}/curl"
rm -f "$SEQ_FILE" "$SHIP_FILE"
: >"$FAKE_CURL_ARGS_LOG"; : >"$FAKE_ASC_ARGS_LOG"
FAKE_SHARED="$S_STAMP"
run_ship --dry-run
planned_pair
check "feed floor 9999 is accepted as the floor" "$(grep -q '9999' "$FAKE_ASC_ARGS_LOG" && echo 0 || echo 1)"
check "feed floor 9999 plans the shared build (got '${PLANNED_BUILD}')" "$([[ "$PLANNED_BUILD" == "$S_STAMP" ]] && echo 0 || echo 1)"
cat >"${FAKE_BIN}/curl" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${FAKE_CURL_ARGS_LOG:-/dev/null}"
printf '%s' '<rss><channel><item><sparkle:version>202610190645</sparkle:version></item></channel></rss>'
exit 0
FAKE
chmod +x "${FAKE_BIN}/curl"
rm -f "$SEQ_FILE" "$SHIP_FILE"
: >"$FAKE_CURL_ARGS_LOG"; : >"$FAKE_ASC_ARGS_LOG"
FAKE_SHARED="$S_STAMP"
run_ship --dry-run
planned_pair
check "feed floor 202610190645 is accepted as the floor" "$(grep -q '202610190645' "$FAKE_ASC_ARGS_LOG" && echo 0 || echo 1)"
check "feed floor 202610190645 plans the shared build (got '${PLANNED_BUILD}')" "$([[ "$PLANNED_BUILD" == "$S_STAMP" ]] && echo 0 || echo 1)"
cat >"${FAKE_BIN}/curl" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${FAKE_CURL_ARGS_LOG:-/dev/null}"
printf '%s' '<rss><channel><item><sparkle:version>0</sparkle:version></item></channel></rss>'
exit 0
FAKE
chmod +x "${FAKE_BIN}/curl"
rm -f "$SEQ_FILE" "$SHIP_FILE"
: >"$FAKE_CURL_ARGS_LOG"; : >"$FAKE_ASC_ARGS_LOG"
run_ship --dry-run
check "feed floor 0 fails closed (rc=${RC})" "$([[ $RC -ne 0 ]] && echo 0 || echo 1)"
check "feed floor 0 says outside 1..12 digits" "$(contains 'outside 1..12 digits' && echo 0 || echo 1)"
cat >"${FAKE_BIN}/curl" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${FAKE_CURL_ARGS_LOG:-/dev/null}"
printf '%s' '<rss><channel><item><sparkle:version>2026102909300</sparkle:version></item></channel></rss>'
exit 0
FAKE
chmod +x "${FAKE_BIN}/curl"
rm -f "$SEQ_FILE" "$SHIP_FILE"
: >"$FAKE_CURL_ARGS_LOG"; : >"$FAKE_ASC_ARGS_LOG"
run_ship --dry-run
check "a 13-digit feed floor fails closed (rc=${RC})" "$([[ $RC -ne 0 ]] && echo 0 || echo 1)"
check "a 13-digit feed floor says outside 1..12 digits" "$(contains 'outside 1..12 digits' && echo 0 || echo 1)"
check "a 13-digit feed floor names the URL and the value" "$(contains "$FEED_URL" && contains '2026102909300' && echo 0 || echo 1)"
check "a 13-digit feed floor never reaches plan-release-build" "$([[ ! -s "$FAKE_ASC_ARGS_LOG" ]] && echo 0 || echo 1)"
cat >"${FAKE_BIN}/curl" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${FAKE_CURL_ARGS_LOG:-/dev/null}"
printf '%s' '<rss><channel><item><sparkle:version>2026102909300000011</sparkle:version></item></channel></rss>'
exit 0
FAKE
chmod +x "${FAKE_BIN}/curl"
rm -f "$SEQ_FILE" "$SHIP_FILE"
: >"$FAKE_CURL_ARGS_LOG"; : >"$FAKE_ASC_ARGS_LOG"
run_ship --dry-run
check "a 19-digit feed floor fails closed (rc=${RC})" "$([[ $RC -ne 0 ]] && echo 0 || echo 1)"
check "a 19-digit feed floor says outside 1..12 digits" "$(contains 'outside 1..12 digits' && echo 0 || echo 1)"
check "a 19-digit feed floor never reaches plan-release-build" "$([[ ! -s "$FAKE_ASC_ARGS_LOG" ]] && echo 0 || echo 1)"
python3 - "$ROUND2DIR/apps.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["apps"]["clutch"].pop("pairedBuildFeed", None)
d["apps"]["clutch"]["pairedBundleId"] = "trade.example.lonelymac"
d["apps"]["clutch"].pop("macBundleId", None)
json.dump(d, open(p, "w"), indent=2)
PY
cat >"${FAKE_BIN}/curl" <<'FAKE'
#!/usr/bin/env bash
echo "fake curl: no feed is configured; refusing the call" >&2
exit 99
FAKE
chmod +x "${FAKE_BIN}/curl"
APP_KEY_SAVED_14="$APP_KEY"; APP_KEY="lonelymac"
rm -f "${STATE}/build-seq-lonelymac.txt" "${STATE}/last-ship-lonelymac.txt"
: >"$FAKE_ASC_ARGS_LOG"
FAKE_SHARED="$S_STAMP"; FAKE_RELEASED=""
run_ship --dry-run
planned_pair
check "macOS entry without a paired id reverse-pairs to the iOS bundle id" "$(grep -q 'codes.clutch.ios' "$FAKE_ASC_ARGS_LOG" && echo 0 || echo 1)"
check "reverse-paired macOS entry plans the shared build (got '${PLANNED_BUILD}')" "$([[ "$PLANNED_BUILD" == "$S_STAMP" ]] && echo 0 || echo 1)"
python3 - "$ROUND2DIR/apps.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["apps"]["lonelymac"]["pairedBundleId"] = "codes.clutch.direct"
json.dump(d, open(p, "w"), indent=2)
PY
rm -f "${STATE}/build-seq-lonelymac.txt" "${STATE}/last-ship-lonelymac.txt"
: >"$FAKE_ASC_ARGS_LOG"
run_ship --dry-run
check "a macOS entry's own paired id wins over the reverse lookup" "$(grep -q 'codes.clutch.direct' "$FAKE_ASC_ARGS_LOG" && ! grep -q 'codes.clutch.ios' "$FAKE_ASC_ARGS_LOG" && echo 0 || echo 1)"
python3 - "$ROUND2DIR/apps.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["apps"]["clutch"].pop("pairedBundleId", None)
d["apps"]["lonelymac"].pop("pairedBundleId", None)
json.dump(d, open(p, "w"), indent=2)
PY
rm -f "${STATE}/build-seq-lonelymac.txt" "${STATE}/last-ship-lonelymac.txt"
: >"$FAKE_ASC_ARGS_LOG"
run_ship --dry-run
planned_pair
check "macOS entry with no referrer passes no paired id" "$(! grep -q 'codes.clutch' "$FAKE_ASC_ARGS_LOG" && echo 0 || echo 1)"
check "unpaired macOS entry still plans the shared build (got '${PLANNED_BUILD}')" "$([[ "$PLANNED_BUILD" == "$S_STAMP" ]] && echo 0 || echo 1)"
APP_KEY="$APP_KEY_SAVED_14"
clear_record "clutch"
rm -f "${FAKE_BIN}/curl"
SHIP="$SHIP_SAVED_14"; FAKE_ASC_ARGS_LOG=""; FAKE_CURL_ARGS_LOG=""
FAKE_ASC_FLOOR=0; FAKE_RELEASED=""; FAKE_SHARED=""; FAKE_ASC_PATCH=236
echo

echo "passed=${PASS} failed=${FAIL}"
if [[ "$FAIL" -gt 0 ]]; then
  echo "test-ship-seq: ${FAIL} check(s) FAILED"
  exit 1
fi
echo "test-ship-seq: all checks passed"
exit 0
