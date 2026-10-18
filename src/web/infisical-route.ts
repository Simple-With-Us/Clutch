// =============================================================================
// infisical-route — the settings API behind the native Infisical panel
// =============================================================================
//
// Clutch's own web UI is upstream `dsh` code (scripts/clutch.sh execs
// node_modules/.bin/dsh), so Clutch cannot add a section to the Settings
// dialog without forking the harness.  It CAN own this route: chat-bridge
// already runs on the Mac, already authenticates the paired native apps with
// a bearer token, and is already Clutch-authored.  The iOS and macOS builds
// of HostsSheet call it, which is how one panel is editable from both.
//
// Two operations, deliberately separated because they have different rules:
//
//   GET  -> redacted view of the machine identity + the managed key inventory.
//           Secret VALUES never cross the wire; only presence does.  Non-secret
//           values (config/knob) are returned so a settings panel can show the
//           current value in an editable field.
//
//   PUT  -> saves the machine identity to $CLUTCH_HOME/infisical.json, and/or
//           writes one managed setting through to Infisical via
//           ClutchSettings.set() (Infisical first, cache only on success).
//
// Why a PUT that changes credentials cannot also write a setting: the running
// process is still holding the OLD client credentials, so a write-through in
// the same request would silently persist under credentials the operator just
// replaced.  That request is refused with 409 and a restart prompt instead —
// the operator saves credentials, restarts, then writes settings.
//
// Clutch is a single-user local tool, so the local user IS the admin and the
// bearer token is the auth boundary (documented no-op admin gate — see
// INFISICAL.md).  Values are never logged here; keys and metadata only.
//
// See infisicalIdentity.ts for the on-disk contract and INFISICAL.md for the
// policy this whole surface exists to serve.

import type { IncomingMessage, ServerResponse } from "node:http";

import {
  CLUTCH_SETTINGS_SCHEMA,
  isSecretSetting,
  type ClutchSettings,
} from "../shared/clutchSettings.ts";
import {
  CLUTCH_INFISICAL_PROJECT_ID,
} from "../shared/clutchSettings.ts";
import {
  infisicalIdentityPath,
  readInfisicalIdentity,
  resolveInfisicalIdentity,
  summarizeInfisicalIdentity,
  writeInfisicalIdentity,
} from "../shared/infisicalIdentity.ts";

/** Bounds the request body so a malformed client cannot exhaust memory. */
const MAX_BODY_BYTES = 8 * 1024;

export interface InfisicalRouteDeps {
  settings: ClutchSettings;
  /** Injected in tests; defaults to process.env. */
  env?: NodeJS.ProcessEnv;
}

function sendJson(res: ServerResponse, status: number, body: unknown): void {
  res.writeHead(status, { "content-type": "application/json" }).end(JSON.stringify(body));
}

async function readJsonBody(req: IncomingMessage): Promise<unknown> {
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of req) {
    const buf = chunk as Buffer;
    size += buf.length;
    if (size > MAX_BODY_BYTES) throw new Error("request body too large");
    chunks.push(buf);
  }
  if (size === 0) return {};
  return JSON.parse(Buffer.concat(chunks).toString("utf8"));
}

function asRecord(value: unknown): Record<string, unknown> | undefined {
  if (value === null || typeof value !== "object" || Array.isArray(value)) return undefined;
  return value as Record<string, unknown>;
}

function str(value: unknown): string {
  return typeof value === "string" ? value.trim() : "";
}

/** The managed-key inventory, masked the same way `clutch-settings list` masks. */
function describeKeys(settings: ClutchSettings): Array<Record<string, unknown>> {
  const all = settings.getAll();
  return CLUTCH_SETTINGS_SCHEMA.map((def) => {
    const value = all[def.key] ?? "";
    return {
      key: def.key,
      kind: def.kind,
      description: def.description,
      isSet: value.length > 0,
      // Secrets report presence only; the value never leaves the Mac.
      value: isSecretSetting(def.key) ? "" : value,
    };
  });
}

/**
 * Handle an Infisical settings request.  Returns true when this route
 * consumed the request, false when the path is not ours (caller continues).
 */
