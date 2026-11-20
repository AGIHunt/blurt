# /// script
# requires-python = ">=3.10"
# ///
"""Which coding-agent CLI processes a recording, in what order, and why one couldn't. The one place agent CLIs are
described (contract C5): the apps and live.py run what this returns instead of building commands themselves.

  agents.py status [--json]        each agent in the configured order: installed? logged in? the fix command
  agents.py order [--json] [--repo DIR]   the configured order (config record.agents), one id per line
  agents.py classify FILE          a failed run's log (agent.log) → {"class": "auth|quota|network|model|skill|null", …}
  agents.py detect [--repo DIR] [--ids a,b] [--no-login] [--no-version] [--lang L] [--fresh]
                                   → {"order": [...], "pick": id|null, "agents": [{id, name, path, state, why, fix,
                                      installed, version, login, headless, home, app, found, linked, last_seen,
                                      conn: connected|linked|found|missing, connect, edition?}]}
  agents.py command ID headless --prompt TEXT|--prompt-file F --repo DIR [--var k=v …] [--no-events]
                   [--no-mcp] [--processing [recording|cards]]
                                   → {"id","mode","argv","cwd","env","events","retry_exit"}; --processing (an
                                      unattended organising run): the processing model + effort for that kind of run
                                      (recording: organizing a recording; cards, the default: snaps, voice notes, AI
                                      fill-in and other small runs) and the usage flags → also "processing", "usage";
                                      "scripts" = the folder the run may call (`uv run <scripts>/<name>.py`: name it
                                      so in the prompt), env = what a sandboxed run needs (sandbox_env)
  agents.py models ID              → {"ok","id","models":[{id,name,description,cheap}],"cheapest","cli_default",
                                      "efforts","processing":{model,effort (= cards),"recording":{model,effort},
                                      "cards":{model,effort}}}   (no network, no tokens)
  agents.py usage ID FILE [--offset N]   tokens a run reported in its output (from byte N) → {"ok","usage"|null}
  agents.py install ID [--skill] [--mcp] [--dry-run]   → {"changes": [{action, path|argv, …}], "applied": bool}
  agents.py manual [--lang L]      any other agent, by hand: {skill, server, command, args, mcp_json, prompt}
  agents.py custom NAME [--home DIR] | --remove ID   a user's own agent in record.agent_defs → {id, def}
  agents.py drop [--os macos|windows|linux]   the card-drag targets: [{agent, name, ids, drop, on, custom}]
  agents.py zip-skill OUT.zip      the skill folder as a .zip (blurt/ at its top) → {path}
  agents.py prompt work --items REF … [--handoff H] [--lang en|zh]
                                   → {"ok","prompt","title","handoff","path","items"}: a short prompt for the user's
                                      own agent, pointing at the items' hand-off note (K6; written unless --handoff
                                      names one), its first line the title ("AW-12 · <title> (Blurt hand-off)" —
                                      work_title)

Blurt runs agents only headless and unattended (organising, AI sort, AI fill-in). Working on items happens in the
user's own agent, from a hand-off note (handoff.py) and the blurt MCP server.

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
from _common import global_config, parse_config_text  # noqa: E402

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
    env = os.environ if env is None else env

    def at(f: str) -> Path:
        return _at(f, env, home)
    cj = st.get("creds_json")
    if isinstance(cj, dict) and cj.get("path"):
        f = at(cj["path"])
        try:
            creds = json.loads(f.read_text(encoding="utf-8"))
            if isinstance(creds, dict) and not any(creds.get(k) for k in cj.get("keys", [])):
                return "logged_out"  # e.g. kimi: provider listed, tokens empty → `kimi -p` fails "no credential configured"
        except (OSError, ValueError):
            pass
    if other_provider(defn, env, home):  # codex on another provider (cc-switch & co.): its ChatGPT login doesn't apply
        return "configured"
    if any(s in low for s in st.get("logged_out", [])):
        return "logged_out"
    if code == 0 and any(s in low for s in st.get("ok_if", [])):
        return "ready"
    if st.get("configured_if") and re.search(st["configured_if"], text or "", re.I):
        return "configured"
    if any(env.get(k) for k in st.get("env_any", [])):
        return "configured"
    if any(at(f).exists() for f in st.get("files_any", [])):
        return "configured"
    if st.get("otherwise") == "logged_out" and (code is not None or "args" not in st):
        return "logged_out"
    return "unknown"


def _at(f: str, env: dict, home: Path) -> Path:
    """A status path: ${VAR:-default} first (grok: ${GROK_HOME:-~/.grok}), then ~/ against `home`."""
    f = _subst(f, env)
    return home / f[2:] if f.startswith("~/") else Path(os.path.expanduser(f))


def other_provider(defn: dict, env: dict | None = None, home: Path | None = None) -> str | None:
    """The model provider the agent's TOML config selects when it isn't the CLI's own (status.provider_toml), else None.
    Codex: top-level `model_provider = "<id>"` with `[model_providers.<id>]` (what cc-switch and similar tools write),
    or the same key in the `[profiles.<name>]` that a top-level `profile = "<name>"` selects (that one wins). Such a
    user has no ChatGPT login and needs none."""
    pt = (defn.get("status") or {}).get("provider_toml")
    if not (isinstance(pt, dict) and pt.get("path") and pt.get("key")):
        return None
    f = _at(pt["path"], os.environ if env is None else env, home or Path.home())
    val = None
    if pt.get("profile") and pt.get("profiles"):
        name = _toml_get(f, [pt["profile"]])
        val = _toml_get(f, [pt["profiles"], name, pt["key"]]) if name else None
    val = val or _toml_get(f, [pt["key"]])
    return val if val and val not in (pt.get("except") or []) else None


def usable(state: str) -> bool:
    return state in ("ready", "configured", "unknown")


def check(defn: dict, env: dict | None = None, lang: str = "en") -> dict:
    env = dict(os.environ) if env is None else env
    path = find_bin(defn, env)
    out = {"id": defn["id"], "name": defn.get("name", defn["id"]), "path": path}
    if not path:
        out.update(state="not_installed", why=("未安装" if lang == "zh" else "not installed"),
                   fix=(defn.get("install") or {}).get(lang, ""))
        return out
    code, text = None, ""
    args = (defn.get("status") or {}).get("args")
    if args:
        code, so, se = probe([path, *args], env, 15)
        if code is not None:
            text = so + se
    state = parse_status(defn, code, text, env)
    why = {"ready": ("已登录", "logged in"), "configured": ("已配置", "configured"),
           "logged_out": ("未登录", "not logged in"), "unknown": ("登录状态未知，会直接试", "login unknown, will try")}[state]
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
            text = c["reason"][lang].replace("{name}", name)
            if not fix and "{fix}" in text:  # no fix known: end the sentence there, never on a bare colon
                return text.split("{fix}")[0].rstrip("：:—– ")
            return text.replace("{fix}", fix)
    if lang == "zh":
        return f"{name} 没整理完（退出码 {code}）" if code is not None else f"{name} 没整理完"
    return f"{name} didn't finish (exit {code})" if code is not None else f"{name} didn't finish"


# ------------------------------------------------------------------ WP2: detect / command / install / prompt (C5)
SCRIPTS = Path(__file__).resolve().parent


def has_skill(folder: Path) -> bool:
    """A folder an agent can be given: the whole skill, SKILL.md at its top (not a bare scripts folder: an install
    folder's resources, a checkout's scripts/)."""
    return (folder / "SKILL.md").is_file()


def skill_root(scripts: Path = SCRIPTS) -> Path:
    """The skill these scripts belong to: their parent when it has SKILL.md, else the app's copy ($BLURT_HOME/skill,
    which the apps keep up to date: BundledSkill / paths::skill_dir) when that has one. Never an install folder
    without SKILL.md — install() refuses to link a folder that has none."""
    if has_skill(scripts.parent):
        return scripts.parent
    from _common import blurt_home  # noqa: PLC0415
    app = blurt_home() / "skill"
    return app if has_skill(app) else scripts.parent


SKILL_ROOT = skill_root()
MCP_SERVER = (SKILL_ROOT / "scripts" / "mcp_server.py") if (SKILL_ROOT / "scripts" / "mcp_server.py").is_file() \
    else SCRIPTS / "mcp_server.py"
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
            # read as the global config.json is (and as the app's ProjectConfig reads it): a trailing comma forgiven
            local = parse_config_text((Path(repo) / ".blurt" / "config.json").read_text(encoding="utf-8-sig")) or {}
        except (OSError, ValueError):
            local = {}
        lrec = local.get("record") if isinstance(local, dict) and isinstance(local.get("record"), dict) else {}
        rec = cfg.setdefault("record", {})
        for k in ("agents", "process"):
            if k in lrec:
                rec[k] = lrec[k]
    return cfg


def _env_get(env: dict, name: str, nt: bool | None = None) -> str | None:
    """env[name]; on Windows by any case, as Windows itself reads them (agents.json writes ${ProgramFiles}, a copied
    environment may hold PROGRAMFILES)."""
    v = env.get(name)
    if v or not (os.name == "nt" if nt is None else nt):
        return v
    up = name.upper()
    return next((val for k, val in env.items() if k.upper() == up and val), None)


def _subst(path: str, env: dict, nt: bool | None = None) -> str:
    """${VAR:-default} / $VAR, leaving ~ alone (names compared without case on Windows)."""
    def sub(m):
        name, default = m.group(1) or m.group(3), m.group(2)
        return _env_get(env, name, nt) or (default if default is not None else "")
    return re.sub(r"\$\{(\w+)(?::-([^}]*))?\}|\$(\w+)", sub, path)


def expand(path: str, env: dict | None = None) -> Path:
    """~ and ${VAR:-default} / $VAR."""
    return Path(os.path.expanduser(_subst(path, os.environ if env is None else env)))


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
    its own uv cache. Never $BLURT_HOME (config.json and its agent_defs, the jobs, the index) nor the
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


def uv_path(env: dict | None = None) -> str:
    """uv's absolute path ({uv} in agents.json): every agent starts the blurt MCP server itself, and not with our PATH —
    desktop apps (Cursor, WorkBuddy) without the login shell's, and on Windows / Linux the apps install uv into
    $BLURT_HOME/bin, which is on nobody's PATH but theirs. PATH first, then that copy, else a bare "uv"."""
    env = os.environ if env is None else env
    found = shutil.which("uv", path=env.get("PATH"))
    if found:
        return found
    from _common import blurt_home  # noqa: PLC0415
    p = blurt_home() / "bin" / ("uv.exe" if os.name == "nt" else "uv")
    return str(p) if p.is_file() else "uv"


