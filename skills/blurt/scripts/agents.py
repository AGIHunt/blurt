# /// script
# requires-python = ">=3.10"
# ///
"""Which coding-agent CLI processes a recording, in what order, and why one couldn't. The one place agent CLIs are
described (contract C5): the apps and live.py run what this returns instead of building commands themselves.

  agents.py status [--json]        each agent in the configured order: installed? logged in? the fix command
  agents.py order [--json] [--repo DIR]   the configured order (config record.agents), one id per line
  agents.py classify FILE          a failed run's log (agent.log) → {"class": "auth|quota|network|model|skill|null", …}
  agents.py detect [--repo DIR] [--ids a,b] [--no-login] [--no-version] [--lang L]
                                   → {"order": [...], "pick": id|null, "agents": [{id, name, path, state, why, fix,
                                      installed, version, login, headless, interactive}]}
  agents.py command ID headless|interactive --prompt TEXT|--prompt-file F --repo DIR [--var k=v …] [--no-events]
                   [--no-mcp] [--processing]
                                   → {"id","mode","argv","cwd","env","url","events","terminal","clipboard","open_app",
                                      "retry_exit","prompt_file"}; --processing (an unattended organising run): the
                                      processing model + effort and the usage flags → also "processing", "usage";
                                      "scripts" = the folder the run may call (`uv run <scripts>/<name>.py`: name it
                                      so in the prompt), env = what a sandboxed run needs (sandbox_env)
  agents.py models ID              → {"ok","id","models":[{id,name,description,cheap}],"cheapest","cli_default",
                                      "efforts","processing":{model,effort}}   (no network, no tokens)
  agents.py usage ID FILE [--offset N]   tokens a run reported in its output (from byte N) → {"ok","usage"|null}
  agents.py install ID [--skill] [--mcp] [--dry-run]   → {"changes": [{action, path|argv, …}], "applied": bool}
  agents.py prompt work --items REF … [--mode session|external] [--worktree on|off] [--branch B] [--handoff H]
                   [--lang en|zh]   → {"ok","prompt","title","handoff","path","items"}: a short prompt pointing at
                                      the items' hand-off note (K6; written unless --handoff names one), its first
                                      line the title ("AW-12 · <title> (Blurt hand-off)" — work_title)

The desktop app as a hand-off target (interactive.desktop): desktop_prompt / desktop_url build its claude:// link,
desktop_continue_check says whether a running terminal session may move there. set_thread_name names a Codex
thread through `codex app-server` (interactive.session.thread_name).

sessions.py builds interactive sessions with session_command() (K5): the agent's interactive.session, its per-session
hooks (Claude: a --settings file; Codex: -c notify and hooks.*) and the blurt MCP server when it isn't installed.

The registry is agents.json next to this file (also bundled into Blurt.app, which implements the same rules in
Agents.swift). Config ($BLURT_HOME/config.json → record): agents = ["claude", "codex", …] (order; agents not listed are
not used), agent_defs = {"<id>": {…same fields as agents.json…}} to add or override one. With --repo, the repo's
.blurt/config.json record.agents / record.process win over the global ones — never its agent_defs: a definition is a
command line Blurt runs, and a project's .blurt/ is writable by the sandboxed organizing run (writable_dirs).

Probes (status / detect) run with the agent-session variables of whoever called us removed (CLAUDECODE,
CLAUDE_CODE_*, CODEX_*… — like the app's agentEnvironment()), so a call from inside Claude Code reports what the
app will see.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from _common import global_config  # noqa: E402

REGISTRY = Path(__file__).with_name("agents.json")
ANSI = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]")
ERRORISH = re.compile(r"error|fail|fatal|exception|denied|invalid|expired|unauthori|limit|not logged|quota|refused|"
                      r"not found|couldn't|could not|unable|错误|失败", re.I)


def registry() -> dict:
    return json.loads(REGISTRY.read_text(encoding="utf-8"))


def definitions(cfg: dict | None = None) -> dict[str, dict]:
    """id → definition, in registry order, with record.agent_defs merged in (new ids go last)."""
    rec = (cfg if cfg is not None else global_config()).get("record", {})
    defs = {d["id"]: d for d in registry()["agents"]}
    for k, v in (rec.get("agent_defs") or {}).items():
        if isinstance(v, dict):
            defs[k] = {**defs.get(k, {}), **v, "id": k}
            defs[k].setdefault("name", k)
            defs[k].setdefault("bins", [k])
    return defs


def agent_order(cfg: dict | None = None) -> list[str]:
    """The order agents are tried in. record.agents if set (unknown ids dropped, duplicates removed); otherwise the
    registry order, with a legacy record.process = "claude" | "codex" moved to the front. App-only agents
    ("headless": false, e.g. zcode) are never in it — same rule as AgentHub.order() in Agents.swift."""
    cfg = cfg if cfg is not None else global_config()
    rec = cfg.get("record", {})
    defs = {k: d for k, d in definitions(cfg).items() if d.get("headless", True) is not False}
    want = rec.get("agents")
    if isinstance(want, str):
        want = [w.strip() for w in want.split(",")]
    if isinstance(want, list) and any(isinstance(w, str) and w in defs for w in want):
        return list(dict.fromkeys(w for w in want if isinstance(w, str) and w in defs))
    order = list(defs)
    legacy = rec.get("process")
    if legacy in defs:
        order.remove(legacy)
        order.insert(0, legacy)
    return order


def parse_status(defn: dict, code: int | None, text: str, env: dict | None = None, home: Path | None = None) -> str:
    """"ready" (verified logged in) | "configured" (has credentials, can't verify) | "logged_out" | "unknown".
    code None = the status command didn't run / timed out."""
    st = defn.get("status") or {}
    low = (text or "").lower()
    key = st.get("json_key")
    if key and "{" in low:
        try:
            obj, _ = json.JSONDecoder().raw_decode(text[text.index("{"):])
            if isinstance(obj, dict) and isinstance(obj.get(key), bool):
                return "ready" if obj[key] else "logged_out"
        except ValueError:
            pass
    home = home or Path.home()
    cj = st.get("creds_json")
    if isinstance(cj, dict) and cj.get("path"):
        f = home / cj["path"][2:] if cj["path"].startswith("~/") else Path(cj["path"])
        try:
            creds = json.loads(f.read_text(encoding="utf-8"))
            if isinstance(creds, dict) and not any(creds.get(k) for k in cj.get("keys", [])):
                return "logged_out"  # e.g. kimi: provider listed, tokens empty → `kimi -p` fails "no credential configured"
        except (OSError, ValueError):
            pass
    if any(s in low for s in st.get("logged_out", [])):
        return "logged_out"
    if code == 0 and any(s in low for s in st.get("ok_if", [])):
        return "ready"
    if st.get("configured_if") and re.search(st["configured_if"], text or "", re.I):
        return "configured"
    env = os.environ if env is None else env
    if any(env.get(k) for k in st.get("env_any", [])):
        return "configured"
    if any((home / f[2:] if f.startswith("~/") else Path(f)).exists() for f in st.get("files_any", [])):
        return "configured"
    if st.get("otherwise") == "logged_out" and (code is not None or "args" not in st):
        return "logged_out"
    return "unknown"


def usable(state: str) -> bool:
    return state in ("ready", "configured", "unknown")


def check(defn: dict, env: dict | None = None, lang: str = "en") -> dict:
    env = dict(os.environ) if env is None else env
    path = next((p for p in (shutil.which(b, path=env.get("PATH")) for b in defn.get("bins", [defn["id"]])) if p), None)
    out = {"id": defn["id"], "name": defn.get("name", defn["id"]), "path": path}
    if not path:
        out.update(state="not_installed", why=("没安装" if lang == "zh" else "not installed"),
                   fix=(defn.get("install") or {}).get(lang, ""))
        return out
    code, text = None, ""
    args = (defn.get("status") or {}).get("args")
    if args:
        try:
            p = subprocess.run([path, *args], capture_output=True, text=True, encoding="utf-8", errors="replace",
                               timeout=15, env=env, stdin=subprocess.DEVNULL)
            code, text = p.returncode, p.stdout + p.stderr
        except (OSError, subprocess.TimeoutExpired):
            pass
    state = parse_status(defn, code, text, env)
    why = {"ready": ("已登录", "logged in"), "configured": ("已配置（无法预先验证）", "configured (can't verify in advance)"),
           "logged_out": ("没登录", "not logged in"), "unknown": ("登录状态未知，会直接试", "login unknown, will try")}[state]
    out.update(state=state, why=why[0] if lang == "zh" else why[1],
               fix=(defn.get("fix") or {}).get(lang, "") if state == "logged_out" else "")
    return out


def _tail_lines(text: str, chars: int = 6000, lines: int = 80) -> str:
    return "\n".join(text[-chars:].splitlines()[-lines:])


def classify(text: str) -> str | None:
    """A failed run's output → the first failure class (agents.json order) found on an error-looking line of the tail,
    else anywhere in the tail. Only the tail: codex logs echo tool output, which can mention "429" or "quota"."""
    tail = _tail_lines(ANSI.sub("", text or ""))
    errorish = "\n".join(ln for ln in tail.splitlines() if ERRORISH.search(ln))
    classes = registry()["failures"]
    for scope in (errorish, tail):
        for c in classes:
            if any(re.search(p, scope, re.I | re.M) for p in c["patterns"]):
                return c["id"]
    return None


def failure_reason(cls: str | None, name: str, fix: str = "", lang: str = "en", code: int | None = None) -> str:
    for c in registry()["failures"]:
        if c["id"] == cls:
            return c["reason"][lang].replace("{name}", name).replace("{fix}", fix or "")
    if lang == "zh":
        return f"{name} 没整理完（退出码 {code}）" if code is not None else f"{name} 没整理完"
    return f"{name} didn't finish (exit {code})" if code is not None else f"{name} didn't finish"


# ------------------------------------------------------------------ WP2: detect / command / install / prompt (C5)
SCRIPTS = Path(__file__).resolve().parent
SKILL_ROOT = SCRIPTS.parent
MCP_SERVER = SCRIPTS / "mcp_server.py"
_SESSION_PREFIXES = ("CLAUDE", "ANTHROPIC_", "CODEX_", "MCP_", "OTEL_")
_SESSION_NAMES = {"AI_AGENT", "BAGGAGE", "USE_LOCAL_OAUTH", "USE_STAGING_OAUTH", "API_TIMEOUT_MS", "DISABLE_AUTOUPDATER",
                  "DISABLE_MICROCOMPACT", "BLURT_APP"}


# Where the user keeps an agent's config — their setting, not a session leak: never dropped.
_USER_CONFIG_VARS = {"CODEX_HOME", "CLAUDE_CONFIG_DIR", "KIMI_CODE_HOME"}


def clean_env(env: dict | None = None) -> dict:
    """This environment minus what an agent session exports to its children (same list as the app's
    isAgentSessionVar and doctor.py), keeping config locations (CODEX_HOME, CLAUDE_CONFIG_DIR). For probes only;
    install() runs with the caller's environment untouched."""
    env = dict(os.environ if env is None else env)
    return {k: v for k, v in env.items()
            if k in _USER_CONFIG_VARS or not (k.startswith(_SESSION_PREFIXES) or k in _SESSION_NAMES)}


def config(repo: str | Path | None = None) -> dict:
    """Global config, with the repo's .blurt/config.json record.agents / process on top. Not its agent_defs: an
    unattended run may write the project's .blurt/ (writable_dirs), and a definition is a command Blurt runs later."""
    cfg = json.loads(json.dumps(global_config()))
    if repo:
        try:
            local = json.loads((Path(repo) / ".blurt" / "config.json").read_text(encoding="utf-8-sig"))
        except (OSError, ValueError):
            local = {}
        lrec = local.get("record") if isinstance(local, dict) and isinstance(local.get("record"), dict) else {}
        rec = cfg.setdefault("record", {})
        for k in ("agents", "process"):
            if k in lrec:
                rec[k] = lrec[k]
    return cfg


def expand(path: str, env: dict | None = None) -> Path:
    """~ and ${VAR:-default} / $VAR."""
    env = os.environ if env is None else env

    def sub(m):
        name, default = m.group(1) or m.group(3), m.group(2)
        return env.get(name) or (default if default is not None else "")
    s = re.sub(r"\$\{(\w+)(?::-([^}]*))?\}|\$(\w+)", sub, path)
    return Path(os.path.expanduser(s))


def sandbox_uv_cache() -> Path:
    """uv's cache for sandboxed runs only. The shared one stays read-only to them: an environment planted there would
    run, unsandboxed, the next time the app calls a script."""
    from _common import blurt_home  # noqa: PLC0415
    return blurt_home() / "sandbox" / "uv-cache"


def sandbox_env() -> dict:
    """What a sandboxed run ("{writable}" in run) needs: its own uv cache (created here — its parent isn't writable
    to the run) and no index writes ($BLURT_HOME isn't writable to it; the app re-indexes what changed)."""
    c = sandbox_uv_cache()
    c.mkdir(parents=True, exist_ok=True)
    return {"UV_CACHE_DIR": str(c), "BLURT_NO_INDEX": "1"}


def writable_dirs() -> list[str]:
    """What an unattended organizing run may write besides its cwd (the session folder) — "{writable}" in run: one
    `--add-dir` each, for codex's workspace-write sandbox: the inbox store and every project's .blurt store that
    exists (ingest files an item straight into the project the agent is sure of; set-frames / patch follow it) and
    its own uv cache. Never $BLURT_HOME (config.json and its agent_defs, the jobs' hook settings, the index) nor the
    shared uv cache: a write there would run outside the sandbox later. Mirrors UnattendedRun.writableDirs (Swift)."""
    import projects  # noqa: PLC0415 — projects imports agents
    import store as st  # noqa: PLC0415
    dirs = [str(st.inbox_root())]
    try:
        dirs += [str(Path(e["path"]) / ".blurt") for e in projects.entries()]
    except Exception:  # noqa: BLE001 — no registry yet: the inbox
        pass
    dirs = [d for d in dirs if Path(d).is_dir()] + [str(sandbox_uv_cache())]  # a moved project's old path: nothing
    return list(dict.fromkeys(dirs))


def _fill(args: list, vals: dict) -> list[str]:
    out = []
    for a in args:
        if a == "{writable}":  # a list, not a string: one --add-dir per folder (writable_dirs)
            for d in vals.get("writable") or []:
                out += ["--add-dir", str(d)]
            continue
        if isinstance(a, str):  # one pass: a "{scripts}" inside the prompt text stays as it is
            a = re.sub(r"\{(\w+)\}", lambda m: str(vals[m.group(1)]) if m.group(1) in vals else m.group(0), a)
        out.append(a)
    return out


def _fill_obj(o, vals: dict):
    if isinstance(o, str):
        return _fill([o], vals)[0]
    if isinstance(o, list):
        return [_fill_obj(x, vals) for x in o]
    if isinstance(o, dict):
        return {k: _fill_obj(v, vals) for k, v in o.items()}
    return o


def find_bin(defn: dict, env: dict | None = None) -> str | None:
    env = os.environ if env is None else env
    return next((p for p in (shutil.which(b, path=env.get("PATH")) for b in defn.get("bins", [defn["id"]])) if p), None)


def app_path(defn: dict) -> str | None:
    key = "macos" if sys.platform == "darwin" else "windows" if os.name == "nt" else "linux"
    p = (defn.get("app") or {}).get(key)
    return str(expand(p)) if p and expand(p).exists() else None


def interactive_kind(defn: dict) -> str | None:
    it = defn.get("interactive") or {}
    return "url" if it.get("url") else "terminal" if "terminal" in it else "copy" if it.get("copy_prompt") else None


def is_headless(defn: dict) -> bool:
    return bool(defn.get("run")) and defn.get("headless", True) is not False


LOGIN = {"ready": "ok", "logged_out": "logged_out", "configured": "unknown", "unknown": "unknown",
         "not_installed": "n/a"}


def version_of(defn: dict, path: str, env: dict) -> str | None:
    args = defn.get("version")
    if not args:
        return None
    try:
        p = subprocess.run([path, *args], capture_output=True, text=True, encoding="utf-8", errors="replace",
                           timeout=10, env=env, stdin=subprocess.DEVNULL)
    except (OSError, subprocess.TimeoutExpired):
        return None
    text = ANSI.sub("", (p.stdout or "") + "\n" + (p.stderr or "")).strip()
    return text.splitlines()[0].strip() if text else None


def detect(ids: list[str] | None = None, login: bool = True, version: bool = True, repo=None, env: dict | None = None,
           lang: str = "en") -> dict:
    """check() for every agent in the configured order (or `ids`), plus installed / version / login / pick.
    pick = the first installed, headless-capable agent that is logged in ("ready"), else the first "configured" /
    "unknown" one, else null."""
    cfg = config(repo)
    defs = definitions(cfg)
    order = agent_order(cfg)
    env = clean_env(env)
    rows = []
    # app-only agents (headless: false) follow the order, so a UI can still offer "copy the prompt" for them
    for i in ids or order + [k for k in defs if k not in order and not is_headless(defs[k])]:
        d = defs.get(i)
        if not d:
            continue
        if login:
            r = check(d, env, lang)
        else:
            path = find_bin(d, env)
            r = {"id": d["id"], "name": d.get("name", d["id"]), "path": path,
                 "state": "unknown" if path else "not_installed", "why": "", "fix": ""}
        if not r["path"] and app_path(d):  # app-only agents (ZCode): installed, nothing to probe
            r.update(path=app_path(d), state="unknown", why="app" if lang == "en" else "应用", fix="")
        r["installed"] = r["state"] != "not_installed"
        r["version"] = version_of(d, r["path"], env) if version and r["installed"] and find_bin(d, env) else None
        r["login"] = LOGIN.get(r["state"], "unknown")
        r["headless"] = is_headless(d)
        r["interactive"] = interactive_kind(d)
        rows.append(r)
    # in the configured order, not the rows' (`ids` may list them in another order, e.g. Settings asks in registry order)
    by_id = {r["id"]: r for r in rows}
    pick = None
    for want in ("ready", "configured", "unknown"):
        pick = next((i for i in order if i in by_id and by_id[i]["state"] == want and by_id[i]["headless"]), None)
        if pick:
            break
    return {"order": order, "pick": pick, "agents": rows}


def _prompt_file(prompt: str, agent: str) -> Path:
    home = Path(os.environ.get("BLURT_HOME") or Path.home() / ".blurt")
    d = home / "prompts"
    d.mkdir(parents=True, exist_ok=True)
    import time
    f = d / f"{time.strftime('%Y%m%d-%H%M%S')}-{agent}-{os.getpid()}.md"
    f.write_text(prompt, encoding="utf-8")
    return f


def command(agent: str, mode: str, prompt: str, repo: str | Path, vars: dict | None = None, events: bool = True,
            cfg: dict | None = None, env: dict | None = None, mcp: bool = True, processing_run: bool = False) -> dict:
    """What to execute for `agent`. headless: argv (absolute bin when found) run in cwd with env added; interactive:
    a url to open, or argv to run in the user's terminal, and/or text to put on the clipboard. processing_run: an
    unattended organising run — the processing model / effort (processing()) and the flags that make the CLI report
    its token usage (out["processing"], out["usage"]: parse its output with parse_usage)."""
    from urllib.parse import quote
    cfg = cfg if cfg is not None else config(repo)
    defs = definitions(cfg)
    d = defs.get(agent)
    if not d:
        raise ValueError(f"unknown agent {agent!r} (known: {', '.join(defs)})")
    repo = str(Path(repo).expanduser().resolve())
    vars = dict(vars or {})
    env_add = {"BLURT_AGENT": agent}
    if vars.get("run_id"):
        env_add["BLURT_RUN_ID"] = str(vars["run_id"])
    bin_ = find_bin(d, clean_env(env)) or (d.get("bins") or [None])[0]
    out = {"id": agent, "mode": mode, "argv": None, "cwd": repo, "env": env_add, "url": None, "events": None,
           "terminal": False, "clipboard": None, "open_app": None, "retry_exit": d.get("retry_exit"), "prompt_file": None}
    if mode == "headless":
        if not is_headless(d) or not bin_:
            raise ValueError(f"{agent} has no headless mode")
        # {scripts}: claude / gemini may run only `uv run <scripts>/<name>.py` — the caller's prompt names that path
        vals = {**vars, "prompt": prompt, "repo": repo, "scripts": str(SCRIPTS)}
        out["scripts"] = str(SCRIPTS)
        if "{writable}" in d["run"]:  # sandboxed: only an organizing run writes the item stores; the rest only cwd
            vals["writable"] = writable_dirs() if processing_run else []
            env_add.update(sandbox_env())
        argv = [bin_, *_fill(d["run"], vals)]
        hm = d.get("headless_mcp") or {}
        if mcp and hm.get("args"):  # the blurt MCP server, usable without approval prompts in an unattended run
            argv += _fill(hm["args"], {**vals, "mcp_server": str(MCP_SERVER), "mcp_server_json": json.dumps(str(MCP_SERVER))})
        if processing_run:
            p = processing(agent, cfg, env)
            argv += p["args"]
            out["processing"] = {"model": p["model"], "effort": p["effort"]}
        ev = d.get("events") or {}
        if events and ev.get("args"):
            argv += _fill(ev["args"], vals)
            out["events"] = ev.get("format")
        elif processing_run and (d.get("usage") or {}).get("args"):
            argv += _fill(d["usage"]["args"], vals)
        if processing_run:
            out["usage"] = (d.get("usage") or {}).get("format") or ("pattern" if (d.get("usage") or {}).get("pattern") else None)
        out["argv"] = argv
        return out
    if mode != "interactive":
        raise ValueError("mode must be headless or interactive")
    it = d.get("interactive") or {}
    if it.get("url"):
        q = prompt
        if it.get("max_prompt") and len(prompt) > it["max_prompt"]:
            f = _prompt_file(prompt, agent)
            out["prompt_file"] = str(f)
            q = f"Read {f} and do what it says."
        vals = {**vars, "repo": repo, "repo_q": quote(repo, safe=""), "prompt_q": quote(q, safe=""), "prompt": q}
        out["url"] = _fill([it["url"]], vals)[0]
    elif "terminal" in it:
        if not bin_:
            raise ValueError(f"{agent} is not installed")
        out["argv"] = [bin_, *_fill(it["terminal"], {**vars, "prompt": prompt, "repo": repo})]
        out["terminal"] = True
        if it.get("paste_prompt"):
            out["clipboard"] = prompt
    elif it.get("copy_prompt"):
        out["clipboard"] = prompt
        out["open_app"] = app_path(d) or (d.get("app") or {}).get("macos")
    else:
        raise ValueError(f"{agent} has no interactive mode")
    return out


# ------------------------------------------------------------------ v0.7: models, the processing model, token usage
EFFORTS = ("low", "medium", "high", "xhigh", "max")
_CHEAP = re.compile(r"\b(affordable|cheap|cheapest|fast|efficient|mini|nano|small|lite|flash|haiku)\b", re.I)


def _toml_top(path: Path, key: str) -> str | None:
    """A top-level string setting of a TOML file (before the first [table]) — enough for `model = "…"`."""
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        return None
    for ln in text.splitlines():
        s = ln.strip()
        if s.startswith("["):
            break
        m = re.match(rf'{re.escape(key)}\s*=\s*"([^"]*)"', s)
        if m:
            return m.group(1)
    return None


def models(agent: str, cfg: dict | None = None, env: dict | None = None) -> dict:
    """The models an agent's CLI offers, best first: a fixed list in agents.json (Claude Code's aliases) or the CLI's
    own model cache (Codex: models_cache.json, models it shows in its picker). cli_default = the model the CLI uses
    when none is passed (its config), when it can be read. Spends nothing: no network, no agent run.
    → {"id", "models": [{id, name, description, cheap}], "cheapest": id|None, "cli_default", "efforts": [...]}"""
    d = definitions(cfg if cfg is not None else config()).get(agent)
    if not d:
        raise ValueError(f"unknown agent {agent!r}")
    spec = d.get("models") or {}
    env = os.environ if env is None else env
    rows: list[dict] = []
    if isinstance(spec.get("list"), list):
        for m in spec["list"]:
            if isinstance(m, dict) and m.get("id"):
                rows.append({"id": m["id"], "name": m.get("name") or m["id"], "description": m.get("description") or "",
                             "cheap": bool(m.get("cheap"))})
    elif spec.get("cache"):
        try:
            raw = json.loads(expand(spec["cache"], env).read_text(encoding="utf-8"))
        except (OSError, ValueError):
            raw = {}
        listed = [m for m in (raw.get("models") if isinstance(raw, dict) else None) or []
                  if isinstance(m, dict) and m.get("slug") and m.get("visibility", "list") == "list"]
        listed.sort(key=lambda m: m.get("priority") if isinstance(m.get("priority"), (int, float)) else 999)
        for m in listed:
            desc = str(m.get("description") or "")
            rows.append({"id": m["slug"], "name": m.get("display_name") or m["slug"], "description": desc,
                         "cheap": bool(_CHEAP.search(desc))})
    cli_default = _toml_top(expand(spec["config"], env), "model") if spec.get("config") else None
    efforts = list(EFFORTS) if (d.get("model_args") or {}).get("effort") else []
    return {"id": agent, "models": rows, "cheapest": next((m["id"] for m in rows if m["cheap"]), None),
            "cli_default": cli_default, "efforts": efforts}


def model_args(defn: dict, model: str | None = None, effort: str | None = None) -> list[str]:
    """argv that make the agent's CLI use `model` / `effort` (nothing for what it can't take)."""
    ma = defn.get("model_args") or {}
    out: list[str] = []
    if model and ma.get("model"):
        out += _fill(ma["model"], {"model": model})
    if effort in EFFORTS and ma.get("effort"):
        out += _fill(ma["effort"], {"effort": effort})
    return out


def processing(agent: str, cfg: dict | None = None, env: dict | None = None) -> dict:
    """The model and effort an unattended organising run (整理, AI sort, AI fill-in, recordings) uses: config
    record.agent_processing.<id> = {model, effort} over agents.json `processing`. model "cheapest" = the cheap one
    from models() (none known → the CLI's default), "default" = the CLI's own setting.
    → {"model": id|None, "effort": level|None, "args": [...]}"""
    cfg = cfg if cfg is not None else config()
    d = definitions(cfg).get(agent)
    if not d:
        raise ValueError(f"unknown agent {agent!r}")
    base = d.get("processing") if isinstance(d.get("processing"), dict) else {}
    over = ((cfg.get("record") or {}).get("agent_processing") or {}).get(agent)
    over = over if isinstance(over, dict) else {}
    want_model = over.get("model", base.get("model"))
    want_effort = over.get("effort", base.get("effort"))
    model = None
    if isinstance(want_model, str) and want_model and want_model != "default":
        model = models(agent, cfg, env)["cheapest"] if want_model == "cheapest" else want_model
    effort = want_effort if want_effort in EFFORTS else None
    return {"model": model, "effort": effort, "args": model_args(d, model, effort)}


def _usage_of(obj) -> dict | None:
    """{"tokens", "input", "output"} from a CLI's JSON usage object (Claude: input + cache + output; Codex:
    input (cached included) + output)."""
    u = obj.get("usage") if isinstance(obj, dict) else None
    if not isinstance(u, dict):
        return None
    def n(k):
        v = u.get(k)
        return int(v) if isinstance(v, (int, float)) and not isinstance(v, bool) else 0
    inp = n("input_tokens") + n("cache_creation_input_tokens") + n("cache_read_input_tokens")
    out = n("output_tokens")
    return {"tokens": inp + out, "input": inp, "output": out} if inp + out else None


def parse_usage(defn: dict, text: str) -> dict | None:
    """The tokens a run reported in its output (the last report wins): agents.json usage.pattern (Codex's
    "tokens used 24,953"), else a JSON result line with a usage object (Claude's --output-format json /
    stream-json, Codex --json turn.completed)."""
    text = ANSI.sub("", text or "")
    pat = (defn.get("usage") or {}).get("pattern")
    if pat:
        hits = re.findall(pat, text)
        if hits:
            digits = re.sub(r"[^0-9]", "", hits[-1] if isinstance(hits[-1], str) else hits[-1][0])
            if digits:
                return {"tokens": int(digits)}
    total = None
    turns = 0
    for ln in text.splitlines():
        s = ln.strip()
        if not (s.startswith("{") and '"usage"' in s):
            continue
        try:
            o = json.loads(s)
        except ValueError:
            continue
        u = _usage_of(o)
        if not u:
            continue
        if o.get("type") == "result":  # Claude: the whole run
            total = u
        elif o.get("type") == "turn.completed":  # Codex --json: per turn
            turns += 1
            total = u if turns == 1 or total is None else {k: total[k] + u[k] for k in u}
    return total


def _run(argv: list[str], env: dict, timeout: int = 60) -> tuple[int | None, str]:
    try:
        p = subprocess.run(argv, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=timeout,
                           env=env, stdin=subprocess.DEVNULL)
        return p.returncode, ((p.stdout or "") + (p.stderr or "")).strip()
    except (OSError, subprocess.TimeoutExpired) as e:
        return None, str(e)


def install(agent: str, skill: bool = True, mcp: bool = True, dry_run: bool = False, env: dict | None = None,
            cfg: dict | None = None) -> dict:
    """Link the skill into the agent's skill dir and register the blurt MCP server with it. Never overwrites a
    different skill already there; with dry_run nothing is touched (the `check` probe of an argv mcp still runs)."""
    defs = definitions(cfg if cfg is not None else config())
    d = defs.get(agent)
    if not d:
        raise ValueError(f"unknown agent {agent!r}")
    env = dict(os.environ if env is None else env)  # CODEX_HOME & co. decide which config gets written
    vals = {"mcp_server": str(MCP_SERVER), "skill": str(SKILL_ROOT)}
    changes, ok = [], True
    if skill:
        if not d.get("skill_dir"):
            changes.append({"action": "manual", "what": "skill", "how": (d.get("fix") or {}).get("en", "")})
        else:
            target = expand(d["skill_dir"], env) / "blurt"
            if target.is_symlink() or target.exists():
                same = target.resolve() == SKILL_ROOT.resolve()
                changes.append({"action": "exists" if same else "conflict", "path": str(target),
                                "points_to": str(target.resolve())})
                ok = ok and same
            else:
                ch = {"action": "symlink", "path": str(target), "target": str(SKILL_ROOT)}
                if not dry_run:
                    try:
                        target.parent.mkdir(parents=True, exist_ok=True)
                        target.symlink_to(SKILL_ROOT, target_is_directory=True)
                        ch["ok"] = True
                    except OSError as e:
                        ch.update(ok=False, error=str(e))
                        ok = False
                changes.append(ch)
    if mcp:
        m = d.get("mcp") or {}
        bin_ = find_bin(d, env)
        if m.get("args"):
            argv = [bin_ or d["bins"][0], *_fill(m["args"], vals)]
            exists = False
            if m.get("check") and bin_:
                code, _ = _run([bin_, *m["check"]], env, timeout=20)
                exists = code == 0
            if exists:
                changes.append({"action": "exists", "argv": [bin_, *m["check"]]})
            else:
                ch = {"action": "run", "argv": argv}
                if not bin_:
                    ch.update(ok=False, error=f"{agent} is not installed")
                    ok = False
                elif not dry_run:
                    code, text = _run(argv, env)
                    ch.update(ok=code == 0, exit=code, output=text[-2000:])
                    ok = ok and code == 0
                changes.append(ch)
        elif m.get("json"):
            spec = m["json"]
            path = expand(spec["path"], env)
            value = _fill_obj(spec["value"], vals)
            try:
                data = json.loads(path.read_text(encoding="utf-8-sig")) if path.exists() else {}
            except ValueError as e:
                data = None
                changes.append({"action": "error", "path": str(path), "error": f"not plain JSON ({e}); add by hand",
                                "key": spec["key"], "value": value})
                ok = False
            if data is not None:
                node = data
                for k in spec["key"][:-1]:
                    node = node.setdefault(k, {}) if isinstance(node, dict) else None
                    if node is None:
                        break
                if isinstance(node, dict) and node.get(spec["key"][-1]) == value:
                    changes.append({"action": "exists", "path": str(path), "key": spec["key"]})
                elif isinstance(node, dict):
                    ch = {"action": "json_merge", "path": str(path), "key": spec["key"], "value": value}
                    if not dry_run:
                        node[spec["key"][-1]] = value
                        path.parent.mkdir(parents=True, exist_ok=True)
                        tmp = path.with_name(path.name + f".{os.getpid()}.tmp")
                        tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
                        os.replace(tmp, path)
                        ch["ok"] = True
                    changes.append(ch)
                else:
                    changes.append({"action": "error", "path": str(path), "error": "unexpected structure"})
                    ok = False
        else:
            changes.append({"action": "manual", "what": "mcp", "how": (d.get("fix") or {}).get("en", ""),
                            "command": ["uv", "run", "--script", str(MCP_SERVER)]})
    return {"changes": changes, "applied": (not dry_run) and ok}


# ------------------------------------------------------------------ K5: interactive sessions (sessions.py dispatch)
SESSIONS_PY = SCRIPTS / "sessions.py"
CLAUDE_HOOKS = ("SessionStart", "UserPromptSubmit", "PostToolUse", "Notification", "Stop", "SessionEnd")
CODEX_HOOKS = ("SessionStart", "UserPromptSubmit", "PostToolUse", "PermissionRequest", "Stop", "SessionEnd")


def session_spec(defn: dict) -> dict | None:
    """interactive.session of an agent: how it runs as an interactive session in a tmux window / the app's pty."""
    sp = (defn.get("interactive") or {}).get("session")
    return sp if isinstance(sp, dict) else None


def waiting_patterns(defn: dict) -> list[str]:
    return [p for p in (defn.get("interactive") or {}).get("waiting_patterns") or [] if isinstance(p, str)]


def error_patterns(defn: dict) -> list[str]:
    """interactive.error_patterns: what an interactive agent draws when it can't work at all (Claude Code's "Not
    logged in · Please run /login") while it stays open — read from the terminal until its hooks report."""
    return [p for p in (defn.get("interactive") or {}).get("error_patterns") or [] if isinstance(p, str)]


def _q(s: str) -> str:
    """Quote a path for the shell an agent runs its hook commands with."""
    if os.name == "nt":
        return '"' + s.replace('"', '\\"') + '"'
    return "'" + s.replace("'", "'\\''") + "'"


def hook_python() -> str:
    """The interpreter hooks run with: this one, minus any venv (`uv run --script` puts scripts in a cache env that
    can disappear; hooks only need the standard library)."""
    base = getattr(sys, "_base_executable", None)
    return base if base and os.path.exists(base) else sys.executable


def hook_command(agent: str, job: str | None, python: str | None = None) -> str:
    """The shell command an agent's hooks run. job None = take it from $BLURT_JOB (Codex: its hooks need the
    user's trust once per distinct command, so the command must not change from one session to the next)."""
    cmd = f"{_q(python or hook_python())} {_q(str(SESSIONS_PY))} hook"
    if job:
        cmd += f" --job {job}"
    return cmd + f" --agent {agent}"


def claude_settings(job: str, python: str | None = None) -> dict:
    """The --settings file of one Claude Code session: hooks only (--settings adds to the user's settings)."""
    h = {"type": "command", "command": hook_command("claude", job, python), "timeout": 5}
    return {"hooks": {ev: [{"matcher": "*", "hooks": [h]}] if ev == "PostToolUse" else [{"hooks": [h]}]
                      for ev in CLAUDE_HOOKS}}


def _toml_str(s: str) -> str:
    return json.dumps(s, ensure_ascii=False)


def codex_hook_args(job: str, python: str | None = None, hooks: bool = True) -> list[str]:
    """-c overrides for one Codex session: notify (turn finished; carries the job id) and, when `hooks`, the
    lifecycle hooks (job from $BLURT_JOB, so the command stays the same and the user trusts it once)."""
    py = python or hook_python()
    notify = [py, str(SESSIONS_PY), "hook", "--job", job, "--agent", "codex"]
    out = ["-c", "notify=[" + ", ".join(_toml_str(x) for x in notify) + "]"]
    if hooks:
        cmd = _toml_str(hook_command("codex", None, py))
        for ev in CODEX_HOOKS:
            out += ["-c", f"hooks.{ev}=[{{hooks=[{{type=\"command\", command={cmd}, timeout=5}}]}}]"]
    return out


def mcp_installed(defn: dict, env: dict | None = None) -> bool | None:
    """Is the blurt MCP server registered with this agent? None = can't tell (no check command)."""
    m = defn.get("mcp") or {}
    bin_ = find_bin(defn, clean_env(env))
    if not m.get("check") or not bin_:
        return None
    code, _ = _run([bin_, *m["check"]], clean_env(env), timeout=20)
    return code == 0


def session_command(agent: str, prompt: str, cwd: str | Path, *, job: str, settings: Path | None = None,
                    python: str | None = None, mcp: bool | None = None, cfg: dict | None = None,
                    env: dict | None = None, model: str | None = None) -> dict:
    """argv for an interactive session of `agent` (K5). settings = where the Claude --settings file goes (written
    here); mcp None = add the blurt MCP server only when the user hasn't installed it; model = the model the user
    picked in the dispatch panel (None / "default" = the CLI's own setting).
    → {"argv", "paste": prompt to paste once it's up | None, "hooks": "claude"|"codex"|None, "patterns": [...]}"""
    defs = definitions(cfg if cfg is not None else config(cwd))
    d = defs.get(agent)
    if not d:
        raise ValueError(f"unknown agent {agent!r} (known: {', '.join(defs)})")
    sp = session_spec(d)
    if sp is None:
        raise ValueError(f"{agent} has no interactive session")
    bin_ = find_bin(d, clean_env(env))
    if not bin_:
        raise ValueError(f"{agent} is not installed")
    paste = sp.get("prompt") == "paste"
    argv = [bin_]
    hooks = sp.get("hooks")
    if hooks == "claude":
        if settings is None:
            raise ValueError("a Claude session needs its settings file path")
        settings.write_text(json.dumps(claude_settings(job, python), ensure_ascii=False, indent=1) + "\n",
                            encoding="utf-8")
        argv += ["--settings", str(settings)]
    elif hooks == "codex":
        argv += codex_hook_args(job, python, hooks=sp.get("lifecycle_hooks", True) is not False)
    want_mcp = (mcp_installed(d, env) is False) if mcp is None else mcp
    if want_mcp and sp.get("mcp"):
        mv = {"mcp_server": str(MCP_SERVER), "mcp_server_json": json.dumps(str(MCP_SERVER)),
              "mcp_config_json": json.dumps({"mcpServers": {"blurt": {
                  "type": "stdio", "command": "uv", "args": ["run", "-q", "--script", str(MCP_SERVER)]}}})}
        margs = (d.get("headless_mcp") or {}).get("args", []) if sp["mcp"] == "headless_mcp" else sp["mcp"]
        argv += _fill(margs, mv)
    if model and model != "default":
        if not (d.get("model_args") or {}).get("model"):
            raise ValueError(f"{agent} can't be given a model")
        argv += model_args(d, model)
    argv += _fill(sp.get("argv", []), {"prompt": prompt, "repo": str(cwd)})
    return {"argv": argv, "paste": prompt if paste else None, "hooks": hooks, "patterns": waiting_patterns(d)}


WORK_PROMPT = {
    "en": "{title}\n\nRead {note} and handle the items in it. {rule} When you finish an item, call the blurt MCP tool "
          "mark_fixed with its uid (or, without the MCP, run the items.py command the note gives).",
    "zh": "{title}\n\n读 {note}，处理里面的条目。{rule}每做完一条，用它的 uid 调用 blurt MCP 工具 mark_fixed（没有 MCP 就运行交接单里给的 "
          "items.py 命令）。",
}
# The desktop app's prompt carries the note itself: the app starts in the worktree and would have to ask before it
# reads a file outside it. Progress comes only from the agent there (no hooks), so it says when it starts an item too.
# The commit rule is in the note itself (inlined below), and so is the fallback without the MCP: only the note's own
# mark_fixed line is left out (DESKTOP_PROMPT says it, with the start call too). Every char counts: the whole prompt
# rides in the claude:// link, and Chinese text percent-encodes to about nine chars a glyph.
DESKTOP_PROMPT = {
    "en": "{title}\n\nHandle the items below (the same note is saved at {note}). When you start an item, call the blurt "
          "MCP tool mark_fixed with its uid and state \"fixing\"; when you finish it, mark_fixed with state \"fixed\" "
          "(or \"wontfix\") and a short note. Blurt shows the user only what you report this way.\n\n{body}",
    "zh": "{title}\n\n处理下面的条目（同一份交接单也存在 {note}）。开始做某一条时，用它的 uid 调用 blurt MCP 工具 mark_fixed，"
          "state 填 \"fixing\"；做完后再调用 mark_fixed，state 填 \"fixed\"（或 \"wontfix\"），附一句说明。口喷鸡只能通过这些报告"
          "告诉用户进度。\n\n{body}",
}
TITLE = {"en": {"one": "{id} · {title} (Blurt hand-off)", "id_only": "{id} (Blurt hand-off)",
                "many": "{n} items · {project} (Blurt hand-off)", "bare": "{n} items (Blurt hand-off)"},
         "zh": {"one": "{id} · {title}（口喷鸡交接）", "id_only": "{id}（口喷鸡交接）",
                "many": "{n} 个条目 · {project}（口喷鸡交接）", "bare": "{n} 个条目（口喷鸡交接）"}}
TITLE_MAX = 120


def _one_line(s) -> str:
    return " ".join(str(s or "").split())


def work_title(items: list[dict], project: str | None, lang: str = "en") -> str:
    """The first line of a hand-off prompt, and the name its Codex thread gets: "AW-12 · Login button does nothing
    (Blurt hand-off)"; several items: "3 items · Atlas Web (Blurt hand-off)". One line of at most TITLE_MAX chars:
    a long item title is cut, never the id or the suffix."""
    t = TITLE["zh" if (lang or "").startswith("zh") else "en"]
    if len(items) == 1:
        it = items[0]
        ref = _one_line(it.get("id") or (it.get("uid") or "")[:8])
        title = _one_line(it.get("title")) or _one_line(it.get("summary"))
        if not title:
            return t["id_only"].format(id=ref)
        room = TITLE_MAX - len(t["one"].format(id=ref, title=""))
        if len(title) > room:
            title = title[:max(8, room - 1)].rstrip() + "…"
        return t["one"].format(id=ref, title=title)
    name = _one_line(project)
    return (t["many"].format(n=len(items), project=name) if name else t["bare"].format(n=len(items)))[:TITLE_MAX]


def _project_name(items: list[dict]) -> str | None:
    import handoff
    pids = {it.get("project") for it in items}
    if len(pids) != 1:
        return None
    try:
        p = handoff.project(next(iter(pids)))
    except handoff.CliError:
        return None
    return (p or {}).get("name")


def prompt_work(refs: list[str], mode: str = "session", worktree: bool = False, handoff_id: str | None = None,
                lang: str | None = None, branch: str | None = None, items: list[dict] | None = None,
                sandboxed: bool = False, project_name: str | None = None) -> dict:
    """The short prompt that starts an agent on some items: a title line first (work_title: what the agent's own
    session list shows), then a pointer at their hand-off note (K6), written here unless handoff_id names one
    already. sandboxed = the agent can't commit in a worktree (interactive.session `sandboxed`): it leaves its
    changes for Blurt to commit (handoff.rule_text). project_name None = looked up from the items' project."""
    import handoff
    lang = handoff.ui_lang(lang)
    if handoff_id:
        h = handoff.describe(handoff_id)
    else:
        h = handoff.create(refs, lang, to=mode, branch=branch, worktree=worktree, items=items, sandboxed=sandboxed)
    its = list(items) if items is not None else []
    if not its:
        for u in h["items"]:
            try:
                its.append(handoff.item(u))
            except handoff.CliError:
                its.append({"uid": u})
    title = work_title(its, project_name if project_name is not None else _project_name(its), lang)
    t = handoff.T[lang]
    rule = handoff.rule_text(t, mode, worktree, branch, sandboxed)
    return {"prompt": WORK_PROMPT[lang].format(title=title, note=h["path"], rule=rule), "title": title,
            "handoff": h["id"], "path": h["path"], "items": h["items"], "full": h.get("full") or "", "rule": rule,
            "lang": lang}


# ------------------------------------------------------------------ the agent's desktop app (interactive.desktop)
def desktop_spec(defn: dict) -> dict | None:
    d = (defn.get("interactive") or {}).get("desktop")
    return d if isinstance(d, dict) and d.get("url") else None


def desktop_url(spec: dict, folder: str, prompt: str) -> str:
    """claude://code/new?folder=…&q=…: the app opens a new conversation in `folder` with the prompt filled in (the
    user confirms the folder and presses Send). Both values fully percent-encoded."""
    from urllib.parse import quote
    return spec["url"].replace("{folder_q}", quote(str(folder), safe="")).replace("{prompt_q}", quote(prompt, safe=""))


def desktop_prompt(work: dict, spec: dict, folder: str) -> dict:
    """The prompt and URL for the desktop app (`work` = prompt_work's answer): the note inline while the URL stays
    within spec max_url (about 14k chars), else the short prompt pointing at the note. → {"prompt", "url", "inline"}"""
    import handoff
    lang = work.get("lang") or "en"
    body = (work.get("full") or "").strip()
    own = (handoff.T.get(lang) or handoff.T["en"])["mcp"]  # the note's own mark_fixed line: said above, with more
    body = "\n".join(ln for ln in body.split("\n") if ln.strip() != own)
    limit = int(spec.get("max_url") or 14000)
    if body:
        full = DESKTOP_PROMPT[lang].format(title=work["title"], note=work["path"], body=body)
        url = desktop_url(spec, folder, full)
        if len(url) <= limit:
            return {"prompt": full, "url": url, "inline": True}
    return {"prompt": work["prompt"], "url": desktop_url(spec, folder, work["prompt"]), "inline": False}


def version_tuple(v: str | None) -> tuple[int, ...] | None:
    """"2.1.285 (Claude Code)" → (2, 1, 285); None when there is no dotted number."""
    m = re.search(r"(\d+)\.(\d+)(?:\.(\d+))?", v or "")
    return tuple(int(x) for x in m.groups() if x is not None) if m else None


def subscription_login(text: str, auth: dict) -> bool | None:
    """Does the auth probe's JSON say logged in with a subscription (not an API key)? None = nothing readable."""
    if "{" not in (text or ""):
        return None
    try:
        obj, _ = json.JSONDecoder().raw_decode(text[text.index("{"):])
    except ValueError:
        return None
    if not isinstance(obj, dict):
        return None
    if obj.get(auth.get("json_key") or "loggedIn") is not True:
        return False
    if any(str(obj.get(k) or "").strip().lower() not in ("", "none", "null")
           for k in auth.get("subscription_keys", [])):
        return True
    return str(obj.get("authMethod") or "").strip().lower() in {str(m).lower() for m in auth.get("auth_methods", [])}


def desktop_continue_check(agent: str, cfg: dict | None = None, env: dict | None = None) -> dict:
    """Can a running terminal session of `agent` move to its desktop app (claude --desktop --resume <id>)? Only from
    interactive.desktop.continue.min_version, and when its status probe says logged in with a subscription. Probes
    only (--version, auth status): never logs in, upgrades or starts anything.
    "mcp": is the blurt MCP installed for the agent (mcp_installed; asked only when available)? A terminal session may
    have had it through --mcp-config, which the desktop app doesn't get: without it nothing reports progress there.
    → {"available": bool, "reason": None | "unsupported" | "not_installed" | "version" | "login", "version", "mcp"}"""
    d = definitions(cfg if cfg is not None else config()).get(agent) or {}
    cont = (desktop_spec(d) or {}).get("continue")
    if not isinstance(cont, dict) or not cont.get("argv"):
        return {"available": False, "reason": "unsupported", "version": None, "mcp": None}
    env = clean_env(env)
    bin_ = find_bin(d, env)
    if not bin_:
        return {"available": False, "reason": "not_installed", "version": None, "mcp": None}
    v = version_of(d, bin_, env)
    have, need = version_tuple(v), version_tuple(cont.get("min_version"))
    if need and (have is None or have < need):
        return {"available": False, "reason": "version", "version": v, "mcp": None}
    args = (d.get("status") or {}).get("args")
    ok = False
    if args:
        code, out = _run([bin_, *args], env, timeout=15)
        ok = code == 0 and subscription_login(out, cont.get("auth") or {}) is True
    if not ok:
        return {"available": False, "reason": "login", "version": v, "mcp": None}
    return {"available": True, "reason": None, "version": v, "mcp": mcp_installed(d, env)}


# ------------------------------------------------------------------ thread names (interactive.session.thread_name)
class RpcError(Exception):
    pass


def rpc_exchange(argv: list[str], calls: list[tuple[str, dict | None]], env: dict, timeout: float = 20,
                 client: dict | None = None) -> list:
    """JSON-RPC over stdio, one JSON object per line in Codex app-server's dialect (no "jsonrpc" field): initialize →
    initialized → each (method, params) in turn, waiting for its answer. → the results, in order. The server's own
    notifications and requests are skipped. RpcError on an error answer, a timeout, or the server ending first; the
    server is always stopped (stdin closed, then terminated)."""
    import queue
    import threading
    try:
        proc = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                env=env, text=True, encoding="utf-8", errors="replace", bufsize=1)
    except OSError as e:
        raise RpcError(f"can't start {argv[0]}: {e}") from None
    lines: queue.Queue = queue.Queue()

    def pump():
        for ln in proc.stdout:  # type: ignore[union-attr]
            lines.put(ln)
        lines.put(None)
    threading.Thread(target=pump, daemon=True).start()
    import time as _time
    deadline = _time.monotonic() + timeout

    def send(obj: dict) -> None:
        try:
            proc.stdin.write(json.dumps(obj, ensure_ascii=False) + "\n")  # type: ignore[union-attr]
            proc.stdin.flush()  # type: ignore[union-attr]
        except (OSError, ValueError) as e:
            raise RpcError(f"the server stopped reading: {e}") from None

    def answer(want: int):
        while True:
            left = deadline - _time.monotonic()
            if left <= 0:
                raise RpcError("timed out")
            try:
                ln = lines.get(timeout=left)
            except queue.Empty:
                raise RpcError("timed out") from None
            if ln is None:
                raise RpcError("the server exited")
            try:
                msg = json.loads(ln)
            except ValueError:
                continue
            if not isinstance(msg, dict) or "method" in msg or msg.get("id") != want:
                continue
            if msg.get("error") is not None:
                e = msg["error"]
                raise RpcError(str(e.get("message") if isinstance(e, dict) else e)[:300])
            return msg.get("result")
    try:
        send({"method": "initialize", "id": 0,
              "params": {"clientInfo": client or {"name": "blurt", "title": "Blurt", "version": "1"}}})
        answer(0)
        send({"method": "initialized"})
        out = []
        for i, (method, params) in enumerate(calls, 1):
            send({"method": method, "id": i, "params": params or {}})
            out.append(answer(i))
        return out
    finally:
        try:
            proc.stdin.close()  # type: ignore[union-attr]
        except OSError:
            pass
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            proc.terminate()
            try:
                proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                proc.kill()


