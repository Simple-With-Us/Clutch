# INFISICAL.md — Clutch

Owner directive (2026-10-03): Infisical is the sole source of truth for every app — secrets, env variables, and tunable settings knobs.  "Truth" means everything an app's behavior depends on that is not code.

Clutch's Infisical project is **`Clutch`** (ID `077fd6f3-9f9b-438e-9b6f-5c69076cf36c`).  Every Clutch entry point, the bash launcher layer and the Cursor cloud start script read the **prod** environment, and only prod.  The dev and staging environments are retired (owner, 2026-10-10).  A `CLUTCH_INFISICAL_ENV` set to anything else is ignored with a loud stderr warning and prod is used; it never stops a restart.

## The policy

- Infisical holds secrets (API keys), env config (service URLs, hosts, ports, model/provider selection), and tunable settings knobs (anything an admin would tweak without a code deploy).
- Per-user settings live in each app's own store and are **explicitly out of scope** — they never go in Infisical.  For Clutch that means: the iOS companion's per-host connection records stay in the iOS app's on-device store.
- Local dev overrides are documented in `.env.example`; real values are never committed.
- Secret values never appear in code, logs, PR bodies, or chat — names and metadata only.

## The runtime contract

1. **Load at startup.**  Every Clutch entry point (`src/web/*.ts`, `scripts/sync-profiles.ts`) calls `await initClutchSettings()` before reading any managed setting.  With universal-auth credentials present it loads the full settings set from the Clutch Infisical project into an in-memory cache.  Without credentials it seeds the cache from `process.env` with a loud stderr warning (local dev / offline fallback — never silent).
2. **Never fetch per-request.**  `get()` / `getAll()` / `has()` read memory (or explicit env) only — zero network calls, safe in hot paths.  A per-request call to Infisical is the one forbidden pattern.
3. **Backfill, don't rewrite reads.**  After a successful Infisical load, managed keys that are NOT already set in `process.env` are backfilled from the cache; explicitly-set env vars always win (local override).  This is the delivery mechanism: ACP driver env params, Python bridges, and spawned child processes inherit Infisical values through the environment with zero code churn.  The bash launcher layer (`scripts/lib/clutch-env.sh`) gets the same backfill from `scripts/lib/clutch-infisical-env.sh` (curl + python3, never fails the boot).
4. **Background refresh.**  The long-running web server refreshes on an interval (`CLUTCH_SETTINGS_REFRESH_MS`, default 5 minutes, itself tunable via Infisical) and on `SIGHUP`.  Refresh failures log loudly but keep serving the last-known-good cache — settings staleness is safer than an outage.
5. **Write-through on admin save.**  `clutch-settings set KEY VALUE` (and `ClutchSettings.set()`) writes to Infisical FIRST, then updates the cache and `process.env`.  If the Infisical write fails, the save fails — the cache and Infisical never diverge silently.  In env-seed mode (no credentials) `set()` refuses loudly.

## Machine identity — the one thing NOT in Infisical

Infisical cannot hold the credentials that authenticate access to itself.  Storing the key to the store inside the store is circular: you would need the credential before you could fetch the credential.  So exactly three values live on the machine, in one owner-only file:

**`$CLUTCH_HOME/infisical.json`** (default `~/.clutch/infisical.json`), mode `600`:

| Field | Meaning |
|---|---|
| `projectId` | Infisical project (workspace) ID.  Defaults to the canonical Clutch project when absent. |
| `clientId` | Universal-auth machine identity client ID. |
| `clientSecret` | Universal-auth machine identity client secret.  Never rendered, never returned over an API, never logged. |

Precedence is the same rule as every managed key: an explicitly-set `INFISICAL_CLIENT_ID` / `INFISICAL_CLIENT_SECRET` / `INFISICAL_PROJECT_ID` in the environment always wins over the file, so CI and one-off shells can override without editing anything.

