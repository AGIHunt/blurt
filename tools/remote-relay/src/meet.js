// Blurt's public go-between at meet.blurt.work (docs/design/remote-go-between.md). The relay's protocol and close codes (src/index.js),
// on a strict budget: a phone and its computer meet here, do the handshake, trade addresses and open the direct UDP path, then move
// everything onto it. What passes is sealed end to end; nothing is stored. It is public, so there is no secret path, and it binds
// nothing but its Durable Object.
import { DurableObject } from "cloudflare:workers";
import { noteMacLeft, peek } from "./index.js";

const PATH = /^\/v1\/([A-Za-z0-9_-]{43})\/(mac|phone|peek)$/;

// the budget per WebSocket connection, counted on what that connection sends
const KiB = 1024;
const MAX_MESSAGE = 16 * KiB;
const MAX_TOTAL = 96 * KiB;
const MAX_WINDOW = 24 * KiB;   // in any 5 s
const WINDOW_MS = 5000;
const SLOT_MS = 250;           // the window is kept as 250 ms slots, so it can look back up to 5.25 s: never less than 5 s
const PHONE_MAX_MS = 12 * 3600 * 1000;

// close codes the apps read
const PHONE_LEFT = 4000;   // the computer reconnects: the next phone starts a new session
const MAC_GONE = 4001;     // the phone's "computer isn't reachable"
const REPLACED = 4002;     // a newer connection in the same role took over
const BUDGET = 4003;       // "the go-between can't carry this": both ends hear it

// adds a message to a connection's counters; false once it passes a limit
function spend(c, size, now) {
  if (size > MAX_MESSAGE) return false;
  c.total += size;
  if (c.total > MAX_TOTAL) return false;
  const slot = Math.floor(now / SLOT_MS);
  c.slots = c.slots.filter(([s]) => s >= slot - WINDOW_MS / SLOT_MS);
  const last = c.slots[c.slots.length - 1];
  if (last && last[0] === slot) last[1] += size; else c.slots.push([slot, size]);
  return c.slots.reduce((n, [, b]) => n + b, 0) <= MAX_WINDOW;
}

export default {
  async fetch(req, env) {
    const path = new URL(req.url).pathname;
    if (path === "/" && (req.method === "GET" || req.method === "HEAD")) {
      return new Response("blurt go-between", { headers: { "Content-Type": "text/plain; charset=utf-8" } });
    }
    // anything else that isn't a room costs no Durable Object request
    const m = path.match(PATH);
    if (!m) return new Response("Not found", { status: 404 });
    // GET …/peek: is its computer waiting, and since when it's asleep or last seen (paired devices only know the room)
    if (m[2] === "peek") return req.method === "GET" ? env.MEET.get(env.MEET.idFromName(m[1])).fetch("https://meet/peek") : new Response("Not found", { status: 404 });
    if (req.headers.get("Upgrade")?.toLowerCase() !== "websocket") return new Response("Expected a WebSocket", { status: 426 });
    return env.MEET.get(env.MEET.idFromName(m[1])).fetch(new Request(`https://meet/${m[2]}`, req));
  },
};

export class Meet extends DurableObject {
  async fetch(req) {
    const role = new URL(req.url).pathname.slice(1);
    if (role === "peek") return peek(this);
    for (const old of this.ctx.getWebSockets(role)) { try { old.close(REPLACED, "replaced"); } catch {} }
    const other = this.open(role === "mac" ? "phone" : "mac");
    const pair = new WebSocketPair();
    this.ctx.acceptWebSocket(pair[1], [role]);
    // the counters live in the attachment, so they survive hibernation
    const c = { opened: Date.now(), total: 0, slots: [] };
    // a phone with no computer there hears so at once, and its leaving says nothing to a computer that comes in meanwhile
    if (role === "phone" && other.length === 0) {
      pair[1].serializeAttachment({ ...c, refused: true });
      pair[1].close(MAC_GONE, "no mac");
    } else {
      pair[1].serializeAttachment(c);
      // the only phone in the room is this one, so the alarm is its 12 hours
      if (role === "phone") await this.ctx.storage.setAlarm(c.opened + PHONE_MAX_MS);
    }
    return new Response(null, { status: 101, webSocket: pair[0] });
  }

  // a peer that vanished stays listed, closing, until the runtime gives up on it: it must not stop bytes reaching the live one
  open(role) { return this.ctx.getWebSockets(role).filter((w) => w.readyState === WebSocket.READY_STATE_OPEN); }

  webSocketMessage(ws, msg) {
    if (ws.readyState !== WebSocket.READY_STATE_OPEN) return;   // replaced or over budget: nothing it says counts any more
    const size = typeof msg === "string" ? new TextEncoder().encode(msg).byteLength : msg.byteLength;
    const c = ws.deserializeAttachment();
    if (!spend(c, size, Date.now())) return this.overBudget();
    ws.serializeAttachment(c);
    const role = this.ctx.getTags(ws)[0];
    for (const o of this.open(role === "mac" ? "phone" : "mac")) { try { o.send(msg); } catch {} }
  }

  // the session can't go on here: both ends hear why
  overBudget() {
    for (const ws of [...this.open("mac"), ...this.open("phone")]) { try { ws.close(BUDGET, "budget"); } catch {} }
  }

  async alarm() {
    const now = Date.now();
    const phones = this.open("phone");
    const ends = phones.map((w) => w.deserializeAttachment().opened + PHONE_MAX_MS);
    if (ends.some((end) => end <= now)) return this.overBudget();
    if (ends.length) await this.ctx.storage.setAlarm(Math.min(...ends));
  }

  webSocketClose(ws, code) { noteMacLeft(this, ws, code); this.left(ws); }
  webSocketError(ws) { noteMacLeft(this, ws, 1006); this.left(ws); }

  left(ws) {
    if (ws.deserializeAttachment()?.refused) return;
    const role = this.ctx.getTags(ws)[0];
    if (this.open(role).some((w) => w !== ws)) return;   // it was replaced: the new one is already in its place
    for (const o of this.open(role === "mac" ? "phone" : "mac")) {
      try { role === "mac" ? o.close(MAC_GONE, "mac left") : o.close(PHONE_LEFT, "phone left"); } catch {}
    }
  }
}
