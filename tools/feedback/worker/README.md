# blurt-feedback Worker

Receives the feedback reports the apps send (`skills/blurt/scripts/feedback.py send`) and keeps them in a private R2
bucket until the developer's `tools/feedback/pull.py` takes them home. The contract is `docs/design/feedback.md`.

    POST   /v1/report                 application/zip, Content-Length ≤ 100 000 000
                                      → 201 {"ok": true, "id"}; 400 not a zip; 411 no length; 413 too large; 429
    GET    /v1/admin/reports          ?cursor=&limit= (≤ 1000) → {"reports": [{"id","size","uploaded","meta"}], "cursor"}
    GET    /v1/admin/reports/<id>     the zip
    DELETE /v1/admin/reports/<id>     → {"ok": true, "id"}

Admin routes need `Authorization: Bearer <ADMIN_TOKEN>` (401 otherwise). Errors are `{"ok": false, "code", "error"}`.

What it keeps: `r/<id>.zip` (id: 128 random bits, 26 base32 characters) with metadata `version`, `platform`, `takes`
from the `X-Blurt-Version`, `X-Blurt-Platform`, `X-Blurt-Takes` headers (anything that isn't a short plain token is
stored as `unknown`). Not the IP: the rate limiter counts it (5 uploads a minute) and forgets it.

The body is streamed to R2 (FixedLengthStream of the declared length, so a body shorter or longer than its
Content-Length fails); only the first chunk is looked at, for the zip signature `PK\x03\x04`. 100 000 000 bytes is
under the 100 MB request-body limit of the Free and Pro plans.

## Deploy (once)

Wrangler 4 (`npx wrangler@4 …`), logged in to the account that owns `agihunt.info`. From this folder:

    # 1. the private bucket (no r2.dev URL: that is off unless turned on; check it stays off)
    npx wrangler@4 r2 bucket create blurt-feedback
    npx wrangler@4 r2 bucket dev-url get blurt-feedback          # → "disabled"

    # 2. reports are deleted 30 days after upload (pull.py deletes each one as soon as it is home)
    npx wrangler@4 r2 bucket lifecycle add blurt-feedback expire-reports r/ --expire-days 30 --force
    npx wrangler@4 r2 bucket lifecycle list blurt-feedback

    # 3. the admin token: made on the developer's Mac, its one copy in ~/.config/blurt-feedback/admin.env
    python3 ../pull.py init                                       # prints the next command
    sh -c '. ~/.config/blurt-feedback/admin.env && printf %s "$BLURT_FEEDBACK_ADMIN_TOKEN"' | npx wrangler@4 secret put ADMIN_TOKEN

    # 4. the Worker, on its custom domain (wrangler.toml: routes … custom_domain = true makes the DNS record and cert)
    npx wrangler@4 deploy

Check it:

    curl -s https://blurt-feedback.agihunt.info/v1/admin/reports                       # 401
    python3 ../pull.py --dry-run                                                       # lists, downloads nothing

The rate limiter's `namespace_id` in wrangler.toml is any integer unique among the account's rate limiters.

## Run it locally

    npx wrangler@4 dev --local --port 8789 --var ADMIN_TOKEN:local-test-token --persist-to /tmp/blurt-feedback-dev

R2 and the rate limiter are simulated (`--local`). Set `CLOUDFLARE_CF_FETCH_ENABLED=false` to keep `wrangler dev` from
fetching the `request.cf` placeholder from workers.cloudflare.com. Then, e.g.:

    BLURT_FEEDBACK_URL=http://localhost:8789 uv run ../../../skills/blurt/scripts/feedback.py send --ids ID
    BLURT_FEEDBACK_URL=http://localhost:8789 BLURT_FEEDBACK_ADMIN_TOKEN=local-test-token python3 ../pull.py --dry-run
