# /// script
# requires-python = ">=3.10"
# ///
"""Export a session's issues to a Feishu / Lark Bitable (多维表格).

Two backends, picked automatically (override with --via):
  lark-cli  official CLI, user identity (`lark-cli auth login`); nothing else to configure.      [preferred]
  openapi   self-built app: env FEISHU_APP_ID + FEISHU_APP_SECRET (optional FEISHU_DOMAIN=open.larksuite.com),
            or ~/.blurt/config.json {"feishu": {...}}. Scopes bitable:app + drive:drive (+ wiki:wiki:readonly);
            the app must be added to the base (··· → 更多 → 添加文档应用).

  feishu.py fields  URL                                     list columns (plan a mapping)
  feishu.py export  SESSION_DIR URL [--map JSON] [--dry-run]
  feishu.py create  "Base name" [--table 问题清单] [--lang zh]  new base + table with default columns; prints URL

URL: https://xxx.feishu.cn/base/<base_token>?table=<table_id>  (wiki-hosted bases: openapi backend)
--map: JSON file or inline JSON {"<issue key>": "<column>"}; several keys may share a column (joined with labels).
Issue keys: id title module owner severity type actual expected steps time quote frames clip code_refs questions.
Missing columns are created (attachment for frames/clip, text otherwise). Issues already exported are skipped.
"""
from __future__ import annotations

import argparse
import io
import json
import mimetypes
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path
from urllib.parse import parse_qs, urlparse

sys.path.insert(0, str(Path(__file__).parent))
from _common import die, fmt_ts, global_config, live_items, load_session, save_session  # noqa: E402
from export_local import LABELS  # noqa: E402

ATTACH_KEYS = {"frames", "clip"}


def parse_url(url: str) -> tuple[str, str, str | None]:
    u = urlparse(url)
    m = re.search(r"/(base|wiki)/([A-Za-z0-9]+)", u.path)
    if not m:
        die("URL must look like https://xxx.feishu.cn/base/<token>?table=<table_id> (open the table, copy the URL)")
    return m.group(1), m.group(2), (parse_qs(u.query).get("table") or [None])[0]


# ------------------------------------------------------------------ lark-cli backend
class LarkCli:
    name = "lark-cli"

    def _run(self, *args, cwd=None, soft=False) -> dict | None:
        exe = shutil.which("lark-cli")
        r = subprocess.run([exe, "base", *args], capture_output=True, text=True, encoding="utf-8", cwd=cwd)
        try:
            out = json.loads(r.stdout)
        except json.JSONDecodeError:
            die(f"lark-cli {args[0]} failed: {(r.stderr or r.stdout)[-800:]}")
        if not out.get("ok") and soft:
            return None
        if not out.get("ok"):
            die(f"lark-cli {args[0]} failed: {json.dumps(out.get('error') or out, ensure_ascii=False)[:800]}\n"
                "If it's an auth error: run `lark-cli auth login` (the user does this).")
        return out.get("data") or {}

    def resolve(self, url):
        kind, token, table = parse_url(url)
        if kind == "wiki":
            die("wiki-hosted base: open it via its /base/ URL, or use --via openapi")
        if not table:
            tables = self._run("+table-list", "--base-token", token).get("items") or []
            if not tables:
                die("base has no tables")
            table = tables[0]["table_id"]
        return token, table

    def fields(self, base, table):
        items = self._run("+field-list", "--base-token", base, "--table-id", table).get("items") or []
        return [{"name": f["field_name"], "kind": "attachment" if f["type"] == "attachment" else f["type"]} for f in items]

    def add_field(self, base, table, name, kind):
        self._run("+field-create", "--base-token", base, "--table-id", table,
                  "--json", json.dumps({"name": name, "type": kind}, ensure_ascii=False))

    def create_record(self, base, table, fields):
        d = self._run("+record-upsert", "--base-token", base, "--table-id", table,
                      "--json", json.dumps(fields, ensure_ascii=False))
        rid = d.get("record_id") or (d.get("record") or {}).get("record_id") or _find_record_id(d)
        if not rid:
            die(f"could not read record id from lark-cli output: {json.dumps(d, ensure_ascii=False)[:400]}")
        return rid

    def _cell(self, base, table, record_id, field) -> list[dict]:
        for _ in range(15):  # a just-created record can 404 for a few seconds (eventual consistency)
            d = self._run("+record-get", "--base-token", base, "--table-id", table, "--record-id", record_id, soft=True)
            if d is not None:
                rec = d["record"]
                return [{"file_token": a["file_token"], "name": a["name"]} for a in (rec.get(field) or [])]
            time.sleep(1)
        die(f"record {record_id} not readable after 15s")

    def attach(self, base, table, record_id, field, paths):
        # +record-upload-attachment (v1.0) replaces the cell, so upload one by one, collect the file tokens,
        # then write the full list back in one upsert.
        collected = self._cell(base, table, record_id, field)
        for p in paths:  # lark-cli only accepts paths relative to its cwd
            p = Path(p).resolve()
            known = {a["file_token"] for a in collected}
            args = ("+record-upload-attachment", "--base-token", base, "--table-id", table,
                    "--record-id", record_id, "--field-id", field, "--file", f"./{p.name}")
            for attempt in range(8):  # the record may not be readable yet right after creation
                if self._run(*args, cwd=p.parent, soft=attempt < 7) is not None:
                    break
                time.sleep(1.5)
            for _ in range(10):  # reads are eventually consistent: wait until the new token shows up
                new = [a for a in self._cell(base, table, record_id, field) if a["file_token"] not in known]
                if new:
                    collected += new
                    break
                time.sleep(1)
        if len(collected) > 1:
            self._run("+record-upsert", "--base-token", base, "--table-id", table, "--record-id", record_id,
                      "--json", json.dumps({field: collected}, ensure_ascii=False))

    def create_base(self, name, table, columns):
        base = self._run("+base-create", "--name", name)["base"]
        fields = [{"name": c, "type": k} for c, k in columns]
        self._run("+table-create", "--base-token", base["base_token"], "--name", table,
                  "--fields", json.dumps(fields, ensure_ascii=False))
        tables = self._run("+table-list", "--base-token", base["base_token"]).get("items") or []
        tid = next((t["table_id"] for t in tables if t["table_name"] == table), tables[-1]["table_id"])
        return f"{base['url']}?table={tid}"


