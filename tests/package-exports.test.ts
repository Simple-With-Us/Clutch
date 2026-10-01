import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

import { existsSync } from "node:fs";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");

describe("package exports", () => {
  it("point at files that exist and never type Python as TypeScript", () => {
    const pkg = JSON.parse(readFileSync(join(ROOT, "package.json"), "utf8")) as {
      exports: Record<string, string>;
    };
    expect(pkg.exports["./dsh/acp"]).toBe("./src/dsh/acp/driver.ts");
    expect(pkg.exports["./dsh/acp/driver"]).toBe("./src/dsh/acp/driver.ts");
    expect(pkg.exports["./dsh/mcp-patch"]).toBe("./src/dsh/acp/mcp-patch.ts");
    expect(pkg.exports["./minimax/acp"]).toBe("./src/minimax/acp/driver.ts");
    expect(pkg.exports["./shared/cordis-patch"]).toBeUndefined();
    // Retired aliases are gone, not kept as shims.
    expect(pkg.exports["./harness/dsh/acp"]).toBeUndefined(); // retired-name
    expect(Object.keys(pkg.exports).some((key) => key.startsWith("./mmh/"))).toBe(false); // retired-name
    for (const [key, target] of Object.entries(pkg.exports)) {
      if (key === "./package.json") continue;
      expect(target.endsWith(".py"), `${key} exports Python`).toBe(false);
      expect(existsSync(join(ROOT, target)), `${key} -> ${target}`).toBe(true);
    }
  });
});

describe("package identity", () => {
  it("is published as clutch with clutch-* bins", () => {
    const pkg = JSON.parse(readFileSync(join(ROOT, "package.json"), "utf8")) as {
      name: string;
      bin: Record<string, string>;
      scripts: Record<string, string>;
    };
    expect(pkg.name).toBe("clutch");
    for (const bin of Object.keys(pkg.bin)) {
      expect(bin === "clutch" || bin.startsWith("clutch-"), bin).toBe(true);
      expect(existsSync(join(ROOT, pkg.bin[bin]!)), `${bin} -> ${pkg.bin[bin]}`).toBe(true);
    }
    expect(pkg.scripts.web).not.toContain("3080");
  });

  it("defaults Clutch web to its own port, not vanilla dsh's 3080", async () => {
    const { CLUTCH_WEB_PORT_DEFAULT, clutchWebPort } = await import("../src/shared/ports.ts");
    expect(CLUTCH_WEB_PORT_DEFAULT).toBe(3180);
    expect(clutchWebPort({})).toBe("3180");
    expect(clutchWebPort({ CLUTCH_WEB_PORT: "3190" })).toBe("3190");
  });
});

describe("httpStatusIsUp", () => {
  it("treats 401 as healthy so the auth-walled web port is not reclaimed", async () => {
    const { httpStatusIsUp } = await import("../src/shared/http-up.ts");
    expect(httpStatusIsUp(200)).toBe(true);
    expect(httpStatusIsUp(401)).toBe(true);
    expect(httpStatusIsUp(403)).toBe(true);
    expect(httpStatusIsUp(0)).toBe(false);
    expect(httpStatusIsUp(500)).toBe(false);
  });
});
