#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["cryptography>=42"]
# ///
"""Windows/Linux in-app updates for a release: sign the installers, write the Tauri feeds, check every signature.

    scripts/release-desktop-update.py 1.0.20 DIR [--notes "…"] [--out OUT] [--publish]

DIR holds the release's installers (desktop.yml's installers-windows / installers-linux artifacts): Blurt_*_x64-setup.exe,
*.msi, *.AppImage, *.deb, *.rpm — whichever are there. Writes:

  DIR/<installer>.sig          signature per installer (tauri signer, minisign)
  DIR/latest.json              the GitHub feed: attach it and the .sig files to the release (GITHUB_FEED in housekeeping.rs)
  OUT/desktop/latest.json      the mainland copy, served as https://dl.blurt.work/desktop/latest.json (tauri.conf.json's
  OUT/desktop/<installer>      endpoint) with the installers small enough for Cloudflare Pages (25 MiB a file) beside it;
                               the bigger ones (the AppImage) stay on GitHub

--publish uploads both: `gh release upload v<version>` and `wrangler pages deploy OUT --project-name blurt-dl`.

Once, before the first --publish: `scripts/release-desktop-update.py --setup-mirror` (with ~/.cloudflare_credentials
sourced) creates the Pages project blurt-dl, its custom domain dl.blurt.work and the CNAME in the blurt.work zone. It is
its own project so that deploying the homepage (site/, project blurt) never removes the feed. Until it exists the app
just falls back to the GitHub feed (unreachable from much of the mainland).

Keys: ~/.config/blurt-updater/tauri-updater.key + password (also in the login keychain, "Blurt Tauri updater key" and
"Blurt Tauri updater key password", account blurt-updater). The public half is plugins.updater.pubkey in tauri.conf.json;
an app only installs what that key signed, so losing the private key means one more manual install for everyone.
Platform keys are the updater's own ({os}-{arch}-{installer} first, then {os}-{arch}): an MSI install never gets the NSIS
installer, a .deb install never gets the AppImage.
"""
from __future__ import annotations

import argparse
import base64
import datetime as dt
import hashlib
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CONF = ROOT / "apps/desktop/src-tauri/tauri.conf.json"
KEYS = Path(os.environ.get("BLURT_UPDATER_KEYS", Path.home() / ".config/blurt-updater"))
TAURI_CLI = "@tauri-apps/cli@2.12.3"
GITHUB = "https://github.com/AGIHunt/blurt/releases/download"
MIRROR = "https://dl.blurt.work/desktop"
PAGES_LIMIT = 25 * 1024 * 1024

# file suffix → the platform keys it serves (the bare {os}-{arch} key is the fallback for builds that don't say how they
# were installed: only the default installer of each OS takes it)
KINDS = [
    ("-setup.exe", ["windows-x86_64-nsis", "windows-x86_64"]),
    (".msi", ["windows-x86_64-msi"]),
    (".AppImage", ["linux-x86_64-appimage", "linux-x86_64"]),
    (".deb", ["linux-x86_64-deb"]),
    (".rpm", ["linux-x86_64-rpm"]),
]


def secret(name: str, keychain: str) -> str:
    f = KEYS / name
    if f.exists():
        return f.read_text().strip()
    r = subprocess.run(["security", "find-generic-password", "-a", "blurt-updater", "-s", keychain, "-w"],
                       capture_output=True, text=True)
    if r.returncode:
        sys.exit(f"no updater key: {f} missing and not in the keychain ({keychain})")
    return r.stdout.strip()


def sign(f: Path, key: str, password: str) -> str:
    env = {**os.environ, "TAURI_SIGNING_PRIVATE_KEY": key, "TAURI_SIGNING_PRIVATE_KEY_PASSWORD": password}
    subprocess.run(["npx", "-y", TAURI_CLI, "signer", "sign", str(f)], env=env, check=True, capture_output=True)
    return Path(f"{f}.sig").read_text().strip()


def verify(f: Path, sig_b64: str, pub_b64: str) -> None:
    """What the app does before it installs: minisign (Ed25519 over BLAKE2b-512 of the file) against the shipped key."""
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

    pub = base64.b64decode(base64.b64decode(pub_b64).decode().splitlines()[1])
    lines = base64.b64decode(sig_b64).decode().splitlines()
    sig = base64.b64decode(lines[1])
    assert sig[:2] == b"ED" and pub[:2] == b"Ed" and sig[2:10] == pub[2:10], f"{f.name}: signed with another key"
    h = hashlib.blake2b(f.read_bytes(), digest_size=64).digest()
    Ed25519PublicKey.from_public_bytes(pub[10:42]).verify(sig[10:74], h)
    trusted = lines[2].removeprefix("trusted comment: ").encode()
    Ed25519PublicKey.from_public_bytes(pub[10:42]).verify(base64.b64decode(lines[3]), sig[10:74] + trusted)


