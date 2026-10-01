/**
 * Clutch MiniMax HTTP constants.
 *
 * Shellular MiniMax uses the dsh coding path (`bridges/minimax/minimax-acp.py` →
 * `dsh --profile minimax-headless`).  These constants remain for direct HTTP
 * callers and BotFleet/AFC imports that need the host, path, and default
 * model without duplicating strings.
 */

export const MINIMAX_DEFAULT_BASE_URL = "https://api.minimax.io/v1";
export const MINIMAX_CHAT_COMPLETIONS_PATH = "/chat/completions";
export const MINIMAX_DEFAULT_MODEL = "MiniMax-M2.7-highspeed";
export const MINIMAX_API_KEY_ENV = "MINIMAX_API_KEY";
export const MINIMAX_API_KEY_NAME_ENV = "CLUTCH_MINIMAX_API_KEY_NAME";

export function minimaxNormalizeBaseUrl(baseUrl: string = MINIMAX_DEFAULT_BASE_URL): string {
  return baseUrl.replace(/\/+$/u, "");
}

export function minimaxChatCompletionsUrl(baseUrl: string = MINIMAX_DEFAULT_BASE_URL): string {
  return `${minimaxNormalizeBaseUrl(baseUrl)}${MINIMAX_CHAT_COMPLETIONS_PATH}`;
}

/** Env contract the Python bridge and any TS caller share. */
export function minimaxTransformEnv(env: Record<string, string | undefined>): void {
  if (!env.CLUTCH_MINIMAX_BASE_URL) env.CLUTCH_MINIMAX_BASE_URL = MINIMAX_DEFAULT_BASE_URL;
  if (!env.CLUTCH_MINIMAX_MODEL) env.CLUTCH_MINIMAX_MODEL = MINIMAX_DEFAULT_MODEL;
  if (!env.CLUTCH_MINIMAX_API_KEY_NAME) env.CLUTCH_MINIMAX_API_KEY_NAME = MINIMAX_API_KEY_ENV;
}

export function minimaxIsAuthenticated(env: Record<string, string | undefined>): boolean {
  const name = env.CLUTCH_MINIMAX_API_KEY_NAME || MINIMAX_API_KEY_ENV;
  return Boolean(env[name] || env.MINIMAX_API_KEY);
}
