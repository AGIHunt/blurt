"""Tests for experiment validity: leakage, reference trust, audio, and failure accounting."""
import copy
import tempfile
from pathlib import Path
import unittest

from dataset import create, load_clips, local_path, split_audit, validate_plan, write_json
from compare import compare
from language_metrics import score, units
from pipeline import prepared_clip, summarize
from benchmark import error_rate
from expansion_draft import build as build_expansion


class PilotTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "dataset"
        self.plan = create(self.root, "test-speaker", ["en", "zh"])

    def clip(self, split="train"):
        take = next(t for t in self.plan["takes"] if t["split"] == split)
        clip = dict(take, video=f"clips/{take['id']}.mov", reference_text=take["prompt"], reference_verified=True,
                    consent_scope="local_research", audio_recorded=False, captured_at="2026-11-06T00:00:00Z", duration_seconds=3)
        (self.root / clip["video"]).write_bytes(b"fixture")
        write_json(self.root / "clips" / (clip["id"] + ".json"), clip)
        return clip

    def test_unique_sessions_and_families(self):
        self.assertEqual(len(self.plan["takes"]), 120)
        validate_plan(self.plan)
        bad = copy.deepcopy(self.plan)
        bad["takes"][-1]["session_id"] = "train-01"
        with self.assertRaisesRegex(ValueError, "crosses splits"):
            validate_plan(bad)
        bad = copy.deepcopy(self.plan)
        bad["takes"][-1]["phrase_family"] = "meeting"
        with self.assertRaisesRegex(ValueError, "crosses splits"):
            validate_plan(bad)

    def test_expansion_preserves_plan_and_holdouts(self):
        original=copy.deepcopy(self.plan)
        draft=build_expansion(self.plan)
        self.assertEqual(self.plan,original)
        self.assertEqual(len(draft['takes']),50)
        self.assertEqual(len({t['phrase_family'] for t in draft['takes']}),40)
        self.assertTrue(all(t['split']=='train' and t['session_id']=='train-03' for t in draft['takes']))
        self.assertTrue(all('reference_verified' not in t for t in draft['takes']))
        self.assertFalse({t['phrase_family'] for t in draft['takes']} & {t['phrase_family'] for t in self.plan['takes']})

    def test_unverified_take_rejected(self):
        c = self.clip()
        c["reference_verified"] = False
        write_json(self.root / "clips" / (c["id"] + ".json"), c)
        with self.assertRaisesRegex(ValueError, "Unverified"):
            load_clips(self.root)

    def test_silent_audio_rejected(self):
        c = self.clip()
        c["audio_recorded"] = True
        write_json(self.root / "clips" / (c["id"] + ".json"), c)
        with self.assertRaisesRegex(ValueError, "audio enabled"):
            load_clips(self.root)

    def test_reference_leakage_rejected(self):
        train = self.clip()
        test = self.clip("test")
        test["reference_text"] = train["reference_text"].upper()
        write_json(self.root / "clips" / (test["id"] + ".json"), test)
        with self.assertRaisesRegex(ValueError, "reference text crosses"):
            load_clips(self.root)

    def test_path_escape_rejected(self):
        with self.assertRaises(ValueError):
            local_path(self.root, "../outside.mov")

    def test_missing_and_changed_preparation(self):
        c = self.clip()
        with self.assertRaises(FileNotFoundError):
            prepared_clip(self.root, c)
        write_json(self.root / "prepared" / c["id"] / "status.json",
                   {"status": "ready", "signature": {"source_sha256": "stale"}})
        with self.assertRaisesRegex(ValueError, "Source changed"):
            prepared_clip(self.root, c)

    def test_failure_counts_and_micro_average(self):
        base = dict(split="test", language="en", mode="silent")
        rows = [dict(base, status="ok", exact_match=True, inference_seconds=1,
                     accuracy=error_rate("one two three", "one two three")),
                dict(base, status="failed", exact_match=False, accuracy=error_rate("four", ""))]
        result = summarize(rows)[0]
        self.assertEqual(result["word_error_rate"], .25)
        self.assertEqual(result["failures"], 1)
        self.assertEqual(result["exact_match_rate"], .5)

    def test_insertions_can_exceed_one_hundred_percent(self):
        self.assertEqual(error_rate("one", "one two three four")["rate"], 3)

    def test_copied_video_crossing_splits_rejected(self):
        self.clip(); self.clip("test")
        _, clips = load_clips(self.root)
        with self.assertRaisesRegex(ValueError, "video content crosses"):
            split_audit(self.root, clips)

    def test_comparison_rejects_different_clip_sets(self):
        checkpoint = dict(base_model_sha256="a", lm_sha256="b", beam=10, language_model=True)
        stock = dict(split="test", checkpoint=checkpoint, clips=[dict(id="one")])
        adapted = dict(split="test", checkpoint=dict(checkpoint, adapter={}), clips=[dict(id="two")])
        with self.assertRaisesRegex(ValueError, "same clip IDs"):
            compare(stock, adapted)

    def test_comparison_rejects_changed_decoder(self):
        checkpoint = dict(base_model_sha256="a", lm_sha256="b", beam=10, language_model=True)
        stock = dict(split="test", checkpoint=checkpoint)
        adapted = dict(split="test", checkpoint=dict(checkpoint, beam=20, adapter={}))
        with self.assertRaisesRegex(ValueError, "decoder settings"):
            compare(stock, adapted)

    def test_tech_profile_ratios_in_every_split_and_mode(self):
        plan = create(Path(self.temp.name) / "tech", "speaker", ["zh", "en"], "tech_zh90_v1")
        self.assertEqual(len(plan["takes"]), 120)
        self.assertEqual(len({t["phrase_family"] for t in plan["takes"]}), 30)
        for split in ("train", "validation", "test"):
            for mode in ("silent", "exaggerated_silent", "whisper", "voiced"):
                rows = [t for t in plan["takes"] if t["split"] == split and t["mode"] == mode]
                self.assertEqual(len(rows), 10)
                self.assertEqual(sum(t["language"] == "zh" for t in rows), 9)
                self.assertEqual(sum(t["language_profile"] == "zh_en_mixed" for t in rows), 3)
                self.assertEqual(sum(t["domain"] == "tech" for t in rows), 7)

    def test_invalid_profile_does_not_create_directory(self):
        root = Path(self.temp.name) / "bad-profile"
        with self.assertRaises(ValueError):
            create(root, "speaker", ["en"], "tech_zh90_v1")
        self.assertFalse(root.exists())

    def test_mixed_language_scoring_keeps_english_words_whole(self):
        self.assertEqual(units("调用 ＡＰＩ，返回 JSON。", "zh_en_mixed"), ["调", "用", "api", "返", "回", "json"])
        self.assertEqual(score("调用 API", "调用 GPU", "zh_en_mixed")["rate"], 1 / 3)

    def test_mandarin_cer_and_empty_output(self):
        self.assertEqual(score("保存草稿", "保存", "zh")["rate"], .5)
        self.assertEqual(score("保存草稿", "", "zh")["rate"], 1)

    def test_number_and_acronym_expansion_not_silently_applied(self):
        self.assertGreater(score("十秒 API", "10秒 A P I", "zh_en_mixed")["errors"], 0)


if __name__ == "__main__":
    unittest.main()
