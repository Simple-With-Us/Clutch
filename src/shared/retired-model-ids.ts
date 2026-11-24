// Rewrite retired model ids that still sit in saved selections.  Dropping
// a row from a catalog only hides it in the picker — a saved selection
// (a BotFleet chain, a profile's agent-default-model, a stored session
// model) keeps naming the old id, and a turn that reaches it burns a spawn
// on an unknown model option.  Map those ids onto the live replacement so
// the send path never hands a dead spelling to an engine.  The same map
// is the authority for the paths that meet an id outside saved selections:
// catalog discovery drops rows it names (a host CLI's live list keeps
// serving a retired model after the shipped catalogs drop it).
//
// This mirrors BotFleet's server/retired-model-ids.ts (BF#2166), narrowed
// to the retirements this repo's own catalogs carried.  Two spellings are
// deliberately absent: `DeepSeek-V4.1-Pro` is a live picker id here (it
// folds onto the wire id `deepseek-v4-pro` in dsh/acp/model-options.ts),
// and `MiniMax-M2.7` is still a live row in the MiniMax catalog.

/** Exact retired picker ids → the live catalog id that replaced them.
 *  `MiniMax-M3` was retired fleet-wide in favour of M3.1 (owner ruling,
 *  2026-11-21/22: MiniMax is M3.1 only).  The M3.1 Flash row was renamed,
 *  not retired: MiniMax dropped the `-Preview` suffix, and every engine
 *  that serves M3.1 now answers to `MiniMax-M3.1-Flash`.
 *  `deepseek-v4-flash` is the retired wire spelling of the same Flash
 *  model — dsh/acp/model-options.ts calls it "the one genuinely retired
 *  spelling" — and folds onto the declared picker id. */
const RETIRED_MODEL_REPLACEMENTS: Readonly<Record<string, string>> = {
  "MiniMax-M3": "MiniMax-M3.1-Flash",
  "MiniMax-M3.1-Flash-Preview": "MiniMax-M3.1-Flash",
  "deepseek-v4-flash": "DeepSeek-V4.1-Flash",
};

/** Live replacement for a retired model id, or the input when it is still
 *  current.  The bare id must match exactly — MiniMax-M3.1-Flash must not
 *  match the retired stem.  A provider-qualified spelling
 *  (`minimax-coding-plan/MiniMax-M3`, as a discovered catalog spells the
 *  models it routes) names the bare id after its last `/`, but only under
 *  a qualifier that is itself a route to these vendors' models (see
 *  RETIRED_MODEL_QUALIFIERS): the retired model is the same product on
 *  those routes, so the match runs on that bare id and the replacement
 *  keeps the qualifier, landing on the same route's live row
 *  (`minimax-coding-plan/MiniMax-M3.1-Flash`).  Any other qualifier is a
 *  different route whose trailing segment merely shares the text, and
 *  its ids are left alone. */
export function rewriteRetiredModelId(model: string): string {
  const bare = retiredBareId(model);
  if (bare === null) return model;
  return model.slice(0, model.length - bare.length) + RETIRED_MODEL_REPLACEMENTS[bare]!;
}

/** True when the model id is one this repo has retired from every catalog
 *  that used to advertise it — bare, or provider-qualified under a known
 *  route qualifier with a retired bare id after the last `/`. */
export function isRetiredModelId(model: string): boolean {
  return retiredBareId(model) !== null;
}

/** Provider qualifiers under which a qualified spelling names one of the
 *  retired models themselves: OpenCode's MiniMax Coding Plan route
 *  (`minimax-coding-plan/MiniMax-M3`) and the DSH engine's provider
 *  spelling (`minimax/MiniMax-M3.1-Flash`). */
const RETIRED_MODEL_QUALIFIERS: ReadonlySet<string> = new Set(["minimax", "minimax-coding-plan"]);

/** The retired bare id a model id names, or null when it names none:
 *  the id itself, or — under a known route qualifier — the segment
 *  after its last `/`. */
function retiredBareId(model: string): string | null {
  const slash = model.lastIndexOf("/");
  const bare = model.slice(slash + 1);
  if (!Object.prototype.hasOwnProperty.call(RETIRED_MODEL_REPLACEMENTS, bare)) return null;
  if (slash !== -1 && !RETIRED_MODEL_QUALIFIERS.has(model.slice(0, slash))) return null;
  return bare;
}
