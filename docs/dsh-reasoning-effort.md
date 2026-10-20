# DSH Reasoning Effort

`dshSupport.effortLevels` is the engine-wide list (`none`, `high`, `max`), and
`dshSupport.perModelEffortLevels` overrides it for the rows that need their own
levels.  A consumer folds the map onto its catalog, so a picker reads one list
per model.

## MiniMax M3.1 Flash — the stable successor to the retired preview

MiniMax retired `MiniMax-M3.1-Flash-Preview` on 2026-10-18 (BF-2494).  A turn
that asked for that id failed with "model is not available for the
managed_token_plan route" on the API and a `DshModelNotOfferedError` on the
Clutch side.

Its stable successor, **`MiniMax-M3.1-Flash`**, is live and verified on both
routes: the MiniMax API lists it on `/v1/models` and `/anthropic/v1/models`,
a real turn on the direct route answers, and a `mcode exec` on the managed
route runs on it.  It is the M3-class multimodal model the picker offers
instead — `input: [text, image, video]`, 1,000,000 context.

**Do not re-add the retired Preview id.**  The Preview id is gone for good;
`MiniMax-M3.1-Flash` is the row that replaced it.

The M3.1 Flash row carries its own effort list — low / medium / high / xhigh /
max, with no `none` because the model forces thinking on — and it needs the
adaptive flag in the installed settings for those levels to reach the wire:

```yaml
llm-pi-ai:
  providers:
    minimax:
      models:
        - id: MiniMax-M3.1-Flash
          name: MiniMax-M3.1-Flash
          contextWindow: 1000000
          maxTokens: 128000
          reasoningEfforts: { low: low, medium: medium, high: high, xhigh: xhigh, max: max }
          compat: { forceAdaptiveThinking: true }
```

A host still shipping the retired Preview id instead of this row needs the row
replaced, not removed.  The current offered set is `MiniMax-M3.1-Flash`,
`MiniMax-M3`, `MiniMax-M2.7-highspeed` and `MiniMax-M2.7` (in
`STATIC_MINIMAX_MODELS`), and the rest of this file describes the per-model
story in the present tense only for those rows.

## Gate On The Installed Settings

`perModelEffortLevels` is what a row offers when it is configured as above.  A
consumer that can read the install's `settings.yaml` should pass the parsed
document to `dshInstalledEffortLevels(settings)` and use its answer as each
row's own levels.  It keeps a level only when the row's entry, under the
provider route the driver sends it to, maps that level in `reasoningEfforts`
and sets `compat.forceAdaptiveThinking: true`.  Without the flag pi-ai falls
back to fixed thinking budgets, clamps `xhigh` and `max` to `high`, and sends
no `output_config.effort`, so the picker would offer levels that run the same
request.  A missing entry, `reasoningEfforts: false` (the shipped
`minimax-headless` profile), no `reasoningEfforts` at all, or a missing or
non-`true` adaptive flag yields `[]`, and every per-model row is always
present in the answer, so that explicit `[]` wins over the static map.  Pass
`undefined` when the file is missing or unreadable.

## Default

A turn with no effort sends nothing for most rows, so a resumed session keeps
the level it last had.  For a row with per-model levels, Default sends the
provider-default value `""` instead, which clears a level an earlier turn
pinned.  That request is best effort for one failure only: a route that
declares its own default effort refuses `""` with JSON-RPC invalid params
(`-32602`), and the turn then runs at the session's current level rather than
failing.  A timeout or an internal error still fails the turn, since the
session is then in a state nobody has checked.  DeepSeek routes always declare
a default, so they keep the old behavior.

`dshReasoningEffortValue(turn)` returns the value a turn sends, and
`dshEffortLevelsForModel(id)` returns the levels a row offers before the
installed settings narrow them.
