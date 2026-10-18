// =============================================================================
// infisicalIdentity — the local machine identity for Infisical
// =============================================================================
//
// The chicken-and-egg problem this module exists to solve: Infisical is the
// source of truth for Clutch's app settings, but the credentials that let Clutch
// read or write Infisical cannot themselves live in Infisical.  Storing the key
// to the store inside the store is circular — you would need the credential
// before you could fetch the credential.
//
// So the machine identity (project ID, universal-auth client ID, client
// secret) lives in ONE owner-only local file, `$CLUTCH_HOME/infisical.json`,
// beside the other machine-local secrets the Mac already keeps there
// (`chat-token`, `web-launch-url`).  Everything ELSE that Clutch configures
// stays in Infisical, exactly as INFISICAL.md describes.
//
// Precedence, matching the rest of Clutch: an explicitly-set environment
// variable always wins over the file, so a CI runner or a one-off shell can
// override the machine without editing anything.  The file is the fallback,
// not an override.
//
// Why not the macOS keychain?  Clutch's bash launcher layer needs these
// values BEFORE Node starts (scripts/lib/clutch-infisical-env.sh sources a
// plain file with no keychain round-trip), and Clutch must keep working the
// same way on a machine with no logged-in GUI session.  A 0600 file is what
// the surrounding code already trusts for `chat-token`.
//
// Secret values are never logged, echoed, or included in error messages —
// key names and metadata only.  Reads never throw: a missing, unreadable, or
// malformed file simply means "no local identity", so a broken file degrades
// to the pre-existing env-seed behaviour instead of blocking startup.
//
// See INFISICAL.md for the policy and the surrounding contract.

import { chmodSync, mkdirSync, readFileSync, renameSync, statSync, unlinkSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { dirname, join } from "node:path";

/** Universal-auth machine identity for the Clutch Infisical project. */
export interface InfisicalIdentity {
  /** Infisical project (workspace) ID. */
  projectId: string;
  /** Universal-auth machine identity client ID. */
  clientId: string;
  /** Universal-auth machine identity client secret. */
  clientSecret: string;
}

const IDENTITY_FILE_NAME = "infisical.json";
const LOG_PREFIX = "[infisical-identity]";

/** Environment slice this module reads; injected in tests. */
export interface IdentityEnv {
  CLUTCH_HOME?: string | undefined;
  HOME?: string | undefined;
  /** Explicit overrides; always win over the file. */
  INFISICAL_PROJECT_ID?: string | undefined;
  INFISICAL_CLIENT_ID?: string | undefined;
  INFISICAL_CLIENT_SECRET?: string | undefined;
}

function trimmed(value: string | undefined): string {
  return (value ?? "").trim();
}

/**
 * Absolute path of the identity file.  `$CLUTCH_HOME` is the same resolution
 * every other Clutch machine-local secret uses (default `~/.clutch`).
 */
export function infisicalIdentityPath(env: IdentityEnv = process.env): string {
  const home = trimmed(env.CLUTCH_HOME) || join(trimmed(env.HOME) || homedir(), ".clutch");
  return join(home, IDENTITY_FILE_NAME);
}

function parseIdentity(raw: string): InfisicalIdentity | undefined {
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return undefined;
  }
  if (parsed === null || typeof parsed !== "object") return undefined;
  const candidate = parsed as Record<string, unknown>;
  const read = (key: string): string => {
    const value = candidate[key];
    return typeof value === "string" ? value.trim() : "";
  };
  const identity: InfisicalIdentity = {
    projectId: read("projectId"),
    clientId: read("clientId"),
    clientSecret: read("clientSecret"),
  };
  // An identity with no client credentials is not an identity; treat it as
  // absent so the caller falls back cleanly instead of half-authenticating.
  if (!identity.clientId || !identity.clientSecret) return undefined;
  return identity;
}

/**
 * Best-effort read of the local identity file.  Returns undefined when the
 * file is missing, unreadable, malformed, or incomplete — never throws, so a
 * corrupt file cannot stop the web server from starting.
 *
 * Warns (names only, never values) when the file is group- or world-readable,
 * because it holds a machine secret.
 */
