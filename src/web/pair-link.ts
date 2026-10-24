/**
 * Pure helpers shared by `start-web` (which hosts clutch web trusts) and
 * `clutch-pair-ios` (the pairing link the iOS app scans).
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
 * The authority set a loopback sidecar trusts, mirroring `start-web.sh`:
 * loopback plus the tailnet names, bare and with the sidecar's own port.
 * `hosts` are bare names (`tailnetDnsName` output, `CLUTCH_TRUSTED_HOSTS`
 * entries); callers always prepend `127.0.0.1` and `localhost`.
 */
export function trustedAuthoritySet(hosts: readonly (string | null | undefined)[], port: string): Set<string> {
  const seen = new Set<string>();
  for (const raw of ["127.0.0.1", "localhost", ...hosts]) {
    const host = raw?.trim().toLowerCase();
    if (!host) continue;
    seen.add(host);
    seen.add(`${host}:${port}`);
  }
  return seen;
}

/**
 * True when a request `Host` header names a trusted authority. The header
 * may carry `host` or `host:port`, in any case; anything else (including a
 * missing header) is untrusted.
 */
export function isTrustedHostHeader(hostHeader: string | null | undefined, allowed: ReadonlySet<string>): boolean {
  if (!hostHeader) return false;
  return allowed.has(hostHeader.trim().toLowerCase());
}

/**
 * The MiniMax Code remote shell URL on the sidecar:
 * `<origin>/minimax-code/?token=<chatToken>`. The token rides as a query
 * (then Bearer) because the shell page itself is unauthenticated; the
 * sidecar API behind it is Bearer-gated like everything else.
 */
export function minimaxShellUrl(options: { origin: string; chatToken: string }): string {
  const origin = new URL(options.origin);
  if (origin.protocol !== "http:" && origin.protocol !== "https:") {
    throw new Error(`origin must be http(s), got ${origin.protocol}`);
  }
  if (!options.chatToken) throw new Error("chat token is required; is the chat sidecar running?");
  const target = new URL("/minimax-code/", origin);
  target.searchParams.set("token", options.chatToken);
  return target.toString();
}
/**
 * The link that pairs the app with a MiniMax Code server host — a machine
 * that runs only the chat sidecar (`mcode acp` behind
 * `/clutch/v1/sessions`), with no `dsh web` and therefore no launch token:
 * `clutch://pair?h=<tailnet-name>&tls=1&kind=mcode&chat=<t>&chatPort=<p>`.
 * The app stores it as a `miniMaxCode` host and talks to the sidecar
 * directly; the web-canvas and dsh-host surfaces do not apply to it.
 */
export function serverPairingLink(options: {
  host: string;
  name?: string;
  chatToken: string;
  chatPort?: string | undefined;
  tls?: boolean;
}): string {
  const host = options.host.trim().toLowerCase().replace(/^https?:\/\//, "").replace(/\/.*$/, "");
  if (!host) throw new Error("host is required; is tailscale up on the server?");
  if (!options.chatToken) throw new Error("chat token is required; is the chat sidecar running on the server?");
  const link = new URL("clutch://pair");
  link.searchParams.set("h", host);
  link.searchParams.set("tls", options.tls === false ? "0" : "1");
  link.searchParams.set("kind", "mcode");
  link.searchParams.set("chat", options.chatToken);
  if (options.chatPort) link.searchParams.set("chatPort", options.chatPort);
  if (options.name) link.searchParams.set("name", options.name);
  return link.toString();
}

/**
 * The link the iOS app pairs from:
 * `clutch://pair?url=<origin>/?token=<t>&name=<label>`.
 * `origin` is where the phone reaches clutch web, e.g.
 * `https://<magicdns>:3180` over Tailscale or `http://127.0.0.1:3180` for the Simulator.
 * `chatToken` (the chat-bridge Bearer token) rides along as `&chat=` when the
 * sidecar has minted one; the app stores it for `/clutch/v1/chat` calls.
 */
export function pairingLink(options: {
  launchUrl: string;
  origin: string;
  name?: string;
  chatToken?: string | undefined;
  chatPort?: string | undefined;
}): string {
  const token = launchToken(options.launchUrl);
  if (token === null) throw new Error("launch URL has no token; is clutch web running?");
  const origin = new URL(options.origin);
  if (origin.protocol !== "http:" && origin.protocol !== "https:") {
    throw new Error(`origin must be http(s), got ${origin.protocol}`);
  }
  const target = new URL("/", origin);
  target.searchParams.set("token", token);
  const link = new URL("clutch://pair");
  link.searchParams.set("url", target.toString());
  if (options.name) link.searchParams.set("name", options.name);
  if (options.chatToken) link.searchParams.set("chat", options.chatToken);
  if (options.chatPort) link.searchParams.set("chatPort", options.chatPort);
  return link.toString();
}
