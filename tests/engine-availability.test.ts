import { chmodSync, existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";

import { engineAvailability, type EngineAvailabilityContext } from "../src/web/chat-bridge.ts";

const temps: string[] = [];

function tempDir(): string {
  const dir = mkdtempSync(join(tmpdir(), "clutch-availability-"));
  temps.push(dir);
  return dir;
}

/** A file a launcher could run: present and executable. */
function executable(path: string, body = "#!/bin/sh\nexit 0\n"): string {
  writeFileSync(path, body);
  chmodSync(path, 0o755);
  return path;
}

afterEach(() => {
  while (temps.length > 0) rmSync(temps.pop()!, { recursive: true, force: true });
});

interface Fixture {
  context: EngineAvailabilityContext;
  home: string;
  credentialFile: string;
  /** Written when an engine binary is actually run. */
  marker: string;
}

/**
 * A host with the launchers, the interpreter and the credential store the
 * engines need.
 *
 * Every fact the check reads is a file, so the check can be exercised
 * without touching the machine the test runs on.
 */
function fixture(options: { python?: boolean } = {}): Fixture {
  const root = tempDir();
  const home = join(root, "home");
  const bin = join(root, "bin");
  mkdirSync(home, { recursive: true });
  mkdirSync(bin, { recursive: true });
  const marker = join(root, "engine-started");
  executable(join(bin, "muse"), `#!/bin/sh\n: > ${JSON.stringify(marker)}\nexit 0\n`);
  executable(join(bin, "mcode"));
  if (options.python !== false) executable(join(bin, "python3"));
  const credentialFile = join(home, ".clutch", "dsh", ".credentials.yaml");
  return {
    home,
    credentialFile,
    marker,
    context: {
      env: { PATH: bin, HOME: home },
      launchers: {
        deepseek: { command: process.execPath, args: [] },
        minimax: { command: process.execPath, args: [] },
        mcode: { command: "mcode", args: ["acp"] },
        muse: { command: process.execPath, args: [] },
        zcode: { command: process.execPath, args: [] },
      },
      credentialFile,
      // The interpreter candidates are empty on purpose: the fixture's own PATH
      // is then the only place a python3 can come from, so the answer never
      // depends on what the host happens to have installed.
      interpreterCandidates: [],
    },
  };
}

describe("engine availability", () => {
  it("reports an engine with no reachable credential as unavailable and says where the key goes", async () => {
    const host = fixture();

    const deepseek = await engineAvailability("deepseek", host.context);
    expect(deepseek.available).toBe(false);
    expect(deepseek.note).toContain("DEEPSEEK_API_KEY");
    expect(deepseek.note).toContain(host.credentialFile);

    const minimax = await engineAvailability("minimax", host.context);
    expect(minimax.available).toBe(false);
    expect(minimax.note).toContain("MINIMAX_API_KEY");
    expect(minimax.note).toContain(host.credentialFile);
  });

  it("keeps DeepSeek's legacy file-presence check but rejects unrelated MiniMax contents", async () => {
    const host = fixture();
    mkdirSync(join(host.home, ".clutch", "dsh"), { recursive: true });
    writeFileSync(host.credentialFile, "# only a comment\nOTHER_PROVIDER_KEY: fixture\n");

    await expect(engineAvailability("deepseek", host.context)).resolves.toMatchObject({ available: true });
    const minimax = await engineAvailability("minimax", host.context);
    expect(minimax.available).toBe(false);
    expect(minimax.note).toContain("MINIMAX_API_KEY");
  });

  it("requires an exact nonempty MiniMax assignment in the DSH credential file", async () => {
    const host = fixture();
    mkdirSync(join(host.home, ".clutch", "dsh"), { recursive: true });
    const contents = [
      "# MiniMax key is not configured",
      "OTHER_MINIMAX_API_KEY: fixture-other",
      "MINIMAX_API_KEY: \"\"",
      "DEEPSEEK_API_KEY=fixture-other",
    ].join("\n");
    writeFileSync(host.credentialFile, `${contents}\n`);
    await expect(engineAvailability("minimax", host.context)).resolves.toMatchObject({ available: false });

    writeFileSync(host.credentialFile, "export MINIMAX_API_KEY = 'fixture:x=y'\n");
    await expect(engineAvailability("minimax", host.context)).resolves.toMatchObject({ available: true });

    const alternate = {
      ...host.context,
      env: { ...host.context.env, CLUTCH_MINIMAX_API_KEY_NAME: "CUSTOM_MINIMAX_KEY" },
    };
    writeFileSync(host.credentialFile, "CUSTOM_MINIMAX_KEY: \"fixture-alt\"\n");
    await expect(engineAvailability("minimax", alternate)).resolves.toMatchObject({ available: true });
  });

  it("counts a key in the environment or in Clutch's own settings as reachable", async () => {
    const host = fixture();

    const withEnvKey = { ...host.context, env: { ...host.context.env, DEEPSEEK_API_KEY: "present" } };
    await expect(engineAvailability("deepseek", withEnvKey)).resolves.toMatchObject({ available: true });

    const withSetting = {
      ...host.context,
      settings: { get: (key: string) => (key === "MINIMAX_API_KEY" ? "present" : "") },
    };
    await expect(engineAvailability("minimax", withSetting)).resolves.toMatchObject({ available: true });
  });

  it("says the bridge needs Python 3 when the interpreter is missing", async () => {
    const host = fixture({ python: false });

    const deepseek = await engineAvailability("deepseek", host.context);
    expect(deepseek.available).toBe(false);
    expect(deepseek.note).toContain("Python 3");
  });

  it("keeps an engine whose launcher is missing out of the picker", async () => {
    const host = fixture();
    const launchers = { ...host.context.launchers!, deepseek: { command: "/nonexistent/dsh-acp.sh", args: [] } };

    const deepseek = await engineAvailability("deepseek", { ...host.context, launchers });
    expect(deepseek.available).toBe(false);
    expect(deepseek.note).toContain("not installed");
  });

  it("asks MiniMax Code to sign in before a turn can run", async () => {
    const host = fixture();

    const mcode = await engineAvailability("mcode", host.context);
    expect(mcode.available).toBe(false);
    expect(mcode.note).toContain("mcode login");

    const store = join(host.home, ".minimax", "auth", "prod", "en", "mcode-public");
    mkdirSync(store, { recursive: true });
    const credential = join(store, "auth.json");
    writeFileSync(credential, "{}\n");
    // The credential only counts when nobody else can read it: MiniMax Code
    // refuses a group- or other-readable file, so the fixture has to be the
    // private file the CLI writes rather than whatever the umask allows.
    chmodSync(credential, 0o600);
    await expect(engineAvailability("mcode", host.context)).resolves.toMatchObject({ available: true });
  });

  it("asks Muse Code to sign in before a turn can run", async () => {
    const host = fixture();

    // The Muse sign-in lives behind the engine being selected, so an engine
    // that needs one stays in the picker with the note that says what is
    // still needed: dropping it would take the owner's only way to sign in.
    const muse = await engineAvailability("muse", host.context);
    expect(muse.available).toBe(true);
    expect(muse.note).toContain("muse login");

    const withKey = {
      ...host.context,
      settings: { get: (key: string) => (key === "META_API_KEY" ? "present" : "") },
    };
    await expect(engineAvailability("muse", withKey)).resolves.toMatchObject({ available: true });
  });

  it("names the ACP bridge's install line when the bridge is missing", async () => {
    const host = fixture();
    // Z Code's CLI has no ACP command (C-129); the launcher is the
    // zcode-acp-server bridge, so a missing one says how to install it.
    const launchers = { ...host.context.launchers!, zcode: { command: "zcode-acp-server", args: [] } };

    const zcode = await engineAvailability("zcode", { ...host.context, launchers });
    expect(zcode.available).toBe(false);
    expect(zcode.note).toContain("npm install -g zcode-acp-server");
  });

  it("keeps Z Code out of the picker when the CLI the bridge drives is missing", async () => {
    const host = fixture();
    const env = { ...host.context.env, ZCODE_BIN: join(host.home, "no-such-zcode") };

    const zcode = await engineAvailability("zcode", { ...host.context, env });
    expect(zcode.available).toBe(false);
    expect(zcode.note).toContain("not installed");
  });

  it("trusts a full Z Code launcher override without the CLI or a sign-in", async () => {
    const host = fixture();
    // CLUTCH_CHAT_LAUNCHER_ZCODE replaces the whole launcher, so the CLI the
    // bridge would drive and the bridge's sign-in are not this host's concern.
    // The sidecar marks that launcher, and the check reads the mark.
    const env = { ...host.context.env, ZCODE_BIN: join(host.home, "no-such-zcode") };
    const launchers = { ...host.context.launchers!, zcode: { command: process.execPath, args: [], override: true } };

    await expect(engineAvailability("zcode", { ...host.context, env, launchers })).resolves.toEqual({ available: true });

    // The override's own command still has to exist.
    const missing = { ...launchers, zcode: { command: join(host.home, "no-such-launcher"), args: [], override: true } };
    await expect(engineAvailability("zcode", { ...host.context, env, launchers: missing })).resolves.toMatchObject({ available: false });

    // A directory is not a launcher the spawn can run.
    const folder = { ...launchers, zcode: { command: host.home, args: [], override: true } };
    await expect(engineAvailability("zcode", { ...host.context, env, launchers: folder })).resolves.toMatchObject({ available: false });
  });

  it("keeps Z Code in the picker without a sign-in and says how to sign in", async () => {
    const host = fixture();
    const cli = executable(join(host.home, "zcode.cjs"));
    const env = { ...host.context.env, ZCODE_BIN: cli };

    // Same reasoning as Muse: the bridge reads a sign-in the file check may
    // not see, so the engine stays listed with the note.  A key in Clutch
    // settings is no Z Code sign-in, because the bridge never reads one.
    const withKey = {
      ...host.context,
      env,
      settings: { get: (key: string) => (key === "ZAI_API_KEY" ? "present" : "") },
    };
    const zcode = await engineAvailability("zcode", withKey);
    expect(zcode.available).toBe(true);
    expect(zcode.note).toContain("zcode-acp setup --provider zai");
    expect(zcode.note).not.toContain("ZAI_API_KEY");

    // A saved `zcode-acp setup` account is a sign-in.
    const accounts = join(host.home, ".zcode", "v2", "acp-accounts.json");
    mkdirSync(join(host.home, ".zcode", "v2"), { recursive: true });
    writeFileSync(accounts, JSON.stringify({ zai: { provider: "zai" } }));
    await expect(engineAvailability("zcode", { ...host.context, env })).resolves.toEqual({ available: true });
  });

  it("counts the Z Code app's own Coding Plan sign-in", async () => {
    const host = fixture();
    const cli = executable(join(host.home, "zcode.cjs"));
    const env = { ...host.context.env, ZCODE_BIN: cli };
    mkdirSync(join(host.home, ".zcode", "v2"), { recursive: true });
    writeFileSync(
      join(host.home, ".zcode", "v2", "config.json"),
      JSON.stringify({ provider: { "builtin:zai-coding-plan": { enabled: true, options: { apiKey: "present" } } } }),
    );

    await expect(engineAvailability("zcode", { ...host.context, env })).resolves.toEqual({ available: true });
  });

  it("never starts an engine to answer the question", async () => {
    const host = fixture();

    for (let request = 0; request < 3; request += 1) {
      await engineAvailability("muse", host.context);
      await engineAvailability("deepseek", host.context);
      await engineAvailability("mcode", host.context);
    }
    expect(existsSync(host.marker)).toBe(false);
  });

  it("fails closed when only the retired secret CLI could supply a key", async () => {
    const host = fixture();
    const marker = join(host.home, "fleet-secrets-called");
    const bin = (host.context.env?.PATH ?? "").split(":")[0]!;
    executable(join(bin, "fleet-secrets"), `#!/bin/sh\nprintf called > ${JSON.stringify(marker)}\nprintf 'MINIMAX_API_KEY\\n'\n`);

    const minimax = await engineAvailability("minimax", host.context);

    expect(minimax.available).toBe(false);
    expect(minimax.note).toContain("Clutch settings");
    expect(minimax.note).not.toContain("fleet-secrets");
    expect(existsSync(marker)).toBe(false);
  });

  it("lets the environment name the MiniMax key over Clutch's own settings", async () => {
    const host = fixture();

    // An explicitly-set env var is the operator's own override, so it beats
    // the managed store.  The key the check looks for is named in the note,
    // which is how the difference is observable.
    const minimax = await engineAvailability("minimax", {
      ...host.context,
      env: { ...host.context.env, CLUTCH_MINIMAX_API_KEY_NAME: "ENV_NAMED_KEY" },
      settings: { get: (key: string) => (key === "CLUTCH_MINIMAX_API_KEY_NAME" ? "SETTINGS_NAMED_KEY" : "") },
    });

    expect(minimax.note).toContain("ENV_NAMED_KEY");
    expect(minimax.note).not.toContain("SETTINGS_NAMED_KEY");
  });
});
