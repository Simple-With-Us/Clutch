import { mkdirSync, mkdtempSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

import { clutchChatPort, clutchWebPort } from "../src/shared/ports.ts";
import { isTrustedHostHeader, pairingLink, serverPairingLink, trustedAuthoritySet } from "../src/web/pair-link.ts";
import { compactToolHistory, loadOrMintToken, materializeAttachment, mcodeAvailable, museInstalled, normalizeSessionUpdate, parseLimitParam, parsePromptImages, parseThreadQuery, readTailnetStatus, resolveTailnetHost, routeForModel, safeAttachmentName, sliceThreadHistory, sortSessionsByUpdated, toolStatusOf } from "../src/web/chat-bridge.ts";
import { parseAcpMessage, readMuseProviderCatalog } from "../src/web/engine-catalog.ts";
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

  it("routes Muse models to the Muse engine when no engine is named", () => {
    expect(routeForModel("muse-wonder-1.0", undefined)).toBe("muse");
    expect(routeForModel("muse-spark-1.3", undefined)).toBe("muse");
    expect(routeForModel(undefined, "muse")).toBe("muse");
  });
});

describe("museInstalled", () => {
  it("needs both the Muse host and the ACP adapter", () => {
    const none = { hosts: [] as string[], adapters: [] as string[] };
    // `process.execPath` stands in for "a path that really exists".  It is
    // always present, on every platform; `/bin/true` is not, because macOS
    // keeps `true` in `/usr/bin` and has no `/bin/true` at all.  On a Mac the
    // old fixture read as a missing file, so the override looked stale and
    // this test failed on every run while CI, on Linux, passed.
    const present = process.execPath;
    expect(museInstalled({ MUSE_CODE_EXECUTABLE: present, MUSE_CODE_ACP_BIN: present }, none)).toBe(true);
    expect(museInstalled({ MUSE_CODE_EXECUTABLE: present, MUSE_CODE_ACP_BIN: "" }, none)).toBe(false);
    expect(museInstalled({ MUSE_CODE_EXECUTABLE: "", MUSE_CODE_ACP_BIN: present }, none)).toBe(false);
    // A stale override path must not count as installed.
    expect(museInstalled({ MUSE_CODE_EXECUTABLE: "/nope/muse", MUSE_CODE_ACP_BIN: "/nope/adapter" }, none)).toBe(false);
  });
});

