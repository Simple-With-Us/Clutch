# Native dsh clients

Clutch's web UI is the upstream `dsh web` binary.  `scripts/start-web.sh`
execs `clutch.sh web`, so a dsh host — a cordis application — already runs
inside Clutch's always-on stack on `$CLUTCH_WEB_PORT` (3180 by default).

That host is a **client server**.  It serves the dsh client contract: a
unary RPC over HTTP and a stream mux over WebSocket.  The upstream browser UI
is one client of it.  A native Swift app can be another.

This document records why that is worth doing, what the contract is, and what
is and is not built.

## The efficiency gate

The owner set the condition before the work started: build native clients
**only if** cordis is as efficient as possible, and **not** if cordis is
Electron-like or otherwise resource-hungry.  The answer, from the source and
from measurement on this Mac:

| Thing | Size | Processes | Notes |
|---|---|---|---|
| cordis core | 2,696 LOC, 176 KB installed | — | 2 runtime deps, **zero** Node builtin imports |
| dsh host | one Node process | 1 | the `dsh web` process Clutch already runs |
| Clutch's live stack | about 20 MB | 4 node processes | measured with `ps -o rss` |
| Zulip (Electron) | 79 MB | 7 | measured on this Mac |
| Claude (Electron) | 333 MB | 20 | measured on this Mac |

The cost of an Electron app is Chromium, and the numbers above are almost
entirely Chromium.  A native macOS app is a SwiftUI process plus the dsh host
that already runs: no Chromium, no WebKit content process, no JavaScript
engine on the device.

**Upstream's own desktop app is Electron** — `apps/desktop/package.json`
depends on `electron-updater` — so it is not the path, under the owner's own
condition.

## What "the dsh files in the app" means here

dsh is already a dependency of Clutch (`"@deepseek-ai/dsh": "0.1.5-rc.3"`),
and the installed package bundles its own dependencies, including the gateway
and client-connection packages that define the wire contract.  Clutch does
not fork it and does not vendor the upstream tree:

- Upstream is MIT, so a fork is unnecessary.
- Upstream moved `0.1.5-rc.3` → `0.2.1-rc.2` in a day.  A vendored tree of
  roughly 4,100 TypeScript files across about 130 packages would turn every
  bump into a manual merge, and Clutch's npm pin plus `renovate.json` already
  automates that.
- The extension surface Clutch needs — profiles, patch rows, client modules —
  is the one upstream designs for.  Upstream's own words: *"adding a setting
  never means editing the shell."*

What Clutch **does** carry in-repo is the contract itself, in two mirrored
places plus a check that keeps them honest:

- `src/shared/dshHostContract.ts` — the source of truth.
- `ios/App/Models/DshHostModels.swift` and
  `ios/App/Services/DshHostClient.swift` — the Swift mirror.
- `tests/dsh-host-pinned.test.ts` — asserts every constant against the
  **installed** `@deepseek-ai/dsh` build, so a dsh bump that moves the
  contract fails in CI rather than on a phone.

A read-only reference clone of the upstream source lives at
`~/apps/upstream/deepseek-harness`, pinned to `dsh-v0.1.5-rc.3`.  See
[`upstream-dsh-reference.md`](./upstream-dsh-reference.md).

## The contract

Read from the upstream source at the pinned tag, and confirmed byte-for-byte
against the installed package.

### Unary calls

A `POST` to `/api/<endpoint>`.  The body is the client-request envelope, and
the answer is the server-response envelope.

```json
{ "type": "client-request", "rpcId": "clutch-1", "method": "remote.session", "payload": { "args": {} } }
```

```json
{ "type": "server-response", "rpcId": "clutch-1", "result": { "ok": true, "value": {} } }
```

A failure carries a typed error instead of a value:

```json
{ "type": "server-response", "rpcId": "clutch-1", "result": { "ok": false, "error": { "code": "gateway/bad-request", "message": "…", "details": {} } } }
```

Endpoint names are one or more `/`-separated segments, each matching
`[A-Za-z0-9_$.-]+`, with no empty, `.` or `..` segment.  Upstream namespaces
them by domain: `remote.session`, `remote.commands`, `remote.terminal`,
`remote.workspace`, `remote.subagents`, `remote.job`, `remote.remotes`,
`credentials.describe`.

### Streams

The WebSocket mux lives at `/api/remote.mux` and carries every Remote stream.
The cordis event stream is the logical stream `$events`; `$events/result` is
the unary endpoint that returns one event outcome.  The mux is **not** the
unary path — unary calls go over HTTP.

### Authentication

The dsh web process mints a per-process launch token and prints the URL.
`scripts/capture-launch-url.cjs` tees that URL to
`$CLUTCH_HOME/web-launch-url` (mode 0600).  Visiting the URL once exchanges
the token for a signed `HttpOnly` cookie, and every later request carries
that cookie.  The native client does the same exchange on connect.

### The Host fence

The host binds every request to a trusted authority.  Its own words: *"Non-
browser and remote clients pass the same fence via loopback, the listener's
bind IP literal, or a declared `trustedHosts` authority."*  So a native
client is a first-class client, not a workaround — and `scripts/start-web.sh`
already declares loopback, this Mac's Tailscale name, and anything in
`CLUTCH_TRUSTED_HOSTS`.

## What is built

- `src/shared/dshHostContract.ts` — the contract, with the envelope
  builders and parsers, the paths, and the endpoint rules.
- `ios/App/Models/DshHostModels.swift` — the Swift mirror of the envelopes.
- `ios/App/Services/DshHostClient.swift` — the client core: the launch-token
  exchange, the WebSocket mux, unary calls over HTTP, and a sink for the
  event stream.  Shared by the iOS and macOS targets.
- `ios/App/Views/DshHostView.swift` — a native surface that connects, calls
  one endpoint and shows the answer.  Reachable from the "Host" tab on both
  platforms.
- `tests/dsh-host-contract.test.ts` — the contract's own rules.
- `tests/dsh-host-pinned.test.ts` — the contract against the installed dsh.
- `tests/dsh-host-live.test.ts` — the live host, when one is running.

## What is not built yet

- A native rendering of the host's own UI.  Upstream's client UI is a DOM
  bundle, so a native app re-implements the surfaces it wants rather than
  reusing them.  The contract, not the layout, is the reusable part.
- The event stream's frame handling beyond "arrived and parsed".
- The macOS release pipeline still builds the deprecated WKWebView Dock
  shell, not this app.  That is tracked separately and needs the owner's go,
  because shipping it replaces the app that is installed on his Mac.

## Telemetry

`scripts/lib/clutch-env.sh` exports `DSH_TELEMETRY_DISABLED=1`.  The dsh base
bundle mounts a `session-telemetry-otel` row that exports session events to
DeepSeek's collector, and the web bundle adds a product-telemetry row on top
of it.  Upstream ships the kill switch: `apps/cli/src/profile-boot.ts` reads
the variable, and `resolveTelemetryPatch()` turns the row off for **any**
non-empty value — including `0` and `false` — so the row never mounts.  Clutch
keeps the engine offline unless the operator sets the variable to the empty
string on purpose.
