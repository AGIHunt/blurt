// What a session through Blurt's public relay gets from this network: both ends run here, so every byte crosses to the relay and back,
// as a computer → relay → phone session does. Tickets come from the go-between the way a host gets them (one ask, no load), the computer
// end holds a picture lease, then: round trips every 200 ms, `seconds` of a 1 Mbps picture-like stream (15 frames a second) one way,
// and stalls (no frame for over 1 s). One JSON line. Uses about 2 × 125 kB × seconds of data.
//   node measure-path.mjs [seconds=120] [go-between=wss://meet.blurt.work]
import { randomBytes } from "node:crypto";
import { performance } from "node:perf_hooks";
import WebSocket from "ws";

const SECONDS = Number(process.argv[2] || 120);
const MEET = process.argv[3] || "wss://meet.blurt.work";
const now = () => performance.timeOrigin + performance.now();
const open = (u) => new Promise((ok, no) => {
  const t0 = now();
  const w = new WebSocket(u, { perMessageDeflate: false });
  w.once("open", () => { w.openMs = now() - t0; ok(w); });
  w.once("error", no);
  w.once("unexpected-response", (_, r) => no(new Error("HTTP " + r.statusCode)));
});
const wait = (ms) => new Promise((r) => setTimeout(r, ms));
const q = (a, p) => { const s = [...a].sort((x, y) => x - y); return +(s[Math.floor(p * (s.length - 1))] ?? NaN).toFixed(1); };

const pair = randomBytes(32).toString("base64url"), room = randomBytes(32).toString("base64url");
const gm = await open(`${MEET}/v1/${pair}/mac`), gp = await open(`${MEET}/v1/${pair}/phone`);
const t = await new Promise((ok) => { gm.once("message", (d) => ok(JSON.parse(d.toString()).ticket)); gm.send(JSON.stringify({ ticket: { room } })); });
gm.close(); gp.close();
if (!t || t.error) { console.log(JSON.stringify({ error: "no ticket", t })); process.exit(1); }
const mac = await open(`${t.relay}/v1/${t.room}/mac?t=${t.mac}`);
const phone = await open(`${t.relay}/v1/${t.room}/phone?t=${t.phone}`);
const lease = await new Promise((ok) => { mac.on("message", (d, b) => { if (!b) ok(JSON.parse(d.toString()).lease); }); mac.send('{"lease":true}'); });

// round trips: the phone end echoes 16-byte probes
const rtts = [];
phone.on("message", (d) => { if (d.length === 16) phone.send(d); });
mac.on("message", (d, b) => { if (b && d.length === 16) rtts.push(now() - d.readDoubleLE(0)); });
const prober = setInterval(() => { const b = Buffer.alloc(16); b.writeDoubleLE(now(), 0); mac.send(b); }, 200);
await wait(10000);
const idle = [...rtts];

// the picture: 1 Mbps as 15 frames a second, computer → phone
const FRAME = Math.round(1e6 / 8 / 15);
let got = 0, frames = 0, last = now(), stalls = 0, longest = 0;
const ages = [];
phone.on("message", (d) => {
  if (d.length !== FRAME) return;
  const t1 = now();
  if (t1 - last > 1000) stalls++;
  longest = Math.max(longest, t1 - last);
  last = t1; got += d.length; frames++; ages.push(t1 - d.readDoubleLE(0));
});
rtts.length = 0;
const sender = setInterval(() => { const f = Buffer.alloc(FRAME, 7); f.writeDoubleLE(now(), 0); mac.send(f); }, 1000 / 15);
const renew = setInterval(() => mac.send('{"lease":true}'), 30000);
const t0 = now();
last = t0;
await wait(SECONDS * 1000);
clearInterval(sender); clearInterval(renew);
const secs = (now() - t0) / 1000;
await wait(1500);
clearInterval(prober);
console.log(JSON.stringify({
  at: new Date().toISOString(), lease: lease?.ok === true, open_ms: [Math.round(mac.openMs), Math.round(phone.openMs)],
  idle_rtt_ms: { p50: q(idle, 0.5), p95: q(idle, 0.95), n: idle.length },
  loaded_rtt_ms: { p50: q(rtts, 0.5), p95: q(rtts, 0.95), n: rtts.length },
  stream: { seconds: Math.round(secs), mbps: +((got * 8) / secs / 1e6).toFixed(2), fps: +(frames / secs).toFixed(1), frame_age_ms: { p50: q(ages, 0.5), p95: q(ages, 0.95), max: q(ages, 1) }, stalls_over_1s: stalls, longest_gap_ms: Math.round(longest) },
}));
mac.close(); phone.close();
process.exit(0);
