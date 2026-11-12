export interface MuseSessionModelMetadata {
  provider?: string;
  model?: string;
}

/** Decode model routing without interpreting opaque provider/profile selectors. */
export function decodeMuseModelTuple(value: unknown): [unknown, unknown, string] | null {
  if (typeof value !== "string" || value.length > 512 || !value.startsWith("muse-model:")) return null;
  const payload = value.slice("muse-model:".length);
  try {
    let tuple: unknown;
    try { tuple = JSON.parse(payload); }
    catch { tuple = JSON.parse(decodeURIComponent(payload)); }
    return Array.isArray(tuple) && tuple.length === 3 && typeof tuple[2] === "string"
      ? tuple as [unknown, unknown, string] : null;
  } catch {
    return null;
  }
}

/** Read exact model identity from the Muse ACP model config option. */
export function modelMetadataFromMuseConfigOptions(value: unknown): MuseSessionModelMetadata | null {
  if (!Array.isArray(value)) return null;
  const option = value.find((candidate) =>
    typeof candidate === "object" && candidate !== null && (candidate as Record<string, unknown>).id === "model",
  ) as Record<string, unknown> | undefined;
  if (!option || typeof option.currentValue !== "string") return null;

  const currentValue = option.currentValue.trim();
  if (!currentValue) return null;
  if (!currentValue.startsWith("muse-model:")) return { model: currentValue };

  const tuple = decodeMuseModelTuple(currentValue);
  if (!tuple) return null;
  const provider = typeof tuple[0] === "string" && tuple[0].trim() ? tuple[0].trim() : undefined;
  const model = typeof tuple[2] === "string" && tuple[2].trim() ? tuple[2].trim() : undefined;
  if (!provider && !model) return null;
  return {
    ...(provider ? { provider } : {}),
    ...(model ? { model } : {}),
  };
}
