/**
 * DSH model-option resolution — map a picker model onto an option the running
 * `dsh` actually advertises.
 *
 * `dsh` selects a model through the ACP `model` config option, and the option
 * values are opaque route identities: `JSON.stringify([provider, modelId])`.
 * The agent answers `session/set_config_option` with an exact-string lookup in
 * the choices it builds from its current provider catalogs (the same set
 * `session/new` advertises, rebuilt on each set), so a value it does not
 * offer is refused with `unknown model option`, however reasonable it
 * looks.
 *
 * The picker ids BotFleet stores are not the ids `dsh` declares:
 *
 *   - Stock `dsh` 0.1.5-rc.x declares `deepseek-flash` (display name
 *     "DeepSeek-V4.1-Flash") and `deepseek-v4-pro` (display name
 *     "DeepSeek-V4.1-Pro").  The picker's `DeepSeek-V4.1-Flash` is the
 *     *display name*, not an id.
 *   - An owner `~/.dsh/settings.yaml` can replace that list outright
 *     (`llm-deepseek.models`), for example with `deepseek-v4.1-flash`.
 *   - Selections saved before the V4.1 rename say `deepseek-v4-flash`, an id
 *     no current catalog declares.
 *
 * Constructing a value from the picker id therefore fails on every install
 * whose declared spelling differs, and the failure is per machine.  Instead of
 * guessing the spelling, resolve against what this session advertised and send
 * the declared value.  The persisted picker id never changes: translation
 * happens only on the wire.
 *
 * Pure: no filesystem, no network, no dependency on the dsh runtime.
 */

/** One model option the running dsh advertised, decoded. */
export interface DshAdvertisedModel {
  /** The opaque ACP option value to send back, exactly as advertised. */
  readonly value: string;
  /** Provider namespace from the value tuple, else the option group id. */
  readonly provider: string;
  /** The model id the installed dsh declares. */
  readonly id: string;
  /** The display name the installed dsh gave it (the id when it gave none). */
  readonly name: string;
}

/** How a picker model was matched, strongest first.  Reported for diagnostics
 *  and tests; nothing branches on it outside this module. */
export type DshModelMatch = "exact" | "id" | "name" | "alias";

export interface DshResolvedModel extends DshAdvertisedModel {
  readonly match: DshModelMatch;
}

/** The model has no advertised option in a session that offers choices.
 *
 *  Carries its own classification: the caller's error classifier recognises
 *  the class, so the fallback chain treats this as a catalog outage without
 *  re-parsing a message that names arbitrary model ids. */
export class DshModelNotOfferedError extends Error {
  readonly model: string;
  readonly offered: readonly string[];
  /** Providers that declare this model under another route, when any do. */
  readonly elsewhere: readonly string[];

  constructor(model: string, offered: readonly string[], elsewhere: readonly string[] = []) {
    const list = offered.length ? offered.join(", ") : "none";
    // A model declared only under a different provider reads as "not offered"
    // next to a list that contains it, so say which route it is on.
    const hint = elsewhere.length ? `; ${model} is declared only under ${elsewhere.join(", ")}` : "";
    super(`unknown model ${model}: the installed Harness CLI does not offer it (offers: ${list}${hint})`);
    this.name = "DshModelNotOfferedError";
    this.model = model;
    this.offered = offered;
    this.elsewhere = elsewhere;
  }
}

/** Spellings of one DeepSeek model, most current first.  Compared by
 *  {@link aliasKey}, so case, spaces and punctuation do not matter.
 *
 *  Pro keeps `deepseek-v4-pro` as a live member: it is still the declared id
 *  on stock dsh 0.1.5-rc.2 (only its display name gained ".1"), so treating it
 *  as retired would reject an id the CLI serves.  Flash's `deepseek-v4-flash`
 *  is the one genuinely retired spelling; it resolves to whichever Flash the
 *  install declares so selections saved under it keep working. */
const DSH_MODEL_FAMILIES: readonly (readonly string[])[] = [
  ["DeepSeek-V4.1-Flash", "deepseek-flash", "deepseek-v4-flash"],
  ["DeepSeek-V4.1-Pro", "deepseek-v4-pro"],
].map((family) => family.map(aliasKey));

function aliasKey(value: string): string {
  return value.toLowerCase().replace(/[^a-z0-9]+/gu, "");
}

function plainKey(value: string): string {
  return value.trim().toLowerCase();
}

function familyOf(model: string): readonly string[] | undefined {
  const key = aliasKey(model);
  return DSH_MODEL_FAMILIES.find((family) => family.includes(key));
}

/** True when both spellings name the same DeepSeek model, or are the same
 *  string ignoring case.  For a catalog merge to fold a settings row such as
 *  `deepseek-v4.1-flash` onto the static `DeepSeek-V4.1-Flash` row instead of
 *  listing the model twice. */
