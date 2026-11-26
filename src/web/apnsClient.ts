/**
 * The APNs client the host uses to push a Live Activity update.
 *
 * Apple pushes a Live Activity with a provider token:  a short-lived JWT the
 * server signs with its own key, sent in the `authorization` header of every
 * request.  The token is minted from three names (the key id, the team id and
 * the `.p8` key), it lives for an hour, and the client keeps one for fifty
 * minutes so a request never rides a token that is about to expire.
 *
 * The client is deliberately small and mostly pure:  the signing is a function
 * of its inputs, and the transport is injectable, so the parts that can be
 * tested are tested without a network and without a real key.
 *
 * Nothing here ever logs the device token, the provider token or the key.
 * The device token is in the request path, so a failure is reported by its
 * status and its reason and never by its URL.
 */

import { createPrivateKey, sign, type KeyObject } from "node:crypto";
import { connect } from "node:http2";
import { z } from "zod";

/** Which APNs the token belongs to. */
export type ApnsEnvironment = "Sandbox" | "Production";

/** How long a provider token is kept before a new one is minted. */
export const APNS_TOKEN_TTL_MS = 50 * 60 * 1000;

/** How long one push request may hang before it counts as failed. */
export const APNS_REQUEST_TIMEOUT_MS = 10_000;

/** The push type Apple's Live Activity updates carry. */
export const APNS_LIVE_ACTIVITY_PUSH_TYPE = "liveactivity";

/**
 * The topic the Clutch iOS app's Live Activity pushes are addressed to.
 *
 * Apple requires the `.push-type.liveactivity` suffix here: the bare bundle
 * id is the ordinary-notification topic, and a Live Activity push sent to it
 * is refused with `BadTopic`.
 */
export const CLUTCH_IOS_PUSH_TOPIC = "codes.clutch.ios.push-type.liveactivity";

/** What the provider token is made of. */
export interface ApnsJwtInput {
  /** The key id Apple issued with the `.p8` key. */
  readonly keyId: string;
  /** The Apple developer team the key belongs to. */
  readonly teamId: string;
  /** The signing key:  a PEM, or an already parsed key. */
  readonly privateKey: KeyObject | string;
  /** When the token was issued, in seconds since the epoch. */
  readonly issuedAtSeconds: number;
}

/** One request, as the transport sees it. */
export interface ApnsTransportRequest {
  readonly host: string;
  readonly path: string;
  readonly headers: Readonly<Record<string, string>>;
  readonly body: string;
}

/** What the transport answers with. */
export interface ApnsTransportResponse {
  readonly status: number;
  readonly body: string;
}

/** How a request reaches APNs.  Injectable so the client can be tested. */
export type ApnsTransport = (request: ApnsTransportRequest) => Promise<ApnsTransportResponse>;

/** One push, as the caller describes it. */
export interface ApnsPushRequest {
  /** The device's push token, in hex. */
  readonly deviceToken: string;
  /** Which APNs the token belongs to. */
  readonly environment: ApnsEnvironment;
  /** The payload, already built. */
  readonly payload: unknown;
  /** When the push may be dropped, in seconds since the epoch. */
  readonly expirationSeconds?: number;
  /** 10 for an update the owner should see now, 5 for one that may wait. */
  readonly priority?: 5 | 10;
  /** The topic, when it is not the app's own. */
  readonly topic?: string;
}

/** What APNs answered. */
export interface ApnsPushResult {
  /** The HTTP status:  200 is a delivered push. */
  readonly status: number;
  /** Apple's reason, when it gave one. */
  readonly reason?: string;
}

/** Encode bytes the way a JWT does:  base64url, without the padding. */
export function base64url(input: Buffer | string): string {
  return Buffer.from(input)
    .toString("base64")
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
}

/**
 * Mint a provider token.
 *
 * The token is an ES256 JWT:  the header names the algorithm and the key id,
 * the claims name the team and the moment the token was issued, and the
 * signature is the raw `R||S` pair over the two encoded halves.  `ieee-p1363`
 * is what makes the signature raw:  no DER wrapping, so nothing has to be
 * unwrapped afterwards.
 *
 * The `iat` claim is in seconds, the way Apple's provider tokens are:  a
 * millisecond stamp would read as a token issued in the far future, and the
 * request would be refused.
 */
export function signApnsJwt(input: ApnsJwtInput): string {
  const header = base64url(JSON.stringify({ alg: "ES256", kid: input.keyId }));
  const claims = base64url(JSON.stringify({ iss: input.teamId, iat: input.issuedAtSeconds }));
  const signingInput = `${header}.${claims}`;
  const key = typeof input.privateKey === "string" ? createPrivateKey(input.privateKey) : input.privateKey;
  const signature = sign("sha256", Buffer.from(signingInput, "utf8"), { key, dsaEncoding: "ieee-p1363" });
  return `${signingInput}.${base64url(signature)}`;
}

/**
 * Apple's documented APNs reason strings.
 *
 * The reason rides in an error body that comes back over the network, and it
 * goes into the sidecar log.  An allowlist means a hostile answer cannot put
 * its own words into the log line; anything off the list reads as no reason
 * at all, and the status still tells the truth.
 */
