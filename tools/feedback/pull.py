#!/usr/bin/env python3
"""Bring the feedback reports home (docs/design/feedback.md §On the developer's Mac): list the reports on the service,
download each, unpack it to ~/BlurtFeedback/<id>/, add its dictations to the Dictation Lab
(`dictation_lab.py import-feedback DIR`), and delete the report from the service once that worked. A report whose
parts never all arrived is deleted once it is an hour old (the sender was told it failed).

  pull.py [--dry-run] [--keep-remote] [--dest DIR]
        --dry-run      list what is there; download, import and delete nothing
        --keep-remote  import, but leave the reports on the service
        --dest         where the reports are unpacked (default ~/BlurtFeedback)
  pull.py init [--force]
        make the admin token: ~/.config/blurt-feedback/admin.env (mode 600), then print the command that gives it to
        the Worker (the value goes from the file to wrangler through a pipe, never on screen)

Settings: ~/.config/blurt-feedback/admin.env (BLURT_FEEDBACK_URL, BLURT_FEEDBACK_ADMIN_TOKEN); the same names in the
environment win (a local `wrangler dev`). BLURT_FEEDBACK_ADMIN_ENV points at another file. The token is never printed.
Stdlib only.
"""
from __future__ import annotations

import argparse
import json
import os
import secrets
import shutil
import stat
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from datetime import datetime, timedelta, timezone
from pathlib import Path, PurePosixPath

ROOT = Path(__file__).resolve().parents[2]
LAB = ROOT / "skills" / "blurt" / "scripts" / "dictation_lab.py"
DEFAULT_URL = "https://blurt-feedback.agihunt.info"
MAX_UNPACKED = 2 * 1024**3          # a 100 MB zip that unpacks past this is not one of ours
ID_CHARS = set("abcdefghijklmnopqrstuvwxyz234567")
STALE = timedelta(hours=1)          # an upload not complete after this long was given up


def _when(iso) -> datetime:
    try:
        t = datetime.fromisoformat(str(iso).replace("Z", "+00:00"))
        return t if t.tzinfo else t.replace(tzinfo=timezone.utc)
    except ValueError:
        return datetime.fromtimestamp(0, timezone.utc)


class Fail(Exception):
    pass


def env_file() -> Path:
    return Path(os.environ.get("BLURT_FEEDBACK_ADMIN_ENV") or Path.home() / ".config" / "blurt-feedback" / "admin.env")


def read_env(path: Path) -> dict:
    out = {}
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return out
    for ln in lines:
        ln = ln.strip()
        if not ln or ln.startswith("#") or "=" not in ln:
            continue
        k, _, v = ln.removeprefix("export ").partition("=")
        out[k.strip()] = v.strip().strip("'\"")
    return out


def settings() -> tuple[str, str]:
    f = read_env(env_file())
    url = os.environ.get("BLURT_FEEDBACK_URL") or f.get("BLURT_FEEDBACK_URL") or DEFAULT_URL
    token = os.environ.get("BLURT_FEEDBACK_ADMIN_TOKEN") or f.get("BLURT_FEEDBACK_ADMIN_TOKEN")
    if not token:
        raise Fail(f"no BLURT_FEEDBACK_ADMIN_TOKEN (in {env_file()} or the environment): run `pull.py init` first")
    return url.rstrip("/"), token


# ------------------------------------------------------------------ the service
def _certs() -> None:
    try:
        import truststore  # the OS's trust store when it's there; Python's own otherwise
        truststore.inject_into_ssl()
    except ImportError:
        pass


def request(url: str, token: str, method: str = "GET", timeout: float = 60):
    req = urllib.request.Request(url, method=method, headers={"Authorization": f"Bearer {token}",
                                                              "User-Agent": "blurt-feedback-pull"})
    try:
        return urllib.request.urlopen(req, timeout=timeout)
    except urllib.error.HTTPError as e:
        hint = " (the token doesn't match the Worker's ADMIN_TOKEN)" if e.code == 401 else ""
        raise Fail(f"{method} {urllib.parse.urlsplit(url).path}: HTTP {e.code}{hint}") from None
    except (urllib.error.URLError, OSError) as e:
        raise Fail(f"{method} {url}: {getattr(e, 'reason', e)}") from None


def list_reports(base: str, token: str) -> list[dict]:
    out, cursor = [], None
    while True:
        q = "?limit=1000" + (f"&cursor={urllib.parse.quote(cursor)}" if cursor else "")
        with request(f"{base}/v1/admin/reports{q}", token) as r:
            page = json.loads(r.read())
        out += page.get("reports") or []
        cursor = page.get("cursor")
        if not cursor:
            return out


def download(base: str, token: str, rid: str, to: Path) -> int:
    n = 0
    with request(f"{base}/v1/admin/reports/{rid}", token, timeout=120) as r, open(to, "wb") as f:
        while chunk := r.read(1 << 20):
            f.write(chunk)
            n += len(chunk)
    return n


def delete(base: str, token: str, rid: str) -> None:
    with request(f"{base}/v1/admin/reports/{rid}", token, method="DELETE") as r:
        r.read()


# ------------------------------------------------------------------ unpacking
def safe_members(z: zipfile.ZipFile) -> list[zipfile.ZipInfo]:
    """The zip's members, refused as a whole if any would land outside the folder (absolute, .., a drive, a
    backslash path), is a link, or the whole unpacks past MAX_UNPACKED: the zip came from a stranger."""
    total = 0
    for m in z.infolist():
        name = m.filename
        p = PurePosixPath(name)
        if (not name or "\\" in name or p.is_absolute() or ".." in p.parts or ":" in p.parts[0]
                or stat.S_ISLNK(m.external_attr >> 16)):
            raise Fail(f"unsafe path in the zip: {name!r}")
        total += m.file_size
    if total > MAX_UNPACKED:
        raise Fail(f"the zip unpacks to {total} bytes")
    return z.infolist()


