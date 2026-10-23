# /// script
# requires-python = ">=3.10"
# ///
"""Captures → items without an agent (v0.7: no tokens). A capture is a line of a shots batch
(<store>/sessions/<ts>-shots/shots.jsonl, K7): a still with its typed or spoken note, or a voice input.

  captures.py file SESSION --captures N … [--project ID|inbox] [--lang en|zh]
      → {"ok", "items": [{"n","uid","id","title","kind","project","path"}], "skipped": [{"n","reason"}]}

Note = the typed text, then the words said (both when there are both). Title = the note's first sentence; quote = the
whole note; kind = a small keyword guess (issue / task / idea, else
note); frames = the shot (the inked copy first). Without a note the title says what it is ("Screenshot 14:32").
Every item gets `enrich: pending`: the app's "AI fill-in" later adds code refs, a better kind, steps — one agent run
for a whole batch (the app's App.enrich). A capture filed before (batch.json local id C-NNN) is skipped, so a
second call is harmless; so is a deleted one, and one dragged out into another app (`"taken": <wall>` — the app's
Recently Taken, kept 7 days; put back on its thread it is `"taken": null` and files as usual). Items are written with items.py (the one writer); the project is --project, else the
capture's own (shots.jsonl), else the batch's store.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import items  # noqa: E402

TITLE_MAX = 80
_SENTENCE_END = re.compile(r"[.!?](?=\s|$)|[。！？；;]")
_TRIM = ".。;；,，:：、 "

# Small, deliberately conservative keyword lists: a wrong guess costs the user a click (or AI fill-in fixes it), so
# anything unclear stays a note. English, Chinese, Japanese, Spanish, French, German.
_KINDS = [
    ("issue", re.compile(
        r"\b(bugs?|broken|crash\w*|errors?|fail\w*|wrong|glitch\w*|typo|misaligned|overlap\w*|freez\w*|stuck|"
        r"doesn'?t work|does not work|not working|won'?t (load|open|work)|can'?t (click|open|see|load|save)|"
        r"cannot (click|open|see|load|save)|blank page|404|500|fehler|kaputt|erreur|cass[ée]|no funciona|falla)\b"
        r"|报错|错误|崩溃|闪退|卡住|卡死|没反应|不对|失败|错位|重叠|白屏|乱码|不显示|点不了|打不开|加载不出|有问题|バグ|エラー|動かない|落ちる",
        re.I)),
    ("task", re.compile(
        r"\b(todo|to-do|remember to|don'?t forget|need to|needs to|follow up|ask \w+ (about|to)|check with|"
        r"schedule|send \w+ the|à faire|pendiente|erledigen)\b"
        r"|待办|记得|别忘|跟进|要做|回头|问一下|找\S{0,4}确认|安排|やること|忘れずに",
        re.I)),
    ("idea", re.compile(
        r"\b(idea|what if|how about|could we|we could|maybe we|would be (nice|great|cool)|wish|inspiration|"
        r"love (this|how)|like (this|how)|borrow|steal this|idée|idea|ideen?)\b"
        r"|想法|点子|灵感|要是|如果能|不如|可以做|可以加|借鉴|参考一下|这个好|挺好|做得好|アイデア|いいね",
        re.I)),
]


def guess_kind(text: str | None) -> str:
    t = text or ""
    for kind, pat in _KINDS:
        if pat.search(t):
            return kind
    return "note"


def first_sentence(text: str, limit: int = TITLE_MAX) -> str:
    """The note's first sentence (or line), at most `limit` characters, cut at a word where there are words."""
    line = next((ln.strip() for ln in text.strip().splitlines() if ln.strip()), "")
    m = _SENTENCE_END.search(line)
    if m and m.start() >= 3:
        line = line[:m.end()]
    line = line.strip().rstrip(_TRIM).strip() or line.strip()
    if len(line) <= limit:
        return line
    cut = line[:limit - 1]
    sp = cut.rfind(" ")
    if sp > limit * 0.6:
        cut = cut[:sp]
    return cut.rstrip(_TRIM) + "…"


LABELS = {"en": {"shot": "Screenshot", "voice": "Voice note"}, "zh": {"shot": "截图", "voice": "语音"}}


def _lang(lang: str | None) -> str:
    try:
        import handoff  # noqa: PLC0415
        return handoff.ui_lang(lang)
    except Exception:  # noqa: BLE001 — the title still needs a language
        return "zh" if (lang or "").lower().startswith("zh") else "en"


def note_of(line: dict) -> str:
    """A capture's note: what was typed first, then what was said (each once) — as the app's card shows it."""
    typed, said = (s.strip() if isinstance(s, str) else "" for s in (line.get("text"), line.get("said")))
    if typed and said:
        if said in typed:
            return typed
        if typed in said:
            return said
        return f"{typed}\n{said}"
    return typed or said


def fields_for(n: int, line: dict, lang: str) -> dict:
    """The items.py `add` fields for one capture."""
    voice = line.get("type") == "voice"
    note = note_of(line)
    if note:
        title = first_sentence(note)
    else:
        wall = line.get("wall") if isinstance(line.get("wall"), (int, float)) else time.time()
        title = f"{LABELS[lang]['voice' if voice else 'shot']} {time.strftime('%H:%M', time.localtime(wall))}"
    f: dict = {"id": f"C-{n:03d}", "kind": guess_kind(note), "title": title,
               "source": {"type": "voice" if voice else "snap", "shot": n}, "enrich": "pending"}
    if note:
        f["quote"] = note
    frames = [{"path": p} for p in (line.get("marked"), line.get("file")) if isinstance(p, str) and p]
    if frames:
        f["frames"] = frames
    return f


def file_captures(session: Path, ns: list[int], project: str | None = None, lang: str | None = None) -> dict:
    session = items.real(session)
    shots = items.read_shots(session)
    lang = _lang(lang)
    made, skipped = [], []
    items.TOUCHED.clear()
    try:
        for n in ns:
            line = shots.get(n)
            if not line:
                skipped.append({"n": n, "reason": "missing"})
                continue
            if line.get("deleted"):
                skipped.append({"n": n, "reason": "deleted"})
                continue
            if line.get("taken"):  # dragged out into another app (Recently Taken): put back on its thread first
                skipped.append({"n": n, "reason": "taken"})
                continue
            b = items.load_batch(session) or {}
            if f"C-{n:03d}" in (b.get("local") or {}):
                skipped.append({"n": n, "reason": "filed"})
                continue
            pid = project or (line.get("project") if isinstance(line.get("project"), str) else None)
            f = fields_for(n, line, lang)
            r = items.add(session, pid, f, None)
            made.append({"n": n, "uid": r["uid"], "id": r["id"], "title": f["title"], "kind": f["kind"],
                         "project": pid, "path": r["path"]})
    finally:
        items.reindex_touched()
    return {"ok": True, "items": made, "skipped": skipped}


def main(argv: list[str] | None = None) -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("file")
    s.add_argument("session")
    s.add_argument("--captures", nargs="+", type=int, required=True, metavar="N")
    s.add_argument("--project")
    s.add_argument("--lang", choices=["en", "zh", "zh-Hans"])
    a = p.parse_args(argv)
    try:
        out = file_captures(Path(a.session), a.captures, a.project, a.lang)
    except items.ItemsError as e:
        print(json.dumps({"ok": False, "error": str(e), "code": e.code}, ensure_ascii=False), flush=True)
        print(f"ERROR: {e}", file=sys.stderr)
        sys.exit(e.exit_code)
    print(json.dumps(out, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