def find_bin(defn: dict, env: dict | None = None) -> str | None:
    env = os.environ if env is None else env
    p = next((p for p in (shutil.which(b, path=env.get("PATH")) for b in defn.get("bins", [defn["id"]])) if p), None)
    return unshim(p) if p else None


# the program the shim hands its arguments to ("…\\claude.exe" %*) — not the node.exe a JavaScript CLI's shim runs
# when one sits next to it (portable Node, nvm-windows: `"%_prog%" "…\\codex.js" %*`)
_SHIM_TARGET = re.compile(r'"%dp0%\\([^"]+\.exe)"[ \t]*%\*', re.I)


def shim_target(text: str) -> str | None:
    """The native program an npm `.cmd` shim runs (relative to the shim's folder), None for a JavaScript CLI's."""
    m = _SHIM_TARGET.search(text)
    return m.group(1) if m else None


def unshim(path: str) -> str:
    """Windows: an npm `.cmd` shim that only starts a native program (Claude Code's: "%dp0%\\…\\claude.exe" %*) → that
    program. A .cmd runs through cmd.exe, which can't carry a multi-line prompt as an argument and which Rust and
    Python refuse to hand such arguments to ("batch file arguments are invalid"); the .exe takes them as they are."""
    if os.name != "nt" or not path.lower().endswith((".cmd", ".bat")):
        return path
    try:
        target = shim_target(Path(path).read_text(encoding="utf-8", errors="replace"))
    except OSError:
        return path
    if not target:
        return path
    exe = Path(path).parent / target
    return str(exe) if exe.is_file() else path


# ------------------------------------------------------------------ where agent apps are (agents.json `app`, `home`)
# An app agent is found by what it leaves behind, never by starting it: its own config folder (`home`, the signal
# that its skill / MCP config will be read) or its app, by an id that doesn't move with the install folder — a
# macOS bundle id (LaunchServices), a Windows executable's stem (from the Uninstall keys, App Paths, Start Menu
# shortcuts, Scoop / WinGet), a Linux .desktop id (XDG, Flatpak, Snap exports). What was found is kept APP_CACHE_TTL.

APP_CACHE_TTL = 600


def os_key(platform: str | None = None) -> str:
    platform = platform or sys.platform
    return "macos" if platform == "darwin" else "windows" if platform.startswith("win") else "linux"


def _as_list(v) -> list:
    return [v] if isinstance(v, str) else [x for x in (v or []) if isinstance(x, str)]


def is_path_id(s: str) -> bool:
    """An app entry that is a path (the v1.0.21 shape, and a fallback when an id isn't known), not an id."""
    return s.startswith(("~", "$", "/")) or "\\" in s or "/" in s or bool(re.match(r"^[A-Za-z]:", s))


def app_ids(defn: dict, osk: str | None = None) -> list[str]:
    return _as_list((defn.get("app") or {}).get(osk or os_key()))


def homes(defn: dict, env: dict | None = None) -> list[Path]:
    env = os.environ if env is None else env
    home = Path(env["HOME"]) if os.name != "nt" and env.get("HOME") else Path.home()
    return [_at(h, env, home) for h in _as_list(defn.get("home"))]


def home_of(defn: dict, env: dict | None = None) -> Path | None:
    """The agent's own config folder when it is there (the first of `home`'s that exists)."""
    return next((h for h in homes(defn, env) if h.is_dir()), None)


# --- macOS: bundle ids
def mac_app_dirs(home: Path | None = None) -> list[Path]:
    h = home or Path.home()
    return [Path("/Applications"), h / "Applications", Path("/Applications/Setapp"), Path("/System/Applications")]


def mac_bundles(dirs: list[Path]) -> dict[str, str]:
    """bundle id → .app path for the apps in these folders (one level, and one folder deeper: /Applications/Foo/Foo.app)."""
    import plistlib  # noqa: PLC0415
    out: dict[str, str] = {}

    def one(app: Path):
        try:
            with open(app / "Contents" / "Info.plist", "rb") as f:
                bid = plistlib.load(f).get("CFBundleIdentifier")
        except (OSError, ValueError, plistlib.InvalidFileException):
            return
        if isinstance(bid, str):
            out.setdefault(bid, str(app))
    for d in dirs:
        try:
            entries = list(d.iterdir())
        except OSError:
            continue
        for e in entries:
            if e.suffix == ".app":
                one(e)
            elif e.is_dir() and not e.name.startswith("."):
                try:
                    for sub in e.iterdir():
                        if sub.suffix == ".app":
                            one(sub)
                except OSError:
                    pass
    return out


def mdfind_bundles(ids: list[str]) -> dict[str, str]:
    """Bundle ids LaunchServices / Spotlight knows anywhere on disk → a path (one query for all)."""
    if not ids or not shutil.which("mdfind"):
        return {}
    q = " || ".join(f'kMDItemCFBundleIdentifier == "{i}"' for i in ids if re.fullmatch(r"[\w.-]+", i))
    code, out, _ = probe(["mdfind", q], dict(os.environ), 5)
    if code != 0:
        return {}
    res: dict[str, str] = {}
    paths = [Path(p) for p in out.splitlines() if p.endswith(".app")]
    for p in paths:
        res.update({k: v for k, v in mac_bundles([p.parent]).items() if k in ids and k not in res})
    return res


# --- Windows: executable stems
def exe_stem(path: str) -> str | None:
    """'"C:\\Program Files\\WorkBuddy\\WorkBuddy.exe",0' → 'workbuddy' (a DisplayIcon, a shortcut's target, a key name)."""
    p = (path or "").strip().strip('"')
    p = re.sub(r",\s*-?\d+$", "", p).strip().strip('"')
    name = re.split(r"[\\/]", p)[-1]
    return name[:-4].lower().strip() if name.lower().endswith(".exe") and len(name) > 4 else None


def lnk_target(data: bytes) -> str | None:
    """The local path a Windows shortcut (.lnk, MS-SHLLINK) points at: its LinkInfo's LocalBasePath (Unicode when
    there is one). None for a shortcut without one (a URL, an MSI advertised shortcut)."""
    import struct  # noqa: PLC0415
    try:
        if len(data) < 0x4C or struct.unpack_from("<I", data, 0)[0] != 0x4C:
            return None
        flags = struct.unpack_from("<I", data, 0x14)[0]
        pos = 0x4C
        if flags & 0x1:  # HasLinkTargetIDList
            pos += 2 + struct.unpack_from("<H", data, pos)[0]
        if not flags & 0x2:  # HasLinkInfo
            return None
        size, head, li_flags, _vol, local = struct.unpack_from("<IIIII", data, pos)
        if not li_flags & 0x1:  # VolumeIDAndLocalBasePath
            return None
        if head >= 0x24:
            uni = struct.unpack_from("<I", data, pos + 0x1C)[0]
            if uni:
                raw = data[pos + uni:pos + size]
                end = next((i for i in range(0, len(raw) - 1, 2) if raw[i:i + 2] == b"\0\0"), len(raw))
                return raw[:end].decode("utf-16-le", errors="replace") or None
        raw = data[pos + local:pos + size]
        return raw.split(b"\0", 1)[0].decode("mbcs" if os.name == "nt" else "latin-1", errors="replace") or None
    except (struct.error, IndexError, LookupError):
        return None


