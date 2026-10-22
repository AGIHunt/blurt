"""Snap mode: frames.py on stills (shots/NNN.png) and the Tk recorder's shots.jsonl.

  python -m unittest tests.test_snap        (needs numpy + pillow; ffmpeg-only cases skip without it)
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1] / "skills" / "blurt" / "scripts"
sys.path.insert(0, str(SCRIPTS))

try:
    from PIL import Image
except ImportError:  # pragma: no cover
    Image = None

HAVE_FFMPEG = shutil.which("ffmpeg") is not None


def run(*args, **kw):
    return subprocess.run([sys.executable, *map(str, args)], capture_output=True, text=True, encoding="utf-8",
                          timeout=60, **kw)


def line(n, **kw):
    o = {"n": n, "file": f"shots/{n:03d}.png", "marked": None, "t": None, "wall": 1.0, "region": [0, 0, 400, 250],
         "voice": None, "text": None, "strokes": []}
    o.update(kw)
    return json.dumps(o, ensure_ascii=False)


@unittest.skipIf(Image is None, "pillow not installed")
class FramesOnStills(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.s = Path(tmp.name) / "20261021-120000-shots"
        (self.s / "shots").mkdir(parents=True)
        for n, col in ((1, "#3355ff"), (2, "#ff5533"), (3, "#22aa66")):
            Image.new("RGB", (800, 500), col).save(self.s / "shots" / f"{n:03d}.png")
        ink = [[[0.5, 0.4], [0.6, 0.45], [0.55, 0.6], [0.48, 0.5]]]
        (self.s / "shots.jsonl").write_text("\n".join([
            line(1), line(1, text="保存按钮太浅"),            # later line for the same n wins
            line(2, strokes=ink, marked="shots/002.marked.png"),
            line(3), line(3, deleted=True),
        ]) + "\n", encoding="utf-8")
        (self.s / "meta.json").write_text(json.dumps({"mode": "shots", "engine": "native-app"}), encoding="utf-8")

    def test_grab_image_with_box_and_ring(self):
        out = self.s / "x" / "a.jpg"
        p = run(SCRIPTS / "frames.py", "grab", self.s / "shots" / "001.png", "-o", out, "--box", "0.1,0.1,0.3,0.3",
                "--ring", "0.5,0.5")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(json.loads(p.stdout)["size"], [800, 500])
        im = Image.open(out).convert("RGB")
        self.assertNotEqual(im.getpixel((80, 80)), im.getpixel((10, 10)))   # the red box is drawn

    def test_crop_stroke_uses_the_shots_ink(self):
        out = self.s / "x" / "b.jpg"
        p = run(SCRIPTS / "frames.py", "grab", self.s / "shots" / "002.png", "-o", out, "--crop", "stroke")
        self.assertEqual(p.returncode, 0, p.stderr)
        w, h = json.loads(p.stdout)["size"]
        self.assertLess(w, 800)
        self.assertLess(h, 500)
        p = run(SCRIPTS / "frames.py", "grab", self.s / "shots" / "001.png", "-o", out, "--crop", "stroke")
        self.assertEqual(p.returncode, 1)
        self.assertIn("no ink", p.stderr)

    def test_grid_and_sheet_of_stills(self):
        p = run(SCRIPTS / "frames.py", "grid", self.s / "shots" / "001.png", "-o", self.s / "x" / "g.jpg")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIsNone(json.loads(p.stdout)["cursor"])
        p = run(SCRIPTS / "frames.py", "sheet", self.s / "shots" / "001.png", self.s / "shots" / "002.png",
                "-o", self.s / "x" / "s.jpg")
        self.assertEqual(p.returncode, 0, p.stderr)
        labels = json.loads(p.stdout)["labels"]
        self.assertEqual([lb["n"] for lb in labels], [1, 2])
        self.assertEqual(labels[0]["note"], "保存按钮太浅")
        self.assertTrue((self.s / "x" / "s.jpg").exists())

    def test_marks_on_a_shots_session(self):
        p = run(SCRIPTS / "frames.py", "marks", self.s)
        self.assertEqual(p.returncode, 0, p.stderr)
        snaps = json.loads(p.stdout)["snaps"]
        self.assertEqual([x["n"] for x in snaps], [1, 2])          # deleted shot 3 left out
        self.assertEqual(snaps[0]["text"], "保存按钮太浅")
        self.assertEqual(snaps[1]["ink"], 1)
        self.assertEqual(snaps[1]["marked"], "shots/002.marked.png")

    def test_video_only_commands_refuse_stills(self):
        p = run(SCRIPTS / "frames.py", "scan", self.s / "shots" / "001.png")
        self.assertEqual(p.returncode, 1)
        self.assertNotIn("Traceback", p.stderr)

    @unittest.skipUnless(HAVE_FFMPEG, "ffmpeg not installed")
    def test_snap_while_recording_gets_its_moment(self):
        rec = self.s.parent / "rec"
        (rec / "shots").mkdir(parents=True)
        subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc2=s=320x200:r=10", "-t", "4",
                        "-pix_fmt", "yuv420p", str(rec / "recording.mp4")], check=True)
        Image.new("RGB", (640, 400), "#888").save(rec / "shots" / "001.png")
        (rec / "shots.jsonl").write_text(line(1, t=2.0, text="this one") + "\n", encoding="utf-8")
        (rec / "events.jsonl").write_text("\n".join(json.dumps(e) for e in [
            {"t": 1.9, "type": "cursor", "x": 0.25, "y": 0.75},
            {"t": 2.0, "type": "marker"},
            {"t": 2.0, "type": "snap", "n": 1, "file": "shots/001.png", "via": "marker"},
        ]) + "\n", encoding="utf-8")
        p = run(SCRIPTS / "frames.py", "marks", rec / "recording.mp4")
        self.assertEqual(p.returncode, 0, p.stderr)
        m = json.loads(p.stdout)
        self.assertEqual(len(m["markers"]), 1)
        self.assertEqual(m["snaps"][0]["t"], 2.0)
        self.assertEqual(m["snaps"][0]["text"], "this one")
        p = run(SCRIPTS / "frames.py", "grab", rec / "shots" / "001.png", "-o", rec / "r.jpg", "--ring", "cursor")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(json.loads(p.stdout)["t"], 2.0)


class TkShots(unittest.TestCase):
    def test_shot_line_matches_the_contract(self):
        from tk_recorder import shot_line
        o = shot_line(7, 12.3456, [10, 20, 300, 200], wall=100.0)
        self.assertEqual(set(o), {"n", "file", "marked", "t", "wall", "region", "voice", "text", "strokes"})
        self.assertEqual(o["file"], "shots/007.png")
        self.assertEqual(o["t"], 12.346)
        self.assertIsNone(shot_line(1, None, [0, 0, 1, 1])["t"])

    def test_snap_cmd_is_one_frame_of_the_region(self):
        from tk_recorder import snap_cmd
        os.environ["BLURT_FAKE_SCREEN"] = "1"
        try:
            cmd = snap_cmd("ffmpeg", [5, 6, 320, 200], Path("x.png"))
        finally:
            del os.environ["BLURT_FAKE_SCREEN"]
        self.assertEqual(cmd[cmd.index("-frames:v") + 1], "1")
        self.assertIn("testsrc2=s=320x200:r=1", cmd)
        self.assertEqual(cmd[-1], "x.png")

    @unittest.skipUnless(HAVE_FFMPEG, "ffmpeg not installed")
    def test_capture_shot_writes_png_and_jsonl(self):
        from tk_recorder import capture_shot
        with tempfile.TemporaryDirectory() as d:
            os.environ["BLURT_FAKE_SCREEN"] = "1"
            try:
                a = capture_shot(Path(d), [0, 0, 320, 200], 1, 1.5)
                b = capture_shot(Path(d), [0, 0, 320, 200], 2, 3.0)
            finally:
                del os.environ["BLURT_FAKE_SCREEN"]
            self.assertTrue(a and b)
            self.assertTrue((Path(d) / "shots" / "001.png").stat().st_size > 0)
            lines = [json.loads(x) for x in (Path(d) / "shots.jsonl").read_text(encoding="utf-8").splitlines()]
            self.assertEqual([x["n"] for x in lines], [1, 2])
            self.assertEqual(lines[1]["t"], 3.0)
            if Image is not None:
                self.assertEqual(Image.open(Path(d) / "shots" / "002.png").size, (320, 200))


MAC = Path(__file__).resolve().parents[1] / "skills" / "blurt" / "recorder" / "macos"
RES = MAC / "Sources" / "BlurtApp" / "Resources"


def strings_table(p: Path) -> dict:
    import re
    return {m.group(1): m.group(2) for m in re.finditer(r'^"((?:[^"\\]|\\.)+)" = "((?:[^"\\]|\\.)*)";$', p.read_text(encoding="utf-8"), re.M)}


def placeholders(s: str) -> list:
    import re
    return sorted(re.findall(r"%(?:\d+\$)?[@dfs]", s))


class CaptureStrings(unittest.TestCase):
    """K10 for the capture side (P5): the Capture table in en and zh-Hans — same keys, same placeholders, and every
    capture.* key the Swift code asks for is there."""

    def test_en_and_zh_hans_match(self):
        en, zh = strings_table(RES / "en.lproj" / "Capture.strings"), strings_table(RES / "zh-Hans.lproj" / "Capture.strings")
        self.assertTrue(en)
        self.assertEqual(set(en), set(zh))
        for k in en:
            self.assertEqual(placeholders(en[k]), placeholders(zh[k]), k)
        import plistlib
        pe = plistlib.loads((RES / "en.lproj" / "Capture.stringsdict").read_bytes())
        pz = plistlib.loads((RES / "zh-Hans.lproj" / "Capture.stringsdict").read_bytes())
        self.assertEqual(set(pe), set(pz))
        for k in pe:
            self.assertIn("other", pe[k]["n"])
            self.assertIn("one", pe[k]["n"])
            self.assertEqual(placeholders(pe[k]["n"]["other"]), placeholders(pz[k]["n"]["other"]), k)

    def test_every_capture_key_in_the_code_exists(self):
        import re
        tables = set(strings_table(RES / "en.lproj" / "Capture.strings"))
        import plistlib
        tables |= set(plistlib.loads((RES / "en.lproj" / "Capture.stringsdict").read_bytes()))
        used = set()
        for f in (MAC / "Sources").rglob("*.swift"):
            for line in f.read_text(encoding="utf-8").splitlines():
                if line.lstrip().startswith("//"):
                    continue
                used |= set(re.findall(r'"(capture\.[a-z_.]+)"', line))
        self.assertTrue(used)
        self.assertEqual(sorted(used - tables), [])


if __name__ == "__main__":
    unittest.main()
