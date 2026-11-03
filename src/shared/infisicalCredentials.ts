// =============================================================================
// Infisical service-token bootstrap for one Clutch host
// =============================================================================
//
// Service tokens cannot be fetched from the project they unlock.  Clutch keeps
// the per-host service token and optional write service token in `$CLUTCH_HOME/infisical.json`
// at mode 0600, beside its other local secrets.  Environment values override
// the file so CI and one-off shells can supply scoped credentials directly.
//
// Token values are never logged, returned by the summary, or included in errors.

import { chmodSync, closeSync, constants, fstatSync, mkdirSync, openSync, readFileSync, renameSync, unlinkSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

export interface InfisicalCredentials {
  projectId: string;
  readToken: string;
  writeToken: string;
}

const CREDENTIALS_FILE_NAME = "infisical.json";
const LOG_PREFIX = "[infisical-credentials]";

export interface CredentialsEnv {
  CLUTCH_HOME?: string;
  HOME?: string;
  INFISICAL_PROJECT_ID?: string;
  INFISICAL_TOKEN?: string;
  INFISICAL_WRITE_TOKEN?: string;
}

function trimmed(value: string | undefined): string {
  return (value ?? "").trim();
}

export function isInfisicalServiceToken(token: string): boolean {
  return token.startsWith("st.") && token.length >= 20 && token.length <= 2048 && !/\s/.test(token);
}

export function infisicalCredentialsPath(env: CredentialsEnv = process.env): string {
  const home = trimmed(env.CLUTCH_HOME) || join(trimmed(env.HOME) || homedir(), ".clutch");
  return join(home, CREDENTIALS_FILE_NAME);
}

function parseCredentials(raw: string): InfisicalCredentials | undefined {
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return undefined;
  }
  if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) return undefined;
  const candidate = parsed as Record<string, unknown>;
  const read = (key: string): string => typeof candidate[key] === "string" ? (candidate[key] as string).trim() : "";
  const credentials = {
    projectId: read("projectId"),
    readToken: read("serviceToken"),
    writeToken: read("writeServiceToken"),
  };
  if (!isInfisicalServiceToken(credentials.readToken)) return undefined;
  if (credentials.writeToken && !isInfisicalServiceToken(credentials.writeToken)) return undefined;
  return credentials;
}

export function readInfisicalCredentials(env: CredentialsEnv = process.env): InfisicalCredentials | undefined {
  const path = infisicalCredentialsPath(env);
  if (typeof constants.O_NOFOLLOW !== "number") return undefined;
  let fd: number;
  try {
    fd = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW);
  } catch {
    return undefined;
  }
  try {
    const stat = fstatSync(fd);
    if (!stat.isFile() || (stat.mode & 0o077) !== 0) {
      console.error(`${LOG_PREFIX} ${path} is not a private regular file — refusing to read service tokens`);
      return undefined;
    }
    return parseCredentials(readFileSync(fd, "utf8"));
  } finally {
    closeSync(fd);
  }
}

export function writeInfisicalCredentials(credentials: InfisicalCredentials, env: CredentialsEnv = process.env): void {
  if (!isInfisicalServiceToken(credentials.readToken)) {
    throw new Error(`${LOG_PREFIX} a valid read service token is required`);
  }
  if (credentials.writeToken && !isInfisicalServiceToken(credentials.writeToken)) {
    throw new Error(`${LOG_PREFIX} the write service token is invalid`);
  }
  const path = infisicalCredentialsPath(env);
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  chmodSync(dirname(path), 0o700);
  const body = `${JSON.stringify({
    projectId: credentials.projectId.trim(),
    serviceToken: credentials.readToken.trim(),
    ...(credentials.writeToken.trim() ? { writeServiceToken: credentials.writeToken.trim() } : {}),
  }, null, 2)}\n`;
  const scratch = join(dirname(path), `.${CREDENTIALS_FILE_NAME}.${process.pid}.${Date.now()}.tmp`);
  try {
    writeFileSync(scratch, body, { mode: 0o600, flag: "wx" });
    renameSync(scratch, path);
    chmodSync(path, 0o600);
  } catch (error) {
    try { unlinkSync(scratch); } catch { /* Best effort cleanup. */ }
    throw new Error(`${LOG_PREFIX} failed to write ${path}: ${error instanceof Error ? error.message : String(error)}`);
  }
}

export interface InfisicalCredentialsSummary {
  projectId: string;
  hasReadToken: boolean;
  hasWriteToken: boolean;
  readTokenFromEnv: boolean;
  writeTokenFromEnv: boolean;
}

export function resolveInfisicalCredentials(
  defaults: Pick<InfisicalCredentials, "projectId">,
  env: CredentialsEnv = process.env,
): InfisicalCredentials {
  const file = readInfisicalCredentials(env);
  const readToken = trimmed(env.INFISICAL_TOKEN) || trimmed(file?.readToken);
  const writeToken = trimmed(env.INFISICAL_WRITE_TOKEN) || trimmed(file?.writeToken);
  return {
    projectId: trimmed(env.INFISICAL_PROJECT_ID) || trimmed(file?.projectId) || defaults.projectId,
    readToken,
    writeToken,
  };
}

export function summarizeInfisicalCredentials(
  credentials: InfisicalCredentials,
  env: CredentialsEnv = process.env,
): InfisicalCredentialsSummary {
  return {
    projectId: credentials.projectId,
    hasReadToken: credentials.readToken.length > 0,
    hasWriteToken: credentials.writeToken.length > 0,
    readTokenFromEnv: trimmed(env.INFISICAL_TOKEN) !== "",
    writeTokenFromEnv: trimmed(env.INFISICAL_WRITE_TOKEN) !== "",
  };
}

export const __testing = { parseCredentials };
