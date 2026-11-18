# Silent dictation: active acoustic sensing on the Mac's own speakers and mic

Question: can the built-in speakers and mic work as a sonar on the mouth at laptop distance, with no added hardware, and does that add information beyond the camera? Tool and analysis live in `tools/silent-dictation/acoustic/`. Raw captures stay in `~/Library/Application Support/Blurt VSR Pilot/acoustic/`.

Status: stage 1 measured, tool built. Stage 3 criteria below were fixed before any person ran a test.

## Stage 1: hardware (Mac17,6, MacBook Pro M5 Max, macOS 26), no person needed

Pass rule set before measuring: at least 3 kHz of usable band above 17 kHz, no AGC, echoes stable with nothing moving. **Passed.**

| Item | Measured |
| --- | --- |
| Rates | Speakers and mic each 44.1, 48, 88.2, 96 kHz; same clock domain |
| Mic channels | One mono channel only; the array is not exposed, and common hidden device UIDs do not resolve |
| Speaker channels | Two; left reaches the mic about 15 dB louder than right |
| Top of the mic path | About 23.2 kHz at 48 kHz, about 22 kHz at 96 kHz, nothing above in either. 96 kHz gives no gain |
| Usable band | 17.5 to 23 kHz, 5.5 kHz, so about 3 cm of one-way range resolution. Response varies about ±6 dB across it |
| Speaker wake | Output reaches full level about 180 ms after start |
| AGC | None seen. Gain within 2 dB from -46 to -20 dBFS at system volume 0.19 |
| Compression | -14 dBFS loses about 1.4 dB, and gain stayed about 2 dB lower for the next 4 s. So stay at or below -20 dBFS unless a test needs more |
| Echo noise, nothing deliberately moving | Direct path -76.6 dB, echoes -85 to -90 dB at 40 to 80 cm extra path, noise -118 dB per 20 ms frame. Phase jitter 0.02 to 0.03 rad, about 0.04 mm of one-way motion at 20 kHz |
| Audible leakage | 200 Hz to 15 kHz within 1 dB of silence; no start click with a 100 ms ramp |

Voice processing is off in this path: the app reads the raw HAL input through a private aggregate device, in one callback with the output, so delay is fixed within a run.

Probe chosen: band-limited periodic chirp, 960 samples (20 ms), left and right speakers offset by half a period so each has its own delay window. It repeats without a click because it contains only FFT bins inside the band. Level -20 dBFS at system volume 0.19, restored afterwards.

The 0.04 mm figure is a noise floor on a static scene, not a demonstration that a mouth is visible.

## Stage 3: criteria fixed before running

Scores use energy of echo change (1 to 14 Hz) in 30 to 170 cm of extra path. AUC is each condition against still trials unless stated. Classifiers use leave-one-round-out cross-validation.

| Test | Pass | Stop or meaning of failure |
| --- | --- | --- |
| 1 Hand | `hand_big` AUC ≥ 0.95, `hand_fingers` ≥ 0.90 | Fail means a setup bug: fix before going on |
| 2 Mouth, 45 cm | `mouth_big` ≥ 0.90, `mouth_silent` ≥ 0.85; silent mouthing separated from blink/brow and breath at AUC ≥ 0.85; sonar predicts held-out lip gap at r ≥ 0.5 with mismatched-trial control ≤ 0.2 | `mouth_silent` < 0.70 after one 6 dB level rise: stop, no-go |
| 3 Head | Silent mouthing vs nod, shake, sway at AUC ≥ 0.85; mouthing during a nod vs nod alone ≥ 0.75 | Fail: no-go for use without holding still |
| 4 Range | Farthest distance with mouth vs still AUC ≥ 0.85 | Reported as the working range; 45 cm must pass |
| 5 Syllables | 8-way sonar alone ≥ 25% (chance 12.5%), permutation p < 0.01. Adds information if sonar plus camera beats camera by ≥ 5 points with the 95% interval above 0, overall or on the pairs d/g and z/zh | Fail: sonar sees motion but not speech content |

**Go** for fusing with the visual model needs tests 2, 3 and 5 to pass. Otherwise no-go, with the reason.

Level may rise to at most -14 dBFS or system volume 0.5, only if a test needs it, and the user is asked whether anything is audible.

## Stage 3 results so far

### System volume and probe level

The volume scalar is a dB taper. Measured direct-path level against 0.19: 0.25 +4 dB, 0.31 +8, 0.38 +12, 0.44 +16, 0.5 +19, 0.625 +24. The app now holds its volume during a run and restores the user's afterwards: the first hand runs happened at 0.625 because the user had changed the volume, which the first build did not prevent. The user heard nothing at 0.625.

