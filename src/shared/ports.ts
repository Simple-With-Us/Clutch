/**
 * Default port for Clutch web.  Vanilla `dsh web` keeps its upstream default
 * of 3080, so Clutch uses its own port and the two can run side by side.
 * `CLUTCH_WEB_PORT` overrides it at runtime.
 */
export const CLUTCH_WEB_PORT_DEFAULT = 3180;

/** The configured Clutch web port as a string, for argv and URLs. */
export function clutchWebPort(env: Record<string, string | undefined> = process.env): string {
  const raw = env.CLUTCH_WEB_PORT?.trim();
  return raw && raw.length > 0 ? raw : String(CLUTCH_WEB_PORT_DEFAULT);
}
