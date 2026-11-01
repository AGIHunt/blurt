"""Only my voice (issue #26, docs/design/voiceprint.md): the voiceprint gate in transcribe.py. The user's voice
($BLURT_HOME/voiceprint.json) is compared with each VAD cut of a dictation piece; another speaker's cuts are silenced
out of what recognition hears, a piece that is all someone else is dropped before the model is even loaded, and the
verdict (with the dropped spans) goes back to the app. Only dictation is gated. No profile / no model: fail-open. No
speaker-embedding model needed here: Voiceprint's embed/target are faked, the gate's arithmetic is real.

  uv run --with numpy --with pytest pytest tests/test_voiceprint.py -q
"""
from __future__ import annotations

import json
import unittest

import numpy as np

import test_asr_select as A

T = A.T
SR = A.SR

ME = np.eye(1, 192, 0, dtype=np.float32)[0]        # the user's voice
OTHER = np.eye(1, 192, 1, dtype=np.float32)[0]     # someone else (orthogonal: cosine 0)


class Settings(unittest.TestCase):
    def test_defaults_config_and_the_request_flag(self):
        with A.config({}):
            self.assertEqual(T.voiceprint_settings(None), (False, T.VP_THRESHOLD))
            self.assertEqual(T.voiceprint_settings(True), (True, T.VP_THRESHOLD))
        with A.config({"record": {"dictation": {"only_my_voice": True, "voiceprint_threshold": 0.4}}}):
            self.assertEqual(T.voiceprint_settings(None), (True, 0.4))
            self.assertEqual(T.voiceprint_settings(False), (False, 0.4))     # the request wins over the config
        with A.config({"record": {"dictation": {"voiceprint_threshold": "loud"}}}):
            self.assertEqual(T.voiceprint_settings(None), (False, T.VP_THRESHOLD))      # a bad value falls back

    def test_the_model_has_mirrors(self):
        self.assertEqual(len(T.VP_URLS), 3)
        self.assertTrue(all(u.endswith(T.VP_FILE) for u in T.VP_URLS))
        self.assertTrue(any("hf-mirror.com" in u for u in T.VP_URLS))


