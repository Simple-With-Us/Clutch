import { describe, it, expect } from "vitest";
import { existsSync, readFileSync } from "node:fs";
import { join, resolve } from "node:path";

import {
  DSH_HOST_API_PATH,
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
const BUNDLED = join(DSH_ROOT, "node_modules/@deepseek-ai");
const GATEWAY_TYPES = join(BUNDLED, "dsh-api-gateway/lib/types/stream-protocol.d.ts");
const CONNECTION_TYPES = join(BUNDLED, "dsh-client-connection/lib/types/rpc.d.ts");

/** Read an installed type file, failing loudly when the layout moved. */
function readInstalled(relative: string): string {
  const path = join(DSH_ROOT, "node_modules/@deepseek-ai", relative);
  if (!existsSync(path)) {
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
    expect(existsSync(GATEWAY_TYPES)).toBe(true);
  });

  it("finds the bundled client-connection types", () => {
    expect(existsSync(CONNECTION_TYPES)).toBe(true);
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
});