def _find_record_id(d):
    if isinstance(d, dict):
        for k, v in d.items():
            if k in ("record_id", "id") and isinstance(v, str) and v.startswith("rec"):
                return v
            if k in ("record_id_list", "record_ids") and isinstance(v, list) and v:
                return v[0]
            if (r := _find_record_id(v)):
                return r
    if isinstance(d, list):
        for v in d:
            if (r := _find_record_id(v)):
                return r
    return None


# ------------------------------------------------------------------ OpenAPI backend
class OpenAPI:
    name = "openapi"
    TYPES = {"text": 1, "attachment": 17}

    def __init__(self):
        cfg = global_config().get("feishu", {})
        self.app_id = os.environ.get("FEISHU_APP_ID") or cfg.get("app_id")
        self.secret = os.environ.get("FEISHU_APP_SECRET") or cfg.get("app_secret")
        self.base = "https://" + (os.environ.get("FEISHU_DOMAIN") or cfg.get("domain") or "open.feishu.cn")
        if not (self.app_id and self.secret):
            die("No lark-cli and no FEISHU_APP_ID / FEISHU_APP_SECRET. Install lark-cli "
                "(npx @larksuite/cli@latest install) or configure an app (see reference/export-feishu.md).")
        self.token = self._req("POST", "/open-apis/auth/v3/tenant_access_token/internal",
                               {"app_id": self.app_id, "app_secret": self.secret}, auth=False)["tenant_access_token"]

    def _req(self, method, path, body=None, auth=True, raw=None, ctype="application/json"):
        headers = {"Content-Type": ctype}
        if auth:
            headers["Authorization"] = f"Bearer {self.token}"
        data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
        res = {}
        for attempt in range(4):
            try:
                req = urllib.request.Request(self.base + path, data=data, headers=headers, method=method)
                with urllib.request.urlopen(req, timeout=60) as r:
                    res = json.loads(r.read())
                break
            except urllib.error.HTTPError as e:
                res = json.loads(e.read() or b"{}") if e.code < 500 else {"code": e.code, "msg": str(e)}
                if e.code in (429, 500, 502, 503) and attempt < 3:
                    time.sleep(2 ** attempt)
                    continue
                break
        if res.get("code", 0) != 0 or "tenant_access_token" in path and "tenant_access_token" not in res:
            die(f"Feishu API {path} failed: code={res.get('code')} msg={res.get('msg')}\n"
                "Common causes: app not added to the base (添加文档应用), missing scopes, wrong URL/credentials.")
        return res.get("data", res)

    def resolve(self, url):
        kind, token, table = parse_url(url)
        if kind == "wiki":
            token = self._req("GET", f"/open-apis/wiki/v2/spaces/get_node?token={token}")["node"]["obj_token"]
        if not table:
            table = self._req("GET", f"/open-apis/bitable/v1/apps/{token}/tables")["items"][0]["table_id"]
        return token, table

    def fields(self, app, table):
        items, page = [], ""
        while True:
            d = self._req("GET", f"/open-apis/bitable/v1/apps/{app}/tables/{table}/fields?page_size=100{page}")
            items += d.get("items") or []
            if not d.get("has_more"):
                break
            page = f"&page_token={d['page_token']}"
        return [{"name": f["field_name"], "kind": "attachment" if f["type"] == 17 else "text" if f["type"] == 1
                 else str(f["type"])} for f in items]

    def add_field(self, app, table, name, kind):
        self._req("POST", f"/open-apis/bitable/v1/apps/{app}/tables/{table}/fields",
                  {"field_name": name, "type": self.TYPES[kind]})

    def create_record(self, app, table, fields):
        return self._req("POST", f"/open-apis/bitable/v1/apps/{app}/tables/{table}/records",
                         {"fields": fields})["record"]["record_id"]

    def attach(self, app, table, record_id, field, paths):
        toks = [{"file_token": self._upload(app, p)} for p in paths]
        self._req("PUT", f"/open-apis/bitable/v1/apps/{app}/tables/{table}/records/{record_id}", {"fields": {field: toks}})

    def _upload(self, app, path: Path) -> str:
        size = path.stat().st_size
        if size > 20 * 2**20:
            die(f"{path} is over 20MB; shorten/compress the clip")
        is_img = (mimetypes.guess_type(path.name)[0] or "").startswith("image/")
        fields = {"file_name": path.name, "parent_type": "bitable_image" if is_img else "bitable_file",
                  "parent_node": app, "size": str(size)}
        b = uuid.uuid4().hex
        buf = io.BytesIO()
        for k, v in fields.items():
            buf.write(f'--{b}\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n{v}\r\n'.encode())
        buf.write(f'--{b}\r\nContent-Disposition: form-data; name="file"; filename="{path.name}"\r\n'
                  f'Content-Type: application/octet-stream\r\n\r\n'.encode())
        buf.write(path.read_bytes())
        buf.write(f"\r\n--{b}--\r\n".encode())
        return self._req("POST", "/open-apis/drive/v1/medias/upload_all", raw=buf.getvalue(),
                         ctype=f"multipart/form-data; boundary={b}")["file_token"]

    def create_base(self, name, table, columns):
        app = self._req("POST", "/open-apis/bitable/v1/apps", {"name": name})["app"]
        t = self._req("POST", f"/open-apis/bitable/v1/apps/{app['app_token']}/tables",
                      {"table": {"name": table, "fields": [{"field_name": c, "type": self.TYPES[k]} for c, k in columns]}})
        return f"{app['url']}?table={t['table_id']}"


