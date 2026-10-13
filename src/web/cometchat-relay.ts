/**
 * CometChat relay — translates the ACP chunk stream into CometChat REST so
 * the iOS kit's socket delivers the agent thread live.
 *
 * Streaming strategy (decided in the spike): create a text message as the
 * agent on the first chunk, apply throttled edits while streaming (at most
 * one PUT per `EDIT_MIN_MS`, plus a final flush on done), and follow up
 * with an interactive card when the turn used tools. CometChat cards are
 * persisted payloads, not live run states, so the running state lives in
 * the edited text and the card is the durable summary.
 *
 * Auth: `COMETCHAT_APP_ID`, `COMETCHAT_REGION` (us|eu|in),
 * `COMETCHAT_REST_API_KEY` (fullAccess, backend-only — never ships in the
 * app), `COMETCHAT_AGENT_UID` (the agent user the backend speaks
 * `onBehalfOf`). Key names only in logs; values never leave this module.
 */
export interface CometChatConfig {
  appId: string;
  region: string;
  restApiKey: string;
  agentUid: string;
}

/**
 * Handoff files quote every value ("KEY=value"); Infisical does not.
 * Accept both so the same parser serves tests, handoff-fed shells, and
 * deployed env without ever caring which source a value came from.
 */
export function cleanEnvValue(raw: string | undefined): string {
  const t = (raw ?? "").trim();
  if (t.length >= 2 && t.startsWith('"') && t.endsWith('"')) return t.slice(1, -1).trim();
  return t;
}

export function cometchatConfigFromEnv(
  env: Record<string, string | undefined> = process.env,
): CometChatConfig | null {
  const appId = cleanEnvValue(env.COMETCHAT_APP_ID);
  const region = cleanEnvValue(env.COMETCHAT_REGION);
  const restApiKey = cleanEnvValue(env.COMETCHAT_REST_API_KEY);
  // The agent identity defaults like chat-config: the handoff only carries
  // dashboard credentials, not the uid the backend speaks on behalf of.
  const agentUid = cleanEnvValue(env.COMETCHAT_AGENT_UID) || "clutch-agent";
  if (!appId || !region || !restApiKey || !agentUid) return null;
  return { appId, region, restApiKey, agentUid };
}

export function cometchatApiBase(config: Pick<CometChatConfig, "appId" | "region">): string {
  // COMETCHAT_API_BASE exists for the full-loop test, which points the relay
  // at a local stub. Production always uses the regional endpoint below.
  const override = process.env.COMETCHAT_API_BASE?.trim().replace(/\/+$/, "");
  if (override) return override;
  return `https://${config.appId}.api-${config.region}.cometchat.io/v3`;
}

export interface TextTarget {
  receiver: string;
  receiverType: "user" | "group";
}

interface RestDeps {
  fetchFn?: typeof fetch;
  onLog?: (line: string) => void;
}

async function rest(
  config: CometChatConfig,
  deps: RestDeps,
  method: string,
  path: string,
  body: unknown,
): Promise<{ id?: unknown } & Record<string, unknown>> {
  const fetchFn = deps.fetchFn ?? fetch;
  const res = await fetchFn(`${cometchatApiBase(config)}${path}`, {
    method,
    headers: {
      "content-type": "application/json",
      apikey: config.restApiKey,
      onBehalfOf: config.agentUid,
    },
    body: JSON.stringify(body),
  });
  if (!res.ok) {
    throw new Error(`cometchat ${method} ${path} -> ${res.status}`);
  }
  return (await res.json()) as { id?: unknown } & Record<string, unknown>;
}

function messageIdOf(result: { id?: unknown; data?: unknown }, what: string): string {
  // Creates return {data: {id}} with no top-level id (probe-verified
  // against the live API); accept both shapes.
  const data = (result.data ?? {}) as { id?: unknown };
  const raw = result.id ?? data.id;
  if (typeof raw !== "string" && typeof raw !== "number") {
    throw new Error(`cometchat ${what} returned no id`);
  }
  return String(raw);
}