describe("Muse engine wiring", () => {
  const source = readFileSync(join(ROOT, "src", "web", "chat-bridge.ts"), "utf8");

  it("runs Muse Code through the shipped adapter launcher", () => {
    expect(source).toContain('join(ROOT, "scripts", "muse-code-acp.sh")');
    expect(source).toContain("CLUTCH_CHAT_LAUNCHER_MUSE");
  });

  it("sends ACP content blocks to Muse, which rejects a bare string", () => {
    expect(source).toContain('this.engine === "mcode" || this.engine === "muse"');
  });

  it("publishes the engine catalog the native model picker reads", () => {
    expect(source).toContain('"/clutch/v1/engines"');
    expect(source).toContain("engineCatalog(");
  });

  it("applies the model and the effort as ACP config options", () => {
    expect(source).toContain("session/set_config_option");
    expect(source).toContain("applySessionChoices");
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

describe("resolveTailnetHost", () => {
  const status = { Self: { DNSName: "jay-server.boa-roygbiv.ts.net." } };

  it("prefers an explicit override over tailscale status", () => {
    expect(resolveTailnetHost(" Mac.TS.net ", status)).toBe("mac.ts.net");
    expect(resolveTailnetHost("mac.ts.net", null)).toBe("mac.ts.net");
  });

  it("reads the MagicDNS name from tailscale status otherwise", () => {
    expect(resolveTailnetHost(null, status)).toBe("jay-server.boa-roygbiv.ts.net");
    expect(resolveTailnetHost("", status)).toBe("jay-server.boa-roygbiv.ts.net");
    expect(resolveTailnetHost(null, null)).toBe(null);
    expect(resolveTailnetHost(null, { Self: {} })).toBe(null);
  });
});

describe("readTailnetStatus", () => {
  const fakeTailscale = (body: string): string => {
    const dir = mkdtempSync(join(tmpdir(), "fake-tailscale-"));
    const path = join(dir, "tailscale");
    writeFileSync(path, `#!/bin/sh\n${body}\n`, { mode: 0o755 });
    return path;
  };

  it("parses the status JSON the CLI prints", async () => {
    const cli = fakeTailscale(`echo '{"Self":{"DNSName":"box.ts.net."}}'`);
    await expect(readTailnetStatus(5000, cli)).resolves.toEqual({ Self: { DNSName: "box.ts.net." } });
  });

  it("gives up on a CLI that never exits instead of holding startup", async () => {
    // A wedged tailscaled can leave `tailscale status` waiting forever, and
    // detection runs before the sidecar listens.
    const cli = fakeTailscale("exec sleep 30");
    const started = Date.now();
    await expect(readTailnetStatus(200, cli)).resolves.toBeNull();
    expect(Date.now() - started).toBeLessThan(5000);
  });

  it("treats a missing CLI as no tailnet", async () => {
    await expect(readTailnetStatus(5000, join(tmpdir(), "no-such-tailscale-cli"))).resolves.toBeNull();
  });
});

describe("chat-bridge server-host wiring", () => {
  const source = readFileSync(join(ROOT, "src", "web", "chat-bridge.ts"), "utf8");

  it("detects the tailnet host instead of trusting loopback only", () => {
    expect(source).toContain("detectTailnetHost");
    expect(source).toContain("tailscale");
  });

  it("registers the explicit cancel route the native Stop buttons call", () => {
    expect(source).toContain('"/clutch/v1/chat/cancel"');
  });

  it("reports MiniMax Code availability on the health route", () => {
    expect(source).toContain("mcodeAvailable");
    expect(mcodeAvailable({ command: "/definitely/not/here/mcode", args: ["acp"] })).toBe(false);
    expect(mcodeAvailable({ command: "mcode", args: ["acp"] })).toBe(true);
  });
});

describe("server pairing link", () => {
  it("pairs a MiniMax Code server host with no launch token", () => {
    const link = new URL(serverPairingLink({ host: "jay-server.boa-roygbiv.ts.net", name: "jay-server", chatToken: "sekrit", chatPort: "3181" }));
    expect(link.protocol).toBe("clutch:");
    expect(link.searchParams.get("h")).toBe("jay-server.boa-roygbiv.ts.net");
    expect(link.searchParams.get("tls")).toBe("1");
    expect(link.searchParams.get("kind")).toBe("mcode");
    expect(link.searchParams.get("chat")).toBe("sekrit");
    expect(link.searchParams.get("chatPort")).toBe("3181");
    expect(link.searchParams.get("name")).toBe("jay-server");
    expect(link.searchParams.has("url")).toBe(false);
  });

  it("rejects a missing host or token instead of minting a dead link", () => {
    expect(() => serverPairingLink({ host: " ", chatToken: "x" })).toThrow();
    expect(() => serverPairingLink({ host: "jay-server.boa-roygbiv.ts.net", chatToken: "" })).toThrow();
  });
});

describe("server bridge install assets", () => {
  it("ships a systemd unit and installer for the Linux server host", () => {
    const unit = readFileSync(join(ROOT, "scripts", "systemd", "clutch-chat-bridge.service"), "utf8");
    expect(unit).toContain("scripts/chat-bridge.sh");
    expect(unit).toContain("Restart=on-failure");
    const installer = readFileSync(join(ROOT, "scripts", "install-server-bridge.sh"), "utf8");
    expect(installer).toContain("systemctl enable --now clutch-chat-bridge");
    expect(installer).toContain("--server");
  });

  it("pair-ios knows the --server mode", () => {
    const source = readFileSync(join(ROOT, "src", "web", "pair-ios.ts"), "utf8");
    expect(source).toContain('"--server"');
    expect(source).toContain("serverPairingLink");
    expect(source).toContain("server-pairing-link.txt");
  });
});

describe("normalizeSessionUpdate", () => {
  it("passes text chunks through unchanged", () => {
    expect(normalizeSessionUpdate({ sessionId: "s1", update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "hi" } } }))
      .toEqual({ sessionId: "s1", kind: "agent_message_chunk", text: "hi" });
  });

  it("forwards tool calls with title and mapped status instead of dropping them", () => {
    expect(normalizeSessionUpdate({ sessionId: "s1", update: { sessionUpdate: "tool_call", toolCallId: "t1", title: "Read file", status: "in_progress" } }))
      .toEqual({ sessionId: "s1", kind: "tool_call", text: "Read file", toolCallId: "t1", toolStatus: "running" });
    expect(normalizeSessionUpdate({ sessionId: "s1", update: { sessionUpdate: "tool_call_update", toolCallId: "t1", status: "completed", content: [{ type: "content", content: { type: "text", text: "done" } }] } }))
      .toEqual({ sessionId: "s1", kind: "tool_call_update", text: "done", toolCallId: "t1", toolStatus: "completed" });
  });

  it("keeps the engine's plan, with its entries and their states", () => {
    expect(normalizeSessionUpdate({
      sessionId: "s1",
      update: {
        sessionUpdate: "plan",
        entries: [
          { content: "Read the failing test", priority: "high", status: "in_progress" },
          { content: "Fix it", priority: "medium", status: "pending" },
        ],
      },
    })).toEqual({
      sessionId: "s1",
      kind: "plan",
      text: "",
      plan: [
        { content: "Read the failing test", priority: "high", status: "in_progress" },
        { content: "Fix it", priority: "medium", status: "pending" },
      ],
    });
  });

  it("reads a plan update that nests its entries under the content", () => {
    expect(normalizeSessionUpdate({
      sessionId: "s1",
      update: {
        sessionUpdate: "plan_update",
        content: { type: "items", planId: "p1", entries: [{ content: "Ship it", status: "completed" }] },
      },
    })).toEqual({
      sessionId: "s1",
      kind: "plan",
      text: "",
      plan: [{ content: "Ship it", priority: "medium", status: "completed" }],
    });
  });

  it("drops a plan whose shape it cannot read, rather than emptying it", () => {
    // An empty list tells the client to remove the plan, so a shape the
    // sidecar does not understand must not become one.
    expect(normalizeSessionUpdate({
      sessionId: "s1",
      update: { sessionUpdate: "plan_update", content: { type: "text", text: "working on it" } },
    })).toBe(null);
  });

  it("reads a removed plan as an empty list", () => {
    expect(normalizeSessionUpdate({
      sessionId: "s1",
      update: { sessionUpdate: "plan_removed" },
    })).toEqual({ sessionId: "s1", kind: "plan", text: "", plan: [] });
  });

  it("drops updates the clients do not render", () => {
    expect(normalizeSessionUpdate({ sessionId: "s1", update: { sessionUpdate: "current_mode_update", currentModeId: "code" } })).toBe(null);
    expect(normalizeSessionUpdate({ update: { sessionUpdate: "agent_message_chunk", content: { text: "x" } } })).toBe(null);
    expect(normalizeSessionUpdate(null)).toBe(null);
  });

  it("maps ACP statuses onto the three client states", () => {
    expect(toolStatusOf("completed")).toBe("completed");
    expect(toolStatusOf("failed")).toBe("failed");
    expect(toolStatusOf("pending")).toBe("running");
    expect(toolStatusOf(undefined)).toBe("running");
  });

  it("wires the SSE tool event beside message and thought", () => {
    const source = readFileSync(join(ROOT, "src", "web", "chat-bridge.ts"), "utf8");
    expect(source).toContain('sseSend(res, "tool"');
    expect(source).toContain("normalizeSessionUpdate");
  });

  it("compacts replayed tool updates into one entry per call", () => {
    const history = [
      { sessionId: "s", kind: "agent_message_chunk" as const, text: "working" },
      { sessionId: "s", kind: "tool_call" as const, text: "write", toolCallId: "t1", toolStatus: "running" as const },
      { sessionId: "s", kind: "tool_call_update" as const, text: "", toolCallId: "t1", toolStatus: "completed" as const },
      { sessionId: "s", kind: "agent_message_chunk" as const, text: "done" },
    ];
    const compacted = compactToolHistory(history);
    expect(compacted).toHaveLength(3);
    expect(compacted[1]).toMatchObject({ text: "write", toolStatus: "completed" });
  });
});

describe("attachments on the dsh bridges", () => {
  it("writes the image bytes where the agent can open them", async () => {
    const root = mkdtempSync(join(tmpdir(), "clutch-attachments-"));
    const file = await materializeAttachment({
      root,
      sessionId: "session-1",
      image: { mimeType: "image/png", data: Buffer.from("hello").toString("base64"), name: "shot.png" },
      index: 0,
    });
    expect(file).not.toBe(null);
    expect(readFileSync(file as string, "utf8")).toBe("hello");
    // The attachment lands under the attachment root, not in the working
    // directory the caller happens to be in.
    expect((file as string).startsWith(root)).toBe(true);
    expect((file as string).endsWith("shot.png")).toBe(true);
  });

  it("keeps a traversal name inside the attachment directory", async () => {
    const root = mkdtempSync(join(tmpdir(), "clutch-attachments-"));
    const file = await materializeAttachment({
      root,
      sessionId: "session-1",
      image: { mimeType: "image/png", data: Buffer.from("x").toString("base64"), name: "../../.ssh/authorized_keys" },
      index: 0,
    });
    expect(file).not.toBe(null);
    expect((file as string).startsWith(root)).toBe(true);
    expect((file as string).includes("..")).toBe(false);
    expect(basename(file as string)).toBe("authorized_keys");
  });

  it("names an unnamed attachment rather than writing nothing", () => {
    expect(safeAttachmentName(undefined, 0)).toBe("attachment-1");
    expect(safeAttachmentName("", 2)).toBe("attachment-3");
    expect(safeAttachmentName("..", 0)).toBe("attachment-1");
    expect(safeAttachmentName("a/b/c.png", 0)).toBe("c.png");
  });
});

describe("parseAcpMessage", () => {
  it("keeps only the fields it understands", () => {
    const message = parseAcpMessage(JSON.stringify({ jsonrpc: "2.0", id: 2, method: "x", result: { sessionId: "s" } }));
    expect(message).toEqual({ id: 2, method: "x", result: { sessionId: "s" } });
  });

  it("drops a malformed message instead of believing it", () => {
    expect(parseAcpMessage("not json")).toBe(null);
    expect(parseAcpMessage("[]")).toBe(null);
    expect(parseAcpMessage(JSON.stringify({ id: "2" }))).toEqual({});
    expect(parseAcpMessage(JSON.stringify({ id: 2, result: "text" }))).toEqual({ id: 2 });
  });
});

describe("Muse model wire values", () => {
  it("offers the provider-qualified form as a fallback for a provider-catalog model", () => {
    const dir = mkdtempSync(join(tmpdir(), "muse-catalog-"));
    writeFileSync(join(dir, "catalog.json"), JSON.stringify({
      provider_id: "meta",
      profile_id: "tbh",
      rows: [
        { model_id: "muse-wonder-1.0", display_label: "muse-wonder-1.0", provider_id: "meta", profile_id: "tbh", visibility: "visible", context_limit: 1007997 },
        { model_id: "muse-hidden-1.0", display_label: "hidden", provider_id: "meta", profile_id: "tbh", visibility: "hidden" },
      ],
    }));
    const home = mkdtempSync(join(tmpdir(), "muse-home-"));
    mkdirSync(join(home, ".local", "share", "muse", "model-catalog"), { recursive: true });
    writeFileSync(join(home, ".local", "share", "muse", "model-catalog", "c.json"), readFileSync(join(dir, "catalog.json")));
    const models = readMuseProviderCatalog(home);
    expect(models.map((model) => model.id)).toEqual(["muse-wonder-1.0"]);
    expect(models[0].value).toBe("muse-wonder-1.0");
    expect(models[0].altValue).toBe('muse-model:["meta","tbh","muse-wonder-1.0"]');
    expect(models[0].contextWindow).toBe(1007997);
  });
});

describe("parsePromptImages", () => {
  const png = "iVBORw0KGgo=";

  it("keeps the images the engines accept", () => {
    const images = parsePromptImages([
      { mimeType: "image/png", data: png, name: "shot.png" },
      { mimeType: "IMAGE/JPEG", data: png },
    ]);
    expect(images).toHaveLength(2);
    expect(images[0]).toEqual({ mimeType: "image/png", data: png, name: "shot.png" });
    expect(images[1].mimeType).toBe("image/jpeg");
  });

  it("drops unsupported types, empty data, and oversized attachments", () => {
    expect(parsePromptImages([{ mimeType: "image/tiff", data: png }])).toEqual([]);
    expect(parsePromptImages([{ mimeType: "image/png", data: "" }])).toEqual([]);
    const big = "A".repeat(9 * 1024 * 1024);
    expect(parsePromptImages([{ mimeType: "image/png", data: big }])).toEqual([]);
  });

  it("ignores anything that is not a list of images", () => {
    expect(parsePromptImages(undefined)).toEqual([]);
    expect(parsePromptImages("nope")).toEqual([]);
    expect(parsePromptImages([null, 42])).toEqual([]);
    // An array element is boundary data too: an array or a nested object
    // is not an image.
    expect(parsePromptImages([["image/png", png]])).toEqual([]);
    expect(parsePromptImages([{ mimeType: "image/png", data: { bytes: png } }])).toEqual([]);
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
