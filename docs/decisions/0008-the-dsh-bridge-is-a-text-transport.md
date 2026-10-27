# Decision 0008 — The dsh bridge is a text transport, not an ACP proxy

**Date:** 2026-10-26
**Status:** Accepted
**Author:** [CODEX]

## Context

The owner asked for the native apps to carry the web canvas's features, and
put approvals first in the order.  A permission request is the one feature
that cannot be built on the client side alone: the engine has to ask, and the
answer has to travel back to the engine while it waits.

The sidecar already speaks real ACP to every engine.  `Bridge` in
`src/web/chat-bridge.ts` sends `initialize`, `session/new`, `session/load`,
`session/list`, `session/prompt` and `session/cancel` over stdio JSON-RPC,
and it already had a handler for an incoming `session/request_permission`.

The engines do not all answer in the same protocol, and the difference
matters here.

**The code engines answer in ACP.**  `mcode acp` and the `muse-code-acp`
adapter are ACP servers, so they send `session/request_permission` to the
sidecar when the model wants a tool approved.

**The dsh engines answer in text.**  `bridges/dsh/dsh-acp.py` does not speak
ACP to dsh at all.  It implements the ACP session methods on the sidecar's
side of the pipe, and then runs `dsh --profile deepseek-headless` (or
`minimax-headless`) as a child process whose stdout it reads line by line:

```python
for line in stdout:
    emit_text(session_id, line)
```

That is a text transport with an ACP-shaped wrapper.  The upstream ACP
server, `@deepseek-ai/dsh-acp`, does send the request — its implementation
calls `conn.request(methods.client.session.requestPermission, params)` — but
the bridge never runs it, because the bridge runs a headless profile instead
of the `acp` profile.

## Decision

The permission relay is built in the sidecar, and the dsh posture stays as it
is until the bridge speaks ACP.

The sidecar holds a permission request instead of answering it, a client says
it can answer by sending `permissions: ask` with the turn, and the answer
comes back through `POST /clutch/v1/permissions`.  A client that does not say
keeps the old behaviour, where the sidecar answers the request itself, so
nothing that already worked changes shape.

The sidecar also stops forcing `DSH_PERMISSION_MODE=danger-full-access` over
the operator's choice, so the posture is theirs to set rather than the
sidecar's.

What is deliberately not done here is flipping the headless profiles to
ask.  A profile change alone would not produce a request: the bridge would
still be reading text, and dsh's approval request would have nowhere to go.
The profiles also carry a deliberate decision — `settings-deepseek-headless.yaml`
says the phone cannot answer approval prompts — which the native approval
card is the thing that changes.

## Consequences

The relay and the native card are live for the code engines, which speak ACP
and ask on their own.

DeepSeek and MiniMax do not ask yet, because the bridge does not carry the
question.  Making them ask is a transport change: the bridge has to proxy
the ACP session methods to dsh's ACP server instead of running a headless
profile, and forward the `session/request_permission` request upstream and
the answer back.

That change is worth doing on its own, and it is the same work that would
bring the rest of the ACP surface to those two engines — plans, todos and
the tool tree all ride on the session updates that the text transport
flattens into prose.

The repo already has the upstream ACP profile pinned and a driver for it:
`src/dsh/acp/driver.ts` spawns `dsh --profile acp`, which is the profile
that carries `@deepseek-ai/dsh-acp-app`.  The headless profiles were built
because the phone could not answer interactive prompts and the headless
runner emits nothing until the final answer, so the work is to keep the
headless settings and gain the ACP transport, not to go back to the default
profile.

## Related

- [`docs/dsh-native-clients.md`](../dsh-native-clients.md) — the dsh host
  contract the native apps can be a second client of.
- [`docs/decisions/0001-bridges-stay-python.md`](./0001-bridges-stay-python.md)
  — why the bridges are Python, and the fixes that must survive any change
  to them.
- [`docs/decisions/0002-acp-core-stays-in-botfleet.md`](./0002-acp-core-stays-in-botfleet.md)
  — why the ACP runtime primitives live in BotFleet rather than here.
