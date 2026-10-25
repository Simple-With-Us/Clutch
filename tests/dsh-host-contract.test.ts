import { describe, it, expect } from "vitest";

import {
  DSH_HOST_API_PATH,
  DSH_HOST_ENDPOINT_NAMESPACES,
  DSH_HOST_EVENT_RESULT_ENDPOINT,
  DSH_HOST_EVENT_STREAM_ENDPOINT,
  DSH_HOST_MUX_PATH,
  DshHostContractError,
  buildDshHostRequest,
  dshHostApiURL,
  dshHostAuthority,
  dshHostEndpointNamespace,
  dshHostMuxURL,
  isKnownDshHostEndpoint,
  parseDshHostServerResponse,
} from "../src/shared/dshHostContract";

// =============================================================================
// dsh-host-contract — the wire contract Clutch's native clients speak.
//
// A native iOS or macOS client is a second client of the dsh host that
// `scripts/start-web.sh` already runs.  These tests pin the parts of that
// contract the Swift client in ios/App/Services/DshHostClient.swift mirrors,
// so a change on either side fails here instead of failing silently on a
// phone.
//
// The values here were read from the upstream source at the tag Clutch pins,
// dsh-v0.1.5-rc.3 (MIT), and are identical at upstream HEAD.
// =============================================================================

describe("dsh host contract — paths", () => {
  it("uses the /api prefix upstream registers", () => {
    expect(DSH_HOST_API_PATH).toBe("/api");
  });

  it("uses the mux route upstream declares", () => {
    expect(DSH_HOST_MUX_PATH).toBe("/api/remote.mux");
  });

  it("uses the upstream logical stream endpoints", () => {
    expect(DSH_HOST_EVENT_STREAM_ENDPOINT).toBe("$events");
    expect(DSH_HOST_EVENT_RESULT_ENDPOINT).toBe("$events/result");
  });

  it("builds a ws mux URL from a loopback origin", () => {
    expect(dshHostMuxURL("http://127.0.0.1:3180")).toBe("ws://127.0.0.1:3180/api/remote.mux");
  });

  it("builds a wss mux URL from an https origin", () => {
    expect(dshHostMuxURL("https://jay-macbook.boa-roygbiv.ts.net:3180")).toBe(
      "wss://jay-macbook.boa-roygbiv.ts.net:3180/api/remote.mux",
    );
  });

  it("tolerates an origin with a trailing slash", () => {
    expect(dshHostMuxURL("http://127.0.0.1:3180/")).toBe("ws://127.0.0.1:3180/api/remote.mux");
  });

  it("builds the API URL from a base origin", () => {
    expect(dshHostApiURL("http://127.0.0.1:3180")).toBe("http://127.0.0.1:3180/api");
  });

  it("derives the authority the host's fence binds on", () => {
    expect(dshHostAuthority("http://127.0.0.1:3180")).toBe("127.0.0.1:3180");
    expect(dshHostAuthority("https://jay-macbook.boa-roygbiv.ts.net")).toBe(
      "jay-macbook.boa-roygbiv.ts.net",
    );
  });
});

describe("dsh host contract — request envelope", () => {
  it("builds a client-request envelope", () => {
    const request = buildDshHostRequest("rpc-1", "remote.session", { args: { limit: 10 } });
    expect(request).toEqual({
      type: "client-request",
      rpcId: "rpc-1",
      method: "remote.session",
      payload: { args: { limit: 10 } },
    });
  });

  it("defaults the payload to an empty argument object", () => {
    expect(buildDshHostRequest("rpc-2", "remote.commands").payload).toEqual({ args: {} });
  });
});

