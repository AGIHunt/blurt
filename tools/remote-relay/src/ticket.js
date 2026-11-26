// Tickets for Blurt's public relay (public.js, docs/design/remote-go-between.md §"The public relay"): minted by the go-between for a
// session whose direct path won't open, checked by the relay. A ticket is `<expiry, unix s>.<tag>.<signature>`:
//   tag       = base64url(HMAC(secret, "blurt-pair-day|" + go-between room + "|" + UTC day)[0..9])   the pair, for today's byte budget
//   signature = base64url(HMAC(secret, "blurt-ticket-1|" + relay room + "|" + role + "|" + expiry + "|" + tag)[0..16])
// The relay room is one the computer made for this session inside the sealed session: the relay never sees the pair's room, and two
// sessions there can't be told apart beyond the day's tag. Web Crypto only, so it runs in the Worker and in Node 20+ alike.
export const TICKET_LIFE_S = 60;
export const PUBLIC_RELAY = "wss://relay.blurt.work";
const ROOM = /^[A-Za-z0-9_-]{43}$/;

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
