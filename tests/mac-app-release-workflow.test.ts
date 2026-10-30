import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { createHash } from "node:crypto";
import { describe, expect, it } from "vitest";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const WORKFLOW = join(ROOT, ".github/workflows/mac-app-build.yml");
const RELEASE_ACTION = "softprops/action-gh-release@efb35369e0ad2afab669f228072c1b0d510eae64 # v3.0.3";

function workflowText(): string {
  return readFileSync(WORKFLOW, "utf8");
}

// Job bodies are the lines indented under each two-space job key.
function jobBody(text: string, id: string): string {
  const lines = text.split("\n");
  const start = lines.findIndex((line) => line === `  ${id}:`);
  expect(start, `job ${id}`).toBeGreaterThan(-1);
  const body: string[] = [];
  for (const line of lines.slice(start + 1)) {
    if (/^  [a-z0-9-]+:$/.test(line)) break;
    body.push(line);
  }
  return body.join("\n");
}

function verifierSource(publishJob: string): string {
  const match = publishJob.match(/python3 - <<'PY'\n([\s\S]*?)\n {10}PY/);
  expect(match, "embedded manifest verifier").not.toBeNull();
  return match?.[1].replace(/^ {10}/gm, "") ?? "";
}

describe("Mac release workflow", () => {
  const text = workflowText();
  const build = jobBody(text, "build");
  const publish = jobBody(text, "publish");

  it("builds on xcode-27 and publishes v3 on a GitHub-hosted Ubuntu runner", () => {
    expect(build).toContain("runs-on: xcode-27");
    expect(build).not.toContain("action-gh-release");
    expect(build).toContain("actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9 # v7.0.2");
    expect(build).toContain("if-no-files-found: error");
    expect(build).toContain("clutch-mac-build.json");

    expect(publish).toContain("needs: build");
    expect(publish).toContain("if: needs.build.result == 'success'");
    expect(publish).toContain("runs-on: ubuntu-latest");
    expect(publish).toContain(`uses: ${RELEASE_ACTION}`);
    expect(publish).toContain("fail_on_unmatched_files: true");
    expect(publish).toContain("make_latest: false");
    expect(publish).toContain("release-assets/Clutch-mac-arm64.zip");
    expect(publish).toContain("release-assets/clutch-mac-build.json");
    expect(text.match(/action-gh-release@/g)).toHaveLength(1);
  });

  it("rejects a manifest that does not match the zip", () => {
    const source = verifierSource(publish);
    const dir = mkdtempSync(join(tmpdir(), "clutch-mac-release-"));
    try {
      const zip = Buffer.from("clutch-mac-zip-bytes");
      const sha256 = createHash("sha256").update(zip).digest("hex");
      writeFileSync(join(dir, "Clutch-mac-arm64.zip"), zip);
      writeFileSync(join(dir, "clutch-mac-build.json"), JSON.stringify({
        schemaVersion: 1,
        commit: "abc123",
        artifact: "Clutch-mac-arm64.zip",
        sha256,
        bytes: zip.length,
      }));
      const run = (sha: string) => {
        try {
          const stdout = execFileSync("python3", ["-c", source], {
            cwd: dir,
            env: { ...process.env, GITHUB_SHA: sha },
            encoding: "utf8",
            stdio: ["ignore", "pipe", "pipe"],
          });
          return { code: 0, stdout, stderr: "" };
        } catch (error) {
          const failed = error as { status?: number; stdout?: string; stderr?: string };
          return {
            code: failed.status ?? 1,
            stdout: failed.stdout ?? "",
            stderr: failed.stderr ?? "",
          };
        }
      };

      const ok = run("abc123");
      expect(ok.code, ok.stderr).toBe(0);
      expect(ok.stdout).toContain(`bytes=${zip.length}`);

      const badCommit = run("def456");
      expect(badCommit.code).not.toBe(0);
      expect(badCommit.stderr).toContain("manifest commit");

      const manifest = JSON.parse(readFileSync(join(dir, "clutch-mac-build.json"), "utf8")) as { sha256: string };
      manifest.sha256 = "0".repeat(64);
      writeFileSync(join(dir, "clutch-mac-build.json"), JSON.stringify(manifest));
      const badHash = run("abc123");
      expect(badHash.code).not.toBe(0);
      expect(badHash.stderr).toContain("sha256 mismatch");
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