def set_thread_name(agent: str, thread_id: str, name: str, cfg: dict | None = None, env: dict | None = None,
                    timeout: float = 20) -> dict:
    """Name an agent's thread officially (interactive.session.thread_name — Codex: `codex app-server`,
    thread/name/set {threadId, name}), with the CODEX_HOME of `env`: the session's own. → {"ok", "error"?}; never
    raises."""
    d = definitions(cfg if cfg is not None else config()).get(agent) or {}
    spec = (session_spec(d) or {}).get("thread_name")
    if not isinstance(spec, dict) or not spec.get("argv") or not spec.get("method"):
        return {"ok": False, "error": "unsupported"}
    env = clean_env(env)
    bin_ = find_bin(d, env)
    if not bin_:
        return {"ok": False, "error": "not installed"}
    try:
        rpc_exchange([bin_, *spec["argv"]], [(spec["method"], {"threadId": thread_id, "name": name})], env, timeout)
    except RpcError as e:
        return {"ok": False, "error": str(e)}
    return {"ok": True}


def _emit(obj) -> None:
    print(json.dumps(obj, ensure_ascii=False), flush=True)


def _fail(msg: str) -> None:
    _emit({"ok": False, "error": msg})
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    lang = "zh" if os.environ.get("LANG", "").startswith("zh") else "en"
    s = sub.add_parser("status")
    s.add_argument("--json", action="store_true")
    s.add_argument("--lang", default=lang)
    s = sub.add_parser("order")
    s.add_argument("--json", action="store_true")
    s.add_argument("--repo")
    c = sub.add_parser("classify")
    c.add_argument("file")
    s = sub.add_parser("detect")
    s.add_argument("--repo")
    s.add_argument("--ids", help="comma-separated; default = the configured order")
    s.add_argument("--no-login", action="store_true", help="don't run the login probes (fast)")
    s.add_argument("--no-version", action="store_true")
    s.add_argument("--json", action="store_true", help="(default; accepted for symmetry with status)")
    s.add_argument("--lang", default=lang)
    s = sub.add_parser("command")
    s.add_argument("id")
    s.add_argument("mode", choices=["headless", "interactive"])
    g = s.add_mutually_exclusive_group(required=True)
    g.add_argument("--prompt")
    g.add_argument("--prompt-file")
    s.add_argument("--repo", required=True)
    s.add_argument("--var", action="append", default=[], metavar="K=V", help="placeholder values; run_id → $BLURT_RUN_ID")
    s.add_argument("--no-events", action="store_true", help="plain output instead of the stream-json flags")
    s.add_argument("--no-mcp", action="store_true", help="leave out the headless_mcp args (blurt MCP server)")
    s.add_argument("--processing", action="store_true", help="an unattended organising run: processing model + usage")
    s = sub.add_parser("models")
    s.add_argument("id")
    s = sub.add_parser("usage")
    s.add_argument("id")
    s.add_argument("file")
    s.add_argument("--offset", type=int, default=0)
    s = sub.add_parser("install")
    s.add_argument("id")
    s.add_argument("--skill", action="store_true")
    s.add_argument("--mcp", action="store_true")
    s.add_argument("--dry-run", action="store_true")
    s = sub.add_parser("prompt")
    s.add_argument("kind", choices=["work"])
    s.add_argument("--items", nargs="+", required=True, metavar="REF")
    s.add_argument("--mode", choices=["session", "external"], default="session")
    s.add_argument("--worktree", choices=["on", "off"], default="off")
    s.add_argument("--branch")
    s.add_argument("--handoff", help="an existing hand-off note (H-0012) instead of writing one")
    s.add_argument("--lang", choices=["en", "zh", "zh-Hans"])
    a = p.parse_args()
    try:
        if a.cmd == "detect":
            _emit(detect(a.ids.split(",") if a.ids else None, login=not a.no_login, version=not a.no_version,
                         repo=a.repo, lang=a.lang))
            return
        if a.cmd == "command":
            prompt = a.prompt if a.prompt is not None else Path(a.prompt_file).read_text(encoding="utf-8")
            vars = dict(kv.partition("=")[::2] for kv in a.var)
            _emit(command(a.id, a.mode, prompt, a.repo, vars, events=not a.no_events, mcp=not a.no_mcp,
                          processing_run=a.processing))
            return
        if a.cmd == "models":
            cfg = config()
            p = processing(a.id, cfg)
            _emit({"ok": True, **models(a.id, cfg), "processing": {"model": p["model"], "effort": p["effort"]}})
            return
        if a.cmd == "usage":
            d = definitions(config()).get(a.id)
            if not d:
                raise ValueError(f"unknown agent {a.id!r}")
            with open(a.file, "rb") as f:
                f.seek(max(0, a.offset))
                text = f.read().decode("utf-8", errors="replace")
            _emit({"ok": True, "usage": parse_usage(d, text)})
            return
        if a.cmd == "install":
            both = not a.skill and not a.mcp
            _emit(install(a.id, skill=a.skill or both, mcp=a.mcp or both, dry_run=a.dry_run))
            return
        if a.cmd == "prompt":
            pw = prompt_work(a.items, a.mode, a.worktree == "on", a.handoff, a.lang, a.branch)
            _emit({"ok": True, **{k: pw[k] for k in ("prompt", "title", "handoff", "path", "items")}})
            return
    except ValueError as e:
        _fail(str(e))
    except Exception as e:  # noqa: BLE001 — handoff.CliError / jobs.JobError carry a machine code
        if not hasattr(e, "code"):
            raise
        _emit({"ok": False, "error": str(e), "code": e.code})
        print(f"ERROR: {e}", file=sys.stderr)
        sys.exit(1)
    if a.cmd == "order":
        order = agent_order(config(a.repo))
        print(json.dumps({"order": order}) if a.json else "\n".join(order))
    elif a.cmd == "classify":
        text = Path(a.file).read_text(encoding="utf-8", errors="replace")
        cls = classify(text)
        print(json.dumps({"class": cls, "reason": failure_reason(cls, "the agent")}, ensure_ascii=False))
    else:
        defs = definitions()
        rows = [check(defs[i], lang=a.lang) for i in agent_order()]
        if a.json:
            print(json.dumps(rows, ensure_ascii=False, indent=2))
        else:
            for r in rows:
                print(f"{'✓' if usable(r['state']) and r['state'] != 'not_installed' else '✗'} {r['name']:<12} {r['why']}"
                      + (f" — {r['fix']}" if r.get("fix") else ""))


if __name__ == "__main__":
    main()
