#!/usr/bin/env bash
# test-scheduled-ship-gate.sh - Offline tests for scheduled-ship-gate.sh.
#
# The gate is the only thing standing between a half-hourly cron and a
# TestFlight build for every backend commit. It runs exclusively on the owned
# Mac runner, so without these tests a defect in it is invisible until either
# testers get spammed or an iOS change silently never ships. Everything here is
# a throwaway git repo in a scratch dir: no network, no credentials, no
# xcodebuild, no App Store Connect.
#
# Usage: bash scripts/ios-fleet/test-scheduled-ship-gate.sh
#
# ASCII-only (Apple bash 3.2 safe).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GATE="${SCRIPT_DIR}/scheduled-ship-gate.sh"
[[ -f "$GATE" ]] || { echo "missing $GATE"; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/ship-gate-test.XXXXXX")"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

REPO="${TMP}/repo"
STATE="${TMP}/state"
mkdir -p "$REPO" "$STATE"

git -C "$REPO" init --quiet -b main
git -C "$REPO" config user.email "test@example.invalid"
git -C "$REPO" config user.name "gate test"

commit() {
  # commit <path> <content> <message>
  mkdir -p "$(dirname "${REPO}/$1")"
  printf '%s\n' "$2" >"${REPO}/$1"
  git -C "$REPO" add -A
  git -C "$REPO" commit --quiet -m "$3"
  git -C "$REPO" rev-parse HEAD
}

PASS=0
FAIL=0
check() {
  # check <label> <expected> <actual>
  if [[ "$2" == "$3" ]]; then
    echo "  ok  : $1 (=$3)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $1 (expected '$2', got '$3')"
    FAIL=$((FAIL + 1))
  fi
}

run_gate() {
  # run_gate <event> [extra args...] -> prints "key=value" lines
  # The old single-prefix call, kept working by the repeatable flag.
  local event="$1"; shift
  bash "$GATE" \
    --event "$event" \
    --path-prefix "ios/" \
    --repo-root "$REPO" \
    --state-dir "$STATE" \
    "$@" 2>&1
}

run_gate_multi() {
  # run_gate_multi <event> <app>... -> prints "key=value" lines
  # The full on.push.paths set, mirroring the gate step in ios-ship.yml.
  local event="$1"; shift
  bash "$GATE" \
    --event "$event" \
    --path-prefix "ios/**" \
    --path-prefix "assets/clutch-icon-1024.png" \
    --path-prefix "scripts/ios-fleet/**" \
    --path-prefix "scripts/ios-ship-testflight.sh" \
    --path-prefix "scripts/ios-appstore-gm-prepare.sh" \
    --path-prefix "scripts/ios-install-appstore-profiles.sh" \
    --path-prefix "scripts/ios-xcodegen-post.sh" \
    --path-prefix "scripts/ios-ui-tests.sh" \
    --path-prefix "ios/appstore-profiles.json" \
    --path-prefix ".github/workflows/ios-ship.yml" \
    --repo-root "$REPO" \
    --state-dir "$STATE" \
    "$@" 2>&1
}

field() {
  # field <output> <key>
  printf '%s\n' "$1" | awk -F= -v k="$2" '$1 == k {print $2}' | tail -1
}

set_state() {
  # set_state <app> <sha>
  printf '%s %s\n' "$(date +%s)" "$2" >"${STATE}/last-ship-$1.txt"
}

echo "== syntax =="
bash -n "$GATE" && echo "  ok  : scheduled-ship-gate.sh parses"

echo "== fixture =="
BASE="$(commit README.md base "base")"
echo "  base commit ${BASE:0:10}"

echo "== 1. push/dispatch events bypass the gate entirely =="
out="$(run_gate push demo)"
check "push -> should_ship" 1 "$(field "$out" should_ship)"
out="$(run_gate workflow_dispatch demo)"
check "workflow_dispatch -> should_ship" 1 "$(field "$out" should_ship)"

echo "== 2. scheduled tick with no ship history skips (hosted runner is empty) =="
out="$(run_gate schedule demo)"
check "no state -> should_ship" 0 "$(field "$out" should_ship)"

echo "== 3. scheduled tick on an already-shipped HEAD skips =="
set_state demo "$BASE"
out="$(run_gate schedule demo)"
check "HEAD already shipped -> should_ship" 0 "$(field "$out" should_ship)"

echo "== 4. backend-only commits since the last ship do NOT ship =="
commit "server/api.ts" "backend change" "feat(server): unrelated to iOS" >/dev/null
commit "docs/notes.md" "docs" "docs: nothing an iOS tester can see" >/dev/null
out="$(run_gate schedule demo)"
check "backend-only -> should_ship" 0 "$(field "$out" should_ship)"

echo "== 5. an iOS change since the last ship DOES ship =="
commit "ios/App/View.swift" "// ui" "fix(ios): visible change" >/dev/null
out="$(run_gate schedule demo)"
check "ios change -> should_ship" 1 "$(field "$out" should_ship)"

echo "== 6. per-app outputs are independent =="
HEAD_SHA="$(git -C "$REPO" rev-parse HEAD)"
set_state demo "$HEAD_SHA"          # caught up
set_state demo-local "$BASE"        # behind, and iOS changed since BASE
out="$(run_gate schedule demo demo-local)"
check "caught-up app" 0 "$(field "$out" ship_demo)"
check "behind app" 1 "$(field "$out" ship_demo_local)"
check "any-app roll-up" 1 "$(field "$out" should_ship)"

echo "== 7. an unreachable last-ship sha falls back to the recorded timestamp =="
# Observed live on Usage-Monitor 2026-08-13: the recorded ship sha was the tip
# of a grok/* ship worktree, not an ancestor of main. Skipping forever would
# make the backstop useless; shipping blind would spam TestFlight.
rm -f "${STATE}/last-ship-demo-local.txt"
FUTURE=$(( $(date +%s) + 600 ))
printf '%s %s\n' "$FUTURE" "0000000000000000000000000000000000000000" >"${STATE}/last-ship-demo.txt"
out="$(run_gate schedule demo)"
check "unreachable sha, no newer iOS commits -> should_ship" 0 "$(field "$out" should_ship)"

PAST=$(( $(date +%s) - 86400 ))
printf '%s %s\n' "$PAST" "0000000000000000000000000000000000000000" >"${STATE}/last-ship-demo.txt"
out="$(run_gate schedule demo)"
check "unreachable sha, iOS commits since -> should_ship" 1 "$(field "$out" should_ship)"

printf 'not-a-timestamp deadbeefdeadbeefdeadbeefdeadbeefdeadbeef\n' >"${STATE}/last-ship-demo.txt"
out="$(run_gate schedule demo)"
check "unreachable sha, unusable ts -> defers to ship script" 1 "$(field "$out" should_ship)"

# Back to a clean skip state for the exit-code assertion below.
set_state demo "$(git -C "$REPO" rev-parse HEAD)"

echo "== 8. deciding 'skip' is never an error exit =="
run_gate schedule demo >/dev/null
check "exit code on skip" 0 "$?"

echo "== 9. a tooling-only merge since the last ship DOES ship (the missed push) =="
# The root cause: the gate used to replay only ios/, so a merge touching
# only ship tooling or project files never shipped when its push run was
# missed (workflow disabled at merge time, a dropped event, a bot merge).
commit "scripts/ios-fleet/ship-testflight.sh" "# tooling fix" "fix(ios-fleet): tooling-only" >/dev/null
out="$(run_gate schedule demo)"
check "old single-prefix call still skips tooling-only" 0 "$(field "$out" should_ship)"
out="$(run_gate_multi schedule demo)"
check "tooling-only change, full push set -> should_ship" 1 "$(field "$out" should_ship)"

echo "== 10. a workflow-file-only merge since the last ship DOES ship =="
set_state demo "$(git -C "$REPO" rev-parse HEAD)"
commit ".github/workflows/ios-ship.yml" "# workflow tune" "ci(ios-ship): tune" >/dev/null
out="$(run_gate_multi schedule demo)"
check "workflow-file-only change -> should_ship" 1 "$(field "$out" should_ship)"

echo "== 11. unrelated-only commits still skip with the full push set =="
set_state demo "$(git -C "$REPO" rev-parse HEAD)"
commit "README.md" "more docs" "docs: readme" >/dev/null
commit "server/api.ts" "backend change" "feat(server): unrelated to iOS" >/dev/null
commit "scripts/build-web.sh" "#!/bin/sh" "chore(web): other tooling" >/dev/null
out="$(run_gate_multi schedule demo)"
check "unrelated-only -> should_ship" 0 "$(field "$out" should_ship)"

echo "== 12. HEAD already shipped still skips with the full push set =="
set_state demo "$(git -C "$REPO" rev-parse HEAD)"
out="$(run_gate_multi schedule demo)"
check "HEAD already shipped (multi) -> should_ship" 0 "$(field "$out" should_ship)"

echo "== 13. a '!' exclusion removes its subtree from a glob =="
commit "ios/Generated/mirror.swift" "// generated" "chore(ios): regen" >/dev/null
out="$(bash "$GATE" --event schedule \
  --path-prefix "ios/**" \
  --path-prefix "!ios/Generated/**" \
  --repo-root "$REPO" \
  --state-dir "$STATE" \
  demo 2>&1)"
check "excluded-only change -> should_ship" 0 "$(field "$out" should_ship)"
out="$(run_gate schedule demo)"
check "same change without the exclusion -> should_ship" 1 "$(field "$out" should_ship)"

echo
echo "passed=${PASS} failed=${FAIL}"
[[ "$FAIL" -eq 0 ]] || exit 1
echo "scheduled-ship-gate: all tests passed"