export class CometChatRelay {
  constructor(
    private config: CometChatConfig,
    private deps: RestDeps = {},
  ) {}

  private log(line: string): void {
    this.deps.onLog?.(line);
  }

  /** POST /messages — the agent's text bubble. Returns the message id. */
  async sendText(target: TextTarget, text: string): Promise<string> {
    const result = await rest(this.config, this.deps, "POST", "/messages", {
      receiver: target.receiver,
      receiverType: target.receiverType,
      category: "message",
      type: "text",
      data: { text },
    });
    const id = messageIdOf(result, "send");
    this.log(`cometchat-relay: sent text message=${id} chars=${text.length}`);
    return id;
  }

  /** PUT /messages/{id} — progressive streaming edit. */
  async editText(messageId: string, text: string): Promise<void> {
    await rest(this.config, this.deps, "PUT", `/messages/${encodeURIComponent(messageId)}`, {
      category: "message",
      type: "text",
      data: { text },
    });
    this.log(`cometchat-relay: edited message=${messageId} chars=${text.length}`);
  }

  /**
   * Interactive card for a finished tool call — the durable summary after
   * the running state streamed as text.
   */
  async sendToolCard(
    target: TextTarget,
    options: { title: string; summary: string; actions?: { id: string; label: string }[] },
  ): Promise<string> {
    const result = await rest(this.config, this.deps, "POST", "/messages", {
      receiver: target.receiver,
      receiverType: target.receiverType,
      category: "interactive",
      type: "card",
      data: {
        interactiveData: {
          text: options.summary,
          title: options.title,
          cardActions: (options.actions ?? []).map((a) => ({
            elementType: "button",
            elementId: a.id,
            buttonText: a.label,
            disableAfterInteracted: true,
          })),
        },
        interactionGoal: { type: "none", elementIds: [] },
        allowSenderInteraction: false,
      },
    });
    const id = messageIdOf(result, "card");
    this.log(`cometchat-relay: sent card message=${id} titleChars=${options.title.length}`);
    return id;
  }
}

export const RELAY_EDIT_MIN_MS = 1000;

export interface StreamSink {
  onUpdate: (kind: "agent_message_chunk" | "agent_thought_chunk", text: string) => void;
  onDone: () => Promise<void>;
}

/**
 * Buffers one turn's text: creates the CometChat message on the first
 * chunk, throttles edits to one per RELAY_EDIT_MIN_MS, flushes on done.
 * Thought chunks stream into the same bubble (the kit has no first-class
 * reasoning block; the native tab keeps its own disclosure UI).
 */
export function createStreamSink(
  relay: CometChatRelay,
  target: TextTarget,
  now: () => number = Date.now,
): StreamSink {
  let full = "";
  let messageId: string | null = null;
  let lastEdit = 0;
  let failed: Error | null = null;
  // Serialized tail of per-chunk work. Without this, a fast onDone can run
  // while the first create is still in flight and send the text twice.
  let pending: Promise<void> = Promise.resolve();

  const fail = (err: unknown): void => {
    if (!failed) failed = err instanceof Error ? err : new Error(String(err));
  };

  return {
    onUpdate: (_kind, text) => {
      if (failed) return;
      full += text;
      pending = pending.then(async () => {
        try {
          if (messageId === null) {
            messageId = await relay.sendText(target, full);
            lastEdit = now();
          } else if (now() - lastEdit >= RELAY_EDIT_MIN_MS) {
            lastEdit = now();
            await relay.editText(messageId, full);
          }
        } catch (err) {
          fail(err);
        }
      });
    },
    onDone: async () => {
      await pending;
      if (failed) throw failed;
      if (messageId === null) {
        if (full.length > 0) await relay.sendText(target, full);
        return;
      }
      await relay.editText(messageId, full);
    },
  };
}