def windows_uninstall_entries() -> list[dict]:
    """DisplayName / DisplayIcon / InstallLocation of every Uninstall key: HKCU, HKLM and HKLM's WOW6432Node."""
    try:
        import winreg  # noqa: PLC0415
    except ImportError:
        return []
    out = []
    roots = [(winreg.HKEY_CURRENT_USER, r"Software\Microsoft\Windows\CurrentVersion\Uninstall"),
             (winreg.HKEY_LOCAL_MACHINE, r"Software\Microsoft\Windows\CurrentVersion\Uninstall"),
             (winreg.HKEY_LOCAL_MACHINE, r"Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall")]
    for root, path in roots:
        try:
            k = winreg.OpenKey(root, path)
        except OSError:
            continue
        with k:
            for i in range(winreg.QueryInfoKey(k)[0]):
                try:
                    with winreg.OpenKey(k, winreg.EnumKey(k, i)) as sub:
                        e = {}
                        for name in ("DisplayName", "DisplayIcon", "InstallLocation"):
                            try:
                                e[name] = str(winreg.QueryValueEx(sub, name)[0])
                            except OSError:
                                pass
                        out.append(e)
                except OSError:
                    continue
    return out


def windows_app_paths() -> list[str]:
    """The App Paths keys' names (Cursor.exe…), HKCU and HKLM."""
    try:
        import winreg  # noqa: PLC0415
    except ImportError:
        return []
    out = []
    for root in (winreg.HKEY_CURRENT_USER, winreg.HKEY_LOCAL_MACHINE):
        try:
            with winreg.OpenKey(root, r"Software\Microsoft\Windows\CurrentVersion\App Paths") as k:
                out += [winreg.EnumKey(k, i) for i in range(winreg.QueryInfoKey(k)[0])]
        except OSError:
            continue
    return out


def windows_stems(uninstall: list[dict], app_paths: list[str], shortcuts: list[tuple[str, str | None]],
                  exes: list[str], listdir=None) -> dict[str, str]:
    """stem → where it was seen (pure but for `listdir`, the files of an InstallLocation): the DisplayIcon's program,
    the programs right in InstallLocation, App Paths names, Start Menu shortcuts (their target's program, and the
    shortcut's own name: "Trae CN.lnk"), Scoop / WinGet links (`exes`)."""
    out: dict[str, str] = {}

    def add(stem, where):
        if stem:
            out.setdefault(stem, where)
    for e in uninstall:
        icon = re.sub(r",\s*-?\d+$", "", (e.get("DisplayIcon") or "").strip()).strip().strip('"')
        add(exe_stem(icon), icon)
        loc = (e.get("InstallLocation") or "").strip().strip('"')
        if loc and listdir:
            for f in listdir(loc):
                add(exe_stem(f), os.path.join(loc, f))
    for name in app_paths:
        add(exe_stem(name), name)
    for lnk, target in shortcuts:
        add(exe_stem(target or ""), target or lnk)
        base = re.split(r"[\\/]", lnk)[-1]
        if base.lower().endswith(".lnk"):
            add(base[:-4].lower().strip(), lnk)
    for x in exes:
        add(exe_stem(x), x)
    return out


def windows_found(env: dict) -> dict[str, str]:
    def listdir(d):
        try:
            return [f for f in os.listdir(d) if f.lower().endswith(".exe")]
        except OSError:
            return []
    shortcuts = []
    for base in (_env_get(env, "APPDATA", True), _env_get(env, "ProgramData", True)):
        if not base:
            continue
        root = Path(base) / "Microsoft" / "Windows" / "Start Menu" / "Programs"
        for lnk in list(root.glob("*.lnk")) + list(root.glob("*/*.lnk")):
            try:
                shortcuts.append((str(lnk), lnk_target(lnk.read_bytes()[:65536])))
            except OSError:
                pass
    exes = []
    local = _env_get(env, "LOCALAPPDATA", True)
    for d in ([Path(local) / "Microsoft" / "WinGet" / "Links"] if local else []) + \
             [Path(_env_get(env, "SCOOP", True) or Path.home() / "scoop") / "shims"]:
        exes += [str(p) for p in d.glob("*.exe")] if d.is_dir() else []
    return windows_stems(windows_uninstall_entries(), windows_app_paths(), shortcuts, exes, listdir)


# --- Linux: .desktop ids
def desktop_entry(text: str) -> dict:
    """The [Desktop Entry] keys that identify an app: Name, Exec's program (its file name, lowercased),
    StartupWMClass."""
    out: dict = {}
    section = None
    for ln in text.splitlines():
        ln = ln.strip()
        if ln.startswith("["):
            section = ln
            continue
        if section != "[Desktop Entry]" or "=" not in ln:
            continue
        k, v = (x.strip() for x in ln.split("=", 1))
        if k in ("Name", "Exec", "StartupWMClass", "Type"):
            out.setdefault(k, v)
    exe = out.get("Exec", "")
    if exe:
        import shlex  # noqa: PLC0415
        try:
            words = [w for w in shlex.split(exe) if not w.startswith("%")]
        except ValueError:
            words = exe.split()
        # flatpak run / snap run / env VAR=x prog
        while words and (words[0].rsplit("/", 1)[-1] in ("env", "flatpak", "snap") or "=" in words[0]
                         or words[0] in ("run",) or words[0].startswith("--")):
            words = words[1:]
        if words:
            out["program"] = words[0].rsplit("/", 1)[-1].lower()
    return out


def linux_app_dirs(env: dict) -> list[Path]:
    home = Path(_env_get(env, "HOME") or Path.home())
    data_home = Path(_env_get(env, "XDG_DATA_HOME") or home / ".local" / "share")
    dirs = [data_home] + [Path(d) for d in (_env_get(env, "XDG_DATA_DIRS") or "/usr/local/share:/usr/share").split(":") if d]
    dirs += [home / ".local/share/flatpak/exports/share", Path("/var/lib/flatpak/exports/share")]
    out = [d / "applications" for d in dirs] + [Path("/var/lib/snapd/desktop/applications")]
    return list(dict.fromkeys(out))


def linux_ids(files: dict[str, str]) -> dict[str, str]:
    """{path of a .desktop file: its text} → id → path: the file's id (cursor.desktop → cursor; a reverse-DNS id
    com.cursor.Cursor → also its last part), Exec's program, StartupWMClass — all lowercased."""
    out: dict[str, str] = {}
    for path, text in files.items():
        e = desktop_entry(text)
        if e.get("Type", "Application") != "Application":
            continue
        fid = re.split(r"[\\/]", path)[-1].removesuffix(".desktop").lower()
        for i in (fid, fid.rsplit(".", 1)[-1], fid.split("_", 1)[-1], e.get("program"), (e.get("StartupWMClass") or "").lower()):
            if i:
                out.setdefault(i, path)
    return out


def linux_found(env: dict) -> dict[str, str]:
    files = {}
    for d in linux_app_dirs(env):
        for f in d.glob("*.desktop") if d.is_dir() else []:
            try:
                files[str(f)] = f.read_text(encoding="utf-8", errors="replace")
            except OSError:
                pass
    return linux_ids(files)


def _app_cache_file() -> Path:
    from _common import blurt_home  # noqa: PLC0415
    return blurt_home() / "run" / "agents-apps.json"


def found_apps(defs: list[dict], env: dict | None = None, fresh: bool = False, now: float | None = None,
               cache: bool = True) -> dict[str, str | None]:
    """agent id → the app found for it on this OS (a path), or None. Kept APP_CACHE_TTL in run/agents-apps.json
    (looking through the registry or every .desktop file takes a moment); `fresh` looks again (Check Again)."""
    import time  # noqa: PLC0415
    env = os.environ if env is None else env
    now = time.time() if now is None else now
    osk = os_key()
    want = {d.get("id", ""): app_ids(d, osk) for d in defs if app_ids(d, osk)}
    key = json.dumps(want, sort_keys=True)
    cf = _app_cache_file()
    if cache and not fresh:
        try:
            c = json.loads(cf.read_text(encoding="utf-8"))
            if c.get("key") == key and now - float(c.get("at", 0)) < APP_CACHE_TTL:
                return {k: v for k, v in c.get("found", {}).items() if k in want}
        except (OSError, ValueError, TypeError, AttributeError):
            pass
    found: dict[str, str | None] = {}
    ids = {i for v in want.values() for i in v if not is_path_id(i)}
    table: dict[str, str] = {}
    if ids:
        if osk == "macos":
            table = mac_bundles(mac_app_dirs())
            missing = [i for i in ids if i not in table]
            if missing:
                table.update(mdfind_bundles(missing))
        elif osk == "windows":
            table = windows_found(env)
        else:
            table = linux_found(env)
        if osk != "macos":
            table = {k.lower(): v for k, v in table.items()}
    for aid, cands in want.items():
        hit = None
        for c in cands:
            if is_path_id(c):
                p = expand(c, env)
                if p.exists():
                    hit = str(p)
            else:
                hit = table.get(c if osk == "macos" else c.lower())
            if hit:
                break
        found[aid] = hit
    try:
        if not cache:
            return found
        cf.parent.mkdir(parents=True, exist_ok=True)
        tmp = cf.with_name(cf.name + f".{os.getpid()}.tmp")
        tmp.write_text(json.dumps({"key": key, "at": now, "found": found}), encoding="utf-8")
        os.replace(tmp, cf)
    except OSError:
        pass
    return found


