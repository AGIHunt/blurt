// Blurt feedback reports (docs/design/feedback.md): an upload in two steps for the apps (announce, then the zip in
// parts of at most 24 MiB) and three admin routes for the developer's pull.py. Built for Cloudflare's free plan, where
// nothing can be billed: the zip's parts are Workers KV values (≤ 25 MiB each), and one SQLite-backed Durable Object
// (Budget) keeps the day's allowance and which parts are in, so KV's daily write / list quotas and its 1 GB are never
// reached. Bodies are piped from the request into KV and back without being read in JS (10 ms CPU a request).

import { DurableObject } from "cloudflare:workers";

const LIMIT = 100_000_000;                  // one report, bytes (feedback.py refuses more first: too_large)
const PART = 24 * 1024 * 1024;              // KV's value limit is 25 MiB
const TTL = 14 * 86400;                     // every key expires: the backstop if pull.py never comes
// the caps; a var of the same name lowers one (local tests: `wrangler dev --var DAY_REPORTS:3`)
const CAPS = {
  DAY_BYTES: 300_000_000,                   // everyone together, per UTC day
  DAY_REPORTS: 60,
  DAY_WRITES: 900,                          // KV: 1,000 writes a day on the free plan (a manifest + each part)
  STORE_BYTES: 900_000_000,                 // KV: 1 GB in all; what is held for the last 14 days stays under it
};
const cap = (env, name) => Math.min(CAPS[name], Number(env[name]) || CAPS[name]);
const RECLAIM_MS = 15 * 60_000;             // a part claimed this long ago and never finished can be sent again
const ZIP_MAGIC = [0x50, 0x4b, 0x03, 0x04];
const ID_RE = /^[a-z2-7]{26}$/;
const META_RE = /^[A-Za-z0-9._+-]{1,64}$/;

function json(body, status = 200, headers = {}) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store", ...headers },
  });
}

const fail = (status, code, message) => json({ ok: false, code, error: message }, status);
const STATUS = { not_found: 404, bad_part: 404, bad_length: 400, exists: 409, full: 503 };
const MESSAGE = {
  not_found: "no such report", bad_part: "no such part", bad_length: "Content-Length is not this part's length",
  exists: "this part is already in", full: "busy today, try tomorrow",
};
const budgetFail = (code) => fail(STATUS[code] || 500, code, MESSAGE[code] || code);

// 128 random bits as RFC 4648 base32, lower case, no padding: 26 characters
function newId() {
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  const alphabet = "abcdefghijklmnopqrstuvwxyz234567";
  let bits = 0, value = 0, out = "";
  for (const b of bytes) {
    value = (value << 8) | b;
    bits += 8;
    while (bits >= 5) {
      out += alphabet[(value >>> (bits - 5)) & 31];
      bits -= 5;
    }
  }
  if (bits > 0) out += alphabet[(value << (5 - bits)) & 31];
  return out;
}

// a header the app sends, kept only when it is a short plain token (it ends up in the manifest)
function meta(request, name) {
  const v = (request.headers.get(name) || "").trim();
  return META_RE.test(v) ? v : "unknown";
}

function intHeader(request, name) {
  const raw = request.headers.get(name);
  if (raw === null || !/^\d{1,12}$/.test(raw.trim())) return null;
  return Number(raw.trim());
}

const budget = (env) => env.BUDGET.get(env.BUDGET.idFromName("global"));

