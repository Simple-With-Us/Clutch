import { describe, expect, it } from "vitest";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";

/**
 * Deploy checks for the TestFlight pipeline (C-84).
 *
 * Auto-ship contract (owner 2026-10-17): a merge to main that touches the iOS
 * tree uploads a fresh TestFlight build with no human step.  Two things broke
 * that and nothing in CI could see either one:
 *
 *  - #133 shipped an AppIcon with an alpha channel.  The PR dry-run is an
 *    unsigned simulator compile, which never validates the icon, so App Store
 *    Connect rejected every later upload (altool 90717) while every PR check
 *    stayed green.
 *  - ios-ship.yml had no scheduled catch-up, so a failed push ship was never
 *    retried.
 *
 * These checks pin both pieces of wiring so a refactor cannot quietly turn the
 * pipeline back into a manual one.  They run on the Linux verify job: pure
 * Node, no sips, no Xcode.
 */

const ROOT = join(__dirname, "..");
const read = (rel: string): string => readFileSync(join(ROOT, rel), "utf8");

// ---------------------------------------------------------------- app icon

const PNG_SIGNATURE = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

interface PngFacts {
  width: number;
  height: number;
  colorType: number;
  chunks: string[];
}

function pngFacts(buf: Buffer): PngFacts {
  expect(buf.subarray(0, 8).equals(PNG_SIGNATURE), "not a PNG").toBe(true);
  const chunks: string[] = [];
  let width = 0;
  let height = 0;
  let colorType = -1;
  let off = 8;
  while (off + 8 <= buf.length) {
    const len = buf.readUInt32BE(off);
    const type = buf.toString("ascii", off + 4, off + 8);
    chunks.push(type);
    if (type === "IHDR") {
      width = buf.readUInt32BE(off + 8);
      height = buf.readUInt32BE(off + 12);
      colorType = buf.readUInt8(off + 8 + 9);
    }
    if (type === "IEND") break;
    off += 12 + len;
  }
  return { width, height, colorType, chunks };
}

interface AppIconImage {
  filename?: string;
  idiom?: string;
  platform?: string;
  size?: string;
}

describe("iOS AppIcon is App Store valid", () => {
  const dir = "ios/Assets.xcassets/AppIcon.appiconset";
  const contents = JSON.parse(read(`${dir}/Contents.json`)) as { images: AppIconImage[] };
  // The mac slot is not part of the iOS archive; only the iOS slots reach altool.
  const iosImages = contents.images.filter((i) => i.idiom !== "mac");

  it("declares an iOS large icon", () => {
    expect(iosImages.some((i) => i.size === "1024x1024" && i.filename)).toBe(true);
  });

  it.each(iosImages.filter((i) => i.filename).map((i) => [i.filename as string]))(
    "%s has no alpha channel (altool 90717)",
    (filename) => {
      const path = join(ROOT, dir, filename);
      expect(existsSync(path), `${filename} is referenced by Contents.json`).toBe(true);
      const facts = pngFacts(readFileSync(path));
      // 2 = RGB, 0 = grayscale.  4 and 6 carry an alpha channel.  Apple rejects
      // the channel itself, so an RGBA file with every pixel at alpha 255 still
      // fails; a palette file (3) is only safe without a tRNS chunk.
      expect([0, 2, 3], `${filename} colour type ${facts.colorType} carries alpha`).toContain(facts.colorType);
      expect(facts.chunks, `${filename} has a tRNS transparency chunk`).not.toContain("tRNS");
      expect(`${facts.width}x${facts.height}`).toBe("1024x1024");
    },
  );

  it("keeps the Mac slot on its own file so the transparent logo survives", () => {
    const mac = contents.images.filter((i) => i.idiom === "mac" && i.filename);
    const ios = iosImages.map((i) => i.filename);
    for (const m of mac) expect(ios).not.toContain(m.filename);
  });
});

// ------------------------------------------------------------- the workflow

