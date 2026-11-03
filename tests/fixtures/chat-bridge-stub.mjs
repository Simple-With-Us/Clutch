#!/usr/bin/env node
// chat-bridge-stub.mjs — a fake ACP bridge for the sidecar full-loop test.
// Speaks just enough JSON-RPC over stdio: initialize, session/list,
// session/new/load, session/prompt, and session/cancel.
import readline from "node:readline";
import { appendFileSync } from "node:fs";

const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
const send = (obj) => process.stdout.write(`${JSON.stringify(obj)}\n`);
let pendingPermission = null;
let pendingSteeringPrompt = null;
let sessionCounter = 0;

// The stub records what the sidecar did to it, so a test can see the engine's
// side of a permission request rather than only the sidecar's own answer.
const logPath = process.env.CHAT_BRIDGE_STUB_LOG;
const record = (entry) => {
  if (!logPath) return;
  try {
    appendFileSync(logPath, `${JSON.stringify(entry)}\n`);
  } catch {
    /* the log is a convenience, never a reason to fail the stub */
  }
};

const finishPrompt = ({ id, sessionId }) => {
  // The engine reports the whole plan every time it changes, so the plan
  // arrives before the answer.
  send({
    jsonrpc: "2.0",
    method: "session/update",
    params: {
      sessionId,
      update: {
        sessionUpdate: "plan",
        entries: [
          { content: "Read the failing test", priority: "high", status: "in_progress" },
          { content: "Fix it", priority: "medium", status: "pending" },
        ],
      },
    },
  });
  send({
    jsonrpc: "2.0",
    method: "session/update",
    params: {
      sessionId,
      update: { sessionUpdate: "agent_message_chunk", content: { text: "stub-answer" } },
    },
  });
  send({ jsonrpc: "2.0", id, result: { stopReason: "endTurn" } });
};

rl.on("line", (line) => {
  const trimmed = line.trim();
  if (!trimmed) return;
  let msg;
  try {
    msg = JSON.parse(trimmed);
  } catch {
    return;
  }
  const { id, method, params } = msg;
  if (!method && id === 900 && pendingPermission) {
    const optionId = msg.result?.outcome?.optionId ?? null;
    const outcome = msg.result?.outcome?.outcome ?? null;
    record({ event: "permission-answered", optionId, outcome });
    if (outcome !== "selected" || optionId !== "allow-once") {
      send({ jsonrpc: "2.0", id: pendingPermission.id, error: { message: "permission was not allowed once" } });
    } else {
      finishPrompt(pendingPermission);
    }
    pendingPermission = null;
    return;
  }
  if (method === "initialize") {
    record({ event: "initialize", clientCapabilities: params?.clientCapabilities });
    send({
      jsonrpc: "2.0",
      id,
      result: {
        agentCapabilities: { loadSession: true, sessionCapabilities: { list: {} } },
        _meta: { "muse/steering": { version: 1, method: "_muse/steer" } },
      },
    });
  } else if (method === "session/list") {
    send({
      jsonrpc: "2.0",
      id,
      result: {
        sessions: [{ sessionId: "mcode-existing-1", title: "Existing MiniMax thread", cwd: "/tmp/project", updatedAt: "2026-10-13T10:00:00Z" }],
      },
    });
  } else if (method === "session/new") {
    // A second turn needs its own session id, or the sidecar cannot tell the
    // two turns apart when it routes a permission request to its owner.
    const sessionId = params?.cwd === "/tmp/engine-collision"
      ? "shared-engine-session"
      : `stub-session-${sessionCounter += 1}`;
    record({ event: "session-new", sessionId });
    send({ jsonrpc: "2.0", id, result: {
      sessionId,
      configOptions: [{ id: "model", currentValue: "muse-model:%5B%22meta%22%2C%22tbh%22%2C%22muse-wonder-1.0%22%5D" }],
    } });
  } else if (method === "session/load") {
    const sessionId = params?.sessionId ?? "mcode-existing-1";
    for (const [sessionUpdate, text] of [
      ["user_message_chunk", "existing question"],
      ["agent_message_chunk", "existing answer"],
    ]) {
      send({ jsonrpc: "2.0", method: "session/update", params: { sessionId, update: { sessionUpdate, content: { text } } } });
    }
    send({ jsonrpc: "2.0", id, result: {
      configOptions: [{ id: "model", currentValue: "muse-model:%5B%22meta%22%2C%22tbh%22%2C%22muse-wonder-1.0%22%5D" }],
    } });
  } else if (method === "session/prompt") {
    const sessionId = params?.sessionId ?? "stub-session-1";
    const promptText = Array.isArray(params?.prompt)
      ? params.prompt.map((part) => part?.text ?? "").join("")
      : String(params?.prompt ?? "");
    if (promptText.includes("transient-error")) {
      send({ jsonrpc: "2.0", id, error: { message: "temporary provider failure" } });
      return;
    }
    if (promptText.includes("after-transient") && sessionId !== "mcode-existing-1") {
      send({ jsonrpc: "2.0", id, error: { message: "loaded thread was detached" } });
      return;
    }
    record({ event: "prompt", sessionId, promptText });
    if (promptText.includes("steer-wait") || promptText.includes("steer-error")) {
      pendingSteeringPrompt = { id, sessionId };
      record({ event: "active-turn", sessionId, turnId: "stub-turn-1" });
      send({
        jsonrpc: "2.0",
        method: "session/update",
        params: {
          sessionId,
          update: { sessionUpdate: "session_info_update", _meta: { "muse/activeTurnId": "stub-turn-1" } },
        },
      });
      return;
    }
    if (Array.isArray(params?.prompt)) {
      pendingPermission = { id, sessionId };
      record({ event: "permission-requested", sessionId });
      send({
        jsonrpc: "2.0",
        id: 900,
        method: "session/request_permission",
        params: {
          sessionId,
          options: [
            { optionId: "allow-once", name: "Allow once", kind: "allow_once" },
            { optionId: "reject-once", name: "Reject", kind: "reject_once" },
          ],
        },
      });
    } else {
      finishPrompt({ id, sessionId });
    }
  } else if (method === "session/cancel") {
    if (pendingSteeringPrompt?.sessionId === params?.sessionId) {
      send({ jsonrpc: "2.0", id: pendingSteeringPrompt.id, result: { stopReason: "cancelled" } });
      pendingSteeringPrompt = null;
    }
    send({ jsonrpc: "2.0", id, result: {} });
  } else if (method === "_muse/steer") {
    record({ event: "steer", params });
    const steeringText = Array.isArray(params?.prompt) ? params.prompt.map((part) => part?.text ?? "").join("") : "";
    if (steeringText === "trigger-error") {
      send({
        jsonrpc: "2.0",
        id,
        error: { code: -32000, message: "muse_session=credential-like-secret prompt=private-test-prompt" },
      });
      return;
    }
    send({ jsonrpc: "2.0", id, result: { status: "accepted", turnId: params?.expectedTurnId } });
    if (pendingSteeringPrompt) {
      finishPrompt(pendingSteeringPrompt);
      pendingSteeringPrompt = null;
    }
  } else if (typeof id === "number") {
    send({ jsonrpc: "2.0", id, error: { message: `unknown method ${method}` } });
  }
});