### Test 1, hand (probe -20 dBFS at volume 0.625)

Two complete runs, 6 trials per condition. Run 2: `hand_big` and `hand_fingers` both AUC 1.00 against still, about 20 dB above still. **Pass.** Run 1: both 0.83, not yet explained; run 2 is the user's clean run.

### Test 2, mouth, first run at volume 0.19 (as planned)

7 trials per condition. A nearby conversation began during trial 22, which the user voided and redid. Voice-band audio confirms speech at 165 to 234 s and none in any kept trial. Every frame had a face, no audio gaps, no dropped video frames.

| Condition | AUC against still (both speakers) |
| --- | --- |
| `mouth_big` | 0.98 |
| `mouth_small` | 0.92 |
| `mouth_silent` | 0.76 |
| `blink_brow` | 1.00 |
| `breath` | 0.47 |

**Not a pass, not a stop.** `mouth_silent` falls short of 0.85. Blinking and raising the brows give more echo change than mouthing, so energy alone cannot tell them apart. Mapping echo change by distance shows why the level is too low: the face sits at 71 to 143 cm of extra path, where still trials are only about 3 dB and silent mouthing about 5 dB above the -126 dB noise floor. So the result is limited by signal-to-noise, not yet by physics. Following the rule above, test 2 is rerun at volume 0.5 (+19 dB), and later tests use 0.5. The 0.19 run is kept as a level comparison.

### Test 2, mouth, rerun at volume 0.5 (+19 dB)

42 trials, none voided, no gaps or dropped frames. The user heard nothing.

| Measure | Volume 0.19 | Volume 0.5 | Preset |
| --- | --- | --- | --- |
| `mouth_big` vs still, energy AUC | 0.98 | 1.00 | ≥ 0.90 |
| `mouth_silent` vs still, energy AUC | 0.76 | 0.98 | ≥ 0.85 |
| `mouth_silent` vs blink/brow + breath, cross-validated classifier AUC | 0.98 | 1.00 | ≥ 0.85 |
| `mouth_silent` vs blink/brow alone | 1.00 | 1.00 | |
| `mouth_small` vs blink/brow + breath + still | 0.88 | 0.99 | |
| Lip gap from sonar, held-out r, silent (mismatched control) | 0.19 (0.14) | 0.35 (0.05) | ≥ 0.5 (≤ 0.2) |
| Lip gap, big (mismatched control) | 0.41 (0.16) | 0.64 (0.41) | |

The classifier uses log echo-change energy per 7 cm gate per speaker in 1-4 Hz and 4-12 Hz, plus a Doppler direction term, with leave-one-round-out cross-validation (`score_mouth.py`).

**Detection passes; tracking lip gap does not, by the preset measure.** Silent mouthing is detected and told apart from blinking, brow raises and breathing. The classifier may partly use the cued rhythm (2 Hz mouthing against 1.5 Hz blinking), which test 3 has to rule out. The mismatched control for `mouth_big` is high because cued trials share timing, so that control is weak for rhythmic trials.

Exploratory, chosen after the preset measure failed: a ridge model on phase-derived displacement per echo bin (`explore_lipgap.py`) gives held-out r 0.51 for silent, 0.46 for big and small, and 0.05 or below when the prediction is shifted in time within the same trial. Because this method was picked after seeing the data, it is fixed now and rerun unchanged on test 3's silent-mouthing trials. It counts only if r ≥ 0.4 with the shifted control ≤ 0.15 there.

Test 3 criteria are unchanged from above, using the same classifier code.

### Test 3, mouth vs head movement (volume 0.5)

Session `head-2026-11-08T07-59-19Z`: 42 trials, none voided, no gaps or dropped frames, 30 fps video. The user heard nothing. Two Blurt start chirps from another session landed in trial 30 (`nod`) at 226.08 s and 226.20 s, each about 0.1 s, peaking near 3 kHz, 38 dB above the room. Probe-band (17.5-23 kHz) level moved by at most 0.6 dB over the whole session, with no change at the chirps, and scoring without trial 30 gives the same verdicts. Audible sounds below the probe band do not reach the echo profile.

Echo-change energy, 30-170 cm extra path, both speakers summed (`analyze.py`):

| Condition | Median dB | AUC vs still |
| --- | --- | --- |
| `still` | -83.3 | |
| `mouth_silent` | -79.9 | 0.88 |
| `nod` | -68.6 | 1.00 |
| `shake` | -70.1 | 1.00 |
| `sway` | -67.7 | 1.00 |
| `mouth_plus_head` | -68.5 | 1.00 |

