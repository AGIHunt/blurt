# Only my voice (issue #26)

Dictation types what the user says, not what a colleague says at the next desk. A speaker-embedding gate sits in front
of recognition: each piece of a take is cut at its pauses, each cut is compared with the user's voice, and another
speaker's cuts are silenced before any recognizer hears them. Settings → Dictation → "Only my voice".

## 1. How it works

- **Who spoke when** (v2, 2026-11-01): pyannote segmentation 3.0 (int8, 1.5 MB, MIT) finds speaker turns inside each
  ≤ 10 s span of a piece, clustered with the same embedding model; speech the turns leave out (a quiet voice across
  the room) is judged on its own. v1 judged VAD cuts, and in a real conversation the next person starts within a
  fraction of a second: on the founder's first hands-on test every reply of a friend sat in one cut with his own
  words and was typed (§3.3).
- **Model**: 3D-Speaker CAM++ zh-en (`3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx`, 28 MB, Apache-2.0),
  on the CPU in the speech server's process. Downloads: GitHub, Hugging Face, hf-mirror.com (the segmentation model:
  the last two).
- **Decision**, per speaker (their turns' audio together, up to 10 s): cosine with the user's voice `< 0.28` → someone
  else; with two voices in a piece, also one ≥ 1.5 s that is 0.3 below the best unless it scores 0.45. A stretch under
  1.5 s is kept only beside a long stretch that is the user's; under 0.5 s it goes with the piece. Where two talk at
  once the user's turn wins. Dropped turns are zeroed with 10 ms ramps; a piece with nobody kept answers an empty
  text before the speech model is loaded.
- **Enrollment**: Settings asks the user to read a passage aloud (≥ 6 s of speech; it stops by itself at ~12 s of
  speech or 2.5 s after the reading ends; 60 s at most) with the microphone they dictate with. The CLI does it
  (`transcribe.py voiceprint enroll`), so the warm server never waits for a download; the download starts when the
  sheet opens. The switch can only be turned on once a voice is learned.
- **Learning**: a piece with one voice only, ≥ 3 s, scoring ≥ 0.5 **against the enrollment take** (not the grown
  profile, so it can't drift) joins the profile (one per 20 s, the latest 40). v1 learned whole cuts against the
  grown profile and took in the friend: his line scored 0.27 against the enrollment, 0.38 against the profile.
  Profiles from v1 keep their enrollment and drop what v1 learned.
- **Profile**: `$BLURT_HOME/voiceprint.json` (0600). A profile another model made is `stale` and never used.
- **What is kept**: the take's audio as recorded (the gate works on the copies recognition hears), and the spans left
  out, as `voice_dropped` in the history entry — enough to see, replay or judge again what was removed.

## 2. Where it applies

Only dictation (`purpose == "dictation"`). Voice notes and recordings keep everyone who speaks.

| Path | How it is gated |
|---|---|
| Local model, pieces | `note` gates each piece; the verdict (`speaker.drop`) goes back to the app |
| Hearing again (windows) | the app silences what its pieces dropped and sends `voiceprint: false` (no second verdict); the last piece, heard only in its window, is judged with the window |
| Second transcript (macOS's recogniser beside a cloud polish) | asked only after the verdicts, on the masked audio |
| Live text (interim) | gated too, but only cuts with ≥ 1.5 s of speech are judged: a shorter one is too little to tell, and the final piece decides it |
| macOS's recogniser as the dictation model, or a cloud model's live text | the server judges the piece first (`vp_gate`), macOS's recogniser hears the masked audio; the server starts for this even when no speech model is used |
| Cloud model, whole take at key-up | `note` gates the whole take (~0.2 s for 30 s of audio) |
| Volcengine streaming | the audio goes out as it is said; at key-up the server gates the take while it waits for the final text and leaves out the sentences (`show_utterances` times) that lie mostly in dropped spans |

Not covered: words said over each other (the user's turn wins); the safety path when macOS's recogniser is the
dictation model (whole take, ungated).

## 3. Measurements (2026-11-01, M5 Max)

**Data.** "Me": the founder's 174 kept dictation takes (42 min, 2026-10-31 and 11-01). Enrollment from the first day,
tests on the second. "Others": 320 real utterances from AISHELL-1, ASCEND, LibriSpeech clean/other, Common Voice de/ja,
level-matched 6 dB below the founder's speech (±) and mixed with the founder's own room tone, as a colleague through
the same microphone. "Mixed": one of the founder's pieces, 0.7 s, someone else's utterance, 0.7 s, the founder's next
piece. One 60 s take (`d-20261101-104040-2ba6`) scores like another speaker throughout: 8× the usual energy above
4 kHz, 6 dB quieter, and it sounds like a livestream played aloud. It is excluded below and reported apart.

**Model choice** (every cut, 20 s enrollment, one threshold per model, the founder's speech dropped / other speech
passed):

| Model | founder dropped / others passed (threshold) | EER by cut length 1–2 s / 2–3 s / 3–5 s / 5 s+ |
|---|---|---|
| ERes2Net base 3D-Speaker (the first version) at 0.50 | 17.3 % / 0.6 % (39 % of takes touched) | 5.6 / 3.1 / 4.2 / 3.7 % |
| ERes2Net base 3D-Speaker at 0.30 | 3.2 % / 5.6 % | |
| ERes2Net base 200k | 2.7 % / 2.1 % at 0.30 | 3.0 / 0.3 / 2.7 / 2.7 % |
| ERes2Net v2 200k (71 MB) | 2.2 % / 5.3 % at 0.30 | 3.1 / 0.0 / 2.6 / 2.3 % |
| ERes2Net large (116 MB) | 3.3 % / 5.9 % at 0.30 | 5.1 / 1.4 / 3.7 / 3.9 % |
| WeSpeaker ResNet34 CN-Celeb | 2.2 % / 2.5 % at 0.575 | 0.4 / 0.5 / 1.3 / 2.6 % |
| CAM++ zh-cn 200k | 3.9 % / 2.4 % at 0.30 | 0.3 / 0.7 / 3.1 / 3.7 % |
| **CAM++ zh-en advanced (28 MB)** | **0.6 % / 2.0 % at 0.225** | **0.2 / 0.0 / 2.0 / 0.7 %** |

These "dropped" figures include the livestream-like take. The first version's 0.5 threshold came from `say` voices,
which score far higher against themselves than a real voice does; on real speech it dropped 17 % of the founder's
words.

**CAM++ zh-en, dictation-shaped pieces, the outlier excluded:**

| Enrollment | Threshold | Founder's speech dropped | Takes touched | Others' speech passed | Mixed: other passed |
|---|---|---|---|---|---|
| 20 s | 0.25 | 0.06 % | 0.3 % | 1.5 % | 2.3 % |
| 20 s | 0.275 | 0.16 % | 1.2 % | 0.7 % | 0.1 % |
| 20 s | 0.30 | 0.57 % | 2.5 % | 0.6 % | 0.1 % |
| 20 s + learning | 0.275 | 0 | 0 | 0.7 % | 0 |
| 20 s + learning | 0.30 | 0 | 0 | 0.5 % | 0 |

Length-aware thresholds and a neighbour rule (a short cut next to a kept one stays) changed nothing on ≥ 3 s pieces;
scoring by the best three enrollment windows instead of their mean let more of the others through as the profile grew.

**Speed and memory**: CAM++ embeds in ~3.5 ms per second of audio (5 s piece: 19 ms; ERes2Net base: 45 ms), loads in
0.17 s (preloaded with the server when the switch is on).

**As shipped** (`tests/bench_voiceprint.py`: 20 s enrollment from the first takes, 166 takes / 420 pieces tested in
order with learning, all takes included; pauses between speakers are the founder's room tone):

| | |
|---|---|
| Founder's speech dropped / takes touched | 0 / 0 |
| Others alone: speech passed / pieces typed at all | 0.6 % / 1.3 % |
| Others between two of the founder's sentences (0.7 s pauses): passed | **16 %** |
| … founder's speech dropped in those | 0.14 % |
| Gate cost (VAD + embeddings) | 6.5 ms per second of audio |

End to end through the speech server's path (`NoteEngine.note`, Qwen3-ASR 1.7B MLX, 30 pieces each, gate off vs on):
the founder's pieces came out identical 30 of 30, +41 ms median (+123 ms p95) on 167 ms; others' pieces came out blank
30 of 30, in 60 ms instead of 216 ms (never decoded); mixed takes matched the founder's words alone 0.965 with the
gate, 0.586 without.

**3.3 v2 — the founder's hands-on test** (11 takes, 2026-11-01 19:53–20:00: he talks, a friend in the same room
answers about the settings' grey text, or a phone plays a video; turns follow each other within a fraction of a
second). v1: 9 of the friend's lines and the video wherever it ran into his speech were typed. v2, same takes, same
enrollment take: all the friend's lines and all the video left out, every word of his kept, +30–200 ms per take.
Per speaker, his voice 0.68–0.84, the friend 0.17–0.27, the video 0.09–0.20.

**v2 on the benchmark** (what recognition hears: speech energy left after the gate; others between two of the
founder's sentences with 0.15 s pauses of his room tone):

| | v1 | v2 |
|---|---|---|
| Others alone: speech passed | 0.6 % (time) | 0.3 % |
| Others between two of his sentences: passed | ~16 % (time) | 2.3 % |
| His speech dropped (mostly clicks and breaths: their scores ≈ 0) | ≈ 0 | 1.3 % |
| His words lost (420 pieces, text gate off vs on, no learning) | — | 27 characters in 12 pieces |
| End to end, Qwen3-ASR 1.7B: his pieces identical / others blank | 30 / 30, 30 / 30 | 29 / 30, 30 / 30 |
| Mixed pieces, match with his words alone (off → on) | — | 0.62 → 0.91 |
| Added per piece (median) | +41 ms | +101 ms |

Tried: threshold 0.33 / 0.38 (fewer others typed, 0.94 → 0.63 %, more of his speech lost); no margin rule (barely
different on the benchmark; it is what keeps a voice close to his out — the friend scored up to 0.27).

## 4. Not measured

- More real colleagues: one friend and one phone video in the founder's room (§3.3); the benchmark's others are
  corpora recorded elsewhere, mixed with his room tone.
- Other users' voices as "me" (only the founder's), AirPods / Bluetooth microphones, Intel Macs.
- Volcengine streaming with the gate (the filter is unit-tested on its sentence times, not run against the service).

Rerun: `tests/bench_voiceprint.py` (header has the command); model comparison scripts were one-off.
