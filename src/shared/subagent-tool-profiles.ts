/**
 * Scoped Subagent Tool Profiles.
 *
 * Implements the minimal-surface principle for multi-agent delegation:
 * Never inject 50+ tool schemas into every subagent prompt.  Schemas are re-tokenized
 * on every single turn, bloating context, slowing execution, and confusing small models.
 *
 * Each profile defines an explicit allowlist of tools, a maximum turn budget,
 * and an economic model tier recommendation.
 */

export interface SubagentToolProfile {
  name: string;
  role: string;
  description: string;
  /** Exact tool names allowed for this subagent role. */
  allowedTools: readonly string[];
  /** Recommended model tier (the 30% rule: default mechanical work to Flash). */
  recommendedModelTier: "flash" | "pro" | "inherit";
  /** Default max turns before reporting back to orchestrator. */
  maxTurns: number;
  /** Whether the subagent should execute in an isolated git worktree. */
  requiresWorktree: boolean;
}

export const SUBAGENT_PROFILES: Record<string, SubagentToolProfile> = {
  researcher: {
    name: "researcher",
    role: "Codebase & Documentation Researcher",
    description: "Read-only exploration of files, symbol search, web documentation, and fleet memory.",
    allowedTools: [
      "view_file",
      "search_code",
      "search_web",
      "read_url_content",
      "recall_search",
      "send_message",
    ],
    recommendedModelTier: "flash",
    maxTurns: 10,
    requiresWorktree: false,
  },
  builder: {
    name: "builder",
    role: "Implementation & Refactoring Specialist",
    description: "Targeted file editing, local code generation, and worktree-scoped compilation.",
    allowedTools: [
      "view_file",
      "replace_file_content",
      "write_to_file",
      "run_command",
      "send_message",
    ],
    recommendedModelTier: "pro",
    maxTurns: 25,
    requiresWorktree: true,
  },
  verifier: {
    name: "verifier",
    role: "Verification & Quality Auditor",
    description: "Runs test suites, linters, typechecks, and git diff checks. No destructive file edits.",
    allowedTools: [
      "view_file",
      "run_command",
      "send_message",
    ],
    recommendedModelTier: "flash",
    maxTurns: 10,
    requiresWorktree: true,
  },
  xcode_ship: {
    name: "xcode_ship",
    role: "macOS / iOS Build & TestFlight Automation Bot",
    description: "Runs xcodebuild, simctl, provisioning, and App Store Connect uploads inside headless macOS Guest VM.",
    allowedTools: [
      "view_file",
      "run_command",
      "send_message",
    ],
    recommendedModelTier: "flash",
    maxTurns: 15,
    requiresWorktree: true,
  },
  coordinator: {
    name: "coordinator",
    role: "DAG Workflow & Multi-Agent Lead",
    description: "Orchestrates parallel lanes, manages THE BOARD and issues, and synthesizes findings at reduce barriers.",
    allowedTools: [
      "view_file",
      "run_command",
      "invoke_subagent",
      "send_message",
      "manage_task",
      "call_mcp_tool",
    ],
    recommendedModelTier: "pro",
    maxTurns: 40,
    requiresWorktree: false,
  },
};

/**
 * Filter an array of tool schema objects down to only those allowed for a specific subagent role.
 */
export function filterToolsForSubagent<T extends { name: string }>(
  allTools: readonly T[],
  profileName: keyof typeof SUBAGENT_PROFILES | string,
): T[] {
  const profile = SUBAGENT_PROFILES[profileName];
  if (!profile) {
    return [...allTools];
  }
  const allowSet = new Set(profile.allowedTools);
  return allTools.filter((tool) => allowSet.has(tool.name));
}

/**
 * Retrieve the subagent tool profile definition by name.
 */
export function getSubagentProfile(name: string): SubagentToolProfile | undefined {
  return SUBAGENT_PROFILES[name];
}