Gentle head movement gives about 11 dB more echo change than silent mouthing.

Preset tests, same classifier as test 2 (`score_head.py`):

| Measure | AUC | Preset |
| --- | --- | --- |
| `mouth_silent` vs nod + shake + sway | 1.00 | ≥ 0.85, pass |
| `mouth_silent` vs each of nod, shake, sway, still | 1.00 | |
| `mouth_plus_head` vs `nod` | 0.49 (0.43 without trial 30) | ≥ 0.75, **fail** |
| Camera only, variance of lip gap / face width, `mouth_plus_head` vs `nod` | 1.00 | for comparison |

Lip gap from sonar, fixed exploratory method (`explore_lipgap.py`, unchanged): held-out r for `mouth_silent` is -0.10, with the shifted control at -0.04 (counts only if r ≥ 0.4). Training only on the quiet trials (`mouth_silent` and `still`) gives -0.12. The block 2 r of 0.51 did not replicate, so it was most likely chance or overfitting.

**Test 3 fails, and that is a stop.** The first test passes only because head movement is about 11 dB larger than mouthing, so "small motion vs big motion" is easy. When the head moves while mouthing, the case that matters in real use, sonar cannot tell it from nodding alone (AUC at chance). The camera tells them apart perfectly. Sonar also does not track lip opening. Go needed tests 2, 3 and 5 to pass. Test 3 has failed, and the camera already does better at what sonar would add. So tests 4 (range) and 5 (syllables) cannot change the outcome and were not run.

## Verdict: no-go on fusing this sonar with the lip model

- **What works:** on this MacBook, an inaudible 17.5-23 kHz probe at -20 dBFS, system volume 0.5, sees a hand and gross mouth movement at about 45 cm, with no added hardware, clicks or audible leakage. It detects silent mouthing against a still head and blink, brow or breath movements (AUC 0.98-1.00).
- **What fails:**
  - Head movement swamps the mouth signal by about 11 dB, and sonar cannot separate mouthing from nodding when both happen together (AUC 0.49).
  - Lip-opening tracking does not hold up across sessions.
  - The single mono mic and two speakers give one range axis and no angle, so the face cannot be isolated from the rest of the head.
- **Information beyond the camera:** none found. The camera separates every case sonar fails on.
- **What could change this:**
  - More mics with array access, which Apple does not expose (`hwinfo.swift`: one mono input).
  - A wider band; the mic path cuts off near 23 kHz even at 96 kHz.
  - Using the camera's head pose to cancel head motion in the echoes. That makes the camera do the work, so it is not worth it for this product.
- **Raw data kept** in `~/Library/Application Support/Blurt VSR Pilot/acoustic/`: `hw/` and `sessions/`, including the discarded and aborted runs.

## Follow-up: would a SAR-style method do better? Other Mac sensors

**The probe is already radar-style.** It is a chirp with matched filtering, the same pulse compression SAR uses for range. Range resolution is c/2B = 343 / (2 × 5500) ≈ 3.1 cm. That is set by the band: the mic path cuts off near 23 kHz, and below about 17 kHz the probe becomes audible. Sensitivity is not the problem, since phase jitter is about 0.04 mm.

**SAR's other axis needs an aperture, and this Mac has none.** SAR gets cross-range resolution from a long synthetic aperture, made by moving the sensor. Here the laptop is still. There are two speakers about 30 cm apart, and macOS exposes only one beamformed mono mic. Two virtual elements at λ ≈ 1.7 cm give grating lobes, not an image. So mouth, chin, cheeks and the rest of the head fall into the same 3 cm range cells with no angle to tell them apart.

**ISAR-style compensation doesn't help either.** Inverse SAR uses the target's own motion instead. As a sonar-only stand-in, `explore_motioncomp.py` removes the k largest coherent motion components across echo bins per trial, standing in for rigid head motion, and scores what is left. Over 10 settings (k = 0-5, 1-12 Hz or 4-12 Hz), `mouth_plus_head` vs `nod` ranges from 0.12 to 0.65. That is no better than chance for 7 vs 7 trials tried 10 ways.

**Other sensors on this Mac** (`sensors_probe.swift`, no root):

| Sensor | Found | Readable |
| --- | --- | --- |
| Lid angle | yes (sensor page 0x20, usage 0x8A) | yes, feature report (read 122°) |
| Accelerometer, gyro, ambient light (SPU HID, vendor page 0xFF00, usages 3, 9, 4) | yes, 8 ms report interval | devices open, but no reports arrive even after setting the driver's reporting properties; probably needs root |
| Camera, mic, speakers | yes | yes |

None of these gives spatial information about the face.