class GateMath(unittest.TestCase):
    """The gate itself: speakers (faked: who spoke when, and how like the user) → kept / dropped → ramped silencing."""

    def setUp(self):
        self.real = (T.Voiceprint.target, T.Voiceprint.enrolled, T.Voiceprint.embed, T.Voiceprint.learn,
                     T.Voiceprint.speakers, T.vad_segments)
        T.Voiceprint.target = classmethod(lambda cls: ME)
        T.Voiceprint.enrolled = classmethod(lambda cls: ME)
        T.Voiceprint.embed = classmethod(lambda cls, x: ME)
        self.learned = []
        T.Voiceprint.learn = classmethod(lambda cls, e: self.learned.append(e))
        T.vad_segments = lambda x, **k: [(0.0, len(x) / SR)]
        self.x = np.full(8 * SR, 0.3, dtype=np.float32)

    def tearDown(self):
        (T.Voiceprint.target, T.Voiceprint.enrolled, T.Voiceprint.embed, T.Voiceprint.learn,
         T.Voiceprint.speakers, T.vad_segments) = self.real

    def gate(self, speakers, interim=False):
        """speakers: [(turns, sim)] — each turn (s, e) in seconds."""
        spk = [{"turns": turns, "sim": sim, "seconds": sum(e - s for s, e in turns),
                "audio": np.zeros(int(sum(e - s for s, e in turns) * SR), np.float32)} for turns, sim in speakers]
        T.Voiceprint.speakers = classmethod(lambda cls, x, t: spk)
        return T.Voiceprint.gate(self.x, T.VP_THRESHOLD, interim=interim)

    def test_all_mine_passes_untouched(self):
        r, y = self.gate([([(0.0, 3.0), (4.0, 6.0)], 0.8)])
        self.assertEqual((r["match"], r["dropped"], r["drop"]), (True, 0, []))
        self.assertTrue(np.array_equal(y, self.x))

    def test_all_someone_else_is_dropped(self):
        r, y = self.gate([([(0.0, 3.0)], 0.1)])
        self.assertEqual((r["match"], r["dropped"], r["drop"]), (False, 1, [[0.0, 3.0]]))
        self.assertTrue(np.array_equal(y, self.x))      # the caller returns blank without recognising

    def test_a_reply_right_after_me_is_silenced(self):
        # the founder's friend: "把那个字改成灰色" between two of his sentences, no pause to cut at
        r, y = self.gate([([(0.0, 2.6), (5.1, 7.0)], 0.76), ([(2.6, 5.1)], 0.18)])
        self.assertEqual((r["match"], r["dropped"], r["drop"]), (True, 1, [[2.6, 5.1]]))
        self.assertAlmostEqual(float(np.abs(y[:2 * SR]).max()), 0.3)                 # my sentences kept
        self.assertAlmostEqual(float(np.abs(y[int(5.2 * SR):7 * SR]).max()), 0.3)
        self.assertLess(float(np.abs(y[3 * SR:5 * SR]).max()), 1e-6)                 # theirs gone

    def test_a_voice_close_to_mine_is_dropped_by_the_margin(self):
        r, _ = self.gate([([(0.0, 3.0)], 0.8), ([(3.5, 6.0)], 0.35)])
        self.assertEqual(r["drop"], [[3.5, 6.0]])
        r, _ = self.gate([([(0.0, 3.0)], 0.8), ([(3.5, 6.0)], 0.5)])      # surely mine: not dropped
        self.assertEqual(r["drop"], [])

    def test_a_short_stretch_goes_with_me_but_not_alone(self):
        r, _ = self.gate([([(0.0, 3.0)], 0.8), ([(3.5, 4.3)], 0.33)])      # my 0.8 s "丫头": kept
        self.assertEqual(r["drop"], [])
        r, _ = self.gate([([(0.0, 3.0)], 0.1), ([(3.5, 4.3)], 0.33)])      # beside someone else: no piece of mine
        self.assertFalse(r["match"])
        r, _ = self.gate([([(0.0, 3.0)], 0.1), ([(3.5, 3.8)], None)])      # too short to score: goes with the rest
        self.assertFalse(r["match"])

    def test_where_two_talk_at_once_my_turn_wins(self):
        r, y = self.gate([([(0.0, 3.0)], 0.8), ([(2.0, 5.0)], 0.1)])
        self.assertAlmostEqual(float(np.abs(y[int(2.5 * SR)]).max()), 0.3)
        self.assertLess(float(np.abs(y[4 * SR])), 1e-6)

    def test_no_speech_passes_as_ever(self):
        T.vad_segments = lambda x, **k: []
        r, y = self.gate([])
        self.assertEqual((r["match"], r["similarity"], r["dropped"]), (True, None, 0))
        self.assertTrue(np.array_equal(y, self.x))

    def test_no_enrolled_voice_fails_open(self):
        T.Voiceprint.target = classmethod(lambda cls: None)
        with self.assertRaises(T.Fail) as cm:
            T.Voiceprint.gate(self.x, 0.3)
        self.assertEqual(cm.exception.code, "not_enrolled")

    def test_an_interim_request_judges_only_speakers_long_enough(self):
        r, _ = self.gate([([(0.0, 0.8)], 0.1)], interim=True)        # too little to tell while it is said
        self.assertEqual((r["match"], r["dropped"]), (True, 0))
        r, _ = self.gate([([(0.0, 2.0)], 0.1)], interim=True)
        self.assertEqual((r["match"], r["dropped"]), (False, 1))
        self.assertEqual(self.learned, [])                     # nothing is learned from the live words

    def test_only_a_long_piece_of_one_voice_is_learned(self):
        self.gate([([(0.0, 4.0)], 0.8)])
        self.assertEqual(len(self.learned), 1)
        self.gate([([(0.0, 2.0)], 0.8)])                        # too short to learn from
        self.gate([([(0.0, 4.0)], 0.8), ([(4.5, 7.0)], 0.1)])  # two voices: never learned (v1 learned a friend)
        self.assertEqual(len(self.learned), 1)


