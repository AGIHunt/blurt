#!/usr/bin/env node
// Blurt's public relay (wss://relay.blurt.work, Hong Kong): docs/design/remote-go-between.md §"The public relay". When a phone and its
// computer meet on the go-between (src/meet.js) and the direct path won't open, the computer asks the go-between for two tickets and both
// ends come here, to a room made for that one session. Bytes pass as on any relay (server.js): sealed end to end, nothing stored or read.
// Unlike an own relay it is shared and public, so it enforces:
//
// - a ticket from the go-between to join: HMAC(room, role, expiry ≤ 60 s, a per-pair-per-day tag), each used once;
// - picture leases, asked for by the computer in a text message: LEASES at once (10), one per IP prefix (/24, /48), renewed every 30 s
//   while the picture flows, gone after RENEW_MS unrenewed, on `{"lease":false}`, on either end leaving, and after LEASE_MAX_MS (2 h);
// - budgets per room and direction, enforced by pausing reads (never by dropping: the frames are sealed in sequence): 256 kbps without a
//   lease, 1.5 Mbps with one; 200 messages a second; DAY_BYTES (1 GB) per pair per UTC day, then 4003;
// - per IP: 16 connections, 10 upgrades in 10 s; a computer alone in its room for 60 s is closed (4011); no `peek`.
//
// It logs counters once a minute and nothing about who: no addresses, rooms or devices.
//
//   TICKET_SECRETS=<secret>[,<older>] HOST=127.0.0.1 PORT=8790 TRUST_PROXY=1 node public.js
"use strict";
const http = require("http");
const crypto = require("crypto");
const { WebSocketServer, WebSocket } = require("ws");

const env = process.env;
const num = (k, d) => (env[k] === undefined || env[k] === "" ? d : Number(env[k]));
const HOST = env.HOST || "127.0.0.1";
const PORT = num("PORT", 8790);
// the newest first; the others still open tickets while a new secret rolls out to the go-between
const SECRETS = (env.TICKET_SECRETS || "").split(",").map((s) => s.trim()).filter(Boolean);
if (!SECRETS.length || SECRETS.some((s) => s.length < 32)) { console.error("TICKET_SECRETS: one or more secrets, 32 characters or more"); process.exit(2); }
const TRUST_PROXY = env.TRUST_PROXY === "1";   // behind Caddy, which sends X-Real-IP

const KiB = 1024;
const LEASES = num("LEASES", 10);
const RENEW_MS = num("RENEW_MS", 75000);               // the computer renews every 30 s while the picture flows
const LEASE_MAX_MS = num("LEASE_MAX_MS", 2 * 3600e3);
const AGAIN_MS = num("AGAIN_MS", 60000);               // after its 2 h, a room asks again behind anyone refused this long ago
const BASE_RATE = num("BASE_RATE", 256000 / 8);        // bytes a second, each way, without a lease
const BASE_BURST = num("BASE_BURST", 64 * KiB);
const LEASED_RATE = num("LEASED_RATE", 1500000 / 8);
const LEASED_BURST = num("LEASED_BURST", 256 * KiB);  // a keyframe is 77–170 KB in one message
const MSG_RATE = num("MSG_RATE", 200), MSG_BURST = num("MSG_BURST", 400);
const DAY_BYTES = num("DAY_BYTES", 1e9);
const WAIT_MS = num("WAIT_MS", 60000);
const SESSION_MS = num("SESSION_MS", 12 * 3600e3);
const PER_IP = num("PER_IP", 16);
const UPGRADES = num("UPGRADES", 10), UPGRADE_WINDOW_MS = 10000;
const MAX_CONNECTIONS = num("MAX_CONNECTIONS", 2000);
const MAX_MESSAGE = 512 * KiB;
// a receiver this far behind pauses its sender; this far, and it is cut (one big message can't make it: it's under MAX_MESSAGE)
const BEHIND_PAUSE = 256 * KiB, BEHIND_CUT = 2 * 1024 * KiB;
const BEAT = 30000;

// close codes the apps read (server.js has the first four)
const PHONE_LEFT = 4000, MAC_GONE = 4001, REPLACED = 4002, OVER_BUDGET = 4003, NOBODY_CAME = 4011;

