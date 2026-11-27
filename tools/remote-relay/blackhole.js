#!/usr/bin/env node
// A test tool, never for real use: a TCP proxy in front of a relay that does what a mobile carrier did on 2026-11-27 (docs/design/remote.md
// §A connection gone dark): it stops passing a connection's bytes, both ways, without closing anything. No FIN, no RST either way; the
// sockets stay open and are no longer read (the senders' buffers fill, as with a peer that never acks), and a close from either end isn't
// passed on. Point a test build's BLURT_RELAY_ONLY at it (SIMCTL_CHILD_BLURT_RELAY_ONLY=ws://127.0.0.1:8790).
//
//   LISTEN=8790 TARGET=127.0.0.1:8787 AFTER_MS=10000 WHICH=1 DELAY_MS=40 node blackhole.js
//
// AFTER: bytes (both ways together) after which a connection goes dark (default 1.2 MB); AFTER_MS: or this long after it opened, whichever
// first. WHICH: which connections go dark: "1" the first only, "1,3" those, "all" every one. LATER_MS: a dark connection after the first
// goes dark this long after it opened (0: at once, nothing passes), as a carrier that keeps refusing for a while. DELAY_MS: each way's
// delay. One line per event, in seconds since it started.
"use strict";
const net = require("net");

const LISTEN = Number(process.env.LISTEN || 8790);
const [TH, TP] = (process.env.TARGET || "127.0.0.1:8787").split(":");
const AFTER = Number(process.env.AFTER || 1200000);
const AFTER_MS = Number(process.env.AFTER_MS || 0);
// DELAY_MS: each way's one-way delay, as a mobile network's (bytes keep their order)
const DELAY_MS = Number(process.env.DELAY_MS || 0);
const WHICH = (process.env.WHICH || "1").split(",").map((s) => s.trim());
// LATER_MS: a dark connection after the first goes dark this long after it opened (0: at once, nothing passes); default AFTER_MS
const LATER_MS = process.env.LATER_MS === undefined ? null : Number(process.env.LATER_MS);
let darkSeen = 0;
const t0 = Date.now();
const log = (s) => console.log(`${((Date.now() - t0) / 1000).toFixed(2)} ${s}`);

let n = 0;
net.createServer((a) => {
  const id = ++n;
  const dark = WHICH.includes("all") || WHICH.includes(String(id));
  const opened = Date.now();
  let bytes = 0, black = false, up = 0, down = 0;
  const b = net.connect(Number(TP), TH);
  log(`#${id} open${dark ? " (goes dark)" : ""}`);
  const goDark = (why) => {
    if (black) return;
    black = true;
    a.pause(); b.pause();
    log(`#${id} DARK after ${bytes} bytes (${up} up, ${down} down), ${((Date.now() - opened) / 1000).toFixed(2)} s in (${why})`);
  };
  const ms = dark && darkSeen++ > 0 && LATER_MS !== null ? LATER_MS : AFTER_MS;
  if (dark && ms === 0 && LATER_MS !== null && darkSeen > 1) goDark("at once");
  const timer = dark && ms ? setTimeout(() => goDark("time"), ms) : null;
  const pass = (from, to, dir) => from.on("data", (d) => {
    if (black) return;
    bytes += d.length;
    if (dir === "up") up += d.length; else down += d.length;
    if (DELAY_MS) setTimeout(() => black || to.write(d), DELAY_MS); else to.write(d);
    if (dir === "down" && down >= 4096 && down - d.length < 4096) log(`#${id} session up (4 KB down)`);
    if (dark && bytes >= AFTER) goDark("bytes");
  });
  pass(a, b, "up");
  pass(b, a, "down");
  const ended = (who, other) => () => {
    clearTimeout(timer);
    if (black) return log(`#${id} ${who} closed its end while dark (not passed on)`);
    log(`#${id} ${who} closed (${bytes} bytes)`);
    setTimeout(() => other.end(), DELAY_MS);
  };
  a.on("end", ended("phone", b)); b.on("end", ended("relay", a));
  a.on("close", () => black || b.destroy()); b.on("close", () => black || a.destroy());
  a.on("error", () => {}); b.on("error", () => {});
}).listen(LISTEN, "127.0.0.1", () => log(`blackhole on 127.0.0.1:${LISTEN} → ${TH}:${TP}, dark after ${AFTER} bytes${AFTER_MS ? ` or ${AFTER_MS} ms` : ""}, connections ${WHICH.join(",")}`));
