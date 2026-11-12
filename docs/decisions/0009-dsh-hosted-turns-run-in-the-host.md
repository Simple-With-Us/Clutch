# Decision 0009 — The dsh-hosted engines run their turns in the host

**Date:** 2026-10-26
**Status:** Accepted
**Author:** [CODEX]

## Context

The owner asked for the native apps to carry the web canvas's features, and
put approvals first.  The permission relay landed in
[decision 0008](./0008-the-dsh-bridge-is-a-text-transport.md) and works for the
code engines, which speak ACP and ask on their own.  DeepSeek and MiniMax
did not ask, because their turns ran on a bridge that reads text.

Reading the installed dsh build showed where the missing features actually
live.  The host owns the sessions of the agents it runs, and with them the
agent's todo list, its tool calls, its plan and its approval requests.  The
web canvas is a client of that host, which is why it shows all of it.  The
sidecar was not: it drove the dsh engines through the bridge, so the native
apps saw a thin transcript with none of the state the host was already
keeping.

The host's contract for a turn is small.  `session/create` opens a thread,
`session/prompt` sends the turn, and `session/follow` carries the thread's
events.  Approval is not an event but a waterfall: the host hands the
question to every client on its `$events` stream and waits for a decision,
which comes back on `$events/result` with the id the question carried.  The
waterfall's `agentId` is the host's agent id, and the agent id is the
session id, so a question can be routed to the turn that owns it.

## Decision

The dsh-hosted engines' turns run inside the host, and the sidecar speaks the
host's contract on their behalf.

The native apps are unchanged in what they speak: they still talk to the
sidecar, never to the host.  The sidecar is the consolidation point, and it
is the one place an upstream bump is absorbed.

The approval relay opens the host's event stream once and keeps it open,
because the host asks every connected client at once and a per-turn stream
would open a generation of its own for each question.  A question about a
thread nobody in the sidecar is driving is left alone: the web canvas is
entitled to answer its own, and answering it here would take the question
away from the person looking at it.

## Consequences

DeepSeek and MiniMax now show the plan, the tool calls and the approval
card, because they are the host's own state rather than a reconstruction of
it.  A thread the sidecar starts is a host thread, so it appears in the
host's own list and survives a restart of the sidecar.

The bridge path stays.  It is still the path for the code engines, and it is
now the fallback for the dsh engines when the host cannot be reached, so a
machine whose host is down is not a machine without DeepSeek.

The text transport from decision 0008 is no longer the dsh engines' only
path, which changes the argument for making the bridge speak ACP.  That
work is still worth doing, because the bridge is what the code engines and
Shellular use, but it is no longer on the critical path for the native
apps' parity.

## Alternatives considered

**Make the bridge proxy ACP.**  The upstream `@deepseek-ai/dsh-acp` server
does send the permission request; the bridge runs a headless profile
instead, and reads its stdout as text.  Proxying the ACP session methods
would give the dsh engines the same surface the code engines have.

It was not chosen first for three reasons.  The bridge is shared with
Shellular, so the change reaches further than Clutch's own clients.  It
changes the bridge's process lifecycle, which carries production fixes that
have to survive the change.  And the ACP profile is not the profile the
dsh-hosted engines are configured for, so the work would be to keep the
headless settings and gain the ACP transport.

Running the turn in the host reaches the same result with no change to the
bridge, and it is what the web canvas does.

## Related

- [`docs/dsh-native-clients.md`](../dsh-native-clients.md) — the dsh host
  contract the native apps are a second client of.
- [`docs/decisions/0008-the-dsh-bridge-is-a-text-transport.md`](./0008-the-dsh-bridge-is-a-text-transport.md)
  — the permission relay, and why the bridge is a text transport.
- [`docs/decisions/0001-bridges-stay-python.md`](./0001-bridges-stay-python.md)
  — why the bridges are Python, and the fixes that must survive any change
  to them.
