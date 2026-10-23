# /// script
# requires-python = ">=3.10"
# dependencies = ["numpy", "truststore"]
# ///
"""Dictation polish (docs/design/dictation.md): a small local LLM (MLX, Apple Silicon) tidies what the speech model
heard — fillers, stutters, self-corrections, punctuation, paragraphs, obvious homophones — and nothing else. A
content-loss guard falls back to the raw text whenever the model rewrote, shortened, answered or translated.

  polish.py models                          the registry (polish_models.json) + installed, selected, recommended
  polish.py setup --model ID                download a model (progress "  N/M MB" on stderr); ModelScope when the
                                            mirror is on (asr.hf_mirror / BLURT_HF_MIRROR) or Hugging Face fails
  polish.py serve [--preload] [--idle 180]  keep the model warm (127.0.0.1, $BLURT_HOME/run/polish-serve.json);
                                            unloads it after --idle s, exits after --exit-after s without a request
  polish.py run (--text T | --stdin) [--model ID] [--timeout S] [--no-server] [--context TEXT] [--no-vocab]
        → {"ok","text","raw","polished","fell_back","reason","model","ms","terms"}   (uses a running `serve` when
        there is one). The custom words ($BLURT_HOME/dictation/vocabulary.json, dictation_vocab.py) and the text
        around the cursor go into the prompt, so a misheard term ("cloud code") comes out as the listed one.
  polish.py guard RAW OUTPUT [--terms A,B] [--context TEXT]   the content-loss guard alone → {"ok","pass","reason","stats"}
  polish.py eval --model ID [--set FILE] [--out FILE]   latency (cold / warm), peak memory, fall-back rate, quality
                                            on tests/fixtures/polish_eval.jsonl

Config (record.dictation): polish "off" | "light" (default), polish_model (default: by hardware tier, see
polish_models.json "defaults"), polish_timeout_ms (3000). Resource caps are the ASR ones (asr.limits: threads,
max_memory_fraction); the model runs at utility priority. mlx-lm is added with `uv run --with` when needed.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import socket
import sys
import time
import unicodedata
import urllib.request
import uuid
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import dictation_vocab as vocab  # noqa: E402
from _common import BLURT_HOME, MODELS_DIR, global_config, load_json, save_json  # noqa: E402

HERE = Path(__file__).parent
RUN_DIR = BLURT_HOME / "run"
SERVE_FILE = RUN_DIR / "polish-serve.json"
POLISH_DIR = MODELS_DIR / "polish"
MLX_PACKAGE = "mlx-lm>=0.32.2"
DEFAULT_TIMEOUT = 3.0


class Fail(Exception):
    def __init__(self, message: str, code: str = "error", exit_code: int = 1):
        super().__init__(message)
        self.code = code
        self.exit_code = exit_code


def emit(obj: dict) -> None:
    print(json.dumps(obj, ensure_ascii=False), flush=True)


# ------------------------------------------------------------------ the content-loss guard (pure, no model)
_CJK = r"㐀-䶿一-鿿豈-﫿"
_UNIT = re.compile(rf"[{_CJK}]|[a-z]+(?:['’][a-z]+)?|[0-9]")
# fillers: removed from the raw text before its length is compared (so removing them never counts as a loss)
_FILLERS_ZH = re.compile(r"就是说|然后呢|你知道吧|对吧|那个|嗯+|呃+|额+|啊+|哎+|唉+|哦+|噢+|诶+|唔+")
_FILLERS_EN = re.compile(r"\b(?:u+m+|u+h+|e+r+m*|a+h+|h+m+|you know|i mean|sort of|kind of|like)\b")
# what a chatty model puts in front of (or after) the text instead of just the text
_CHATTY = re.compile(
    r"^\s*(?:好的|好啊|当然|以下是|下面是|这是|修改后|润色后|整理后|清理后|输出|结果|"
    r"sure\b|certainly\b|of course\b|here is\b|here's\b|here are\b|okay,? here\b|i've\b|i have (?:cleaned|polished|fixed)|"
    r"as an ai\b|polished\b|cleaned(?: up)?(?: text)?\b|output\b|corrected\b)", re.I)
_CHATTY_ANYWHERE = re.compile(r"希望对你有帮助|如有需要|let me know|hope this helps|i hope this|\bas an ai\b", re.I)
# a question: a question word first (English, after "so / okay …"), or a Chinese question word / final particle
_QUESTION_EN = re.compile(
    r"^(?:(?:so|okay|ok|and|but|well|hey|oh|now|then|also|basically|um|uh)[\s,]+)*"
    r"(?:(?:what|why|how|when|where|who|which)(?:'s|\s+(?:is|are|was|were|do|does|did|can|could|would|will|should|has|have)\b)"
    r"|(?:can|could|would|will|do|does|did|is|are|was|were|should|shall|may|might|have|has)\s+"
    r"(?:you|i|we|they|he|she|it|this|that|there|the|a|an|my|our|your|anyone|someone)\b)", re.I)
_QUESTION_ZH = re.compile(r"为什么|为啥|怎么|怎样|什么|哪|谁|多少|是否|能不能|可不可以|要不要|有没有|吗|呢$")
# self-corrections: what follows the marker is the version to keep
_CORRECTION = re.compile(r"不对|不是|我是说|我的意思是|应该是|算了|还是|更正|"
                         r"\bno wait\b|\bwait no\b|\bi mean\b|\bsorry\b|\bactually\b|\bscratch that\b|\bmake that\b|\brather\b")

# Thresholds (docs/design/dictation.md §Guard): calibrated on the eval set's reference outputs, which keep every
# legitimate edit (fillers out, a correction applied) inside them with room to spare.
SHRINK_SLACK = 8          # units the output may lose regardless of length
SHRINK_RATIO = 0.25       # … or this share of the filler-free input, whichever is larger
CORRECTION_SLACK = 6      # more per self-correction (at most two): the corrected-away words go
CORRECTION_TAIL = 4       # the first units after a correction marker (the corrected version) must all stay
GROW_RATIO = 1.25         # longer than the whole raw text × this + GROW_SLACK = something was added (an answer)
GROW_SLACK = 8
NOVEL_SLACK = 4           # words / characters not in the input: homophone fixes add one or two
NOVEL_RATIO = 0.15


def _is_question(t: str) -> bool:
    t = (t or "").strip()
    t = t.lstrip(" ,，.。")
    return "?" in t or "？" in t or bool(_QUESTION_ZH.search(t.rstrip("。.!！，, "))) or bool(_QUESTION_EN.match(t))


def units(text: str) -> list[str]:
    """What the guard counts: each CJK character, each Latin word (lower case), each digit."""
    t = unicodedata.normalize("NFKC", text or "").lower()
    return _UNIT.findall(t)


def strip_fillers(text: str) -> str:
    t = unicodedata.normalize("NFKC", text or "").lower()
    t = _FILLERS_EN.sub(" ", _FILLERS_ZH.sub(" ", t))
    # stutters: a unit (or a 2–4 character run) said twice or more in a row
    t = re.sub(rf"([{_CJK}]{{1,4}})(?:\s*\1)+", r"\1", t)
    t = re.sub(r"\b([a-z]+)(?:\s+\1\b)+", r"\1", t)
    return t


def clean_output(text: str) -> str:
    """What a model adds around the answer: a <think> block, a label line, quotes or a code fence around it all."""
    t = re.sub(r"<think>.*?(?:</think>|$)", "", text or "", flags=re.S).strip()
    t = re.sub(r"^```[a-z]*\n?|\n?```$", "", t).strip()
    t = re.sub(r"^(?:输出|结果|Output|Result|Cleaned text|Cleaned|Dictation)\s*[:：]\s*", "", t, flags=re.I).strip()
    for a, b in (('"', '"'), ("“", "”"), ("「", "」"), ("'", "'")):
        if len(t) > 2 and t.startswith(a) and t.endswith(b) and t.count(a) == 1 and t.count(b) == 1:
            t = t[1:-1].strip()
    return t


def guard(raw: str, out: str, allowed: set[str] | None = None, terms: list[str] | None = None) -> dict:
    """Is `out` a safe replacement for `raw`? → {"pass": bool, "reason": None | empty | chatty | answered |
    correction | translated | shrunk | grew | novel, "stats": {...}}. Pure: the thresholds above, nothing learned.
    `allowed`: units that may appear although they weren't spoken — the custom words and the context around the
    cursor (dictation_vocab.allowed_units), so "cloud code" → "Claude Code" is a fix, not new words.
    `terms`: custom words; one that was spoken must still be there (`term`: a dropped name is a lost meaning, even
    when it is too short for `shrunk`)."""
    core = strip_fillers(raw)
    raw_u, out_u, core_u = units(raw), units(out), units(core)
    n_raw, n_core, n_out = len(raw_u), len(core_u), len(out_u)
    raw_set, out_set = set(raw_u) | set(core_u), set(out_u)
    allowed = allowed or set()
    novel = [u for u in out_u if u not in raw_set and not u.isdigit() and u not in allowed]
    said = unicodedata.normalize("NFKC", raw or "").lower()
    fixes = list(_CORRECTION.finditer(said))
    stats = {"raw": n_raw, "core": n_core, "out": n_out, "novel": len(novel), "novel_units": novel[:12],
             "corrections": len(fixes)}
    if allowed:
        stats["vocab_units"] = sorted({u for u in out_u if u not in raw_set and u in allowed})[:12]

    def verdict(reason: str | None) -> dict:
        return {"pass": reason is None, "reason": reason, "stats": stats}

    if n_raw and not n_out:
        return verdict("empty")
    key = lambda x: re.sub(r"[\s\-]+", "", unicodedata.normalize("NFKC", x or "").lower())  # noqa: E731
    if any(key(t) and key(t) in key(raw) and key(t) not in key(out) for t in terms or []):
        return verdict("term")
    lead = _CHATTY.match(out or "")
    if (lead and not _CHATTY.match(raw or "")) or (_CHATTY_ANYWHERE.search(out or "") and not _CHATTY_ANYWHERE.search(raw or "")):
        return verdict("chatty")
    if _is_question(core.strip()) and not _is_question(out):
        return verdict("answered")
    # a self-correction keeps what comes after the marker (the model kept the wrong version, or dropped both)
    for f in fixes:
        after = units(strip_fillers(_CORRECTION.sub(" ", said[f.end():])))[:CORRECTION_TAIL]
        if any(u not in out_set for u in after):
            return verdict("correction")
    # words spoken in one script came back in the other (a translation, or English terms turned into Chinese). A
    # misheard word replaced by a custom word or a context word ("口喷机" → "口喷鸡", "cloud" → "Claude") is neither.
    cjk = re.compile(rf"[{_CJK}]")
    stems = {u.rstrip("s") for u in out_set}
    lost_latin = [u for u in set(core_u) if u.isalpha() and u.isascii() and u not in out_set and u.rstrip("s") not in stems]
    if allowed:
        novel_allowed = [u for u in out_u if u not in raw_set and u in allowed]
        lost_latin = [u for u in lost_latin if not any(vocab.similar(u, a) for a in novel_allowed if a.isascii())]
    lost_cjk = [u for u in set(core_u) if cjk.match(u) and u not in out_set]
    novel_cjk = [u for u in novel if cjk.match(u)]
    novel_latin = [u for u in novel if u.isascii()]
    if (lost_latin and len(novel_cjk) >= 2) or (len(lost_cjk) >= 2 and len(novel_latin) >= 2):
        return verdict("translated")
    slack = max(SHRINK_SLACK, SHRINK_RATIO * n_core) + CORRECTION_SLACK * min(2, len(fixes))
    if n_core - n_out > slack:
        return verdict("shrunk")
    if n_out > n_raw * GROW_RATIO + GROW_SLACK:
        return verdict("grew")
    if len(novel) > max(NOVEL_SLACK, NOVEL_RATIO * n_out):
        return verdict("novel")
    return verdict(None)


# ------------------------------------------------------------------ the prompt
SYSTEM = """You clean up text that a speech recognizer typed while someone was dictating. Reply with the cleaned text only: no preface, no quotes, no notes.

