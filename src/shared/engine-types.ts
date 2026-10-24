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