class Utterances(unittest.TestCase):
    """A stream's text (Volcengine) without another speaker's sentences, by their times."""

    U = [{"text": "我在写代码。", "start_time": 0, "end_time": 2500},
         {"text": "今天中午吃什么？", "start_time": 3100, "end_time": 5800},
         {"text": "先把测试跑完。", "start_time": 6500, "end_time": 8000}]

    def test_their_sentence_is_left_out(self):
        sp = {"match": True, "drop": [[3.0, 6.0]]}
        self.assertEqual(T.voiceprint_utterances("全文", self.U, sp), "我在写代码。先把测试跑完。")

    def test_english_keeps_its_spaces(self):
        u = [{"text": "Hello there.", "start_time": 0, "end_time": 2000},
             {"text": "Lunch?", "start_time": 3200, "end_time": 5000},
             {"text": "Run the tests.", "start_time": 6400, "end_time": 8000}]
        self.assertEqual(T.voiceprint_utterances("x", u, {"match": True, "drop": [[3.0, 5.5]]}),
                         "Hello there. Run the tests.")

    def test_all_someone_else_and_nothing_to_go_by(self):
        self.assertEqual(T.voiceprint_utterances("全文", self.U, {"match": False, "drop": []}), "")
        self.assertEqual(T.voiceprint_utterances("全文", None, {"match": True, "drop": [[3.0, 6.0]]}), "全文")
        self.assertEqual(T.voiceprint_utterances("全文", self.U, {"match": True, "drop": []}), "全文")


class Quick(A.FakeBackend):
    """A backend that takes interim requests (SenseVoice-like)."""
    quick_decode = True


class GateInNote(unittest.TestCase):
    """note() consults the gate before the model is loaded, for dictation only."""

    def setUp(self):
        self.patches = {"BACKENDS": T.BACKENDS, "vad_segments": T.vad_segments, "gate": T.Voiceprint.gate}
        T.vad_segments = lambda x, **k: [(0.0, len(x) / SR)]
        T.BACKENDS = {**self.patches["BACKENDS"], "sensevoice": Quick}
        self.real_installed = A.fake_installed("sensevoice-small")
        self.wav = A.write_wav(A.Path(A.tempfile.mkdtemp()) / "w.wav", 1.0)
        self.asked = []

    def tearDown(self):
        for k, v in self.patches.items():
            setattr(T, k, v)
        T.installed = self.real_installed

    def fake_gate(self, match: bool):
        def g(cls, x, t, interim=False):
            self.asked.append(interim)
            return {"match": match, "similarity": 0.9 if match else 0.1, "threshold": t,
                    "dropped": 0 if match else 1, "drop": [] if match else [[0.0, 1.0]]}, x
        T.Voiceprint.gate = classmethod(g)

    def note(self, e, purpose="dictation", **kw):
        with A.config({"asr": {"auto": False, "backend": "sensevoice"},
                       "record": {"dictation": {"only_my_voice": True}}}):
            return e.note(self.wav, purpose=purpose, model_id="sensevoice-small", **kw)

    def test_a_piece_that_is_all_someone_else_never_loads_the_model(self):
        self.fake_gate(False)
        e = T.NoteEngine()
        r = self.note(e)
        self.assertEqual((r["ok"], r["text"]), (True, ""))
        self.assertEqual((r["speaker"]["match"], r["speaker"]["drop"]), (False, [[0.0, 1.0]]))
        self.assertIsNone(e.backend)                       # dropped before the model was even loaded

    def test_my_piece_is_recognised_with_the_speaker_verdict(self):
        self.fake_gate(True)
        r = self.note(T.NoteEngine())
        self.assertEqual((r["ok"], r["text"]), (True, "heard 1.0s"))
        self.assertEqual((r["speaker"]["match"], r["speaker"]["dropped"]), (True, 0))

    def test_off_in_the_config_the_gate_is_not_even_asked(self):
        self.fake_gate(True)
        with A.config({"asr": {"auto": False, "backend": "sensevoice"}, "record": {"dictation": {}}}):
            r = T.NoteEngine().note(self.wav, purpose="dictation", model_id="sensevoice-small")
        self.assertEqual((r["text"], self.asked), ("heard 1.0s", []))
        self.assertNotIn("speaker", r)

    def test_a_voice_note_is_never_gated(self):
        # a voice note or a recording keeps everyone who speaks: the switch is dictation's
        self.fake_gate(False)
        r = self.note(T.NoteEngine(), purpose=None)
        self.assertEqual((r["text"], self.asked), ("heard 1.0s", []))

    def test_the_app_can_say_a_window_is_already_judged(self):
        self.fake_gate(False)
        r = self.note(T.NoteEngine(), voiceprint=False)
        self.assertEqual((r["text"], self.asked), ("heard 1.0s", []))

    def test_an_interim_request_is_gated_as_interim(self):
        self.fake_gate(True)
        r = self.note(T.NoteEngine(), stop=lambda: False)
        self.assertEqual((r["ok"], r["text"], self.asked), (True, "heard 1.0s", [True]))

    def test_no_profile_fails_open(self):
        T.Voiceprint.gate = classmethod(lambda cls, x, t, interim=False: (_ for _ in ()).throw(
            T.Fail("no voice enrolled", "not_enrolled")))
        r = self.note(T.NoteEngine())
        self.assertEqual((r["ok"], r["text"]), (True, "heard 1.0s"))
        self.assertNotIn("speaker", r)


