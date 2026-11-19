# Owning a relay without the work

2026-11-11. Status: research, nothing built. Six agents each played one kind of user, or a competitor analyst, and walked the setup from
zero against current prices and docs. No one deployed or bought anything. Every latency below comes from docs, geography or remote.md's
own 10 ms / 630 ms figures: this Mac sits behind a fake-IP proxy, so nothing could be timed from China.

## Why

A reader on the Remote article: what makes NetEase UU远程 work is that nobody sets up a relay, which our article ends by asking for. They're
right about the experience. UU, ToDesk and 向日葵 all run a free relay for everyone (ToDesk's free plan caps it at 300 connections or 120 h a
month). Overseas and open-source tools mostly don't: Parsec has none, Moonlight leaves it to Tailscale, and RustDesk's public server now
requires a login because of abuse. Blurt runs no relay (remote.md §Away from home). So the bar is that owning one should feel like
pairing: a few clicks, no terminal, a few minutes.

## Where each kind of user stands today

| Who | Today's path | Would they finish today? | Best path | Cost a year | Latency |
|---|---|---|---|---|---|
| Mainland China, nothing | none that fits | no | Aliyun ECS ¥99 a year (2 vCPU, 3 Mbps, renewal price locked through 2029), used by IP | ¥99 | ~10–30 ms |
| Mainland China, a server (Tencent, Aliyun) | Node + systemd + nginx + certbot, or ws://IP | with an ICP-filed domain yes; otherwise maybe | one command: a single relay binary with a Let's Encrypt **IP certificate**, `wss://IP:port/secret` | ¥0 extra | same as the server |
| Mainland China, a domain, no server | Worker on Cloudflare | maybe, and slow | rent the ¥99 server and use its IP; the domain doesn't help | ¥99 | ~10–30 ms |
| Overseas, nothing | Worker on a custom domain | no (no domain) | Worker on **workers.dev**, set up by Blurt from a Cloudflare API token | $0 | nearby edge |
| Overseas or China, VPS + domain + a proxy on 443 | README server path | maybe | a published container image with Traefik or Caddy labels, routed by host | $0 | same as the VPS |
| Already on Tailscale, 蒲公英 or ZeroTier | none | no: Blurt ignores those addresses | Blurt offers the overlay address like a local one, so no relay is needed | $0 | direct |

## What was ruled out, and why

- **workers.dev from mainland China:** DNS-poisoned, as checked against 223.5.5.5 and 114.114.114.114 on 2026-11-11. Cloudflare's free plan from China goes
  via the US or HK, hundreds of ms. The China Network is Enterprise-only and needs ICP.
- **Tailscale, ZeroTier and 蒲公英 for China users:** iOS runs one VPN at a time, which knocks out Shadowrocket or Clash. Tailscale and ZeroTier
  aren't in the China App Store. Fine for anyone without that conflict, hence the overlay-address change.
- **Cloudflare quick tunnels (trycloudflare):** the address changes on every restart, and an away phone can't learn the new one.
- **nip.io / sslip.io hostnames:** not on the Public Suffix List, so every user shares one Let's Encrypt rate-limit bucket. In China they are also
  an unfiled domain.
- **An unfiled domain on a mainland server:** Tencent blocks it by SNI/Host on HTTP/HTTPS. Use the IP.
- **Free edge platforms:**
  - Aliyun ESA's free plan dropped WebSocket for new users on 2026-01-13, and has a 120 s cap.
  - EdgeOne Makers (formerly Pages): 120 s, 5 GB a month, no shared room, mainland needs ICP.
  - Render, Deno Deploy, ngrok free, 花生壳 free: transfer caps of 1–20 GB a month, an hour or a few of screen.
  - Vercel Hobby: 300 s function limit.