def app_path(defn: dict, env: dict | None = None, fresh: bool = False) -> str | None:
    """An agent's app on this OS (agents.json app.<os>: ids, or paths)."""
    return found_apps([defn], env, fresh, cache=False).get(defn.get("id", ""))


# ------------------------------------------------------------------ connected? (mcp-clients.json)
def mcp_clients_file() -> Path:
    from _common import blurt_home  # noqa: PLC0415
    return blurt_home() / "run" / "mcp-clients.json"


def record_mcp_client(name: str | None, version: str | None = None, now: float | None = None,
                      via: str | None = None) -> None:
    """The blurt MCP server was started by an agent: its clientInfo.name and when (mcp_server.py, at initialize and
    on hello). The proof that an agent really reads Blurt — not that a config file names it. A run the app started
    (via="app") goes in `app_at` beside the user's own `at`, never over it."""
    import time  # noqa: PLC0415
    name = " ".join(str(name or "").split())[:80]
    if not name:
        return
    f = mcp_clients_file()
    try:
        from _common import file_lock  # noqa: PLC0415
        f.parent.mkdir(parents=True, exist_ok=True)
        with file_lock(f.with_name(f.name + ".lock"), timeout=3):
            try:
                d = json.loads(f.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                d = {}
            clients = d.get("clients") if isinstance(d, dict) and isinstance(d.get("clients"), dict) else {}
            t = time.time() if now is None else now
            prev = clients.get(name) if isinstance(clients.get(name), dict) else {}
            if via == "app":
                e = {**prev, "app_at": t}
                if prev.get("via") == "app":  # an older entry whose `at` was the app's run
                    e.pop("at", None)
                    e.pop("version", None)
            else:
                e = {**prev, "at": t, "version": version or None}
            e.pop("via", None)
            clients[name] = e
            tmp = f.with_name(f.name + f".{os.getpid()}.tmp")
            tmp.write_text(json.dumps({"clients": clients}, ensure_ascii=False, indent=1), encoding="utf-8")
            os.replace(tmp, f)
    except Exception:  # noqa: BLE001 — a log, never in the way of the server
        pass


def mcp_clients() -> dict[str, dict]:
    try:
        d = json.loads(mcp_clients_file().read_text(encoding="utf-8"))
        return d["clients"] if isinstance(d.get("clients"), dict) else {}
    except (OSError, ValueError, KeyError, AttributeError):
        return {}


def client_agent(client: str, defs: dict[str, dict]) -> str | None:
    """Which agent a clientInfo.name is: agents.json mcp_clients (exact, any case), else its id or name."""
    c = client.strip().lower()
    for d in defs.values():
        if c in [x.lower() for x in _as_list(d.get("mcp_clients"))] or c in (d["id"].lower(), str(d.get("name", "")).lower()):
            return d["id"]
    return None


def last_seen(defs: dict[str, dict], clients: dict[str, dict] | None = None) -> dict[str, float]:
    """agent id → when its MCP client last started the blurt server (runs the app started — `app_at`, or an older
    entry's via="app" — don't count: those prove the app's command line, not the user's agent)."""
    out: dict[str, float] = {}
    for name, e in (mcp_clients() if clients is None else clients).items():
        aid = client_agent(name, defs)
        at = e.get("at") if isinstance(e, dict) else None
        if aid and isinstance(at, (int, float)) and e.get("via") != "app":
            out[aid] = max(out.get(aid, 0), float(at))
    return out


def linked(defn: dict, env: dict | None = None) -> bool:
    """Blurt is set up in the agent, as far as files say (no CLI started): its skill folder has our skill (link or
    copy), or its MCP config file names blurt."""
    env = os.environ if env is None else env
    if defn.get("skill_dir"):
        t = expand(defn["skill_dir"], env) / "blurt"
        try:
            head = (t / "SKILL.md").read_text(encoding="utf-8")[:600].splitlines() if has_skill(t) else []
            if any(ln.strip() == "name: blurt" for ln in head):  # ours, or another copy of Blurt (a checkout)
                return True
        except OSError:
            pass
    spec = ((defn.get("mcp") or {}).get("json")) or {}
    if spec.get("path"):
        try:
            node = json.loads(expand(spec["path"], env).read_text(encoding="utf-8-sig") or "{}")
            for k in spec["key"]:
                node = node.get(k) if isinstance(node, dict) else None
            return node is not None
        except (OSError, ValueError):
            pass
    return False


def connectable(defn: dict) -> bool:
    """Listed under "Use Blurt in your agent": it has a skill folder or an MCP setup Connect can write, or a by-hand
    note; `connect: false` (DoubaoWork: a card-drag target only) is not."""
    return defn.get("connect") is not False and bool(defn.get("skill_dir") or defn.get("mcp") or defn.get("fix"))


def is_headless(defn: dict) -> bool:
    return bool(defn.get("run")) and defn.get("headless", True) is not False


LOGIN = {"ready": "ok", "logged_out": "logged_out", "configured": "unknown", "unknown": "unknown",
         "not_installed": "n/a"}


def probe(argv: list[str], env: dict, timeout: float) -> tuple[int | None, str, str]:
    """Run a short probe → (returncode | None on timeout or failure, stdout, stderr). On a timeout the whole process tree
    is killed, not only the direct child: on Windows an npm agent is cmd.exe → node.exe, and subprocess.run(timeout=)
    kills cmd.exe then waits, without a limit, for pipes node still holds (grok models, opencode auth list waiting on
    the network) — Settings → Agent sat on "Checking…" until the app's 90 s limit."""
    nt = os.name == "nt"
    try:
        p = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, stdin=subprocess.DEVNULL, env=env,
                             text=True, encoding="utf-8", errors="replace", start_new_session=not nt,
                             creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0) if nt else 0)
    except OSError as e:
        return None, "", str(e)
    try:
        out, err = p.communicate(timeout=timeout)
        return p.returncode, out or "", err or ""
    except subprocess.TimeoutExpired:
        try:
            if nt:
                subprocess.run(["taskkill", "/T", "/F", "/PID", str(p.pid)], capture_output=True, timeout=10,
                               creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
            else:
                os.killpg(p.pid, 9)
        except (OSError, subprocess.SubprocessError):
            p.kill()
        try:
            out, err = p.communicate(timeout=3)
        except subprocess.TimeoutExpired:
            out, err = "", ""  # a grandchild kept the pipes: give up on its output rather than wait
        return None, out or "", err or ""


def version_of(defn: dict, path: str, env: dict) -> str | None:
    args = defn.get("version")
    if not args:
        return None
    code, out, err = probe([path, *args], env, 10)
    if code is None:
        return None
    text = ANSI.sub("", out + "\n" + err).strip()
    return text.splitlines()[0].strip() if text else None


CONN = ("connected", "linked", "found", "missing")


def conn_state(found: bool, is_linked: bool, seen: float | None) -> str:
    """For "Use Blurt in your agent": connected (its MCP client started the blurt server) > linked (set up, not used
    yet) > found (its app or config folder is here, not set up) > missing."""
    if seen:
        return "connected"
    if is_linked:
        return "linked"
    return "found" if found else "missing"


def detect(ids: list[str] | None = None, login: bool = True, version: bool = True, repo=None, env: dict | None = None,
           lang: str = "en", fresh: bool = False) -> dict:
    """check() for every agent in the configured order (or `ids`), plus installed / version / login / pick, and for
    "Use Blurt in your agent": home, app, found, linked, last_seen, conn (CONN), connect (connectable), edition.
    pick = the first installed, headless-capable agent that is logged in ("ready"), else the first "configured" /
    "unknown" one, else null. Only headless agents are probed (their CLI's sign-in and version); an app agent is
    found by its config folder or its app (found_apps, cached; `fresh` looks again), never by starting anything."""
    cfg = config(repo)
    defs = definitions(cfg)
    order = agent_order(cfg)
    env = clean_env(env)
    # connect-only agents (headless: false) follow the order: Settings → Agents lists them for Connect
    todo = [defs[i] for i in ids or order + [k for k in defs if k not in order and not is_headless(defs[k])] if i in defs]
    apps = found_apps(todo, env, fresh)
    seen = last_seen(defs)
    L = "zh" if (lang or "").startswith("zh") else "en"

    def one(d: dict) -> dict:
        headless = is_headless(d)
        if login and headless:
            r = check(d, env, lang)
        else:
            path = find_bin(d, env)
            r = {"id": d["id"], "name": d.get("name", d["id"]), "path": path,
                 "state": "unknown" if path else "not_installed", "why": "", "fix": ""}
        home = home_of(d, env)
        app = apps.get(d["id"])
        if not headless and not r["path"] and (app or home):  # an app agent: its app or its own folder is here
            r.update(path=app or str(home), state="unknown", why="app" if L == "en" else "应用", fix="")
        r["installed"] = r["state"] != "not_installed"
        r["version"] = version_of(d, r["path"], env) if version and headless and r["installed"] and find_bin(d, env) else None
        r["login"] = LOGIN.get(r["state"], "unknown")
        r["headless"] = headless
        r["home"] = str(home) if home else None
        r["app"] = app
        r["found"] = bool(r["installed"] or home or app)
        r["linked"] = linked(d, env)
        r["last_seen"] = seen.get(d["id"])
        r["conn"] = conn_state(r["found"], r["linked"], r["last_seen"])
        r["connect"] = connectable(d)
        if isinstance(d.get("edition"), dict):
            r["edition"] = d["edition"].get(L) or d["edition"].get("en")
        if d.get("custom"):
            r["custom"] = True
        return r

    # every agent at once: each probe is a CLI start-up (node on Windows: seconds), one after another they added up
    # past the app's limit. Rows stay in `todo`'s order.
    from concurrent.futures import ThreadPoolExecutor  # noqa: PLC0415
    with ThreadPoolExecutor(max_workers=max(1, min(8, len(todo)))) as pool:
        rows = list(pool.map(one, todo))
    # in the configured order, not the rows' (`ids` may list them in another order, e.g. Settings asks in registry order)
    by_id = {r["id"]: r for r in rows}
    pick = None
    for want in ("ready", "configured", "unknown"):
        pick = next((i for i in order if i in by_id and by_id[i]["state"] == want and by_id[i]["headless"]), None)
        if pick:
            break
    return {"order": order, "pick": pick, "agents": rows}


def command(agent: str, mode: str, prompt: str, repo: str | Path, vars: dict | None = None, events: bool = True,
            cfg: dict | None = None, env: dict | None = None, mcp: bool = True, processing_run: bool | str = False) -> dict:
    """What to execute for `agent`, unattended: argv (absolute bin when found) run in cwd with env added. mode is
    always "headless" (Blurt starts no interactive agent: the user hands items to their own). processing_run: an
    unattended organising run — the processing model / effort (processing(); "recording" or "cards", True = cards)
    and the flags that make the CLI report its token usage (out["processing"], out["usage"]: parse its output with
    parse_usage)."""
    if mode != "headless":
        raise ValueError("mode must be headless")
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
    out = {"id": agent, "mode": mode, "argv": None, "cwd": repo, "env": env_add, "events": None,
           "retry_exit": d.get("retry_exit")}
    if not is_headless(d) or not bin_:
        raise ValueError(f"{agent} has no headless mode")
    # {scripts}: claude / gemini may run only `uv run <scripts>/<name>.py` — the caller's prompt names that path. The
    # caller's spelling of it (--var scripts=…) when given: the prompt and the allowlist must be one string, also when
    # the folder sits under a symlink or a junction (this file's resolved path would differ)
    scripts = str(vars.pop("scripts", None) or SCRIPTS)
    vals = {**vars, "prompt": prompt, "repo": repo, "scripts": scripts}
    out["scripts"] = scripts
    if "{writable}" in d["run"]:  # sandboxed: only an organizing run writes the item stores; the rest only cwd
        vals["writable"] = writable_dirs() if processing_run else []
        env_add.update(sandbox_env())
    argv = [bin_, *_fill(d["run"], vals)]
    hm = d.get("headless_mcp") or {}
    if mcp and hm.get("args"):  # the blurt MCP server, usable without approval prompts in an unattended run
        uv = uv_path(clean_env(env))  # *_json: a TOML string for codex's -c (a Windows path's backslashes escaped)
        argv += _fill(hm["args"], {**vals, "mcp_server": str(MCP_SERVER), "mcp_server_json": json.dumps(str(MCP_SERVER)),
                                   "uv": uv, "uv_json": json.dumps(uv)})
    if processing_run:
        p = processing(agent, cfg, env, kind=processing_run if processing_run in KINDS else "cards")
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


# ------------------------------------------------------------------ v0.7: models, the processing model, token usage
EFFORTS = ("low", "medium", "high", "xhigh", "max")
_CHEAP = re.compile(r"\b(affordable|cheap|cheapest|fast|efficient|mini|nano|small|lite|flash|haiku)\b", re.I)


def _toml_top(path: Path, key: str) -> str | None:
    """A string setting of a TOML file — enough for codex's top-level `model = "…"` and grok's models.default (a dotted
    key: `default = "…"` under `[models]`, or `models.default = "…"` at the top)."""
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        return None
    table, _, name = key.rpartition(".")
    current = ""
    for ln in text.splitlines():
        s = ln.strip()
        if s.startswith("["):
            current = s.strip("[] ")
            continue
        for want, k in ((table, name), ("", key)):
            m = re.match(rf'{re.escape(k)}\s*=\s*"([^"]*)"', s) if current == want else None
            if m:
                return m.group(1)
    return None


def _toml_get(path: Path, keys: list[str]) -> str | None:
    """A string setting of a TOML file by its key path (["profiles", "work", "model_provider"]): tomllib when there
    is one (Python 3.11+: quoted keys, literal strings), else _toml_top."""
    try:
        import tomllib  # noqa: PLC0415
    except ImportError:
        return _toml_top(path, ".".join(keys))
    try:
        node = tomllib.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):  # missing, unreadable, not TOML (TOMLDecodeError is a ValueError)
        return None
    for k in keys:
        node = node.get(k) if isinstance(node, dict) else None
    return node if isinstance(node, str) else None


