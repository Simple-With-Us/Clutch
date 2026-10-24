import { spawn } from "node:child_process";

/**
 * How long one `tailscale status` call may take.  Detection runs before the
 * sidecar listens, so a CLI left waiting on a wedged tailscaled would keep the
 * bridge from ever starting; past this the call counts as "no tailnet yet".
 */
export const TAILNET_STATUS_TIMEOUT_MS = 3000;

/**
 * Run `tailscale status --self --json` and parse the JSON it prints.
 *
 * The timeout is the whole point: `tailscale status` can block indefinitely on a
 * wedged tailscaled, and every caller waits on this before it starts serving.
 * Without the bound, one hung CLI wedges startup forever instead of falling
 * through to "no tailnet yet".
 */
export function readTailnetStatus(
  timeoutMs: number = TAILNET_STATUS_TIMEOUT_MS,
  command: string = "tailscale",
): Promise<unknown> {
  return new Promise((resolvePromise) => {
    let settled = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const settle = (value: unknown): void => {
      if (settled) return;
      settled = true;
      if (timer) clearTimeout(timer);
      resolvePromise(value);
    };
    const child = spawn(command, ["status", "--self", "--json"], { stdio: ["ignore", "pipe", "ignore"] });
    timer = setTimeout(() => {
      child.kill("SIGKILL");
      settle(null);
    }, timeoutMs);
    let out = "";
    child.stdout.on("data", (chunk: Buffer) => {
      out += chunk.toString("utf8");
    });
    child.on("error", () => settle(null));
    // "close", not "exit": the process can be gone while its stdout pipe still
    // holds unread bytes, and "exit" fires before the last chunk is delivered.
    // Settling there parses an empty buffer and reports "no tailnet" for a
    // perfectly healthy machine.
    child.on("close", () => {
      try {
        settle(JSON.parse(out));
      } catch {
        settle(null);
      }
    });
  });
}
