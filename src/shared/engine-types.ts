/**
 * The engine identifiers Clutch's sidecar can run, and their display names.
 *
 * Kept in its own module so the chat bridge and the engine catalog can both
 * name engines without importing each other.
 */
export type Engine = "deepseek" | "minimax" | "mcode" | "muse";

/** The engines a phone or Mac can pick, in the order the picker shows them. */
export const ENGINE_ORDER: readonly Engine[] = ["deepseek", "minimax", "mcode", "muse"];

/** Owner-facing names for the engines. */
export const ENGINE_LABELS: Record<Engine, string> = {
  deepseek: "DeepSeek",
  minimax: "MiniMax",
  mcode: "MiniMax Code",
  muse: "Muse Code",
};

/** True when the id names an engine Clutch can run. */
export function isEngine(value: unknown): value is Engine {
  return typeof value === "string" && (ENGINE_ORDER as readonly string[]).includes(value);
}

/**
 * The engines the dsh host runs, and whose threads it owns.
 *
 * Their threads live in the host's session log under `$CLUTCH_HOME/dsh`, the
 * same store the ACP bridge reads, so the sidecar reads and resumes them
 * through the host rather than through a bridge of its own.  The code engines
 * keep their own stores and speak ACP directly.
 */
export const DSH_HOSTED_ENGINES: readonly Engine[] = ["deepseek", "minimax"];

/** True when the dsh host owns this engine's threads. */
export function isDshHostedEngine(value: unknown): value is Engine {
  return typeof value === "string" && (DSH_HOSTED_ENGINES as readonly string[]).includes(value);
}
