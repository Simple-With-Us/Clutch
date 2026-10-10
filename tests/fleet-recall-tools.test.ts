import { describe, expect, it } from "vitest";
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { pathToFileURL } from "node:url";

import { createFleetRecallTools } from "../src/presets/fleet-recall/plugins/fleet-recall-tools.mjs";

/**
 * The regression this file exists for: the preset once passed the tool body to
 * `defineTool` as `run` (the host reads `execute`) and called
 * `ctx.shell.resolve` with an `args` array plus `cwd` (the host takes one
 * `command` string plus `workdir`).  Every recall call then failed with
 * `userExecute is not a function`, and a string-presence test could not see it.
 */

type ToolOptions = {
  name: string;
  execute?: (args: Record<string, unknown>, exec?: unknown) => Promise<unknown>;
  run?: unknown;
  output: { schema: unknown; render: (args: unknown, value: unknown) => unknown };
  parameters: unknown;
};
type Tool = ToolOptions & { name: string };

/** A stand-in for @deepseek-ai/dsh-tools defineTool that mirrors its contract. */
function recordingDefineTool(definitions: ToolOptions[]) {
  return (options: ToolOptions): Tool => {
    definitions.push(options);
    return { ...options, name: options.name };
  };
}

function fakeHost(reply: Partial<{ exitCode: number; stdout: string; stderr: string; timedOut: boolean; aborted: boolean }> = {}) {
  const specs: Record<string, unknown>[] = [];
  const ctx = {
    shell: {
      resolve(request: Record<string, unknown>) {
        specs.push({ ...request });
        return request;
      },
      async run(spec: Record<string, unknown>) {
        void spec;
        return { exitCode: 0, stdout: "", stderr: "", timedOut: false, aborted: false, ...reply };
      },
    },
  };
  return { ctx, specs };
}

/** The tool body returns the schema-validated value; output.render turns it into content. */
function valueOf(out: unknown): string {
  return String((out as { text?: unknown }).text ?? "");
}

function build(reply?: Parameters<typeof fakeHost>[0]) {
  const definitions: ToolOptions[] = [];
  const host = fakeHost(reply);
  const tools = createFleetRecallTools(recordingDefineTool(definitions) as never, host.ctx as never) as unknown as Tool[];
  return { definitions, tools, ...host };
}