def models(agent: str, cfg: dict | None = None, env: dict | None = None) -> dict:
    """The models an agent's CLI offers, best first: a fixed list in agents.json (Claude Code's aliases) or the CLI's
    own model cache (Codex, Grok: models_cache.json, the models it shows in its picker). cli_default = the model the CLI uses
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
    elif spec.get("cache") and not other_provider(d, env):
        # the cache lists the CLI's own provider's models (codex: OpenAI's); on another provider the processing run
        # keeps the config's model instead of a "cheapest" one that provider doesn't have
        try:
            raw = json.loads(expand(spec["cache"], env).read_text(encoding="utf-8"))
        except (OSError, ValueError):
            raw = {}
        found = raw.get("models") if isinstance(raw, dict) else None
        if spec.get("format") == "grok" and isinstance(found, dict):
            # grok: {id: {"info": {name, description, hidden}}} in its picker's order; none counts as cheap (its fast
            # model costs more), so "cheapest" falls back to the CLI's own default
            for mid, m in found.items():
                info = m.get("info") if isinstance(m, dict) else None
                if isinstance(info, dict) and not info.get("hidden"):
                    rows.append({"id": info.get("id") or mid, "name": info.get("name") or mid,
                                 "description": str(info.get("description") or ""), "cheap": False})
        else:
            listed = [m for m in (found if isinstance(found, list) else [])
                      if isinstance(m, dict) and m.get("slug") and m.get("visibility", "list") == "list"]
            listed.sort(key=lambda m: m.get("priority") if isinstance(m.get("priority"), (int, float)) else 999)
            for m in listed:
                desc = str(m.get("description") or "")
                rows.append({"id": m["slug"], "name": m.get("display_name") or m["slug"], "description": desc,
                             "cheap": bool(_CHEAP.search(desc))})
    cli_default = _toml_top(expand(spec["config"], env), spec.get("config_key") or "model") if spec.get("config") else None
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


KINDS = ("recording", "cards")


def _kind_of(spec, kind: str) -> dict:
    """One kind's {model, effort} from a processing spec: {"recording": {…}, "cards": {…}}, or the v0.8 shape
    {model, effort} that stood for every run (a custom agent_defs entry, a user's earlier choice)."""
    if not isinstance(spec, dict):
        return {}
    if isinstance(spec.get(kind), dict):
        return spec[kind]
    return {k: spec[k] for k in ("model", "effort") if k in spec}


def processing(agent: str, cfg: dict | None = None, env: dict | None = None, kind: str = "cards") -> dict:
    """The model and effort an unattended organising run uses. kind "recording": organizing a recording (agents.json:
    the CLI's own default model at low effort — a recording is long and its items need judgement); "cards": snap
    and voice-note batches, AI fill-in and other small runs (the cheapest model, low effort). Config
    record.agent_processing.<id>.<kind> = {model, effort} (Settings → Agents) over agents.json `processing`. model
    "cheapest" = the cheap one from models() (none known → the CLI's default), "default" = the CLI's own setting.
    → {"model": id|None, "effort": level|None, "args": [...]}"""
    cfg = cfg if cfg is not None else config()
    d = definitions(cfg).get(agent)
    if not d:
        raise ValueError(f"unknown agent {agent!r}")
    kind = kind if kind in KINDS else "cards"
    base = _kind_of(d.get("processing"), kind)
    over = _kind_of(((cfg.get("record") or {}).get("agent_processing") or {}).get(agent), kind)
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
    code, out, err = probe(argv, env, timeout)
    if code is None and not (out or err):
        return None, f"timed out after {timeout} s or couldn't start: {argv[0]}"
    return code, (out + err).strip()


COPY_MARK = ".blurt-skill-copy"  # in a skill folder install() copied (Windows, no junction): the folder it copies


def _link_dir(target: Path, source: Path, copy: bool = False) -> str:
    """Make target show source's folder → "symlink" | "junction" | "copy". Windows: a directory junction — a symlink
    needs Developer Mode or admin (WinError 1314), a junction no privilege — else (a file system without junctions)
    a copy marked with COPY_MARK, refreshed by the next install."""
    if not copy and os.name != "nt":
        target.symlink_to(source, target_is_directory=True)
        return "symlink"
    if not copy:
        try:
            import _winapi  # noqa: PLC0415 — Windows only
            _winapi.CreateJunction(str(source), str(target))
            return "junction"
        except OSError:
            pass
    shutil.copytree(source, target, ignore=shutil.ignore_patterns("__pycache__", ".venv", COPY_MARK))
    (target / COPY_MARK).write_text(str(source.resolve()), encoding="utf-8")
    return "copy"


def _our_copy(target: Path) -> bool:
    try:
        return (not target.is_symlink() and target.is_dir()
                and (target / COPY_MARK).read_text(encoding="utf-8").strip() == str(SKILL_ROOT.resolve()))
    except OSError:
        return False


def _names_all(text: str, want: list[str]) -> bool:
    """Whether a CLI's description of a registered MCP server names every value in `want` (its command, our server
    path): one of the string values when the output is JSON (codex mcp get --json; a Windows path's backslashes
    escaped there), else in the text (claude mcp get)."""
    if not want:
        return True
    leaves: list[str] = []
    try:
        obj, _ = json.JSONDecoder().raw_decode(text[text.index("{"):])

        def walk(o):
            if isinstance(o, str):
                leaves.append(o)
            elif isinstance(o, dict):
                for v in o.values():
                    walk(v)
            elif isinstance(o, list):
                for v in o:
                    walk(v)
        walk(obj)
    except ValueError:  # no "{" or not JSON: the text itself
        return all(w in text for w in want)
    return all(w in leaves for w in want)


def _approve_lines(server: str, tools: list[str]) -> list[str]:
    return [f'[mcp_servers.{server}.tools.{t}] approval_mode = "approve"' for t in tools]


def _approvals_missing(text: str, server: str, tools: list[str]) -> list[str]:
    """The tools of `server` a Codex config.toml doesn't set to approval_mode = "approve" yet."""
    try:
        import tomllib  # noqa: PLC0415
        try:
            node = tomllib.loads(text)
        except ValueError:
            node = None
        if node is not None:
            got = ((node.get("mcp_servers") or {}).get(server) or {}).get("tools") or {}
            return [t for t in tools if not (isinstance(got.get(t), dict) and got[t].get("approval_mode") == "approve")]
    except ImportError:
        pass
    missing = []
    for t in tools:
        sec = re.search(rf"(?ms)^\s*\[mcp_servers\.{re.escape(server)}\.tools\.{re.escape(t)}\]\s*$(.*?)(?=^\s*\[|\Z)", text)
        if not (sec and re.search(r'(?m)^\s*approval_mode\s*=\s*["\']approve["\']\s*$', sec.group(1))):
            missing.append(t)
    return missing


def _with_approvals(text: str, server: str, tools: list[str]) -> str:
    """`text` with [mcp_servers.<server>.tools.<t>] approval_mode = "approve" for each of `tools`: the line replaced in
    a table that is already there, else the table appended. Everything else is left byte for byte."""
    for t in tools:
        head = re.compile(rf"(?m)^\s*\[mcp_servers\.{re.escape(server)}\.tools\.{re.escape(t)}\]\s*$")
        m = head.search(text)
        if not m:
            text = (text.rstrip("\n") + "\n\n" if text.strip() else "") + \
                f'[mcp_servers.{server}.tools.{t}]\napproval_mode = "approve"\n'
            continue
        nxt = re.search(r"(?m)^\s*\[", text[m.end():])
        end = m.end() + (nxt.start() if nxt else len(text) - m.end())
        body = text[m.end():end]
        if re.search(r"(?m)^\s*approval_mode\s*=", body):
            body = re.sub(r"(?m)^(\s*)approval_mode\s*=.*$", r'\1approval_mode = "approve"', body, count=1)
        else:
            body = '\napproval_mode = "approve"' + body
        text = text[:m.end()] + body + text[end:]
    return text


def _codex_approvals(spec: dict, bin_: str | None, check: list[str] | None, env: dict, dry_run: bool,
                     registered: bool) -> dict:
    """Connect's per-tool approval for the reporting tools only (agents.json mcp.approve: Codex's mark_fixed,
    get_item, search_items): an unattended run with approval "never" refuses any MCP call that would ask, so the
    agent's report never reached Blurt. Nothing that takes a key (setup_connect) is in the list: those still ask.
    Written after the server is registered (`codex mcp add` rewrites the server's table and drops these; a tools table
    for a server that isn't there yet stops Codex from loading its config), then checked by loading the config with
    Codex itself — if that fails the file goes back as it was."""
    path = expand(spec["path"], env)
    server, tools = spec.get("server") or "blurt", list(spec.get("tools") or [])
    try:
        text = path.read_text(encoding="utf-8") if path.exists() else ""
    except OSError as e:
        return {"action": "error", "what": "mcp", "path": str(path), "error": str(e)}
    key = ["mcp_servers", server, "tools"]
    missing = tools if not registered and dry_run else _approvals_missing(text, server, tools)
    if not missing:
        return {"action": "exists", "what": "mcp", "path": str(path), "key": key, "lines": _approve_lines(server, tools)}
    ch = {"action": "toml_set", "what": "mcp", "path": str(path), "key": key, "tools": missing,
          "lines": _approve_lines(server, missing)}
    if dry_run:
        return ch
    if not registered:
        ch.update(ok=False, error="the blurt MCP server isn't registered with Codex")
        return ch
    new = _with_approvals(text, server, missing)
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_name(path.name + f".{os.getpid()}.tmp")
        tmp.write_text(new, encoding="utf-8")
        os.replace(tmp, path)
    except OSError as e:
        ch.update(ok=False, error=str(e))
        return ch
    if bin_ and check:
        code, out = _run([bin_, *check], env, timeout=20)
        if code != 0:  # Codex can't load it: put the user's file back exactly as it was
            try:
                path.write_text(text, encoding="utf-8")
            except OSError:
                pass
            ch.update(ok=False, error=f"Codex didn't accept the change: {out[-300:]}")
            return ch
    ch["ok"] = True
    return ch


def install(agent: str, skill: bool = True, mcp: bool = True, dry_run: bool = False, env: dict | None = None,
            cfg: dict | None = None) -> dict:
    """Link the skill into the agent's skill dir and register the blurt MCP server with it. Never overwrites a
    different skill already there; with dry_run nothing is touched (the `check` probe of an argv mcp still runs)."""
    defs = definitions(cfg if cfg is not None else config())
    d = defs.get(agent)
    if not d:
        raise ValueError(f"unknown agent {agent!r}")
    env = dict(os.environ if env is None else env)  # CODEX_HOME & co. decide which config gets written
    vals = {"mcp_server": str(MCP_SERVER), "skill": str(SKILL_ROOT), "uv": uv_path(env)}
    changes, ok = [], True
    if skill:
        if d.get("skill_dir") and not has_skill(SKILL_ROOT):
            # the folder an agent would read has no SKILL.md (the app's scripts alone): never link that
            changes.append({"action": "error", "what": "skill", "path": str(SKILL_ROOT),
                            "error": f"no SKILL.md in {SKILL_ROOT}: not a skill folder"})
            ok = False
        elif not d.get("skill_dir"):
            changes.append({"action": "manual", "what": "skill", "how": (d.get("fix") or {}).get("en", "")})
        else:
            target = expand(d["skill_dir"], env) / "blurt"
            if os.path.lexists(target):  # a dangling link / junction too: never replaced
                same = target.resolve() == SKILL_ROOT.resolve()
                ch = {"action": "exists" if same else "conflict", "path": str(target), "points_to": str(target.resolve())}
                if not same and _our_copy(target):  # the copy fallback: brought up to date, still ours
                    same = True
                    ch.update(action="exists", points_to=str(SKILL_ROOT), kind="copy")
                    if not dry_run:
                        try:
                            shutil.rmtree(target)
                            _link_dir(target, SKILL_ROOT, copy=True)
                            ch["refreshed"] = True
                        except OSError as e:
                            ch.update(action="error", error=str(e))
                            same = False
                changes.append(ch)
                ok = ok and same
            else:
                # "symlink" whatever it ends up as (the apps key on it); kind says which: on Windows a junction
                ch = {"action": "symlink", "path": str(target), "target": str(SKILL_ROOT),
                      "kind": "junction" if os.name == "nt" else "symlink"}
                if not dry_run:
                    try:
                        target.parent.mkdir(parents=True, exist_ok=True)
                        ch.update(kind=_link_dir(target, SKILL_ROOT), ok=True)
                    except OSError as e:
                        ch.update(ok=False, error=str(e))
                        ok = False
                changes.append(ch)
    if mcp:
        m = d.get("mcp") or {}
        bin_ = find_bin(d, env)
        if m.get("args"):
            argv = [bin_ or d["bins"][0], *_fill(m["args"], vals)]
            exists = stale = False
            if m.get("check") and bin_:
                code, text = _run([bin_, *m["check"]], env, timeout=20)
                # registered, and with the command we'd write: an older entry (a bare `uv` that Windows can't start,
                # a moved skill) is written again
                exists = code == 0 and _names_all(text, _fill(m.get("current") or [], vals))
                stale = code == 0 and not exists
            registered = exists
            if exists:
                changes.append({"action": "exists", "argv": [bin_, *m["check"]]})
            else:
                ch = {"action": "run", "argv": argv}
                if stale:
                    ch["replaces"] = "stale"
                if not bin_:
                    ch.update(ok=False, error=f"{agent} is not installed")
                    ok = False
                elif not dry_run:
                    if stale and m.get("remove"):  # a CLI that won't add over an existing entry (claude)
                        _run([bin_, *m["remove"]], env)
                    code, text = _run(argv, env)
                    ch.update(ok=code == 0, exit=code, output=text[-2000:])
                    ok = ok and code == 0
                    registered = code == 0
                changes.append(ch)
            if m.get("approve") and bin_:
                ch = _codex_approvals(m["approve"], bin_, m.get("check"), env, dry_run, registered)
                ok = ok and ch.get("ok") is not False and ch["action"] != "error"
                changes.append(ch)
        elif m.get("json"):
            spec = m["json"]
            path = expand(spec["path"], env)
            value = _fill_obj(spec["value"], vals)
            try:
                text = path.read_text(encoding="utf-8-sig") if path.exists() else ""
                data = json.loads(text) if text.strip() else {}  # an empty file (Antigravity's) is no config yet
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
                            "command": [vals["uv"], "run", "--script", str(MCP_SERVER)]})
    return {"changes": changes, "applied": (not dry_run) and ok}