export async function handleInfisicalSettingsRequest(
  req: IncomingMessage,
  res: ServerResponse,
  pathname: string,
  deps: InfisicalRouteDeps,
): Promise<boolean> {
  if (pathname !== "/clutch/v1/infisical") return false;
  const { settings } = deps;
  const env = deps.env ?? process.env;

  if (req.method === "GET") {
    const identity = resolveInfisicalIdentity({ projectId: CLUTCH_INFISICAL_PROJECT_ID }, env);
    sendJson(res, 200, {
      identity: summarizeInfisicalIdentity(identity, env),
      // Where the managed settings themselves are read from.
      source: settings.source,
      identityPath: infisicalIdentityPath(env as NodeJS.ProcessEnv),
      restartRequired: false,
      keys: describeKeys(settings),
    });
    return true;
  }

  if (req.method !== "PUT" && req.method !== "POST") {
    sendJson(res, 405, { error: "use GET or PUT" });
    return true;
  }

  let body: unknown;
  try {
    body = await readJsonBody(req);
  } catch (error) {
    sendJson(res, 400, {
      error: error instanceof Error ? error.message : "invalid request body",
    });
    return true;
  }
  const payload = asRecord(body);
  if (payload === undefined) {
    sendJson(res, 400, { error: "body must be a JSON object" });
    return true;
  }

  // -- identity ---------------------------------------------------------------
  const identityInput = asRecord(payload["identity"]);
  const settingInput = asRecord(payload["setting"]);
  const settingKey = settingInput === undefined ? "" : str(settingInput["key"]);
  const settingValue = settingInput === undefined ? "" : str(settingInput["value"]);

  const current = resolveInfisicalIdentity({ projectId: CLUTCH_INFISICAL_PROJECT_ID }, env);
  let identityChanged = false;
  let savedIdentity: typeof current | undefined;

  if (identityInput !== undefined) {
    const nextProjectId = str(identityInput["projectId"]);
    const nextClientId = str(identityInput["clientId"]);
    const nextClientSecret = typeof identityInput["clientSecret"] === "string" ? identityInput["clientSecret"] : "";
    // An omitted or empty secret means "keep the stored one" so a panel that
    // masks the field never wipes the credential on save.
    const merged = {
      projectId: nextProjectId || current.projectId,
      clientId: nextClientId || current.clientId,
      clientSecret: nextClientSecret.length > 0 ? nextClientSecret : current.clientSecret,
    };
    identityChanged =
      merged.projectId !== current.projectId ||
      merged.clientId !== current.clientId ||
      merged.clientSecret !== current.clientSecret;

    if (!merged.clientId || !merged.clientSecret) {
      sendJson(res, 400, {
        error: "a machine identity needs both a client ID and a client secret",
      });
      return true;
    }
    if (identityChanged) {
      if (settingKey) {
        // See the file header: writing settings here would persist them under
        // the credentials the operator just replaced.
        sendJson(res, 409, {
          error:
            "save the machine identity and restart Clutch first — a setting cannot be " +
            "written in the same request that changes the credentials it would use",
          restartRequired: true,
        });
        return true;
      }
      try {
        writeInfisicalIdentity(merged, env as NodeJS.ProcessEnv);
      } catch (error) {
        sendJson(res, 500, {
          error: error instanceof Error ? error.message : "failed to save the machine identity",
        });
        return true;
      }
      savedIdentity = merged;
    }
  }

  // -- managed setting write-through -----------------------------------------
  if (settingKey) {
    if (CLUTCH_SETTINGS_SCHEMA.some((def) => def.key === settingKey) === false) {
      sendJson(res, 400, { error: `unknown setting key: ${settingKey}` });
      return true;
    }
    try {
      await settings.set(settingKey, settingValue);
    } catch (error) {
      // InfisicalWriteError already names the key and explains; it never
      // carries the value.  env-seed mode lands here too.
      sendJson(res, 503, {
        error: error instanceof Error ? error.message : "write-through failed",
        key: settingKey,
        writeThrough: false,
      });
      return true;
    }
  }

  const identity = savedIdentity ?? resolveInfisicalIdentity({ projectId: CLUTCH_INFISICAL_PROJECT_ID }, env);
  sendJson(res, 200, {
    identity: summarizeInfisicalIdentity(identity, env),
    source: settings.source,
    restartRequired: identityChanged,
    identitySaved: identityChanged,
    settingSaved: settingKey ? settingKey : "",
    keys: describeKeys(settings),
  });
  return true;
}

/** Re-exported so callers can report whether a local identity file exists. */
export const hasLocalIdentityFile = (env: NodeJS.ProcessEnv = process.env): boolean =>
  readInfisicalIdentity(env as never) !== undefined;