#!/usr/bin/env node
// Blurt's iPhone relay for your own server: the same protocol as the Cloudflare Worker (src/index.js), in one Node process. A phone and
// its Mac each open a WebSocket to the same room and bytes pass between them. It can't read them and it stores nothing.
//
//   HOST=127.0.0.1 PORT=8787 RELAY_SECRET=<random> node server.js
//
// RELAY_SECRET (at least 16 of A-Z a-z 0-9 _ -) is a path only your devices know: the relay then answers wss://host/<secret>/v1/… and
// nothing else, so a stranger who finds the host can't use it as a free pipe. Blurt's address is then wss://host/<secret>.
//
// Behind a web server for wss://, or on an open port for ws://. See README.md.
//
// BUDGET=1 applies the limits of Blurt's public go-between (src/meet.js, docs/design/remote-go-between.md), so it can be tested end to end
// without Cloudflare: per connection, 16 KiB a message, 96 KiB in all and 24 KiB in any 5 s, then both ends get 4003; a phone stays
// at most 12 h. `GET /` then answers "blurt go-between".
"use strict";
const http = require("http");
const { WebSocketServer, WebSocket } = require("ws");

const HOST = process.env.HOST || "127.0.0.1";
const PORT = Number(process.env.PORT || 8787);
const crypto = require("crypto");
const SECRET = process.env.RELAY_SECRET || "";
if (SECRET && !/^[A-Za-z0-9_-]{16,}$/.test(SECRET)) { console.error("RELAY_SECRET: at least 16 of A-Z a-z 0-9 _ -"); process.exit(2); }
const PATH = /^(?:\/([A-Za-z0-9_-]+))?\/v1\/([A-Za-z0-9_-]{43})\/(mac|phone|peek)$/;
const same = (a, b) => a.length === b.length && crypto.timingSafeEqual(Buffer.from(a), Buffer.from(b));
// [room, role] when the path is a room and carries the secret (or none is set and it has no prefix)
function route(url) {
  const m = PATH.exec(url);
  if (!m || (SECRET ? !m[1] || !same(m[1], SECRET) : m[1] !== undefined)) return null;
  return [m[2], m[3]];
}
const MAX_MESSAGE = 1 << 20;
const MAX_ROOMS = Number(process.env.MAX_ROOMS || 256);
const MAX_PER_ADDRESS = Number(process.env.MAX_PER_ADDRESS || 32);
const BEAT = 30000;
// what a slow peer may fall behind by: the bytes are sealed in sequence, so none can be dropped, and it starts over instead
const MAX_BEHIND = 4 << 20;
// behind your own web server, set this and have it send X-Real-IP
const TRUST_PROXY = process.env.TRUST_PROXY === "1";

// close codes the apps read
const PHONE_LEFT = 4000;   // the Mac reconnects: the next phone starts a new session
const MAC_GONE = 4001;     // the phone's "Mac isn't reachable"
const REPLACED = 4002;     // a newer connection in the same role took over
const OVER_BUDGET = 4003;  // BUDGET=1: "the go-between can't carry this", to both ends
const ASLEEP = 4010;       // from a Mac: it's going to sleep (a peek then says since when)

const BUDGET = process.env.BUDGET === "1";
const KiB = 1024;
const MAX_TOTAL = 96 * KiB, MAX_WINDOW = 24 * KiB, BUDGET_MESSAGE = 16 * KiB;
const WINDOW_MS = 5000, SLOT_MS = 250;   // the window is kept as 250 ms slots, so it looks back 5 to 5.25 s, as in src/meet.js
const PHONE_MAX_MS = 12 * 3600 * 1000;
// adds a message to a connection's counters; false once it passes a limit (the same as src/meet.js)
function spend(c, size, now) {
  if (size > BUDGET_MESSAGE) return false;
  c.total += size;
  if (c.total > MAX_TOTAL) return false;
  const slot = Math.floor(now / SLOT_MS);
  c.slots = c.slots.filter(([s]) => s >= slot - WINDOW_MS / SLOT_MS);
  const last = c.slots[c.slots.length - 1];
  if (last && last[0] === slot) last[1] += size; else c.slots.push([slot, size]);
  return c.slots.reduce((n, [, b]) => n + b, 0) <= MAX_WINDOW;
}

const rooms = new Map();   // room → { mac, phone }
// room → { seen, asleep } (ms): when its Mac last left, and whether it said it was going to sleep. Only for `peek`, which only a
// paired device can ask (the room comes from the pair's key); the oldest go past MAX_SEEN
const seen = new Map();
const MAX_SEEN = 4096;
const perAddress = new Map();