const withoutComments = (text: string): string =>
  text
    .split("\n")
    .filter((line) => !/^\s*#/.test(line))
    .join("\n");

/** The top-level `on:` mapping, up to the next top-level key. */
function onBlock(yml: string): string {
  const m = yml.match(/^on:\n((?:[ \t]+.*\n|[ \t]*#.*\n|\n)*)/m);
  if (!m || m[1] === undefined) throw new Error("ios-ship.yml must declare an on: block");
  return m[1];
}

describe("ios-ship.yml auto-ship contract", () => {
  const yml = read(".github/workflows/ios-ship.yml");
  const code = withoutComments(yml);
  const on = withoutComments(onBlock(yml));
  const pushBlock = on.match(/push:\n([\s\S]*?)\n  \w/)?.[1] ?? "";

  it("ships on a push to main that touches the native tree", () => {
    expect(on).toMatch(/push:\s*\n\s+branches:\s*\[main\]/);
    expect(pushBlock).toMatch(/paths:\s*\n(?:\s+-\s+'[^']+'\n)*?\s+-\s+'ios\/\*\*'/);
    expect(on).toMatch(/workflow_dispatch:/);
  });

  it("retries a failed push ship on a schedule, behind the scheduled path gate", () => {
    expect(on).toMatch(/^\s+schedule:\s*\n\s+- cron: '[^']+'/m);
    expect(code).toMatch(/scheduled-ship-gate\.sh/);
    expect(code).toMatch(/--path-prefix 'ios\/\*\*'/);
    expect(code).toMatch(/--event "\$\{\{ github\.event_name \}\}"/);
    expect(existsSync(join(ROOT, "scripts/ios-fleet/scheduled-ship-gate.sh"))).toBe(true);
  });

  it("gives the scheduled gate every push path, so a missed push still ships", () => {
    // The cron has no paths filter of its own: the gate replays on.push.paths
    // one --path-prefix each.  A push path missing from the gate never ships
    // when its push run is missed (disabled workflow, dropped event, bot
    // merge); an extra gate prefix ships builds no push would have built.
    const pushPaths = Array.from(pushBlock.matchAll(/-\s+'([^']+)'/g), (m) => m[1] as string);
    expect(pushPaths).toContain("ios/**");
    const gatePrefixes = Array.from(code.matchAll(/--path-prefix '([^']+)'/g), (m) => m[1] as string);
    expect([...gatePrefixes].sort()).toEqual([...pushPaths].sort());
  });

  it("carries the last-ship state between hosted runs", () => {
    expect(code).toMatch(/actions\/cache\/restore@/);
    expect(code).toMatch(/actions\/cache\/save@/);
    expect(code).toMatch(/path: ~\/\.cache\/ios-fleet/);
    // The save must key off the gate so a no-op tick writes nothing.
    expect(code).toMatch(/if: \$\{\{ always\(\) && steps\.gate\.outputs\.should_ship == '1' \}\}/);
  });

  it("checks out full history so the gate and the notes can read the commit range", () => {
    expect(code).toMatch(/fetch-depth:\s*0/);
  });

  it("publishes What to Test and ships through the fleet wrapper", () => {
    expect(code).toMatch(/IOS_TF_RELEASE_NOTES:\s*"1"/);
    expect(code).not.toMatch(/IOS_TF_RELEASE_NOTES:\s*"0"/);
    expect(code).toMatch(/run: bash scripts\/ios-ship-testflight\.sh --build "\$\{\{ steps\.plan\.outputs\.build \}\}"/);
  });

  it("plans the release build once and hands that one value to the ship", () => {
    // One plan per release: the plan step runs --plan-build-only behind the
    // scheduled gate, exposes the value as a step and job output, and the
    // ship step is the only consumer of it.
    expect(code).toMatch(/id: plan\n(\s+)if: steps\.gate\.outputs\.should_ship == '1'/);
    expect(code).toMatch(/bash scripts\/ios-ship-testflight\.sh --plan-build-only/);
    expect(code).toMatch(/echo "build=\$\{build\}" >>"\$GITHUB_OUTPUT"/);
    expect(code).toMatch(/build: \$\{\{ steps\.plan\.outputs\.build \}\}/);
    expect(code).not.toMatch(/next-shared-build/);
  });

  it("takes ASC credentials from Fleet-OPS /asc and guards the Xcode toolchain", () => {
    expect(code).toMatch(/INFISICAL_ASC_PROJECT_ID:\s*[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}/);
    expect(code).toMatch(/Assert stable Xcode/);
    expect(code).toMatch(/runs-on:\s*xcode-27/);
    expect(code).not.toMatch(/runs-on:\s*\[?self-hosted/);
  });

  it("never sets a standing gate override", () => {
    expect(code).not.toMatch(/IOS_TF_MIN_INTERVAL_SEC/);
    expect(code).not.toMatch(/--force-ship/);
    expect(code).not.toMatch(/if:.*secrets\./);
  });
});

describe("TestFlight What to Test uses the owner clock", () => {
  it("renders a 12-hour lower-case am or pm and no timezone abbreviation", () => {
    const src = read("scripts/ios-fleet/asc-api.mjs");
    const fn = src.match(/function centralTimestamp[\s\S]*?\n}\n/)?.[0];
    expect(fn, "centralTimestamp is present").toBeTruthy();
    const centralTimestamp = new Function(`${fn}; return centralTimestamp;`)() as (d: Date) => string;
    // 8:35pm on Oct 17 in Chicago is 01:35 UTC on Oct 18 (CDT).
    expect(centralTimestamp(new Date("2026-10-18T01:35:00Z"))).toBe("Sat, Oct 17, 2026 at 8:35pm");
    // CST in winter.
    expect(centralTimestamp(new Date("2026-12-01T18:05:00Z"))).toBe("Tue, Dec 1, 2026 at 12:05pm");
    expect(centralTimestamp(new Date("2026-08-12T06:15:00Z"))).not.toMatch(/\b(?:CT|CDT|CST)\b|AM|PM/);
  });
});
