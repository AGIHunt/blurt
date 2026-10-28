// Blurt feedback reports (docs/design/feedback.md): one upload route for the apps, three admin routes for the
// developer's pull.py. Reports live in the private R2 bucket as r/<id>.zip; nothing about the sender is kept.

const LIMIT = 100_000_000;            // bytes; the app refuses more before uploading (feedback.py, code too_large)
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

// a header the app sends, kept only when it is a short plain token (it ends up in the object's metadata)
function meta(request, name) {
  const v = (request.headers.get(name) || "").trim();
  return META_RE.test(v) ? v : "unknown";
}

// The body with its first 4 bytes checked against the zip signature, without holding more than the first chunk:
// the chunks read to see them are put back in front of the rest.
async function zipBody(body) {
  const reader = body.getReader();
  const head = [];
  let have = 0;
  while (have < 4) {
    const { done, value } = await reader.read();
    if (done) break;
    head.push(value);
    have += value.byteLength;
  }
  const first = new Uint8Array(Math.min(have, 4));
  let off = 0;
  for (const c of head) {
    for (let i = 0; i < c.byteLength && off < first.length; i++) first[off++] = c[i];
    if (off >= first.length) break;
  }
  if (first.length < 4 || ZIP_MAGIC.some((b, i) => first[i] !== b)) {
    reader.cancel().catch(() => {});
    return null;
  }
  return new ReadableStream({
    start(controller) {
      for (const c of head) controller.enqueue(c);
    },
    async pull(controller) {
      const { done, value } = await reader.read();
      if (done) controller.close();
      else controller.enqueue(value);
    },
    cancel(reason) {
      return reader.cancel(reason);
    },
  });
}

async function upload(request, env) {
  // per IP, not stored: the binding counts the key and forgets it
  const ip = request.headers.get("cf-connecting-ip") || "unknown";
  const { success } = await env.UPLOADS.limit({ key: ip });
  if (!success) return fail(429, "rate_limited", "too many reports from here; try again in a minute");

  const type = (request.headers.get("content-type") || "").split(";")[0].trim().toLowerCase();
  if (type !== "application/zip") return fail(400, "not_zip", "Content-Type must be application/zip");
  const raw = request.headers.get("content-length");
  if (raw === null) return fail(411, "no_length", "Content-Length is required");
  const length = Number(raw);
  if (!Number.isSafeInteger(length) || length < 0) return fail(400, "bad_length", "bad Content-Length");
  if (length > LIMIT) return fail(413, "too_large", `at most ${LIMIT} bytes`);
  if (length < 22 || !request.body) return fail(400, "not_zip", "not a zip");   // 22: an empty zip's end record

  const body = await zipBody(request.body);
  if (!body) return fail(400, "not_zip", "not a zip");

  const id = newId();
  // R2 needs the length up front for a stream; FixedLengthStream also errors if the body is shorter or longer
  const fixed = new FixedLengthStream(length);
  const piping = body.pipeTo(fixed.writable);
  try {
    await env.REPORTS.put(`r/${id}.zip`, fixed.readable, {
      httpMetadata: { contentType: "application/zip" },
      customMetadata: {
        version: meta(request, "x-blurt-version"),
        platform: meta(request, "x-blurt-platform"),
        takes: meta(request, "x-blurt-takes"),
      },
    });
    await piping;
  } catch (e) {
    piping.catch(() => {});
    return fail(400, "incomplete", "the upload did not match its Content-Length");
  }
  return json({ ok: true, id }, 201);
}

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

async function admin(request, env, rest) {
  if (!(await authorized(request, env))) {
    return json({ ok: false, code: "unauthorized", error: "unauthorized" }, 401, { "www-authenticate": "Bearer" });
  }
  if (rest === "") {
    if (request.method !== "GET") return fail(405, "method", "GET only");
    const url = new URL(request.url);
    const limit = Math.min(Math.max(Number(url.searchParams.get("limit")) || 100, 1), 1000);
    const listed = await env.REPORTS.list({
      prefix: "r/", limit, cursor: url.searchParams.get("cursor") || undefined, include: ["customMetadata"],
    });
    const reports = listed.objects.map((o) => ({
      id: o.key.slice(2, -4), size: o.size, uploaded: o.uploaded.toISOString(), meta: o.customMetadata || {},
    }));
    return json({ reports, cursor: listed.truncated ? listed.cursor : null });
  }
  const id = rest.slice(1);
  if (!rest.startsWith("/") || !ID_RE.test(id)) return fail(404, "not_found", "no such report");
  const key = `r/${id}.zip`;
  if (request.method === "GET") {
    const o = await env.REPORTS.get(key);
    if (!o) return fail(404, "not_found", "no such report");
    return new Response(o.body, {
      headers: {
        "content-type": "application/zip", "content-length": String(o.size), "cache-control": "no-store",
        "content-disposition": `attachment; filename="${id}.zip"`,
      },
    });
  }
  if (request.method === "DELETE") {
    await env.REPORTS.delete(key);
    return json({ ok: true, id });
  }
  return fail(405, "method", "GET or DELETE");
}

export default {
  async fetch(request, env) {
    const { pathname } = new URL(request.url);
    if (pathname === "/v1/report") {
      if (request.method !== "POST") return fail(405, "method", "POST only");
      return upload(request, env);
    }
    if (pathname === "/v1/admin/reports" || pathname.startsWith("/v1/admin/reports/")) {
      return admin(request, env, pathname.slice("/v1/admin/reports".length));
    }
    return fail(404, "not_found", "not found");
  },
};
