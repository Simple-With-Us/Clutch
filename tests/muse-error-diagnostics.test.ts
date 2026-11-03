import { describe, expect, it } from "vitest";

import { attachMuseErrorDiagnostics, museErrorDiagnostics } from "../src/web/muse-error-diagnostics.ts";

describe("Muse error diagnostics", () => {
  it("keeps a safe original category after the display error is sanitized", () => {
    const displayed = new Error("Muse request failed (ACP code -32603).");
    attachMuseErrorDiagnostics(displayed, { code: -32603, message: "Provider timed out with token=private-value" });
    expect(museErrorDiagnostics(displayed)).toEqual({ code: -32603, category: "timeout" });
    expect(JSON.stringify(displayed)).not.toContain("private-value");
    expect(JSON.stringify(museErrorDiagnostics(displayed))).not.toContain("private-value");
  });

  it("returns only a numeric code and an allowlisted category", () => {
    const input = {
      code: -32001,
      message: "Not authenticated for prompt: reveal-me; token=secret-value",
      sessionId: "private-session-id",
      data: { providerBody: "private provider response" },
    };

    const result = museErrorDiagnostics(input);

    expect(result).toEqual({ code: -32001, category: "auth" });
    expect(JSON.stringify(result)).not.toContain("reveal-me");
    expect(JSON.stringify(result)).not.toContain("secret-value");
    expect(JSON.stringify(result)).not.toContain("private-session-id");
    expect(JSON.stringify(result)).not.toContain("private provider response");
  });

  it("keeps an unrecognized ACP internal error generic while preserving its safe code", () => {
    expect(museErrorDiagnostics({
      code: -32603,
      message: "provider failed for session private-session-id: token=secret-value",
    })).toEqual({ code: -32603, category: "internal" });
  });

  it("classifies known session, timeout, process, and rate-limit signals", () => {
    expect(museErrorDiagnostics(new Error("This session is already in use"))).toEqual({ code: null, category: "session-in-use" });
    expect(museErrorDiagnostics(Object.assign(new Error("request failed"), { code: "ETIMEDOUT" }))).toEqual({ code: null, category: "timeout" });
    expect(museErrorDiagnostics(Object.assign(new Error("bridge exited"), { name: "BridgeProcessError" }))).toEqual({ code: null, category: "process" });
    expect(museErrorDiagnostics(new Error("Too many requests; rate limit exceeded"))).toEqual({ code: null, category: "rate-limit" });
  });

  it("rejects unsafe codes and handles non-error inputs without leaking them", () => {
    expect(museErrorDiagnostics({ code: 1.5, message: "token=secret-value" })).toEqual({ code: null, category: "internal" });
    expect(museErrorDiagnostics("prompt and token=secret-value")).toEqual({ code: null, category: "internal" });
  });
});
