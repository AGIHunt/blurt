# Blurt relay for iPhone

Passes sealed bytes between a paired iPhone and Mac when they aren't on one network. It can't read them and stores nothing: everything is
sealed end to end with keys only the two devices have (docs/design/remote.md §Security). Blurt doesn't run a relay that carries sessions
(its go-between, below, only helps the two meet): you run your own, on one of these two, and give Blurt its address.

| | You need | Good for |
|---|---|---|
| Cloudflare Worker | A domain on Cloudflare, a free account | No server to keep. Screen over the relay for about 8 hours a day on the free plan |
| Your own server | A server with a public IP; a domain if you want `wss://` | No quota, and the shortest path if the server is near you |

Which is faster depends on where you and your computers are: time a few HTTPS requests from here to Cloudflare and to your server, and pick the shorter round trip. Check the rules where the server is, too: some countries require registering a website served from there (mainland China's ICP filing, for one).
The picture over a relay follows what the link carries, up to 4 Mbps by default; 2 Mbps out for each person using it at once is plenty.

**Give it a secret path.** Anyone who finds the relay's host can otherwise use it as a free pipe for their own traffic (they can't
read or reach yours). Make a random secret, `openssl rand -hex 16`, set it as `RELAY_SECRET`, and the relay answers only
`wss://relay.example.com/<secret>/…`. That full address, secret included, is the one Blurt gets. The path travels inside TLS, so
only the server and your devices see it; keep it out of DNS names, docs and chats.

Whichever you pick, finish with:

```bash
node test.mjs wss://relay.example.com/<secret>    # Node 22 or later, from anywhere
```

Then paste the address into Blurt → Settings → iPhone → Relay Address. The phone gets it from the Mac the next time it connects on the same
network, and from then on connects from anywhere. Copy Instructions next to it gives you a prompt for Claude Code or
Codex that does all of this.

## Blurt's go-between

`wss://meet.blurt.work` is Blurt's public go-between: the same protocol, so a phone and its computer can meet there, do the handshake and
open a direct path between them, but on a strict budget per connection: 16 KiB a message, 96 KiB in all, 24 KiB in any 5 s, and a phone
for 12 h at most. Past any of them both ends are closed with 4003. It carries no picture or audio, and it is best effort: on a network
where the direct path won't open, or once the day's free quota is gone, it can't help. A relay of your own always works, so it's the one
to set up. The go-between is `src/meet.js` with `wrangler.meet.toml` (docs/design/remote-go-between.md).

To try it without Cloudflare, `BUDGET=1 node server.js` applies the same limits (and answers `GET /` like the go-between), then:

```bash
node test-meet.mjs ws://127.0.0.1:8787      # about 30 s; or wss://meet.blurt.work
```

## Cloudflare Worker

Set the `pattern` in `wrangler.toml` to a subdomain of a domain on your account, then:

```bash
npx wrangler@4 login
npx wrangler@4 secret put RELAY_SECRET
npx wrangler@4 deploy
```

## Your own server

Node 12 or later, one dependency. It listens on 127.0.0.1:8787 unless `HOST` and `PORT` say otherwise.

```bash
sudo mkdir -p /opt/blurt-relay
sudo cp server.js package.json /opt/blurt-relay/
cd /opt/blurt-relay && sudo npm install --omit=dev
sudo useradd --system --no-create-home blurt-relay
```

`/etc/systemd/system/blurt-relay.service`:

```ini
[Unit]
Description=Blurt relay
After=network.target

[Service]
ExecStart=/usr/bin/node /opt/blurt-relay/server.js
Environment=HOST=127.0.0.1 PORT=8787 TRUST_PROXY=1 RELAY_SECRET=<secret>
User=blurt-relay
Restart=always
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl enable --now blurt-relay
```

With a domain, point a DNS record at the server (on Cloudflare: DNS only, grey cloud; going through its proxy would undo the short path) and
pass WebSockets through with a publicly trusted certificate. nginx:

```nginx
server {
    listen 443 ssl;
    server_name relay.example.com;
    ssl_certificate     /etc/letsencrypt/live/relay.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/relay.example.com/privkey.pem;
    location /<secret>/v1/ {
        proxy_pass http://127.0.0.1:8787;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header X-Real-IP $remote_addr;
        proxy_buffering off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        access_log off;
    }
    location / { return 404; }
}
```

Caddy does the same, and gets its own certificate:

```
relay.example.com {
    reverse_proxy /<secret>/v1/* 127.0.0.1:8787 {
        header_up X-Real-IP {remote_host}
    }
}
```

With no domain, set `HOST=0.0.0.0`, remove `TRUST_PROXY=1`, open the port in the firewall, and use `ws://<ip>:8787/<secret>`. What your devices say to each other is sealed
either way, but over `ws://` the secret path is in the clear: anyone on the same Wi-Fi or network path can see it, use your relay
as a pipe and keep knocking your phone off it until you change the secret. Some mobile networks also interfere with unencrypted
WebSockets. Use `wss://` on 443 unless the network between is yours.
