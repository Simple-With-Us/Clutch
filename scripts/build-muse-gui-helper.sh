#!/usr/bin/env bash
# Build and package the on-demand Muse ACP helper as a nested app bundle.
set -euo pipefail

die() { echo "build-muse-gui-helper.sh: $*" >&2; exit 1; }

if [[ $# -lt 1 ]]; then
  die "usage: build-muse-gui-helper.sh <output.app> [arm64] [x86_64]"
fi

OUTPUT_APP="$1"
shift
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT/native/muse-gui-helper/main.swift"
INFO="$ROOT/native/muse-gui-helper/Info.plist"
if [[ ! -f "$SOURCE" || ! -f "$INFO" ]]; then
  die "native/muse-gui-helper source or Info.plist is missing"
fi
if [[ -e "$OUTPUT_APP" || -L "$OUTPUT_APP" ]]; then
  die "output already exists: $OUTPUT_APP"
fi

if [[ $# -eq 0 ]]; then
  set -- "$(uname -m)"
fi

ARCHS=()
for arch in "$@"; do
  case "$arch" in
    arm64|x86_64) ARCHS+=("$arch") ;;
    *) die "unsupported app architecture: $arch" ;;
  esac
done
if [[ ${#ARCHS[@]} -eq 0 ]]; then
  die "no app architectures were supplied"
fi

TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/clutch-muse-helper.XXXXXX")"
cleanup() { rm -rf "$TEMP_ROOT"; }
trap cleanup EXIT

SDK="$(xcrun --sdk macosx --show-sdk-path)"
BINARIES=()
for arch in "${ARCHS[@]}"; do
  binary="$TEMP_ROOT/ClutchMuseACP-$arch"
  xcrun --sdk macosx swiftc \
    -sdk "$SDK" \
    -target "$arch-apple-macosx14.0" \
    -O \
    "$SOURCE" \
    -o "$binary"
  BINARIES+=("$binary")
done

mkdir -p "$OUTPUT_APP/Contents/MacOS"
ditto "$INFO" "$OUTPUT_APP/Contents/Info.plist"
if [[ ${#BINARIES[@]} -eq 1 ]]; then
  ditto "${BINARIES[0]}" "$OUTPUT_APP/Contents/MacOS/ClutchMuseACP"
else
  xcrun lipo -create "${BINARIES[@]}" -output "$OUTPUT_APP/Contents/MacOS/ClutchMuseACP"
fi
chmod 755 "$OUTPUT_APP/Contents/MacOS/ClutchMuseACP"

for arch in "${ARCHS[@]}"; do
  xcrun lipo -verify_arch "$arch" "$OUTPUT_APP/Contents/MacOS/ClutchMuseACP"
done
