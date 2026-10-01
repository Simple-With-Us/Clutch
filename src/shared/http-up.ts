/**
 * HTTP "is the server up" probe.  The Clutch web UI is auth-walled and
 * answers 401 on `/`, so a successful TCP listener that returns 401 or 403
 * still counts as healthy.  Treating those as down reclaim-kills the live
 * `clutch-web` job on every restart.
 */
export function httpStatusIsUp(code: number): boolean {
  if (!Number.isFinite(code) || code <= 0) return false;
  return (code >= 200 && code < 400) || code === 401 || code === 403;
}