const PATH = /^\/v1\/([A-Za-z0-9_-]{43})\/(mac|phone)\?t=([0-9]{10}\.[A-Za-z0-9_-]{12}\.[A-Za-z0-9_-]{22})$/;
const same = (a, b) => a.length === b.length && crypto.timingSafeEqual(Buffer.from(a), Buffer.from(b));
const sign = (secret, room, role, exp, tag) =>
  crypto.createHmac("sha256", secret).update(`blurt-ticket-1|${room}|${role}|${exp}|${tag}`).digest().subarray(0, 16).toString("base64url");
const used = new Map();   // ticket signature → expiry (s): a ticket opens one connection
// { room, role, tag } for a path with a good, unused ticket; else why not
function admit(url, now) {
  const m = PATH.exec(url);
  if (!m) return { why: "path" };
  const [, room, role, t] = m;
  const [exp, tag, sig] = t.split(".");
  const s = Math.floor(now / 1000);
  if (Number(exp) < s || Number(exp) > s + 120) return { why: "ticket" };
  if (!SECRETS.some((k) => same(sign(k, room, role, exp, tag), sig))) return { why: "ticket" };
  if (used.has(sig)) return { why: "ticket" };
  used.set(sig, Number(exp));
  return { room, role, tag };
}

// an address's prefix for the one-lease rule: IPv4 /24, IPv6 /48
function prefix(ip) {
  const v4 = /(\d+)\.(\d+)\.(\d+)\.\d+$/.exec(ip);
  if (v4 && (!ip.includes(":") || ip.toLowerCase().startsWith("::ffff:"))) return `${v4[1]}.${v4[2]}.${v4[3]}`;
  const head = ip.split("::")[0].split(":");
  const full = ip.includes("::") ? head : ip.split(":");
  return full.slice(0, 3).map((h) => (h || "0").toLowerCase().replace(/^0+(?=.)/, "")).join(":") + "::/48";
}

const counts = { upgrades: 0, refused: {}, granted: 0, leaseRefused: {}, bytes: 0, paused: 0, overBudget: 0 };
const refuse = (why) => { counts.refused[why] = (counts.refused[why] || 0) + 1; };

const rooms = new Map();   // room → { mac, phone, tag, prefix, lease, opened }
const leased = new Map();  // room → its lease { granted, renewed, prefix }
let lastRefusedAt = 0;     // the last lease refused for want of room
const perIP = new Map(), upgradesBy = new Map();
const dayBytes = new Map();
let day = Math.floor(Date.now() / 86400e3);
let connections = 0;

const server = http.createServer((req, res) => {
  if (req.url === "/" && (req.method === "GET" || req.method === "HEAD")) {
    res.writeHead(200, { "Content-Type": "text/plain; charset=utf-8", "Cache-Control": "no-store" });
    return res.end("blurt relay");
  }
  res.writeHead(404, { "Content-Type": "text/plain" });
  res.end("Not found\n");
});
server.headersTimeout = 10000;
server.requestTimeout = 10000;
const wss = new WebSocketServer({ noServer: true, maxPayload: MAX_MESSAGE, perMessageDeflate: false });

function deny(socket, status, why) {
  refuse(why);
  try { socket.end(`HTTP/1.1 ${status}\r\nConnection: close\r\nContent-Length: 0\r\n\r\n`); } catch {}
  socket.destroy();
}

server.on("upgrade", (req, socket, head) => {
  const now = Date.now();
  counts.upgrades++;
  const from = (TRUST_PROXY && req.headers["x-real-ip"]) || req.socket.remoteAddress || "";
  const recent = (upgradesBy.get(from) || []).filter((t) => t > now - UPGRADE_WINDOW_MS);
  recent.push(now);
  upgradesBy.set(from, recent);
  if (recent.length > UPGRADES) return deny(socket, "429 Too Many Requests", "rate");
  if ((perIP.get(from) || 0) >= PER_IP || connections >= MAX_CONNECTIONS) return deny(socket, "429 Too Many Requests", "connections");
  const a = admit(req.url, now);
  if (!a.room) return deny(socket, a.why === "path" ? "404 Not Found" : "403 Forbidden", a.why);
  const room = rooms.get(a.room);
  // a phone with no computer there hears so at once (as on any relay)
  if (a.role === "phone" && !isOpen(room && room.mac)) {
    return wss.handleUpgrade(req, socket, head, (ws) => { ws.on("error", () => ws.terminate()); ws.close(MAC_GONE, "no mac"); });
  }
  perIP.set(from, (perIP.get(from) || 0) + 1);
  connections++;
  socket.once("close", () => {
    connections--;
    const n = perIP.get(from) - 1;
    if (n > 0) perIP.set(from, n); else perIP.delete(from);
  });
  socket.setNoDelay(true);
  wss.handleUpgrade(req, socket, head, (ws) => join(ws, a, from));
});

