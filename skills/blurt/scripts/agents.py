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
                   [--no-mcp]
                                   → {"id","mode","argv","cwd","env","url","events","terminal","clipboard","open_app",
                                      "retry_exit","prompt_file"}
  agents.py install ID [--skill] [--mcp] [--dry-run]   → {"changes": [{action, path|argv, …}], "applied": bool}
  agents.py prompt work --items REF … [--mode session|external] [--worktree on|off] [--branch B] [--handoff H]
                   [--lang en|zh]   → {"ok","prompt","handoff","path","items"}: a short prompt pointing at the
                                      items' hand-off note (K6; written unless --handoff names one)

sessions.py builds interactive sessions with session_command() (K5): the agent's interactive.session, its per-session
hooks (Claude: a --settings file; Codex: -c notify and hooks.*) and the blurt MCP server when it isn't installed.

The registry is agents.json next to this file (also bundled into Blurt.app, which implements the same rules in
Agents.swift). Config ($BLURT_HOME/config.json → record): agents = ["claude", "codex", …] (order; agents not listed are
not used), agent_defs = {"<id>": {…same fields as agents.json…}} to add or override one. With --repo, the repo's
.blurt/config.json record.agents / record.process / record.agent_defs win over the global ones.

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
    """Global config, with the repo's .blurt/config.json record.agents / process / agent_defs on top."""
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
        if isinstance(lrec.get("agent_defs"), dict):
            rec["agent_defs"] = {**(rec.get("agent_defs") or {}), **lrec["agent_defs"]}
    return cfg


def expand(path: str, env: dict | None = None) -> Path:
    """~ and ${VAR:-default} / $VAR."""
    env = os.environ if env is None else env

    def sub(m):
        name, default = m.group(1) or m.group(3), m.group(2)
        return env.get(name) or (default if default is not None else "")
    s = re.sub(r"\$\{(\w+)(?::-([^}]*))?\}|\$(\w+)", sub, path)
    return Path(os.path.expanduser(s))


def _fill(args: list, vals: dict) -> list[str]:
    out = []
    for a in args:
        if isinstance(a, str):
            for k, v in vals.items():
                a = a.replace("{" + k + "}", str(v))
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
    pick = None
    for want in ("ready", "configured", "unknown"):
        pick = next((r["id"] for r in rows if r["state"] == want and r["headless"] and r["id"] in order), None)
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
            cfg: dict | None = None, env: dict | None = None, mcp: bool = True) -> dict:
    """What to execute for `agent`. headless: argv (absolute bin when found) run in cwd with env added; interactive:
    a url to open, or argv to run in the user's terminal, and/or text to put on the clipboard."""
    from urllib.parse import quote
    defs = definitions(cfg if cfg is not None else config(repo))
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
        vals = {**vars, "prompt": prompt, "repo": repo}
        argv = [bin_, *_fill(d["run"], vals)]
        hm = d.get("headless_mcp") or {}
        if mcp and hm.get("args"):  # the blurt MCP server, usable without approval prompts in an unattended run
            argv += _fill(hm["args"], {**vals, "mcp_server": str(MCP_SERVER), "mcp_server_json": json.dumps(str(MCP_SERVER))})
        ev = d.get("events") or {}
        if events and ev.get("args"):
            argv += _fill(ev["args"], vals)
            out["events"] = ev.get("format")
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
                    env: dict | None = None) -> dict:
    """argv for an interactive session of `agent` (K5). settings = where the Claude --settings file goes (written
    here); mcp None = add the blurt MCP server only when the user hasn't installed it.
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
    argv += _fill(sp.get("argv", []), {"prompt": prompt, "repo": str(cwd)})
    return {"argv": argv, "paste": prompt if paste else None, "hooks": hooks, "patterns": waiting_patterns(d)}


WORK_PROMPT = {
    "en": "Read {note} and handle the items in it. {rule} When you finish an item, call the blurt MCP tool "
          "mark_fixed with its uid (or, without the MCP, run the items.py command the note gives).",
    "zh": "读 {note}，处理里面的条目。{rule}每做完一条，用它的 uid 调用 blurt MCP 工具 mark_fixed（没有 MCP 就运行交接单里给的 "
          "items.py 命令）。",
}


def prompt_work(refs: list[str], mode: str = "session", worktree: bool = False, handoff_id: str | None = None,
                lang: str | None = None, branch: str | None = None, items: list[dict] | None = None) -> dict:
    """The short prompt that starts an agent on some items: it points at their hand-off note (K6), written here
    unless handoff_id names one already."""
    import handoff
    lang = handoff.ui_lang(lang)
    if handoff_id:
        h = handoff.describe(handoff_id)
    else:
        h = handoff.create(refs, lang, to=mode, branch=branch, worktree=worktree, items=items)
    t = handoff.T[lang]
    rule = (t["rule_worktree"].format(branch=branch or "") if mode == "session" and worktree
            else t["rule_direct"] if mode == "session" else t["rule_external"])
    return {"prompt": WORK_PROMPT[lang].format(note=h["path"], rule=rule), "handoff": h["id"], "path": h["path"],
            "items": h["items"]}


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
            _emit(command(a.id, a.mode, prompt, a.repo, vars, events=not a.no_events, mcp=not a.no_mcp))
            return
        if a.cmd == "install":
            both = not a.skill and not a.mcp
            _emit(install(a.id, skill=a.skill or both, mcp=a.mcp or both, dry_run=a.dry_run))
            return
        if a.cmd == "prompt":
            _emit({"ok": True, **prompt_work(a.items, a.mode, a.worktree == "on", a.handoff, a.lang, a.branch)})
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
