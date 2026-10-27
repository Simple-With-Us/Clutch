import { DshHostHandshakeError, DshHostTransportError } from "./dshHostClient.ts";

/** Cache a host identity until the host refuses it.  Do not replay a failed request. */
export class DshHostClientCache<T> {
  private client: T | null = null;
  private failedAt: number | null = null;
  private pending: Promise<T> | null = null;
  private refusals = 0;

  constructor(
    private readonly connect: () => Promise<T>,
    private readonly now: () => number = Date.now,
    private readonly cooldownMs = 30_000,
  ) {}

  async run<R>(read: (client: T) => Promise<R>): Promise<R> {
    const client = await this.get();
    try {
      const result = await read(client);
      this.refusals = 0;
      return result;
    } catch (error) {
      this.noteFailure(client, error);
      throw error;
    }
  }

  /**
   * Record a failure from a read made through a client this cache handed out.
   *
   * A client held across a stream or a turn cannot go through run(), so its
   * owner reports the error here.  A refused identity (401, 404 or a failed
   * handshake) on the client still in use drops it, so the next read exchanges
   * a fresh one; two refusals in a row start the cooldown.  Any other error,
   * or an error from a client the cache already replaced, changes nothing.
   */
  noteFailure(client: T, error: unknown): void {
    if (
      error instanceof DshHostTransportError &&
      (error.status === 401 || error.status === 404 || error instanceof DshHostHandshakeError) &&
      this.client === client
    ) {
      this.client = null;
      this.refusals += 1;
      this.failedAt = this.refusals >= 2 ? this.now() : null;
    }
  }

  private async get(): Promise<T> {
    if (this.client !== null) return this.client;
    if (this.failedAt !== null && this.now() - this.failedAt < this.cooldownMs) {
      throw new Error("the dsh host is not reachable");
    }
    if (this.pending !== null) return this.pending;
    this.pending = this.open();
    try {
      return await this.pending;
    } finally {
      this.pending = null;
    }
  }

  private async open(): Promise<T> {
    try {
      this.client = await this.connect();
      this.failedAt = null;
      return this.client;
    } catch (error) {
      this.failedAt = this.now();
      throw error;
    }
  }
}
