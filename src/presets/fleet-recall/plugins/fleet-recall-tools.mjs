// Fleet recall tools for Clutch / MiniMax.
//
// Registers three Tools (recall_search, recall_stats, recall_contribute)
// that wrap the `recall` CLI at /Users/jay/apps/fleet-rag/recall (linked
// from ~/.local/bin/recall and installed by ai-fleet-coordinator's
// scripts/install-fleet-rag.sh).  The CLI reads Qdrant / TEI / Infisical
// creds itself — no secret value lives in this file or any preset YAML.
//
// Loaded as a relative entry from preset/agent.cordis.yml.  The host
// composition owns `shell` and `tools`; this file does not ship its own
// subprocess primitives (it just calls ctx.shell.run with a spec built
// from JSON tool args), and it registers into a scope-local ToolLayer via
// ctx.tools.register — no root-realm collision.
//
// Two host contracts this file has to match exactly; breaking either one
// fails EVERY call at dispatch time with "userExecute is not a function"
// or a shell that ignores the arguments:
//   - defineTool() reads the tool body from `execute(args, exec)`.  A
//     `run` key is silently ignored (see @deepseek-ai/dsh-tools).
//   - ctx.shell.resolve()/run() take ONE `command` shell string plus
//     `workdir`.  There is no `args` array on the request, and `cwd` is
//     not the field name (see @deepseek-ai/dsh-bash-local and
//     @deepseek-ai/dsh-tool-bash).

import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const CLUTCH_RUNTIME = process.env.CLUTCH_RUNTIME_ROOT || "/Users/jay/apps/clutch-runtime";

const CANDIDATE_TOOL_PATHS = [
  join(CLUTCH_RUNTIME, "node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai/dsh-tools/lib/index.js"),
  join(CLUTCH_RUNTIME, "node_modules/@deepseek-ai/dsh-tools/lib/index.js"),
  "/Users/jay/apps/dsh-runtime/node_modules/@deepseek-ai/dsh-tools/lib/index.js",
];

async function loadDefineTool() {
  for (const cand of CANDIDATE_TOOL_PATHS) {
    if (!existsSync(cand)) continue;
    try {
      const mod = await import(pathToFileURL(cand).href);
      if (mod.defineTool) return mod.defineTool;
    } catch {}
  }
  try {
    const mod = await import("@deepseek-ai/dsh-tools");
    if (mod.defineTool) return mod.defineTool;
  } catch {}
  return null;
}

const resolvedDefineTool = await loadDefineTool();

const RECALL_BIN = process.env.FLEET_RECALL_BIN || "/Users/jay/apps/fleet-rag/recall";
const RECALL_CWD = process.env.FLEET_RECALL_CWD || homedir();
const DEFAULT_LIMIT = 5;
const MAX_LIMIT = 20;
const TIMEOUT_MS = 30_000;

