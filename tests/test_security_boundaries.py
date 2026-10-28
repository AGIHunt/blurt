"""Offline regressions for attachment, cloud credential and model-download boundaries."""
from __future__ import annotations

import json
import contextlib
import os
import sys
from argparse import Namespace
from pathlib import Path
from unittest import mock

import numpy as np
import pytest

sys.path.insert(0, str(Path(__file__).parent))
from p2_env import SCRIPTS, p2  # noqa: E402,F401
from test_model_downloads import FakeModelScope, FakeResponse  # noqa: E402

sys.path.insert(0, str(SCRIPTS))
import _common as C  # noqa: E402
import export_local as B  # noqa: E402
import items as I  # noqa: E402
import polish as P  # noqa: E402
import store as S  # noqa: E402
import transcribe as T  # noqa: E402


@pytest.mark.parametrize("keys,base,key", [
    ({"OPENAI_API_KEY": "openai-test"}, "https://api.openai.com/v1", "openai-test"),
    ({"GROQ_API_KEY": "groq-test"}, "https://api.groq.com/openai/v1", "groq-test"),
    ({"OPENAI_API_KEY": "openai-test", "GROQ_API_KEY": "groq-test"},
     "https://api.openai.com/v1", "openai-test"),
    ({"BLURT_ASR_API_KEY": "custom-test", "OPENAI_API_KEY": "openai-test", "GROQ_API_KEY": "groq-test"},
     "https://api.openai.com/v1", "custom-test"),
    ({"BLURT_ASR_API_KEY": "custom-test", "BLURT_ASR_BASE_URL": "https://speech.example/v1/"},
     "https://speech.example/v1", "custom-test"),
])
def test_cloud_provider_pairing(keys, base, key):
    # Check the actual outgoing request, with synthetic keys and no network.
    args = Namespace(model=None, language=None, prompt=None)
    with mock.patch.dict(os.environ, keys, clear=True), mock.patch.object(T, "_post", return_value={"text": "hello"}) as post:
        backend = T.OpenAICompat(args)
        backend.transcribe(np.zeros(160, dtype=np.float32))
    assert post.call_args.args[0] == base + "/audio/transcriptions"
    assert post.call_args.args[2]["Authorization"] == "Bearer " + key


def test_cloud_explicit_model_and_missing_key():
    with mock.patch.dict(os.environ, {}, clear=True), pytest.raises(T.Fail, match="no API key"):
        T.OpenAICompat(Namespace(model=None))
    with mock.patch.dict(os.environ, {"GROQ_API_KEY": "groq-test"}, clear=True):
        backend = T.OpenAICompat(Namespace(model="chosen-model"))
    assert backend.model == "chosen-model"


@pytest.fixture
def mirror(tmp_path, monkeypatch):
    monkeypatch.setattr(T, "MODELS_DIR", tmp_path / "models")
    monkeypatch.setattr(P, "POLISH_DIR", tmp_path / "models" / "polish")

    def setup(kind, files):
        fake = FakeModelScope(files)
        monkeypatch.setattr(T.urllib.request, "urlopen", fake)
        if kind == "asr":
            dest = T.MODELS_DIR / "asr" / "Test-model"
            run = lambda: T._modelscope("mlx-community/Test-model", 1)
        else:
            dest = P.POLISH_DIR / "Test-model"
            run = lambda: P._modelscope({"repo": "mlx-community/Test-model"})
        return dest, run, fake
    return setup


@pytest.mark.parametrize("kind", ["asr", "polish"])
@pytest.mark.parametrize("bad", ["../outside.bin", "nested/../../outside.bin", "/absolute.bin", "C:\\outside.bin",
                                 "..\\outside.bin", "C:/outside.bin", "//server/share/model.bin", "", "."])
def test_mirror_rejects_manifest_before_fetching(mirror, kind, bad):
    dest, run, fake = mirror(kind, {"config.json": b"{}", bad: b"bad"})
    with pytest.raises((ValueError, T.Fail)):
        run()
    assert not fake.opened  # even the safe first file must not have been downloaded
    assert not (dest / "config.json").exists()
    assert not (dest / C.DOWNLOAD_MANIFEST).exists()


@pytest.mark.parametrize("kind", ["asr", "polish"])
@pytest.mark.parametrize("part", [False, True])
def test_mirror_rejects_escaping_symlinks(mirror, tmp_path, kind, part):
    dest, run, fake = mirror(kind, {"config.json": b"{}"})
    dest.mkdir(parents=True)
    private = tmp_path / "private.txt"
    private.write_bytes(b"private-sentinel")
    (dest / ("config.json.part" if part else "config.json")).symlink_to(private)
    with pytest.raises((ValueError, T.Fail)):
        run()
    assert private.read_bytes() == b"private-sentinel"
    assert not fake.opened


