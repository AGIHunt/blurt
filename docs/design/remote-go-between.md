# The go-between: phone and computer meet through Blurt, then talk directly

2026-11-19. Status: being built (branch `claude/remote-go-between`). Why and the numbers behind it:
[remote-relay-setup.md](remote-relay-setup.md). The wire it extends: [remote-protocol.md](remote-protocol.md).

## What it is

Blurt runs one public **go-between** at `wss://meet.blurt.work`. It is a Cloudflare Worker that speaks the relay's protocol
(`/v1/<room>/<mac|phone>`, the same rooms and close codes), but on a strict budget. A phone and its computer meet there, do the handshake,
trade addresses, open the direct UDP path, and then move everything onto that path. The go-between is meant to stay quiet after the first
seconds of a session.

It is offered, not promised:

- The user's own relay, when set, wins. Blurt never uses the go-between then.
- When the direct path won't open on that network, the go-between can't carry the session. Both ends say so and point to setting up an own
  relay.
- When the day's free quota is gone, the go-between refuses connections until 00:00 UTC. Both ends say that too.

Settings on the computer: under the existing Relay Address there is a switch, **Public connection service** (公共连接服务), on by default. It
only has an effect once a phone is paired, because nothing listens or connects out before that.

## Who uses which path

In order, the first that works wins:

1. The same network, as today.
2. An overlay address: Tailscale, ZeroTier or similar (below). This needs no server at all.
3. The user's own relay, if set. This is today's behaviour, unchanged; the stream does not move.
4. The go-between, if the switch is on, the user's relay is empty, and both ends support `move`.

The computer holds one idle WebSocket per paired phone to whichever of 3 or 4 applies, as it does to a relay today. Its heartbeat must be a
**WebSocket protocol ping**, not a message: Cloudflare doesn't bill incoming protocol pings.

## Wire additions

All are backwards compatible: readers ignore unknown keys and drop unknown cases.

