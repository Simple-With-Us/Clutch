#!/usr/bin/env node
// chat-bridge-stub.mjs — a fake ACP bridge for the sidecar full-loop test.
// Speaks just enough JSON-RPC over stdio: initialize, session/new,
// session/prompt (emits one agent chunk, then endTurn), session/cancel.
import readline from "node:readline";

const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
const send = (obj) => process.stdout.write(`${JSON.stringify(obj)}\n`);

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
  if (method === "initialize") {
    send({ jsonrpc: "2.0", id, result: {} });
  } else if (method === "session/new") {
    send({ jsonrpc: "2.0", id, result: { sessionId: "stub-session-1" } });
  } else if (method === "session/prompt") {
    const sessionId = params?.sessionId ?? "stub-session-1";
    send({
      jsonrpc: "2.0",
      method: "session/update",
      params: {
        sessionId,
        update: { sessionUpdate: "agent_message_chunk", content: { text: "stub-answer" } },
      },
    });
    send({ jsonrpc: "2.0", id, result: { stopReason: "endTurn" } });
  } else if (method === "session/cancel") {
    send({ jsonrpc: "2.0", id, result: {} });
  } else if (typeof id === "number") {
    send({ jsonrpc: "2.0", id, error: { message: `unknown method ${method}` } });
  }
});
