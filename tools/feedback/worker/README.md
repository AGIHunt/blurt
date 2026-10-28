# blurt-feedback Worker

Receives the feedback reports the apps send (`skills/blurt/scripts/feedback.py send`) and keeps them until the
developer's `tools/feedback/pull.py` takes them home. The contract is `docs/design/feedback.md`.

It runs on Cloudflare's **free plan only**: Workers KV and one SQLite-backed Durable Object, both with hard limits,
so nothing can ever be billed. No R2 (that needs a payment method).

## Routes

    POST   /v1/report            X-Blurt-Size (≤ 100 000 000), X-Blurt-Parts (= ceil(size / 24 MiB)),
                                 X-Blurt-Version / -Platform / -Takes (kept as the report's metadata), no body
                                 → 201 {"ok", "id", "part_size": 25165824}
                                   400 bad_request / bad_parts / not_zip · 413 too_large · 429 rate_limited · 503 full
    PUT    /v1/report/<id>/<i>   part i (0-based), Content-Length = exactly its length (part_size, the last one the
                                 rest); part 0 starts with PK\x03\x04
                                 → 201 {"ok", "id", "part", "complete"}
                                   400 bad_length / not_zip / incomplete · 404 not_found / bad_part · 409 exists ·
                                   411 no_length · 503 full
    GET    /v1/admin/reports            → {"reports": [{"id","size","parts","part_size","done","complete","uploaded",
                                           "meta"}], "cursor": null, "usage": {"day","bytes","reports","writes","held"}}
    GET    /v1/admin/reports/<id>       the zip: the parts streamed back to back (409 incomplete until all are in)
    DELETE /v1/admin/reports/<id>       the manifest and the parts → {"ok", "id"}

Admin routes need `Authorization: Bearer <ADMIN_TOKEN>` (401 otherwise; compared in constant time). Errors are
`{"ok": false, "code", "error"}`.

## How it stays inside the free plan

| limit (free plan)                | how                                                                              |
|----------------------------------|----------------------------------------------------------------------------------|
| KV value ≤ 25 MiB                | a report is cut into 24 MiB parts, one KV value each (`p/<id>/<i>`)              |
| KV 1,000 writes a day            | Budget counts them (a manifest + each part claimed) and stops at 900             |
| KV 1,000 lists a day             | none: the admin listing comes from Budget's SQLite, not a KV list                |
| KV 1 GB stored                   | Budget refuses a report that would take what is held (last 14 days) past 900 MB  |
| Worker 10 ms CPU a request       | bodies are piped (request → FixedLengthStream → KV, KV → response), never read in JS; part 0's first chunk is looked at through a tee |
| Worker 100 MB request body       | a part is ≤ 24 MiB                                                               |

Budget (one Durable Object, `idFromName("global")`, SQLite storage) also holds the day's allowance, everyone
together: at most 300 MB and 60 reports a UTC day (`503 full`, "busy today, try tomorrow"), and which parts are in —
a part is claimed before its bytes are streamed (so a second PUT of it gets `409 exists`), released if the stream
fails, and a claim never finished is free again after 15 minutes. Per IP, 5 new reports a minute (the Rate Limiting
binding; the IP is counted, never stored).

Every KV key has `expirationTtl` 14 days: the clean-up if pull.py never comes. Budget forgets a report after the
same 14 days. pull.py deletes a report as soon as it is imported, and an incomplete one once it is an hour old.

The caps can be lowered (never raised) by a var of the same name, for tests: `DAY_BYTES`, `DAY_REPORTS`,
`DAY_WRITES`, `STORE_BYTES`.

## Deploy (once)

Wrangler 4 (`npx wrangler@4 …`), logged in to the account that owns `agihunt.info`. From this folder:

    # 1. the KV namespace; put the id it prints into wrangler.toml (kv_namespaces → id = "REPLACE_ME")
    npx wrangler@4 kv namespace create blurt-feedback

    # 2. the admin token: made on the developer's Mac, its one copy in ~/.config/blurt-feedback/admin.env
    python3 ../pull.py init                                       # prints the next command
    sh -c '. ~/.config/blurt-feedback/admin.env && printf %s "$BLURT_FEEDBACK_ADMIN_TOKEN"' | npx wrangler@4 secret put ADMIN_TOKEN

    # 3. the Worker, its Durable Object (migration v1) and the custom domain (routes … custom_domain = true makes
    #    the DNS record and the certificate)
    npx wrangler@4 deploy

Check it:

    curl -s https://blurt-feedback.agihunt.info/v1/admin/reports                       # 401
    python3 ../pull.py --dry-run                                                       # lists, downloads nothing

The rate limiter's `namespace_id` in wrangler.toml is any integer unique among the account's rate limiters.

## Run it locally

    env -u CF_API_KEY -u CF_API_EMAIL -u CLOUDFLARE_API_KEY -u CLOUDFLARE_EMAIL -u CLOUDFLARE_API_TOKEN \
      WRANGLER_SEND_METRICS=false CLOUDFLARE_CF_FETCH_ENABLED=false \
      npx wrangler@4 dev --local --port 8789 --var ADMIN_TOKEN:local-test-token --persist-to /tmp/blurt-feedback-dev

KV, the Durable Object and the rate limiter are simulated (`--local`); without the credentials and with those two
variables, `wrangler dev` talks to nothing at Cloudflare. Add `--var DAY_REPORTS:3` to try the daily cap. Then:

    BLURT_FEEDBACK_URL=http://localhost:8789 uv run ../../../skills/blurt/scripts/feedback.py send --ids ID
    BLURT_FEEDBACK_URL=http://localhost:8789 BLURT_FEEDBACK_ADMIN_TOKEN=local-test-token python3 ../pull.py --dry-run

(with `NO_PROXY=localhost,127.0.0.1` when a proxy is set in the environment).