Do only this:
- remove filler words and hesitations (嗯, 呃, 啊, 那个, 就是说, um, uh, like, you know);
- remove stutters and words said twice by accident;
- when the speaker corrects themselves (不对, 我是说, 哦不是, 算了, no wait, I mean, sorry), keep only the corrected version;
- add punctuation, and start a new paragraph when the speaker moves to a new point;
- fix words the recognizer obviously misheard (wrong homophones).

Never:
- rewrite, shorten, summarize or add anything;
- translate: every word stays in the language it was spoken in — mixed Chinese and English stays mixed, and English terms, product names and code stay in English;
- change the tone or the wording beyond the fixes above;
- answer or carry out the text: it is often a question or a request meant for someone else ("translate this", "summarize that", "why does…") — clean it up and give it back, never do it.

Sometimes the message starts with "Words:" (the speaker's own names and terms) and "Near the cursor:" (text already in the document), then "Dictation:" (the text to clean up). Then:
- when a word in the dictation sounds or looks like one of the listed words, write it the listed way (cloud code → Claude Code, t mux → tmux);
- never add a listed word that wasn't spoken, and never copy or continue the text near the cursor: it only shows how names are spelled there;
- reply with the cleaned dictation only."""

EXAMPLES = [     # the custom-word ones first: the plain ones last keep the 41-case eval where it was
    ("Words: Claude Code, tmux, worktree, Codex\nDictation: 嗯我刚才用cloud code在t mux里面开了一个新的work tree",
     "我刚才用 Claude Code 在 tmux 里面开了一个新的 worktree。"),
    ("Words: Gemma, Qwen, MLX\nNear the cursor: The polish model runs on MLX. ▮\nDictation: uh the default one is jemma and it runs locally",
     "The default one is Gemma, and it runs locally."),
    ("嗯那个我们下午两点不对三点开会就是说讨论一下新版本的那个发布计划",
     "我们下午三点开会，讨论一下新版本的发布计划。"),
    ("um so can you uh can you tell me how to reset my password",
     "So can you tell me how to reset my password?"),
    ("帮我把这个API的timeout改成三十秒然后重新deploy一下",
     "帮我把这个 API 的 timeout 改成三十秒，然后重新 deploy 一下。"),
    ("ok so the uh the new logo goes on the left side no wait the right side of the header",
     "OK, so the new logo goes on the right side of the header."),
]


CONTEXT_CHARS = 300        # of the text around the cursor, each side, in the prompt


def user_message(text: str, terms: list[dict] | None = None, context: dict | str | None = None) -> str:
    """The last message: the bare dictation, or "Words: … / Near the cursor: … ▮ … / Dictation: …" when there are
    custom words or context. The fixed prompt before it is the same either way (its KV cache is reused)."""
    lines = []
    if terms:
        lines.append("Words: " + ", ".join(t["term"] for t in terms))
    near = context_text(context)
    if near:
        lines.append("Near the cursor: " + near)
    if not lines:
        return text
    return "\n".join(lines + ["Dictation: " + text])


def context_text(context: dict | str | None) -> str:
    """The context for the prompt: the text before the cursor, ▮, the text after (each cut to CONTEXT_CHARS, on one
    line), else the window title. Never stored."""
    if not context:
        return ""
    if isinstance(context, str):
        return " ".join(context.split())[:2 * CONTEXT_CHARS]
    before = " ".join(str(context.get("before") or "").split())[-CONTEXT_CHARS:]
    after = " ".join(str(context.get("after") or "").split())[:CONTEXT_CHARS]
    sel = " ".join(str(context.get("selection") or "").split())[:CONTEXT_CHARS]
    if before or after or sel:
        return (before + " ▮" + (f"[{sel}]" if sel else "") + (" " + after if after else "")).strip()
    return " ".join(str(context.get("title") or "").split())[:120]


def context_all(context: dict | str | None) -> str:
    """Every word of the context the guard may accept (title and app name included)."""
    if not context:
        return ""
    if isinstance(context, str):
        return context
    return " ".join(str(context.get(k) or "") for k in ("before", "selection", "after", "title", "app"))


def messages(text: str, terms: list[dict] | None = None, context: dict | str | None = None) -> list[dict]:
    m = [{"role": "system", "content": SYSTEM}]
    for q, a in EXAMPLES:
        m += [{"role": "user", "content": q}, {"role": "assistant", "content": a}]
    m.append({"role": "user", "content": user_message(text, terms, context)})
    return m


# ------------------------------------------------------------------ registry, hardware, config
_REG: dict | None = None


def registry() -> dict:
    global _REG
    if _REG is None:
        _REG = json.loads((HERE / "polish_models.json").read_text(encoding="utf-8"))
    return _REG


def entry(model_id: str | None) -> dict | None:
    return next((m for m in registry()["models"] if m["id"] == model_id), None)


def dictation_config() -> dict:
    d = (global_config().get("record") or {}).get("dictation")
    return d if isinstance(d, dict) else {}


def supported() -> bool:
    """MLX: Apple Silicon only."""
    import platform
    return sys.platform == "darwin" and platform.machine() == "arm64"


def hardware() -> dict:
    try:
        import transcribe  # noqa: PLC0415 — the shared probe (tiers, cores, RAM)
        hw = transcribe.probe()
        return {"tier": hw["tier"], "ram_gb": hw["ram_gb"], "chip": hw.get("chip"), "perf_cores": hw["perf_cores"]}
    except Exception:  # noqa: BLE001 — numpy missing in a bare test run: a plain guess
        return {"tier": "standard", "ram_gb": 16.0, "chip": None, "perf_cores": 4}


def limits() -> dict:
    try:
        import transcribe  # noqa: PLC0415
        lim = transcribe.limits()
        return {"threads": lim["threads"], "max_memory_fraction": lim["max_memory_fraction"]}
    except Exception:  # noqa: BLE001
        return {"threads": 3, "max_memory_fraction": 0.25}


def recommended(tier: str | None = None) -> str:
    return registry()["defaults"].get(tier or hardware()["tier"]) or registry()["defaults"]["standard"]


def mirror_on() -> bool:
    return bool(os.environ.get("BLURT_HF_MIRROR")) or bool((global_config().get("asr") or {}).get("hf_mirror"))


def hf_cache() -> Path:
    if os.environ.get("HF_HUB_CACHE"):
        return Path(os.environ["HF_HUB_CACHE"])
    return Path(os.environ.get("HF_HOME") or Path.home() / ".cache" / "huggingface") / "hub"


def _complete(d: Path) -> bool:
    return d.is_dir() and (d / "config.json").exists() and any(d.glob("*.safetensors")) \
        and not any(d.glob("*.part")) and not any(d.glob("*.incomplete"))


def model_path(m: dict) -> Path | None:
    """The newest complete copy: our own download ($BLURT_HOME/models/polish/<name>) or the Hugging Face cache."""
    own = POLISH_DIR / m["repo"].split("/")[-1]
    if _complete(own):
        return own
    root = hf_cache() / ("models--" + m["repo"].replace("/", "--"))
    if root.is_dir() and not any((root / "blobs").glob("*.incomplete")):
        for s in sorted((root / "snapshots").glob("*"), key=lambda p: p.stat().st_mtime, reverse=True):
            if _complete(s):
                return s
    return None


def selected() -> str | None:
    """The model polish uses: the configured one, else the tier's recommendation — only when it is installed."""
    want = dictation_config().get("polish_model") or recommended()
    m = entry(want)
    return want if m and model_path(m) else None


def polish_enabled() -> bool:
    return dictation_config().get("polish", "light") != "off"


def timeout_s() -> float:
    try:
        return max(0.5, float(dictation_config().get("polish_timeout_ms") or DEFAULT_TIMEOUT * 1000) / 1000)
    except (TypeError, ValueError):
        return DEFAULT_TIMEOUT


# ------------------------------------------------------------------ packages, caps
def ensure_mlx() -> None:
    """mlx-lm is only needed to run a model: re-run this command under `uv run --with mlx-lm` when it is missing
    (through a PyPI mirror when the download mirror is on)."""
    import importlib.util
    if importlib.util.find_spec("mlx_lm") is not None:
        return
    if not supported():
        raise Fail("polish needs Apple Silicon (MLX)", "unsupported", 4)
    import shutil
    uv = shutil.which("uv") or str(BLURT_HOME / "bin" / "uv")
    if os.environ.get("BLURT_POLISH_REEXEC") or not Path(uv).exists() or not sys.argv[0].endswith(".py"):
        raise Fail(f"mlx-lm is not installed (run with: uv run --with mlx-lm {Path(sys.argv[0]).name} …)", "deps", 4)
    os.environ["BLURT_POLISH_REEXEC"] = "1"
    if mirror_on():
        os.environ.setdefault("UV_DEFAULT_INDEX", "https://mirrors.aliyun.com/pypi/simple/")
    sys.stdout.flush()
    sys.stderr.flush()
    os.execvp(uv, [uv, "run", "-q", "--with", MLX_PACKAGE, os.path.abspath(sys.argv[0]), *sys.argv[1:]])


def throttle(priority: str | None = None) -> dict:
    """The ASR caps (threads before MLX loads; utility priority by default) — CLI runs only."""
    lim = limits()
    for k in ("OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS", "VECLIB_MAXIMUM_THREADS",
              "NUMEXPR_NUM_THREADS", "RAYON_NUM_THREADS", "TOKENIZERS_PARALLELISM"):
        os.environ[k] = "false" if k == "TOKENIZERS_PARALLELISM" else str(lim["threads"])
    level = priority or dictation_config().get("polish_priority") or "utility"
    done = {"threads": lim["threads"], "level": level}
    try:
        import transcribe  # noqa: PLC0415
        done.update(transcribe.apply_priority(level))
    except Exception:  # noqa: BLE001
        pass
    return done


def cap_memory() -> int | None:
    try:
        import transcribe  # noqa: PLC0415
        return transcribe.cap_mlx_memory(limits()["max_memory_fraction"])
    except Exception:  # noqa: BLE001
        return None


def peak_memory_mb() -> float | None:
    try:
        import transcribe  # noqa: PLC0415
        return transcribe.peak_memory_mb()
    except Exception:  # noqa: BLE001
        return None


# ------------------------------------------------------------------ the model
class Engine:
    """One polish model, loaded once (in-process `run` / `eval`, or kept warm by `serve`). The fixed part of the
    prompt (rules + examples) is prefilled once and reused, so a request only pays for its own text."""

    def __init__(self):
        self.model = self.tok = self.model_id = None
        self.prefix: list[int] = []
        self.prefix_cache = None
        self.last = time.time()
        self.load_ms = 0

    def load(self, model_id: str | None = None) -> "Engine":
        model_id = model_id or selected()
        if not model_id:
            raise Fail("no polish model is installed (polish.py setup --model ID)", "model_missing")
        if self.model is not None and model_id == self.model_id:
            return self
        m = entry(model_id)
        if not m:
            raise Fail(f"unknown polish model {model_id}", "usage")
        path = model_path(m)
        if not path:
            raise Fail(f"{model_id} is not downloaded (polish.py setup --model {model_id})", "model_missing")
        self.unload()
        t0 = time.perf_counter()
        ensure_mlx()
        cap_memory()
        from mlx_lm import load
        self.model, self.tok = load(str(path))
        self.model_id = model_id
        self._prefill()
        self.load_ms = int((time.perf_counter() - t0) * 1000)
        self.last = time.time()
        return self

    def unload(self):
        self.model = self.tok = self.prefix_cache = None
        self.model_id = None
        self.prefix = []
        import gc
        gc.collect()
        try:
            import mlx.core as mx
            mx.clear_cache()
        except Exception:  # noqa: BLE001
            pass

    def prompt(self, text: str, terms: list[dict] | None = None, context: dict | str | None = None) -> str:
        kw = {"tokenize": False, "add_generation_prompt": True}
        msgs = messages(text, terms, context)
        try:
            return self.tok.apply_chat_template(msgs, enable_thinking=False, **kw)
        except TypeError:
            return self.tok.apply_chat_template(msgs, **kw)

    def _prefill(self):
        """Tokens of the prompt before the user's text, and their KV cache (skipped when the tokenizer doesn't split
        the prompt cleanly there)."""
        self.prefix, self.prefix_cache = [], None
        try:
            mark = "⁣BLURT⁣"
            full = self.prompt(mark)
            head = full[:full.index(mark)]
            ptoks = self.tok.encode(head, add_special_tokens=False)
            probe = self.tok.encode(self.prompt("你好 hello"), add_special_tokens=False)
            if len(ptoks) < 8 or probe[:len(ptoks)] != ptoks:
                return
            import mlx.core as mx
            from mlx_lm.models.cache import make_prompt_cache
            cache = make_prompt_cache(self.model)
            self.model(mx.array(ptoks)[None], cache=cache)
            mx.eval([c.state for c in cache])
            self.prefix, self.prefix_cache = ptoks, cache
        except Exception as e:  # noqa: BLE001 — caching is an optimisation
            print(f"polish: no prompt cache ({type(e).__name__}: {e})", file=sys.stderr, flush=True)

    def generate(self, text: str, deadline: float, terms: list[dict] | None = None,
                 context: dict | str | None = None) -> tuple[str, bool]:
        """The model's raw reply and whether the deadline cut it short."""
        import copy
        from mlx_lm import stream_generate
        from mlx_lm.sample_utils import make_sampler
        toks = self.tok.encode(self.prompt(text, terms, context), add_special_tokens=False)
        cache = None
        if self.prefix_cache is not None and toks[:len(self.prefix)] == self.prefix:
            cache = copy.deepcopy(self.prefix_cache)
            toks = toks[len(self.prefix):]
        n_in = len(self.tok.encode(text, add_special_tokens=False))
        out, cut = [], False
        kw = {"prompt_cache": cache} if cache is not None else {}
        for r in stream_generate(self.model, self.tok, toks, max_tokens=int(n_in * 1.6) + 24,
                                 sampler=make_sampler(temp=0.0), **kw):
            out.append(r.text)
            if time.time() > deadline:
                cut = True
                break
        return "".join(out), cut

    def polish(self, text: str, model_id: str | None = None, timeout: float | None = None,
               terms: list | None = None, context: dict | str | None = None) -> dict:
        """terms: the custom words (None = $BLURT_HOME/dictation/vocabulary.json, [] = none); context: the text around
        the cursor ({"before","after","selection","title","app"}) — in the prompt and the guard's allowance only."""
        t0 = time.perf_counter()
        timeout = timeout or timeout_s()
        all_terms = vocab.load() if terms is None else vocab.normalize(terms)
        raw, applied = vocab.apply((text or "").strip(), all_terms)     # exact sounds-like / spelling fixes first
        res = {"ok": True, "raw": raw, "text": raw, "polished": None, "fell_back": False, "reason": None,
               "model": None, "terms": applied, "context": bool(context_text(context))}
        if len(units(raw)) <= 2:          # nothing to tidy
            res["reason"] = "short"
            return {**res, "ms": 0}
        use = vocab.ranked(all_terms, raw, context_all(context))
        try:
            self.load(model_id)        # warm already when the app asked on key-down; a cold load is not timed
            res["model"] = self.model_id
            reply, cut = self.generate(raw, time.time() + timeout, use, context)
        except Fail:
            raise
        except Exception as e:  # noqa: BLE001 — a model error is a fall-back, never a lost dictation
            res.update(fell_back=True, reason="error", error=f"{type(e).__name__}: {e}"[:300])
            return {**res, "ms": int((time.perf_counter() - t0) * 1000)}
        self.last = time.time()
        out = clean_output(reply)
        res["polished"] = out
        if cut:
            res.update(fell_back=True, reason="timeout")
        else:
            g = guard(raw, out, vocab.allowed_units(use, context_all(context)) if (use or context) else None,
                      [t["term"] for t in use])
            res["guard"] = g["stats"]
            if g["pass"]:
                res["text"] = out
                low, before = out.lower(), raw.lower()
                res["terms"] = list(dict.fromkeys(applied + [t["term"] for t in use if t["term"].lower() in low
                                                             and t["term"].lower() not in before]))
            else:
                res.update(fell_back=True, reason=g["reason"])
        return {**res, "ms": int((time.perf_counter() - t0) * 1000)}


# ------------------------------------------------------------------ the warm server
def _server_call(req: dict, timeout: float) -> dict | None:
    info = load_json(SERVE_FILE, None)
    if not isinstance(info, dict) or not info.get("port"):
        return None
    try:
        with socket.create_connection(("127.0.0.1", int(info["port"])), timeout=0.3) as s:
            s.settimeout(timeout)
            s.sendall((json.dumps({**req, "token": info.get("token")}, ensure_ascii=False) + "\n").encode())
            buf = b""
            while not buf.endswith(b"\n"):
                chunk = s.recv(65536)
                if not chunk:
                    break
                buf += chunk
        return json.loads(buf) if buf else None
    except (OSError, ValueError):
        return None


def cmd_serve(a):
    """One warm polish model per machine. Protocol: one JSON line in ({"token","cmd":"ping"|"load"|"polish",…}),
    one JSON line out — the same as transcribe.py serve."""
    if (r := _server_call({"cmd": "ping"}, timeout=2)) and r.get("ok"):
        return emit({"ok": True, "already": True, "pid": r.get("pid"), "model": r.get("model")})
    ensure_mlx()
    throttle(a.priority)
    RUN_DIR.mkdir(parents=True, exist_ok=True)
    token = uuid.uuid4().hex
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.bind(("127.0.0.1", 0))
    srv.listen(4)
    srv.settimeout(1.0)
    port = srv.getsockname()[1]
    save_json(SERVE_FILE, {"pid": os.getpid(), "port": port, "token": token,
                           "started": datetime.now().astimezone().isoformat(timespec="seconds")})
    eng = Engine()
    if a.preload:
        try:
            eng.load(a.model_id)
        except Fail as e:
            print(f"serve: {e}", file=sys.stderr, flush=True)
    emit({"ok": True, "pid": os.getpid(), "port": port, "model": eng.model_id, "load_ms": eng.load_ms})
    last = time.time()
    try:
        while time.time() - last < a.exit_after:
            if eng.model is not None and time.time() - eng.last > a.idle:
                eng.unload()
                print("serve: idle, model unloaded", file=sys.stderr, flush=True)
            try:
                conn, _ = srv.accept()
            except socket.timeout:
                continue
            with conn:
                conn.settimeout(10)
                try:
                    buf = b""
                    while not buf.endswith(b"\n") and len(buf) < 1 << 20:
                        chunk = conn.recv(65536)
                        if not chunk:
                            break
                        buf += chunk
                    req = json.loads(buf or b"{}")
                    if req.get("token") != token:
                        resp = {"ok": False, "error": "bad token", "code": "auth"}
                    elif req.get("cmd") == "ping":
                        resp = {"ok": True, "pid": os.getpid(), "model": eng.model_id, "loaded": eng.model is not None}
                    elif req.get("cmd") == "load":
                        last = time.time()
                        eng.load(req.get("model"))
                        eng.last = time.time()
                        resp = {"ok": True, "model": eng.model_id, "load_ms": eng.load_ms}
                    elif req.get("cmd") == "polish":
                        last = time.time()
                        resp = eng.polish(str(req.get("text") or ""), req.get("model"), req.get("timeout"),
                                          req.get("vocab"), req.get("context"))
                    else:
                        resp = {"ok": False, "error": "unknown cmd", "code": "usage"}
                except Fail as e:
                    resp = {"ok": False, "error": str(e), "code": e.code}
                except Exception as e:  # noqa: BLE001 — keep serving
                    resp = {"ok": False, "error": f"{type(e).__name__}: {e}"[:300], "code": "error"}
                try:
                    conn.sendall((json.dumps(resp, ensure_ascii=False) + "\n").encode())
                except OSError:
                    pass
    finally:
        info = load_json(SERVE_FILE, None)
        if isinstance(info, dict) and info.get("pid") == os.getpid():
            SERVE_FILE.unlink(missing_ok=True)
        srv.close()


# ------------------------------------------------------------------ commands
def cmd_run(a):
    text = sys.stdin.read() if a.stdin else (a.text or "")
    timeout = a.timeout or timeout_s()
    terms = [] if a.no_vocab else None
    if not a.no_server:
        r = _server_call({"cmd": "polish", "text": text, "model": a.model_id, "timeout": timeout, "vocab": terms,
                          "context": a.context}, timeout + 5)
        if r is not None:
            if not r.get("ok"):
                raise Fail(r.get("error") or "server error", r.get("code") or "error")
            return emit({**r, "server": True})
    if len(units(text)) <= 2:
        fixed, applied = vocab.apply(text.strip(), vocab.load() if terms is None else [])
        return emit({"ok": True, "raw": fixed, "text": fixed, "polished": None, "fell_back": False,
                     "reason": "short", "model": None, "ms": 0, "terms": applied})
    want = a.model_id or selected()
    if not want or not entry(want) or not model_path(entry(want)):
        raise Fail(f"{want or 'no polish model'} is not installed (polish.py setup --model ID)", "model_missing")
    ensure_mlx()
    throttle(a.priority)
    emit(Engine().polish(text, want, timeout, terms, a.context))


def cmd_guard(a):
    out = clean_output(a.output)
    terms = vocab.normalize([t for t in (a.terms or "").split(",") if t.strip()])
    allowed = vocab.allowed_units(terms, a.context or "") if (terms or a.context) else None
    emit({"ok": True, **guard(a.raw, out, allowed, [t["term"] for t in terms]), "cleaned": out})


def cmd_models(_a):
    hw = hardware()
    rec = recommended(hw["tier"])
    cfg = dictation_config()
    rows = []
    for m in registry()["models"]:
        p = model_path(m)
        rows.append({**m, "installed": p is not None, "path": str(p) if p else None, "recommended": m["id"] == rec})
    emit({"ok": True, "supported": supported(), "tier": hw["tier"], "ram_gb": hw["ram_gb"], "recommended": rec,
          "configured": cfg.get("polish_model"), "selected": selected(), "polish": cfg.get("polish", "light"),
          "timeout_ms": int(timeout_s() * 1000), "mirror": mirror_on(), "models": rows})


def _progress(target: Path, total_mb: float, stop) -> None:
    while not stop.wait(1.0):
        if target.exists():
            done = sum(f.stat().st_size for f in target.rglob("*") if f.is_file() and not f.is_symlink()) / 2**20
            print(f"  {int(min(done, total_mb))}/{int(total_mb)} MB", file=sys.stderr, flush=True)


def _modelscope(m: dict) -> Path:
    """mlx-community's repos are mirrored on ModelScope (fast from mainland China): files into
    $BLURT_HOME/models/polish/<name>, each written to .part first."""
    repo = m["repo"]
    dest = POLISH_DIR / repo.split("/")[-1]
    dest.mkdir(parents=True, exist_ok=True)
    api = f"https://modelscope.cn/api/v1/models/{repo}/repo/files?Recursive=true"
    with urllib.request.urlopen(urllib.request.Request(api, headers={"User-Agent": "blurt"}), timeout=30) as r:
        files = json.load(r)["Data"]["Files"]
    want = [f for f in files if f.get("Type") == "blob" and not f["Path"].endswith((".md", ".gitattributes"))]
    total = sum(f.get("Size") or 0 for f in want) / 2**20
    done = 0.0
    print(f"downloading {repo} (ModelScope)", file=sys.stderr, flush=True)
    for f in want:
        p = dest / f["Path"]
        if p.exists() and p.stat().st_size == f.get("Size"):
            done += p.stat().st_size / 2**20
            continue
        p.parent.mkdir(parents=True, exist_ok=True)
        url = f"https://modelscope.cn/models/{repo}/resolve/master/{f['Path']}"
        tmp = p.with_name(p.name + ".part")
        t0 = time.time()
        with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "blurt"}), timeout=60) as r, \
                open(tmp, "wb") as o:
            while chunk := r.read(1 << 20):
                o.write(chunk)
                done += len(chunk) / 2**20
                if time.time() - t0 > 1:
                    print(f"  {int(done)}/{int(total)} MB", file=sys.stderr, flush=True)
                    t0 = time.time()
        os.replace(tmp, p)
    return dest


