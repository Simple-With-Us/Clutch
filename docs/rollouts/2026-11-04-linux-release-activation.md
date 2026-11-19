# Linux Release Activation And C-113 Delivery State

Date: 2026-11-04.  Issue: C-113 (parked for final Mac delivery).  Refs AFC-618.

## What This Adds

The Linux sidecar (`clutch-chat-bridge.service`) used to run from the main checkout.  C-112 and C-113 moved it onto immutable, non-Git release artifacts, and the helpers that did the switch lived only as untracked files in a working lane.  They are now tracked in `scripts/systemd/release-activation/`.

| File | Purpose |
|---|---|
| `activate_release.py` | First-release activation from the main checkout to an immutable release, with preflight, diagnose and recovery modes. |
| `activate_next_release.py` | Guarded release-to-release switch with a rollback mode.  Loads `activate_release.py` as its base. |
| `test_activate_next_release.py` | Six offline tests for attempt ownership, CLI parsing and health retry logic. |
| `verify_health.py` | Starts the staged release on a loopback port with a throwaway home and token, and checks `/clutch/v1/health`. |
| `safe_process_facts.py` | Prints boolean facts about listener processes (cwd, entry point, cgroup, environment shape) without printing any command line or environment value. |

Left out on purpose: the source tarballs, the unit copy, the one-off C-113 recovery finalizer and the catalog-latency measurement script.

## Configuration

The helpers carried deployment paths, a release SHA and expected hashes as constants.  They now read them from the environment, and fail closed when a pin is missing, because an empty expected hash never matches.

| Variable | Meaning |
|---|---|
| `FLEET_APPS_ROOT`, `FLEET_CODE_ROOT` | Fleet roots.  Default to `~/apps` and `~/Code`. |
| `CLUTCH_RELEASES_ROOT` | Where immutable releases live.  Default `$FLEET_APPS_ROOT/runtime/Clutch/releases`. |
| `CLUTCH_SERVICE_USER`, `CLUTCH_SERVICE_HOME` | The account the unit runs as and its home.  Default to the current user. |
| `CLUTCH_MAIN_SOURCE` | The main checkout the first release replaces.  Default `$FLEET_CODE_ROOT/Clutch`. |
| `CLUTCH_RELEASE_SHA`, `CLUTCH_EXPECTED_SOURCE_TREE`, `CLUTCH_EXPECTED_SOURCE_ARCHIVE_SHA256`, `CLUTCH_EXPECTED_PACKAGE_LOCK_SHA256`, `CLUTCH_EXPECTED_DROPIN_SHA256` | Pins for `activate_release.py`. |
| `CLUTCH_PREVIOUS_RELEASE_SHA`, `CLUTCH_PREVIOUS_DROPIN_SHA256` | The release being replaced, for `activate_next_release.py` and its rollback. |
| `CLUTCH_CPU_DROPIN_HASHES` | JSON object of host CPU drop-in path to sha256, kept as machine state. |
| `CLUTCH_NODE`, `CLUTCH_HEALTH_SCRATCH` | Node binary and scratch directory for `verify_health.py`. |

`activate_next_release.py` also takes `--release-sha`, `--source-tree`, `--source-archive-sha256`, `--package-lock-sha256` and `--dropin-sha256` on the command line, and modes `preflight`, `activate`, `rollback` and `diagnose`.

## Delivery State At Parking

- Mac app and standalone runtime were verified at merged `0d92cff0178c22f5a88980dfbc547f462944492a`, build `202611031359`.  The live catalog was Spark 1.3 Contributor, Wonder 1.0 Contributor and Wonder Full 1.0 Contributor, with efforts Minimal through Xhigh.
- The Linux unit ran immutable release `b2cf05df7d70355672787ecd7b0b7f41ec109a35` (PR #247, tree `b9de0233cc801cbedf9a37b7a73e597acdd82db4`).  Pairing, state home, CPU drop-ins and port 3181 were preserved.  Authenticated health returned HTTP 200 with zero active turns.
- Source archive SHA256 `6813041a0ec1e72362dde454b655997ec0c1451e3f161f149ddd18ee91bc6363`, lock SHA256 `3141200b0c0449df9d9def246b363fb84adb2d5f02b9ed8b9c3cae7c504df100`, stable `20-clutch-release.conf` SHA256 `39efcf2fee4ffadda7108126ed75585ab75ddeb94b7e31cdc288bdb783edba43`.
- The first cold Muse-only catalog request returned in 18 ms and the cached one in 5 ms.  Fixture results showed a selected Muse request making zero MiniMax probes.  These are not live Mac latency.
- The helper's first postflight check compared the TSX entry point to the old release path.  No extra restart or rollback happened;  a read-only recovery step verified the real paths and process identities.  Do not rerun activation against the completed attempt.
- Rollback needs a healthy candidate and is not an unconditional recovery claim.

## Still Open

- A fresh Mac-to-Linux paired round trip for the latest release was not verified because the Mac peer was offline.
- The Mac cutover to a package built from the merge SHA was prepared but not run.  Check for the normal CI artifact first, then use the documented local fallback.  Keep the updater pause and backups until delivery is verified.
- A corrected native-selection experiment and any live compaction run were not performed.
- Telemetry (C-110) is parked separately for the hub rollout.
