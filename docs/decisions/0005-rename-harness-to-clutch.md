# Decision 0005 — Rename Harness to Clutch

**Date:** 2026-09-30
**Status:** Accepted
**Author:** [CLAUDE]

## Context

The product was named Harness.  The owner chose Clutch (clutch.codes) as its name, registered the App Store Connect record as Clutch.Codes, and renamed the GitHub repo to `jaywedgeworth22/Clutch`.  The old name also collided with the upstream engine's name ("DeepSeek Harness") and with unrelated generic uses of the word across the fleet.

## Decisions

- **Naming:** the product is "Clutch" wherever it names itself, "clutch" in running prose per the copy rule, and "Clutch.Codes" only on store and catalog listings.  The fleet acronym is `CK`, the Slack tag is `repo: clutch`, the board slug is `clutch`, and new lanes are `~/apps/clutch-<seat>[-<lane>]`.
- **Package and CLI:** the npm package is `clutch` (0.4.0).  The CLI is `clutch`, installed as a real wrapper file at `~/.local/bin/clutch`.  Bins, exports (`clutch/dsh/acp`, `clutch/dsh/mcp-patch`, `clutch/minimax/acp`) and env vars follow: every variable this repo owns uses the `CLUTCH_` prefix.  Variables the upstream engine reads (`DSH_HOME`, `DSH_SESSION_ID`, `DSH_PERMISSION_MODE`, and the other upstream-read names) keep their names.
- **MiniMax acronym:** `mmh` becomes `minimax` everywhere in the repo.  `dsh` names stay, because they name the upstream engine.
- **No shims:** there are no compatibility aliases, symlinks, re-exports or fallback paths for the old names.  Anything still using the old name fails loudly so the remaining references get found and fixed.  The root-level shell shims were deleted.
- **State isolation:** `CLUTCH_HOME` defaults to `~/.clutch`.  Every Clutch launcher sets `DSH_HOME="$CLUTCH_HOME/dsh"` unconditionally, so Clutch's engine state (`~/.clutch/dsh`) never mixes with vanilla `dsh` and BotFleet, which keep `~/.dsh`.  Migration copies state; it never moves it.
- **Port:** Clutch web defaults to `3180`.  Vanilla `dsh web` keeps its upstream default of `3080`, so both run side by side.
- **Runtime clone:** `~/apps/clutch-runtime` is a real, standalone `git clone` with its own `node_modules`, updated only on purpose by `scripts/update-mac-app.sh`.  It is not a symlink or a worktree, and pm2 never runs from `~/Code/Clutch`.
- **Apps:** `~/Applications/Clutch.app` (bundle `codes.clutch.macos`) and the iOS app (`codes.clutch.ios`, scheme `clutch://`, version 1.0.0).  See `docs/bundle-id-history.md`.
- **Profiles:** `dsh-headless` and `mmh-headless` become `deepseek-headless` and `minimax-headless`, matching the Shellular agent ids.  The unused web profiles are deleted.
- **Generic noun:** inside this repo no owned line keeps the old word.  Generic phrases are reworded.

## Keep List

These names are not ours and do not change:

- upstream identity: `@deepseek-ai/*` packages, the `dsh` CLI, the "DeepSeek Harness" product name, `github.com/deepseek-ai/deepseek-harness`, and the `deepseek_harness` key;
- the `NOTICE` upstream attribution block and the README credits;
- vanilla DSH state and tooling: `~/.dsh`, `~/apps/dsh-runtime`, `~/.local/bin/dsh`;
- engine-named code: `src/dsh/`, `bridges/dsh/`, `scripts/dsh-acp.sh`, driver ids `dsh` and `dshAgent`, and the Shellular agent ids `deepseek` and `minimax`;
- historical records: dated effort-log rows, `docs/audits/`, earlier decision records 0001-0004, existing rows of `docs/bundle-id-history.md`, and `docs/migrate-from-dsh-runtime.md` (a forward note was added at the top only).

## Consequences

- BotFleet changes its dependency key and import specifiers in a paired PR and switches `isStockDshCli` callers to `isDshEngineCli`.
- Old pairing links, bundle ids and `harness-*` commands stop working at the cutover.  That is intended.
- The Mac cutover (pm2 job, Tailscale Serve, Shellular paths, Dock app, state copy) is a separate, owner-reviewed step after the repo PRs land.
