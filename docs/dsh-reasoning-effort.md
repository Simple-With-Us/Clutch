# DSH Reasoning Effort

`dshSupport.effortLevels` is the engine-wide list (`none`, `high`, `max`), and
`dshSupport.perModelEffortLevels` overrides it for the rows that need their own
levels.  A consumer folds the map onto its catalog, so a picker reads one list
per model.

## MiniMax M3.1 Flash Preview

| Picker id | Levels |
|---|---|
| `MiniMax-M3.1-Flash-Preview` | `low`, `medium`, `high`, `xhigh`, `max` |

M3.1 is newer than the pi-ai catalog that dsh 0.1.5-rc.2 installs, so dsh only
knows it from the owner's `settings.yaml`.  The levels above work only when
that entry declares them:

```yaml
llm-pi-ai:
  providers:
    minimax:
      models:
        - id: MiniMax-M3.1-Flash-Preview
          name: MiniMax-M3.1-Flash-Preview
          contextWindow: 1000000
          maxTokens: 512000
          reasoningEfforts: { low: low, medium: medium, high: high, xhigh: xhigh, max: max }
          compat: { forceAdaptiveThinking: true }
```

With that entry, pi-ai sends `thinking: {type: "adaptive", display: "summarized"}`
plus `output_config: {effort: <level>}` to `api.minimax.io/anthropic`, and dsh
advertises exactly these five `reasoning_effort` ids plus the provider-default
value `""`.  It advertises no `off`, which is why `none` is not in the list.
Without the entry, dsh refuses every level here with `unknown reasoning effort`.

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