def test_saved_mirror_manifest_cannot_certify_external_files(tmp_path):
    dest = tmp_path / "model"
    dest.mkdir()
    private = tmp_path / "private.txt"
    private.write_text("private")
    (dest / C.DOWNLOAD_MANIFEST).write_text(json.dumps([{"path": "../private.txt", "size": 7}]))
    assert not C.folder_complete(dest)


@pytest.mark.parametrize("kind", ["asr", "polish"])
def test_mirror_rejects_symlink_parent(mirror, tmp_path, kind):
    dest, run, fake = mirror(kind, {"nested/config.json": b"{}"})
    dest.mkdir(parents=True)
    outside = tmp_path / "outside"
    outside.mkdir()
    (dest / "nested").symlink_to(outside, target_is_directory=True)
    with pytest.raises((ValueError, T.Fail)):
        run()
    assert not list(outside.iterdir()) and not fake.opened


@pytest.mark.parametrize("kind", ["asr", "polish"])
def test_mirror_keeps_valid_nested_files(mirror, monkeypatch, kind):
    files = {"config.json": b"{}", "nested/tokenizer.json": b"tokenizer", "model.safetensors": b"weights"}
    dest, run, fake = mirror(kind, files)

    def response(req, timeout=None):
        if req.full_url.endswith("/nested/tokenizer.json"):
            return FakeResponse(files["nested/tokenizer.json"])
        return fake(req, timeout)
    monkeypatch.setattr(T.urllib.request, "urlopen", response)
    assert run() == dest and C.folder_complete(dest)
    assert (dest / "nested/tokenizer.json").read_bytes() == b"tokenizer"


def test_huggingface_snapshot_links_still_work(tmp_path, monkeypatch):
    monkeypatch.setenv("HF_HUB_CACHE", str(tmp_path))
    repo = "mlx-community/security-test"
    root = tmp_path / "models--mlx-community--security-test"
    snap = root / "snapshots" / "test-revision"
    blobs = root / "blobs"
    snap.mkdir(parents=True)
    blobs.mkdir()
    for name, data in {"config.json": b"{}", "weights.safetensors": b"weights"}.items():
        (blobs / name).write_bytes(data)
        (snap / name).symlink_to(Path("../../blobs") / name)
    assert T.hf_snapshot(repo) == snap
    assert P._complete(snap)


@pytest.fixture
def stored_item(p2):
    project = p2.project(p2.repo("shared-project"))
    made = p2.item(project["id"])
    item = p2.get(made["uid"])
    return p2, project, item


@pytest.mark.parametrize("field", ["frames", "clip"])
@pytest.mark.parametrize("form", ["absolute", "relative", "symlink"])
def test_stored_media_cannot_escape_into_bundle(stored_item, field, form):
    p2, _, item = stored_item
    root = Path(item["store"])
    private = p2.tmp / "private.txt"
    private.write_bytes(b"private-sentinel")
    if form == "absolute":
        ref = str(private)
    elif form == "relative":
        ref = os.path.relpath(private, root)
    else:
        (root / "assets").mkdir(exist_ok=True)
        (root / "assets" / "outside.txt").symlink_to(private)
        ref = "assets/outside.txt"
    path = Path(item["path"])
    raw = S.read_item(path)
    raw[field] = [{"path": ref}] if field == "frames" else ref
    S.write_item(path, raw)  # simulate data supplied by a shared project, not an explicit import
    out = p2.run("export_local.py", "bundle", "--items", item["uid"], "-o", p2.tmp / "out.zip", ok=False)
    assert out["_exit"] == 1 and out["code"] == "bad_media_path"
    assert not (p2.tmp / "out.zip").exists()


def test_bundle_rechecks_paths_at_the_read(stored_item):
    p2, _, item = stored_item
    private = p2.tmp / "private.txt"
    private.write_bytes(b"private-sentinel")
    item["clip"] = str(private)  # do not depend solely on a previous present() call
    with pytest.raises(B.BundleError):
        B.bundle([item], p2.tmp / "out.zip")
    assert not (p2.tmp / "out.zip").exists()


@pytest.mark.parametrize("update", [False, True])
@pytest.mark.parametrize("form", ["absolute", "relative", "symlink"])
def test_session_ingest_cannot_import_external_media(stored_item, update, form):
    p2, project, item = stored_item
    session = Path(item["store"]) / "sessions" / "20261029-120000"
    session.mkdir(parents=True)
    private = p2.tmp / "private.txt"
    private.write_bytes(b"private-sentinel")
    (session / "meta.json").write_text(json.dumps({"project": project["id"]}))
    data = {"items": [{"id": "I-001", "kind": "note", "title": "Shared recording"}]}
    if update:
        (session / "items.json").write_text(json.dumps(data))
        p2.run("items.py", "ingest", session)
    if form == "absolute":
        ref = str(private)
    elif form == "relative":
        ref = os.path.relpath(private, session)
    else:
        (session / "outside.txt").symlink_to(private)
        ref = "outside.txt"
    data["items"][0]["clip"] = ref
    (session / "items.json").write_text(json.dumps(data))
    out = p2.run("items.py", "ingest", session, ok=False)
    assert out["_exit"] == 1 and out["code"] == "bad_media_path"
    assert not list((Path(item["store"]) / "assets").rglob("clip*"))


