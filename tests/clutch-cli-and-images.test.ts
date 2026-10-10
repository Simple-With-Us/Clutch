import { describe, expect, it } from "vitest";
import { execFileSync } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
  dshCredentialCandidates,
  dshEngineStem,
  dshLoginNote,
  dshSupport,
  dshVersionCompatibilityReason,
  DSH_PER_MODEL_IMAGES,
  STATIC_DSH_MODELS,
} from "../src/dsh/acp/driver.ts";
import { MINIMAX_PER_MODEL_IMAGES, STATIC_MINIMAX_MODELS, minimaxSupport } from "../src/minimax/acp/driver.ts";
import { isDshEngineCli } from "../src/dsh/acp/mcp-patch.ts";

const ROOT = join(__dirname, "..");

describe("DSH engine identity", () => {
  it("recognises the engine under both of its names", () => {
    // Clutch ships its own pinned wrapper; the engine is still `dsh`.  Every
    // engine-scoped policy has to answer yes for both.
    for (const cli of ["dsh", "clutch", "DSH", "Clutch"]) {
      expect(isDshEngineCli(cli)).toBe(true);
    }
  });

  it("recognises a wrapper by path, extension stripped", () => {
    // BotFleet spawns whatever string the instance config carries, which is
    // routinely an absolute path.
    for (const cli of [
      "/Users/jay/apps/clutch-runtime/scripts/clutch.sh",
      "/Users/jay/apps/dsh-runtime/dsh.sh",
      "/Users/jay/.local/bin/clutch",
      "/opt/homebrew/bin/dsh.mjs",
    ]) {
      expect(isDshEngineCli(cli)).toBe(true);
    }
  });

  it("does not claim some other engine", () => {
    for (const cli of ["grok", "codex", "claude", "pi", "minimax-acp.sh", "clutch-rogue"]) {
      expect(isDshEngineCli(cli)).toBe(false);
    }
  });

  it("dropped the retired wrapper name instead of aliasing it", () => {
    expect(isDshEngineCli("harness")).toBe(false); // retired-name
  });
});

describe("the minimum-version gate follows the engine, not the binary name", () => {
  it("still fires for the clutch wrapper", () => {
    // Regression.  The gate used to compare against the literal "dsh" and
    // return early for everything else, so configuring the very wrapper this
    // repo ships silently disabled the one check standing between an outdated
    // CLI and a paid turn.
    const reason = dshVersionCompatibilityReason("0.0.1", "clutch");
    expect(reason).toContain("required for native ACP");
  });

  it("fires for an old stock binary too", () => {
    expect(dshVersionCompatibilityReason("0.0.1", "dsh")).toContain("required");
    expect(dshVersionCompatibilityReason("0.0.1", "/x/dsh.sh")).toContain("required");
  });

  it("passes a new enough version", () => {
    expect(dshVersionCompatibilityReason("0.1.5-rc.2", "clutch")).toBeNull();
    expect(dshVersionCompatibilityReason("0.1.5-rc.2", "dsh")).toBeNull();
  });

  it("stays exempt for a genuinely different engine", () => {
    // A DSH version floor is meaningless for another binary, and pretending
    // otherwise would block a perfectly good CLI.
    expect(dshVersionCompatibilityReason("0.0.1", "grok")).toBeNull();
    expect(dshVersionCompatibilityReason("0.0.1", "claude")).toBeNull();
  });
});

describe("engine state home per CLI stem", () => {
  const env = { HOME: "/home/u", CLUTCH_HOME: "/home/u/.clutch-test", DSH_HOME: "/elsewhere" };

  it("reads the Clutch store for clutch and the vanilla store for dsh", () => {
    expect(dshEngineStem("/Users/jay/.local/bin/clutch")).toBe("clutch");
    expect(dshEngineStem("dsh")).toBe("dsh");
    expect(dshCredentialCandidates(env, "clutch")).toEqual(["/home/u/.clutch-test/dsh/.credentials.yaml"]);
    expect(dshCredentialCandidates(env, "scripts/clutch.sh")).toEqual(["/home/u/.clutch-test/dsh/.credentials.yaml"]);
    expect(dshCredentialCandidates(env, "dsh")).toEqual(["/elsewhere/.credentials.yaml"]);
    expect(dshCredentialCandidates({ HOME: "/home/u" }, "dsh")).toEqual(["/home/u/.dsh/.credentials.yaml"]);
    expect(dshCredentialCandidates({ HOME: "/home/u" }, "clutch")).toEqual(["/home/u/.clutch/dsh/.credentials.yaml"]);
    // No CLI means the default (vanilla dsh), never "either store".
    expect(dshCredentialCandidates(env)).toEqual(["/elsewhere/.credentials.yaml"]);
  });

  it("names the matching store in the login note", () => {
    expect(dshLoginNote("clutch")).toBe("Clutch CLI auth missing — add ~/.clutch/dsh/.credentials.yaml");
    expect(dshLoginNote("dsh")).toBe("dsh CLI auth missing — add ~/.dsh/.credentials.yaml");
    // defaultCli stays vanilla `dsh`, so the static note matches it.
    expect(dshSupport.defaultCli).toBe("dsh");
    expect(dshSupport.loginNote).toBe(dshLoginNote("dsh"));
    expect(dshSupport.displayName).toBe("Clutch");
  });
});