def _huggingface(m: dict) -> Path:
    import importlib.util
    import threading
    if importlib.util.find_spec("huggingface_hub") is None:
        ensure_mlx()          # mlx-lm brings huggingface_hub
    os.environ.setdefault("HF_HUB_DISABLE_PROGRESS_BARS", "1")
    from huggingface_hub import snapshot_download
    print(f"downloading {m['repo']}", file=sys.stderr, flush=True)
    stop = threading.Event()
    target = hf_cache() / ("models--" + m["repo"].replace("/", "--"))
    th = threading.Thread(target=_progress, args=(target, float(m["size_mb"]), stop), daemon=True)
    th.start()
    try:
        return Path(snapshot_download(m["repo"], allow_patterns=["*.json", "*.safetensors", "*.jinja", "*.txt",
                                                                 "*.model", "tokenizer*"]))
    finally:
        stop.set()


def cmd_setup(a):
    m = entry(a.model_id)
    if not m:
        raise Fail(f"unknown polish model {a.model_id}", "usage")
    if not supported():
        raise Fail("polish needs Apple Silicon (MLX)", "unsupported")
    have = model_path(m)
    if not have:
        sources = [_modelscope, _huggingface] if mirror_on() else [_huggingface, _modelscope]
        last = None
        for src in sources:
            try:
                src(m)
                if model_path(m):
                    break
            except Exception as e:  # noqa: BLE001 — try the other source
                last = e
                print(f"  failed: {e}", file=sys.stderr, flush=True)
        if not model_path(m):
            raise Fail(f"could not download {m['repo']}: {last}", "network")
    if a.use:
        from _common import update_global_config  # noqa: PLC0415
        cfg = global_config()
        rec = cfg.setdefault("record", {})
        d = rec.get("dictation") if isinstance(rec.get("dictation"), dict) else {}
        update_global_config({"record": {**rec, "dictation": {**d, "polish_model": m["id"]}}})
    emit({"ok": True, "model": m["id"], "path": str(model_path(m))})


