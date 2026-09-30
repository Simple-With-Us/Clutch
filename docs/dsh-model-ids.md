# DSH Model Ids

Why a model picked in BotFleet can be refused by the installed `dsh`, and how
the driver now avoids it.

## The Failure

`dsh` selects a model through the ACP `model` config option.  Each option value
is an opaque route identity, `JSON.stringify([provider, modelId])`, and the agent
answers `session/set_config_option` with an exact-string lookup in the set it
advertised at `session/new`.  A value it did not advertise is refused with
`Invalid params: unknown model option`, however reasonable it looks.

The ids a picker catalog and a saved bot selection carry are not reliably the
ids an install declares:

| Picker id | Stock dsh 0.1.5-rc.x declares | An owner `settings.yaml` override may declare |
|---|---|---|
| `DeepSeek-V4.1-Flash` | `deepseek-flash` (display name "DeepSeek-V4.1-Flash") | `deepseek-v4.1-flash` |
| `DeepSeek-V4.1-Pro` | `deepseek-v4-pro` (display name "DeepSeek-V4.1-Pro") | `deepseek-v4-pro` |
| `deepseek-v4-flash` (saved before the V4.1 rename) | nothing | nothing |
| `deepseek-v4-pro` (saved before the V4.1 rename) | `deepseek-v4-pro` | `deepseek-v4-pro` |

Building the value from the picker id therefore fails on stock dsh and on an
overridden install alike, and the failure differs per machine.

## The Resolution

`dshModelOptionValue(model, advertised)` takes the session's advertised
`configOptions` and resolves the picker model against the options dsh declared,
within the model's own provider namespace.  First hit wins, strongest first:

1. **exact**: the wire value the picker id would have produced
2. **id**: the declared id, ignoring case
3. **name**: the declared display name, ignoring case
4. **alias**: another spelling of the same DeepSeek model (Flash: `DeepSeek-V4.1-Flash`,
   `deepseek-flash`, `deepseek-v4-flash`; Pro: `DeepSeek-V4.1-Pro`, `deepseek-v4-pro`)

The declared value is what gets sent.  The picker id is never rewritten, so saved
selections keep their id and only the wire value is translated.

- No `model` option in the reply, or one that lists no model: the value is built
  from the picker id exactly as before.
- The session offers models but not this one: `DshModelNotOfferedError` is thrown
  before the switch, naming what is offered.  `classifyDshError` maps it to
  `model_catalog_outage` by type, so the fallback chain moves on.  Sending a value
  dsh did not advertise would only be refused after a wasted round trip, and
  falling back to the session default would silently run a different model than
  the one picked.

## Consumers

BotFleet's ACP core already passes the session's `configOptions` as the second
argument of `selectModel.valueForModel`, so bumping the `harness` dependency is
enough.  `dshSameModel(a, b)` is exported for a catalog merge that needs to fold a
settings-file row such as `deepseek-v4.1-flash` onto the static `DeepSeek-V4.1-Flash`
row instead of listing the model twice.

`session/new` and `session/resume` both return `configOptions`, so resumed
sessions resolve the same way.
