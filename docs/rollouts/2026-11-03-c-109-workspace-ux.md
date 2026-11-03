# C-109 Workspace Interaction And Response Retention

The owner reported a fixed divider above the current response, an unusable composer during work, disappearing streamed prose, a stale plan, difficult thread selection, hidden project assignments, missing model metadata, and missing Muse contributor choices.

## Behavior

- Drag the horizontal grip between transcript history and current activity to resize the independently scrolling activity pane; the preferred height survives relaunch and clamps to small windows.
- Write while a turn runs, then Queue or Steer from the composer; the macOS Settings sheet selects the default action, with a per-message override.
- Queue sends in order after confirmed successful completion; a dispatched message moves into the transcript, and Stop, stream failure, or unmarked EOF pause the remaining queue for explicit continuation.
- Steering uses Muse's negotiated native `_muse/steer` operation; it injects text into the existing turn without cancelling or starting one.
- Retain already received text and tool state exactly once on success, failure, EOF, or Stop; ignore late events from an older turn.
- Route updates and permission requests by both engine and session ID, keeping different engines isolated even when their native IDs collide.
- Clear the previous plan at the next prompt and show the current plan as a compact expandable summary.
- Follow new tool rows, tool updates, and current response text; context menus can pause following.
- Show immediate thread-opening feedback, cancel superseded loads, retry the failed thread, and keep details behind an explicit action.
- Group assigned threads under named project sections; creating a project from a thread retains the existing create-and-assign behavior and makes its result visible.
- Offer Spark, Wonder, and Wonder Full contributor variants from exact provider catalog IDs and show readable names.
- Report exact provider/model metadata from loaded Muse config options independently of token accounting.

## Performance Evidence

One live process sample measured Clutch at 97.9% of one CPU core; this does not measure its share of overall Mac load.  The sampled main thread repeatedly rebuilt date formatters while laying out the sidebar.

The isolated Mac benchmark sorted 100 synthetic threads ten times.  Original code took 1.8457 seconds; cached parsing and one-pass derivation took 0.0332 seconds, about 56 times faster for that operation.  This is not an end-to-end model response benchmark.

## Verification

- Initial repository gates: TypeScript typecheck, 828 Vitest tests passed with three skipped, and 25 Node tests passed.
- Initial native macOS build passed in an isolated lane without launching or replacing the active app.
- Final repository gates: TypeScript typecheck, 843 Vitest tests passed with three skipped, and 25 Node tests passed, including the same-session-ID cross-engine regression.
- The expanded native Mac build and the isolated Swift partial-output/steering regression executable passed.
- Review fixes reset a fresh empty queue's stale pause, keep tool IDs within the current turn, preserve unidentified tool events, and let cache hits bypass the formatter lock.
- ACP envelopes, steering metadata, and prompt results now use Zod validation; a malformed-frame regression verifies the turn and server remain available.

## Observability And Limits

The reported latest failure was `-32603`, a generic ACP internal error.  Existing Muse logs discarded its underlying reason; historical login failures were followed by successful turns and do not establish this failure's cause.  Classified diagnostics retain a safe numeric code and a fixed category without copying free-form provider text.

Muse ACP `session/list` does not expose model/provider for unvisited sessions.  Opening a session supplies exact config metadata, which Clutch retains for its list and details view; missing values remain unreported rather than inferred from a model picker or unrelated token record.

No live account probes, authentication changes, upstream contact, active-thread interruption, or modification of the dirty integration checkout were performed for the audit and validation.
