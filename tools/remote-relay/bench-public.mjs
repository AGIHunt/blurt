// Load for the public relay (public.js): `rooms` sessions, each a computer with a picture lease sending `bps` of frames at `fps` plus
// 60 small messages a second, and a phone sending 31. Reports what arrived, frame latency and errors as one JSON line. Tickets are
// signed here, so the relay under test needs the same TICKET_SECRETS (a bench copy, never the live service) and PER_PREFIX/LEASES/
// UPGRADES/PER_IP raised to let one machine open them all.
//   node bench-public.mjs <ws(s)://host[:port]> <secret> <rooms> [bps=1000000] [fps=15] [warm=6] [measure=15]
// BIND and RELAY_IP as in measure-path.mjs: send it straight out of this machine's LAN interface past a local proxy.
import { randomBytes } from "node:crypto";
import { performance } from "node:perf_hooks";
import WebSocket from "ws";
import { ticket } from "./src/ticket.js";

const [url, secret, n, bps = "1000000", fps = "15", warm = "6", measure = "15"] = process.argv.slice(2);
const FRAME = Math.round(+bps / 8 / +fps);
const now = () => performance.timeOrigin + performance.now();
const tag = randomBytes(9).toString("base64url");
const exp = Math.floor(Date.now() / 1000) + 60;
const direct = process.env.BIND ? {
  localAddress: process.env.BIND,
  ...(process.env.RELAY_IP && { lookup: (h, o, cb) => (o.all ? cb(null, [{ address: process.env.RELAY_IP, family: 4 }]) : cb(null, process.env.RELAY_IP, 4)) }),
} : {};
const open = async (room, role) => new Promise(async (ok, no) => {
  const w = new WebSocket(`${url}/v1/${room}/${role}?t=${await ticket(secret, room, role, exp, tag)}`, { perMessageDeflate: false, ...direct });
  w.once("open", () => ok(w)); w.once("error", no); w.once("unexpected-response", (_, r) => no(new Error("HTTP " + r.statusCode)));
});
const lat = []; let bytes = 0, frames = 0, errors = 0, leases = 0, measuring = false;
const timers = [];
for (let i = 0; i < +n; i++) {
  const room = randomBytes(32).toString("base64url");
  try {
    const mac = await open(room, "mac");
    const phone = await open(room, "phone");
    mac.on("message", (d, binary) => { if (!binary && JSON.parse(d.toString()).lease?.ok) leases++; });
    mac.send('{"lease":true}');
    phone.on("message", (d) => {
      if (!measuring) return;
      bytes += d.length;
      if (d.length >= 1000) { frames++; lat.push(now() - d.readDoubleLE(0)); }
    });
    for (const w of [mac, phone]) w.on("close", () => { if (measuring) errors++; });
    const frame = Buffer.alloc(FRAME, 1), small = Buffer.alloc(40, 2);
    timers.push(setInterval(() => { frame.writeDoubleLE(now(), 0); mac.send(frame); }, 1000 / +fps));
    timers.push(setInterval(() => mac.send(small), 1000 / 60));
    timers.push(setInterval(() => phone.send(small), 1000 / 31));
    timers.push(setInterval(() => mac.send('{"lease":true}'), 30000));
  } catch (e) { errors++; }
}
await new Promise((r) => setTimeout(r, +warm * 1000));
measuring = true;
const t0 = Date.now();
await new Promise((r) => setTimeout(r, +measure * 1000));
measuring = false;
const secs = (Date.now() - t0) / 1000;
lat.sort((a, b) => a - b);
const q = (p) => +(lat[Math.floor(p * (lat.length - 1))] ?? 0).toFixed(1);
console.log(JSON.stringify({ rooms: +n, leases, mbps: +((bytes * 8) / secs / 1e6).toFixed(1), fps: +(frames / secs / +n).toFixed(1), p50: q(0.5), p99: q(0.99), max: q(1), errors }));
for (const t of timers) clearInterval(t);
process.exit(0);