function join(ws, a, from) {
  let room = rooms.get(a.room);
  if (!room) {
    room = { id: a.room, tag: a.tag, prefix: prefix(from), opened: Date.now() };
    rooms.set(a.room, room);
  }
  const old = room[a.role];
  room[a.role] = ws;
  if (old) old.close(REPLACED, "replaced");
  if (a.role === "mac") room.prefix = prefix(from);
  ws.role = a.role;
  ws.alive = true;
  ws.bucket = { bytes: BASE_BURST, msgs: MSG_BURST, at: Date.now() };
  ws.on("pong", () => { ws.alive = true; });
  clearTimeout(room.waiting);
  if (!isOpen(room.phone)) room.waiting = setTimeout(() => { if (room.mac === ws && !isOpen(room.phone)) ws.close(NOBODY_CAME, "nobody came"); }, WAIT_MS);
  if (a.role === "phone" && !room.ends) room.ends = setTimeout(() => overBudget(room), SESSION_MS - (Date.now() - room.opened));

  ws.on("message", (data, binary) => {
    if (room[a.role] !== ws || ws.readyState !== WebSocket.OPEN) return;
    if (!binary) return a.role === "mac" ? said(room, ws, data) : undefined;   // only the computer speaks to the relay
    const other = room[a.role === "mac" ? "phone" : "mac"];
    if (!isOpen(other)) return;
    const today = Math.floor(Date.now() / 86400e3);
    if (today !== day) { day = today; dayBytes.clear(); }
    const n = (dayBytes.get(room.tag) || 0) + data.length;
    dayBytes.set(room.tag, n);
    if (n > DAY_BYTES) return overBudget(room);
    if (other.bufferedAmount > BEHIND_CUT) return other.terminate();
    counts.bytes += data.length;
    other.send(data, { binary: true });
    spend(room, ws, other, data.length);
  });
  ws.on("close", () => left(room, a.role, ws));
  ws.on("error", () => ws.terminate());
}

// the token buckets of one direction: spent on every message, and the sender's reads pause while either is in debt or the receiver is
// behind. A message is never dropped; a big one only puts the sender in debt for longer.
function spend(room, ws, other, size) {
  const b = ws.bucket, now = Date.now();
  const [rate, burst] = leased.has(room.id) ? [LEASED_RATE, LEASED_BURST] : [BASE_RATE, BASE_BURST];
  const dt = (now - b.at) / 1000;
  b.at = now;
  b.bytes = Math.min(burst, b.bytes + dt * rate) - size;
  b.msgs = Math.min(MSG_BURST, b.msgs + dt * MSG_RATE) - 1;
  if (b.bytes >= 0 && b.msgs >= 0 && other.bufferedAmount <= BEHIND_PAUSE) return;
  if (ws.isPaused) return;
  counts.paused++;
  ws.pause();
  const check = () => {
    if (ws.readyState !== WebSocket.OPEN) return;
    const t = Date.now();
    const [r, br] = leased.has(room.id) ? [LEASED_RATE, LEASED_BURST] : [BASE_RATE, BASE_BURST];
    const d = (t - b.at) / 1000;
    b.at = t;
    b.bytes = Math.min(br, b.bytes + d * r);
    b.msgs = Math.min(MSG_BURST, b.msgs + d * MSG_RATE);
    const o = room[ws.role === "mac" ? "phone" : "mac"];
    const behind = isOpen(o) && o.bufferedAmount > BEHIND_PAUSE;
    if (b.bytes >= 0 && b.msgs >= 0 && !behind) return ws.resume();
    const wait = Math.max(behind ? 20 : 0, b.bytes < 0 ? (-b.bytes / r) * 1000 : 0, b.msgs < 0 ? (-b.msgs / MSG_RATE) * 1000 : 0);
    setTimeout(check, Math.min(1000, Math.max(5, wait)));
  };
  setTimeout(check, 5);
}