class Enrollment(unittest.TestCase):
    """enroll / status / clear / learn against a scratch $BLURT_HOME profile (embed_windows faked)."""

    def setUp(self):
        self.path = T.Voiceprint.PROFILE
        self.old = self.path.read_bytes() if self.path.exists() else None
        self.path.unlink(missing_ok=True)
        self.real = T.Voiceprint.embed_windows
        T.Voiceprint._target = None
        T.Voiceprint._learned_at = 0.0

    def tearDown(self):
        T.Voiceprint.embed_windows = self.real
        T.Voiceprint._target = None
        if self.old is None:
            self.path.unlink(missing_ok=True)
        else:
            self.path.write_bytes(self.old)

    def test_enroll_status_learn_clear(self):
        T.Voiceprint.embed_windows = classmethod(lambda cls, x: [ME, ME, ME])
        wav = A.write_wav(A.Path(A.tempfile.mkdtemp()) / "me.wav", 1.0)
        r = T.Voiceprint.enroll(wav)
        self.assertEqual((r["ok"], r["enrolled"], r["takes"]), (True, True, 1))
        self.assertEqual(T.Voiceprint.enroll(wav)["takes"], 2)        # takes accumulate (the voice and room drift)
        self.assertAlmostEqual(float(T.Voiceprint.target() @ ME), 1.0, places=4)
        T.Voiceprint.learn(ME)
        T.Voiceprint.learn(ME)                                         # within VP_LEARN_EVERY: not again
        self.assertEqual(T.Voiceprint.status()["learned"], 1)
        self.assertEqual(T.Voiceprint.enroll(wav)["learned"], 1)      # re-recording keeps what dictation taught
        for _ in range(T.Voiceprint.TAKES + 2):
            T.Voiceprint.enroll(wav)
        self.assertEqual(T.Voiceprint.status()["takes"], T.Voiceprint.TAKES)
        s = T.Voiceprint.clear()
        self.assertEqual((s["enrolled"], s["takes"], s["learned"]), (False, 0, 0))
        self.assertFalse(self.path.exists())
        self.assertIsNone(T.Voiceprint.target())

    def test_what_v1_learned_is_forgotten(self):
        # v1 learned whole cuts, a friend's reply inside one included
        self.path.write_text(json.dumps({"model": T.VP_FILE, "embeddings": [ME.tolist()], "learned": [OTHER.tolist()]}))
        self.assertEqual(T.Voiceprint.status()["learned"], 0)
        self.assertAlmostEqual(float(T.Voiceprint.target() @ ME), 1.0, places=4)

    def test_a_profile_from_another_model_is_stale(self):
        self.path.write_text(json.dumps({"model": "old.onnx", "embeddings": [[1.0] * 512]}))
        s = T.Voiceprint.status()
        self.assertEqual((s["enrolled"], s["stale"]), (False, True))
        self.assertIsNone(T.Voiceprint.target())                       # never compared across models

    def test_room_tone_is_never_learned(self):
        T.Voiceprint.embed_windows = classmethod(lambda cls, x: [ME])  # one window: too little speech
        wav = A.write_wav(A.Path(A.tempfile.mkdtemp()) / "quiet.wav", 1.0)
        self.assertEqual(T.Voiceprint.enroll(wav)["code"], "too_short")
        self.assertFalse(self.path.exists())

    def test_a_missing_wav_is_a_clean_error(self):
        self.assertEqual(T.Voiceprint.enroll(A.Path("/no/such.wav"))["code"], "not_found")


if __name__ == "__main__":
    unittest.main()
