#!/usr/bin/env node
// chat-bridge-stub.mjs — a fake ACP bridge for the sidecar full-loop test.
// Speaks just enough JSON-RPC over stdio: initialize, session/list,
// session/new/load, session/prompt, and session/cancel.
import readline from "node:readline";

const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
const send = (obj) => process.stdout.write(`${JSON.stringify(obj)}\n`);
let pendingPermission = null;

const finishPrompt = ({ id, sessionId }) => {
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
    if (msg.result?.outcome?.outcome !== "selected" || msg.result?.outcome?.optionId !== "allow-once") {
      send({ jsonrpc: "2.0", id: pendingPermission.id, error: { message: "permission was not allowed once" } });
    } else {
      finishPrompt(pendingPermission);
    }
    pendingPermission = null;
    return;
  }
  if (method === "initialize") {
    send({
      jsonrpc: "2.0",
      id,
      result: { agentCapabilities: { loadSession: true, sessionCapabilities: { list: {} } } },
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
    send({ jsonrpc: "2.0", id, result: { sessionId: "stub-session-1" } });
  } else if (method === "session/load") {
    const sessionId = params?.sessionId ?? "mcode-existing-1";
    for (const [sessionUpdate, text] of [
      ["user_message_chunk", "existing question"],
      ["agent_message_chunk", "existing answer"],
    ]) {
      send({ jsonrpc: "2.0", method: "session/update", params: { sessionId, update: { sessionUpdate, content: { text } } } });
    }
    send({ jsonrpc: "2.0", id, result: {} });
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
    if (Array.isArray(params?.prompt)) {
      pendingPermission = { id, sessionId };
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
    send({ jsonrpc: "2.0", id, result: {} });
  } else if (typeof id === "number") {
    send({ jsonrpc: "2.0", id, error: { message: `unknown method ${method}` } });
  }
});
