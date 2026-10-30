import { execFileSync } from "node:child_process";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { afterEach, describe, expect, it } from "vitest";

import { bundledEngineDir, loadEnginePlugins } from "../src/shared/engines/index.ts";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const LAUNCHER = join(ROOT, "scripts", "muse-code-acp.sh");

const scratchDirs: string[] = [];

function scratch(): string {
  const dir = mkdtempSync(join(tmpdir(), "clutch-muse-"));
  scratchDirs.push(dir);
  return dir;
}

afterEach(() => {
  while (scratchDirs.length > 0) {
    rmSync(scratchDirs.pop() as string, { recursive: true, force: true });
  }
});

/** Load the shipped plugin from the repo's own `engines/` directory. */
async function loadMuse() {
  const result = await loadEnginePlugins({ dirs: [bundledEngineDir()] });
  expect(result.problems, JSON.stringify(result.problems, null, 2)).toEqual([]);
  const plugin = result.plugins.find((candidate) => candidate.id === "muse-code");
  expect(plugin, "muse-code plugin is discoverable").toBeDefined();
  return plugin!;
}

describe("the shipped Muse Code plugin", () => {
  it("loads from engines/ as a declarative manifest", async () => {
    const plugin = await loadMuse();
    expect(plugin.kind).toBe("manifest");
    expect(plugin.origin).toBe("bundled");
    expect(plugin.file.endsWith("engines/muse-code.engine.json")).toBe(true);
  });

  it("describes the native ACP shape, not a dsh profile", async () => {
    const { support } = await loadMuse();
    expect(support.driverKind).toBe("museCodeAgent");
    expect(support.displayName).toBe("Muse Code");
    // Current Muse builds speak ACP v1 directly.  Recording that here keeps a
    // future reader from routing Muse through dsh or adding a Python bridge.
    expect(support.nativeSource).toBe("muse.acp");
    expect(support.defaultCli).toBe("muse-code-acp.sh");
    expect(support.resumeMethod).toBe("session/load");
  });

  it("carries the capabilities the adapter advertised on initialize", async () => {
    const { support } = await loadMuse();
    // promptCapabilities.image and mcpCapabilities.http were both true on the
    // live 0.7.0 handshake.
    expect(support.images).toBe(true);
    expect(support.mcpServers).toBe(true);
  });

  it("advertises only effort levels Clutch's shared contract can carry", async () => {
    const { support } = await loadMuse();
    // Muse offers none|minimal|low|medium|high|xhigh|ultra.  `minimal` and
    // `ultra` have no EffortLevel equivalent, and `max` is not offered, so the
    // plugin advertises the intersection rather than inventing a mapping.
    expect(support.effortLevels).toEqual(["none", "low", "medium", "high", "xhigh"]);
  });

  it("names the Muse credential and backend-selection knobs", async () => {
    const { support } = await loadMuse();
    expect(support.credentialEnv).toContain("META_API_KEY");
    expect(support.credentialEnv).toContain("MUSE_CODE_EXECUTABLE");
    expect(support.credentialEnv).toContain("MUSE_CODE_ACP_BACKEND");
    expect(support.credentialEnv).toContain("MUSE_EXPERIMENTAL_ACP");
  });

  it("leaves authentication to the selected ACP runtime", async () => {
    const { support } = await loadMuse();
    expect(support.pickAuthMethod).toBeUndefined();
    expect(support.authFailure).toBe("continue");
    expect(support.isAuthenticated).toBeUndefined();
  });

  it("maps the model onto the encoded wire value the adapter advertised", async () => {
    const { support } = await loadMuse();
    const select = support.selectModel!;
    expect(select.configId).toBe("model");
    // Captured live from @bex-co/muse-code-acp 0.7.0: the value is
    // URL-encoded JSON, which is why this is an exact map and not a template.
    const wire = 'muse-model:%5B%22meta%22%2Cnull%2C%22muse-spark-1.3-contributor%22%5D';
    expect(select.valueForModel("muse-spark-1.3-contributor")).toBe(wire);
    expect(select.modelForValue(wire)).toBe("muse-spark-1.3-contributor");
    // Preferred over the exact map, because the host may publish a richer one.
    expect(select.valueForModel("muse-spark-1.3-contributor", "host-advertised")).toBe("host-advertised");
  });

  it("has a default model that is actually in its catalog", async () => {
    const { support } = await loadMuse();
    const ids = support.models.options.map((option) => option.id);
    expect(ids).toContain(support.models.default);
  });

  it("describes model availability without claiming that login expands the catalog", async () => {
    const { support } = await loadMuse();
    const [option] = support.models.options;
    expect(option!.badgeTitle).toMatch(/configured model catalog/);
    expect(option!.badgeTitle).toMatch(/Signing in does not expand the model list/);
    expect(option!.badgeTitle).toMatch(/installed Muse runtime and account/);
  });

  it("tells the operator about native ACP and service-user login", async () => {
    const { support } = await loadMuse();
    expect(support.loginNote).toMatch(/muse acp/);
    expect(support.loginNote).toMatch(/muse login/);
  });

  it("classifies a missing Meta key as invalid credentials", async () => {
    const { support } = await loadMuse();
    expect(support.classifyError!(new Error("muse: not logged in, run `muse login`"))).toBe("invalid_credentials");
    expect(support.classifyError!(new Error("service unavailable"))).toBe("upstream_outage");
    expect(support.classifyError!(new Error("who knows"))).toBeUndefined();
  });

  it("installs the adapter with npm and says it needs Node", async () => {
    const { support } = await loadMuse();
    expect(support.install!.command.darwin).toContain("@bex-co/muse-code-acp");
    expect(support.install!.needsNode).toBe(true);
  });
});

