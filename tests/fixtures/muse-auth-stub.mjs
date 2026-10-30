#!/usr/bin/env node
import readline from "node:readline";
import { appendFileSync } from "node:fs";

const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
const send = (value) => process.stdout.write(`${JSON.stringify(value)}\n`);
let authenticated = false;
let pendingAuthId = null;
const record = (event) => {
  if (!process.env.MUSE_AUTH_STUB_LOG) return;
  appendFileSync(process.env.MUSE_AUTH_STUB_LOG, `${JSON.stringify(event)}\n`);
};

rl.on("line", (line) => {
  let message;
  try {
    message = JSON.parse(line);
  } catch {
    return;
  }
  const { id, method, params } = message;
  if (method === "initialize") {
    record({ method, capabilities: params?.clientCapabilities });
    send({
      jsonrpc: "2.0",
      id,
      result: {
        authMethods: process.env.MUSE_AUTH_STUB_UNSUPPORTED === "1" ? [] : [
          { id: "muse-login", name: "Log in to Muse", description: "Sign in with a device code shown in your browser." },
        ],
        agentCapabilities: { loadSession: true, sessionCapabilities: { list: {} } },
      },
    });
  } else if (method === "authenticate") {
    record({ method, methodId: params?.methodId });
    if (params?.methodId !== "muse-login") {
      send({ jsonrpc: "2.0", id, error: { code: -32602, message: "unsupported method" } });
      return;
    }
    pendingAuthId = id;
    send({
      jsonrpc: "2.0",
      id: "muse-elicitation",
      method: "elicitation/create",
      params: {
        requestId: "auth-request",
        mode: "url",
        elicitationId: "muse-auth-fixture-1",
        url: "https://login.example.test/device?flow=fixture",
        message: "Open the sign-in page and enter the displayed device code.",
      },
    });
  } else if (id === "muse-elicitation" && pendingAuthId !== null) {
    record({ method: "elicitation/answer", action: message.result?.action });
    if (message.result?.action === "accept") {
      authenticated = true;
      send({ jsonrpc: "2.0", method: "elicitation/complete", params: { elicitationId: "muse-auth-fixture-1" } });
      send({ jsonrpc: "2.0", id: pendingAuthId, result: {} });
    } else {
      send({ jsonrpc: "2.0", id: pendingAuthId, error: { code: -32800, message: "sign-in canceled" } });
    }
    pendingAuthId = null;
  } else if (method === "session/new") {
    record({ method });
    if (!authenticated) {
      send({ jsonrpc: "2.0", id, error: { code: -32000, message: "log in to Muse before opening a session" } });
    } else {
      send({ jsonrpc: "2.0", id, result: { sessionId: "muse-fixture-session", configOptions: [] } });
    }
  } else if (method === "session/prompt") {
    send({ jsonrpc: "2.0", id, result: { stopReason: "endTurn" } });
  } else if (method === "session/list") {
    send({ jsonrpc: "2.0", id, result: { sessions: [] } });
  } else if (method === "session/close") {
    send({ jsonrpc: "2.0", id, result: {} });
  } else if (method === "session/load") {
    send({ jsonrpc: "2.0", id, result: {} });
  }
});
