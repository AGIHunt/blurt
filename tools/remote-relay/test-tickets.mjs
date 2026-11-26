// From the go-between to the public relay, offline: server.js (BUDGET=1, as src/meet.js) mints tickets for a computer whose phone is in
// the room (a few a connection, a few a minute per IP across rooms), and public.js lets both ends into the session's own room with them.
// Exits non-zero on the first failure. A few seconds.
//   node test-tickets.mjs
import { spawn } from "node:child_process";
import { randomBytes } from "node:crypto";
import WebSocket from "ws";

const SECRET = randomBytes(32).toString("hex");
const P1 = 18900 + Math.floor(Math.random() * 50), P2 = P1 + 50;
const run = (file, env) => spawn(process.execPath, [new URL(file, import.meta.url).pathname], { env: { ...process.env, HOST: "127.0.0.1", ...env }, stdio: ["ignore", "pipe", "inherit"] });
const meet = run("./server.js", { PORT: String(P1), BUDGET: "1", TICKET_SECRET: SECRET, PUBLIC_RELAY: `ws://127.0.0.1:${P2}` });
const hk = run("./public.js", { PORT: String(P2), TICKET_SECRETS: SECRET });
const done = (c) => { meet.kill(); hk.kill(); process.exit(c); };
setTimeout(() => { console.error("FAILED: timed out"); done(1); }, 30000).unref();
const expect = (what, got, want) => {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  console.log(`${ok ? "ok  " : "FAIL"} ${what}: ${JSON.stringify(got)}`);
  if (!ok) { console.error(`     wanted ${JSON.stringify(want)}`); done(1); }
};
await Promise.all([meet, hk].map((p) => new Promise((ok) => p.stdout.once("data", ok))));
const room = () => randomBytes(32).toString("base64url");
const open = (u) => new Promise((ok, no) => { const w = new WebSocket(u); w.on("open", () => ok(w)); w.on("error", no); w.on("unexpected-response", (_, r) => ok(r.statusCode)); });
const text = (w) => new Promise((ok) => w.once("message", (d, binary) => ok(binary ? null : JSON.parse(d.toString()))));
const ask = async (w, m) => { const a = text(w); w.send(JSON.stringify(m)); return a; };

const pair = room(), hkRoom = room();
const mac = await open(`ws://127.0.0.1:${P1}/v1/${pair}/mac`);
expect("alone, no tickets", await ask(mac, { ticket: { room: hkRoom } }), { ticket: { error: "alone" } });
const phone = await open(`ws://127.0.0.1:${P1}/v1/${pair}/phone`);
let passed = 0;
phone.on("message", () => passed++);
expect("a phone asking", await ask(phone, { ticket: { room: hkRoom } }), { ticket: { error: "bad" } });
passed = 0;   // its own answer
expect("a bad room", await ask(mac, { ticket: { room: "short" } }), { ticket: { error: "bad" } });
const t = (await ask(mac, { ticket: { room: hkRoom } })).ticket;
expect("tickets for both, and where", [t.relay, t.room, /^\d{10}\.[\w-]{12}\.[\w-]{22}$/.test(t.mac), /^\d{10}\.[\w-]{12}\.[\w-]{22}$/.test(t.phone)], [`ws://127.0.0.1:${P2}`, hkRoom, true, true]);
expect("the fourth ask on one connection", await ask(mac, { ticket: { room: hkRoom } }), { ticket: { error: "limit" } });
expect("nothing of it reached the phone", passed, 0);
const hm = await open(`${t.relay}/v1/${t.room}/mac?t=${t.mac}`);
const hp = await open(`${t.relay}/v1/${t.room}/phone?t=${t.phone}`);
expect("both ends are in the public relay's room", [hm instanceof WebSocket, hp instanceof WebSocket], [true, true]);
const got = new Promise((ok) => hm.once("message", (d) => ok(d.toString())));
hp.send(Buffer.from("sealed"));
expect("bytes pass", await got, "sealed");
expect("the phone's ticket can't open the computer's end", await open(`${t.relay}/v1/${t.room}/mac?t=${t.phone}`), 403);
// per client IP across rooms: a modified client can make go-between rooms at will; 6 tickets a minute from one address, then "limit"
const answers = [];
for (let i = 0; i < 6; i++) {
  const pr = room();
  const m = await open(`ws://127.0.0.1:${P1}/v1/${pr}/mac`);
  const p = await open(`ws://127.0.0.1:${P1}/v1/${pr}/phone`);
  answers.push((await ask(m, { ticket: { room: room() } })).ticket.error ?? "ok");
  m.close(); p.close();
}
expect("from one IP, in new rooms each time, a minute's tickets (one was the first room's; bad asks don't count)", answers, ["ok", "ok", "ok", "ok", "ok", "limit"]);
console.log("PASSED");
done(0);
