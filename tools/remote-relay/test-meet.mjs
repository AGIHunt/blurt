// The go-between's budget (src/meet.js, or server.js with BUDGET=1): a handshake passes; too much closes both ends with 4003. Exits
// non-zero if not. Takes about 30 s, most of it sending 100 KiB slowly enough to stay under the 5 s window.
//   node test-meet.mjs wss://meet.blurt.work     (Node 22 or later)
//   BUDGET=1 node server.js & node test-meet.mjs ws://127.0.0.1:8787
const base = (process.argv[2] ?? "").replace(/\/+$/, "");
if (!/^wss?:\/\//.test(base)) { console.error("usage: node test-meet.mjs wss://meet.blurt.work"); process.exit(2); }
setTimeout(() => { console.error("FAILED: timed out"); process.exit(1); }, 120000).unref();

const KiB = 1024;
const http = base.replace(/^ws/, "http");
const newRoom = () => Buffer.from(crypto.getRandomValues(new Uint8Array(32))).toString("base64url");
const open = (u) => new Promise((ok, no) => { const w = new WebSocket(u); w.binaryType = "arraybuffer"; w.onopen = () => ok(w); w.onerror = () => no(new Error("can't connect to " + u)); });
const closed = (w) => new Promise((ok) => w.addEventListener("close", (e) => ok(e.code), { once: true }));
const once = (w) => new Promise((ok) => w.addEventListener("message", (e) => ok(e.data), { once: true }));
const wait = (ms) => new Promise((ok) => setTimeout(ok, ms));
const expect = (what, got, want) => {
  console.log(`${what}: ${got}`);
  if (got !== want) { console.error(`FAILED: wanted ${want}`); process.exit(1); }
};

// a computer and a phone in a new room; the computer counts what reaches it
async function pair() {
  const room = newRoom();
  const mac = await open(`${base}/v1/${room}/mac`);
  const phone = await open(`${base}/v1/${room}/phone`);
  const got = { messages: 0, bytes: 0 };
  mac.addEventListener("message", (e) => { got.messages++; got.bytes += e.data.byteLength; });
  return { mac, phone, got, macClosed: closed(mac), phoneClosed: closed(phone) };
}

try {
  const health = await fetch(http + "/");
  expect("GET / answers", `${health.status} ${(await health.text()).trim()}`, "200 blurt go-between");
  for (const p of ["/v1/short/mac", `/v1/${newRoom()}/tablet`, `/secret/v1/${newRoom()}/mac`, "/favicon.ico"]) {
    expect(`${p.slice(0, 24)}… gets`, (await fetch(http + p)).status, 404);
  }

  const early = await open(`${base}/v1/${newRoom()}/phone`);
  expect("a phone with no computer is closed with", await closed(early), 4001);

  // a handshake's worth, both ways: hello, session, addresses, probes; about 10 KiB each way, all through and still open
  {
    const room = newRoom();
    const mac = await open(`${base}/v1/${room}/mac`);
    const phone = await open(`${base}/v1/${room}/phone`);
    let shut = 0;
    for (const w of [mac, phone]) w.addEventListener("close", () => shut++);
    const sizes = [300, 2400, 900, 1500, 600, 120, 120, 120, 3000, 800];
    for (const n of sizes) {
      phone.send(new Uint8Array(n));
      expect(`  phone → computer ${n} B arrives as`, (await once(mac)).byteLength, n);
      mac.send(new Uint8Array(n));
      expect(`  computer → phone ${n} B arrives as`, (await once(phone)).byteLength, n);
    }
    await wait(500);
    expect("after a handshake's traffic, connections closed", shut, 0);
    mac.close(); phone.close();
  }

  // one 20 KiB message (a 16 KiB one is fine)
  {
    const s = await pair();
    s.phone.send(new Uint8Array(16 * KiB));
    // as soon as it's through (a far network takes longer than a near one), at most 5 s
    for (let t = 0; t < 50 && s.got.bytes < 16 * KiB; t++) await wait(100);
    expect("a 16 KiB message passes, bytes through", s.got.bytes, 16 * KiB);
    s.phone.send(new Uint8Array(20 * KiB));
    expect("a 20 KiB message: the sender is closed with", await s.phoneClosed, 4003);
    expect("  and the other end with", await s.macClosed, 4003);
    expect("  and the message didn't pass, bytes through", s.got.bytes, 16 * KiB);
  }

  // 30 KiB within 5 s, as 3 KiB messages from the computer: the ninth (27 KiB) is too much
  {
    const s = await pair();
    for (let i = 0; i < 10; i++) { s.mac.send(new Uint8Array(3 * KiB)); await wait(50); }
    expect("30 KiB within 5 s: the sender is closed with", await s.macClosed, 4003);
    expect("  and the other end with", await s.phoneClosed, 4003);
  }

  // 100 KiB in all, 4 KiB every 1.1 s (at most 20 KiB in any 5.25 s): 96 KiB pass, the 25th message is too much
  {
    const s = await pair();
    let shut = null;
    s.phoneClosed.then((code) => { shut = code; });
    for (let i = 0; i < 25 && shut === null; i++) { s.phone.send(new Uint8Array(4 * KiB)); await wait(1100); }
    expect("100 KiB in all, paced: the sender is closed with", await s.phoneClosed, 4003);
    expect("  and the other end with", await s.macClosed, 4003);
    expect("  bytes that passed", s.got.bytes, 96 * KiB);
  }

  console.log("PASSED");
  process.exit(0);
} catch (e) {
  console.error("FAILED:", e.message);
  process.exit(1);
}
