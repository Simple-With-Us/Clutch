import { describe, expect, it } from "vitest";
import { existsSync, statSync } from "node:fs";
import { join } from "node:path";

import { dshSupport, dshVersionCompatibilityReason, STATIC_DSH_MODELS } from "../src/dsh/acp/driver.ts";
import { isDshEngineCli, isStockDshCli } from "../src/dsh/acp/mcp-patch.ts";

const ROOT = join(__dirname, "..");

describe("DSH engine identity", () => {
  it("recognises the engine under both of its names", () => {
    // Harness is the product and ships its own pinned wrapper; the engine is
    // still `dsh`.  Every engine-scoped policy has to answer yes for both.
    for (const cli of ["dsh", "harness", "DSH", "Harness"]) {
      expect(isDshEngineCli(cli)).toBe(true);
    }
  });

  it("recognises a wrapper by path, extension stripped", () => {
    // BotFleet spawns whatever string the instance config carries, which is
    // routinely an absolute path.
    for (const cli of [
      "/Users/jay/Code/Harness/scripts/harness.sh",
      "/Users/jay/Code/Harness/scripts/dsh.sh",
      "/opt/homebrew/bin/harness",
      "/opt/homebrew/bin/dsh.mjs",
    ]) {
      expect(isDshEngineCli(cli)).toBe(true);
    }
  });

  it("does not claim some other engine", () => {
    for (const cli of ["grok", "codex", "claude", "pi", "mmh-acp.sh", "harness-rogue"]) {
      expect(isDshEngineCli(cli)).toBe(false);
    }
  });

  it("keeps the old name working as an alias", () => {
    // BotFleet imports isStockDshCli directly; dropping it breaks the driver
    // at import time.
    expect(isStockDshCli("harness")).toBe(true);
    expect(isStockDshCli("grok")).toBe(false);
  });
});

describe("the minimum-version gate follows the engine, not the binary name", () => {
  it("still fires for a harness wrapper", () => {
    // Regression.  The gate used to compare against the literal "dsh" and
    // return early for everything else, so configuring the very wrapper this
    // repo ships silently disabled the one check standing between an outdated
    // CLI and a paid turn.
    const reason = dshVersionCompatibilityReason("0.0.1", "harness");
    expect(reason).toContain("required for native ACP");
  });

  it("fires for an old stock binary too", () => {
    expect(dshVersionCompatibilityReason("0.0.1", "dsh")).toContain("required");
    expect(dshVersionCompatibilityReason("0.0.1", "/x/dsh.sh")).toContain("required");
  });

  it("passes a new enough version", () => {
    expect(dshVersionCompatibilityReason("0.1.5-rc.2", "harness")).toBeNull();
    expect(dshVersionCompatibilityReason("0.1.5-rc.2", "dsh")).toBeNull();
  });

  it("stays exempt for a genuinely different engine", () => {
    // A DSH version floor is meaningless for another binary, and pretending
    // otherwise would block a perfectly good CLI.
    expect(dshVersionCompatibilityReason("0.0.1", "grok")).toBeNull();
    expect(dshVersionCompatibilityReason("0.0.1", "claude")).toBeNull();
  });
});

describe("harness CLI wrapper", () => {
  it("makes harness.sh the canonical implementation and dsh.sh a shim", () => {
    for (const path of ["scripts/harness.sh", "scripts/dsh.sh", "harness.sh"]) {
      expect(existsSync(join(ROOT, path))).toBe(true);
    }
    const shim = join(ROOT, "scripts/dsh.sh");
    const canonical = join(ROOT, "scripts/harness.sh");
    expect(statSync(shim).mode & 0o111).toBeTruthy();
    expect(statSync(canonical).mode & 0o111).toBeTruthy();
  });

  it("delegates rather than duplicating, because the loop guard must live once", () => {
    // The 2026-09-16 incident was a self-exec loop in this script.  Two copies
    // of the guard are two places for it to rot.
    const shim = require("node:fs").readFileSync(join(ROOT, "scripts/dsh.sh"), "utf8");
    expect(shim).toContain("harness.sh");
    expect(shim).toContain('exec "$TARGET"');
  });

  it("keeps the self-exec refusal in the canonical wrapper", () => {
    const canonical = require("node:fs").readFileSync(join(ROOT, "scripts/harness.sh"), "utf8");
    expect(canonical).toContain("refuse self-exec");
    expect(canonical).toContain('exec "$BIN" "$@"');
  });
});

describe("per-model image support", () => {
  it("answers the engine question yes", () => {
    // The engine can consume a referenced image: the ACP prompt is a single
    // text block and the agent opens the path with its own read tool.
    expect(dshSupport.images).toBe(true);
  });

  it("marks the multimodal model and not the reasoning one", () => {
    // DeepSeek V4.1 Flash is the image/video model; V4.1 Pro is not.  A model
    // that cannot interpret the bytes should not be offered an attachment.
    const byId = new Map(STATIC_DSH_MODELS.options.map((o) => [o.id, o]));
    expect(byId.get("DeepSeek-V4.1-Flash")?.images).toBe(true);
    expect(byId.get("DeepSeek-V4.1-Pro")?.images).toBe(false);
  });

  it("gives every model an explicit answer", () => {
    // A missing flag means "not established", which a surface has to treat as
    // unknown.  Better that the catalog is complete.
    for (const option of STATIC_DSH_MODELS.options) {
      expect(typeof option.images).toBe("boolean");
    }
  });
});