# ------------------------------------------------------------------ evaluation
_EVAL_FILLERS = ["嗯", "呃", "那个", "就是说", "然后呢", " um ", " uh ", " like ", "you know"]


def _norm(t: str) -> str:
    return "".join(ch for ch in unicodedata.normalize("NFKC", t or "").lower()
                   if unicodedata.category(ch)[0] in "LN")


def score(case: dict, text: str) -> dict:
    """Scripted quality for one case: the must-keep terms are there, the corrected-away ones are not, the fillers
    are gone, an untouched sentence stays the same (letters and digits), similarity to the reference."""
    import difflib
    n = _norm(text)
    keep = [k for k in case.get("keep", []) if _norm(k) not in n]
    drop = [d for d in case.get("drop", []) if _norm(d) and _norm(d) in n]
    padded = " " + (text or "").lower() + " "
    fillers_in = sum(1 for f in _EVAL_FILLERS if f in " " + case["input"].lower() + " ")
    fillers_left = sum(1 for f in _EVAL_FILLERS if f in padded and f in " " + case["input"].lower() + " ")
    return {"kept": not keep, "missing": keep, "dropped_ok": not drop, "leaked": drop,
            "fillers_in": fillers_in, "fillers_left": fillers_left,
            "untouched_ok": (n == _norm(case["input"])) if case.get("untouched") else None,
            "sim": round(difflib.SequenceMatcher(None, n, _norm(case["reference"])).ratio(), 3)}