/** Single-quote one argv element for the `bash -c` command the shell service runs. */
function shellQuote(value) {
  return `'${String(value).replace(/'/g, `'\\''`)}'`;
}

function pushFlag(out, key, value) {
  if (value === undefined || value === null || value === false || value === "") return;
  out.push(`--${key}`);
  if (value === true) return;
  const text = String(value);
  out.push(text.startsWith("-") ? `./${text}` : text);
}

function buildArgs(pairs) {
  const out = [];
  for (const [key, value] of pairs) pushFlag(out, key, value);
  return out;
}

function clampLimit(value) {
  const parsed = Math.trunc(Number(value ?? DEFAULT_LIMIT));
  if (!Number.isFinite(parsed)) return DEFAULT_LIMIT;
  return Math.min(Math.max(parsed, 1), MAX_LIMIT);
}

async function runRecall(subArgs, ctx, signal) {
  const shell = ctx.shell;
  if (!shell) throw new Error("fleet-recall-tools needs the host shell service");
  const spec = shell.resolve({
    command: [RECALL_BIN, ...subArgs].map(shellQuote).join(" "),
    workdir: RECALL_CWD,
    timeoutMs: TIMEOUT_MS,
    ...(signal === undefined ? {} : { signal }),
  });
  const result = await shell.run(spec);
  if (result.aborted) throw new Error("recall command aborted");
  if (result.timedOut) throw new Error(`recall command timed out after ${TIMEOUT_MS} ms`);
  return {
    exitCode: typeof result.exitCode === "number" ? result.exitCode : 1,
    stdout: (result.stdout || "").toString(),
    stderr: (result.stderr || "").toString(),
  };
}

/** The model-facing text for one finished recall invocation; throws on a non-zero exit. */
function recallText(out, label) {
  if (out.exitCode !== 0) {
    const detail = (out.stderr || out.stdout || "").trim() || `(exit ${out.exitCode})`;
    throw new Error(`${label} failed (exit ${out.exitCode}): ${detail}`);
  }
  return out.stdout.trim() || out.stderr.trim() || "(recall returned no output)";
}

const OUTPUT = {
  schema: {
    type: "object",
    additionalProperties: false,
    properties: { text: { type: "string", required: true } },
  },
  render: (_args, value) => [{ type: "text", text: value.text }],
};

/**
 * Build the three recall Tools against one `defineTool` implementation and
 * the host context that carries `shell`.  Exported so the tracked test can
 * exercise the definitions without a live DSH host (the module-level
 * resolution above only runs inside a real one).
 * @param defineTool - `defineTool` from @deepseek-ai/dsh-tools.
 * @param ctx - the plugin context; only `ctx.shell` is read.
 * @returns the registry-ready tool definitions.
 */
export function createFleetRecallTools(defineTool, ctx) {
  return [
    defineTool({
      name: "recall_search",
      description:
        "Search the fleet-agents recall corpus for relevant lessons, notes, findings, runbooks, and decisions. " +
        "Returns one hit per document with title, source, score, and excerpt.",
      output: OUTPUT,
      parameters: {
        query: { type: "string", description: "Natural-language query text.", required: true },
        limit: { type: "number", description: `Max hits to return (default ${DEFAULT_LIMIT}).` },
        category: {
          type: "string",
          description: "Optional category filter.",
          enum: ["lesson", "preference", "infrastructure", "decision", "runbook", "finding", "note", "doc"],
        },
        app: { type: "string", description: "Optional app slug filter (e.g. fleet, socratic-trade)." },
        seat: { type: "string", description: "Optional seat tag filter (e.g. MM, CLAUDE, GROK)." },
        source: { type: "string", description: "Optional corpus source filter (board, doc, effort-log, apple-note, ...)." },
        sinceDays: { type: "number", description: "Only content from the last N days." },
      },
      async execute(args, exec) {
        const subArgs = buildArgs([
          ["limit", clampLimit(args.limit)],
          ["category", args.category],
          ["app", args.app],
          ["seat", args.seat],
          ["source", args.source],
          ["since-days", args.sinceDays],
        ]);
        const out = await runRecall(["search", args.query, ...subArgs], ctx, exec?.signal);
        return { text: recallText(out, "recall_search") };
      },
    }),

    defineTool({
      name: "recall_stats",
      description: "Show recall corpus health (total points, per-source, per-app counts) so an agent can judge reachability before searching.",
      output: OUTPUT,
      parameters: {},
      async execute(_args, exec) {
        const out = await runRecall(["stats", "--json"], ctx, exec?.signal);
        const text = recallText(out, "recall_stats");
        try {
          return { text: JSON.stringify(JSON.parse(text), null, 2) };
        } catch {
          return { text };
        }
      },
    }),

    defineTool({
      name: "recall_contribute",
      description:
        "Contribute a reusable lesson, preference, decision, runbook, or infrastructure fact to the fleet recall corpus. " +
        "Refuses near-duplicates and scrubs credentials; pass secrets as files via --file, never as inline text. " +
        "Returns the stored doc id on success.",
      output: OUTPUT,
      parameters: {
        text: {
          type: "string",
          description:
            "Body of the contribution (40..4000 chars). Plain prose, no credentials. " +
            "Use a --file path for log excerpts that might contain values.",
          required: true,
        },
        category: {
          type: "string",
          description: "Category of the contribution.",
          required: true,
          enum: ["lesson", "preference", "infrastructure", "decision", "runbook"],
        },
        app: { type: "string", description: "App slug (default fleet)." },
        seat: { type: "string", description: "Originating seat tag." },
        title: { type: "string", description: "Short title for the contribution." },
        url: { type: "string", description: "Source URL (PR, board item, doc)." },
        force: { type: "boolean", description: "Store even when a near-duplicate already exists (default false)." },
      },
      async execute(args, exec) {
        const subArgs = buildArgs([
          ["category", args.category],
          ["app", args.app ?? "fleet"],
          ["seat", args.seat],
          ["title", args.title],
          ["url", args.url],
          ["force", args.force],
        ]);
        const out = await runRecall(["contribute", args.text, ...subArgs], ctx, exec?.signal);
        return { text: recallText(out, "recall_contribute") };
      },
    }),
  ];
}

export default {
  name: "fleet-recall-tools",
  inject: ["shell", "tools"],
  apply(ctx) {
    if (!resolvedDefineTool) {
      throw new Error("fleet-recall-tools: unable to resolve defineTool from @deepseek-ai/dsh-tools");
    }
    for (const tool of createFleetRecallTools(resolvedDefineTool, ctx)) ctx.tools.register(tool);
  },
};
