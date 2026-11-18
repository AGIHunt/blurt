// Two clients through a relay: bytes pass both ways, and the close codes are what the apps expect. Exits non-zero if not.
//   node test.mjs wss://relay.example.com     (Node 22 or later)
const base = (process.argv[2] ?? "").replace(/\/+$/, "");
if (!/^wss?:\/\//.test(base)) { console.error("usage: node test.mjs wss://relay.example.com"); process.exit(2); }
setTimeout(() => { console.error("FAILED: timed out"); process.exit(1); }, 60000).unref();

const newRoom = () => Buffer.from(crypto.getRandomValues(new Uint8Array(32))).toString("base64url");
let room = newRoom();
const url = (r) => `${base}/v1/${room}/${r}`;
const open = (u) => new Promise((ok, no) => { const w = new WebSocket(u); w.binaryType = "arraybuffer"; w.onopen = () => ok(w); w.onerror = () => no(new Error("can't connect to " + u)); });
const once = (w, ev) => new Promise((ok) => w.addEventListener(ev, ok, { once: true }));
const expect = (what, got, want) => {
  console.log(`${what}: ${got}`);
  if (got !== want) { console.error(`FAILED: wanted ${want}`); process.exit(1); }
};

try {
  const early = await open(url("phone"));
  expect("a phone with no Mac is closed with", (await once(early, "close")).code, 4001);

  const mac = await open(url("mac"));
  const phone = await open(url("phone"));
  mac.onmessage = (e) => mac.send(e.data);
  const rtts = [];
  for (let i = 0; i < 20; i++) {
    const t = performance.now();
    phone.send(new Uint8Array(1200));
    const m = await once(phone, "message");
    if (m.data.byteLength !== 1200) throw new Error("bytes changed on the way");
    rtts.push(performance.now() - t);
  }
  rtts.sort((a, b) => a - b);
  console.log("round trip ms: median", rtts[10].toFixed(0), "worst", rtts[19].toFixed(0));

  const second = await open(url("phone"));
  expect("the replaced phone is closed with", (await once(phone, "close")).code, 4002);
  const left = once(mac, "close");
  second.close();
  expect("the Mac hears the phone left with", (await left).code, 4000);

  const bad = await fetch(`${base.replace(/^ws/, "http")}/v1/short/mac`);
  expect("a bad room gets", bad.status, 404);
  console.log("PASSED");
  process.exit(0);
} catch (e) {
  console.error("FAILED:", e.message);
  process.exit(1);
}
