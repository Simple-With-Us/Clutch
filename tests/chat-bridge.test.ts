import { mkdtempSync, readFileSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

import { clutchChatPort, clutchWebPort } from "../src/shared/ports.ts";
import { isTrustedHostHeader, pairingLink, trustedAuthoritySet } from "../src/web/pair-link.ts";
import { loadOrMintToken, parseLimitParam, parseThreadQuery, routeForModel, sliceThreadHistory, sortSessionsByUpdated } from "../src/web/chat-bridge.ts";
import { miniMaxCodeRemoteHtml } from "../src/web/minimax-code-remote.ts";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");

describe("chat-bridge ports", () => {
  it("sits one above web and honors CLUTCH_CHAT_PORT", () => {
    expect(clutchWebPort({})).toBe("3180");
    expect(clutchChatPort({})).toBe("3181");
    expect(clutchChatPort({ CLUTCH_CHAT_PORT: "  3911 " })).toBe("3911");
  });
});

describe("routeForModel", () => {
  it("sends MiniMax models to the minimax bridge and everything else to deepseek", () => {
    expect(routeForModel("MiniMax-M3", undefined)).toBe("minimax");
    expect(routeForModel("minimax-m2.7-highspeed", undefined)).toBe("minimax");
    expect(routeForModel("DeepSeek-V4.1-Pro", undefined)).toBe("deepseek");
    expect(routeForModel(undefined, undefined)).toBe("deepseek");
    expect(routeForModel("DeepSeek-V4.1-Pro", "minimax")).toBe("minimax");
    expect(routeForModel(undefined, "mcode")).toBe("mcode");
  });
});

describe("chat-bridge host trust", () => {
  const allowed = trustedAuthoritySet(["mac.ts.net", null, ""], "3181");

  it("trusts loopback, the tailnet name, and their ported forms", () => {
    for (const h of ["127.0.0.1", "127.0.0.1:3181", "localhost", "LOCALHOST:3181", "mac.ts.net", "mac.ts.net:3181"]) {
      expect(isTrustedHostHeader(h, allowed)).toBe(true);
    }
  });

  it("rejects anything else, including missing and wrong-port hosts", () => {
    for (const h of [null, undefined, "", "evil.ts.net", "mac.ts.net:3180", "127.0.0.1:3180"]) {
      expect(isTrustedHostHeader(h, allowed)).toBe(false);
    }
  });
});

describe("chat-bridge token file", () => {
  it("mints a long token once and keeps it owner-only", () => {
    const dir = mkdtempSync(join(tmpdir(), "chat-bridge-token-"));
    const file = join(dir, "chat-token");
    const first = loadOrMintToken(file);
    expect(first.length).toBeGreaterThanOrEqual(32);
    expect(loadOrMintToken(file)).toBe(first);
    expect(statSync(file).mode & 0o777).toBe(0o600);
  });
});

describe("pairing link carries the chat token", () => {
  const launch = "http://127.0.0.1:3180/?token=abc-123_XYZ";

  it("adds &chat= when the bridge has minted one, omits it otherwise", () => {
    const withChat = new URL(pairingLink({ launchUrl: launch, origin: "https://mac.ts.net:3180", chatToken: "sekrit" }));
    expect(withChat.searchParams.get("chat")).toBe("sekrit");
    const without = new URL(pairingLink({ launchUrl: launch, origin: "https://mac.ts.net:3180" }));
    expect(without.searchParams.has("chat")).toBe(false);
  });
});

describe("chat-bridge launch wiring", () => {
  it("both web launchers start the sidecar before exec, unless disabled", () => {
    const sh = readFileSync(join(ROOT, "scripts", "start-web.sh"), "utf8");
    expect(sh).toContain("scripts/chat-bridge.sh");
    expect(sh).toContain("CLUTCH_CHAT_BRIDGE");
    const ts = readFileSync(join(ROOT, "src", "web", "start-web.ts"), "utf8");
    expect(ts).toContain("scripts\", \"chat-bridge.sh");
    expect(ts).toContain("CLUTCH_CHAT_BRIDGE");
  });

  it("the launcher maps the chat port on Tailscale and execs the sidecar over tsx", () => {
    const sh = readFileSync(join(ROOT, "scripts", "chat-bridge.sh"), "utf8");
    expect(sh).toContain("CLUTCH_CHAT_PORT");
    expect(sh).toContain("tailscale serve");
    expect(sh).toContain("src/web/chat-bridge.ts");
  });

  it("launches MiniMax Code directly over ACP instead of the DSH MiniMax bridge", () => {
    const source = readFileSync(join(ROOT, "src", "web", "chat-bridge.ts"), "utf8");
    expect(source).toContain('join(homedir(), ".minimax-code", "bin", "mcode")');
    expect(source).toContain('args: ["acp"]');
    expect(source).toContain("CLUTCH_MCODE_CLI");
  });
});

describe("MiniMax Code remote shell", () => {
  it("emits syntactically valid browser JavaScript", () => {
    const script = /<script>([\s\S]*)<\/script>/.exec(miniMaxCodeRemoteHtml())?.[1];
    expect(script).toBeDefined();
    expect(() => new Function(script ?? "")).not.toThrow();
  });
});

describe("parseThreadQuery", () => {
  const query = (raw: string) => parseThreadQuery(new URL(raw, "http://127.0.0.1:3181").searchParams);

  it("takes the device uid with a bounded limit", () => {
    expect(query("/clutch/v1/thread?uid=clutch-mac-abcdef12")).toEqual({ uid: "clutch-mac-abcdef12", limit: 50 });
    expect(query("/clutch/v1/thread?uid=clutch-mac-abcdef12&limit=10")).toEqual({ uid: "clutch-mac-abcdef12", limit: 10 });
    expect(query("/clutch/v1/thread?uid=clutch-mac-abcdef12&limit=9999")).toEqual({ uid: "clutch-mac-abcdef12", limit: 100 });
    expect(query("/clutch/v1/thread?uid=clutch-mac-abcdef12&limit=bogus")).toEqual({ uid: "clutch-mac-abcdef12", limit: 50 });
  });

  it("rejects missing and path-shaped uids", () => {
    expect(query("/clutch/v1/thread")).toEqual({ error: "uid is required" });
    expect(query("/clutch/v1/thread?uid=")).toEqual({ error: "uid is required" });
    expect(query("/clutch/v1/thread?uid=../../etc")).toEqual({ error: "uid is required" });
  });
});

describe("thread endpoint wiring", () => {
  it("registers the gated thread route beside chat-config", () => {
    const source = readFileSync(join(ROOT, "src", "web", "chat-bridge.ts"), "utf8");
    expect(source).toContain('"/clutch/v1/thread"');
    expect(source).toContain("parseThreadQuery");
    expect(source).toContain("fetchThread");
  });
});

describe("parseLimitParam", () => {
  it("bounds integers and falls back on garbage", () => {
    expect(parseLimitParam("10", 50, 100)).toBe(10);
    expect(parseLimitParam(null, 50, 100)).toBe(50);
    expect(parseLimitParam("", 50, 100)).toBe(50);
    expect(parseLimitParam("bogus", 50, 100)).toBe(50);
    expect(parseLimitParam("0", 50, 100)).toBe(1);
    expect(parseLimitParam("9999", 50, 100)).toBe(100);
  });
});

describe("sortSessionsByUpdated", () => {
  it("orders newest first with undated entries last", () => {
    const rows = [
      { sessionId: "a", updatedAt: "2026-10-14T01:00:00Z" },
      { sessionId: "b" },
      { sessionId: "c", updatedAt: "2026-10-14T03:00:00Z" },
    ];
    expect(sortSessionsByUpdated(rows).map((r) => r.sessionId)).toEqual(["c", "a", "b"]);
  });
});

describe("sliceThreadHistory", () => {
  it("keeps the tail when over budget", () => {
    expect(sliceThreadHistory([1, 2, 3, 4], 2)).toEqual([3, 4]);
    expect(sliceThreadHistory([1, 2], 5)).toEqual([1, 2]);
  });
});
