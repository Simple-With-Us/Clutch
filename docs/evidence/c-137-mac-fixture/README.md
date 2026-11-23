# C-137 Mac Fixture Evidence

The three moments of one synthetic turn on the macOS surface, captured by `ClutchMacFixtureUITests` against the stub sidecar.

## Fixture identity

- Session: `C-137 Mac Fixture Turn` (`c-137-mac-fixture`), served by `StubSidecar` in its fixture mode.
- Engine: `Stub Engine`, served by the stub's own catalog.
- Turn: a running tool call (`read_file`), a permission request the test looks at and never answers, and the transcript the turn ends in.
- Data: fake throughout.  No owner window, no live engine, no live approval, no push, no biometric.

## How to replay it

```bash
CLUTCH_MAC_UI_DERIVED_DATA=/tmp/clutch-mac-dd bash scripts/mac-ui-tests.sh
```

The same sequence runs on every machine, so two captures of it can be compared with each other.

## The captures

- `mac-fixture-running.jpg` — the turn running:  the streamed text, the spinner, and the composer swapped to a stop button.
- `mac-fixture-permission.jpg` — the permission card:  what the tool wants, the tool's own name, and the engine's own options, none of them tapped.
- `mac-fixture-transcript.jpg` — the transcript the turn ended in:  the tool call at `Done`, the final text, and the composer back to sending.

## The receipt

The run that produced these three files executed three tests with no failures and no skips:

```
Test Case '-[ClutchMacUITests.ClutchMacFixtureUITests testTheFixtureTurnRunsStopsAtItsPermissionCardAndEndsInATranscript]' passed
Test Case '-[ClutchMacUITests.ClutchMacSurfaceUITests testWorkspaceOpensAndListsTheStubThread]' passed
Test Case '-[ClutchMacUITests.ClutchMacSurfaceUITests testWorkspaceShowsTheEngineCatalogTheStubServed]' passed
Executed 3 tests, with 0 failures (0 unexpected)
```

The result bundle is `mac-ui.xcresult` at the root of the checkout, and every capture is kept in it as an attachment.

## What a hosted runner can and cannot do here

The macOS CI job runs the same test.  A runner whose automation session cannot see the Mac app's window skips the suite loudly and says so in the result bundle rather than reporting a pass it did not earn, so the captures above are the ones from a machine that could see the window.