- **Tencent SCF / Aliyun FC function URLs:** the only no-server mainland option with a Tencent-owned `wss://` address. But the computer's
  always-open idle socket is billed around the clock, about ¥250–450 a year before traffic, more than a ¥99 server. Whether both sockets
  land on one instance is unverified.

## What to build, by how much it moves

1. **One command for any Linux server (M).** `curl -fsSL https://blurt.work/relay.sh | sudo bash`. Host it on the site's own Pages zone, not
   raw.githubusercontent.com, which is unreliable from mainland servers. Docker Hub and ghcr.io are unreliable there too, so the script
   can't depend on them.
   - Downloads a static `blurt-relay` binary with a pinned sha256: from registry.npmmirror.com, falling back to GitHub Releases.
   - Gets a Let's Encrypt IP certificate: GA since 2026-01-15, `shortlived` profile, 160 h, renewed in process.
   - Picks 443 if it's free (TLS-ALPN-01), otherwise 8443 with HTTP-01. If nginx, 宝塔 or 1Panel holds 80, it asks before adding one
     ACME-challenge snippet.
   - Opens ufw or firewalld, and prints the one cloud-firewall step with the port. Tencent Lighthouse opens only 22 and 80 by default; Aliyun
     opens 443.
   - Runs as a systemd unit with DynamicUser. A re-run reprints the address. Takes `--domain` and `--uninstall`.
   - **The app makes the secret.** Settings shows the command with `--secret …` already in it; after running it the user types only the server's
     IP into Blurt, which builds `wss://IP:port/secret` and checks it. Nothing long to copy back. On a new Aliyun or Tencent server the
     console's web shell is enough, so no SSH client is needed.
   - The binary is Rust, on what crates/blurt-remote already uses (tokio-tungstenite). It speaks server.js's protocol, and test.mjs runs in CI
     against server.js, the Worker and the binary so the three can't drift.
2. **Overlay addresses as local ones (S).** The Mac offers only `en*` and `bridge*` addresses (RemoteServer.swift `addresses()`), and the Rust
   hosts skip `utun`, `tailscale`, `zt` and similar on purpose (crates/blurt-remote/src/relay.rs). Offer Tailscale's 100.64/10 and
   fd7a:115c:a1e0::/48 addresses, and 蒲公英's and ZeroTier's, as candidates. Anyone on such a network then needs no relay at all.
3. **"Set up on Cloudflare" in the app, for users outside China (M).**
   - Blurt opens a Cloudflare token page with the permissions filled in. The user creates the token and pastes it into Blurt.
   - Blurt then does the rest itself: uploads src/index.js with the Durable Object binding and its migration on workers.dev (a random
     subdomain if the account has none) with a secret it makes, checks the address, fills it in, and forgets the token.
   - It's free, with no card or domain, and the user never touches a CLI.
   - The exact token template and API shapes are unverified.
   - Cheaper fallback (S): a Deploy to Cloudflare button from a `workers-dev/` folder. Today's wrangler.toml has `workers_dev = false` and a
     custom-domain route, so a button on it would fail.
   - Send `User-Agent: Blurt/<version>` from every client, since workers.dev's Browser Integrity Check can refuse library defaults.
4. **A guide for buying the ¥99 server (S).** Pictures of the exact choices: Shanghai or the nearest region, Ubuntu, tick HTTP/HTTPS, set a
   password, then the web shell. Together with 1, a user with nothing finishes in about 12 minutes, most of it Aliyun's sign-up and face scan.
5. **A container image for people with a proxy already on 443 (S).**
   - `ghcr.io/agihunt/blurt-relay`, amd64 and arm64, plus Traefik or Caddy label snippets routed by host only, so the secret never appears
     in proxy config.
   - Inside the image, `HOST=0.0.0.0`; today's default of 127.0.0.1 makes a hand-built container unreachable.