def setup_mirror() -> None:
    """Pages project blurt-dl on dl.blurt.work (idempotent). Needs CF_API_EMAIL / CF_API_KEY in the environment."""
    import urllib.error
    import urllib.request

    h = {"X-Auth-Email": os.environ["CF_API_EMAIL"], "X-Auth-Key": os.environ["CF_API_KEY"], "Content-Type": "application/json"}

    def api(method: str, path: str, body: dict | None = None) -> dict:
        req = urllib.request.Request("https://api.cloudflare.com/client/v4" + path, method=method, headers=h,
                                     data=json.dumps(body).encode() if body is not None else None)
        try:
            with urllib.request.urlopen(req) as r:
                return json.load(r)
        except urllib.error.HTTPError as e:
            return json.load(e)

    def said(what: str, r: dict) -> None:
        errs = [e.get("message") for e in r.get("errors", [])]
        print(f"{what}: {'ok' if r.get('success') else errs}")

    z = api("GET", "/zones?name=blurt.work")["result"][0]
    zid, acc = z["id"], z["account"]["id"]
    if not api("GET", f"/accounts/{acc}/pages/projects/blurt-dl").get("success"):
        # the REST call, not `wrangler pages project create` (current wrangler makes a Worker instead)
        said("project blurt-dl", api("POST", f"/accounts/{acc}/pages/projects", {"name": "blurt-dl", "production_branch": "main"}))
    if not any(d["name"] == "dl.blurt.work" for d in api("GET", f"/accounts/{acc}/pages/projects/blurt-dl/domains").get("result", [])):
        said("domain dl.blurt.work", api("POST", f"/accounts/{acc}/pages/projects/blurt-dl/domains", {"name": "dl.blurt.work"}))
    if not api("GET", f"/zones/{zid}/dns_records?name=dl.blurt.work")["result"]:
        said("CNAME dl → blurt-dl.pages.dev", api("POST", f"/zones/{zid}/dns_records",
                                                  {"type": "CNAME", "name": "dl", "content": "blurt-dl.pages.dev", "proxied": True}))
    print("mirror ready (the domain's certificate can take a few minutes)")


def main() -> None:
    if sys.argv[1:] == ["--setup-mirror"]:
        return setup_mirror()
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("version")
    ap.add_argument("dir", type=Path)
    ap.add_argument("--notes", default="")
    ap.add_argument("--out", type=Path)
    ap.add_argument("--publish", action="store_true")
    a = ap.parse_args()
    version = a.version.removeprefix("v")
    tag = f"v{version}"
    out = a.out or a.dir / "dl"
    pub = json.loads(CONF.read_text())["plugins"]["updater"]["pubkey"]
    if not pub:
        sys.exit("tauri.conf.json has no updater pubkey: these builds can't update themselves")
    key = secret("tauri-updater.key", "Blurt Tauri updater key")
    password = secret("password", "Blurt Tauri updater key password")

    found = []
    for f in sorted(a.dir.iterdir()):
        for suffix, keys in KINDS:
            if f.is_file() and f.name.endswith(suffix):
                if version not in f.name:
                    sys.exit(f"{f.name} isn't version {version}")
                found.append((f, keys))
    if not found:
        sys.exit(f"no installers in {a.dir}")

    now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    github = {"version": version, "notes": a.notes, "pub_date": now, "platforms": {}}
    mirror = {"version": version, "notes": a.notes, "pub_date": now, "platforms": {}}
    (out / "desktop").mkdir(parents=True, exist_ok=True)
    uploads = []
    for f, keys in found:
        sig = sign(f, key, password)
        verify(f, sig, pub)
        uploads += [f, Path(f"{f}.sig")]
        near = f.stat().st_size <= PAGES_LIMIT
        if near:
            shutil.copy2(f, out / "desktop" / f.name)
        for k in keys:
            if k in github["platforms"]:
                sys.exit(f"two installers for {k}")
            github["platforms"][k] = {"signature": sig, "url": f"{GITHUB}/{tag}/{f.name}"}
            mirror["platforms"][k] = {"signature": sig, "url": f"{MIRROR}/{f.name}" if near else f"{GITHUB}/{tag}/{f.name}"}
        print(f"signed + verified  {f.name}  ({f.stat().st_size / 1e6:.1f} MB{', mirrored' if near else ', GitHub only'})")
    (a.dir / "latest.json").write_text(json.dumps(github, indent=2, ensure_ascii=False) + "\n")
    (out / "desktop/latest.json").write_text(json.dumps(mirror, indent=2, ensure_ascii=False) + "\n")
    (out / "_headers").write_text("/desktop/latest.json\n  Cache-Control: no-cache\n")
    print(f"feeds: {a.dir / 'latest.json'}  {out / 'desktop/latest.json'}")

    upload = ["gh", "release", "upload", tag, "--clobber", str(a.dir / "latest.json"), *[str(p) for p in uploads if p.suffix == ".sig"]]
    deploy = ["npx", "-y", "wrangler@4", "pages", "deploy", str(out), "--project-name", "blurt-dl", "--branch", "main"]
    if a.publish:
        subprocess.run(upload, check=True, cwd=ROOT)
        subprocess.run(deploy, check=True, cwd=ROOT)
    else:
        print("publish with:\n  " + " ".join(upload) + "\n  " + " ".join(deploy))


if __name__ == "__main__":
    main()
