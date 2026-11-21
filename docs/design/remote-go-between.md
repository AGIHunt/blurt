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
3. The WebSocket stays open and idle: idle costs the go-between nothing. If it closes, the session carries on over UDP.
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
  in a loop: they back off at 30 s, 2 min, 10 min, then hourly.

**In front, a Cloudflare rate-limiting rule** on meet.blurt.work blocks an IP for 10 s past 40 requests in 10 s, before the Worker runs.

**Billing safety:** the account's Workers plan is Free, so limits fail and nothing is billed. The Worker binds nothing billable: no R2,
no KV, only the Durable Object class `Meet` (SQLite-backed, hibernating).

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
