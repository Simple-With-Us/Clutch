/**
 * ACP support-shape types — pure type definitions for the driver support
 * record that BotFleet's `acp/core.ts` consumes via `createAcpDriver(support)`.
 *
 * BotFleet owns the runtime (the spawn wrapper, the JSON-RPC client, the
 * MCP mount assembler); Harness owns the engine-specific support shape
 * (catalog, error classifier, version gate, etc.).  Both sides typecheck
 * against this interface, so drift between them surfaces at compile time.
 *
 * Long-term: lift the ACP core into Harness too.  See
 * `docs/decisions/0002-acp-core-stays-in-botfleet.md`.
 */

import type { ModelCatalog, EffortLevel } from "./contracts.ts";

/** A single config option the harness can set on a session.  Mirrors
 * BotFleet's `AcpConfigOption`; defined here so types align across repos. */
export interface AcpConfigOption {
  readonly id: string;
  readonly currentValue?: unknown;
}

export interface AcpInstallInstructions {
  readonly command: { darwin: string; linux: string; win32: string };
  readonly docsUrl?: string;
  readonly needsNode?: boolean;
}

export interface AcpConfig {
  readonly cli: string;
  readonly env?: Record<string, string | undefined>;
}

export interface AcpTurn {
  readonly system?: string;
  readonly text: string;
  readonly model?: string;
  readonly effort?: EffortLevel;
  readonly integrations?: Record<string, unknown>;
}

export interface AcpSelectModel {
  readonly configId: string;
  readonly valueForModel: (model: string) => string;
  readonly modelForValue: (value: unknown) => string | null;
}

export interface AcpConfigureInput {
  readonly request: (method: string, params: Record<string, unknown>) => Promise<unknown>;
  readonly sessionId: string;
  readonly turn: AcpTurn;
}

export interface AcpSupport {
  readonly driverKind: string;
  readonly displayName: string;
  readonly images?: boolean;
  readonly models: ModelCatalog;
  readonly resolveModels?: (env: Record<string, string | undefined>) => ModelCatalog;
  readonly effortLevels?: readonly EffortLevel[];
  /**
   * Per-model effort-level overrides, keyed by model id.  When a model id
   * appears here its entry wins over the driver-wide `effortLevels`; models
   * absent from the map fall back to `effortLevels`.  Lets a driver advertise
   * different reasoning budgets per model (e.g. MiniMax-M3 vs M2.7).
   */
  readonly perModelEffortLevels?: Readonly<Record<string, readonly EffortLevel[]>>;
  readonly mcpServers?: boolean;
  readonly defaultCli: string;
  readonly nativeSource: string;
  readonly loginNote?: string;
  readonly install?: AcpInstallInstructions;
  readonly spawnArgs: (config: AcpConfig, turn: Pick<AcpTurn, "integrations">) => readonly string[];
  readonly resumeMethod?: string;
  readonly selectModel?: AcpSelectModel;
  readonly versionCompatibilityReason?: (version: string, config: AcpConfig) => string | null;
  readonly configureSession?: (input: AcpConfigureInput) => Promise<void>;
  readonly transformEnv?: (env: Record<string, string | undefined>) => void;
  readonly classifyError?: (error: unknown) => string | undefined;
  readonly credentialEnv?: readonly string[];
  readonly pickAuthMethod?: (methods: readonly unknown[]) => unknown;
  readonly authFailure?: "continue" | "abort";
  readonly isAuthenticated?: (env: Record<string, string | undefined>) => boolean;
  readonly buildPromptText?: (turn: AcpTurn) => string;
}
