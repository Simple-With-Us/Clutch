# Muse Code Native ACP

## Summary

Clutch now prefers Muse Code's official experimental ACP v1 server through `muse acp`.  Older Muse builds remain supported through the existing `@bex-co/muse-code-acp` compatibility adapter.

## Why

Muse Code previously reached Clutch only through an MSP-to-ACP community adapter.  Muse Code 1.4.14 includes a native ACP server, so Clutch can use the product's own protocol implementation while retaining the adapter for older installations.

## Files

- `scripts/muse-code-acp.sh` selects `auto`, `native`, or `adapter` backends.
- `src/web/chat-bridge.ts` detects native ACP asynchronously without blocking requests or caching failures.
- `src/web/engine-catalog.ts` publishes the capabilities the active ACP server actually advertises.
- `engines/muse-code.engine.json` and the Muse documentation describe native ACP and the fallback route.
- Muse launcher, catalog, and full-loop sidecar tests cover both backends.

## Verification

- `umask 022 && npm run typecheck && npm test`
- Live `initialize` and `session/new` against Muse Code 1.4.14 using `MUSE_CODE_ACP_BACKEND=native` and the local echo provider.
- `git diff --check`

## Follow-Up

Native Muse 1.4.14 advertises model selection, images, HTTP MCP servers, and device-code login.  It does not advertise session loading or a reasoning-effort option, so Clutch hides those controls for the native backend and restores them automatically when a future ACP server advertises them.
