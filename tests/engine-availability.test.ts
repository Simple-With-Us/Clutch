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
      },
      credentialFile,
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

  it("counts the dsh credential store the bridge reads as a reachable credential", async () => {
    const host = fixture();
    mkdirSync(join(host.home, ".clutch", "dsh"), { recursive: true });
    // The store's presence is the answer; its contents are never read here.
    writeFileSync(host.credentialFile, "# a credential store lives here\n");

    await expect(engineAvailability("deepseek", host.context)).resolves.toMatchObject({ available: true });
    await expect(engineAvailability("minimax", host.context)).resolves.toMatchObject({ available: true });
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
    writeFileSync(join(store, "auth.json"), "{}\n");
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

  it("never starts an engine to answer the question", async () => {
    const host = fixture();

    for (let request = 0; request < 3; request += 1) {
      await engineAvailability("muse", host.context);
      await engineAvailability("deepseek", host.context);
      await engineAvailability("mcode", host.context);
    }
    expect(existsSync(host.marker)).toBe(false);
  });

  it("counts a key that lives only in fleet-secrets as reachable", async () => {
    const host = fixture();
    const asked: string[] = [];

    // The MiniMax bridge's last resort is `fleet-secrets get NAME`, so a host
    // that keeps its key only there still runs the turn.  The catalog must
    // not drop the engine there.
    const minimax = await engineAvailability("minimax", {
      ...host.context,
      fleetSecretPresent: async (name) => {
        asked.push(name);
        return name === "MINIMAX_API_KEY";
      },
    });

    expect(minimax.available).toBe(true);
    expect(asked).toEqual(["MINIMAX_API_KEY"]);
  });

  it("asks fleet-secrets only when the cheaper sources found nothing", async () => {
    const host = fixture();
    let asked = 0;

    const withKey = { ...host.context, env: { ...host.context.env, MINIMAX_API_KEY: "present" } };
    const minimax = await engineAvailability("minimax", {
      ...withKey,
      fleetSecretPresent: async () => {
        asked += 1;
        return false;
      },
    });

    expect(minimax.available).toBe(true);
    expect(asked).toBe(0);
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