describe("fleet-recall preset tools", () => {
  it("defines all three tools through the host's execute contract, never run", () => {
    const { definitions, tools } = build();
    expect(tools.map((tool) => tool.name)).toEqual(["recall_search", "recall_stats", "recall_contribute"]);
    for (const definition of definitions) {
      expect(typeof definition.execute, definition.name).toBe("function");
      expect(definition.run, `${definition.name} must not use the ignored run key`).toBeUndefined();
      expect(typeof definition.output.render, definition.name).toBe("function");
      expect(definition.output.schema, definition.name).toBeTruthy();
    }
  });

  it("renders the validated value into one text content part", () => {
    const { definitions } = build();
    for (const definition of definitions) {
      expect(definition.output.render({}, { text: "hello" }), definition.name).toEqual([{ type: "text", text: "hello" }]);
    }
  });

  it("runs recall_search with one quoted command string plus workdir", async () => {
    const { tools, specs } = build({ stdout: "1 hit" });
    const tool = tools.find((entry) => entry.name === "recall_search")!;
    const out = await tool.execute({ query: "pm2 orphan holds port", limit: 3, app: "fleet", sinceDays: 30 }, {});

    expect(specs).toHaveLength(1);
    const spec = specs[0]!;
    // The host request shape: command string + workdir, never an args array or cwd.
    expect(Object.keys(spec).sort()).toEqual(["command", "timeoutMs", "workdir"]);
    expect(spec.workdir).toBe(homedir());
    expect(spec.command).toContain("'search'");
    expect(spec.command).toContain("'pm2 orphan holds port'");
    expect(spec.command).toContain("'--limit' '3'");
    expect(spec.command).toContain("'--app' 'fleet'");
    expect(spec.command).toContain("'--since-days' '30'");
    expect(valueOf(out)).toBe("1 hit");
  });

  it("shell-quotes a query so metacharacters and quotes stay one argument", async () => {
    const { tools, specs } = build();
    const tool = tools.find((entry) => entry.name === "recall_search")!;
    await tool.execute({ query: "it's $HOME; rm -rf /" }, {});

    const command = String(specs[0]!.command);
    expect(command).toContain("'it'\\''s $HOME; rm -rf /'");
    // The dangerous tokens only ever appear inside the single-quoted argument.
    expect(command.endsWith("'")).toBe(true);
  });

  it("clamps limit into 1..20 instead of forwarding a raw model number", async () => {
    const { tools, specs } = build();
    const tool = tools.find((entry) => entry.name === "recall_search")!;
    await tool.execute({ query: "x", limit: 99 }, {});
    await tool.execute({ query: "x", limit: 0 }, {});
    expect(specs[0]!.command).toContain("'--limit' '20'");
    expect(specs[1]!.command).toContain("'--limit' '1'");
  });

  it("pretty-prints recall_stats JSON and falls back to raw text", async () => {
    const json = build({ stdout: '{"points":7}' });
    const tool = json.tools.find((entry) => entry.name === "recall_stats")!;
    expect(valueOf(await tool.execute({}, {}))).toBe(JSON.stringify({ points: 7 }, null, 2));
    expect(json.specs[0]!.command).toContain("'stats' '--json'");

    const raw = build({ stdout: "not json" });
    const rawTool = raw.tools.find((entry) => entry.name === "recall_stats")!;
    expect(valueOf(await rawTool.execute({}, {}))).toBe("not json");
  });

  it("defaults recall_contribute's app and forwards force", async () => {
    const { tools, specs } = build({ stdout: "stored abc123" });
    const tool = tools.find((entry) => entry.name === "recall_contribute")!;
    await tool.execute({ text: "a".repeat(40), category: "lesson", force: true }, {});
    const command = String(specs[0]!.command);
    expect(command).toContain("'contribute'");
    expect(command).toContain("'--category' 'lesson'");
    expect(command).toContain("'--app' 'fleet'");
    expect(command).toContain("'--force'");
  });

  it("surfaces a non-zero exit as a tool error carrying stderr", async () => {
    const { tools } = build({ exitCode: 1, stderr: "similar lesson already exists: doc-1" });
    const tool = tools.find((entry) => entry.name === "recall_contribute")!;
    await expect(tool.execute({ text: "a".repeat(40), category: "lesson" }, {})).rejects.toThrow(
      /recall_contribute failed \(exit 1\): similar lesson already exists: doc-1/,
    );
  });

  it("propagates the model call's abort signal to the host shell", async () => {
    const { tools, specs } = build();
    const signal = { aborted: false };
    const tool = tools.find((entry) => entry.name === "recall_stats")!;
    await tool.execute({}, { signal });
    expect(specs[0]!.signal).toBe(signal);
  });
});

const DSH_TOOLS = "/Users/jay/apps/clutch-runtime/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai/dsh-tools/lib/index.js";
const hasRealDshTools = existsSync(DSH_TOOLS);

describe.skipIf(!hasRealDshTools)("fleet-recall preset tools under the real defineTool", () => {
  it("compiles its schemas and dispatches every tool", async () => {
    const { defineTool } = (await import(pathToFileURL(DSH_TOOLS).href)) as { defineTool: (options: never) => Tool };
    const host = fakeHost({ stdout: "real ok" });
    const tools = createFleetRecallTools(defineTool as never, host.ctx as never) as unknown as Tool[];

    expect(tools.map((tool) => tool.name)).toEqual(["recall_search", "recall_stats", "recall_contribute"]);
    for (const tool of tools) {
      expect(typeof tool.execute).toBe("function");
    }
    const out = await tools.find((tool) => tool.name === "recall_stats")!.execute({}, {});
    expect(valueOf(out)).toBe("real ok");
  });

  it("rejects malformed arguments before touching the shell", async () => {
    const { defineTool } = (await import(pathToFileURL(DSH_TOOLS).href)) as { defineTool: (options: never) => Tool };
    const host = fakeHost();
    const tools = createFleetRecallTools(defineTool as never, host.ctx as never) as unknown as Tool[];
    const search = tools.find((tool) => tool.name === "recall_search")!;
    await expect(search.execute({}, {})).rejects.toThrow(/invalid arguments/);
    expect(host.specs).toHaveLength(0);
  });
});
