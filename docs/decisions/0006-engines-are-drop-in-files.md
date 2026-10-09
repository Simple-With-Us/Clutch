# Decision 0006 — Engines are drop-in files

**Date:** 2026-10-09
**Status:** Accepted
**Author:** [CLUTCH]

## Context

Adding an engine to Clutch was a code change in five loosely-coupled places,
none of which was a registry:

1. An `AcpSupport` const under `src/<engine>/acp/`, re-exported through
   `src/index.ts` and mapped in `package.json` `exports`.
2. A `src/profiles/<name>/` directory, if the engine runs inside dsh's cordis
   loop.
3. A `bridges/<name>/` Python file plus a `scripts/<name>-acp.sh` launcher,
   where the filename *is* the registration.
4. Two literal managed-key lists that no generator keeps in sync
   (`src/shared/clutchSettings.ts`, `scripts/lib/clutch-infisical-env.sh`).
5. Hardcoded strings in tests, docs, the Swift dock app and the iOS app.

There was no engine enum, no `EngineId` union, no zod schema and no central
table — `AcpSupport` in `src/shared/acp-core.ts` is deliberately an open shape.
That openness is good for BotFleet, which consumes `createAcpDriver(support)`,
and it is exactly why adding an engine touched everything.

BotFleet had just landed Muse Code as a first-class engine on the Clutch-bridge
shape (PR #864).  Its own write-up recorded the cost: a new driver is spawnable
after one file and still invisible until roughly twenty more touch points are
updated, because there is no single place that says "these are the engines".

## Decision

Introduce a filesystem-discovered engine-plugin format, and make Muse Code its
first plugin.

- `engines/<id>.engine.json` — declarative, maps onto `AcpSupport` without
  executing anything.  This tier exists because most engines need only a
  catalog, model wire values, error patterns and credential names.
- `engines/<id>.engine.mjs` — programmatic, exports an `AcpSupport` for the
  cases that need real logic.
- Discovered from the package's `engines/` and then `$CLUTCH_HOME/engines`, with
  the later directory overriding by `id`.
- `clutch-engines list` reports what resolved and exits non-zero on a broken
  plugin.

The format targets `AcpSupport` as it already exists rather than introducing a
new engine interface, so a plugin and a hand-written driver are
interchangeable at the consumer.

## Consequences

- **Adding an engine stops being a code change** for everything reached over
  ACP: no package export to add, no barrel to extend, no test asserting an exact
  export list.
- **Discovery never throws.**  A malformed plugin becomes a reported problem and
  every other engine still loads, because one bad file in a drop-in directory
  must not take down the engines that work.
- **Bad manifests fail loudly.**  Validation returns every problem at once and
  refuses to map a manifest with any of them; a half-valid engine is worse than
  a missing one.
- **An absent optional key stays absent** on the support record, rather than
  becoming present-and-undefined, so `exactOptionalPropertyTypes` consumers see
  what they expect.
- **Two ids in one directory conflict** rather than override.  There is no
  principled way to choose, so the first in sorted order wins and the other is
  reported.
- **The programmatic tier executes code**, which is why it is a separate
  extension and why per-machine drop-ins in `$CLUTCH_HOME/engines` deserve the
  same trust as the repo.

## What this deliberately does not solve

Recorded so the next reader does not expect it:

- The web model picker is upstream dsh's bundle inside a `WKWebView`, decorated
  by injected JavaScript in `ClutchWindow.swift`.  A plugin does not appear
  there.
- The iOS app's model buttons and its UI test are hardcoded.
- A dsh-hosted engine still needs a `src/profiles/<name>/` directory, and
  `tests/profiles.test.ts` asserts the exact list of profile names.
- Managed settings still need hand edits in two places.
- Token usage has no `AcpSupport` hook.

## Alternatives considered

- **A central engine registry (an enum plus a factory table).**  Better
  discoverability and compile-time safety, and the smallest change to make.  It
  keeps a code change and a release for every new engine, which is the thing
  being removed.  `AcpSupport`'s open shape is not the bug; the missing runtime
  discovery is.
- **Rewrite the existing engines as plugins.**  Rejected as its own unit.
  `dshSupport` and `minimaxSupport` carry logic that reads well as TypeScript
  and is already load-bearing in BotFleet.  Moving them would churn two
  consumers for no user-visible gain.
- **Manifests only, no programmatic tier.**  Rejected: an engine with a live
  model catalog has no declarative encoding, and forcing one into a template
  would have made the first plugin a special case.