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
                        "takes": [{"id", "audio": "audio/<id>.wav" | null}]}
    history.jsonl      the lines of history.jsonl for these takes, as written: their entry lines and the edit lines
                       ({"op": …}) that name them; "context" removed from each when context_included is false
    audio/<id>.wav     each take's kept recording

Fields are platform-neutral so the Linux and Windows apps write the same bundle (`platform` says which).

## The service (Cloudflare: one Worker + one R2 bucket)

    POST /v1/report            Content-Type: application/zip, Content-Length ≤ 100 000 000,
                               X-Blurt-Version, X-Blurt-Platform, X-Blurt-Takes (the zip's report.json is at its end,
                               so the Worker can't read them from the body without buffering it)
                               → 201 {"ok": true, "id"}; 400 not a zip; 411 no length; 413 too large; 429 too many
    GET    /v1/admin/reports            → {"reports": [{"id", "size", "uploaded", "meta"}], "cursor"}
    GET    /v1/admin/reports/<id>       the zip
    DELETE /v1/admin/reports/<id>

- The id is 128 random bits (26 characters, base32); the object is `r/<id>.zip` with its metadata (the three headers,
  each kept only when it is a short plain token). Nothing else about the sender is stored: no account, no IP.
- The worker and its deploy steps: `tools/feedback/worker/` (README.md there: the bucket, the lifecycle rule, the
  secret, the custom domain).
- Uploads are limited per IP by the Worker's rate-limit binding (5 a minute); the IP is not stored.
- The bucket is private: no public URL, no r2.dev. Only the admin routes read, with `Authorization: Bearer <token>`, a
  Worker secret whose one copy is on the developer's Mac (`~/.config/blurt-feedback/admin.env`, mode 600).
- A lifecycle rule deletes `r/` objects 30 days after upload; the pull below deletes each one as soon as it is home.

## On the developer's Mac

`tools/feedback/pull.py` (run by hand, later on a schedule): lists the new reports, downloads each, unpacks it to
`~/BlurtFeedback/<id>/` (a zip with an absolute path, `..`, a symlink or over 2 GB unpacked is refused), adds each dictation to the Dictation Lab as a case (`dictation_lab.py import-feedback DIR`:
source "feedback", `"tags": ["feedback"]` and `"feedback": {report, platform, …}`, the device and app version, the
report id in the note, the recording as its audio — `errors` stays empty, it only takes the Lab's error kinds), and deletes the report
from the bucket once that worked. From there the usual Lab and review loop reproduces and fixes it.