6. **The prompt, the README and the check (S).**
   - `relayPrompt` and the README lead with the paths above. Today they send no-domain users to plain ws://, which mobile networks can break.
   - Add the Shadowrocket and Clash rules: DIRECT for the relay host and for the STUN servers. Without the STUN rule the direct path sees the
     proxy's exit IP and never opens.
   - Make the check two messages: "can't reach the host" vs "it answers, but not as a relay: check the secret".
   - Show the relay's round trip in Settings, so 600 ms vs 10 ms is visible.
   - Fix the stale "iPhone" naming and the Node 12 vs Node 22 contradiction.
   - server.js runs open when RELAY_SECRET is unset. It should make a secret and print the address instead.

Against doing setup over SSH from the app: the app would hold a root-capable key, which undercuts "the relay can't read anything", and editing a
live nginx or Traefik config is what experienced users fear. Item 1's "app makes the secret, user pastes one line" gets the same result
without it.

## Tailscale as the main path? (2026-11-11)

Users have asked for it. It's free (Personal plan), on every platform, needs no server, and its way through NATs is better than Blurt's own:
port mapping, hard-NAT probing, IPv6. Latency depends on which path it finds:

- **Direct (WireGuard peer to peer):** about the same as the networks between phone and computer, the same as Blurt's own direct path. Domestic
  is tens of ms.
