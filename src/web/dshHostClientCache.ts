import { DshHostTransportError } from "./dshHostClient.ts";

/** Cache a host identity until the host refuses it.  Do not replay a failed request. */
export class DshHostClientCache<T> {
  private client: T | null = null;
  private failedAt: number | null = null;

  constructor(
    private readonly connect: () => Promise<T>,
    private readonly now: () => number = Date.now,
    private readonly cooldownMs = 30_000,
  ) {}

  async run<R>(read: (client: T) => Promise<R>): Promise<R> {
    const client = await this.get();
    try {
      return await read(client);
    } catch (error) {
      if (
        error instanceof DshHostTransportError &&
        (error.status === 401 || error.status === 404) &&
        this.client === client
      ) {
        this.client = null;
        this.failedAt = null;
      }
      throw error;
    }
  }

  private async get(): Promise<T> {
    if (this.client !== null) return this.client;
    if (this.failedAt !== null && this.now() - this.failedAt < this.cooldownMs) {
      throw new Error("the dsh host is not reachable");
    }
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
