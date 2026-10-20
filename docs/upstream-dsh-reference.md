# Upstream dsh reference checkout

Owner directive (2026-10-17): Clutch must be able to learn from and borrow from
`@deepseek-ai/dsh`, and so must BotFleet, which consumes Clutch's ACP drivers.
Neither is possible from `node_modules`, because the published package ships
compiled output only.

## Why a separate checkout

`@deepseek-ai/dsh-web-frontend/package.json` declares:

```json
"files": ["dist", "!dist/**/*.map", "!dist/preview.html", "!dist/preview"]
```

So npm gives a build artifact with the source maps deliberately excluded.  The
TypeScript exists only in the git repository, whose `apps/web` is a real Vite
app with `src/`.  Verified locally: the shipped `dist` bundle contains **zero**
occurrences of `settings.section` and zero of `Agent presets` — the Settings
dialog is assembled at runtime from slot registrations, not hardcoded into the
bundle.

## Where it is

```
~/apps/upstream/deepseek-harness
```

- **Read-only reference.**  Not a fleet repo, not a lane, not a build input.
  Never commit to it, never push, never open a PR against DeepSeek.  Clutch's
  `AGENTS.md` forbids forks of other people's repositories and any external
  contact without the owner's explicit per-case approval.
- Shallow clone (`--depth 1`) with two tags fetched on demand:
  - `dsh-v0.1.5-rc.3` — commit `a4c74a91e06b00fe0b0937bde982170c526cc842`,
    the exact version Clutch pins at `package.json:71`.
  - `dsh-v0.2.1-rc.2` — upstream HEAD as of 2026-10-17, to see what is moving.
- License: **MIT**, Copyright (c) 2026 DeepSeek.  Vendoring is therefore legal
  with attribution; see the trade-off note below before assuming that is wise.

## How the update story actually works

Clutch pins dsh **exactly** and Renovate auto-merges pin/patch/minor bumps
(`renovate.json`, 5-day minimum release age).  That single pin is the entire
update surface, and it is why Clutch should keep consuming rather than forking:

| Approach | Getting upstream updates |
|---|---|
| Consume via npm (today) | Automatic PRs against one line.  Nothing Clutch owns can break. |
| Adopt the `settings.section` seam | Still npm, but Clutch starts naming dsh's internal bundles in a profile and compiling a client bundle against `dsh-client-ui-slots` — which is **not published**, so a moved slot fails silently. |
| Vendor / fork deepseek-harness | None.  Manual merges across ~130 packages, on an RC line that moved `0.1.5-rc.3` → `0.2.1-rc.2` in a single day. |

## The seams that do exist

Worth knowing before proposing any "we can't do that" conclusion:

- **Client module registration** — `dsh-client-modules` scans enabled cordis
  Loader entries for packages declaring `dsh.client` in their `package.json`,
  and serves each package's built `lib/client.js` under `/plugins`.
- **Settings sections** — `packages/client/ui-settings/src/client/contract/slots.ts`
  declares `settings.section` as `{ kind: 'list'; scope: 'root' }`.  Upstream's
  own header comment states the design intent: *"A feature owns its own
  settings pages — adding a setting never means editing the shell."*
- **HTTP routes** — `dsh-host-webserver` exposes `ctx.webServer.register(route)`.
- **Injecting external plugins** — the cordis patch layer accepts
  `insert?: EntryOptions[]`, not just `disabled` / `config` toggles.

Until Clutch deliberately takes over composing the web app (a `clutch-web`
profile plus a client-bundle build), its own settings surfaces are the
`clutch-settings` CLI, the `GET`/`PUT /clutch/v1/infisical` sidecar route, and
the native Hosts and Settings sheet.

## The client contract

The dsh host serves a client contract, and that is what makes a native app
possible without embedding anything.  Two transports:

- **Unary calls** are a `POST` to `/api/<endpoint>` carrying the
  client-request envelope, answered with the server-response envelope.  The
  endpoint name is the envelope's `method`, and it must be one or more
  `/`-separated segments matching `[A-Za-z0-9_$.-]+`.
- **Streams** ride the WebSocket mux at `/api/remote.mux`.  The cordis event
  stream is the logical stream `$events`; `$events/result` is the unary
  endpoint that returns one event outcome.  The mux is not the unary path.

Authentication is a per-process launch token that is exchanged once for a
signed cookie, and the host binds every request to a trusted authority —
loopback, the listener's bind IP literal, or a declared `trustedHosts` entry.
Upstream's own comment says it plainly: *"Non-browser and remote clients pass
the same fence via loopback, the listener's bind IP literal, or a declared
`trustedHosts` authority."*

Clutch's copy of the contract is `src/shared/dshHostContract.ts`, mirrored in
Swift for the native clients, and pinned against the installed build by
`tests/dsh-host-pinned.test.ts`.  See
[`dsh-native-clients.md`](./dsh-native-clients.md).

### Layout drift between tags

The upstream tree moves between releases, so a path that is correct at one tag
may not exist at another.  At `dsh-v0.1.5-rc.3` — the tag Clutch pins — the
telemetry kill switch lives in `apps/cli/src/profile-boot.ts`, and
`packages/boot/app-boot/src/profile-context.ts` does not exist yet; it
arrives later.  Read the pinned tag, not the checkout's working tree.

## Known trap

`docs/migrate-from-dsh-runtime.md` records a real outage: a headless cordis
patch leaking into the web profile through the cascade loader, which upstream's
`compose()` turns into `Failed to load plugins`.  Any future profile work must
keep the headless patches scoped to their own profile directory.