import { describe, expect, it } from "vitest";
import {
  filterToolsForSubagent,
  getSubagentProfile,
  SUBAGENT_PROFILES,
} from "../src/shared/subagent-tool-profiles.ts";

describe("subagent-tool-profiles", () => {
  it("defines standard roles with minimal tool surfaces", () => {
    expect(SUBAGENT_PROFILES.researcher).toBeDefined();
    expect(SUBAGENT_PROFILES.builder).toBeDefined();
    expect(SUBAGENT_PROFILES.verifier).toBeDefined();
    expect(SUBAGENT_PROFILES.xcode_ship).toBeDefined();
    expect(SUBAGENT_PROFILES.coordinator).toBeDefined();

    // Researcher must never have write or command execution tools
    expect(SUBAGENT_PROFILES.researcher.allowedTools).not.toContain("write_to_file");
    expect(SUBAGENT_PROFILES.researcher.allowedTools).not.toContain("run_command");
    expect(SUBAGENT_PROFILES.researcher.allowedTools).toContain("view_file");
    expect(SUBAGENT_PROFILES.researcher.allowedTools).toContain("recall_search");

    // Verifier must never have write tools
    expect(SUBAGENT_PROFILES.verifier.allowedTools).not.toContain("write_to_file");
    expect(SUBAGENT_PROFILES.verifier.allowedTools).not.toContain("replace_file_content");
    expect(SUBAGENT_PROFILES.verifier.allowedTools).toContain("run_command");
  });

  it("filters a broad tool list down to a subagent profile", () => {
    const allTools = [
      { name: "view_file" },
      { name: "write_to_file" },
      { name: "replace_file_content" },
      { name: "run_command" },
      { name: "search_code" },
      { name: "search_web" },
      { name: "read_url_content" },
      { name: "recall_search" },
      { name: "send_message" },
      { name: "invoke_subagent" },
    ];

    const researcherTools = filterToolsForSubagent(allTools, "researcher");
    const allowed = new Set(researcherTools.map((t) => t.name));

    expect(allowed.has("view_file")).toBe(true);
    expect(allowed.has("search_code")).toBe(true);
    expect(allowed.has("recall_search")).toBe(true);
    expect(allowed.has("write_to_file")).toBe(false);
    expect(allowed.has("replace_file_content")).toBe(false);
    expect(allowed.has("run_command")).toBe(false);
    expect(allowed.has("invoke_subagent")).toBe(false);
  });

  it("returns all tools if profile is unknown", () => {
    const tools = [{ name: "foo" }, { name: "bar" }];
    expect(filterToolsForSubagent(tools, "non_existent_role")).toEqual(tools);
  });

  it("recommends Flash model for mechanical roles per 30% rule", () => {
    expect(getSubagentProfile("researcher")?.recommendedModelTier).toBe("flash");
    expect(getSubagentProfile("verifier")?.recommendedModelTier).toBe("flash");
    expect(getSubagentProfile("xcode_ship")?.recommendedModelTier).toBe("flash");
    expect(getSubagentProfile("builder")?.recommendedModelTier).toBe("pro");
    expect(getSubagentProfile("coordinator")?.recommendedModelTier).toBe("pro");
  });
});
