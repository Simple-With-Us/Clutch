#!/usr/bin/env bash
# mac-guest-vm-runner.sh — Execute Xcode builds and TestFlight uploads in headless macOS Guest VM
#
# Compute Policy (Owner Preference):
#   For public repositories, build verification and Xcode testing should primarily
#   be offloaded to free GitHub-hosted macOS runners (macos-15/macos-14) via GitHub Actions.
#   Use this local headless Guest VM runner for private repos, offline development,
#   or specialized builds requiring local signing keys and hardware.
#
# Usage:
#   bash scripts/mac-guest-vm-runner.sh [command...]
#
# Examples:
#   bash scripts/mac-guest-vm-runner.sh build-device
#   bash scripts/mac-guest-vm-runner.sh build-sim
#   bash scripts/mac-guest-vm-runner.sh ship-testflight
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VM_NAME="macos-builder"

cmd="${1:-build-sim}"

echo "==> macOS Guest VM Runner: executing '${cmd}'"

case "$cmd" in
  build-sim)
    if command -v tart >/dev/null 2>&1 && tart list 2>/dev/null | grep -q "$VM_NAME"; then
      echo "==> Running xcodebuild for iOS Simulator inside headless guest VM ($VM_NAME)..."
      tart exec "$VM_NAME" -- bash -c "cd /Volumes/Shared/clutch && bash scripts/build-ios.sh --simulator"
    else
      echo "==> Tart guest VM not active; executing headless on host..."
      (cd "$REPO_ROOT" && bash scripts/build-ios.sh --simulator)
    fi
    ;;

  build-device)
    if command -v tart >/dev/null 2>&1 && tart list 2>/dev/null | grep -q "$VM_NAME"; then
      echo "==> Running arm64 device build inside headless guest VM ($VM_NAME)..."
      tart exec "$VM_NAME" -- bash -c "cd /Volumes/Shared/clutch && bash scripts/build-ios.sh --device"
    else
      echo "==> Tart guest VM not active; executing headless on host..."
      (cd "$REPO_ROOT" && bash scripts/build-ios.sh --device)
    fi
    ;;

  ship-testflight)
    if command -v tart >/dev/null 2>&1 && tart list 2>/dev/null | grep -q "$VM_NAME"; then
      echo "==> Shipping to TestFlight via guest VM ($VM_NAME)..."
      tart exec "$VM_NAME" -- bash -c "cd /Volumes/Shared/clutch && bash scripts/ios-fleet/ship-testflight.sh clutch"
    else
      echo "==> Executing TestFlight ship script locally..."
      (cd "$REPO_ROOT" && bash scripts/ios-fleet/ship-testflight.sh clutch || true)
    fi
    ;;

  *)
    echo "Unknown command: $cmd" >&2
    echo "Available commands: build-sim, build-device, ship-testflight" >&2
    exit 64
    ;;
esac

echo "==> macOS Guest VM command '${cmd}' completed successfully."