const APNS_REASON_ALLOWLIST = new Set([
  "BadCollapseId",
  "BadDeviceToken",
  "BadExpirationDate",
  "BadMessageId",
  "BadPriority",
  "BadTopic",
  "DeviceTokenNotForTopic",
  "DuplicateHeaders",
  "IdleTimeout",
  "InvalidMessageId",
  "InvalidPushSize",
  "MissingDeviceToken",
  "MissingTopic",
  "PayloadEmpty",
  "TopicDisallowed",
  "BadCertificate",
  "BadCertificateEnvironment",
  "ExpiredProviderToken",
  "InvalidProviderToken",
  "MissingProviderToken",
  "TooManyProviderTokenUpdates",
  "TooManyRequests",
  "InternalServerError",
  "ServiceUnavailable",
  "Shutdown",
  "PayloadNotAllowableTopic",
  "Unregistered",
]);

/** Apple's error body, validated before any field is read. */
export const ApnsErrorSchema = z.object({
  /** Apple's static reason string, when the body carries one. */
  reason: z.string().optional(),
  description: z.string().optional(),
  timestamp: z.number().optional(),
});

/** Read Apple's reason out of an error body, when it gave one. */
function reasonFrom(body: string): string | undefined {
  let parsed: unknown;
  try {
    parsed = JSON.parse(body);
  } catch {
    /* not JSON at all */
    return undefined;
  }
  const parsedError = ApnsErrorSchema.safeParse(parsed);
  if (!parsedError.success) return undefined;
  const reason = parsedError.data.reason;
  if (typeof reason === "string" && APNS_REASON_ALLOWLIST.has(reason)) return reason;
  return undefined;
}

/** The host a token is pushed to. */
export function apnsHost(environment: ApnsEnvironment): string {
  return environment === "Production" ? "api.push.apple.com" : "api.sandbox.push.apple.com";
}

/**
 * The transport that really talks to APNs.
 *
 * The request is one HTTP/2 stream:  the device token is in the path, so the
 * stream is closed as soon as the answer is in, and a failure is reported by
 * its status rather than by its URL.
 */
export const http2ApnsTransport: ApnsTransport = (request) =>
  new Promise<ApnsTransportResponse>((resolve) => {
    let settled = false;
    let client: ReturnType<typeof connect> | undefined;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const finish = (response: ApnsTransportResponse): void => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve(response);
      // Every request opens its own session, so it must die with the answer:
      // an unclosed client is a leaked socket, and APNs hands out no reuse
      // benefit worth keeping one alive for a single push.
      try {
        client?.close();
      } catch {
        /* the session is already gone */
      }
    };
    try {
      client = connect(`https://${request.host}`);
    } catch {
      finish({ status: 0, body: "" });
      return;
    }
    timer = setTimeout(() => finish({ status: 0, body: "" }), APNS_REQUEST_TIMEOUT_MS);
    client.on("error", () => finish({ status: 0, body: "" }));
    const stream = client.request({
      ":method": "POST",
      ":path": request.path,
      ...request.headers,
    });
    let body = "";
    stream.on("response", (headers) => {
      const status = Number(headers[":status"] ?? 0);
      stream.on("data", (chunk: Buffer) => {
        body += chunk.toString("utf8");
      });
      stream.on("end", () => finish({ status, body }));
      stream.on("error", () => finish({ status: 0, body: "" }));
    });
    stream.on("error", () => finish({ status: 0, body: "" }));
    stream.end(request.body);
  });

/**
 * The client the relay pushes through.
 *
 * It holds the provider token, mints a new one when the old one is close to
 * its end, and turns every answer into a status and a reason.
 */
export class ApnsClient {
  /** The provider token in hand, and when it was minted. */
  private token: { jwt: string; at: number } | null = null;

  constructor(private readonly options: {
    readonly keyId: string;
    readonly teamId: string;
    readonly privateKey: KeyObject | string;
    readonly topic: string;
    readonly now?: () => number;
    readonly transport?: ApnsTransport;
  }) {}

  /** The provider token, minted when the last one is gone or nearly gone. */
  providerToken(): string {
    const now = this.options.now?.() ?? Date.now();
    if (this.token && now - this.token.at < APNS_TOKEN_TTL_MS) return this.token.jwt;
    const issuedAtSeconds = Math.floor(now / 1000);
    const jwt = signApnsJwt({
      keyId: this.options.keyId,
      teamId: this.options.teamId,
      privateKey: this.options.privateKey,
      issuedAtSeconds,
    });
    this.token = { jwt, at: now };
    return jwt;
  }

  /** Push one Live Activity update. */
  async sendLiveActivity(request: ApnsPushRequest): Promise<ApnsPushResult> {
    const transport = this.options.transport ?? http2ApnsTransport;
    const headers: Record<string, string> = {
      authorization: `bearer ${this.providerToken()}`,
      "apns-topic": request.topic ?? this.options.topic,
      "apns-push-type": APNS_LIVE_ACTIVITY_PUSH_TYPE,
      "apns-priority": String(request.priority ?? 10),
      "apns-expiration": String(request.expirationSeconds ?? 0),
      "content-type": "application/json",
    };
    try {
      const response = await transport({
        host: apnsHost(request.environment),
        path: `/3/device/${request.deviceToken}`,
        headers,
        body: JSON.stringify(request.payload),
      });
      const reason = reasonFrom(response.body);
      return { status: response.status, ...(reason ? { reason } : {}) };
    } catch {
      // The failure never carries the URL:  the device token is in the path.
      return { status: 0, reason: "transport-error" };
    }
  }
}
