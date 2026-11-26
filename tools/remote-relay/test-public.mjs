// The public relay's rules (public.js, docs/design/remote-go-between.md §"The public relay"), against a copy started here with short
// timers: tickets, ten leases and the eleventh refused, leases freed, budgets by pausing (nothing dropped), the waiting room, per-IP caps,
// a prefix's day across tickets, an IPv6 /64 as one address.
// Exits non-zero on the first failure. About 20 s.
//   node test-public.mjs
import { spawn } from "node:child_process";
import { randomBytes } from "node:crypto";
import WebSocket from "ws";
import { ticket } from "./src/ticket.js";

const PORT = 18790 + Math.floor(Math.random() * 100);
const SECRET = randomBytes(32).toString("hex");
const env = {
  ...process.env, PORT: String(PORT), HOST: "127.0.0.1", TICKET_SECRETS: SECRET, TRUST_PROXY: "1", LEASES: "10",
  RENEW_MS: "1500", LEASE_MAX_MS: "4000", AGAIN_MS: "3000", WAIT_MS: "1500", DAY_BYTES: "3000000", PREFIX_DAY_BYTES: "4000000", UPGRADES: "10", COUNT_MS: "600000",
  BASE_RATE: "100000", BASE_BURST: "20000", LEASED_RATE: "1000000", LEASED_BURST: "200000",
};
const relay = spawn(process.execPath, [new URL("./public.js", import.meta.url).pathname], { env, stdio: ["ignore", "pipe", "inherit"] });
let failed = false;
const done = (code) => { relay.kill(); process.exit(code); };
setTimeout(() => { console.error("FAILED: timed out"); done(1); }, 90000).unref();
const expect = (what, got, want) => {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  console.log(`${ok ? "ok  " : "FAIL"} ${what}: ${JSON.stringify(got)}`);
  if (!ok) { failed = true; console.error(`     wanted ${JSON.stringify(want)}`); done(1); }
};
await new Promise((ok) => relay.stdout.once("data", ok));

const base = `ws://127.0.0.1:${PORT}`;
const newRoom = () => randomBytes(32).toString("base64url");
const tag = randomBytes(9).toString("base64url");
const exp = () => Math.floor(Date.now() / 1000) + 60;
const wait = (ms) => new Promise((ok) => setTimeout(ok, ms));
let ipN = 0;
const nextIP = () => `10.${Math.floor(++ipN / 250)}.${ipN % 250}.7`;
// opens `role` in `room` from `ip`; resolves with the socket, or the HTTP status / close code that refused it
function open(room, role, { ip = nextIP(), t, secret = SECRET, tg = tag, e = exp() } = {}) {
  return (async () => {
    const tk = t ?? await ticket(secret, room, role, e, tg);
    return new Promise((ok) => {
      const w = new WebSocket(`${base}/v1/${room}/${role}?t=${tk}`, { headers: { "X-Real-IP": ip } });
      w.got = [];
      w.leases = [];
      w.on("message", (d, binary) => { if (binary) w.got.push(d); else { const m = JSON.parse(d.toString()); if (m.lease) w.leases.push(m.lease); } });
      w.closed = new Promise((c) => w.on("close", (code) => c(code)));
      w.on("open", () => ok(w));
      w.on("unexpected-response", (_, res) => ok(res.statusCode));
      w.on("error", () => ok("error"));
    });
  })();
}
async function session(ip) {
  const room = newRoom();
  const mac = await open(room, "mac", { ip });
  const phone = await open(room, "phone");
  return { room, mac, phone };
}
const lease = async (mac, on = true) => { const n = mac.leases.length; mac.send(JSON.stringify({ lease: on })); if (!on) return null; for (let i = 0; i < 100 && mac.leases.length === n; i++) await wait(10); return mac.leases[mac.leases.length - 1]; };

