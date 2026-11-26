// Tickets for Blurt's public relay (public.js, docs/design/remote-go-between.md §"The public relay"): minted by the go-between for a
// session whose direct path won't open, checked by the relay. A ticket is `<expiry, unix s>.<tag>.<signature>`:
//   tag       = base64url(HMAC(secret, "blurt-pair-day|" + go-between room + "|" + UTC day)[0..9])   the pair, for today's byte budget
//   signature = base64url(HMAC(secret, "blurt-ticket-1|" + relay room + "|" + role + "|" + expiry + "|" + tag)[0..16])
// The relay room is one the computer made for this session inside the sealed session: the relay never sees the pair's room, and two
// sessions there can't be told apart beyond the day's tag. Web Crypto only, so it runs in the Worker and in Node 20+ alike.
export const TICKET_LIFE_S = 60;
export const PUBLIC_RELAY = "wss://relay.blurt.work";
const ROOM = /^[A-Za-z0-9_-]{43}$/;
// a well-formed ask: only these count toward the per-IP limit
export const goodAsk = (asked) => typeof asked?.ticket?.room === "string" && ROOM.test(asked.ticket.room);

const enc = (s) => new TextEncoder().encode(s);
const b64url = (b) => btoa(String.fromCharCode(...new Uint8Array(b))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
async function hmac(secret, text, n) {
  const k = await crypto.subtle.importKey("raw", enc(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return b64url((await crypto.subtle.sign("HMAC", k, enc(text))).slice(0, n));
}

export async function ticket(secret, room, role, exp, tag) {
  return `${exp}.${tag}.${await hmac(secret, `blurt-ticket-1|${room}|${role}|${exp}|${tag}`, 16)}`;
}

// The answer to a computer's `{"ticket":{"room":…}}` in go-between room `pair`: both tickets, or why not.
export async function mint(secret, pair, asked, now = Date.now()) {
  const room = asked?.ticket?.room;
  if (!secret) return { ticket: { error: "off" } };
  if (typeof room !== "string" || !ROOM.test(room)) return { ticket: { error: "bad" } };
  const exp = Math.floor(now / 1000) + TICKET_LIFE_S;
  const tag = await hmac(secret, `blurt-pair-day|${pair}|${Math.floor(now / 86400e3)}`, 9);
  return { ticket: { relay: PUBLIC_RELAY, room, mac: await ticket(secret, room, "mac", exp, tag), phone: await ticket(secret, room, "phone", exp, tag) } };
}

// a text message that is a ticket request (no app sends text otherwise)
export const asksTicket = (msg) => typeof msg === "string" && msg.startsWith('{"ticket"') && msg.length <= 256;
export const TICKETS_PER_CONNECTION = 3;
// and per client IP, across rooms, in a minute (the go-between's TICKETS rate limiter; server.js keeps the same window)
export const TICKETS_PER_IP_MINUTE = 6;

// who "one client" is for that limit: an IPv4 address, or an IPv6 /64 (one is handed to one line or machine)
export function clientKey(ip) {
  ip = String(ip || "").split("%")[0].toLowerCase();
  if (!ip.includes(":") || /^::ffff:\d+\.\d+\.\d+\.\d+$/.test(ip)) return ip.replace(/^::ffff:/, "");
  const [a, b] = ip.split("::");
  const head = a ? a.split(":") : [], tail = b === undefined ? [] : b ? b.split(":") : [];
  const g = b === undefined ? head : [...head, ...Array(Math.max(0, 8 - head.length - tail.length)).fill("0"), ...tail];
  return g.slice(0, 4).map((h) => (parseInt(h, 16) || 0).toString(16)).join(":") + "::/64";
}