def cmd_eval(a):
    ensure_mlx()
    applied = throttle(a.priority)
    cases = [json.loads(ln) for ln in Path(a.set).read_text(encoding="utf-8").splitlines() if ln.strip()]
    eng = Engine()
    t0 = time.perf_counter()
    eng.load(a.model_id)
    load_ms = int((time.perf_counter() - t0) * 1000)
    rows = []
    for i, c in enumerate(cases):
        r = eng.polish(c["input"], a.model_id, a.timeout)
        out = r["polished"] or ""
        rows.append({"id": c["id"], "lang": c["lang"], "tags": c.get("tags", []), "ms": r["ms"],
                     "fell_back": r["fell_back"], "reason": r["reason"], "output": out, "final": r["text"],
                     "model_score": score(c, out), "final_score": score(c, r["text"])})
        print(f"{c['id']}: {r['ms']} ms {'FALLBACK ' + str(r['reason']) if r['fell_back'] else ''}\n  in : {c['input']}\n"
              f"  out: {out}", file=sys.stderr, flush=True)
    warm = sorted(x["ms"] for x in rows[1:]) or [0]

    def rate(key, sub="final_score", only=None):
        xs = [x[sub][key] for x in rows if x[sub][key] is not None and (only is None or only(x))]
        return round(sum(1 for v in xs if v) / len(xs), 3) if xs else None
    fin = sum(x["final_score"]["fillers_in"] for x in rows)
    summary = {
        "model": eng.model_id, "cases": len(rows), "load_ms": load_ms, "cold_ms": load_ms + rows[0]["ms"],
        "warm_ms_median": warm[len(warm) // 2], "warm_ms_p90": warm[int(len(warm) * 0.9) - 1 if len(warm) > 1 else 0],
        "peak_mb": peak_memory_mb(), "fallback_rate": round(sum(x["fell_back"] for x in rows) / len(rows), 3),
        "fallback_reasons": {k: sum(1 for x in rows if x["reason"] == k) for k in {x["reason"] for x in rows if x["fell_back"]}},
        "model_kept": rate("kept", "model_score"), "model_dropped_ok": rate("dropped_ok", "model_score"),
        "model_untouched_ok": rate("untouched_ok", "model_score"),
        "model_sim": round(sum(x["model_score"]["sim"] for x in rows) / len(rows), 3),
        "final_kept": rate("kept"), "final_dropped_ok": rate("dropped_ok"), "final_untouched_ok": rate("untouched_ok"),
        "final_sim": round(sum(x["final_score"]["sim"] for x in rows) / len(rows), 3),
        "fillers_removed": round(1 - sum(x["final_score"]["fillers_left"] for x in rows) / fin, 3) if fin else None,
        "priority": applied, "prompt_cache": bool(eng.prefix),
    }
    out = {"ok": True, "summary": summary, "rows": rows}
    if a.out:
        Path(a.out).write_text(json.dumps(out, ensure_ascii=False, indent=1), encoding="utf-8")
    emit({"ok": True, "summary": summary})


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("models")
    s = sub.add_parser("setup")
    s.add_argument("--model", "--model-id", dest="model_id", required=True)
    s.add_argument("--use", action="store_true", help="also select it (record.dictation.polish_model)")
    sv = sub.add_parser("serve")
    sv.add_argument("--preload", action="store_true")
    sv.add_argument("--model", "--model-id", dest="model_id")
    sv.add_argument("--idle", type=float, default=180, help="unload the model after this many idle seconds")
    sv.add_argument("--exit-after", type=float, default=1800, help="exit after this many seconds without a request")
    sv.add_argument("--priority", choices=["utility", "background", "user-initiated", "default"])
    r = sub.add_parser("run")
    r.add_argument("--text")
    r.add_argument("--stdin", action="store_true")
    r.add_argument("--model", "--model-id", dest="model_id")
    r.add_argument("--timeout", type=float)
    r.add_argument("--no-server", action="store_true")
    r.add_argument("--priority", choices=["utility", "background", "user-initiated", "default"])
    r.add_argument("--context", help="text around the cursor (for spelling; never stored)")
    r.add_argument("--no-vocab", action="store_true", help="ignore the custom words")
    g = sub.add_parser("guard")
    g.add_argument("raw")
    g.add_argument("output")
    g.add_argument("--terms", help="custom words, comma separated")
    g.add_argument("--context")
    e = sub.add_parser("eval")
    e.add_argument("--model", "--model-id", dest="model_id", required=True)
    e.add_argument("--set", default=str(HERE.parent.parent.parent / "tests" / "fixtures" / "polish_eval.jsonl"))
    e.add_argument("--out")
    e.add_argument("--timeout", type=float, default=30.0, help="per sentence (eval measures, it doesn't cut short)")
    e.add_argument("--priority", choices=["utility", "background", "user-initiated", "default"])
    a = p.parse_args()
    try:
        {"models": cmd_models, "setup": cmd_setup, "serve": cmd_serve, "run": cmd_run, "guard": cmd_guard,
         "eval": cmd_eval}[a.cmd](a)
    except Fail as e:
        print(f"ERROR: {e}", file=sys.stderr)
        emit({"ok": False, "error": str(e), "code": e.code})
        sys.exit(e.exit_code)


if __name__ == "__main__":
    main()
