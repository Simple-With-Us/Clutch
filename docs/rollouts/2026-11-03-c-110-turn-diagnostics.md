# C-110 Turn Diagnostics And Delivery

The chat sidecar records safe turn lifecycle details beside its pairing state, in `diagnostics/turn-diagnostics.jsonl`.  The current file and one rotated file each retain up to 512 KiB; the separate pending export file retains up to 512 KiB.  Files use owner-only permissions and the in-memory write backlog is bounded.

## Recorded Data

Each turn has a generated diagnostic ID, trace ID, engine, observed model/provider and supported native session ID, progress sizes, tool states, plan size, permission/steering outcomes, completion state and duration.  Error records preserve signed ACP codes and a finite failure category.  Prompt/reply text, command arguments, tool output, working paths, authorization and arbitrary provider error bodies are excluded.

Streaming progress counts are coalesced between phase, size and terminal boundaries, with at most one ordinary periodic progress write per second.  Each record retains at most one million reported characters, and the recorded counts retain the full total; ordinary text chunks do not drain or reread the export outbox.  Failure categories are classified before provider messages are replaced with safe display copy, without retaining the original text.

Latest-response token/context observations remain distinct from exact billed calls.  The sidecar records observed occupancy where the engine supplies it and does not invent missing Muse accounting, sum repeated context samples, estimate costs or publish a second cash ledger.

## Transport

`CLUTCH_TELEMETRY_ENDPOINT` and `CLUTCH_TELEMETRY_AUTHORIZATION` are managed through the existing Clutch Infisical settings route.  Both are required for remote export; changing them requires a sidecar restart.  Never use another registered producer's bearer.

Completed spans spool locally before authenticated OTLP HTTP export.  Coherent hub acknowledgements are required before removing pending spans; failures remain pending and back off from five seconds to one minute.  The authenticated health response exposes configuration state, pending count, receiver acceptance/failure times, dropped-record count and local write failures, without endpoint or authorization values.  Receiver acceptance is separate from downstream Sentry or Usage Monitor receipt.

## Verified Deployment Boundary

Inspection of the running server image at `80f0c927` found mandatory metadata-only and Sentry-only mode.  Its authenticated source registry has no Clutch entry.  The source checkout alone had older routing behavior, so it did not establish the running deployment's policy.

This change supplies local diagnostics and the Clutch exporter.  It does not create credentials, borrow another producer's registration, change the server hub policy, or establish either downstream receipt.  Activating Clutch requires its own registered source and matching app configuration; forwarding turn diagnostics to Usage Monitor also requires a reviewed server routing change.  Existing native usage collectors continue to own their authoritative usage records.

## Verification

Focused tests exercise privacy, file bounds/permissions, signed error codes, idempotent terminal handling, failed/rejected exports, persisted retry and receiver acceptance status.  A synthetic full-loop bridge test verifies the real sidecar records a turn and exports its correlated summary to a local stub hub without transcript content or fabricated billing fields.