try {
  expect("GET / answers", await fetch(`http://127.0.0.1:${PORT}/`).then(async (r) => `${r.status} ${await r.text()}`), "200 blurt relay");
  expect("no peek", (await fetch(`http://127.0.0.1:${PORT}/v1/${newRoom()}/peek`)).status, 404);

  // tickets
  {
    const room = newRoom();
    expect("no ticket", await new Promise((ok) => { const w = new WebSocket(`${base}/v1/${room}/mac`, { headers: { "X-Real-IP": nextIP() } }); w.on("unexpected-response", (_, r) => ok(r.statusCode)); }), 404);
    expect("a ticket signed with another secret", await open(room, "mac", { secret: randomBytes(32).toString("hex") }), 403);
    expect("an expired ticket", await open(room, "mac", { e: Math.floor(Date.now() / 1000) - 1 }), 403);
    expect("a ticket for another room", await open(room, "mac", { t: await ticket(SECRET, newRoom(), "mac", exp(), tag) }), 403);
    expect("the phone's ticket used as the computer", await open(room, "mac", { t: await ticket(SECRET, room, "phone", exp(), tag) }), 403);
    const t = await ticket(SECRET, room, "mac", exp(), tag);
    const mac = await open(room, "mac", { t });
    expect("a good ticket opens", mac instanceof WebSocket, true);
    expect("the same ticket again", await open(room, "mac", { t }), 403);
    mac.close();
  }

  // a phone with no computer; a computer nobody comes to
  {
    const p = await open(newRoom(), "phone");
    expect("a phone with no computer is closed with", await p.closed, 4001);
    const m = await open(newRoom(), "mac");
    const t0 = Date.now();
    expect("a computer alone is closed with", await m.closed, 4011);
    expect("after about WAIT_MS", Math.abs(Date.now() - t0 - 1500) < 600, true);
  }

  // bytes pass both ways, in order
  {
    const { mac, phone } = await session();
    for (let i = 0; i < 20; i++) phone.send(Buffer.from([i]));
    mac.send(Buffer.from("hello"));
    await wait(200);
    expect("phone → computer, in order", mac.got.map((b) => b[0]), [...Array(20).keys()]);
    expect("computer → phone", phone.got.map(String), ["hello"]);
    phone.close();
    expect("the computer hears the phone left", await mac.closed, 4000);
  }

  // leases: ten, the eleventh refused, freed by off / disconnect / time, one per IP prefix
  {
    const s = [];
    for (let i = 0; i < 11; i++) s.push(await session(`10.200.${i}.1`));
    for (let i = 0; i < 10; i++) expect(`lease ${i + 1}`, (await lease(s[i].mac)).ok, true);
    expect("the 11th is refused", await lease(s[10].mac), { ok: false, why: "full" });
    const again = await lease(s[0].mac);
    expect("a holder asking again renews", again.ok, true);
    await lease(s[0].mac, false);
    await wait(50);
    expect("after one is given back, the 11th gets it", (await lease(s[10].mac)).ok, true);
    expect("then the one that gave it back is refused", await lease(s[0].mac), { ok: false, why: "full" });
    s[1].phone.close();
    await s[1].mac.closed;
    expect("after a phone leaves, its lease is free", (await lease(s[0].mac)).ok, true);
    // one per prefix: a second session from 10.200.0.x
    const same = await session("10.200.0.99");
    s[2].mac.close();
    await s[2].phone.closed;
    expect("a second lease for the same /24", await lease(same.mac), { ok: false, why: "prefix" });
    expect("one from another /24", (await lease((await session("10.201.0.1")).mac)).ok, true);
    // unrenewed: gone after RENEW_MS, and the computer hears so
    const quiet = s[3].mac;
    const n = quiet.leases.length;
    // keep the others renewed so only this one lapses
    const keep = setInterval(() => { for (const x of [s[0], ...s.slice(4)]) if (x.mac.readyState === 1) x.mac.send('{"lease":true}'); }, 400);
    await wait(2500);
    expect("an unrenewed lease is taken back", quiet.leases.slice(n).at(-1), { ok: false, why: "expired" });
    // past LEASE_MAX_MS even a renewed one goes
    await wait(2000);
    clearInterval(keep);
    expect("past the longest lease, it ends (then may be asked for again)", s[4].mac.leases.some((l) => l.why === "expired"), true);
    for (const x of [...s, same]) { try { x.mac.close(); x.phone.close(); } catch {} }
    await wait(300);
  }

  // budgets: paused, never dropped
  {
    const { mac, phone } = await session("10.250.0.1");
    const size = 4000, count = 60;   // 240 KB at 100 kB/s after a 20 kB burst: about 2.2 s
    const t0 = Date.now();
    for (let i = 0; i < count; i++) { const b = Buffer.alloc(size, i); mac.send(b); }
    while (phone.got.length < count && Date.now() - t0 < 10000) await wait(20);
    const ms = Date.now() - t0;
    expect("every message arrives, in order", phone.got.map((b) => b[0]), [...Array(count).keys()]);
    expect(`without a lease it is paced (${ms} ms for 240 KB)`, ms > 1500 && ms < 4000, true);
    expect("with a lease", (await lease(mac)).ok, true);
    phone.got = [];
    const t1 = Date.now();
    for (let i = 0; i < count; i++) mac.send(Buffer.alloc(size, i));
    while (phone.got.length < count && Date.now() - t1 < 10000) await wait(10);
    expect(`it goes faster (${Date.now() - t1} ms)`, Date.now() - t1 < 800, true);
    // the day's budget (3 MB here): past it, both ends hear 4003
    const big = Buffer.alloc(200000);
    for (let i = 0; i < 16; i++) mac.send(big);
    expect("past the day's bytes the computer hears", await mac.closed, 4003);
    expect("and the phone", await phone.closed, 4003);
  }

  // a prefix's day (4 MB here) across pairs: tickets with two tags, so each pair stays under its own 3 MB
  {
    const pairA = randomBytes(9).toString("base64url"), pairB = randomBytes(9).toString("base64url");
    const sess = async (ip, tg) => { const room = newRoom(); const mac = await open(room, "mac", { ip, tg }); const phone = await open(room, "phone", { tg }); return { mac, phone }; };
    const a = await sess("10.240.0.1", pairA);
    expect("lease A", (await lease(a.mac)).ok, true);
    const big = Buffer.alloc(250000);
    for (let i = 0; i < 10; i++) a.mac.send(big);   // 2.5 MB: under pair A's 3 MB
    while (a.phone.got.length < 10) await wait(20);
    a.mac.close(); await a.phone.closed;
    const b = await sess("10.240.0.2", pairB);
    expect("lease B", (await lease(b.mac)).ok, true);
    for (let i = 0; i < 8; i++) if (b.mac.readyState === 1) b.mac.send(big);   // 2 MB more from the same /24: past its 4 MB
    expect("past the prefix's day, a pair still under its own hears", await b.mac.closed, 4003);
    expect("a new connection from that /24 today", await open(newRoom(), "mac", { ip: "10.240.0.3" }), 429);
    const other = await open(newRoom(), "mac", { ip: "10.241.0.3" });
    expect("one from another /24", other instanceof WebSocket, true);
    other.close();
  }

  // IPv6: one /64 is one address for the upgrade limit; another /64 isn't
  {
    const got = [];
    for (let i = 0; i < 11; i++) got.push(await open(newRoom(), "phone", { ip: `2001:db8:1:2::${(i + 1).toString(16)}` }));
    expect("the 11th upgrade from one /64 in 10 s, each from its own address", got[10], 429);
    const p = await open(newRoom(), "phone", { ip: "2001:db8:1:3::1" });
    expect("another /64 in the same /48 isn't counted with it", p !== 429, true);
  }

  // per IP: ten upgrades in 10 s
  {
    const ip = "10.99.99.99";
    const got = [];
    for (let i = 0; i < 11; i++) got.push(await open(newRoom(), "phone", { ip }));
    expect("the 11th upgrade from one IP in 10 s", got[10], 429);
  }
  console.log("PASSED");
  done(0);
} catch (e) {
  console.error("FAILED:", e);
  done(1);
}