describe("the Muse Code launcher", () => {
  it("is executable and keeps stdout clean for JSON-RPC", () => {
    const source = readFileSync(LAUNCHER, "utf8");
    expect(source.startsWith("#!/usr/bin/env bash")).toBe(true);
    // Every diagnostic in the script must go to stderr; stdout carries ACP.
    expect(source).not.toMatch(/^\s*echo\s/m);
  });

  it("stays out of the DSH engine home, like grok", () => {
    // Muse Code is not the DSH engine; sourcing clutch-env.sh would create and
    // force an engine home it never uses.
    expect(readFileSync(LAUNCHER, "utf8")).not.toMatch(/^\s*(source|\.)\s+.*clutch-env\.sh/m);
  });

  it("prefers native ACP when the installed Muse binary proves support", () => {
    const stub = scratch();
    const muse = join(stub, "muse");
    writeFileSync(
      muse,
      '#!/usr/bin/env bash\nif [ "$1" = acp ] && [ "${2:-}" = --help ]; then exit 0; fi\nprintf "NATIVE gate=%s args=%s\\n" "$MUSE_EXPERIMENTAL_ACP" "$*"\n',
    );
    chmodSync(muse, 0o755);

    const started = Date.now();
    const out = execFileSync(LAUNCHER, ["--trust-workspace"], {
      env: {
        PATH: `${stub}:${process.env.PATH ?? ""}`,
        HOME: stub,
      },
      encoding: "utf8",
    });
    expect(out).toContain("NATIVE gate=on");
    expect(out).toContain("args=acp --trust-workspace");
    expect(Date.now() - started).toBeLessThan(2_000);
  });

  it("routes Darwin native ACP through the installed GUI helper", () => {
    const stub = scratch();
    const app = join(stub, "Clutch.app");
    const helperApp = join(app, "Contents", "Helpers", "ClutchMuseACP.app");
    const helperExecutable = join(helperApp, "Contents", "MacOS", "ClutchMuseACP");
    mkdirSync(dirname(helperExecutable), { recursive: true });
    writeFileSync(helperExecutable, "fixture helper");
    chmodSync(helperExecutable, 0o755);
    const muse = join(stub, "muse");
    writeFileSync(muse, '#!/usr/bin/env bash\n[ "$1" = acp ] && [ "${2:-}" = --help ] && exit 0\nprintf "NATIVE args=%s\\n" "$*"\n');
    chmodSync(muse, 0o755);
    const uname = join(stub, "uname");
    writeFileSync(uname, '#!/usr/bin/env bash\nprintf "Darwin\\n"\n');
    chmodSync(uname, 0o755);
    const python = join(stub, "python3");
    writeFileSync(python, '#!/usr/bin/env bash\nprintf "BROKER\\n"\nprintf "%s\\n" "$@"\n');
    chmodSync(python, 0o755);

    const out = execFileSync(LAUNCHER, ["--trust-workspace"], {
      env: { PATH: `${stub}:/usr/bin:/bin`, HOME: stub, CLUTCH_MAC_APP: app },
      encoding: "utf8",
    });
    expect(out).toContain("BROKER");
    expect(out).toContain(join(ROOT, "bridges", "muse", "gui-acp.py"));
    expect(out).toContain(helperApp);
    expect(out).toContain(muse);
    expect(out).toContain("--trust-workspace");
    expect(out).not.toContain("NATIVE");
  });

  it("keeps native ACP direct when META_API_KEY is set or the helper is absent", () => {
    const stub = scratch();
    const app = join(stub, "Clutch.app");
    mkdirSync(app, { recursive: true });
    const muse = join(stub, "muse");
    writeFileSync(muse, '#!/usr/bin/env bash\n[ "$1" = acp ] && [ "${2:-}" = --help ] && exit 0\nprintf "NATIVE args=%s\\n" "$*"\n');
    chmodSync(muse, 0o755);
    const uname = join(stub, "uname");
    writeFileSync(uname, '#!/usr/bin/env bash\nprintf "Darwin\\n"\n');
    chmodSync(uname, 0o755);
    const python = join(stub, "python3");
    writeFileSync(python, '#!/usr/bin/env bash\nprintf "BROKER\\n"\n');
    chmodSync(python, 0o755);
    const base = { PATH: `${stub}:/usr/bin:/bin`, HOME: stub, CLUTCH_MAC_APP: app };

    const withApiKey = execFileSync(LAUNCHER, ["--flag"], {
      env: { ...base, META_API_KEY: "test-key-placeholder" },
      encoding: "utf8",
    });
    expect(withApiKey).toContain("NATIVE args=acp --flag");
    expect(withApiKey).not.toContain("BROKER");

    const withoutHelper = execFileSync(LAUNCHER, ["--flag"], { env: base, encoding: "utf8" });
    expect(withoutHelper).toContain("NATIVE args=acp --flag");
    expect(withoutHelper).not.toContain("BROKER");
  });

  it("falls back to the adapter when the installed Muse binary lacks native ACP", () => {
    const stub = scratch();
    const adapter = join(stub, "fake-adapter");
    const muse = join(stub, "muse");
    writeFileSync(adapter, '#!/usr/bin/env bash\nprintf "ADAPTER host=%s args=%s\\n" "$MUSE_CODE_EXECUTABLE" "$*"\n');
    writeFileSync(muse, '#!/usr/bin/env bash\n[ "$1" = acp ] && exit 5\nexit 0\n');
    chmodSync(adapter, 0o755);
    chmodSync(muse, 0o755);

    const out = execFileSync(LAUNCHER, ["--serve", "--flag"], {
      env: {
        PATH: `${stub}:${process.env.PATH ?? ""}`,
        HOME: stub,
        MUSE_CODE_ACP_BIN: adapter,
      },
      encoding: "utf8",
    });
    expect(out).toContain(`host=${muse}`);
    expect(out).toContain("args=--serve --flag");
  });

  it("prefers an explicit MUSE_CODE_EXECUTABLE over PATH discovery", () => {
    const stub = scratch();
    const adapter = join(stub, "fake-adapter");
    const muse = join(stub, "muse");
    const pinned = join(stub, "pinned-muse");
    writeFileSync(adapter, '#!/usr/bin/env bash\nprintf "host=%s\\n" "$MUSE_CODE_EXECUTABLE"\n');
    writeFileSync(muse, "#!/usr/bin/env bash\nexit 0\n");
    writeFileSync(pinned, "#!/usr/bin/env bash\nexit 0\n");
    chmodSync(adapter, 0o755);
    chmodSync(muse, 0o755);
    chmodSync(pinned, 0o755);

    const out = execFileSync(LAUNCHER, [], {
      env: {
        PATH: `${stub}:${process.env.PATH ?? ""}`,
        HOME: stub,
        MUSE_CODE_ACP_BIN: adapter,
        MUSE_CODE_ACP_BACKEND: "adapter",
        MUSE_CODE_EXECUTABLE: pinned,
      },
      encoding: "utf8",
    });
    expect(out.trim()).toBe(`host=${pinned}`);
  });

  it("lets an operator require the native backend", () => {
    const stub = scratch();
    const muse = join(stub, "muse");
    writeFileSync(muse, '#!/usr/bin/env bash\n[ "$1" = acp ] && exit 5\nexit 0\n');
    chmodSync(muse, 0o755);

    expect(() => execFileSync(LAUNCHER, [], {
      env: {
        PATH: `${stub}:${process.env.PATH ?? ""}`,
        HOME: stub,
        MUSE_CODE_ACP_BACKEND: "native",
      },
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
    })).toThrow(/native ACP is unavailable/);
  });

  it("bounds a native capability probe that never answers", () => {
    const stub = scratch();
    const muse = join(stub, "muse");
    writeFileSync(muse, '#!/usr/bin/env bash\nif [ "$1" = acp ] && [ "${2:-}" = --help ]; then trap "" TERM; while :; do sleep 1; done; fi\n');
    chmodSync(muse, 0o755);
    const started = Date.now();

    expect(() => execFileSync(LAUNCHER, [], {
      env: {
        PATH: `${stub}:${process.env.PATH ?? ""}`,
        HOME: stub,
        MUSE_CODE_ACP_BACKEND: "native",
      },
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
      timeout: 10_000,
    })).toThrow(/native ACP is unavailable/);
    expect(Date.now() - started).toBeLessThan(8_000);
  }, 12_000);

  it("explains the missing adapter instead of failing silently", () => {
    const stub = scratch();
    const muse = join(stub, "muse");
    writeFileSync(muse, '#!/usr/bin/env bash\n[ "$1" = acp ] && exit 5\nexit 0\n');
    chmodSync(muse, 0o755);
    let message = "";
    try {
      execFileSync(LAUNCHER, [], {
        // The launcher's own search list is replaced with an empty one, so a
        // machine that really has the adapter installed (this server does)
        // does not change what this test sees.
        env: {
          PATH: `${stub}:/usr/bin:/bin`,
          HOME: stub,
          MUSE_CODE_ACP_SEARCH_PATHS: join(stub, "empty"),
        },
        encoding: "utf8",
        stdio: ["ignore", "pipe", "pipe"],
      });
    } catch (error) {
      const stderr = (error as { stderr?: string }).stderr ?? "";
      message = String(stderr);
    }
    expect(message).toMatch(/muse-code-acp was not found/);
    expect(message).toMatch(/npm install -g @bex-co\/muse-code-acp/);
  });
});
describe("the real failure this plugin was verified against", () => {
  // Captured verbatim from a live turn through scripts/muse-code-acp.sh on
  // Muse Code 1.4.4 with an OAuth credential in the login keychain: the host
  // spawns and accepts the prompt, then the provider rejects it.  ACP delivers
  // that as a plain object, not an Error.
  const REJECTION =
    "Muse SDK turn failed: not logged in: run /login to add an API key. Replace the rejected provider credentials or run muse login, then explicitly submit again.";

  it("classifies the rejection from a plain ACP error object", async () => {
    const { support } = await loadMuse();
    // String() on a bare { code, message } is "[object Object]", so a
    // classifier that only unwraps Error instances loses this entirely.
    expect(support.classifyError!({ code: -32000, message: REJECTION })).toBe("invalid_credentials");
    expect(support.classifyError!(new Error(REJECTION))).toBe("invalid_credentials");
    expect(support.classifyError!({ code: -32000, message: REJECTION, data: {} })).toBe("invalid_credentials");
  });

  it("still declines to classify a string with no credential signal", async () => {
    const { support } = await loadMuse();
    expect(support.classifyError!("something unrelated")).toBeUndefined();
  });

  it("does not guess native Muse login state from environment variables", async () => {
    const { support } = await loadMuse();
    expect(support.isAuthenticated).toBeUndefined();
  });
});
