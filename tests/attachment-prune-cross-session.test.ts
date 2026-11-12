import { describe, it, expect, vi } from "vitest";
import { mkdtemp, mkdir, utimes, access, rm as realRm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

const gate = vi.hoisted(() => ({ target: "", paused: () => {}, release: Promise.resolve() }));
vi.mock("node:fs/promises", async (original) => {
  const fs = await original<typeof import("node:fs/promises")>();
  return { ...fs, rm: async (path: Parameters<typeof fs.rm>[0], options: Parameters<typeof fs.rm>[1]) => {
    if (path === gate.target) { gate.paused(); await gate.release; }
    return fs.rm(path, options);
  } };
});
import { materializeAttachment, prepareAttachedPrompt, pruneAttachments } from "../src/web/chat-bridge.ts";

describe("landed cross-session prune", () => {
  it("serializes another session prune before the image writer", async () => {
    const root = await mkdtemp(join(tmpdir(), "clutch-prune-proof-"));
    const old = join(root, "active-S");
    await mkdir(old);
    const expired = new Date(Date.now() - 3 * 24 * 60 * 60 * 1000);
    await utimes(old, expired, expired);
    gate.target = old;
    let release!: () => void;
    gate.release = new Promise<void>((resolve) => { release = resolve; });
    const paused = new Promise<void>((resolve) => { gate.paused = resolve; });
    const pruning = pruneAttachments(root, 24 * 60 * 60 * 1000, "other-T");
    await paused;
    let finished = false;
    const writing = materializeAttachment({ root, sessionId: "active-S", image: { mimeType: "image/png", data: Buffer.from("fixture image").toString("base64"), name: "shot.png" }, index: 0 }).then((file) => { finished = true; return file; });
    await new Promise((resolve) => setTimeout(resolve, 10));
    expect(finished).toBe(false);
    release();
    await pruning;
    const file = await writing;
    expect(file).not.toBeNull();
    await expect(access(file!)).resolves.toBeUndefined();
    gate.target = "";
    await realRm(root, { recursive: true, force: true });
  });
  it("releases the serialization queue after a failed batch", async () => {
    const root = await mkdtemp(join(tmpdir(), "clutch-prune-release-"));
    const image = { mimeType: "image/png", data: Buffer.from("fixture").toString("base64") };
    await expect(prepareAttachedPrompt(root, "../outside", "text", [image])).rejects.toThrow();
    const file = await materializeAttachment({ root, sessionId: "valid", image, index: 0 });
    expect(file).not.toBeNull();
    await expect(access(file!)).resolves.toBeUndefined();
    await realRm(root, { recursive: true, force: true });
  });

});