def test_explicit_external_import_still_copies_into_assets(stored_item):
    p2, _, item = stored_item
    media = p2.tmp / "chosen.png"
    media.write_bytes(b"user-chosen-media")
    p2.run("items.py", "set-frames", item["uid"], str(media))
    frame = Path(p2.get(item["uid"])["frames"][0]["path"])
    assert frame.is_relative_to(Path(item["store"]) / "assets")
    assert frame.read_bytes() == b"user-chosen-media"


def test_import_cannot_write_through_assets_symlink(stored_item):
    p2, _, item = stored_item
    root = Path(item["store"])
    assets = root / "assets"
    if assets.exists():
        assets.rmdir()
    outside = p2.tmp / "outside"
    outside.mkdir()
    assets.symlink_to(outside, target_is_directory=True)
    media = p2.tmp / "chosen.png"
    media.write_bytes(b"chosen")
    out = p2.run("items.py", "set-frames", item["uid"], str(media), ok=False)
    assert out["_exit"] == 1 and out["code"] == "bad_media_path"
    assert not list(outside.iterdir())


@pytest.mark.parametrize("op", ["set", "add"])
def test_review_edits_cannot_install_external_references(stored_item, op):
    p2, project, item = stored_item
    private = p2.tmp / "private.txt"
    private.write_text("private")
    change = {"op": "set", "id": item["uid"], "set": {"clip": str(private)}} if op == "set" else {
        "op": "add", "item": {"uid": item["uid"], "clip": str(private)}}
    out = p2.run("items.py", "user-ops", "--project", project["id"], "--json", json.dumps([change]), ok=False)
    assert out["_exit"] == 1 and out["code"] == "bad_media_path"
    assert not p2.get(item["uid"]).get("clip")


def test_loose_session_missing_frame_can_arrive_later(stored_item):
    p2, _, _ = stored_item
    session = p2.tmp / "shared-session"
    (session / "frames").mkdir(parents=True)
    data = {"items": [{"id": "I-001", "kind": "note", "title": "Frame to follow",
                        "frames": [{"path": "frames/late.png"}]}]}
    (session / "items.json").write_text(json.dumps(data))
    uid = p2.run("items.py", "ingest", session)["items"][0]["uid"]
    missing = p2.get(uid)
    assert Path(missing["frames"][0]["path"]).is_relative_to(Path(missing["store"]))
    assert not Path(missing["frames"][0]["path"]).exists()
    (session / "frames/late.png").write_bytes(b"late-frame")
    (session / "items.json").write_text(json.dumps(data))
    p2.run("items.py", "ingest", session)
    assert Path(p2.get(uid)["frames"][0]["path"]).read_bytes() == b"late-frame"


def test_mcp_rechecks_image_paths(stored_item, monkeypatch):
    import mcp_server as M
    p2, _, item = stored_item
    private = p2.tmp / "private.png"
    private.write_bytes(b"not-to-be-opened")
    item["frames"] = [{"path": str(private)}]
    monkeypatch.setattr(M, "_known", lambda uid: None)
    monkeypatch.setattr(M, "_items_py", lambda *args: {"item": item})
    with mock.patch.object(M, "_jpeg") as jpeg, pytest.raises((I.ItemsError, ValueError)):
        M.get_item(item["uid"])
    jpeg.assert_not_called()


@pytest.mark.parametrize("cross_volume", [False, True])
@pytest.mark.parametrize("linked", [False, True])
def test_moving_valid_internal_media_keeps_it_readable(stored_item, cross_volume, linked):
    p2, _, item = stored_item
    root = Path(item["store"])
    owned = root / "assets" / item["uid"]
    owned.mkdir(parents=True)
    media = owned / "1.png"
    if linked:
        shared = root / "assets" / "shared.png"
        shared.write_bytes(b"valid-internal-media")
        media.symlink_to(shared)
    else:
        media.write_bytes(b"valid-internal-media")
    path = Path(item["path"])
    raw = S.read_item(path)
    raw["frames"] = [{"path": str(media)}]
    S.write_item(path, raw)
    assert Path(p2.get(item["uid"])["frames"][0]["path"]).read_bytes() == b"valid-internal-media"
    other = p2.project(p2.repo("other-project"))
    target = Path(other["path"]) / ".blurt"
    rename = mock.patch.object(I.os, "rename", side_effect=OSError("cross-device link")) if cross_volume else contextlib.nullcontext()
    with mock.patch.object(I, "store_for_project", return_value=S.Store(target)), rename:
        I.move_items([path], other["id"], "user")
    moved = p2.get(item["uid"])
    frame = Path(moved["frames"][0]["path"])
    assert frame.is_relative_to(target) and frame.read_bytes() == b"valid-internal-media"
