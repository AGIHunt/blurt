// The go-between's tickets per client IP (src/meet.js, its TICKETS rate limiter: 6 a minute, across rooms), against `wrangler dev`.
// Exits non-zero if not. The limiter counts per Cloudflare location, so run it against a local dev copy, never the live service:
//   npx wrangler dev --config wrangler.meet.toml --port 18961 --local --var TICKET_SECRET:<any 64 hex> & node test-meet-tickets.mjs ws://127.0.0.1:18961
import { randomBytes } from "node:crypto";
import WebSocket from "ws";

const base = (process.argv[2] ?? "").replace(/\/+$/, "");
if (!/^ws:\/\/(127\.0\.0\.1|localhost)/.test(base)) { console.error("usage: node test-meet-tickets.mjs ws://127.0.0.1:<wrangler dev port>"); process.exit(2); }
setTimeout(() => { console.error("FAILED: timed out"); process.exit(1); }, 60000).unref();
const room = () => randomBytes(32).toString("base64url");
const open = (u, ip) => new Promise((ok, no) => { const w = new WebSocket(u, { headers: { "CF-Connecting-IP": ip } }); w.on("open", () => ok(w)); w.on("error", no); });
const ask = (w, m) => new Promise((ok) => { w.once("message", (d) => ok(JSON.parse(d.toString()))); w.send(JSON.stringify(m)); });
const expect = (what, got, want) => {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  console.log(`${ok ? "ok  " : "FAIL"} ${what}: ${JSON.stringify(got)}`);
  if (!ok) { console.error(`     wanted ${JSON.stringify(want)}`); process.exit(1); }
};
async function tickets(ip, n, ask1 = { ticket: { room: room() } }) {
  const out = [];
  for (let i = 0; i < n; i++) {
    const pair = room();
    const m = await open(`${base}/v1/${pair}/mac`, ip), p = await open(`${base}/v1/${pair}/phone`, ip);
    const a = (await ask(m, i === 0 ? ask1 : { ticket: { room: room() } })).ticket;
    out.push(a.error ?? (a.mac && a.phone ? "ok" : "?"));
    m.close(); p.close();
  }
  return out;
}
const ip = `198.51.100.${1 + Math.floor(Math.random() * 250)}`;
expect("a bad ask doesn't count", await tickets(ip, 1, { ticket: { room: "short" } }), ["bad"]);
expect("from one IP, a new room each time: six a minute, then limit", await tickets(ip, 7), ["ok", "ok", "ok", "ok", "ok", "ok", "limit"]);
expect("another IP isn't held back", await tickets(`203.0.113.${1 + Math.floor(Math.random() * 250)}`, 1), ["ok"]);
const v6 = `2001:db8:${(1 + Math.floor(Math.random() * 65000)).toString(16)}:7`;
const six = [];
for (let i = 1; i <= 7; i++) six.push(...await tickets(`${v6}::${i.toString(16)}`, 1));
expect("one IPv6 /64, a new address each time, counts as one", six, ["ok", "ok", "ok", "ok", "ok", "ok", "limit"]);
console.log("PASSED");
process.exit(0);
