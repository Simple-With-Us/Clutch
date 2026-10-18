# Decision 0007 — Usage accounting rides the dsh session logs

**Date:** 2026-10-17
**Status:** Accepted
**Author:** [CLAUDE]
**Issue:** CK-79 (Linear C-79)

## Context

Usage Monitor (UM) needs to see what Clutch spends on paid models.  The first
audit (2026-10-15) found no token or cost accounting anywhere in `src/minimax`,
`src/deepseek`, `src/dsh` or `engines`, and read that as a gap in Clutch's
direct provider calls.

## Finding

Clutch makes no direct paid-model completion calls.  Every path is a spawned
engine process:

| Path | What actually runs | Where usage lands | UM coverage |
| --- | --- | --- | --- |
| DeepSeek bridge (`scripts/dsh-acp.sh`, `scripts/deepseek-acp.sh`) | `dsh` with DeepSeek | `~/.clutch/dsh/sessions` | `deepseek-dsh` collector, provider `deepseek` |
| MiniMax bridge (`scripts/minimax-acp.sh`, engine `minimax`) | `dsh --profile minimax-headless` | `~/.clutch/dsh/sessions` | same collector, provider `minimax` |
| Muse Code engine plugin | `dsh` with the Muse provider | `~/.clutch/dsh/sessions` | same collector, provider `muse-code` |
| MiniMax Code remote (engine `mcode`) | the `mcode acp` CLI, a separate product | its own store | `minimax-code` producer |
| `src/minimax/http-client` | exports constants only, no `fetch` | none | nothing to count |
| `GET https://api.deepseek.com/models` (dock app, `deepseek-models.ts`) | model list, no tokens billed | none | nothing to count |
| iOS `TranscriptionService` | audio transcription (Whisper), billed per audio second, not per token | none | out of scope here |

The `deepseek-dsh` collector (`scripts/deepseek-usage-collector.mjs` in
Usage-Monitor) reads both `~/.dsh/sessions` and `~/.clutch/dsh/sessions`, and
tags Clutch rows `clutch` in their source metadata.  Prod holds them: DeepSeek,
MiniMax (M3 and M3.1 Flash Preview) and Muse Code rows from Clutch, with exact
input, output and cache-read tokens, model and per-step duration.

## Decision

Clutch does not report usage to UM itself.  A second reporter would only
double count what the collector already reads from the same sessions, and there
is no direct call path left to instrument.  Usage accounting for Clutch is the
`deepseek-dsh` collector, a 15 minute LaunchAgent on the Mac.

## When to revisit

Add an in-process reporter (canonical `ai` block from
`@jaywedgeworth22/congress-trading-shared`, producer `clutch`, `billingMode:
payg`, deterministic `eventId`, off unless an ingest URL and token are set) only
when Clutch gains a code path that calls a provider over HTTP itself, or runs
somewhere the collector cannot read `~/.clutch/dsh/sessions` (for example a
hosted Clutch).  Before adding one, check that its turns do not also land in the
session logs.
