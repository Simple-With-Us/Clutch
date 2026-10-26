import { describe, it, expect } from "vitest";
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { join, resolve } from "node:path";

import {
  DSH_HOST_API_PATH,
  DSH_HOST_ENDPOINT_NAMESPACES,
  DSH_HOST_EVENT_RESULT_ENDPOINT,
  DSH_HOST_EVENT_STREAM_ENDPOINT,
  DSH_HOST_MUX_PATH,
} from "../src/shared/dshHostContract";

// =============================================================================
// dsh-host-pinned — the contract Clutch's native clients speak, checked
// against the dsh build Clutch actually ships.
//
// `@deepseek-ai/dsh` bundles its own dependencies, so the installed package
// carries the gateway and client-connection type definitions that define the
// wire contract.  Clutch's native iOS and macOS clients implement that
// contract; this test proves the two still agree.
//
// It reads the installed artifact rather than the upstream git tree on
// purpose.  The tree moves; the installed package is what runs on Jay's Mac
// and what CI installs, so a dsh bump that changes the mux path, the event
// endpoints or the request and response envelopes fails here instead of
// failing on a phone with no host to talk to.
// =============================================================================

const DSH_ROOT = resolve("node_modules/@deepseek-ai/dsh");

/**
 * The version of the dsh build Clutch ships.
 *
 * Every `@deepseek-ai/*` package is released in lockstep with dsh, so the dsh
 * version is the one that identifies the matching copy of a package.
 */
function installedDshVersion(): string {
  const manifest = join(DSH_ROOT, "package.json");
  if (!existsSync(manifest)) {
    throw new Error(
      "The installed dsh package is gone. The native client contract is asserted against " +
        "the build Clutch ships, so a dsh bump that moves it must be reviewed by hand.",
    );
  }
  return (JSON.parse(readFileSync(manifest, "utf8")) as { version?: string }).version ?? "";
}

/**
 * Every directory that may hold an installed `@deepseek-ai` package.
 *
 * The layout depends on the installer. npm nests a package's dependencies
 * under it; pnpm keeps them in a content-addressed store and links to them.
 * The contract is asserted against the build Clutch ships either way, so the
 * test looks in both places and takes the copy whose version matches dsh's.
 */
function packageRoots(): string[] {
  const roots = [
    join(DSH_ROOT, "node_modules/@deepseek-ai"),
    join("node_modules/@deepseek-ai"),
  ];
  const store = "node_modules/.pnpm";
  if (existsSync(store)) {
    for (const entry of readdirSync(store)) {
      roots.push(join(store, entry, "node_modules/@deepseek-ai"));
    }
  }
  return roots;
}

/** The installed directory of one `@deepseek-ai` package, or null. */
function locatePackage(name: string): string | null {
  const version = installedDshVersion();
  for (const root of packageRoots()) {
    const manifest = join(root, name, "package.json");
    if (!existsSync(manifest)) continue;
    const found = (JSON.parse(readFileSync(manifest, "utf8")) as { version?: string }).version;
    if (found === version) return join(root, name);
  }
  return null;
}

/** Read one file out of an installed `@deepseek-ai` package, failing loudly. */
function readInstalled(relative: string): string {
  const [name, ...rest] = relative.split("/");
  const root = locatePackage(name);
  const path = root ? join(root, ...rest) : "";
  if (!root || !existsSync(path)) {
    throw new Error(
      `The installed dsh package no longer ships ${relative}. ` +
        "The native client contract is asserted against this file, so a dsh bump that " +
        "moves it must be reviewed by hand before the native clients are rebuilt.",
    );
  }
  return readFileSync(path, "utf8");
}

/** The string literal a `export declare const NAME = "value";` declares. */
function declaredString(source: string, name: string): string | null {
  const match = source.match(new RegExp(`declare const ${name}\\s*=\\s*"([^"]*)"`));
  return match?.[1] ?? null;
}

describe("dsh host contract — pinned to the installed dsh build", () => {
  it("finds the bundled gateway types", () => {
    expect(locatePackage("dsh-api-gateway")).not.toBeNull();
  });

  it("finds the bundled client-connection types", () => {
    expect(locatePackage("dsh-client-connection")).not.toBeNull();
  });

  it("uses the mux path the installed gateway declares", () => {
    const source = readInstalled("dsh-api-gateway/lib/types/stream-protocol.d.ts");
    expect(declaredString(source, "REMOTE_STREAM_MUX_PATH")).toBe(DSH_HOST_MUX_PATH);
  });

  it("uses the event endpoints the installed gateway declares", () => {
    const source = readInstalled("dsh-api-gateway/lib/types/stream-protocol.d.ts");
    expect(declaredString(source, "REMOTE_EVENT_STREAM_ENDPOINT")).toBe(DSH_HOST_EVENT_STREAM_ENDPOINT);
    expect(declaredString(source, "REMOTE_EVENT_RESULT_ENDPOINT")).toBe(DSH_HOST_EVENT_RESULT_ENDPOINT);
  });

  it("uses the /api prefix the installed connection declares", () => {
    const source = readInstalled("dsh-client-connection/lib/types/api-path.d.ts");
    expect(declaredString(source, "API_PATH")).toBe(DSH_HOST_API_PATH);
  });

  it("uses the request envelope the installed connection declares", () => {
    const source = readInstalled("dsh-client-connection/lib/types/rpc.d.ts");
    expect(source).toMatch(/type:\s*'client-request'/);
    expect(source).toMatch(/rpcId:\s*RpcId/);
    expect(source).toMatch(/method:\s*string/);
    expect(source).toMatch(/payload:\s*unknown/);
  });

  it("uses the response envelope the installed connection declares", () => {
    const source = readInstalled("dsh-client-connection/lib/types/rpc.d.ts");
    expect(source).toMatch(/type:\s*'server-response'/);
    expect(source).toMatch(/result:\s*ConnectionRpcResult/);
  });

  it("declares the endpoint namespaces the installed build dispatches", () => {
    const source = readInstalled("dsh-api-remotes/lib/client.js");
    const namespaces = new Set<string>();
    for (const match of source.matchAll(/namespace:\s*"([A-Za-z0-9_$-]+)"/g)) {
      namespaces.add(match[1]);
    }
    expect(namespaces.size).toBeGreaterThan(0);
    expect([...namespaces].sort()).toEqual([...DSH_HOST_ENDPOINT_NAMESPACES].sort());
  });

  it("declares no namespace the host cannot dispatch", () => {
    // A terminal, a job and a remotes namespace are all fiction: the terminal
    // is a tool card, and jobs ride the session controller.
    for (const fictional of ["terminal", "job", "remotes"]) {
      expect(DSH_HOST_ENDPOINT_NAMESPACES as readonly string[]).not.toContain(fictional);
    }
  });

  it("declares the mux frame union the native client decodes", () => {
    const source = readInstalled("dsh-api-gateway/lib/types/stream-protocol.d.ts");
    for (const frame of ["'open'", "'cancel'", "'item'", "'error'", "'end'"]) {
      expect(source).toContain(frame);
    }
  });
});
