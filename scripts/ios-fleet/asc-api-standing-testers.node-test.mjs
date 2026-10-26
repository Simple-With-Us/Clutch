import assert from "node:assert/strict";
import test from "node:test";
import { addTesterToGroup } from "./asc-api.mjs";

// C-102: a standing address that is a tester on another fleet app, but has
// no tester record for this app and is not an App Store Connect user.
// Assigning the cross-app record answers 409 STATE_ERROR; the fix creates
// a fresh record for this app instead of giving up with that 409 forever.
test("cross-app record 409 falls through to creating this app's tester", async () => {
  const calls = [];
  const api = async (method, path) => {
    calls.push(`${method} ${path}`);
    if (method === "GET" && path.includes("filter[email]") && path.includes("filter[apps]")) {
      return { ok: true, status: 200, parsed: { data: [] } };
    }
    if (method === "GET" && path.includes("filter[email]")) {
      return {
        ok: true, status: 200,
        parsed: { data: [{ id: "other-app-tester", attributes: { email: "person@example.com" } }] },
      };
    }
    if (method === "GET" && path.includes("filter[apps]")) {
      return { ok: true, status: 200, parsed: { data: [], links: {} } };
    }
    if (method === "POST" && path.includes("/relationships/betaTesters")) {
      return {
        ok: false, status: 409,
        parsed: { errors: [{ code: "STATE_ERROR", detail: "Tester(s) cannot be assigned" }] },
      };
    }
    if (method === "POST" && path === "/v1/betaTesters") {
      return { ok: true, status: 201, parsed: { data: { id: "new-tester", attributes: { email: "person@example.com" } } } };
    }
    throw new Error(`unexpected call ${method} ${path}`);
  };
  const out = await addTesterToGroup({ api, appId: "6817951255", groupId: "g1", email: "person@example.com" });
  assert.equal(out.ok, true);
  assert.ok(calls.some((c) => c === "POST /v1/betaTesters"), `expected a create, got: ${calls.join(" | ")}`);
});

test("already-assigned record stays a no-create success path", async () => {
  const api = async (method, path) => {
    if (method === "GET" && path.includes("filter[apps]")) {
      return {
        ok: true, status: 200,
        parsed: { data: [{ id: "mine", attributes: { email: "person@example.com" } }], links: {} },
      };
    }
    if (method === "GET") return { ok: true, status: 200, parsed: { data: [] } };
    if (method === "POST" && path.includes("/relationships/betaTesters")) {
      return { ok: true, status: 204, parsed: {} };
    }
    throw new Error(`unexpected call ${method} ${path}`);
  };
  const out = await addTesterToGroup({ api, appId: "6817951255", groupId: "g1", email: "person@example.com" });
  assert.equal(out.ok, true);
  assert.equal(out.existing, true);
});