// ------------------------------------------------------------------ the Durable Object: the allowance and the parts
export class Budget extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    this.sql = ctx.storage.sql;
    this.sql.exec(`CREATE TABLE IF NOT EXISTS reports (id TEXT PRIMARY KEY, size INTEGER, parts INTEGER,
                     part_size INTEGER, meta TEXT, created INTEGER);
                   CREATE TABLE IF NOT EXISTS parts (id TEXT, i INTEGER, state TEXT, at INTEGER, PRIMARY KEY (id, i));
                   CREATE TABLE IF NOT EXISTS days (day TEXT PRIMARY KEY, bytes INTEGER, reports INTEGER, writes INTEGER);`);
  }

  // the rows KV has let expire (TTL) are forgotten here too, so what is held stays what KV holds
  #expire(now) {
    const cut = now - TTL * 1000;
    this.sql.exec("DELETE FROM parts WHERE id IN (SELECT id FROM reports WHERE created < ?)", cut);
    this.sql.exec("DELETE FROM reports WHERE created < ?", cut);
    this.sql.exec("DELETE FROM days WHERE day < ?", new Date(now - 30 * 86400_000).toISOString().slice(0, 10));
  }

  #day(now) {
    const day = new Date(now).toISOString().slice(0, 10);
    const row = this.sql.exec("SELECT bytes, reports, writes FROM days WHERE day = ?", day).toArray()[0];
    return { day, bytes: 0, reports: 0, writes: 0, ...row };
  }

  #saveDay(d) {
    this.sql.exec("INSERT OR REPLACE INTO days (day, bytes, reports, writes) VALUES (?, ?, ?, ?)",
      d.day, d.bytes, d.reports, d.writes);
  }

  // a new report: today's bytes / reports / KV writes and the total held, all or nothing
  reserve(id, size, parts, partSize, metaJson) {
    const now = Date.now();
    this.#expire(now);
    const d = this.#day(now);
    const held = this.sql.exec("SELECT COALESCE(SUM(size), 0) AS s FROM reports").one().s;
    const env = this.env;
    if (d.bytes + size > cap(env, "DAY_BYTES") || d.reports + 1 > cap(env, "DAY_REPORTS")
        || d.writes + 1 + parts > cap(env, "DAY_WRITES") || held + size > cap(env, "STORE_BYTES")) {
      return { ok: false, code: "full" };
    }
    d.bytes += size;
    d.reports += 1;
    d.writes += 1;                                  // the manifest; each part counts when it is claimed
    this.#saveDay(d);
    this.sql.exec("INSERT INTO reports (id, size, parts, part_size, meta, created) VALUES (?, ?, ?, ?, ?, ?)",
      id, size, parts, partSize, metaJson, now);
    return { ok: true, created: now };
  }

  // part i of a report, before its bytes are streamed into KV: once only, at its exact length
  claim(id, i, length) {
    const now = Date.now();
    this.#expire(now);
    const r = this.sql.exec("SELECT size, parts, part_size FROM reports WHERE id = ?", id).toArray()[0];
    if (!r) return { ok: false, code: "not_found" };
    if (!(i >= 0 && i < r.parts)) return { ok: false, code: "bad_part" };
    const want = i < r.parts - 1 ? r.part_size : r.size - r.part_size * (r.parts - 1);
    if (length !== want) return { ok: false, code: "bad_length", want };
    const p = this.sql.exec("SELECT state, at FROM parts WHERE id = ? AND i = ?", id, i).toArray()[0];
    if (p && (p.state === "done" || now - p.at < RECLAIM_MS)) return { ok: false, code: "exists" };
    const d = this.#day(now);
    if (d.writes + 1 > cap(this.env, "DAY_WRITES")) return { ok: false, code: "full" };
    d.writes += 1;
    this.#saveDay(d);
    this.sql.exec("INSERT OR REPLACE INTO parts (id, i, state, at) VALUES (?, ?, 'up', ?)", id, i, now);
    return { ok: true };
  }

  done(id, i) {
    this.sql.exec("UPDATE parts SET state = 'done', at = ? WHERE id = ? AND i = ?", Date.now(), id, i);
    const r = this.sql.exec("SELECT parts FROM reports WHERE id = ?", id).toArray()[0];
    const n = this.sql.exec("SELECT COUNT(*) AS n FROM parts WHERE id = ? AND state = 'done'", id).one().n;
    return { complete: !!r && n === r.parts };
  }

  release(id, i) {
    this.sql.exec("DELETE FROM parts WHERE id = ? AND i = ? AND state = 'up'", id, i);
  }

  #rows(where, ...args) {
    return this.sql.exec(`SELECT r.id, r.size, r.parts, r.part_size, r.meta, r.created,
                            (SELECT COUNT(*) FROM parts p WHERE p.id = r.id AND p.state = 'done') AS done
                          FROM reports r ${where} ORDER BY r.created`, ...args).toArray()
      .map((r) => ({
        id: r.id, size: r.size, parts: r.parts, part_size: r.part_size, meta: JSON.parse(r.meta || "{}"),
        uploaded: new Date(r.created).toISOString(), done: r.done, complete: r.done === r.parts,
      }));
  }

  list() {
    this.#expire(Date.now());
    return this.#rows("");
  }

  get(id) {
    return this.#rows("WHERE r.id = ?", id)[0] || null;
  }

  // the report is gone from KV: what it held is free again (today's counts stay: KV's quotas are per day too)
  forget(id) {
    this.sql.exec("DELETE FROM parts WHERE id = ?", id);
    this.sql.exec("DELETE FROM reports WHERE id = ?", id);
  }

  usage() {
    const now = Date.now();
    this.#expire(now);
    const held = this.sql.exec("SELECT COALESCE(SUM(size), 0) AS s FROM reports").one().s;
    return { ...this.#day(now), held };
  }
}

