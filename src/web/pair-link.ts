/**
 * Pure helpers shared by `start-web` (which hosts harness web trusts) and
 * `harness-pair-ios` (the pairing link the iOS app scans).
 *
 * dsh web auth in one paragraph: each dsh web process mints a launch token
 * and prints `http://127.0.0.1:<port>/?token=<t>`.  Visiting `/?token=<t>`
 * on ANY trusted authority sets a signed cookie bound to that authority
 * (30-day lifetime, signing secret persisted across restarts) and 303s to
 * `/`.  Separately, every `/api` request must carry a trusted Host header,
 * so the Tailscale name the phone uses has to be in `--trusted-host`.
 */

/** Legacy tailnet name baked into the live install before auto-detection. */
export const LEGACY_TAILNET_HOST = "macbook.boa-roygbiv.ts.net";
export const LEGACY_TAILNET_IPV4 = "100.113.106.39";

/**
 * This machine's MagicDNS name from `tailscale status --self --json`
 * (`Self.DNSName`, trailing dot removed, lowercased), or null.
 */
export function tailnetDnsName(statusJson: unknown): string | null {
  if (typeof statusJson !== "object" || statusJson === null) return null;
  const self = (statusJson as { Self?: unknown }).Self;
  if (typeof self !== "object" || self === null) return null;
  const dns = (self as { DNSName?: unknown }).DNSName;
  if (typeof dns !== "string") return null;
  const cleaned = dns.trim().replace(/\.$/, "").toLowerCase();
  return /^[a-z0-9.-]+$/.test(cleaned) && cleaned.includes(".") ? cleaned : null;
}

/** `--trusted-host` argv for each host, bare and with the port, de-duplicated. */
export function trustedHostArgs(hosts: readonly (string | null | undefined)[], port: string): string[] {
  const seen = new Set<string>();
  const args: string[] = [];
  for (const raw of hosts) {
    const host = raw?.trim().toLowerCase();
    if (!host) continue;
    for (const authority of [host, `${host}:${port}`]) {
      if (seen.has(authority)) continue;
      seen.add(authority);
      args.push("--trusted-host", authority);
    }
  }
  return args;
}

/** The `token` query value of a dsh web launch URL, or null. */
export function launchToken(launchUrl: string): string | null {
  try {
    const token = new URL(launchUrl.trim()).searchParams.get("token");
    return token && token.length > 0 ? token : null;
  } catch {
    return null;
  }
}

/**
 * The link the iOS app pairs from:
 * `harness://pair?url=<origin>/?token=<t>&name=<label>`.
 * `origin` is where the phone reaches harness web, e.g.
 * `https://<magicdns>:3080` over Tailscale or `http://127.0.0.1:3080` for the Simulator.
 */
export function pairingLink(options: { launchUrl: string; origin: string; name?: string }): string {
  const token = launchToken(options.launchUrl);
  if (token === null) throw new Error("launch URL has no token; is harness web running?");
  const origin = new URL(options.origin);
  if (origin.protocol !== "http:" && origin.protocol !== "https:") {
    throw new Error(`origin must be http(s), got ${origin.protocol}`);
  }
  const target = new URL("/", origin);
  target.searchParams.set("token", token);
  const link = new URL("harness://pair");
  link.searchParams.set("url", target.toString());
  if (options.name) link.searchParams.set("name", options.name);
  return link.toString();
}
