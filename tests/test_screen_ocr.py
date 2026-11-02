"""screen_ocr.py's own rules (the reading itself needs RapidOCR: checked on Windows)."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "skills" / "blurt" / "scripts"))
import screen_ocr  # noqa: E402


def test_a_small_selection_is_read_at_twice_its_size():
    assert screen_ocr.upscale_factor(1100, 110) == 2
    assert screen_ocr.upscale_factor(1920, 1080) == 1
    assert screen_ocr.upscale_factor(0, 0) == 1


def test_cjk_and_latin_get_their_space_back():
    assert screen_ocr.spaced("用ClaudeCode跑") == "用 ClaudeCode 跑"
    assert screen_ocr.spaced("the save button") == "the save button"
