import { readFileSync, rmSync } from "node:fs";
import { dirname } from "node:path";
import { afterEach, describe, expect, it } from "vitest";

import {
  DSH_MCP_PATCH_PREFIX,
  dshMcpPatchYaml,
  dshMcpServerName,
  isDshEngineCli,
  writeDshMcpPatch,
} from "../src/dsh/acp/mcp-patch.ts";

const written: string[] = [];

afterEach(() => {
  for (const path of written.splice(0)) {
    rmSync(dirname(path), { recursive: true, force: true });
  }
});

describe("isDshEngineCli", () => {
  it("matches a stock dsh binary name", () => {
    expect(isDshEngineCli("dsh")).toBe(true);
    expect(isDshEngineCli("/usr/local/bin/dsh")).toBe(true);
    expect(isDshEngineCli("dsh-acp.sh")).toBe(false);
  });
});

describe("dshMcpServerName", () => {
  it("uniquifies colliding names", () => {
    const used = new Set<string>();
    expect(dshMcpServerName("computer", used)).toBe("computer");
    expect(dshMcpServerName("computer", used)).toBe("computer_2");
  });

  it("uses mcp when the cleaned name is empty", () => {
    const used = new Set<string>();
    expect(dshMcpServerName("", used)).toBe("mcp");
  });
});

describe("dshMcpPatchYaml", () => {
  it("emits one dsh-mcp-client row per stdio mount", () => {
    const yaml = dshMcpPatchYaml([
      { name: "computer", command: "node", args: ["mcp.js"], env: [{ name: "TOKEN", value: "x" }] },
    ]);
    expect(yaml).toContain("@deepseek-ai/dsh-mcp-client");
    expect(yaml).toContain("serverName: \"computer\"");
    expect(yaml).toContain("TOKEN: \"x\"");
    expect(yaml).toContain(`${DSH_MCP_PATCH_PREFIX}0-computer`);
  });
});

describe("writeDshMcpPatch", () => {
  it("writes a 0600 overlay in a private 0700 directory", () => {
    const path = writeDshMcpPatch([
      { name: "computer", command: "node", args: [], env: [] },
    ]);
    written.push(path);
    const yaml = readFileSync(path, "utf8");
    expect(yaml).toContain("dsh-mcp-client");
    expect(dirname(path)).toContain(DSH_MCP_PATCH_PREFIX);
  });
});