# ------------------------------------------------------------------ mapping
def default_map(lang: str, kind: str = "issue") -> dict:
    if kind == "idea":
        if lang == "zh":
            return {"title": "想法", "summary": "概述", "why": "为什么", "inspired_by": "灵感来源", "next_steps": "下一步",
                    "frames": "截图", "clip": "截图", "tags": "标签", "quote": "原话", "time": "录屏时间点", "id": "编号"}
        return {"title": "Idea", "summary": "Summary", "why": "Why", "inspired_by": "Inspired by", "next_steps": "Next steps",
                "frames": "Screenshots", "clip": "Screenshots", "tags": "Tags", "quote": "Quote", "time": "Time", "id": "ID"}
    if kind != "issue":
        L = LABELS[lang]
        return {"title": L["title"], "summary": L["summary"], "details": L["details"], "owner": L["owner"], "due": L["due"],
                "tags": L["tags"], "frames": L["frames"], "quote": L["quote"], "time": L["time"], "id": L["id"]}
    if lang == "zh":  # the classic bug-sheet header
        return {"title": "异常描述", "module": "所属模块", "expected": "预期效果与实际效果", "actual": "预期效果与实际效果",
                "steps": "复现步骤", "frames": "截图或视频", "clip": "截图或视频", "owner": "对应 owner",
                "severity": "严重程度", "time": "录屏时间点", "quote": "原话", "code_refs": "疑似代码位置", "id": "编号"}
    L = LABELS["en"]
    return {"title": L["title"], "module": L["module"], "expected": "Expected vs actual", "actual": "Expected vs actual",
            "steps": L["steps"], "frames": "Screenshots / video", "clip": "Screenshots / video", "owner": L["owner"],
            "severity": L["severity"], "time": L["time"], "quote": L["quote"], "code_refs": L["code_refs"], "id": L["id"]}