describe("dsh host contract — response envelope", () => {
  it("parses a successful response", () => {
    const parsed = parseDshHostServerResponse({
      type: "server-response",
      rpcId: "rpc-1",
      result: { ok: true, value: { sessions: [] } },
    });
    expect(parsed.rpcId).toBe("rpc-1");
    expect(parsed.result.ok).toBe(true);
    if (parsed.result.ok) expect(parsed.result.value).toEqual({ sessions: [] });
  });

  it("parses a failed response with its error", () => {
    const parsed = parseDshHostServerResponse({
      type: "server-response",
      rpcId: "rpc-3",
      result: {
        ok: false,
        error: { code: "gateway/bad-request", message: "nope", details: { field: "limit" } },
      },
    });
    expect(parsed.result.ok).toBe(false);
    if (!parsed.result.ok) {
      expect(parsed.result.error.code).toBe("gateway/bad-request");
      expect(parsed.result.error.message).toBe("nope");
      expect(parsed.result.error.details).toEqual({ field: "limit" });
    }
  });

  it("rejects a non-object", () => {
    expect(() => parseDshHostServerResponse("nope")).toThrow(DshHostContractError);
  });

  it("rejects an unknown envelope type", () => {
    expect(() => parseDshHostServerResponse({ type: "server-push", rpcId: "x" })).toThrow(
      DshHostContractError,
    );
  });

  it("rejects a response with no rpcId", () => {
    expect(() => parseDshHostServerResponse({ type: "server-response", result: { ok: true } })).toThrow(
      DshHostContractError,
    );
  });

  it("rejects a response with no result", () => {
    expect(() => parseDshHostServerResponse({ type: "server-response", rpcId: "x" })).toThrow(
      DshHostContractError,
    );
  });

  it("rejects a result that is neither ok nor failed", () => {
    expect(() =>
      parseDshHostServerResponse({ type: "server-response", rpcId: "x", result: { ok: "maybe" } }),
    ).toThrow(DshHostContractError);
  });

  it("rejects a failed response with no error object", () => {
    expect(() =>
      parseDshHostServerResponse({ type: "server-response", rpcId: "x", result: { ok: false } }),
    ).toThrow(DshHostContractError);
  });

  it("normalizes a missing error code and message rather than throwing", () => {
    const parsed = parseDshHostServerResponse({
      type: "server-response",
      rpcId: "x",
      result: { ok: false, error: {} },
    });
    if (!parsed.result.ok) {
      expect(parsed.result.error.code).toBe("unknown");
      expect(parsed.result.error.message).toBe("");
      expect(parsed.result.error.details).toEqual({});
    }
  });
});

describe("dsh host contract — endpoint names", () => {
  it("joins a namespace to its method with a slash", () => {
    expect(dshHostEndpointNamespace("session/list")).toBe("session");
    expect(dshHostEndpointNamespace("session")).toBeNull();
  });

  it("accepts the endpoints the installed build dispatches", () => {
    expect(isKnownDshHostEndpoint("session/list")).toBe(true);
    expect(isKnownDshHostEndpoint("commands/execute")).toBe(true);
    expect(isKnownDshHostEndpoint("workspaceFiles/list")).toBe(true);
    expect(isKnownDshHostEndpoint("credentials/describe")).toBe(true);
  });

  it("rejects a Context service key as a wire endpoint", () => {
    expect(isKnownDshHostEndpoint("remote.session")).toBe(false);
  });

  it("rejects the namespaces the host does not declare", () => {
    expect(isKnownDshHostEndpoint("terminal/read")).toBe(false);
    expect(isKnownDshHostEndpoint("job/list")).toBe(false);
    expect(isKnownDshHostEndpoint("remotes/list")).toBe(false);
  });

  it("rejects a malformed name even when the namespace is known", () => {
    expect(isKnownDshHostEndpoint("session/../secret")).toBe(false);
    expect(isKnownDshHostEndpoint("/list")).toBe(false);
  });

  it("declares every namespace exactly once", () => {
    expect(new Set(DSH_HOST_ENDPOINT_NAMESPACES).size).toBe(DSH_HOST_ENDPOINT_NAMESPACES.length);
  });
});