- `ToMac.hello` gets an optional `features: [String]`. A phone that can move its stream sends `["move"]`.
- `RemoteSessionInfo` gets an optional `features: [String]`. A host that can move sends `["move"]`.
- A host offers the go-between (in `session.relay`, and in the pairing link's `r=`) only to a phone that sent `move`. It sends `relay` as
  today for an own relay.
- New control case `streamMoved` (`{"streamMoved":{}}`), in both directions: "this is my last frame on the old stream".
- New control case `noDirect` (`{"noDirect":{}}`), host → phone: "the direct path didn't open in time; this session can't continue here".
- New frame kinds, datagrams only, sealed on channel 1 like every other datagram:
  - **7 `stream`**: body = u64 BE `offset` ∥ bytes. At most 1,100 bytes after the offset field. The bytes continue the sender's stream: the
    same length-prefixed, channel-0-sealed frames it would otherwise write to TCP or the WebSocket, with the same implicit counters.
    `offset` counts bytes of this UDP stream from 0.
  - **8 `streamAck`**: body = u64 BE `next`, the receiver's next expected offset, cumulative.

### Moving the stream

Only on the go-between, and only when both ends listed `move`:

1. After `udpOK` (the host saw a sealed datagram; the phone got the message), each side sends `streamMoved` as its last frame on the old
   stream. From then on it writes its outgoing stream bytes into kind-7 datagrams starting at offset 0.
2. A receiver keeps reading frames from the old stream until it reads `streamMoved`. Then it reads frames from the UDP stream, in offset
   order. Kind-7 bytes that arrive earlier are buffered (up to the window).
3. The WebSocket stays open and idle: idle costs the go-between nothing. If it closes, the session carries on over UDP, and the host puts
   another waiting connection in the room at once, for the phone coming back before the session's end is noticed. A frame read on the old
   stream after the phone's `streamMoved` is a phone starting over in the room: the host ends the session.
4. If no datagram arrives for 6 s after the move, the session ends. The phone connects again from the start.

Rules for the stream over UDP:

- **Sender:**
  - Keeps every unacknowledged byte, at most 256 KiB in flight.
  - Sends new bytes in chunks of up to 1,100 bytes while in flight < 256 KiB, and queues the rest.
  - **Retransmission:** after RTO = max(200 ms, 2 × smoothed RTT) with no progress, sends again from the acked offset, up to 8 chunks.
    The RTO doubles on each such timeout, up to 2 s. Three acks in a row with the same `next` resend one chunk at once.
- **Receiver:**
  - Acks on every kind-7 packet, at most once every 20 ms unless the packet filled a gap.
  - Keeps out-of-order bytes up to 256 KiB past `next`. A chunk that overlaps what it has is fine.
- Picture (kind 3), pointer (2), cursor (5), probes and feedback stay as plain datagrams, as on any direct path. Before the move, a host on
  the go-between sends no picture or audio over the WebSocket at all, and the phone sends no audio. `cursorShape` and other large control
  messages wait until the move.
- If `udpOK` hasn't happened 8 s after `session`, the host sends `noDirect` and closes. The phone shows the no-direct help.

## The go-between server

`tools/remote-relay` gets a **budget mode**: `BUDGET=1` for server.js, always on in the Worker deployed to meet.blurt.work.
`src/index.js` stays the own-relay Worker; the go-between is `src/meet.js` with its own `wrangler.meet.toml`.

**Limits per WebSocket connection** (close code **4003 `budget`** when one is passed; the apps read it as "the go-between can't carry this"):

- at most 16 KiB per message;
- at most 96 KiB in total;
- at most 24 KiB in any 5 s.

**Other limits:**

- A phone connection lives at most 12 h.
- A malformed path gets 404 before any Durable Object is touched, so it costs no Durable Object request.
- `GET /` answers `blurt go-between` in plain text, as a health check.
- Quota or rate refusals arrive as HTTP 429 or 1015, or as a failed upgrade. Apps read them as "busy today" and show that, without retrying
  in a loop: they back off at 30 s, 2 min, 10 min, then hourly. One refusal counts once, however many devices' connections it came to; a
  success, a wake or another network clears it. A phone whose user taps Retry or changes networks asks again at once (12 s after the
  refusal at the earliest), one that comes back to the app at most once a minute (2026-11-26, remote.md §Coming back).

**In front, a Cloudflare rate-limiting rule** on meet.blurt.work blocks an IP for 10 s past 40 requests in 10 s, before the Worker runs.

**Billing safety:** the account's Workers plan is Free, so limits fail and nothing is billed. The Worker binds nothing billable: no R2,
no KV, only the Durable Object class `Meet` (SQLite-backed, hibernating).

## The public relay (Hong Kong, 2026-11-26)

When the go-between finds no direct path, the session no longer just ends: it goes on through **Blurt's public relay**,
`wss://relay.blurt.work`, a Tencent Lighthouse box in Hong Kong (2 vCPU, 2 GB, 200 Mbps peak; `tools/remote-relay/public.js` behind
Caddy). It is free, shared and offered without a guarantee. Reviews: `promo/cases/public-relay-1126/` (security F1–F6, capacity).
It carries sealed bytes like any relay: it can delay or cut a session, never read or change it.

### Order of paths

Same network → overlay → own relay → go-between (direct UDP) → **public relay** → "Can't connect directly". The public relay is used
only when the go-between was (own relay empty, Public connection service on) and both ends list `publicRelay`. It is one more step of the
same setting; the apps call it the public connection service too (copy.md).

### Getting in: tickets and a room per session

1. On the go-between, 8 s after `session` with no datagram, a host whose phone listed `publicRelay` makes a room for this session:
   32 random bytes, base64url (43 characters). It sends the go-between a **text** WebSocket message `{"ticket":{"room":"<room>"}}`
   (no app sends text otherwise; the go-between answers it and never passes it on).
2. The go-between answers only a computer whose phone is in the room, at most 3 times a connection:
   `{"ticket":{"relay":"wss://relay.blurt.work","room":…,"mac":"<t>","phone":"<t>"}}`, or `{"ticket":{"error":"off|alone|limit|bad"}}`.
   A ticket is `<expiry>.<tag>.<signature>` (`src/ticket.js`): expiry = now + 60 s; tag = HMAC(S, pair's go-between room ‖ UTC day), 9
   bytes, so the relay can keep a day's byte budget per pair without learning the pair's room; signature = HMAC(S, relay room ‖ role ‖
   expiry ‖ tag), 16 bytes. S is a Worker secret (`TICKET_SECRET`) and `TICKET_SECRETS` on the box (comma list, newest first, to rotate).
3. The host checks `relay` is one of `RemotePublicRelay.addresses` (`wss://relay.blurt.work` only; a test build may add
   `BLURT_PUBLIC_RELAY`), opens `<relay>/v1/<room>/mac?t=<mac ticket>` within 5 s, then sends the phone, sealed,
   `{"publicRelay":{"address":…,"room":…,"ticket":<phone ticket>}}` and `noDirect`, and closes the go-between session as before.
   Any failure on the way (no answer in 3 s, an error, the relay not open in 5 s) is today's `noDirect` alone.
4. A phone that got `publicRelay` (an allowed address, within the last 10 s) answers `noDirect` by connecting to
   `<address>/v1/<room>/phone?t=<ticket>` and doing the usual handshake with the paired key. It gives up after **5 s** without `session`
   (refused, 4001, 4011, timeout) and shows the existing no-direct line. No retry loop: the next try starts at the go-between again.
5. The host's waiting connection takes one handshake, from that device id only. The relay closes a computer nobody came to after 60 s
   (**4011**). A ticket opens one connection; the room is never used again.

The relay never sees the pair's room or a device id in the clear before the handshake (the hello's id is inside TLS to the relay, as on
any relay), so two sessions there can be linked only within a day, by the tag.

### The picture: leases

The relay can't see whether the picture is on, so the host asks: text messages on its relay connection, never passed on.

- `{"lease":true}` asks, or renews one held; `{"lease":false}` gives it back. Answers: `{"lease":{"ok":true,"ttl":75}}`,
  `{"lease":{"ok":false,"why":"full"|"prefix"|"alone"}}`; `{"lease":{"ok":false,"why":"expired"}}` when the relay takes one back.
- At most **10** at once (`LEASES`), **one per IP prefix** of the computer (/24, /48). Refused: no queue.
- The host asks before it starts the picture; on refusal it sends `screenFailed("busy")` and asks again every **30 s** while the picture
  is still wanted, starting it (`screenView`) once granted. It renews every 30 s while frames flow; the relay takes back one unrenewed
  for 75 s. Given back at once on picture off, the app going to the background (the phone stops the picture), the session's end; after
  **5 min** with no touch, key or voice from the device the host stops the picture (`screenFailed("stopped")`) and gives it back; the
  relay takes it back after **2 h** (asked again, it goes behind anyone refused in the last minute).
- The picture on this path is Data Saver's: at most **1280 wide, 1 Mbps, 15 fps**, asked by the device and clamped by the host.

### Budgets (the relay)

Enforced by pausing the sender's reads, never by dropping (the frames are sealed in sequence, with AEAD counters):

- each direction of a room: **256 kbps** without a lease (64 KiB burst), **1.5 Mbps** with one (256 KiB burst: a keyframe is 77–170 KB);
  200 messages a second; a receiver 256 KiB behind pauses its sender, 2 MiB behind is cut;
- **1 GB per pair per UTC day** (the tag), then 4003 to both; a session at most 12 h (4003); messages at most 512 KiB;
- per IP: 16 connections, 10 upgrades in 10 s (HTTP 429); 2,000 connections in all;
- no `peek`; `GET /` answers `blurt relay`; counters once a minute, nothing about who.

### What the devices do on this path

- **Voice:** Opus, frame kind **9**, one packet per 20 ms of 16 kHz mono, about 32 kbps, when the device listed `opus` and the host did
  too; PCM (256 kbps) never goes here. A device that can't send Opus, or a host that can't hear it, has no microphone on this path.
- **Files:** at most **50 MB per device per UTC day** over this path, counted by the sender; a send over **20 MB** is asked about first.
- **The picture busy:** `screenFailed("busy")` shows a card (below); keys, pointer and voice work meanwhile, and the picture comes by
  itself once there is room.
- The connection label says Public connection service, as on the go-between.

### Copy (en / zh)

| Where | English | 中文 |
|---|---|---|
| No picture lease free (card under "Can't show the screen") | The public connection service is busy. Keys, the pointer and voice still work. | 公共连接服务繁忙。按键、指针和语音仍可使用。 |
| The same in a computer viewer (no voice there) | The public connection service is busy. Keys and the pointer still work. | 公共连接服务繁忙。按键和指针仍可使用。 |
| A send over 20 MB on this path | Send 35 MB over the public connection service? | 通过公共连接服务发送 35 MB？ |
| Past 50 MB today | You can send up to 50 MB a day over the public connection service. | 通过公共连接服务每天最多可发送 50 MB。 |
| Voice when the host can't hear Opus | To use this, update Blurt on %@. (existing) | 若要使用此功能，请更新 %@ 上的口喷鸡。（已有） |

### The box (deployed 2026-11-26)

- Ubuntu 24.04, Node 22.21.1 LTS from nodejs.org (checksum checked) in `/opt/node`, `public.js` + `ws` 8.18.0 in `/opt/blurt-relay`, a
  systemd service `blurt-relay` as user `blurt-relay`: `Restart=always`, `MemoryMax=1G`, `LimitNOFILE=65536`, `NoNewPrivileges`,
  `ProtectSystem=strict`, `ProtectHome`, `PrivateTmp`, no capabilities. The secret is `/etc/blurt-relay.env` (root, 600), never in git.
- Caddy 2.11 in front: Let's Encrypt by HTTP-01/TLS-ALPN (no DNS token on the box), no access log, errors only, header timeout 10 s,
  `X-Real-IP` to the relay. DNS: `relay.blurt.work` A 43.161.232.195, DNS only, TTL 60; CAA `0 issue "letsencrypt.org"` on that name only.
- ufw: 22, 80, 443 in; root SSH off, passwords off; journald ≤ 200 MB; unattended-upgrades on. The Lighthouse console firewall must
  allow 443 too (it didn't at first: SYNs to 443 never arrived).
- Outside check: `.github/workflows/relay-health.yml` every 10 min (TLS, ≥14 days of certificate, `GET /`, and the go-between).
- The go-between (`blurt-meet`, version f4bc4a18) mints tickets; a ticket it minted opened a room on the box.

### Measured

| What | Result |
|---|---|
| On the box, relay only (`bench-public.mjs`, no TLS, generator on the same 2 vCPUs): 10 / 30 / 60 / 120 leased 1 Mbps sessions | every frame at 15 fps; p99 1.1 / 1.1 / 1.5 / 2.3 ms; **5 / 11 / 22 / 41 %** of one vCPU; RSS 60–74 MB |
| China Mobile 5G (a phone hotspot in mainland China), 15:10 CST, ICMP | rtt 66 / 71 / 79 ms (min / avg / max), no loss |
| Local end to end: Android emulator ↔ fake host through `server.js` (tickets) and `public.js` (`LEASES=1`) | on the relay 8.3 s after launch; busy, then the picture back by itself at the next 30 s ask; Opus 32.6 kbps; dead relay → no-direct line 5.2 s after `noDirect`, no retry |
| Local end to end: Mac viewer ↔ in-process host, the same servers | lands on the relay; busy then granted (12+ H.264 frames decoded); dead relay → no-direct; a silent room → gives up in 4.5–6 s |

## Overlay addresses (Tailscale, ZeroTier, …)

- **Hosts** list the addresses of overlay interfaces as well as LAN ones: IPv4 in 100.64.0.0/10, IPv6 in fd7a:115c:a1e0::/48 (Tailscale),
  and any address on a `zt*` / `ZeroTier` interface. They go into `session.candidates` and the pairing link's `a=`, and the host listens on
  them: the Mac listens on any interface; Windows and Linux must not skip them.
- **The phone** keeps the latest candidate list per computer. Away from the same network, it tries a TCP connection to each overlay address
  at the host's TCP port, with a 1.5 s timeout, in parallel with step 3 or 4 above. If both succeed, the overlay connection wins.
- A session over an overlay address counts as **away** for the picture's ceiling. The path label says "Tailscale" for Tailscale's ranges
  and "Overlay network" otherwise.
- **Proxies:** an iPhone or Android phone runs one VPN at a time, so Tailscale and Shadowrocket exclude each other; then the overlay attempt
  just times out. On a computer, a TUN-mode proxy must send 100.64.0.0/10 and Tailscale's own traffic DIRECT. The help page says this.

## What each end shows

- **Computer, Settings → Remote Control → Other networks** (2026-11-21):
  - the go-between switch first, its line the state: in use, why it can't be now (over the limit, no direct path), standing in
    while the own relay is down, or only used while it is;
  - then Own relay with the Relay Address field (the page's control width, the whole address in its tooltip), its line what
    the check found;
  - Copy Instructions as the section's footnote. The path a connected device came by is on the page's first row.
- **Phone:** the connection label names the path. On `noDirect` or 4003 it shows the no-direct line below, and on "busy" the
  over-the-limit line.

All copy is in English and Chinese, plain and concrete. "Go-between" is this doc's word only; the apps say:

| | English | 中文 |
|---|---|---|
| The switch | Public connection service | 公共连接服务 |
| Its note | Free, with no guarantee. If a network can't connect directly, set up your own relay. | 免费，不保证可用。无法直连时，请设置自建中转。 |
| Own relay | Own relay | 自建中转 |
| Paths | Same network · Direct · Tailscale · Virtual network · Own relay · Public connection service | 同一网络 · 直连 · Tailscale · 虚拟局域网 · 自建中转 · 公共连接服务 |
| No direct path | Can't connect directly. Set up your own relay on the computer. | 无法直连。请在电脑上设置自建中转。 |
| Over the limit | The public connection service has reached today's limit. Try again later, or use your own relay. | 公共连接服务今日已达上限。请稍后再试，或使用自建中转。 |

## Not measured yet

- How often the direct path opens on Chinese mobile networks.
- The go-between's round trip from China, to blurt.work on Cloudflare's free plan.