# ------------------------------------------------------------------ any other agent, by hand ("Other Agent…")
MANUAL_PROMPT = {
    "en": "Set up Blurt for yourself. The Blurt skill is the folder {skill} (SKILL.md is in it): link or copy it into "
          "your own skills folder under the name blurt. Then add an MCP server named blurt that runs {uv} with the "
          "arguments run --script {server}. When both are in place, call the blurt MCP tool hello to check the "
          "connection, and tell me what you changed.",
    "zh": "请为你自己装上口喷鸡（Blurt）。口喷鸡的 skill 是文件夹 {skill}（里面有 SKILL.md）：把它链接或复制到你自己的 skills "
          "文件夹，名字叫 blurt。再添加一个名为 blurt 的 MCP 服务器，命令是 {uv}，参数是 run --script {server}。两样都装好后，"
          "调用 blurt 的 MCP 工具 hello 检查连接，并告诉我你改了哪些设置。",
}


def manual(lang: str = "en", env: dict | None = None) -> dict:
    """What any agent needs to use Blurt, for the by-hand sheet: the skill folder, the MCP server as the common
    `mcpServers` JSON (real absolute paths, written by json.dumps: a Windows path's backslashes escaped), the same as a
    command and its arguments, and a prompt the user can paste so their agent sets itself up."""
    env = os.environ if env is None else env
    uv = uv_path(env)
    server = str(MCP_SERVER)
    args = ["run", "--script", server]
    L = "zh" if (lang or "").startswith("zh") else "en"
    return {"skill": str(SKILL_ROOT), "skill_ok": has_skill(SKILL_ROOT), "server": server, "command": uv, "args": args,
            "mcp_json": json.dumps({"mcpServers": {"blurt": {"command": uv, "args": args}}}, ensure_ascii=False, indent=2),
            "prompt": MANUAL_PROMPT[L].format(skill=str(SKILL_ROOT), uv=uv, server=server),
            "clients_file": str(mcp_clients_file())}


