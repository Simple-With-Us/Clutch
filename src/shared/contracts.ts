/**
 * Shared engine contract types for Clutch.
 *
 * These mirror the subset of `server/contracts.ts` from BotFleet that the
 * driver / bridge code in this repo needs.  The canonical runtime lives in
 * BotFleet; this file is the type-level contract so Clutch typechecks
 * in isolation.  Keep the two lists in sync when adding a code.
 */

/** Reasoning-effort levels, ascending.  Same union as BotFleet's
 * `EFFORT_LEVELS`; each driver declares the subset its engine takes. */
export type EffortLevel = "none" | "low" | "medium" | "high" | "xhigh" | "max";

export interface ModelCatalog {
  default: string;
  options: Array<{
    id: string;
    label: string;
    contextWindow?: number;
    custom?: boolean;
    badge?: string;
    badgeTitle?: string;
    /**
     * Whether this model can interpret a referenced image.
     *
     * Images are never sent as binary content blocks: an ACP turn is a single
     * text prompt, and an attachment rides as a `<attached-image path="…" />`
     * tag that the agent opens with its own read tool.  So this flag is about
     * what the model does once the bytes are in front of it, not about whether
     * the transport could carry them.  Absent means "not established" and a
     * surface should fall back to the engine-wide answer.
     */
    images?: boolean;
  }>;
}

export type ProviderErrorCode =
  | "invalid_credentials"
  | "inactive_subscription"
  | "quota_or_region_restriction"
  | "upstream_outage"
  | "model_catalog_outage"
  | "unknown";
