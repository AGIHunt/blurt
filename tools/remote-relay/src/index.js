// Blurt's iPhone relay. A phone and its Mac each open a WebSocket to the same room and bytes pass between them. It can't read
// them: they're the same sealed frames as on the local network, with keys the relay never sees. It stores nothing, and a room
// holds one Mac and one phone at most. The room's name is an HMAC of the pair's key, so it can't be guessed and says
// nothing about who is in it.
import { DurableObject } from "cloudflare:workers";

const ROOM = /^[A-Za-z0-9_-]{43}$/;
const MAX_MESSAGE = 1 << 20;

// close codes the apps read
const PHONE_LEFT = 4000;   // the Mac reconnects: the next phone starts a new session
const MAC_GONE = 4001;     // the phone's "Mac isn't reachable"
const REPLACED = 4002;     // a newer connection in the same role took over

// equal strings, in time that doesn't depend on where they differ
async function same(a, b) {
  const [x, y] = await Promise.all([a, b].map((s) => crypto.subtle.digest("SHA-256", new TextEncoder().encode(s))));
  return crypto.subtle.timingSafeEqual(x, y);
}

export default {
  async fetch(req, env) {
    // RELAY_SECRET (a secret: `wrangler secret put RELAY_SECRET`) is a path only your devices know: wss://host/<secret>/v1/…
    const m = new URL(req.url).pathname.match(/^(?:\/([^/]+))?\/v1\/([^/]+)\/(mac|phone)$/);
    const secret = env.RELAY_SECRET || "";
    if (!m || !ROOM.test(m[2]) || !(secret ? m[1] !== undefined && await same(m[1], secret) : m[1] === undefined)) {
      return new Response("Not found", { status: 404 });
    }
    if (req.headers.get("Upgrade")?.toLowerCase() !== "websocket") return new Response("Expected a WebSocket", { status: 426 });
    return env.ROOM.get(env.ROOM.idFromName(m[2])).fetch(new Request(`https://room/${m[3]}`, req));
  },
};

export class Room extends DurableObject {
  async fetch(req) {
    const role = new URL(req.url).pathname.slice(1);
    for (const old of this.ctx.getWebSockets(role)) { try { old.close(REPLACED, "replaced"); } catch {} }
    const other = this.open(role === "mac" ? "phone" : "mac");
    const pair = new WebSocketPair();
    this.ctx.acceptWebSocket(pair[1], [role]);
    // a phone with no Mac there hears so at once, and its leaving says nothing to a Mac that comes in meanwhile
    if (role === "phone" && other.length === 0) {
      pair[1].serializeAttachment({ refused: true });
      pair[1].close(MAC_GONE, "no mac");
    }
    return new Response(null, { status: 101, webSocket: pair[0] });
  }

  // a peer that vanished stays listed, closing, until the runtime gives up on it: it must not stop bytes reaching the live one
  open(role) { return this.ctx.getWebSockets(role).filter((w) => w.readyState === WebSocket.READY_STATE_OPEN); }

  webSocketMessage(ws, msg) {
    const size = typeof msg === "string" ? msg.length : msg.byteLength;
    if (size > MAX_MESSAGE) return ws.close(1009, "too big");
    if (ws.readyState !== WebSocket.READY_STATE_OPEN) return;   // replaced: nothing it says counts any more
    const role = this.ctx.getTags(ws)[0];
    for (const o of this.open(role === "mac" ? "phone" : "mac")) { try { o.send(msg); } catch {} }
  }

  webSocketClose(ws) { this.left(ws); }
  webSocketError(ws) { this.left(ws); }

  left(ws) {
    if (ws.deserializeAttachment()?.refused) return;
    const role = this.ctx.getTags(ws)[0];
    if (this.open(role).some((w) => w !== ws)) return;   // it was replaced: the new one is already in its place
    for (const o of this.open(role === "mac" ? "phone" : "mac")) {
      try { role === "mac" ? o.close(MAC_GONE, "mac left") : o.close(PHONE_LEFT, "phone left"); } catch {}
    }
  }
}