describe("clutch CLI wrapper", () => {
  it("is the only CLI script; the old shims are gone", () => {
    const canonical = join(ROOT, "scripts/clutch.sh");
    expect(existsSync(canonical)).toBe(true);
    expect(statSync(canonical).mode & 0o111).toBeTruthy();
    for (const path of [
      "scripts/dsh.sh",
      "dsh.sh",
      "dsh-acp.sh",
      "grok-acp.sh",
      "ensure-web.sh",
      "start-web.sh",
      "serve-tailscale.sh",
      "install-dock-app.sh",
    ]) {
      expect(existsSync(join(ROOT, path)), path).toBe(false);
    }
  });

  it("keeps the self-exec refusal", () => {
    const canonical = readFileSync(join(ROOT, "scripts/clutch.sh"), "utf8");
    expect(canonical).toContain("refuse self-exec");
    expect(canonical).toContain('exec "$BIN" "$@"');
  });

  it("forces DSH_HOME to $CLUTCH_HOME/dsh even when DSH_HOME is already set", () => {
    // Vanilla dsh and BotFleet own ~/.dsh.  An inherited DSH_HOME must never
    // point Clutch back at their state.
    const scratch = mkdtempSync(join(tmpdir(), "clutch-cli-test-"));
    try {
      const runtime = join(scratch, "runtime");
      const binDir = join(runtime, "node_modules", ".bin");
      mkdirSync(binDir, { recursive: true });
      const stub = join(binDir, "dsh");
      writeFileSync(stub, '#!/usr/bin/env bash\nprintf "%s" "$DSH_HOME"\n');
      chmodSync(stub, 0o755);
      const clutchHome = join(scratch, "clutch-home");
      const out = execFileSync("bash", [join(ROOT, "scripts/clutch.sh"), "--version"], {
        env: {
          PATH: process.env.PATH ?? "/usr/bin:/bin",
          HOME: scratch,
          CLUTCH_RUNTIME_ROOT: runtime,
          CLUTCH_HOME: clutchHome,
          DSH_HOME: "/tmp/elsewhere",
        },
        encoding: "utf8",
      });
      expect(out).toBe(join(clutchHome, "dsh"));
      expect(statSync(join(clutchHome, "dsh")).isDirectory()).toBe(true);
      expect(statSync(join(clutchHome, "dsh")).mode & 0o077).toBe(0);
    } finally {
      rmSync(scratch, { recursive: true, force: true });
    }
  });

  it("finds its lib when npm runs it through a node_modules/.bin symlink", () => {
    const scratch = mkdtempSync(join(tmpdir(), "clutch-bin-link-"));
    try {
      const runtime = join(scratch, "runtime");
      const binDir = join(runtime, "node_modules", ".bin");
      mkdirSync(binDir, { recursive: true });
      const stub = join(binDir, "dsh");
      writeFileSync(stub, '#!/usr/bin/env bash\nprintf "%s" "$DSH_HOME"\n');
      chmodSync(stub, 0o755);
      const link = join(binDir, "clutch");
      symlinkSync(join(ROOT, "scripts/clutch.sh"), link);
      const clutchHome = join(scratch, "clutch-home");
      const out = execFileSync(link, ["--version"], {
        env: {
          PATH: process.env.PATH ?? "/usr/bin:/bin",
          HOME: scratch,
          CLUTCH_RUNTIME_ROOT: runtime,
          CLUTCH_HOME: clutchHome,
        },
        encoding: "utf8",
      });
      expect(out).toBe(join(clutchHome, "dsh"));
    } finally {
      rmSync(scratch, { recursive: true, force: true });
    }
  });

  it("keeps Grok out of the engine home", () => {
    // Grok is not the DSH engine; sourcing clutch-env.sh would create and
    // force an engine home it never uses.
    const grok = readFileSync(join(ROOT, "scripts/grok-acp.sh"), "utf8");
    expect(grok).not.toMatch(/^\s*(source|\.)\s+.*clutch-env\.sh/m);
    for (const script of ["clutch.sh", "start-web.sh", "ensure-web.sh", "serve-tailscale.sh", "dsh-acp.sh", "minimax-acp.sh"]) {
      expect(readFileSync(join(ROOT, "scripts", script), "utf8"), script).toMatch(/source .*lib\/clutch-env\.sh/);
    }
  });
});

describe("per-model image support", () => {
  it("keeps the engine gate closed until BotFleet consumes per-model flags", () => {
    // BotFleet currently gates image intake by engine alone.  Do not offer
    // attachments on non-vision Pro before the per-model consumer deploys.
    expect(dshSupport.images).toBe(false);
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

  it("publishes the same answer through the per-model map and the catalog row", () => {
    // A surface may read either, so the two must agree row for row.
    const byId = new Map(STATIC_DSH_MODELS.options.map((o) => [o.id, o]));
    for (const [id, images] of Object.entries(DSH_PER_MODEL_IMAGES)) {
      expect(byId.get(id)?.images, id).toBe(images);
    }
    expect(dshSupport.perModelImages).toEqual(DSH_PER_MODEL_IMAGES);
  });

  it("routes MiniMax image support by the provider's own modality declaration", () => {
    // The installed pi-ai catalog declares M3 (and the newer M3.1 preview) as
    // text+image and the M2.7 family as text-only.  Offering an attachment to a
    // text-only row is what produced the refusal the owner hit.
    const byId = new Map(STATIC_MINIMAX_MODELS.options.map((o) => [o.id, o]));
    expect(byId.get("MiniMax-M3.1-Flash-Preview")?.images).toBe(true);
    expect(byId.get("MiniMax-M3")?.images).toBe(true);
    expect(byId.get("MiniMax-M2.7-highspeed")?.images).toBe(false);
    expect(byId.get("MiniMax-M2.7")?.images).toBe(false);
    for (const option of STATIC_MINIMAX_MODELS.options) {
      expect(typeof option.images, option.id).toBe("boolean");
    }
    expect(minimaxSupport.perModelImages).toEqual(MINIMAX_PER_MODEL_IMAGES);
  });
});