- **Through Tailscale's relays (DERP):** there is none in mainland China. Hong Kong is the nearest; one 2026 post measured ~270 ms to it from
  the mainland, and DERP is slow for video (about 2 Mbps in one report). Peer relays and custom DERP fix that, but both need a server
  again ([DERP servers](https://tailscale.com/kb/1232/derp-servers)).
- **This Mac, as a demonstration of the trap:** its proxy runs in TUN mode, so `tailscale netcheck` saw every relay through it. It reported
  Ashburn as nearest at 2.7 s, Hong Kong unreachable, and NAT mapping that varies by destination, which defeats peer to peer. A computer whose proxy captures
  Tailscale's traffic needs DIRECT for 100.64.0.0/10 and for Tailscale's own process.

The phone side is what decides it for China:

- iOS and Android run one VPN at a time, so the Tailscale app and Shadowrocket exclude each other.
- Surge, Stash, Choc and mihomo can carry a tailnet inside the proxy app as an outbound ([Stash](https://stash.wiki/en/release-notes/ios),
  [Surge](https://manual.nssurge.com/policy/tailscale.html), [mihomo](https://wiki.metacubex.one/en/config/proxies/tailscale/)).
  Shadowrocket showed no such support.
- The Tailscale app isn't in the China App Store.

So the split is:

- **Overseas, and anyone without a proxy on the phone:** Tailscale is the best default.
- **In China:** it's the free first try when it works for that user, with the one-command relay as the dependable fallback. China users who
  can't run it alongside their phone proxy can't use it.

Either way Blurt has to offer tailnet addresses (§What to build, 2). Treat them as away, not local, for the picture's ceiling, because a path
through DERP is far from a LAN. Not yet measured: a real phone on 5G reaching a Mac at home over Tailscale (`tailscale ping` shows direct or
DERP, and the round trip).

## Peer to peer: what needs a server and what doesn't (2026-11-12)

Tailscale has the same shape as Blurt. A central coordination server handles logins, keys and each device's addresses. Its relays (DERP)
carry the first hole-punching messages and the traffic of any pair that can't get through. Only the data itself goes peer to peer once a
direct path opens. Two devices behind NATs can't find each other with no third party at all: each needs to learn the other's current
address and port, at the same moment. And when both NATs are symmetric (IPv4 CGNAT on mobile data), no hole punching opens, so a relay
carries it.

Blurt already works this way: the relay is the go-between, and the pointer and video go direct when they can. Two things would make it
peer to peer without the user owning anything:

1. **A direct path as strong as Tailscale's.**
   - Everything moves onto the direct path once it opens. Today control stays on the relay.
   - IPv6 is tried first: China's mobile networks mostly have it, and a stateful IPv6 firewall opens to simultaneous sends.
   - The home router is asked to open a port (UPnP, NAT-PMP, PCP).
   - Hard NATs get Tailscale's many-ports probing.
2. **A go-between nobody has to run**, needed only for a few seconds at the start of a session:
   - **iCloud for a Mac and an iPhone on one Apple ID.** Both write their addresses to a CloudKit private database and are woken by its pushes.
     Developer ID Mac apps can use CloudKit (macOS 10.12 notes). Apple only. A phone app that users build themselves can't use Blurt's
     container until it's in the App Store.
   - **A public DHT.** For example pkarr on BitTorrent's Mainline DHT, or HyperDHT, which also relays the opening handshake. No operator;
     lookups take seconds. The computer would have to poll for a phone's arrival, or be reachable directly. Unproven from China.
   - **A Blurt-run rendezvous** (below): the simplest and most dependable.

None of these removes the relay for pairs whose NATs won't open. How many pairs that is decides whether this is worth building. The cheapest
way to find out is Tailscale itself: a phone on 5G running `tailscale ping` to the home Mac says "direct" or "via DERP".

## Left for the founder: a Blurt-run rendezvous

This is the only thing that gives UU's no-setup experience, and it isn't a relay: a shared server that only introduces the phone and the computer.
They trade addresses there, then everything goes over the direct path.

- **Cost:** about $6 a month at 1,000 monthly users and $15 at 10,000. That assumes a Worker with hibernating Durable Objects, 1 h a day each,
  and control moving off it once the direct path is up.
- **Changes it needs:**
  - control moves onto the direct path (today keys stay on the relay);
  - a per-room byte cap, so a modified client can't turn it into a free video relay;
  - its own domain for China, since workers.dev is poisoned there;
  - the user's own relay stays as the fallback.
- **The gap:** without a user's relay, the direct path fails for an estimated 20 % of sessions with IPv6 at both ends and about 50 % under
  IPv4-only CGNAT. Those users get nothing.
- **Carrying media for those sessions costs real money:** about $46–$1,150 a month on Durable Objects (slow from China), or ¥6.5k–¥162k at
  mainland bandwidth prices.
- **First, measure** how often the direct path opens on real mobile data. remote.md lists that as not yet tried.

### Would one small server carry it? (2026-11-19, estimates)

The machine in question: Aliyun, 2 vCPU, 4 GB, 3 Mbps out, unlimited traffic. With outbound under 10 Mbps, Aliyun gives 10 Mbps in
([public bandwidth](https://help.aliyun.com/zh/ecs/public-bandwidth)). Each computer that's on keeps one idle connection to the server so a
phone can find it; a phone connects only when it starts a session. Below, every computer is assumed to be on at once, which is the worst case.

| Load | 10,000 computers | 100,000 computers |
|---|---|---|
| Heartbeats, the server pinging every 30 s as server.js does (~130 B out a round) | 0.35 Mbps out | 3.5 Mbps out: over the limit |
| Heartbeats, the computer pinging every 60–120 s, the server only answering | ~0.1 Mbps | 0.6–1.2 Mbps |
| Memory, at 10–20 KB an idle connection (buffers kept small) | 0.1–0.2 GB | 1–2 GB |
| Session setup: ~2 KB out each; 5 sessions a person a day, 15 % in the busiest hour | ~0.03 Mbps | ~0.3 Mbps |
| Everyone reconnecting after a restart: full TLS ~3 KB out each | ~80 s | ~13 min; 2–4 min with session resumption |

A comfortable fit at 10,000. At 100,000 it fits only if:
- the computers send the heartbeat, every 60–120 s;
- the server is Rust or Go with small per-connection buffers, since library defaults of 64–128 KB a connection would not fit in 4 GB;
- TLS session resumption is on, and reconnects wait a random delay;
- each room has a hard cap of a few KB a second. One screen sent through it at 2–4 Mbps would fill the whole 3 Mbps.

From about 50,000 computers on at once, 5–10 Mbps of bandwidth is the cheap safety margin.

### Cloudflare's free plan as the go-between, or as the backup (2026-11-19, estimates)

The free plan allows 100,000 Durable Object requests a day and 13,000 GB-s, and an object idle enough to hibernate isn't billed for duration
([pricing](https://developers.cloudflare.com/durable-objects/platform/pricing)). Incoming WebSocket messages count 20:1. Incoming WebSocket
protocol pings and outgoing messages are free, so the computer's heartbeat costs nothing if it's a protocol ping. What counts is connecting:

- 10–30 reconnects a computer a day (sleep, wake, network changes, deploys);
- about 5 sessions a day at ~1.5 requests each;
- a reconnect after each session, as the protocol works today.

That's 25–45 requests a computer a day, so the free plan holds about 2,000–4,000 computers in daily use. Past that, the request fails
with an error; nothing is billed. Duration isn't the limit.

The account's quota is shared: the feedback service already runs on a Durable Object on the same free account. A go-between there should
get its own account, or Workers Paid. Paid is $5 a month with 1 M Durable Object requests included, then $0.15 a million. Holding 100,000
computers is about 105 M requests a month, roughly $50 a month with the Workers requests included.

As a backup behind the Aliyun box:

- **Cold standby.** The computer holds its idle connection to the primary only. It moves to Cloudflare when the primary stops answering,
  and goes back when the primary returns. A phone tries the place its computer told it about (inside the sealed session, as the relay
  address travels today), then the other one, including when the first says "no computer here". It costs nothing while the primary is up.
  An outage costs one connection per computer: free up to a few thousand, a cent on Paid.
- **Hot standby.** The computer holds both. This also covers a phone that can't reach the primary while its computer can, but it costs as
  much as running everything on Cloudflare.
- **China.** workers.dev is poisoned there, so a Cloudflare backup needs a custom domain, such as one under blurt.work. From China each
  message is 200–600 ms, so a session opened through it takes a second or two longer. Once the direct path is up, nothing goes through it.

## Decision: a public go-between on Cloudflare, nothing more (founder, 2026-11-19)

- Blurt runs one public go-between: a Worker under blurt.work on the existing Cloudflare account. There is no Aliyun primary, so no
  server of ours carries it.
  - blurt.work works from China because Cloudflare serves it from outside the mainland, so no ICP filing is needed; only workers.dev is
    poisoned.
  - The account's Workers plan is Free, so going over a limit fails and is never billed. R2 is the only paid product, and the Worker
    binds nothing that bills.
- It is offered, not promised. When it can't help (the direct path won't open, or today's quota is gone), Blurt says so and points to the
  user's own relay. The own relay stays the recommended path. When the user has set one, Blurt uses it and not the public go-between.
- It does only the go-between's job, enforced on the server:
  - a small byte budget per room, enough for a handshake and addresses and too little for a picture;
  - a short life for a phone's connection;
  - a few KB per message;
  - a Cloudflare rate-limit rule in front (40 requests in 10 s per IP), so floods are refused before they reach the Worker and use its
    quota.
- Its quota is shared with the feedback service's Worker, so a flood that uses up the day also stops feedback until 00:00 UTC. That's
  accepted.
- What was built: [remote-go-between.md](remote-go-between.md).

## Not verified

- Phones and hosts trusting a short-lived IP certificate: iOS NWConnection, Android, and webpki-roots on Windows and Linux. The chain moved to
  new roots in May 2026.
- Whether Aliyun or Tencent interfere with bare-IP TLS on 443. Their ICP blocking is documented by domain.
- Cloudflare's account-token template and Workers upload API shapes.
- SCF: same-instance routing, the connection time cap and idle billing.
- Every latency figure, and the direct path's success rate on Chinese mobile networks.
