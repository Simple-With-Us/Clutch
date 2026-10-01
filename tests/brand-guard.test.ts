import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");

// Historical records and the guard itself may name the retired brand.
const ALLOWED_FILES = [
  /^docs\/EFFORT-LOG\.md$/,
  /^docs\/audits\/2026-09-23-harness-simplewithus-rename\.md$/,
  /^docs\/decisions\/000[1-5]-.*\.md$/,
  /^docs\/migrate-from-dsh-runtime\.md$/,
  /^docs\/bundle-id-history\.md$/,
  /^tests\/brand-guard\.test\.ts$/,
];

// Lines that legitimately keep the word: the upstream product, an explicit
// retired-name marker, and the fleet seat tag and branch prefix, which the
// owner has not retired (the seat roster is outside this rename).
const ALLOWED_LINE =
  /DeepSeek Harness|deepseek-harness|deepseek_harness|retired-name|\[HARNESS\]|`harness\/\*`/;

// Port 3080 is vanilla dsh's.  Clutch serves on 3180.
const PORT_ALLOWED_FILES = [
  ...ALLOWED_FILES,
  /^tests\/package-exports\.test\.ts$/,
];
const PORT_ALLOWED_LINE = /vanilla|upstream|retired-name/i;

function trackedFiles(): string[] {
  return execFileSync("git", ["ls-files", "-z"], { cwd: ROOT, encoding: "utf8" })
    .split("\0")
    .filter(Boolean);
}

const BINARY = /\.(png|jpg|jpeg|gif|ico|icns|pdf|woff2?|ttf|zip|gz|a|dylib)$/i;

function textOf(path: string): string | null {
  if (BINARY.test(path)) return null;
  try {
    const buf = readFileSync(join(ROOT, path));
    if (buf.includes(0)) return null;
    return buf.toString("utf8");
  } catch {
    return null;
  }
}

describe("brand guard", () => {
  const files = trackedFiles();

  it("keeps the retired product name out of tracked paths", () => {
    const bad = files.filter(
      (f) => /harness/i.test(f) && !ALLOWED_FILES.some((re) => re.test(f)),
    );
    expect(bad).toEqual([]);
  });

  it("keeps the retired product name out of tracked contents", () => {
    const hits: string[] = [];
    for (const f of files) {
      if (ALLOWED_FILES.some((re) => re.test(f))) continue;
      const text = textOf(f);
      if (text === null) continue;
      text.split("\n").forEach((line, i) => {
        if (/harness/i.test(line) && !ALLOWED_LINE.test(line)) {
          hits.push(`${f}:${i + 1}: ${line.trim().slice(0, 120)}`);
        }
      });
    }
    expect(hits).toEqual([]);
  });

  it("keeps vanilla dsh's port 3080 out of Clutch files", () => {
    const hits: string[] = [];
    for (const f of files) {
      if (PORT_ALLOWED_FILES.some((re) => re.test(f))) continue;
      if (f === "package-lock.json") continue;
      const text = textOf(f);
      if (text === null) continue;
      text.split("\n").forEach((line, i) => {
        if (/\b3080\b/.test(line) && !PORT_ALLOWED_LINE.test(line)) {
          hits.push(`${f}:${i + 1}: ${line.trim().slice(0, 120)}`);
        }
      });
    }
    expect(hits).toEqual([]);
  });
});