// ------------------------------------------------------------------ the apps' routes
async function announce(request, env) {
  // per IP, not stored: the binding counts the key and forgets it
  const ip = request.headers.get("cf-connecting-ip") || "unknown";
  const { success } = await env.UPLOADS.limit({ key: ip });
  if (!success) return fail(429, "rate_limited", "too many reports from here; try again in a minute");

  const size = intHeader(request, "x-blurt-size");
  const parts = intHeader(request, "x-blurt-parts");
  if (size === null || parts === null) return fail(400, "bad_request", "X-Blurt-Size and X-Blurt-Parts are required");
  if (size > LIMIT) return fail(413, "too_large", `at most ${LIMIT} bytes`);
  if (size < 22) return fail(400, "not_zip", "not a zip");                 // 22: an empty zip's end record
  if (parts !== Math.ceil(size / PART)) return fail(400, "bad_parts", `X-Blurt-Parts must be ceil(size / ${PART})`);

  const id = newId();
  const created = new Date().toISOString();
  const m = { version: meta(request, "x-blurt-version"), platform: meta(request, "x-blurt-platform"),
              takes: meta(request, "x-blurt-takes") };
  const r = await budget(env).reserve(id, size, parts, PART, JSON.stringify(m));
  if (!r.ok) return budgetFail(r.code);
  const manifest = { id, size, parts, part_size: PART, meta: m, created };
  await env.REPORTS.put(`m/${id}`, JSON.stringify(manifest), { expirationTtl: TTL });
  return json({ ok: true, id, part_size: PART }, 201);
}

// The body with its first bytes checked against the zip signature: a tee whose one branch is read only that far.
async function startsLikeZip(body) {
  const [probe, rest] = body.tee();
  const reader = probe.getReader();
  const head = new Uint8Array(4);
  let have = 0;
  while (have < 4) {
    const { done, value } = await reader.read();
    if (done) break;
    const take = Math.min(value.byteLength, 4 - have);
    head.set(value.subarray(0, take), have);
    have += take;
  }
  reader.cancel().catch(() => {});
  const ok = have === 4 && ZIP_MAGIC.every((b, i) => head[i] === b);
  if (!ok) rest.cancel().catch(() => {});
  return ok ? rest : null;
}

