#!/usr/bin/env bash
# build-ios.sh — Build Harness iOS Companion App via XcodeGen & xcodebuild
#
# Usage:
#   bash scripts/build-ios.sh [options]
#
# Options:
#   --clean         Clean build artifacts before building
#   --device        Build for generic iOS device (arm64)
#   --simulator     Build for generic iOS Simulator (default)
#   --release       Build Release configuration (default: Debug)
#   --help          Show this help

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IOS_DIR="${REPO_ROOT}/ios"

dest="generic/platform=iOS Simulator"
config="Debug"
clean=0

for arg in "$@"; do
    case "$arg" in
        --clean) clean=1 ;;
        --device) dest="generic/platform=iOS" ;;
        --simulator) dest="generic/platform=iOS Simulator" ;;
        --release) config="Release" ;;
        -h|--help)
            sed -n '2,13p' "$0"
            exit 0
            ;;
        *)
            echo "Unknown flag: $arg" >&2
            exit 64
            ;;
    esac
done

echo "==> 1. Generating Xcode project with xcodegen"
(cd "$IOS_DIR" && xcodegen generate)

if [ "$clean" -eq 1 ]; then
    echo "==> 2. Cleaning build folder"
    xcodebuild -project "$IOS_DIR/HarnessCompanion.xcodeproj" \
        -scheme HarnessCompanion \
        -destination "$dest" \
        clean
fi

echo "==> 3. Building HarnessCompanion ($config, $dest)"
xcodebuild -project "$IOS_DIR/HarnessCompanion.xcodeproj" \
    -scheme HarnessCompanion \
    -destination "$dest" \
    -configuration "$config" \
    CODE_SIGNING_ALLOWED=NO \
    build

echo "==> Build succeeded!"
