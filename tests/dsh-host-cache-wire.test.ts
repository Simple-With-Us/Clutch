import { createServer } from "node:http";
import { createHash } from "node:crypto";
import { once } from "node:events";
import { describe, expect, it } from "vitest";
import { DshHostClient, DshHostHandshakeError, DshHostTransportError } from "../src/web/dshHostClient.ts";
import { DshHostClientCache } from "../src/web/dshHostClientCache.ts";
import { loadDshHostHistory } from "../src/web/dshHostSessions.ts";

describe("real local transport refusal recovery", () => {
  for (const path of ["unary", "mux"]) {
    it(`exchanges a fresh cookie after ${path} refusal`, async () => {
      let exchanges = 0;
      const cookies: string[] = [];
      const sockets = new Set<import("node:net").Socket>();
      const server = createServer((req, res) => {
        if (req.url?.startsWith("/launch")) {
          exchanges += 1;
          res.writeHead(200, { "set-cookie": `identity=${exchanges}; Path=/` }).end("ok");
          return;
        }
        if (req.url === "/api/session/list") {
          cookies.push(req.headers.cookie ?? "");
          if (req.headers.cookie === "identity=1") res.writeHead(401).end();
          else res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify({ type: "server-response", rpcId: "fixture", result: { ok: true, value: { items: [] } } }));
          return;
        }
        res.writeHead(404).end();
      });
      server.on("connection", (socket) => { sockets.add(socket); socket.on("close", () => sockets.delete(socket)); });
      server.on("upgrade", (req, socket) => {
        cookies.push(req.headers.cookie ?? "");
        if (req.headers.cookie === "identity=1") {
          socket.end("HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n");
          return;
        }
        const key = req.headers["sec-websocket-key"];
        if (typeof key !== "string") { socket.destroy(); return; }
        const accept = createHash("sha1").update(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest("base64");
        socket.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
        socket.once("data", (frame) => {
          const len = frame[1]! & 127;
          const offset = len === 126 ? 4 : 2;
          const size = len === 126 ? frame.readUInt16BE(2) : len;
          const mask = frame.subarray(offset, offset + 4);
          const payload = Buffer.from(frame.subarray(offset + 4, offset + 4 + size));
          for (let i = 0; i < payload.length; i++) payload[i] = payload[i]! ^ mask[i % 4]!;
          const opened = JSON.parse(payload.toString());
          const response = Buffer.from(JSON.stringify({ type: "item", streamId: opened.streamId, value: { type: "snapshot", records: [] } }));
          const header = response.length < 126 ? Buffer.from([0x81, response.length]) : Buffer.from([0x81, 126, response.length >> 8, response.length & 255]);
          socket.write(Buffer.concat([header, response]));
        });
      });
      server.listen(0, "127.0.0.1");
      await once(server, "listening");
      const address = server.address();
      if (address === null || typeof address === "string") throw new Error("fixture address");
      const cache = new DshHostClientCache(() => DshHostClient.connect({ launchUrl: `http://127.0.0.1:${address.port}/launch?token=fixture` }));
      const read = (client: DshHostClient) => path === "unary" ? client.call("session/list") : loadDshHostHistory(client, { sessionId: "fixture" });
      try {
        const error = await cache.run(read).catch((err: unknown) => err);
        expect(error).toBeInstanceOf(path === "unary" ? DshHostTransportError : DshHostHandshakeError);
        expect(exchanges).toBe(1);
        await cache.run(read);
        expect(exchanges).toBe(2);
        // The runtime may retry a refused upgrade internally.  Verify identity
        // rotation rather than the implementation-specific handshake count.
        expect(cookies[0]).toBe("identity=1");
        expect(cookies.at(-1)).toBe("identity=2");
        expect(new Set(cookies)).toEqual(new Set(["identity=1", "identity=2"]));
        const freshAt = cookies.indexOf("identity=2");
        expect(cookies.slice(freshAt).every((cookie) => cookie === "identity=2")).toBe(true);
      } finally {
        for (const socket of sockets) socket.destroy();
        server.close();
        await once(server, "close");
      }
    });
  }
});
