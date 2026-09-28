/**
 * Shared engine contract types for Harness.
 *
 * These mirror the subset of `server/contracts.ts` from BotFleet that the
 * driver / bridge code in this repo needs.  The canonical runtime lives in
 * BotFleet; this file is the type-level contract so Harness typechecks
 * in isolation.  Keep the two lists in sync when adding a code.
 */

export type EffortLevel = "none" | "low" | "medium" | "high" | "max";

export interface ModelCatalog {
  default: string;
  options: Array<{
    id: string;
    label: string;
    contextWindow?: number;
    custom?: boolean;
    badge?: string;
    badgeTitle?: string;
  }>;
}

export type ProviderErrorCode =
  | "invalid_credentials"
  | "inactive_subscription"
  | "quota_or_region_restriction"
  | "upstream_outage"
  | "model_catalog_outage"
  | "unknown";
