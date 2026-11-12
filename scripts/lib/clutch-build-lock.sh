#!/usr/bin/env bash
# shellcheck shell=bash
# A one-at-a-time lock for builds that share a DerivedData directory.
#
# Sourced by scripts/build-mac-app.sh.  macOS ships no flock(1), so this is a
# mkdir lock (mkdir is atomic) that records the holder's pid:  a waiter whose
# holder is gone takes the lock over instead of waiting on it forever, and a
# lock directory that never got a pid file is treated as abandoned once it is
# two minutes old.
#
#   clutch_build_lock_acquire DIR [WAIT_SECONDS]   wait for DIR (default 3600s)
#   clutch_build_lock_release                      drop it if this process holds it
#
# The caller owns the EXIT trap:  call clutch_build_lock_release from it.

CLUTCH_BUILD_LOCK_DIR=""

clutch_build_lock_acquire() {
  local dir="$1" wait="${2:-3600}" waited=0 holder again
  # One whole-second poll interval feeds both the sleep and the elapsed-time
  # counter.  A fractional or non-numeric value would break the $(( )) below, and
  # 0 would never advance it, so a bad value falls back to the 2s default and
  # anything under 1s is raised to 1s.  10# keeps a leading zero from reading as
  # octal.
  local poll="${CLUTCH_BUILD_LOCK_POLL_SECONDS:-2}"
  case "$poll" in (''|*[!0-9]*) poll=2 ;; esac
  poll=$((10#$poll))
  [ "$poll" -ge 1 ] || poll=1
  while ! mkdir "$dir" 2>/dev/null; do
    holder="$(cat "$dir/pid" 2>/dev/null || true)"
    if [ -n "$holder" ]; then
      if ! kill -0 "$holder" 2>/dev/null; then
        # The holder died without releasing.  Look again right before removing,
        # so a waiter that already took the lock over is not undone.
        again="$(cat "$dir/pid" 2>/dev/null || true)"
        if [ "$again" = "$holder" ]; then rm -rf "$dir"; fi
        continue
      fi
    elif [ -n "$(find "$dir" -maxdepth 0 -mmin +2 2>/dev/null)" ]; then
      # No pid file and two minutes old:  the holder died between mkdir and
      # writing it.
      rm -rf "$dir"
      continue
    fi
    if [ "$waited" -ge "$wait" ]; then
      echo "another build still holds ${dir} after ${wait}s" >&2
      return 1
    fi
    if [ "$waited" -eq 0 ]; then
      echo "waiting for another build to finish (${dir})" >&2
    fi
    sleep "$poll"
    waited=$((waited + poll))
  done
  printf '%s\n' "$$" >"$dir/pid"
  CLUTCH_BUILD_LOCK_DIR="$dir"
}

clutch_build_lock_release() {
  if [ -n "$CLUTCH_BUILD_LOCK_DIR" ] && [ "$(cat "$CLUTCH_BUILD_LOCK_DIR/pid" 2>/dev/null || true)" = "$$" ]; then
    rm -rf "$CLUTCH_BUILD_LOCK_DIR"
  fi
  CLUTCH_BUILD_LOCK_DIR=""
  return 0
}