def unpack(zpath: Path, dest: Path) -> None:
    tmp = dest.with_name(dest.name + ".part")
    shutil.rmtree(tmp, ignore_errors=True)
    tmp.mkdir(parents=True)
    root = tmp.resolve()
    try:
        with zipfile.ZipFile(zpath) as z:
            for m in safe_members(z):
                out = (root / m.filename).resolve()
                if not out.is_relative_to(root):          # belt and braces after safe_members
                    raise Fail(f"unsafe path in the zip: {m.filename!r}")
                if m.is_dir():
                    out.mkdir(parents=True, exist_ok=True)
                    continue
                out.parent.mkdir(parents=True, exist_ok=True)
                with z.open(m) as src, open(out, "wb") as f:
                    shutil.copyfileobj(src, f, 1 << 20)
    except (zipfile.BadZipFile, OSError) as e:
        shutil.rmtree(tmp, ignore_errors=True)
        raise Fail(f"could not unpack: {e}") from None
    except Fail:
        shutil.rmtree(tmp, ignore_errors=True)
        raise
    shutil.rmtree(dest, ignore_errors=True)
    tmp.rename(dest)


def import_lab(d: Path, rid: str) -> dict:
    r = subprocess.run([sys.executable, str(LAB), "import-feedback", str(d), "--report", rid],
                       capture_output=True, text=True)
    for ln in reversed(r.stdout.strip().splitlines()):
        try:
            o = json.loads(ln)
        except ValueError:
            continue
        if isinstance(o, dict):
            return o
    return {"ok": False, "error": (r.stderr.strip().splitlines() or ["no answer"])[-1]}


# ------------------------------------------------------------------ commands
def pull(dest: Path, dry_run: bool, keep_remote: bool) -> int:
    base, token = settings()
    _certs()
    reports = list_reports(base, token)
    print(f"{len(reports)} report(s) at {base}")
    failed = 0
    now = datetime.now(timezone.utc)
    for rep in reports:
        rid = str(rep.get("id") or "")
        meta = rep.get("meta") or {}
        line = (f"  {rid}  {rep.get('size', 0) / 1e6:.1f} MB  {rep.get('uploaded')}  "
                f"{meta.get('platform', '?')} {meta.get('version', '?')}, {meta.get('takes', '?')} take(s)")
        if len(rid) != 26 or not set(rid) <= ID_CHARS:
            print(line + "  skipped: not a report id")
            failed += 1
            continue
        if not rep.get("complete"):
            # a send that stopped half way: the app said it failed, so nobody waits for it
            age = now - _when(rep.get("uploaded"))
            line += f"  incomplete ({rep.get('done', '?')}/{rep.get('parts', '?')} parts)"
            if age < STALE:
                print(line + "; still arriving, left for now")
            elif dry_run:
                print(line + "; would be deleted")
            else:
                try:
                    delete(base, token, rid)
                    print(line + "; over an hour old, deleted")
                except Fail as e:
                    print(line + f"; delete failed: {e}")
                    failed += 1
            continue
        if dry_run:
            print(line)
            continue
        dest.mkdir(parents=True, exist_ok=True)
        zpath = dest / f".{rid}.zip.part"
        try:
            download(base, token, rid, zpath)
            unpack(zpath, dest / rid)
        except Fail as e:
            print(line + f"  failed: {e}")
            failed += 1
            continue
        finally:
            zpath.unlink(missing_ok=True)
        r = import_lab(dest / rid, rid)
        if not r.get("ok"):
            print(line + f"  import failed ({r.get('code', 'error')}): {r.get('error')}; kept on the service")
            failed += 1
            continue
        line += f"  → {len(r.get('imported') or [])} case(s)"
        if r.get("skipped"):
            line += f", {len(r['skipped'])} skipped"
        if keep_remote:
            print(line + "; kept on the service")
            continue
        try:
            delete(base, token, rid)
            print(line + "; deleted from the service")
        except Fail as e:
            print(line + f"; delete failed: {e}")
            failed += 1
    return 1 if failed else 0


def init(force: bool) -> int:
    f = env_file()
    if f.exists() and not force:
        print(f"{f} exists; `pull.py init --force` makes a new token (then put it in the Worker again)")
        return 1
    f.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(f.parent, 0o700)
    url = read_env(f).get("BLURT_FEEDBACK_URL") or DEFAULT_URL
    tmp = f.with_name(f.name + ".tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(f"BLURT_FEEDBACK_URL={url}\nBLURT_FEEDBACK_ADMIN_TOKEN={secrets.token_urlsafe(32)}\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, f)
    worker = Path(__file__).resolve().parent / "worker"
    print(f"wrote {f} (mode 600). Give the token to the Worker:\n")
    print(f"  cd {worker}")
    print(f"  sh -c '. \"{f}\" && printf %s \"$BLURT_FEEDBACK_ADMIN_TOKEN\"' | npx wrangler@4 secret put ADMIN_TOKEN")
    return 0


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="pull.py", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("cmd", nargs="?", choices=["pull", "init"], default="pull")
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--keep-remote", action="store_true")
    p.add_argument("--dest", default=str(Path.home() / "BlurtFeedback"))
    p.add_argument("--force", action="store_true", help="init: replace an existing admin.env")
    a = p.parse_args(argv)
    try:
        if a.cmd == "init":
            return init(a.force)
        return pull(Path(a.dest).expanduser(), a.dry_run, a.keep_remote)
    except Fail as e:
        print(f"error: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
