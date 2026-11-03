import { z } from "zod";

export const MuseLaunchOptionsSchema = z.object({
  yolo: z.boolean(),
  contributorMode: z.boolean(),
}).strict();

export type MuseLaunchOptions = z.infer<typeof MuseLaunchOptionsSchema>;

export function museLaunchArguments(options: MuseLaunchOptions): string[] {
  return [
    "--contributor-mode", options.contributorMode ? "on" : "off",
    ...(options.yolo ? ["--disable-sandbox", "--trust-workspace"] : []),
  ];
}

export function sameMuseLaunchOptions(a: MuseLaunchOptions, b: MuseLaunchOptions): boolean {
  return a.yolo === b.yolo && a.contributorMode === b.contributorMode;
}

const CONTRIBUTOR_IDS = new Set([
  "muse-spark-1.3-contributor",
  "muse-wonder-1.0-contributor",
  "muse-wonder-full-1.0-contributor",
]);

function museModelId(value: unknown): string | null {
  if (typeof value !== "string" || value.length > 512) return null;
  if (!value.startsWith("muse-model:")) return value;
  try {
    // Provider and profile selectors are opaque; only the model ID is ours to interpret.
    const parsed = z.tuple([z.unknown(), z.unknown(), z.string()]).safeParse(JSON.parse(decodeURIComponent(value.slice("muse-model:".length))));
    return parsed.success ? parsed.data[2] : null;
  } catch {
    return null;
  }
}

/** Both supported ACP spellings identify the same allowlisted picker model. */
export function museContributorModelId(value: unknown): string | null {
  const id = museModelId(value);
  return id && CONTRIBUTOR_IDS.has(id) ? id : null;
}

/** The effort restriction also covers contributor IDs outside the picker allowlist. */
export function isMuseContributorModel(value: unknown): boolean {
  return museModelId(value)?.endsWith("-contributor") ?? false;
}

export function contributorDefaultModel(currentModel?: string): string {
  const exact = museContributorModelId(currentModel);
  if (exact) return exact;
  if (currentModel && CONTRIBUTOR_IDS.has(`${currentModel}-contributor`)) return `${currentModel}-contributor`;
  return "muse-spark-1.3-contributor";
}

export class MuseSettingsError extends Error {
  constructor(reason: "busy" | "mode" | "model" | "effort" | "restart" | "native") {
    super({
      busy: "Finish other Muse turns before changing YOLO or Contributor Mode.",
      mode: "This Muse connection could not apply the selected approval mode.",
      model: "Muse could not select the requested model.\u00A0 No prompt was sent.",
      effort: "Muse could not select the requested effort.\u00A0 No prompt was sent.",
      restart: "Muse could not restart with the selected settings.\u00A0 Try again after its current work finishes.",
      native: "These settings require native Muse ACP.\u00A0 Choose the native backend or update Muse Code.",
    }[reason]);
  }
}
