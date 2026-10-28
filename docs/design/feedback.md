# Feedback reports (v1.0.3)

A user sends chosen dictations to the Blurt developers, who reproduce and fix them on their own Mac. There is no rating
and no form: what was said, what Blurt made of it at every step, and on what machine, is enough to replay it.

## In the app

Dictation page → History → **Send Feedback…** (header, right). A sheet lists the recent dictations with a checkbox
each (the rows selected in the list come pre-checked), Select All, and one switch, **Include the text around the
cursor** (on). Below: what is sent, where it goes, who can read it and when it is deleted, the total size (at most
100 MB). **Send** uploads it and shows the report's ID (copyable). Nothing is sent without that click.

What goes in: the device (platform, OS and version, machine model, chip, cores, memory, locale), the app's version, the
dictation settings and the models (speech, polish), the custom words, and for each dictation its history line (what
was heard, every streamed piece, what polish and the structuring pass did, the guard's reasons, timings, the fit at the
cursor, the user's correction) and its original recording. The text around the cursor only with the switch on.

Recordings are kept by default since v1.0.3 (record.dictation.keep_audio: absent = on, false = off), for 30 days
(retention_days); without a recording a dictation is sent as text only.

## The bundle

One zip, at most 100 000 000 bytes:

    report.json        {"schema": 1, "created": ISO-8601, "platform": "macos" | "linux" | "windows",
                        "app": {"version", "build"},
                        "device": {"os", "os_version", "arch", "model", "chip", "cores", "memory_gb", "locale"},
                        "dictation": {the record.dictation settings},
                        "models": {"asr", "polish", …},
                        "terms": [custom words],
                        "context_included": bool,
                        "takes": [{"id", "audio": "audio/<id>.flac" | "audio/<id>.wav" | null}]}
    history.jsonl      the lines of history.jsonl for these takes, as written: their entry lines and the edit lines
                       ({"op": …}) that name them; "context" removed from each when context_included is false
    audio/<id>.flac    each take's kept recording, lossless (about half the 16 kHz WAV: afconvert on macOS, ffmpeg
                       elsewhere; 32 kbit/s AAC changed what the speech model heard on a test clip, and a report is
                       for replaying exactly what was heard); audio/<id>.wav when neither can convert it. The Lab
                       import turns it back into its 16 kHz mono audio.wav

Fields are platform-neutral so the Linux and Windows apps write the same bundle (`platform` says which).

## The service (Cloudflare free plan: one Worker, Workers KV, one Durable Object)

Nothing that can be billed: there is no payment method on the account, so no R2. Workers KV holds the reports, one
SQLite-backed Durable Object (`Budget`) keeps the day's allowance and which parts are in. The app uploads in two steps:

    POST /v1/report              X-Blurt-Size (the zip's bytes, ≤ 100 000 000), X-Blurt-Parts (ceil(size / 24 MiB)),
                                 X-Blurt-Version, X-Blurt-Platform, X-Blurt-Takes (the metadata; the zip's report.json
                                 is at its end, so the Worker can't read them from the body); no body
                                 → 201 {"ok", "id", "part_size": 25165824}; 413 too large; 429 rate_limited (this IP);
                                   503 full (today's allowance is used up: "busy today, try tomorrow")
    PUT  /v1/report/<id>/<i>     part i of the zip, Content-Length exactly its length; part 0 starts with PK\x03\x04
                                 → 201 {"ok", "id", "part", "complete"}; 404 no such report or part; 409 the part is
                                   already in; 400 wrong length / not a zip / the body broke off
    GET    /v1/admin/reports            → {"reports": [{"id", "size", "parts", "done", "complete", "uploaded",
                                           "meta"}], "usage": {today's bytes, reports, KV writes; bytes held}}
    GET    /v1/admin/reports/<id>       the zip (the parts streamed back to back; 409 until all are in)
    DELETE /v1/admin/reports/<id>       the manifest and the parts

- The id is 128 random bits (26 characters, base32). KV keys: `m/<id>` the manifest (size, parts, part_size, meta,
  created), `p/<id>/<i>` each part (≤ 24 MiB: a KV value is at most 25 MiB). Every key expires after 14 days
  (expirationTtl): the clean-up if nobody pulls. Nothing about the sender is stored: no account, no IP.
- The free plan's hard limits, and how they are kept: KV 1 GB stored (Budget refuses a report that would take what the
  last 14 days hold past 900 MB), 1,000 KV writes a day (Budget counts the manifest and each part, stops at 900),
  1,000 KV lists a day (the admin listing comes from Budget, not a KV list), 10 ms CPU a request (the bodies are piped
  request → KV → response, never read in JS; part 0's first bytes through a tee), 100 MB a request body (a part is
  ≤ 24 MiB).
- The day's allowance, everyone together, per UTC day: at most 300 MB and 60 reports (503 `full`). Per IP: 5 new
  reports a minute (the Worker's rate-limit binding; the IP is counted, not stored).
- A part is claimed in Budget before its bytes are streamed (a second PUT of it: 409), released if the stream fails;
  a claim never finished is free again after 15 minutes. The app sends a part that failed once more.
- Only the admin routes read, with `Authorization: Bearer <token>`, a Worker secret whose one copy is on the
  developer's Mac (`~/.config/blurt-feedback/admin.env`, mode 600). No workers.dev URL; the custom domain only.
- The worker and its deploy steps: `tools/feedback/worker/` (README.md there: the KV namespace, the secret, the
  Durable Object's migration, the custom domain).

## On the developer's Mac

`tools/feedback/pull.py` (run by hand, later on a schedule): lists the new reports, downloads each complete one, unpacks it to
`~/BlurtFeedback/<id>/` (a zip with an absolute path, `..`, a symlink or over 2 GB unpacked is refused), adds each dictation to the Dictation Lab as a case (`dictation_lab.py import-feedback DIR`:
source "feedback", `"tags": ["feedback"]` and `"feedback": {report, platform, …}`, the device and app version, the
report id in the note, the recording as its audio, back to 16 kHz WAV — `errors` stays empty, it only takes the Lab's
error kinds), and deletes the report from the service once that worked. A report whose parts never all arrived (the
app said the send failed) is deleted once it is an hour old. From there the usual Lab and review loop reproduces and fixes it.