Both layers read it — `src/shared/infisicalIdentity.ts` for Node, and `_clutch_infisical_identity()` in `scripts/lib/clutch-infisical-env.sh` for the bash launchers, which run before Node starts.  A missing, unreadable, or malformed file is not an error: it degrades to the existing env-seed behaviour and never blocks a restart.  Writes are atomic (temp file plus rename) at mode `600`, and a loosened mode produces a loud warning.

**Editing it.**  The native **Hosts and Settings** sheet ("Infisical" section, on both iOS and macOS) reads and writes it over `GET`/`PUT /clutch/v1/infisical` on the chat sidecar, and also exposes a managed-setting write-through field backed by `ClutchSettings.set()`.  The Clutch web Settings dialog cannot be used: it is upstream `dsh` code (see "Consuming the client").  **Saving new credentials requires a Clutch restart** — the running process already holds the old client, and the API refuses a request that would both change the identity and write a setting under it.  The CLI remains a first-class surface too: `clutch-settings set KEY VALUE`.

## Admin gating

Clutch is a single-user local tool: the web UI binds loopback plus the owner's Tailscale tailnet, and the CLI runs as the machine user.  The local user **is** the admin, so the gate is a documented no-op — there is no multi-user role system to check against, and none is invented.  The admin write surfaces are the `clutch-settings` CLI, the native Hosts and Settings sheet, and the Infisical UI itself.

## Key inventory for THIS app

Secrets (placeholders below — Jay fills real values in the Infisical UI; nothing invented here):

| Key | Kind | Default | Notes |
|---|---|---|---|
| `MINIMAX_API_KEY` | secret | — | MiniMax provider auth.  Missing = MiniMax features report "not authenticated", nothing crashes. |
| `DEEPSEEK_API_KEY` | secret | — | DeepSeek provider auth.  Same graceful degradation. |
| `META_API_KEY` | secret | — | Meta API key, used by the Muse Code engine plugin (`engines/muse-code.engine.json`).
  Read by the spawned `muse serve` host, which cannot read a login-keychain OAuth credential, so a
  browser login alone leaves headless spawns unauthenticated.  Missing = Muse Code turns fail with
  `not logged in`, classified as `invalid_credentials`; nothing else crashes. |
| `COMETCHAT_AUTH_KEY` | secret | — | CometChat Auth Key served to the paired phone via chat-config (dev-grade; server-minted user tokens are the follow-up). |
| `COMETCHAT_REST_API_KEY` | secret | — | CometChat REST key, backend-only.  The sidecar relay authenticates with it; it never ships in the app. |
| `APPLE_API_KEY_ID` | secret | — | App Store Connect API key id for GitHub-hosted iOS/Mac ships (org-wide GitHub sync or CI fetch). |
| `APPLE_API_ISSUER_ID` | secret | — | App Store Connect issuer id for CI ships. |
| `APPLE_API_KEY_P8_BASE64` | secret | — | Base64 App Store Connect API private key (.p8) for CI ships. |
| `IOS_CERT_P12_BASE64` | secret | — | iOS Distribution identity (.p12, base64) for TestFlight archive signing. |
| `IOS_CERT_PASSWORD` | secret | — | Password for `IOS_CERT_P12_BASE64`. |
| `MAC_CERT_P12_BASE64` | secret | — | Optional Developer ID Application identity for signed `Clutch.app` CI builds. |
| `MAC_CERT_PASSWORD` | secret | — | Password for `MAC_CERT_P12_BASE64`. |

Env config:

| Key | Kind | Default | Notes |
|---|---|---|---|
| `CLUTCH_MINIMAX_API_KEY_NAME` | config | `MINIMAX_API_KEY` | Which env var holds the MiniMax key |
| `CLUTCH_MINIMAX_BASE_URL` | config | `https://api.minimax.io/v1` | MiniMax API base URL |
| `CLUTCH_MINIMAX_MODEL` | config | `MiniMax-M3.1-Flash` | Default MiniMax model |
| `CLUTCH_MINIMAX_PROFILE` | config | `minimax-headless` | Default MiniMax cordis profile |
| `CLUTCH_WEB_HOST` | config | `127.0.0.1` | Clutch web bind host |
| `CLUTCH_WEB_PORT` | config | `3180` | Clutch web port (vanilla dsh keeps 3080) |
| `CLUTCH_TAILNET_HOST` | config | — | Override for the detected Tailscale MagicDNS name |
| `CLUTCH_TAILNET_IPV4` | config | — | Optional Tailscale IPv4 trusted for /api |
| `CLUTCH_TRUSTED_HOSTS` | config | — | Extra comma-separated trusted Host values for /api |
| `COMETCHAT_APP_ID` | config | — | CometChat App ID (native chat coordinates) |
| `COMETCHAT_REGION` | config | — | CometChat region (us, eu, or in) |
| `COMETCHAT_AGENT_UID` | config | `clutch-agent` | Agent user uid the relay speaks on behalf of |
| `CLUTCH_AGENT_PROXY_ADDRESS` | config | `127.0.0.1:17322` | Address of local Infisical Agent Proxy (host:port) |
| `CLUTCH_AGENT_PROXY_PROJECT_ID` | config | — | Optional Infisical Project ID override for Agent Proxy (defaults to Clutch project) |
| `CLUTCH_AGENT_PROXY_ENV` | config | `prod` | Infisical environment slug for Agent Proxy |
| `CLUTCH_AGENT_PROXY_PATH` | config | `/` | Secret path folder scope for Agent Proxy |
| `CLUTCH_AGENT_PROXY_CA_CERT_PATH` | config | — | Optional CA certificate path for Agent Proxy TLS MITM |

Knobs:

| Key | Kind | Default | Notes |
|---|---|---|---|
| `CLUTCH_SETTINGS_REFRESH_MS` | knob | `300000` | Background settings refresh interval (ms); 0 disables the timer |
| `CLUTCH_AGENT_PROXY_ENABLED` | knob | `false` | Enable routing spawned agent engines through Infisical Agent Proxy |

### Infisical Agent Proxy (optional)

Clutch can optionally route spawned agent engines (ACP drivers, Python bridges, CLI runners) through an Infisical Agent Proxy daemon (`infisical secrets agent-proxy start`).
When `CLUTCH_AGENT_PROXY_ENABLED` is set to `"true"` (in Infisical or via environment), Clutch backfills standard proxy variables into `process.env`:
- `HTTP_PROXY`, `HTTPS_PROXY`, `ALL_PROXY`: `http://<address>` (default `http://127.0.0.1:17322`)
- `NO_PROXY`: `localhost,127.0.0.1`
- `INFISICAL_AGENT_PROXY_ADDRESS`: `<address>`
- `INFISICAL_PROJECT_ID`: `CLUTCH_AGENT_PROXY_PROJECT_ID` (defaults to Clutch project `077fd6f3-9f9b-438e-9b6f-5c69076cf36c`)
- `INFISICAL_ENVIRONMENT`: `CLUTCH_AGENT_PROXY_ENV` (default `prod`)
- `INFISICAL_SECRET_PATH`: `CLUTCH_AGENT_PROXY_PATH` (default `/`)
- `SSL_CERT_FILE`, `NODE_EXTRA_CA_CERTS`: `CLUTCH_AGENT_PROXY_CA_CERT_PATH` (when provided)

Because child engines and ACP processes inherit `process.env`, outbound agent calls are transparently brokered by the proxy.  When disabled (`false`, the default), requests proceed directly.

Clutch only fills variables that are unset, so a proxy variable you set yourself always wins and is never removed.  It remembers the ones it injected: a change to a `CLUTCH_AGENT_PROXY_*` key that Node loaded from Infisical itself (picked up on the next refresh or `SIGHUP` of the running server) re-points them, and `CLUTCH_AGENT_PROXY_ENABLED` set to `false` removes them.  A `CLUTCH_AGENT_PROXY_*` value already in the environment at launch, including one exported by the bash launcher from Infisical, counts as set and needs a restart to change.  `clutch-settings reload` runs in its own process and does not change a running server.

