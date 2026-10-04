# INFISICAL.md — Clutch

Owner directive (2026-10-03): Infisical is the sole source of truth for every app — secrets, env variables, and tunable settings knobs.  "Truth" means everything an app's behavior depends on that is not code.

Clutch's Infisical project is **`Clutch`** (ID `077fd6f3-9f9b-438e-9b6f-5c69076cf36c`, envs dev / staging / prod).  The always-on Mac instance uses the **prod** environment; override with `CLUTCH_INFISICAL_ENV` for dev work.

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

## Admin gating

Clutch is a single-user local tool: the web UI binds loopback plus the owner's Tailscale tailnet, and the CLI runs as the machine user.  The local user **is** the admin, so the gate is a documented no-op — there is no multi-user role system to check against, and none is invented.  The admin write surfaces are the `clutch-settings` CLI and the Infisical UI itself.

## Key inventory for THIS app

Secrets (placeholders below — Jay fills real values in the Infisical UI; nothing invented here):

| Key | Kind | Default | Notes |
|---|---|---|---|
| `MINIMAX_API_KEY` | secret | — | MiniMax provider auth.  Missing = MiniMax features report "not authenticated", nothing crashes. |
| `DEEPSEEK_API_KEY` | secret | — | DeepSeek provider auth.  Same graceful degradation. |

Env config:

| Key | Kind | Default | Notes |
|---|---|---|---|
| `CLUTCH_MINIMAX_API_KEY_NAME` | config | `MINIMAX_API_KEY` | Which env var holds the MiniMax key |
| `CLUTCH_MINIMAX_BASE_URL` | config | `https://api.minimax.io/v1` | MiniMax API base URL |
| `CLUTCH_MINIMAX_MODEL` | config | `MiniMax-M2.7-highspeed` | Default MiniMax model |
| `CLUTCH_MINIMAX_PROFILE` | config | `minimax-headless` | Default MiniMax cordis profile |
| `CLUTCH_WEB_HOST` | config | `127.0.0.1` | Clutch web bind host |
| `CLUTCH_WEB_PORT` | config | `3180` | Clutch web port (vanilla dsh keeps 3080) |
| `CLUTCH_TAILNET_HOST` | config | — | Override for the detected Tailscale MagicDNS name |
| `CLUTCH_TAILNET_IPV4` | config | — | Optional Tailscale IPv4 trusted for /api |
| `CLUTCH_TRUSTED_HOSTS` | config | — | Extra comma-separated trusted Host values for /api |

Knobs:

| Key | Kind | Default | Notes |
|---|---|---|---|
| `CLUTCH_SETTINGS_REFRESH_MS` | knob | `300000` | Background settings refresh interval (ms); 0 disables the timer |

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

Auth: universal auth.  Credentials come from `INFISICAL_CLIENT_ID` / `INFISICAL_CLIENT_SECRET` in the machine's secret store (Infisical machine identity), never in code.  Keep those in the machine's secret store, never in code.

## Rotation notes

- To rotate a value, an admin edits the key in the Infisical UI (or runs `clutch-settings set`) — running instances pick it up on the next background refresh (≤ 5 minutes) or immediately via `clutch-settings reload` / `SIGHUP`.
- Rotating the universal-auth client secret itself: update `INFISICAL_CLIENT_SECRET` in the machine's secret store, then restart instances.
- If a refresh fails, instances log loudly (`[clutch-settings] ...`) and keep serving last-known-good values; fix Infisical-side access and the next interval recovers automatically.