export function dshSameModel(left: string, right: string): boolean {
  if (plainKey(left) === plainKey(right)) return true;
  const family = familyOf(left);
  return family !== undefined && family.includes(aliasKey(right));
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function decodeValue(value: string): { provider: string; id: string } | null {
  try {
    const decoded: unknown = JSON.parse(value);
    if (
      Array.isArray(decoded) &&
      decoded.length === 2 &&
      typeof decoded[0] === "string" &&
      typeof decoded[1] === "string" &&
      decoded[1].length > 0
    ) {
      return { provider: decoded[0], id: decoded[1] };
    }
  } catch {
    // Not a route tuple; handled by the caller.
  }
  return null;
}

function collect(options: unknown, group: string, into: DshAdvertisedModel[]): void {
  if (!Array.isArray(options)) return;
  for (const entry of options) {
    if (!isRecord(entry)) continue;
    // ACP select options are flat `{value, name}` or grouped
    // `{group, name, options: [...]}`.  dsh advertises one group per provider.
    if (Array.isArray(entry.options)) {
      collect(entry.options, typeof entry.group === "string" ? entry.group : group, into);
      continue;
    }
    if (typeof entry.value !== "string" || !entry.value) continue;
    const tuple = decodeValue(entry.value);
    const id = tuple?.id ?? entry.value;
    into.push({
      value: entry.value,
      provider: tuple?.provider ?? group,
      id,
      name: typeof entry.name === "string" && entry.name.trim() ? entry.name : id,
    });
  }
}

/** The models the session advertised through its `model` config option.
 *
 *  `null` means the reply carries no `model` option at all, which is a stock
 *  ACP agent that reports no state and is a different condition from "offers
 *  nothing".  An empty array means the option is there and lists no model. */
export function parseAdvertisedDshModels(advertised: unknown, configId = "model"): DshAdvertisedModel[] | null {
  if (!Array.isArray(advertised)) return null;
  const option = advertised.find((candidate) => isRecord(candidate) && candidate.id === configId);
  if (!isRecord(option)) return null;
  const models: DshAdvertisedModel[] = [];
  collect(option.options, "", models);
  return models;
}

/** Find the advertised option for a picker model, or `undefined`.
 *
 *  Tiers, strongest first; the first tier with a hit wins, and within a tier
 *  the advertised order does:
 *
 *    1. exact      — the wire value the picker id would have produced
 *    2. id         — the declared id, ignoring case
 *    3. name       — the display name, ignoring case
 *    4. alias      — another spelling of the same DeepSeek model
 *
 *  Tiers 2 to 4 only consider the provider namespace the model belongs to, so
 *  a MiniMax id can never resolve into the DeepSeek group or the reverse.  An
 *  option with no provider information (a non-tuple value in an ungrouped
 *  list) is treated as belonging to every namespace. */
export function matchAdvertisedDshModel(
  model: string,
  provider: string,
  advertised: readonly DshAdvertisedModel[],
): DshResolvedModel | undefined {
  const wanted = JSON.stringify([provider, model]);
  const exact = advertised.find((entry) => entry.value === wanted);
  if (exact) return { ...exact, match: "exact" };

  const scope = advertised.filter((entry) => entry.provider === provider || entry.provider === "");
  const key = plainKey(model);
  const byId = scope.find((entry) => plainKey(entry.id) === key);
  if (byId) return { ...byId, match: "id" };
  const byName = scope.find((entry) => plainKey(entry.name) === key);
  if (byName) return { ...byName, match: "name" };

  const family = familyOf(model);
  if (family) {
    for (const alias of family) {
      const hit =
        scope.find((entry) => aliasKey(entry.id) === alias) ?? scope.find((entry) => aliasKey(entry.name) === alias);
      if (hit) return { ...hit, match: "alias" };
    }
  }
  return undefined;
}

/** Resolve a picker model against a session's advertised config options.
 *
 *  - `undefined`: nothing to resolve against (no `model` option, or one that
 *    lists no model).  The caller keeps its own construction, which is what it
 *    did before this existed.
 *  - a value: the option to send.
 *  - throws {@link DshModelNotOfferedError}: the session offers models and the
 *    picker model is not among them.  `dsh` would refuse any other value with
 *    `unknown model option` after a wasted round trip; failing here names what
 *    it does offer, and never runs a model other than the one picked. */
export function resolveDshModelOption(
  model: string,
  provider: string,
  advertised: unknown,
): DshResolvedModel | undefined {
  const models = parseAdvertisedDshModels(advertised);
  if (!models || models.length === 0) return undefined;
  const match = matchAdvertisedDshModel(model, provider, models);
  if (match) return match;
  // A different provider may declare this very model.  That is a different
  // route (its own credentials, billing and quota), so it is never sent
  // silently in place of the one this bot routes through; it is named in the
  // error instead, because the offered list alone would seem to contain it.
  const key = plainKey(model);
  const elsewhere = [
    ...new Set(
      models
        .filter((entry) => entry.provider && entry.provider !== provider)
        .filter((entry) => plainKey(entry.id) === key || plainKey(entry.name) === key)
        .map((entry) => entry.provider),
    ),
  ];
  throw new DshModelNotOfferedError(
    model,
    models.map((entry) => {
      const route = entry.provider ? `${entry.provider}/${entry.id}` : entry.id;
      return entry.name === entry.id ? route : `${route} (${entry.name})`;
    }),
    elsewhere,
  );
}
