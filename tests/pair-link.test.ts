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
    expect(sh).toContain("clutch_tailnet_host");
    expect(sh).toContain('"${TRUSTED_ARGS[@]}"');
    const ts = readFileSync(join(ROOT, "src", "web", "start-web.ts"), "utf8");
    expect(ts).toContain("detectTailnetHost()");
    expect(ts).toContain("trustedHostArgs(");
  });

  it("detects the MagicDNS name in exactly one shared place", () => {
    const lib = readFileSync(join(ROOT, "scripts", "lib", "clutch-tailnet-host.sh"), "utf8");
    expect(lib).toContain("tailscale status --self --json");
    expect(lib).toContain("Self.DNSName");
    // Both launchers source the one implementation rather than re-inlining it.
    for (const script of ["start-web.sh", "serve-tailscale.sh"]) {
      const body = readFileSync(join(ROOT, "scripts", script), "utf8");
      expect(body).toContain("lib/clutch-tailnet-host.sh");
      expect(body).not.toContain("Self.DNSName");
    }
  });

  // Regression: on 2026-10-11 the iOS app got a 403 on /api for nine hours
  // because pm2 started clutch-web before Tailscale finished starting, the
  // one-shot read came back empty, and nothing ever corrected the host list.
  // Both launchers must retry, and the shell launcher must be able to repair
  // itself after the fact.
  it("both launchers retry the tailnet read instead of trusting a single cold-start read", () => {
    const sh = readFileSync(join(ROOT, "scripts", "start-web.sh"), "utf8");
    expect(sh).toContain("clutch_tailnet_host");
    expect(sh).not.toContain('tailnet_host="${CLUTCH_TAILNET_HOST:-$(tailscale status');

    const ts = readFileSync(join(ROOT, "src", "web", "start-web.ts"), "utf8");
    expect(ts).toContain("readTailnetHost()");
    expect(ts).toMatch(/while|for \(;;\)/);
    expect(ts).toContain("CLUTCH_TAILNET_WAIT_SECONDS");
  });

  it("starts the reconciler and says so when the tailnet name is missing at boot", () => {
    const sh = readFileSync(join(ROOT, "scripts", "start-web.sh"), "utf8");
    expect(sh).toContain("clutch_reconcile_tailnet_host");
    expect(sh).toMatch(/403/);
  });

  it("bounds the reconciler so a Mac that never joins a tailnet cannot loop", () => {
    const lib = readFileSync(join(ROOT, "scripts", "lib", "clutch-tailnet-host.sh"), "utf8");
    expect(lib).toContain("CLUTCH_TAILNET_MAX_RESTARTS");
    expect(lib).toMatch(/restarts < CLUTCH_TAILNET_MAX_RESTARTS/);
    expect(lib).toContain("CLUTCH_TAILNET_RECONCILE_SECONDS");
    // Restarts only on a real mismatch, never speculatively.
    expect(lib).toContain("clutch_running_trusts_host");
  });

  it("defers Tailscale Serve rather than dropping it when Tailscale is still starting", () => {
    const serve = readFileSync(join(ROOT, "scripts", "serve-tailscale.sh"), "utf8");
    expect(serve).toContain("clutch_tailnet_host");
    expect(serve).not.toContain('HOST="${CLUTCH_TAILNET_HOST:-$(tailscale status');
  });
});

describe("iOS app schemes and packages", () => {
  it("registers clutch and minimax schemes with ExyteChat", () => {
    const projectYml = readFileSync(join(ROOT, "ios", "project.yml"), "utf8");
    expect(projectYml).toMatch(/- clutch$/m);
    expect(projectYml).toMatch(/- minimax$/m);
    expect(projectYml).not.toMatch(/- harness$/m); // retired-name
    expect(projectYml).toContain("ExyteChat");
    expect(projectYml).toContain("ITSAppUsesNonExemptEncryption: false");
  });
});