const server = http.createServer((req, res) => {
  if (BUDGET && req.url === "/" && (req.method === "GET" || req.method === "HEAD")) {
    res.writeHead(200, { "Content-Type": "text/plain; charset=utf-8" });
    return res.end("blurt go-between");
  }
  const r = route(req.url);
  // GET …/v1/<room>/peek: is its Mac waiting, and if not, since when it's asleep or last seen (the computer cards' states)
  if (r && r[1] === "peek" && req.method === "GET") {
    const s = seen.get(r[0]) || {};
    res.writeHead(200, { "Content-Type": "application/json", "Cache-Control": "no-store" });
    // Node 12 (README): no ?. or ??
    const room = rooms.get(r[0]);
    const nil = (v) => (v === undefined ? null : v);
    return res.end(JSON.stringify({ host: isOpen(room && room.mac), asleep: nil(s.asleep), seen: nil(s.seen) }));
  }
  const ok = r !== null && r[1] !== "peek";
  res.writeHead(ok ? 426 : 404, { "Content-Type": "text/plain" });
  res.end(ok ? "Expected a WebSocket\n" : "Not found\n");
});
const wss = new WebSocketServer({ noServer: true, maxPayload: MAX_MESSAGE, perMessageDeflate: false });

server.on("upgrade", (req, socket, head) => {
  const m = route(req.url);
  const from = (TRUST_PROXY && req.headers["x-real-ip"]) || req.socket.remoteAddress;
  const held = perAddress.get(from) || 0;
  if (!m || m[1] === "peek" || held >= MAX_PER_ADDRESS || (!rooms.has(m[0]) && rooms.size >= MAX_ROOMS)) return socket.destroy();
  perAddress.set(from, held + 1);
  socket.once("close", () => {
    const n = perAddress.get(from) - 1;
    if (n > 0) perAddress.set(from, n); else perAddress.delete(from);
  });
  socket.setNoDelay(true);
  wss.handleUpgrade(req, socket, head, (ws) => join(ws, m[0], m[1]));
});

function join(ws, id, role) {
  const room = rooms.get(id) || {};
  // a phone with no Mac there hears so at once, and was never in the room: its leaving says nothing to a Mac that comes in meanwhile
  if (role === "phone" && !isOpen(room.mac)) {
    ws.on("error", () => ws.terminate());
    return ws.close(MAC_GONE, "no mac");
  }
  rooms.set(id, room);
  const old = room[role];
  room[role] = ws;
  if (old) old.close(REPLACED, "replaced");
  ws.alive = true;
  ws.on("pong", () => { ws.alive = true; });
  let budget = null, expire = null;
  if (BUDGET) {
    budget = { total: 0, slots: [] };
    if (role === "phone") expire = setTimeout(() => overBudget(room), PHONE_MAX_MS);
  }
  ws.on("message", (data, binary) => {
    if (room[role] !== ws || ws.readyState !== WebSocket.OPEN) return;   // replaced or over budget: nothing it says counts any more
    if (budget && !spend(budget, data.length, Date.now())) return overBudget(room);
    const other = room[role === "mac" ? "phone" : "mac"];
    if (!isOpen(other)) return;
    if (other.bufferedAmount > MAX_BEHIND) return other.terminate();
    other.send(data, { binary });
  });
  ws.on("close", (code) => {
    clearTimeout(expire);
    if (role === "mac" && room.mac === ws) {
      seen.delete(id);
      seen.set(id, { seen: Date.now(), asleep: code === ASLEEP ? Date.now() : null });
      if (seen.size > MAX_SEEN) seen.delete(seen.keys().next().value);
    }
    left(id, room, role, ws);
  });
  ws.on("error", () => ws.terminate());
}

// BUDGET=1: the session can't go on here, and both ends hear why
function overBudget(room) {
  for (const ws of [room.mac, room.phone]) if (isOpen(ws)) ws.close(OVER_BUDGET, "budget");
}

function isOpen(ws) { return !!ws && ws.readyState === WebSocket.OPEN; }

function left(id, room, role, ws) {
  if (room[role] !== ws) return;           // it was replaced: the new one is already in its place
  room[role] = undefined;
  const other = room[role === "mac" ? "phone" : "mac"];
  if (isOpen(other)) role === "mac" ? other.close(MAC_GONE, "mac left") : other.close(PHONE_LEFT, "phone left");
  if (!room.mac && !room.phone) rooms.delete(id);
}

// a peer that vanished without closing: nothing else would tell
setInterval(() => {
  for (const ws of wss.clients) {
    if (!ws.alive) { ws.terminate(); continue; }
    ws.alive = false;
    ws.ping();
  }
}, BEAT).unref();

server.listen(PORT, HOST, () => console.log(`blurt ${BUDGET ? "go-between (budget mode)" : "relay"} on ${HOST}:${PORT}`));
