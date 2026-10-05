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
// subprocess primitives (it just calls ctx.shell.run with an argv built
// from JSON tool args), and it registers into a scope-local ToolLayer via
// ctx.tools.register — no root-realm collision.

import { existsSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const CLUTCH_RUNTIME = process.env.CLUTCH_RUNTIME_ROOT || "/Users/jay/apps/clutch-runtime";

const CANDIDATE_TOOL_PATHS = [
  join(CLUTCH_RUNTIME, "node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai/dsh-tools/lib/index.js"),
  join(CLUTCH_RUNTIME, "node_modules/@deepseek-ai/dsh-tools/lib/index.js"),
  "/Users/jay/apps/dsh-runtime/node_modules/@deepseek-ai/dsh-tools/lib/index.js",
];

let defineTool = null;
for (const cand of CANDIDATE_TOOL_PATHS) {
  if (existsSync(cand)) {
    try {
      const mod = await import(pathToFileURL(cand).href);
      if (mod.defineTool) {
        defineTool = mod.defineTool;
        break;
      }
    } catch {}
  }
}

if (!defineTool) {
  try {
    const mod = await import("@deepseek-ai/dsh-tools");
    if (mod.defineTool) defineTool = mod.defineTool;
  } catch {}
}

if (!defineTool) {
  throw new Error("fleet-recall-tools: unable to resolve defineTool from @deepseek-ai/dsh-tools");
}

const RECALL_BIN = "/Users/jay/apps/fleet-rag/recall";
const DEFAULT_LIMIT = 5;
const TIMEOUT_MS = 30_000;

function quoteIfNeeded(value) {
  return value.startsWith("-") ? `./${value}` : value;
}

function pushFlag(out, key, value) {
  if (value === undefined || value === null || value === false || value === "") return;
  out.push(`--${key}`);
  if (value === true) return;
  out.push(quoteIfNeeded(String(value)));
}

function buildArgs(pairs) {
  const out = [];
  for (const [key, value] of pairs) pushFlag(out, key, value);
  return out;
}

async function runRecall(subArgs, ctx) {
  const shell = ctx.shell;
  if (!shell) throw new Error("fleet-recall-tools needs the host shell service");
  const spec = shell.resolve({
    command: RECALL_BIN,
    args: subArgs,
    cwd: "/Users/jay",
    timeoutMs: TIMEOUT_MS,
  });
  const result = await shell.run(spec);
  return {
    exitCode: result.exitCode,
    stdout: (result.stdout || "").toString(),
    stderr: (result.stderr || "").toString(),
  };
}

function textResult(value, isError = false) {
  const text = typeof value === "string" ? value : JSON.stringify(value, null, 2);
  return { content: [{ type: "text", text }], isError };
}

function exitResult(out) {
  const ok = out.exitCode === 0;
  return textResult(ok ? out.stdout : (out.stderr || out.stdout || `(exit ${out.exitCode})`));
}

export default {
  name: "fleet-recall-tools",
  inject: ["shell", "tools"],
  apply(ctx) {
    ctx.tools.register(defineTool({
      name: "recall_search",
      description:
        "Search the fleet-agents recall corpus for relevant lessons, notes, findings, runbooks, and decisions. " +
        "Returns one hit per document with title, source, score, and excerpt.",
      output: {
        schema: { type: "object", additionalProperties: true },
        render: (_args, value) => value?.content ?? [],
      },
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
      async run(args) {
        const subArgs = buildArgs([
          ["limit", args.limit ?? DEFAULT_LIMIT],
          ["category", args.category],
          ["app", args.app],
          ["seat", args.seat],
          ["source", args.source],
          ["since-days", args.sinceDays],
        ]);
        const out = await runRecall(["search", args.query, ...subArgs], ctx);
        return exitResult(out);
      },
    }));

    ctx.tools.register(defineTool({
      name: "recall_stats",
      description: "Show recall corpus health (total points, per-source, per-app counts) so an agent can judge reachability before searching.",
      output: {
        schema: { type: "object", additionalProperties: true },
        render: (_args, value) => value?.content ?? [],
      },
      parameters: {},
      async run(args) {
        const out = await runRecall(["stats", "--json"], ctx);
        if (out.exitCode === 0 && out.stdout.trim()) {
          try {
            const parsed = JSON.parse(out.stdout);
            return textResult(parsed);
          } catch {
            // fall through to raw stdout
          }
        }
        return exitResult(out);
      },
    }));

    ctx.tools.register(defineTool({
      name: "recall_contribute",
      description:
        "Contribute a reusable lesson, preference, decision, runbook, or infrastructure fact to the fleet recall corpus. " +
        "Refuses near-duplicates and scrubs credentials; pass secrets as files via --file, never as inline text. " +
        "Returns the stored doc id on success.",
      output: {
        schema: { type: "object", additionalProperties: true },
        render: (_args, value) => value?.content ?? [],
      },
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
      async run(args) {
        const subArgs = buildArgs([
          ["category", args.category],
          ["app", args.app ?? "fleet"],
          ["seat", args.seat],
          ["title", args.title],
          ["url", args.url],
          ["force", args.force],
        ]);
        const out = await runRecall(["contribute", args.text, ...subArgs], ctx);
        return exitResult(out);
      },
    }));
  },
};