Out of scope (NOT in Infisical): `CLUTCH_HOME` / `CLUTCH_RUNTIME_ROOT` / `DSH_HOME` (bash bootstrap — needed before Node starts), `CLUTCH_LAUNCH_URL_FILE` / `CLUTCH_WEB_URL` (derived at runtime), upstream-read vars (`DSH_HOME`, `DSH_SESSION_ID`, `DSH_PERMISSION_MODE`), per-host iOS connection records (on-device store).

## Consuming the client

```ts
import { initClutchSettings } from "./shared/clutchSettings.ts";

const settings = await initClutchSettings(); // top-level await in entry points

settings.get("CLUTCH_WEB_PORT");        // memory/env only, never network
settings.get("CLUTCH_MINIMAX_MODEL");   // schema default when unset everywhere
await settings.set("CLUTCH_WEB_PORT", "3199");  // write-through to Infisical
await settings.refresh();               // on-demand (SIGHUP wired in start-web.ts)
settings.stop();                        // on shutdown
```

Auth: universal auth.  Credentials come from `INFISICAL_CLIENT_ID` / `INFISICAL_CLIENT_SECRET`, resolved by environment first and then by `$CLUTCH_HOME/infisical.json` (see "Machine identity" above).  Never in code.

### Why Clutch settings cannot be added to the web Settings dialog

The Clutch web UI is **upstream `@deepseek-ai/dsh` code, not this repo's** — `scripts/clutch.sh` execs `node_modules/.bin/dsh`, and the Settings dialog ships inside `@deepseek-ai/dsh-web-frontend`, which npm publishes as compiled `dist` only (`"files": ["dist", "!dist/**/*.map"]`).  So that screen is not editable from here without forking deepseek-harness.

Upstream does expose a supported seam — a `settings.section` runtime slot that its own source documents as "adding a setting never means editing the shell" — but adopting it means Clutch taking over composition of the whole web app (`dsh --profile`, a Clutch profile, and a client bundle built against `dsh-client-ui-slots`, which is *not* published).  That couples Clutch to dsh internals on every upstream bump, which is the opposite of the automatic Renovate updates the exact pin at `package.json:71` buys today.  Until that is deliberately adopted, Clutch's own settings surface is the `clutch-settings` CLI, the `GET`/`PUT /clutch/v1/infisical` sidecar route, and the native Hosts and Settings sheet.

## Rotation notes

- To rotate a value, an admin edits the key in the Infisical UI (or runs `clutch-settings set`) — running instances pick it up on the next background refresh (≤ 5 minutes) or immediately via `clutch-settings reload` / `SIGHUP`.
- Rotating the universal-auth client secret itself: update `INFISICAL_CLIENT_SECRET` in the machine's secret store, then restart instances.
- If a refresh fails, instances log loudly (`[clutch-settings] ...`) and keep serving last-known-good values; fix Infisical-side access and the next interval recovers automatically.

### GitHub-hosted iOS signing sources

`ios-ship.yml` uses `scripts/ios-signing-fetch.mjs` with two explicit prod sources:
- Fleet-OPS (`8dae6d03-8f12-48b2-adf3-e5c1b881c8c5`), `/asc`: `ASC_KEY_ID`, `ASC_ISSUER_ID`, raw PEM `ASC_KEY_P8`.
- Clutch (`077fd6f3-9f9b-438e-9b6f-5c69076cf36c`), `/`: `IOS_CERT_P12_BASE64`, `IOS_CERT_PASSWORD`.

The shared key is mapped to `APPLE_API_KEY_ID`, `APPLE_API_ISSUER_ID`, and
`APPLE_API_KEY_P8_BASE64` for the existing signing preparation script. No Apple
key is copied into Clutch. The CI machine identity must have read access to both
sources. Repository Actions secrets must provide `INFISICAL_CLIENT_ID` and
`INFISICAL_CLIENT_SECRET` (the `INFISICAL_UNIVERSAL_AUTH_*` aliases also work).
Project IDs are non-secret workflow constants rather than encrypted bindings.

Missing CI inputs, authentication/list errors, or missing signing entries fail
before export. GitHub signing-secret fallbacks and Infisical imports are not used.
Local regression test: `node --test scripts/ios-signing-fetch.test.mjs`.
