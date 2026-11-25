import { generateKeyPairSync, verify } from "node:crypto";
import { mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { IncomingMessage, ServerResponse } from "node:http";

import { afterEach, describe, expect, it } from "vitest";

import {
  ActivityPushRelay,
  ActivityTokenStore,
  buildActivityContentState,
  buildLiveActivityPayload,
  handleActivityTokensRequest,
  splitActivityThreads,
  type ActivityThreadApproval,
  type ActivityThreadRun,
} from "../src/web/activityPushRelay.ts";
import { signApnsJwt } from "../src/web/apnsClient.ts";

const TOKEN = "relay-test-cred";
const CREDENTIAL = `Bearer ${TOKEN}`;
// Composed, never a literal, so no scanner mistakes the fixture for a
// live scheme-and-credential pair.
const WRONG = `Bearer ${TOKEN}-wrong`;
const homes: string[] = [];

afterEach(() => {
  for (const home of homes.splice(0)) rmSync(home, { recursive: true, force: true });
});

function home(): string {
  const dir = mkdtempSync(join(tmpdir(), "clutch-activity-"));
  homes.push(dir);
  return dir;
}

function registration(overrides: Partial<Parameters<ActivityTokenStore["put"]>[0]> = {}) {
  return {
    deviceUid: "clutch-ios-device",
    activityId: "activity-1",
    pushToken: "ab".repeat(32),
    environment: "Sandbox" as const,
    sessionId: "phone-session",
    attributes: {},
    ...overrides,
  };
}

function fakeResponse(): { res: ServerResponse; state: { status: number; body: string } } {
  const state = { status: 0, body: "" };
  const res = {
    writeHead(status: number) {
      state.status = status;
      return res;
    },
    end(value?: string) {
      state.body = value ?? "";
      return res;
    },
  } as unknown as ServerResponse;
  return { res, state };
}

function fakeRequest(method: string, authorization: string | undefined, body?: unknown): IncomingMessage {
  const payload = body === undefined ? "" : JSON.stringify(body);
  const listeners = new Map<string, Array<(...args: unknown[]) => void>>();
  const req = {
    method,
    headers: authorization === undefined ? {} : { authorization },
    on(event: string, handler: (...args: unknown[]) => void) {
      const list = listeners.get(event) ?? [];
      list.push(handler);
      listeners.set(event, list);
      return req;
    },
  } as unknown as IncomingMessage;
  setTimeout(() => {
    for (const handler of listeners.get("data") ?? []) handler(Buffer.from(payload, "utf8"));
    for (const handler of listeners.get("end") ?? []) handler();
  }, 0);
  return req;
}

describe("the activity token store", () => {
  it("keeps the registrations, writes them atomically and keeps the file owner-only", () => {
    const dir = home();
    const file = join(dir, "activity-tokens.json");
    const store = new ActivityTokenStore(file);

    store.put(registration());

    const kept = store.list();
    expect(kept).toHaveLength(1);
    expect(kept[0]?.deviceUid).toBe("clutch-ios-device");
    expect(statSync(file).mode & 0o777).toBe(0o600);
    // The write goes through a temporary file and a rename, so the directory
    // never holds a half-written file next to the real one.
    expect(readdirSync(dir)).toEqual(["activity-tokens.json"]);
    expect(JSON.parse(readFileSync(file, "utf8")).tokens).toHaveLength(1);
  });

  it("replaces the registration of the same activity and takes it away again", () => {
    const store = new ActivityTokenStore(join(home(), "activity-tokens.json"));

    store.put(registration({ pushToken: "cd".repeat(32) }));
    store.put(registration({ pushToken: "ef".repeat(32) }));

    expect(store.list()).toHaveLength(1);
    expect(store.list()[0]?.pushToken).toBe("ef".repeat(32));
    expect(store.remove("clutch-ios-device", "activity-1")).toBe(true);
    expect(store.list()).toHaveLength(0);
    expect(store.remove("clutch-ios-device", "activity-1")).toBe(false);
  });

  it("keeps the newest registrations when there are too many of them", () => {
    const store = new ActivityTokenStore(join(home(), "activity-tokens.json"));

    for (let index = 0; index < 70; index += 1) {
      store.put(registration({ activityId: `activity-${index}`, updatedAt: index }));
    }

    const kept = store.list();
    expect(kept).toHaveLength(64);
    // The oldest registration is the one that goes.
    expect(kept[0]?.activityId).toBe("activity-6");
    expect(kept[kept.length - 1]?.activityId).toBe("activity-69");
  });

  it("reads a damaged file as no registrations rather than as a crash", () => {
    const file = join(home(), "activity-tokens.json");
    const store = new ActivityTokenStore(file);
    store.put(registration());
    writeFileSync(file, "{");
    expect(store.list()).toEqual([]);
  });
});

describe("the activity content state", () => {
  const approval = (overrides: Partial<ActivityThreadApproval> = {}): ActivityThreadApproval => ({
    hostId: "local",
    sessionId: "s1",
    requestId: "r1",
    title: "Refactor The Parser",
    ...overrides,
  });
  const run = (overrides: Partial<ActivityThreadRun> = {}): ActivityThreadRun => ({
    hostId: "local",
    sessionId: "s1",
    title: "Refactor The Parser",
    ...overrides,
  });

  it("counts a thread that waits on two requests once and keeps it out of the running list", () => {
    const split = splitActivityThreads(
      [approval({ requestId: "r1" }), approval({ requestId: "r2" })],
      [run()],
    );

    expect(split.waiting).toHaveLength(1);
    expect(split.running).toHaveLength(0);
  });

  it("keeps a thread on another host apart from this one", () => {
    const split = splitActivityThreads(
      [approval({ hostId: "host-a" })],
      [run({ hostId: "host-b" })],
    );

    expect(split.waiting).toHaveLength(1);
    expect(split.running).toHaveLength(1);
  });

  it("counts the totals and shows the approvals before the runs", () => {
    const state = buildActivityContentState(
      [approval({ sessionId: "w1" })],
      [run({ sessionId: "r1" })],
      1_700_000_000,
    );

    expect(state.waitingCount).toBe(1);
    expect(state.runningCount).toBe(1);
    expect(state.sessions.map((row) => row.id)).toEqual(["w1", "r1"]);
    expect(state.sessions.map((row) => row.status)).toEqual(["waiting", "running"]);
  });

  it("shows three sessions and says how many there really are", () => {
    const state = buildActivityContentState(
      [approval({ sessionId: "w1" }), approval({ sessionId: "w2" }), approval({ sessionId: "w3" }), approval({ sessionId: "w4" })],
      [run({ sessionId: "r1" })],
      1_700_000_000,
    );

    expect(state.sessions).toHaveLength(3);
    expect(state.waitingCount).toBe(4);
    expect(state.runningCount).toBe(1);
  });
});

describe("the live activity payload", () => {
  it("carries the state and nothing about the request", () => {
    const poisoned = {
      hostId: "local",
      sessionId: "s1",
      requestId: "r1",
      title: "Refactor The Parser",
      toolName: "bash",
      reason: "rm -rf /important",
      callId: "call-42",
      cwd: "/Users/dev/app-dir",
      command: "echo build-log.txt",
      diff: "@@ -1 +1 @@",
    } as unknown as ActivityThreadApproval;

    const state = buildActivityContentState([poisoned], [], 1_700_000_000);
    const payload = buildLiveActivityPayload({
      event: "update",
      timestampSeconds: 1_700_000_000,
      attributes: {},
      contentState: state,
    });

    const text = JSON.stringify(payload);
    for (const leak of ["bash", "rm -rf", "call-42", "app-dir", "build-log.txt", "@@ -1 +1 @@"]) {
      expect(text, leak).not.toContain(leak);
    }
    expect(Object.keys(payload.aps)).toEqual(["event", "timestamp", "attributes-type", "attributes", "content-state"]);
    expect(payload.aps["attributes-type"]).toBe("ClutchActivityAttributes");
    expect(payload.aps["content-state"]).toEqual({
      waitingCount: 1,
      runningCount: 0,
      sessions: [{ id: "s1", title: "Refactor The Parser", status: "waiting" }],
      // The host stamps the time on Apple's default Date scale: seconds
      // since 2001-01-01, which is how the system decodes a pushed state.
      updatedAt: 1_700_000_000 - 978_307_200,
    });
  });

  it("carries no attributes whatever the phone registered", async () => {
    // ClutchActivityAttributes has no stored fields, so the host pushes the
    // empty attribute set even against a registration that carried one, and
    // a stored registration cannot put a field onto the island.
    const store = new ActivityTokenStore(join(home(), "activity-tokens.json"));
    store.put(registration({ attributes: { toolName: "bash", cwd: "/Users/jay/secret" } }));
    expect(store.list()[0]?.attributes).toEqual({});

    let approvals: ActivityThreadApproval[] = [{ hostId: "local", sessionId: "s1", requestId: "r1", title: "Needs Me" }];
    const sent: Array<{ payload: unknown }> = [];
    const relay = new ActivityPushRelay({
      store,
      enabled: true,
      sender: {
        sendLiveActivity: async (request) => {
          sent.push({ payload: request.payload });
          return { status: 200 };
        },
      },
      snapshot: () => ({ approvals, runs: [] }),
      now: () => 1_700_000_000_000,
      minIntervalMs: 0,
    });

    await relay.notify();
    await relay.settled();
    expect(sent).toHaveLength(1);
    const aps = (sent[0] as { payload: { aps: Record<string, unknown> } }).payload.aps;
    expect(aps["attributes"]).toEqual({});
    expect(JSON.stringify(sent[0])).not.toContain("secret");
  });

  it("wakes for waiting work and rides the background for routine movement", async () => {
    // Apple budgets Live Activity pushes; only a state where the owner is
    // needed gets priority 10, and counts moving underneath get 5.
    const store = new ActivityTokenStore(join(home(), "activity-tokens.json"));
    store.put(registration());
    const priorities: Array<number | undefined> = [];
    let approvals: ActivityThreadApproval[] = [];
    let runs: ActivityThreadRun[] = [];
    let clock = 1_700_000_000_000;
    const relay = new ActivityPushRelay({
      store,
      enabled: true,
      sender: {
        sendLiveActivity: async (request) => {
          priorities.push(request.priority);
          return { status: 200 };
        },
      },
      snapshot: () => ({ approvals, runs }),
      now: () => (clock += 10_000),
      minIntervalMs: 0,
    });

    await relay.notify();       // nothing waiting, nothing running -> 5
    await relay.settled();
    approvals = [{ hostId: "local", sessionId: "s1", requestId: "r1", title: "Needs Me" }];
    await relay.notify();       // something waits on the owner -> 10
    await relay.settled();
    runs = [{ hostId: "local", sessionId: "s2", title: "Working" }];
    approvals = [];
    await relay.notify();       // busy but nobody is needed -> 5
    await relay.settled();

    expect(priorities).toEqual([5, 10, 5]);
  });
});

describe("the apns provider token", () => {
  it("is a compact token a verifier accepts", () => {
    const { privateKey, publicKey } = generateKeyPairSync("ec", { namedCurve: "prime256v1" });

    const token = signApnsJwt({
      keyId: "KEY1234567",
      teamId: "TEAM123456",
      privateKey,
      issuedAtSeconds: 1_700_000_000,
    });

    const parts = token.split(".");
    expect(parts).toHaveLength(3);
    expect(JSON.parse(Buffer.from(parts[0]!, "base64url").toString("utf8"))).toEqual({ alg: "ES256", kid: "KEY1234567" });
    expect(JSON.parse(Buffer.from(parts[1]!, "base64url").toString("utf8"))).toEqual({ iss: "TEAM123456", iat: 1_700_000_000 });
    const signature = Buffer.from(parts[2]!, "base64url");
    expect(signature).toHaveLength(64);
    const verified = verify(
      "sha256",
      Buffer.from(`${parts[0]}.${parts[1]}`, "utf8"),
      { key: publicKey, dsaEncoding: "ieee-p1363" },
      signature,
    );
    expect(verified).toBe(true);
  });
});

describe("the push relay", () => {
  it("pushes a changed state and does not push an unchanged one", async () => {
    const store = new ActivityTokenStore(join(home(), "activity-tokens.json"));
    store.put(registration());
    const sent: unknown[] = [];
    let approvals: ActivityThreadApproval[] = [];
    const relay = new ActivityPushRelay({
      store,
      enabled: true,
      sender: {
        sendLiveActivity: async (request) => {
          sent.push(request);
          return { status: 200 };
        },
      },
      snapshot: () => ({ approvals, runs: [] }),
      now: () => 1_700_000_000_000,
      minIntervalMs: 0,
    });

    await relay.notify();
    await relay.settled();
    expect(sent).toHaveLength(1);

    // The same state again is not worth a push.
    await relay.notify();
    await relay.settled();
    expect(sent).toHaveLength(1);

    approvals = [{
      hostId: "local",
      sessionId: "s1",
      requestId: "r1",
      title: "Refactor The Parser",
    }];
    await relay.notify();
    await relay.settled();
    expect(sent).toHaveLength(2);
  });

  it("pushes nothing while it is disabled", async () => {
    const store = new ActivityTokenStore(join(home(), "activity-tokens.json"));
    store.put(registration());
    const sent: unknown[] = [];
    const relay = new ActivityPushRelay({
      store,
      enabled: false,
      sender: {
        sendLiveActivity: async (request) => {
          sent.push(request);
          return { status: 200 };
        },
      },
      snapshot: () => ({ approvals: [], runs: [] }),
    });

    await relay.notify();
    await relay.settled();
    expect(sent).toHaveLength(0);
    expect(relay.enabled).toBe(false);
  });
});

describe("the activity token route", () => {
  it("refuses a registration without the sidecar's credential", async () => {
    const store = new ActivityTokenStore(join(home(), "activity-tokens.json"));
    const relay = new ActivityPushRelay({ store, enabled: false, snapshot: () => ({ approvals: [], runs: [] }) });
    const { res, state } = fakeResponse();

    const handled = await handleActivityTokensRequest(
      fakeRequest("PUT", WRONG, registration()),
      res,
      "/clutch/v1/activity-tokens",
      TOKEN,
      relay,
    );

    expect(handled).toBe(true);
    expect(state.status).toBe(401);
    expect(store.list()).toHaveLength(0);
  });

  it("accepts a registration, takes it away again and keeps the token out of the answers", async () => {
    const store = new ActivityTokenStore(join(home(), "activity-tokens.json"));
    const relay = new ActivityPushRelay({ store, enabled: false, snapshot: () => ({ approvals: [], runs: [] }) });

    const put = fakeResponse();
    expect(await handleActivityTokensRequest(
      fakeRequest("PUT", CREDENTIAL, registration()),
      put.res,
      "/clutch/v1/activity-tokens",
      TOKEN,
      relay,
    )).toBe(true);
    expect(put.state.status).toBe(200);
    expect(JSON.parse(put.state.body)).toEqual({ enabled: false, registered: true });
    expect(put.state.body).not.toContain("ab".repeat(32));
    expect(store.list()).toHaveLength(1);

    const remove = fakeResponse();
    expect(await handleActivityTokensRequest(
      fakeRequest("DELETE", CREDENTIAL, { deviceUid: "clutch-ios-device", activityId: "activity-1" }),
      remove.res,
      "/clutch/v1/activity-tokens",
      TOKEN,
      relay,
    )).toBe(true);
    expect(remove.state.status).toBe(200);
    expect(store.list()).toHaveLength(0);
  });

  it("answers a store that cannot be written with a static 500", async () => {
    // The registration file is a directory here, so the atomic rename
    // cannot land.  The route must fail the request, not the process:  a
    // throw out of the handler would take the always-on sidecar with it.
    const dir = home();
    mkdirSync(join(dir, "activity-tokens.json"));
    const store = new ActivityTokenStore(join(dir, "activity-tokens.json"));
    const relay = new ActivityPushRelay({ store, enabled: false, snapshot: () => ({ approvals: [], runs: [] }) });
    const { res, state } = fakeResponse();

    expect(await handleActivityTokensRequest(
      fakeRequest("PUT", CREDENTIAL, registration()),
      res,
      "/clutch/v1/activity-tokens",
      TOKEN,
      relay,
    )).toBe(true);

    expect(state.status).toBe(500);
    expect(state.body).toEqual(JSON.stringify({ error: "the registration could not be stored" }));
    expect(state.body).not.toContain("ab".repeat(32));
  });

  it("refuses a body it cannot use without quoting the token back", async () => {
    const store = new ActivityTokenStore(join(home(), "activity-tokens.json"));
    const relay = new ActivityPushRelay({ store, enabled: false, snapshot: () => ({ approvals: [], runs: [] }) });
    const { res, state } = fakeResponse();

    expect(await handleActivityTokensRequest(
      fakeRequest("PUT", CREDENTIAL, { deviceUid: "d", activityId: "a", pushToken: "not-hex-at-all", environment: "Sandbox", sessionId: "s" }),
      res,
      "/clutch/v1/activity-tokens",
      TOKEN,
      relay,
    )).toBe(true);

    expect(state.status).toBe(400);
    expect(state.body).not.toContain("not-hex");
    expect(store.list()).toHaveLength(0);
  });

  it("leaves another route alone", async () => {
    const store = new ActivityTokenStore(join(home(), "activity-tokens.json"));
    const relay = new ActivityPushRelay({ store, enabled: false, snapshot: () => ({ approvals: [], runs: [] }) });
    const { res, state } = fakeResponse();

    expect(await handleActivityTokensRequest(
      fakeRequest("GET", CREDENTIAL),
      res,
      "/clutch/v1/health",
      TOKEN,
      relay,
    )).toBe(false);
    expect(state.status).toBe(0);
  });
});

describe("the push relay delivery guarantees", () => {
  const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

  it("drops the waiting push when the work returns to a state the phone has", async () => {
    // A is delivered, B is coalesced into a timer, and the work settles
    // back to A before the timer fires.  Without the cancel, the island
    // would walk back to B — a state that stopped being true.
    const store = new ActivityTokenStore(join(home(), "activity-tokens.json"));
    store.put(registration());
    const sent: unknown[] = [];
    let approvals: ActivityThreadApproval[] = [];
    const relay = new ActivityPushRelay({
      store,
      enabled: true,
      sender: {
        sendLiveActivity: async (request) => {
          sent.push(request.payload);
          return { status: 200 };
        },
      },
      snapshot: () => ({ approvals, runs: [] }),
      now: () => 1_700_000_000_000,
      minIntervalMs: 20,
    });

    await relay.notify();
    await relay.settled();
    expect(sent).toHaveLength(1);

    approvals = [{ hostId: "local", sessionId: "s1", requestId: "r1", title: "Needs Me" }];
    await relay.notify(); // waits on the interval
    approvals = [];
    await relay.notify(); // back to the delivered state: the wait is off
    await sleep(60);
    await relay.settled();
    expect(sent).toHaveLength(1);
  });

  it("retries a transiently failing push until it lands", async () => {
    const store = new ActivityTokenStore(join(home(), "activity-tokens.json"));
    store.put(registration());
    const statuses = [503, 200];
    let attempts = 0;
    let approvals: ActivityThreadApproval[] = [{ hostId: "local", sessionId: "s1", requestId: "r1", title: "Needs Me" }];
    const relay = new ActivityPushRelay({
      store,
      enabled: true,
      sender: {
        sendLiveActivity: async () => ({ status: statuses[Math.min(attempts++, statuses.length - 1)]! }),
      },
      snapshot: () => ({ approvals, runs: [] }),
      now: () => 1_700_000_000_000,
      minIntervalMs: 0,
      retryBaseMs: 5,
    });

    await relay.notify();
    await sleep(60);
    await relay.settled();
    expect(attempts).toBe(2);

    // The retry landed, so the state is remembered and no third push rides.
    await relay.notify();
    await relay.settled();
    expect(attempts).toBe(2);
    void approvals;
  });

  it("spends a capped number of retries before waiting for the next change", async () => {
    const store = new ActivityTokenStore(join(home(), "activity-tokens.json"));
    store.put(registration());
    let attempts = 0;
    const relay = new ActivityPushRelay({
      store,
      enabled: true,
      sender: {
        sendLiveActivity: async () => {
          attempts += 1;
          return { status: 429 };
        },
      },
      snapshot: () => ({ approvals: [{ hostId: "local", sessionId: "s1", requestId: "r1", title: "Needs Me" }] as ActivityThreadApproval[], runs: [] }),
      now: () => 1_700_000_000_000,
      minIntervalMs: 0,
      retryBaseMs: 5,
      retryLimit: 2,
    });

    await relay.notify();
    await sleep(80);
    await relay.settled();
    // The first push and two retries; the throttle is not a broken pipe.
    expect(attempts).toBe(3);

    // With the budget spent, only a state change tries again.
    await relay.notify();
    await relay.settled();
    expect(attempts).toBe(3);
  });

  it("does not retry a push Apple rejected for good", async () => {
    const store = new ActivityTokenStore(join(home(), "activity-tokens.json"));
    store.put(registration());
    let attempts = 0;
    const relay = new ActivityPushRelay({
      store,
      enabled: true,
      sender: {
        sendLiveActivity: async () => {
          attempts += 1;
          return { status: 410, reason: "Unregistered" };
        },
      },
      snapshot: () => ({ approvals: [{ hostId: "local", sessionId: "s1", requestId: "r1", title: "Needs Me" }] as ActivityThreadApproval[], runs: [] }),
      now: () => 1_700_000_000_000,
      minIntervalMs: 0,
      retryBaseMs: 5,
    });

    await relay.notify();
    await sleep(60);
    await relay.settled();
    expect(attempts).toBe(1);
  });
});
