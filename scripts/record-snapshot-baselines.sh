#!/usr/bin/env bash
# Lift the snapshot baselines out of a UI test result bundle and into the
# repository.
#
# The test runner is sandboxed and cannot write into the checkout, so a
# recording run attaches each baseline it wrote and this script lifts those
# attachments into the Baselines folder the test target ships.
#
# Usage: scripts/record-snapshot-baselines.sh <result-bundle> <destination>
set -uo pipefail

BUNDLE="${1:-}"
DEST="${2:-}"
if [ -z "$BUNDLE" ] || [ -z "$DEST" ]; then
  printf 'usage: %s <result-bundle> <destination>\n' "$0" >&2
  exit 2
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

xcrun xcresulttool export attachments --path "$BUNDLE" --output-path "$WORK" >/dev/null 2>&1 || {
  printf 'record-snapshot-baselines: could not export the attachments from %s\n' "$BUNDLE" >&2
  exit 1
}

python3 - "$WORK" "$DEST" <<'PY'
import json, os, re, shutil, sys

work, dest = sys.argv[1], sys.argv[2]
manifest = json.load(open(os.path.join(work, "manifest.json")))

# The result bundle names an attachment "<name>-baseline_<index>_<uuid>",
# so the index and the identifier come off before the name is used.
BASELINE = re.compile(r"^(?P<stem>.+)-baseline(?:_\d+_[0-9A-Fa-f-]+)?$")

os.makedirs(dest, exist_ok=True)
written = []
for test in manifest:
    for attachment in test.get("attachments", []):
        name = attachment.get("suggestedHumanReadableName", "")
        match = BASELINE.match(name)
        if not match:
            continue
        source = attachment.get("exportedFileName")
        if not source:
            continue
        # The bundle looks a baseline up as Baselines/<name>.png, so the
        # lifted file has to carry that name.  The "-baseline" suffix is the
        # attachment's marker, not part of the baseline's name, and the
        # result bundle may or may not put an index and an identifier after
        # it.  A lifted file under any other name is never found, and every
        # later run stays in SNAPSHOT-GAP.
        target = os.path.join(dest, match.group("stem") + ".png")
        shutil.copyfile(os.path.join(work, source), target)
        written.append(target)

if not written:
    print("record-snapshot-baselines: no baselines in the result bundle", file=sys.stderr)
    sys.exit(1)
for path in sorted(written):
    print(f"record-snapshot-baselines: wrote {path}")
PY