// what the computer says to the relay itself: `{"lease":true}` asks for a picture lease or renews it, `{"lease":false}` gives it back
function said(room, ws, data) {
  if (data.length > 256) return;
  let m;
  try { m = JSON.parse(data.toString()); } catch { return; }
  if (m && m.lease === true) return ask(room, ws);
  if (m && m.lease === false) return free(room, null);
}

function answer(room, o) {
  if (isOpen(room.mac)) room.mac.send(JSON.stringify({ lease: o }));
}

function ask(room, ws) {
  const now = Date.now();
  const l = leased.get(room.id);
  if (l) {
    l.renewed = now;
    return answer(room, { ok: true, ttl: Math.round(RENEW_MS / 1000) });
  }
  let why = null;
  if (!isOpen(room.phone)) why = "alone";
  else if (leased.size >= LEASES) why = "full";
  else if ([...leased.values()].some((x) => x.prefix === room.prefix)) why = "prefix";
  // its 2 h are up: anyone refused in the last minute goes first
  else if (room.spentAt && now - room.spentAt < AGAIN_MS && now - lastRefusedAt < AGAIN_MS) why = "full";
  if (why) {
    if (why === "full") lastRefusedAt = now;
    counts.leaseRefused[why] = (counts.leaseRefused[why] || 0) + 1;
    return answer(room, { ok: false, why });
  }
  leased.set(room.id, { granted: now, renewed: now, prefix: room.prefix });
  counts.granted++;
  answer(room, { ok: true, ttl: Math.round(RENEW_MS / 1000) });
}

// the lease goes; `why` is said to the computer when the relay took it back by itself
function free(room, why) {
  if (!leased.delete(room.id)) return;
  if (why) answer(room, { ok: false, why });
}

setInterval(() => {
  const now = Date.now();
  for (const [id, l] of leased) {
    const room = rooms.get(id);
    if (!room) { leased.delete(id); continue; }
    if (now - l.granted >= LEASE_MAX_MS) { room.spentAt = now; free(room, "expired"); } else if (now - l.renewed >= RENEW_MS) free(room, "expired");
  }
  const s = Math.floor(now / 1000);
  for (const [sig, exp] of used) if (exp < s) used.delete(sig);
  for (const [ip, ts] of upgradesBy) if (!ts.some((t) => t > now - UPGRADE_WINDOW_MS)) upgradesBy.delete(ip);
}, Math.min(5000, Math.max(200, RENEW_MS / 5))).unref();

function overBudget(room) {
  counts.overBudget++;
  for (const ws of [room.mac, room.phone]) if (isOpen(ws)) ws.close(OVER_BUDGET, "budget");
}

function isOpen(ws) { return !!ws && ws.readyState === WebSocket.OPEN; }

function left(room, role, ws) {
  if (room[role] !== ws) return;   // replaced: the new one is in its place
  room[role] = undefined;
  free(room, null);
  const other = room[role === "mac" ? "phone" : "mac"];
  if (isOpen(other)) role === "mac" ? other.close(MAC_GONE, "mac left") : other.close(PHONE_LEFT, "phone left");
  if (!room.mac && !room.phone) {
    clearTimeout(room.waiting);
    clearTimeout(room.ends);
    rooms.delete(room.id);
  }
}

setInterval(() => {
  for (const ws of wss.clients) {
    if (!ws.alive) { ws.terminate(); continue; }
    ws.alive = false;
    ws.ping();
  }
}, BEAT).unref();

// counters once a minute: how much, never who
let cpu = process.cpuUsage(), cpuAt = Date.now();
setInterval(() => {
  const c = process.cpuUsage(cpu), now = Date.now();
  const line = {
    t: new Date(now).toISOString().slice(0, 16), connections, rooms: rooms.size, leases: leased.size, ...counts,
    cpu: Math.round(((c.user + c.system) / 1000 / (now - cpuAt)) * 1000) / 10, rssMB: Math.round(process.memoryUsage().rss / 1048576),
  };
  cpu = process.cpuUsage();
  cpuAt = now;
  console.log(JSON.stringify(line));
  Object.assign(counts, { upgrades: 0, refused: {}, granted: 0, leaseRefused: {}, bytes: 0, paused: 0, overBudget: 0 });
}, num("COUNT_MS", 60000)).unref();

server.listen(PORT, HOST, () => console.log(`blurt public relay on ${HOST}:${PORT}, ${LEASES} leases`));