async function putPart(request, env, id, i) {
  const raw = request.headers.get("content-length");
  if (raw === null) return fail(411, "no_length", "Content-Length is required");
  const length = Number(raw);
  if (!Number.isSafeInteger(length) || length < 1 || !request.body) return fail(400, "bad_length", "bad Content-Length");
  const b = budget(env);
  const c = await b.claim(id, i, length);
  if (!c.ok) return budgetFail(c.code);

  let body = request.body;
  if (i === 0) {
    body = await startsLikeZip(body);
    if (!body) {
      await b.release(id, i);
      return fail(400, "not_zip", "not a zip");
    }
  }
  // KV takes the stream as it comes; FixedLengthStream also errors if the body is shorter or longer than declared
  const fixed = new FixedLengthStream(length);
  const piping = body.pipeTo(fixed.writable);
  try {
    await env.REPORTS.put(`p/${id}/${i}`, fixed.readable, { expirationTtl: TTL });
    await piping;
  } catch (e) {
    piping.catch(() => {});
    await b.release(id, i);
    return fail(400, "incomplete", "the part did not arrive whole");
  }
  const { complete } = await b.done(id, i);
  return json({ ok: true, id, part: i, complete }, 201);
}

// ------------------------------------------------------------------ admin
async function sha256(s) {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s)));
}

// Constant time: both sides hashed to the same length first, then compared with timingSafeEqual
async function authorized(request, env) {
  if (!env.ADMIN_TOKEN) return false;
  const m = /^Bearer (.+)$/.exec(request.headers.get("authorization") || "");
  if (!m) return false;
  const [a, b] = await Promise.all([sha256(m[1]), sha256(env.ADMIN_TOKEN)]);
  return crypto.subtle.timingSafeEqual(a, b);
}

async function admin(request, env, ctx, rest) {
  if (!(await authorized(request, env))) {
    return json({ ok: false, code: "unauthorized", error: "unauthorized" }, 401, { "www-authenticate": "Bearer" });
  }
  const b = budget(env);
  if (rest === "") {
    if (request.method !== "GET") return fail(405, "method", "GET only");
    // from the Durable Object: no KV list (1,000 a day) for a listing
    return json({ reports: await b.list(), cursor: null, usage: await b.usage() });
  }
  const id = rest.slice(1);
  if (!rest.startsWith("/") || !ID_RE.test(id)) return fail(404, "not_found", "no such report");
  const r = await b.get(id);
  if (request.method === "GET") {
    if (!r) return fail(404, "not_found", "no such report");
    if (!r.complete) return fail(409, "incomplete", `${r.done} of ${r.parts} parts are in`);
    // the parts back to back, each piped from KV in turn: the one zip that was sent
    const { readable, writable } = new FixedLengthStream(r.size);
    ctx.waitUntil((async () => {
      try {
        for (let i = 0; i < r.parts; i++) {
          const part = await env.REPORTS.get(`p/${id}/${i}`, { type: "stream" });
          if (!part) throw new Error(`part ${i} is gone`);
          await part.pipeTo(writable, { preventClose: true });
        }
        await writable.close();
      } catch (e) {
        await writable.abort(e).catch(() => {});
      }
    })());
    return new Response(readable, {
      headers: {
        "content-type": "application/zip", "content-length": String(r.size), "cache-control": "no-store",
        "content-disposition": `attachment; filename="${id}.zip"`,
      },
    });
  }
  if (request.method === "DELETE") {
    const parts = r ? r.parts : 0;
    await Promise.all([env.REPORTS.delete(`m/${id}`),
                       ...Array.from({ length: parts }, (_, i) => env.REPORTS.delete(`p/${id}/${i}`))]);
    await b.forget(id);
    return json({ ok: true, id });
  }
  return fail(405, "method", "GET or DELETE");
}

export default {
  async fetch(request, env, ctx) {
    const { pathname } = new URL(request.url);
    if (pathname === "/v1/report") {
      if (request.method !== "POST") return fail(405, "method", "POST only");
      return announce(request, env);
    }
    const part = /^\/v1\/report\/([a-z2-7]{26})\/(\d{1,3})$/.exec(pathname);
    if (part) {
      if (request.method !== "PUT") return fail(405, "method", "PUT only");
      return putPart(request, env, part[1], Number(part[2]));
    }
    if (pathname === "/v1/admin/reports" || pathname.startsWith("/v1/admin/reports/")) {
      return admin(request, env, ctx, pathname.slice("/v1/admin/reports".length));
    }
    return fail(404, "not_found", "not found");
  },
};