def zip_skill(out: str | Path) -> dict:
    """The skill folder as a .zip with `blurt/` at its top (for an agent that imports a skill from a file: WorkBuddy's
    技能 → 导入技能), without caches. → {"path"}"""
    import zipfile  # noqa: PLC0415
    out = Path(out).expanduser()
    if out.suffix.lower() != ".zip":
        out = out.with_suffix(".zip")
    if not has_skill(SKILL_ROOT):
        raise ValueError(f"no SKILL.md in {SKILL_ROOT}")
    out.parent.mkdir(parents=True, exist_ok=True)
    tmp = out.with_name(out.name + f".{os.getpid()}.tmp")
    with zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as z:
        for f in sorted(SKILL_ROOT.rglob("*")):
            rel = f.relative_to(SKILL_ROOT)
            if f.is_dir() or any(p in ("__pycache__", ".venv", "recorder", "models") for p in rel.parts) \
                    or f.suffix == ".pyc" or f.name == COPY_MARK:
                continue
            z.write(f, Path("blurt") / rel)
    os.replace(tmp, out)
    return {"path": str(out)}


def custom_id(name: str, taken) -> str:
    """A custom agent's id from its name: "My Agent" → "my-agent" (letters / digits kept, any script), unique."""
    base = re.sub(r"[^\w]+", "-", name.strip().lower()).strip("-_") or "agent"
    i, out = 2, base
    while out in taken:
        out, i = f"{base}-{i}", i + 1
    return out


def add_custom(name: str, home: str | None = None, app: dict | None = None, drop: str | None = None) -> dict:
    """"Other Agent…" → Save: an entry in config record.agent_defs (definitions() merges it): a connect-only agent
    (headless: false) with its name, and its config folder or app when given (app: {os: [id]}, drop: composer |
    terminal: a card-drag target too). → {"id", "def"}."""
    from _common import update_global_config  # noqa: PLC0415
    name = " ".join((name or "").split())
    if not name:
        raise ValueError("a name is needed")
    defs = definitions()
    d: dict = {"name": name, "bins": [], "headless": False, "custom": True}
    if home:
        d["home"] = home
    if app:
        d["app"] = {k: _as_list(v) for k, v in app.items() if k in ("macos", "windows", "linux")}
    if drop in ("composer", "terminal"):
        d["drop"] = drop
    # set up by hand (its home only says whether it is here): Blurt doesn't know where such an agent reads skills
    d["fix"] = {"zh": "按「其他 Agent…」里的步骤设置", "en": "set it up with the steps in Other Agent…"}
    aid = custom_id(name, defs)
    cur = (global_config().get("record") or {}).get("agent_defs") or {}  # the patch replaces record.agent_defs whole
    update_global_config({"record": {"agent_defs": {**cur, aid: d}}})
    return {"id": aid, "def": d}


def remove_custom(aid: str) -> bool:
    from _common import global_config, save_config_if_readable  # noqa: PLC0415
    rec = global_config().get("record") or {}
    cur = dict(rec.get("agent_defs") or {})
    if not (isinstance(cur.get(aid), dict) and cur[aid].get("custom")):
        return False
    cur.pop(aid)
    return save_config_if_readable({"record": {"agent_defs": cur or None}})


# ------------------------------------------------------------------ card drag targets (one list with the agents)
def drop_kind(defn: dict, osk: str) -> str | None:
    """agents.json `drop` for this OS: "composer" | "terminal" (a string for every OS, or {os: kind})."""
    v = defn.get("drop")
    v = v.get(osk) if isinstance(v, dict) else v
    return v if v in ("composer", "terminal") else None