export function readInfisicalIdentity(env: IdentityEnv = process.env): InfisicalIdentity | undefined {
  const path = infisicalIdentityPath(env);
  let raw: string;
  try {
    raw = readFileSync(path, "utf8");
  } catch {
    return undefined; // absent is the normal case, not an error.
  }
  try {
    const mode = statSync(path).mode & 0o777;
    if (mode & 0o077) {
      console.error(
        `${LOG_PREFIX} ${path} is group/world accessible (mode ${mode.toString(8)}) — ` +
          `it holds a machine secret; run: chmod 600 ${path}`,
      );
    }
  } catch {
    // A stat race is not worth failing a read over; the file just parsed.
  }
  return parseIdentity(raw);
}

/**
 * Write the identity file atomically at mode 600.
 *
 * Atomic because the read side tolerates a torn file, but a half-written
 * identity would silently drop the operator's machine credentials on the
 * next boot.  The temp file is created in the destination directory so the
 * rename stays on one filesystem.
 */
export function writeInfisicalIdentity(identity: InfisicalIdentity, env: IdentityEnv = process.env): void {
  const path = infisicalIdentityPath(env);
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  const body = `${JSON.stringify(
    {
      projectId: identity.projectId.trim(),
      clientId: identity.clientId.trim(),
      clientSecret: identity.clientSecret,
    },
    null,
    2,
  )}\n`;

  // Unique temp name: two settings saves must not race on one scratch file.
  const scratch = join(dirname(path), `.${IDENTITY_FILE_NAME}.${process.pid}.${Date.now()}.tmp`);
  try {
    writeFileSync(scratch, body, { mode: 0o600 });
    renameSync(scratch, path);
    // rename preserves the temp file's mode on both platforms we ship on, but
    // re-assert it so a pre-existing loose file cannot stay loose.
    chmodSync(path, 0o600);
  } catch (error) {
    try {
      unlinkSync(scratch);
    } catch {
      // Best effort; the scratch file is already unreachable by name.
    }
    // Never include the body (it is the secret) in the error.
    throw new Error(`${LOG_PREFIX} failed to write ${path}: ${error instanceof Error ? error.message : String(error)}`);
  }
}

/**
 * Resolve the effective machine identity: explicit environment first, then the
 * local identity file.  `defaults.projectId` is used only when neither source
 * supplies one, so a stock checkout keeps working against the canonical Clutch
 * project.
 */
export function resolveInfisicalIdentity(
  defaults: Pick<InfisicalIdentity, "projectId">,
  env: IdentityEnv = process.env,
): InfisicalIdentity {
  const file = readInfisicalIdentity(env);
  return {
    projectId: trimmed(env.INFISICAL_PROJECT_ID) || trimmed(file?.projectId) || defaults.projectId,
    clientId: trimmed(env.INFISICAL_CLIENT_ID) || trimmed(file?.clientId),
    clientSecret: trimmed(env.INFISICAL_CLIENT_SECRET) || trimmed(file?.clientSecret),
  };
}

/**
 * A redacted view safe to return over an API: the secret is reported only as
 * present/absent plus a short trailing hint, never the value itself.
 */
export interface InfisicalIdentitySummary {
  projectId: string;
  clientId: string;
  /** Whether a client secret is configured — the value is never returned. */
  hasClientSecret: boolean;
  /** Last 4 characters of the client ID, or "" when unset.  Identity only. */
  clientIdHint: string;
  /** True when the values came from env rather than the local file. */
  fromEnv: boolean;
}

export function summarizeInfisicalIdentity(
  identity: InfisicalIdentity,
  env: IdentityEnv = process.env,
): InfisicalIdentitySummary {
  const fromEnv =
    trimmed(env.INFISICAL_CLIENT_ID) !== "" || trimmed(env.INFISICAL_CLIENT_SECRET) !== "";
  return {
    projectId: identity.projectId,
    clientId: identity.clientId,
    hasClientSecret: identity.clientSecret.length > 0,
    clientIdHint: identity.clientId.length > 4 ? identity.clientId.slice(-4) : "",
    fromEnv,
  };
}

/** Exported for tests that need an isolated scratch location. */
export const __testing = { parseIdentity, tmpdir };