def text_value(issue: dict, key: str) -> str:
    v = issue.get(key)
    if key == "steps":
        return "\n".join(f"{n}. {s}" for n, s in enumerate(v or [], 1))
    if key == "time":
        return f"{fmt_ts(v.get('start', 0))}–{fmt_ts(v.get('end', 0))}" if v else ""
    if isinstance(v, list):
        return "\n".join(map(str, v))
    return "" if v is None else str(v)


def columns_of(mapping: dict) -> dict[str, list[str]]:
    cols: dict[str, list[str]] = {}
    for key, col in mapping.items():
        cols.setdefault(col, []).append(key)
    return cols


def pick_backend(via: str | None):
    if via == "openapi" or (via is None and not shutil.which("lark-cli")):
        return OpenAPI()
    if not shutil.which("lark-cli"):
        die("lark-cli not found. Install: npx @larksuite/cli@latest install; then lark-cli config init && lark-cli auth login")
    return LarkCli()


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--via", choices=["lark-cli", "openapi"])
    sub = p.add_subparsers(dest="cmd", required=True)
    f = sub.add_parser("fields")
    f.add_argument("url")
    e = sub.add_parser("export")
    e.add_argument("session")
    e.add_argument("url")
    e.add_argument("--map", help="JSON file or inline JSON mapping issue keys → column names")
    e.add_argument("--dry-run", action="store_true")
    e.add_argument("--kind", default="issue", help="which items to export: issue (default) | idea | note | task | <lens>")
    c = sub.add_parser("create")
    c.add_argument("name")
    c.add_argument("--table", default=None)
    c.add_argument("--lang", default="zh")
    a = p.parse_args()
    be = pick_backend(a.via)

    if a.cmd == "create":
        cols = columns_of(default_map(a.lang))
        spec = [(col, "attachment" if set(keys) & ATTACH_KEYS else "text") for col, keys in cols.items()]
        spec.sort(key=lambda x: x[0] != default_map(a.lang)["title"])  # title column first = primary field
        url = be.create_base(a.name, a.table or ("问题清单" if a.lang == "zh" else "Issues"), spec)
        print(json.dumps({"url": url, "backend": be.name}, ensure_ascii=False))
        return

    base, table = be.resolve(a.url)
    if a.cmd == "fields":
        print(json.dumps(be.fields(base, table), ensure_ascii=False, indent=2))
        return

    session = Path(a.session)
    data = load_session(session) or die("no items.json in this session")
    lang = "zh" if str(data.get("language", "")).startswith("zh") else "en"
    mapping = default_map(lang, a.kind)
    if a.map:
        mapping = json.loads(Path(a.map).read_text(encoding="utf-8") if Path(a.map).exists() else a.map)
    L = LABELS[lang]
    cols = columns_of(mapping)
    existing = {x["name"]: x["kind"] for x in be.fields(base, table)}
    missing = {col: ("attachment" if set(keys) & ATTACH_KEYS else "text") for col, keys in cols.items()
               if col not in existing}
    todo = [i for i in live_items(data, a.kind) if not (i.get("exported") or {}).get("feishu_done")]
    if a.dry_run:
        print(json.dumps({"backend": be.name, "base": base, "table": table, "will_create_columns": missing,
                          "items": len(todo), "mapping": mapping}, ensure_ascii=False, indent=2))
        return
    for col, kind in missing.items():
        be.add_field(base, table, col, kind)
        existing[col] = kind

    done = 0
    for i in todo:
        rec, files = {}, {}
        for col, keys in cols.items():
            if existing.get(col) == "attachment":
                paths = [session / fr["path"] for fr in i.get("frames", [])] if "frames" in keys else []
                if "clip" in keys and i.get("clip"):
                    paths.append(session / i["clip"])
                if paths := [pth for pth in paths if pth.exists()]:
                    files[col] = paths
                continue
            parts = [(k, text_value(i, k)) for k in keys if k not in ATTACH_KEYS]
            parts = [(k, v) for k, v in parts if v]
            if parts:
                rec[col] = parts[0][1] if len(parts) == 1 else "\n".join(f"{L.get(k, k)}：{v}" for k, v in parts)
        exp = i.setdefault("exported", {})
        rid = exp.get("feishu")  # record created on an earlier, interrupted run -> only attach
        if not rid:
            rid = exp["feishu"] = be.create_record(base, table, rec)
            save_session(session, data)  # save as we go: a rerun never duplicates
        for col, paths in files.items():
            be.attach(base, table, rid, col, paths)
        exp["feishu_done"] = True
        save_session(session, data)
        done += 1
        print(f"  {i.get('id')} → {rid}", file=sys.stderr, flush=True)
    print(json.dumps({"backend": be.name, "exported": done, "created_columns": list(missing), "url": a.url},
                     ensure_ascii=False))


if __name__ == "__main__":
    main()
