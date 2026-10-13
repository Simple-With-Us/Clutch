#!/usr/bin/env bash
# Download a CI-built Clutch.app for a given commit from GitHub Releases.
# Verifies sha256 from clutch-mac-build.json.  Never uploads or dispatches ships.
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

REPO="${CLUTCH_MAC_RELEASE_REPO:-Simple-With-Us/Clutch}"
COMMIT="${1:-}"
DEST_APP="${2:-${HOME}/Applications/Clutch.app}"
WORKDIR="${CLUTCH_MAC_FETCH_WORKDIR:-$(mktemp -d)}"
trap '[[ "${CLUTCH_MAC_FETCH_WORKDIR:-}" == "" ]] && rm -rf "$WORKDIR"' EXIT

die() { echo "fetch-ci-mac-app: error: $*" >&2; exit 1; }
log() { echo "fetch-ci-mac-app: $*" >&2; }

[[ -n "$COMMIT" ]] || die "usage: fetch-ci-mac-app.sh <commit-sha> [dest-app-path]"

TAG="mac-${COMMIT}"
API="https://api.github.com/repos/${REPO}/releases/tags/${TAG}"
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  AUTH=( -H "Authorization: Bearer ${GITHUB_TOKEN}" )
else
  AUTH=()
fi

json="$(curl -fsSL "${AUTH[@]}" "$API" 2>/dev/null)" || json=""
if [[ -z "$json" || "$json" == *"Not Found"* ]]; then
  die "no GitHub release for tag ${TAG}"
fi

zip_url="$(python3 -c 'import json,sys; d=json.load(sys.stdin); assets=d.get("assets") or []; z=[a for a in assets if a.get("name")=="Clutch-mac-arm64.zip"]; print(z[0]["browser_download_url"] if z else "")' <<<"$json")"
manifest_url="$(python3 -c 'import json,sys; d=json.load(sys.stdin); assets=d.get("assets") or []; z=[a for a in assets if a.get("name")=="clutch-mac-build.json"]; print(z[0]["browser_download_url"] if z else "")' <<<"$json")"
[[ -n "$zip_url" ]] || die "release ${TAG} has no Clutch-mac-arm64.zip asset"
[[ -n "$manifest_url" ]] || die "release ${TAG} has no clutch-mac-build.json asset"

curl -fsSL "${AUTH[@]}" -o "$WORKDIR/clutch-mac-build.json" "$manifest_url"
curl -fsSL "${AUTH[@]}" -o "$WORKDIR/Clutch-mac-arm64.zip" "$zip_url"

expected="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["sha256"])' "$WORKDIR/clutch-mac-build.json")"
actual="$(shasum -a 256 "$WORKDIR/Clutch-mac-arm64.zip" | awk '{print $1}')"
if [[ "$expected" != "$actual" ]]; then
  die "sha256 mismatch for ${TAG} (expected ${expected}, got ${actual})"
fi

manifest_commit="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["commit"])' "$WORKDIR/clutch-mac-build.json")"
if [[ "$manifest_commit" != "$COMMIT" ]]; then
  die "manifest commit ${manifest_commit} does not match requested ${COMMIT}"
fi

rm -rf "$WORKDIR/Clutch.app"
ditto -x -k "$WORKDIR/Clutch-mac-arm64.zip" "$WORKDIR"
[[ -d "$WORKDIR/Clutch.app" ]] || die "zip did not contain Clutch.app"

mkdir -p "$(dirname "$DEST_APP")"
rm -rf "$DEST_APP"
ditto "$WORKDIR/Clutch.app" "$DEST_APP"
log "installed ${DEST_APP} from ${TAG}"
echo "$DEST_APP"
