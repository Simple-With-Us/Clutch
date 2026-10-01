import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

import { launchToken, pairingLink, tailnetDnsName, trustedHostArgs } from "../src/web/pair-link.ts";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");

describe("tailnetDnsName", () => {
  it("reads Self.DNSName without the trailing dot", () => {
    expect(tailnetDnsName({ Self: { DNSName: "Jay-MacBook.boa-roygbiv.ts.net." } })).toBe("jay-macbook.boa-roygbiv.ts.net");
  });

  it("returns null for missing or malformed status", () => {
    expect(tailnetDnsName(null)).toBeNull();
    expect(tailnetDnsName({})).toBeNull();
    expect(tailnetDnsName({ Self: { DNSName: "" } })).toBeNull();
    expect(tailnetDnsName({ Self: { DNSName: "bad host;rm" } })).toBeNull();
  });
});

describe("trustedHostArgs", () => {
  it("emits bare and ported authorities once each, skipping empties", () => {
    expect(trustedHostArgs(["127.0.0.1", "LOCALHOST", "localhost", null, "", "mac.ts.net"], "3180")).toEqual([
      "--trusted-host", "127.0.0.1",
      "--trusted-host", "127.0.0.1:3180",
      "--trusted-host", "localhost",
      "--trusted-host", "localhost:3180",
      "--trusted-host", "mac.ts.net",
      "--trusted-host", "mac.ts.net:3180",
    ]);
  });
});

describe("pairingLink", () => {
  const launch = "http://127.0.0.1:3180/?token=abc-123_XYZ";

  it("extracts the launch token", () => {
    expect(launchToken(launch)).toBe("abc-123_XYZ");
    expect(launchToken("http://127.0.0.1:3180/")).toBeNull();
    expect(launchToken("not a url")).toBeNull();
  });

  it("re-points the launch URL at the tailnet origin inside a clutch:// link", () => {
    const link = new URL(pairingLink({ launchUrl: launch, origin: "https://jay-macbook.boa-roygbiv.ts.net:3180", name: "Jay's Mac" }));
    expect(link.protocol).toBe("clutch:");
    expect(link.host).toBe("pair");
    expect(link.searchParams.get("url")).toBe("https://jay-macbook.boa-roygbiv.ts.net:3180/?token=abc-123_XYZ");
    expect(link.searchParams.get("name")).toBe("Jay's Mac");
  });

  it("refuses a launch URL without a token and non-web origins", () => {
    expect(() => pairingLink({ launchUrl: "http://127.0.0.1:3180/", origin: "http://127.0.0.1:3180" })).toThrow(/no token/);
    expect(() => pairingLink({ launchUrl: launch, origin: "minimax://127.0.0.1:7842" })).toThrow(/http/);
  });
});

describe("start-web trusted hosts", () => {
  it("both launchers trust the detected tailnet name, not only the legacy one", () => {
    const sh = readFileSync(join(ROOT, "scripts", "start-web.sh"), "utf8");
    expect(sh).toContain("tailscale status --self --json");
    expect(sh).toContain('"${TRUSTED_ARGS[@]}"');
    const ts = readFileSync(join(ROOT, "src", "web", "start-web.ts"), "utf8");
    expect(ts).toContain("detectTailnetHost()");
    expect(ts).toContain("trustedHostArgs(");
  });
});

describe("iOS app registers only the clutch scheme", () => {
  it("no longer registers minimax:// or browses _minimax._tcp", () => {
    const projectYml = readFileSync(join(ROOT, "ios", "project.yml"), "utf8");
    expect(projectYml).not.toMatch(/- minimax$/m);
    expect(projectYml).not.toContain("_minimax._tcp");
    expect(projectYml).not.toMatch(/- harness$/m); // retired-name
    expect(projectYml).toMatch(/- clutch$/m);
    expect(projectYml).not.toContain("ExyteChat");
    expect(projectYml).toContain("ITSAppUsesNonExemptEncryption: false");
  });
});