def drop_targets(cfg: dict | None = None, osk: str | None = None) -> list[dict]:
    """The apps a card dragged in gets the picture's path and its note (CardDropTarget.swift, card_drop.rs read the
    same data): every agent with a `drop` for this OS — agents.json plus the user's record.agent_defs — and their app
    ids, minus the agents switched off (record.agent_drop.<id> = false). The legacy record.agent_apps (v1.0.21: app id
    → on / off) still counts until the list is next edited (migrate_agent_apps).
    → [{"agent", "name", "ids", "drop", "on", "custom"}]"""
    cfg = cfg if cfg is not None else global_config()
    osk = osk or os_key()
    rec = cfg.get("record") or {}
    off = {k for k, v in (rec.get("agent_drop") or {}).items() if v is False}
    legacy = {(k if osk == "macos" else k.lower()): v for k, v in (rec.get("agent_apps") or {}).items() if isinstance(v, bool)}
    out = []
    seen: set[str] = set()
    for d in definitions(cfg).values():
        kind = drop_kind(d, osk)
        ids = [i if osk == "macos" else i.lower() for i in app_ids(d, osk) if not is_path_id(i)]
        if not kind or not ids:
            continue
        on = d["id"] not in off and not any(legacy.get(i) is False for i in ids)
        out.append({"agent": d["id"], "name": d.get("name", d["id"]), "ids": ids, "drop": kind, "on": on,
                    "custom": bool(d.get("custom"))})
        seen.update(ids)
    for i, v in legacy.items():
        if v is True and i not in seen:
            out.append({"agent": i, "name": i, "ids": [i], "drop": "terminal", "on": True, "custom": True})
    return out


def migrate_agent_apps(cfg: dict, osk: str | None = None) -> dict:
    """record.agent_apps (v1.0.21) → the new shape, as a config patch: an app switched off → its agent in
    record.agent_drop = false; an app the user added → a custom agent (record.agent_defs) with that app id and
    drop "terminal". Pure: the caller writes the patch."""
    osk = osk or os_key()
    rec = cfg.get("record") or {}
    legacy = rec.get("agent_apps")
    if not isinstance(legacy, dict):
        return {}
    defs = definitions(cfg)
    by_app = {(i if osk == "macos" else i.lower()): d["id"] for d in defs.values() for i in app_ids(d, osk)}
    drop_off = dict(rec.get("agent_drop") or {})
    new_defs = {}
    for k, v in legacy.items():
        kk = k if osk == "macos" else k.lower()
        if v is False and kk in by_app:
            drop_off[by_app[kk]] = False
        elif v is True and kk not in by_app:
            aid = custom_id(kk.rsplit(".", 1)[-1], set(defs) | set(new_defs))
            new_defs[aid] = {"name": kk.rsplit(".", 1)[-1] if osk == "macos" else kk, "bins": [], "headless": False,
                             "custom": True, "connect": False, "app": {osk: [k]}, "drop": "terminal"}
    patch: dict = {"agent_apps": None}
    if drop_off:
        patch["agent_drop"] = drop_off
    if new_defs:  # the patch replaces record.agent_defs whole: the user's other definitions go with it
        patch["agent_defs"] = {**(rec.get("agent_defs") or {}), **new_defs}
    return {"record": patch}


WORK_PROMPT = {
    "en": "{title}\n\nRead {note} and handle the items in it. {rule} When you finish an item, call the blurt MCP tool "
          "mark_fixed with its uid (or, without the MCP, run the items.py command the note gives).",
    "zh": "{title}\n\n读 {note}，处理里面的事项。{rule}每做完一个，用它的 uid 调用 blurt MCP 工具 mark_fixed（没有 MCP 就运行交接单里给的 "
          "items.py 命令）。",
}
TITLE = {"en": {"one": "{id} · {title} (Blurt hand-off)", "id_only": "{id} (Blurt hand-off)",
                "many": "{n} items · {project} (Blurt hand-off)", "bare": "{n} items (Blurt hand-off)"},
         "zh": {"one": "{id} · {title}（口喷鸡交接）", "id_only": "{id}（口喷鸡交接）",
                "many": "{n} 个事项 · {project}（口喷鸡交接）", "bare": "{n} 个事项（口喷鸡交接）"}}
TITLE_MAX = 120


def _one_line(s) -> str:
    return " ".join(str(s or "").split())


def work_title(items: list[dict], project: str | None, lang: str = "en") -> str:
    """The first line of a hand-off prompt (what the agent's conversation list shows): "AW-12 · Login button does
    nothing (Blurt hand-off)"; several items: "3 items · Atlas Web (Blurt hand-off)". One line of at most TITLE_MAX chars:
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


def prompt_work(refs: list[str], handoff_id: str | None = None, lang: str | None = None,
                items: list[dict] | None = None, project_name: str | None = None) -> dict:
    """The short prompt that starts the user's own agent on some items: a title line first (work_title: what the
    agent's conversation list shows), then a pointer at their hand-off note (K6), written here unless handoff_id names
    one already. project_name None = looked up from the items' project."""
    import handoff
    lang = handoff.ui_lang(lang)
    h = handoff.describe(handoff_id) if handoff_id else handoff.create(refs, lang, items=items)
    its = list(items) if items is not None else []
    if not its:
        for u in h["items"]:
            try:
                its.append(handoff.item(u))
            except handoff.CliError:
                its.append({"uid": u})
    title = work_title(its, project_name if project_name is not None else _project_name(its), lang)
    rule = handoff.T[lang]["rule_external"]
    return {"prompt": WORK_PROMPT[lang].format(title=title, note=h["path"], rule=rule), "title": title,
            "handoff": h["id"], "path": h["path"], "items": h["items"], "full": h.get("full") or "", "rule": rule,
            "lang": lang}


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
    s.add_argument("--fresh", action="store_true", help="look for the agents' apps again (else kept 10 min)")
    s = sub.add_parser("manual")
    s.add_argument("--lang", default=lang)
    s = sub.add_parser("custom")
    s.add_argument("name", nargs="?")
    s.add_argument("--home")
    s.add_argument("--remove", metavar="ID")
    s = sub.add_parser("drop")
    s.add_argument("--os", choices=["macos", "windows", "linux"])
    s = sub.add_parser("zip-skill")
    s.add_argument("out")
    s = sub.add_parser("command")
    s.add_argument("id")
    s.add_argument("mode", choices=["headless"])
    g = s.add_mutually_exclusive_group(required=True)
    g.add_argument("--prompt")
    g.add_argument("--prompt-file")
    s.add_argument("--repo", required=True)
    s.add_argument("--var", action="append", default=[], metavar="K=V", help="placeholder values; run_id → $BLURT_RUN_ID")
    s.add_argument("--no-events", action="store_true", help="plain output instead of the stream-json flags")
    s.add_argument("--no-mcp", action="store_true", help="leave out the headless_mcp args (blurt MCP server)")
    s.add_argument("--processing", nargs="?", const="cards", choices=KINDS,
                   help="an unattended organising run: processing model + usage (recording | cards, the default)")
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
    s.add_argument("--mode", choices=["external"], default="external", help="(the only one; accepted for old callers)")
    s.add_argument("--handoff", help="an existing hand-off note (H-0012) instead of writing one")
    s.add_argument("--lang", choices=["en", "zh", "zh-Hans"])
    a = p.parse_args()
    try:
        if a.cmd == "detect":
            _emit(detect(a.ids.split(",") if a.ids else None, login=not a.no_login, version=not a.no_version,
                         repo=a.repo, lang=a.lang, fresh=a.fresh))
            return
        if a.cmd == "manual":
            _emit({"ok": True, **manual(a.lang)})
            return
        if a.cmd == "custom":
            if a.remove:
                _emit({"ok": remove_custom(a.remove)})
            else:
                _emit({"ok": True, **add_custom(a.name or "", a.home)})
            return
        if a.cmd == "zip-skill":
            _emit({"ok": True, **zip_skill(a.out)})
            return
        if a.cmd == "drop":
            _emit({"ok": True, "os": a.os or os_key(), "targets": drop_targets(osk=a.os)})
            return
        if a.cmd == "command":
            prompt = a.prompt if a.prompt is not None else Path(a.prompt_file).read_text(encoding="utf-8")
            vars = dict(kv.partition("=")[::2] for kv in a.var)
            _emit(command(a.id, a.mode, prompt, a.repo, vars, events=not a.no_events, mcp=not a.no_mcp,
                          processing_run=a.processing or False))
            return
        if a.cmd == "models":
            cfg = config()
            ps = {k: processing(a.id, cfg, kind=k) for k in KINDS}
            _emit({"ok": True, **models(a.id, cfg),
                   "processing": {"model": ps["cards"]["model"], "effort": ps["cards"]["effort"],
                                  **{k: {"model": v["model"], "effort": v["effort"]} for k, v in ps.items()}}})
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
            pw = prompt_work(a.items, a.handoff, a.lang)
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
