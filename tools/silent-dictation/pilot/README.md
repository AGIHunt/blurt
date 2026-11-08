# Local silent dictation pilot

The native recorder, offline preparation, English evaluation, and bounded personalization are implemented. Separate research probes now run Mandarin CMLR and multilingual ViSpeR inference and ViSpeR adaptation. The app is built at `~/Library/Application Support/Blurt VSR Pilot/PilotRecorder.app`. The current Chinese-first dataset is `~/Library/Application Support/Blurt VSR Pilot/datasets/speaker-01-tech-zh90-v1`; there is no upload, transcription service, or production integration. The earlier balanced dataset and app build are preserved separately.

The November 6 workflow update adds keyboard capture/review, persistent audio preference, fixed 1× playback, and built-in microphone preference. The earlier participant run was retired at the participant's request. As of November 7, the replacement training session has 40 verified clips (122.43 seconds), and validation has 40 (152.81 seconds). Test remains unrecorded. The separate `train-03` expansion is now selected in the recorder, with 50 pending takes (40 new natural-silent phrases and ten voiced pairs); original recordings and holdouts are preserved.

## Start recording

The interface follows the Mac's preferred language by default. The **Interface language / 界面语言** selector supports **Follow system**, **English**, **简体中文**, and **繁體中文**. It switches the recorder's controls, instructions and status messages immediately, and remembers the choice across launches. Unsupported system languages fall back to the next supported preferred language, then English. Native macOS permission dialogs use the system/app language; localized camera and microphone descriptions are bundled. The interface setting does not translate or change assigned recording prompts, reference text, session IDs, or dataset language labels.

Open the app, or run from the repository:

```sh
zsh tools/silent-dictation/pilot/run.sh open
```

1. Begin with `train-02`. **Space** enables the camera if needed and starts recording; **Space** again stops. Pause briefly before and after articulating the displayed sentence in the specified mode. A take stops automatically at 30 seconds.
2. **P** replays from the start at **1×**. **R** discards the unfinished take and immediately starts a retake. Correct the reference if necessary, then **Enter** confirms the displayed text and saves/advances; the Save button has the same explicit confirmation meaning, without a separate checkbox. Shortcuts ignore key repeats and do not intercept text editing or IME composition. **Esc** leaves text editing. Silent modes never add a microphone input. The optional audio choice persists across takes, sessions and launches, including across silent takes. Capture prefers the built-in microphone to avoid Bluetooth call-mode transitions, displays its name, and records the device/sample rate in metadata. The recognition pipeline always strips audio.
3. Turn the camera off to switch sessions. Collect `validation-02` in a separate sitting. Collect `test-02` on a different day, without rehearsing its phrases during training. Do not change training settings based on repeated test results.
4. The app resumes unsaved takes on reopening. Closing the last window quits it. Local unsaved `draft-*.mov` files can remain after a crash; they are excluded from training/evaluation until a verified manifest exists. Do not run two recorder instances on the same dataset.

The `tech_zh90_v1` starter plan contains 30 phrase families × 4 articulation modes = 120 takes: 40 training, 40 validation, 40 test. Each split and each mode contains 60% Mandarin-only, 30% Mandarin with English terms, and 10% English. Thus Chinese-dominant utterances are 90%; this is an utterance ratio, not a measured duration/token ratio. AI/tech content is 70%, with 30% general language to retain breadth. Mode order rotates by phrase. Families stay in one split; vocabulary intentionally includes held-out technical terms.

This is a small functionality/pilot set, **not** enough to establish general dictation quality or useful personalization. It contains just one English phrase family per split, so English comparisons are particularly underpowered. Keep framing and lighting consistent for the first session, then measure realistic variation separately. Future enrollment should expand phonetic, speaker, accent and task coverage, not repeat these phrases to inflate data volume.

The original `run.sh adapt/evaluate` commands remain English-only and require `--language en`. Use the separate multilingual probes below for Mandarin/mixed diagnostics. `language_metrics.py` scores CER, WER and mixed character/word MER. Actual participant results and their limitations are in the [language and compute follow-up](../../../docs/design/silent-dictation-zh-tech.md); no current model meets the natural-silent dictation acceptance gate.

## Multilingual research probes

The research runtime includes the author checkouts `visper` and `multilingual-vsr`, their separate research weights, and Lipflow's MediaPipe face model. These are not commercial product dependencies. Use Python 3.11 from `runtime/model-venv`; additional probe dependencies are `mediapipe==0.10.21`, `hydra-core==1.3.8`, `PyYAML==6.0.3`, and `opencc-python-reimplemented==0.1.7`, alongside the model environment's PyTorch, NumPy, OpenCV and SentencePiece. Direct E2E imports avoid Fairseq/Lightning for inference and these bounded adaptation probes.

```sh
pilot_data="$HOME/Library/Application Support/Blurt VSR Pilot/datasets/speaker-01-tech-zh90-v1"
pilot_runtime="$HOME/Library/Application Support/Blurt VSR Pilot/runtime"
pilot_python="$pilot_runtime/model-venv/bin/python"

# Run native preparation first for any new verified footage.
zsh tools/silent-dictation/pilot/run.sh prepare
# Separate reference-wrapper crops; never overwrite native crops or original video.
"$pilot_python" tools/silent-dictation/pilot/reference_crops.py "$pilot_data" \
  --checkout "$pilot_runtime/lipflow"

# Choose a fresh output path for every run. This command requires validation footage.
"$pilot_python" tools/silent-dictation/pilot/multilingual_probe.py "$pilot_data" \
  --backend visper --checkout "$pilot_runtime/visper" \
  --checkpoint "$pilot_runtime/visper/visper_vsr_base.pth" \
  --crop-folder prepared-mediapipe --split validation \
  --output "$pilot_data/runs/visper-validation-stock-v1.json"

# Frozen adapter from the completed all-mode development experiment.
# Repeat with visper-adapt-silent-development-v1.pth to compare the silent-only variant.
"$pilot_python" tools/silent-dictation/pilot/multilingual_probe.py "$pilot_data" \
  --backend visper --checkout "$pilot_runtime/visper" \
  --checkpoint "$pilot_runtime/visper/visper_vsr_base.pth" \
  --crop-folder prepared-mediapipe --split validation \
  --adapter "$pilot_data/runs/visper-adapt-development-v2.pth" \
  --output "$pilot_data/runs/visper-validation-adapted-v1.json"
```

`multilingual_probe.py` never sends reference text to its decoder, but supplies the planned dominant-language tag (`<zh>` for mixed clips). Automatic language detection is not evaluated. Default beam is 10; these are task-specific experiments, not reproduction of published benchmark settings. CMLR additionally takes `--config`, and optional paired `--lm`/`--lm-config`; its vocabulary cannot represent English letters.

By default, `visper_adapt_probe.py` uses only clips labeled `train`, reserves whole families `document_summary` and `umbrella`, and saves the best development-loss epoch, including epoch zero. `--epochs 10 --max-seconds 600` is a bounded run; `--train-modes silent exaggerated_silent` performs the mode ablation. The reserved clips stay in their original training session: this diagnostic does not turn them into independent validation. With `--development-split validation`, complete training and validation recordings are required; all selected training clips receive gradient updates, and separate validation clips choose the best epoch without gradient updates. Test footage never participates. This new option completed a 40-train/40-validation run. Adapters are approximately 103 MB and need the exact base model; the newer probe validates checkpoint/adapter hashes, crop variant, speaker and fit-media exclusion before evaluation.

`score_probe.py --baseline <stock.json> --adapted <development.json> --output <new.json>` reports paired strict and OpenCC script-normalized development scores. Script normalization is explicitly post-hoc and preserves the original result files. `benchmark_multilingual.py` measures offline warm ViSpeR decoding on the longest natural-silent training clip per language profile with three warm repeats. `command_probe.py` is a separate ten-known-command retrieval diagnostic; its template matching must not be presented as unrestricted transcription.

The same scoring command accepts two complete evaluation runs on the same split. It rejects different coverage, source footage, references, weights or preprocessing. Scoring policy was fixed before the fresh validation comparison. `visper_crops.py` invokes the author ViSpeR crop functions with MediaPipe-derived five-point observations, keeping outputs in `prepared-visper5`; it needs `PyArabic==0.6.15` for the upstream module import. It tests crop geometry, not original detector parity. `phonetic_diagnostic.py` uses `pypinyin==0.55.0` to measure text-derived toneless-syllable error and enrollment coverage; these are not phonetic annotations or a Pinyin recognizer.

`multilingual_probe.py --backend cnvsrc` uses the isolated CNVSRC2025 `VSR` checkout, its `datamodule/char_units.txt` and visual config. The author prediction script uses beam 40 and CTC weight 0.3, exposed through `--beam 40 --ctc-weight .3`. Its vocabulary has no ASCII alphabet tokens; select `--profiles zh` for the Mandarin comparator. Research/comparison restrictions apply.

`expansion_draft.py <dataset> --output <new.json>` prepares a separate 40-phrase/50-take enrollment draft, with 40 natural-silent takes and ten matched voiced takes. It verifies family/prompt separation and the 90% Chinese-dominant/70% technical quotas. It does not modify the active plan, assign verified labels, open capture, or promise an accuracy improvement. Existing validation and test families remain reserved.

## Rapid recording

`RapidRecorder` records one long take with camera and microphone instead of one file per prompt. It kept about 9 clips a minute in the first two sessions.

```bash
./build-rapid.sh
open "$HOME/Library/Application Support/Blurt VSR Pilot/RapidRecorder.app"
```

Space moves to the next segment, Delete or Left voids the last one and redoes it, Esc ends the take. Modes: voiced then silent (pairs, the default), silent only, voiced only, free talk (see below). Segments under 0.6 s are not written. `--dry` runs without saving; quit a dry instance before opening the real app, or the real one will not be the one that opens.

`rapid_script.py` builds `rapid/script.json` and a never-shown `script-test.json` from the newest 15% of Blurt history. These sentences come from the user's own messages and stay on this Mac: do not send them to a cloud model without asking.

After a take, cut and crop it:

```bash
"$R/model-venv/bin/python" rapid_cut.py "<session dir>"
```

It cuts by the marks, checks voiced segments against the script with mlx-whisper, drops silent segments where the participant spoke aloud, tracks with MediaPipe, and writes `clips/<n>/rois.npy` plus `clips.json`. It warns when median sharpness is under 120.

To evaluate, pass sessions to `personal_ft.py --rapid`. Each fold holds out a fifth of the rapid sentences, and paired takes of a sentence stay together. `--no-pilot` scores rapid clips alone, `--fit-modes` and `--score-modes` restrict training and scoring, and `--epochs 0` gives the untrained baseline on the same folds. Output JSON is rewritten after every fold, so a file read during a run is partial. `compare_runs.py` prints paired tables from finished runs.

## Free talk

The fastest way to add personal data. Open the recorder, choose 随便说, press Space and keep talking; pause between sentences. Space changes the prompt, Esc ends. No script and no key per sentence. Then:

```bash
./talk.sh
```

It transcribes each sentence with Qwen3-ASR and Whisper, opens a browser page for the sentences where they disagree, cuts the take into crops, and reopens the recorder on `shadow.json` so you can mouth about 40% of your own sentences. Label what was actually said, including slips. Enter accepts, Tab swaps in the other transcription, Ctrl+D drops, Ctrl+R replays. Everything runs on this Mac. After mouthing, cut that session with `rapid_cut.py`; matching `line` ids keep the pairs together. These tools use `runtime/asr-venv` (`uv pip install qwen-asr mlx-whisper rapidfuzz pypinyin`).

`asr_oracle.py` measures how much degradation the frozen Qwen3-ASR decoder tolerates in its audio features.

## Prepare and compare

The installed research runtime is preserved under `~/Library/Application Support/Blurt VSR Pilot/runtime` so it does not depend on temporary experiment files. It contains the pinned Lipflow research checkout and weights, a minimal model environment, and the native Vision probe. The crop stage uses the host's Python, NumPy, OpenCV, FFmpeg, and FFprobe. This is a local developer setup, not a distributable installer; see the parent README for reproducible dependencies and license constraints. The copied Python environment's package-manager entry points can reference its original location; use its `bin/python` as the wrapper does, or rebuild the environment to maintain it.

```sh
# Check how many references have been verified.
zsh tools/silent-dictation/pilot/run.sh audit

# Normalize to 25 fps, remove audio, track with Vision, and create mouth crops.
zsh tools/silent-dictation/pilot/run.sh prepare

# Optional English-only baseline. This does not train Mandarin or code-switching.
# Choose the best validation-loss epoch.
# A new output filename is required. Nothing is installed in Blurt.
pilot_data="$HOME/Library/Application Support/Blurt VSR Pilot/datasets/speaker-01-tech-zh90-v1"
zsh tools/silent-dictation/pilot/run.sh adapt \
  --language en --epochs 6 --max-seconds 1800 --output "$pilot_data/models/silent-v1.pth"

# Once test recordings exist, prepare again and run matched test evaluations.
zsh tools/silent-dictation/pilot/run.sh prepare
zsh tools/silent-dictation/pilot/run.sh evaluate \
  --language en --output "$pilot_data/runs/stock-test-v1.json"
zsh tools/silent-dictation/pilot/run.sh evaluate \
  --language en --adapter "$pilot_data/models/silent-v1.pth" \
  --output "$pilot_data/runs/adapted-test-v1.json"
zsh tools/silent-dictation/pilot/run.sh compare \
  "$pilot_data/runs/stock-test-v1.json" "$pilot_data/runs/adapted-test-v1.json" \
  --output "$pilot_data/runs/comparison-v1.json"
```

For a different dataset/runtime, set `VSR_PILOT_DATASET` / `VSR_PILOT_RUNTIME`. New datasets default to `--profile tech_zh90_v1`. To collect English only, create a separate dataset with `python3 tools/silent-dictation/pilot/dataset.py init /absolute/new/path --speaker speaker-02 --languages en --profile balanced_v1` and use the dataset override. Do not remove already captured entries from an experiment plan to hide unsuccessful takes.

## What the reports mean

- WER is total word edits divided by total reference words, grouped by mode. Case and punctuation are ignored; number formats are not normalized. WER can exceed 100% from insertions. Exact match is also reported.
- Every verified English clip in the selected split is counted, including failures. A pipeline failure yields an empty hypothesis and all reference words count as deletions. Missing/unrecorded planned takes are reported as incomplete coverage, not invented observations. Failed preprocessing requires investigation or a documented retake; it must not quietly disappear from comparisons.
- Preparation rejects clips with fewer than 95% usable anchor frames, any multiple-face frames, unexpected audio tracks, or duration over 32 seconds. These are initial engineering thresholds, not validated acceptance criteria. Native alignment remains experimental.
- Timing is warm offline inference, with preparation reported separately. It excludes capture, UI interaction, correction and insertion. The current tools do **not** measure corrected words/minute, task-specific name/number accuracy, fatigue, or audio-ASR accuracy. Those require a subsequent task study/baseline integration.
- Session/family overlaps, identical references across splits, copied source videos across splits, stale crops, wrong-speaker adapters, and changed checkpoint hashes are rejected. Same-day test/adaptation collection is flagged. Semantic paraphrase leakage still needs human review.
- Adaptation is frontend + embedding + first encoder layer, not LoRA. BatchNorm statistics stay frozen. It uses only selected training modes (default `silent`), a fixed seed, AdamW, and a mean per-clip validation loss to select a snapshot. The stock model is epoch zero and remains selected if no full epoch improves validation loss. Test footage is never used for gradient updates or model selection; its metadata/hashes are read for leakage checks.
- Limits are 30 minutes of input, at most 30 epochs, and at most a requested hour of training/validation. The default budget is 30 minutes, checked between clips; an in-flight clip/snapshot can exceed it. Model loading is outside that budget. These are bounded research runs, not a measured billing estimate. Test WER must establish whether personalization helps.
- The source wrapper's license does not clear pretrained weights or derived adapters for commercial distribution. Keep this pilot separate from shipping/paywalling a model until rights are resolved.

## Validation performed

The app compiles and its idle UI was inspected with capture off. Automated checks cover reference verification, silent-audio metadata, split leakage, stale preparation, copied videos, metric aggregation, and matched comparisons. A separate public-video fixture completed normalization → Vision → mouth crops → one real training epoch/validation → adapter save/reload → stock/adapted inference → comparison. Fixture references were deliberately approximate software-test labels, so its error scores are **not accuracy evidence**. The fixture never enters the participant dataset.

On 2026-11-06, opening review initially aborted inside `_AVKit_SwiftUI` superclass metadata initialization. Review now embeds AppKit `AVPlayerView` instead of SwiftUI `VideoPlayer`. A public-video fixture passed recovery, playback, save, and journal cleanup through the native UI; the participant subsequently saved 12 takes. At take 13 the participant reported slow playback and requested a fresh run after workflow improvements. The old audio used a 24 kHz AirPods input. Bluetooth route switching is a plausible contributor, not a proven sole cause. Replay now resets both default and active rate to 1×, and native speed controls are hidden. A synthetic fixture measured 2.112 media seconds in 2.111 wall seconds, including a deliberately stale 0.5× default rate before replay.

Live UI checks covered Space start/stop, R retake with camera off and on, P playback, Enter save/advance, editing protection, and retention of the audio choice across silent/voiced takes. The new voiced fixture used the built-in microphone at 48 kHz: 3.317 seconds between capture-start callback and Stop, 3.400 seconds of video and 3.307 seconds of audio. The silent fixture had no audio track. These checks establish timing and recorder behavior, not subjective speech quality or recognition accuracy. Camera-start testing also exposed a preview/session deadlock; a single preview layer is now attached before session configuration begins and reused across review transitions. Retired participant footage, old prepared crops, and software fixtures are outside the active dataset.

New recordings write durable take context to `pending/` before capture begins. The latest unfinished draft for the selected session is restored when the app reopens. Pending metadata is kept outside `clips/` so it cannot be mistaken for verified training data. An older unjournaled clip can be opened explicitly with `--recover-draft /absolute/dataset/clips/draft-....mov`; this associates it with the current take, records legacy-recovery provenance, and still requires the participant to review and confirm the actual text. Recovery never marks a reference verified automatically.

```sh
python3 -m unittest discover -s tools/silent-dictation/pilot -p 'test_*.py' -v
zsh tools/silent-dictation/pilot/build.sh
# Synthetic playback timing, recovery, submission and preference regression (no camera).
zsh tools/silent-dictation/pilot/check-recorder.sh
```

Check language resolution, persistence, message formatting and catalog completeness without opening a camera:

```sh
swiftc tools/silent-dictation/pilot/Localization.swift \
  tools/silent-dictation/pilot/LocalizationChecks.swift -o /tmp/blurt-pilot-localization-checks
/tmp/blurt-pilot-localization-checks "$HOME/Library/Application Support/Blurt VSR Pilot/PilotRecorder.app"
```
# Public dataset metadata audit

`public_data_audit.py` summarizes pinned Hugging Face metadata without downloading
media, training a model, or reading the personal corpus. It takes a directory with
`*-api.json` HF dataset snapshots, Chinese-LiPS `meta_train.csv`, `meta_valid.csv`
and `meta_test.csv`, and optional `multivsr-*.csv` files. Download those files using
the exact revisions in `../results/public-data-audit.json` to reproduce this audit.
Keep raw metadata outside the repository. The output includes file hashes, split
overlap, language counts, and literal Latin-token coverage; it does not verify
spoken code-switching, media quality, or permission to train a product.

```sh
python3 tools/silent-dictation/pilot/public_data_audit.py \
  "$HOME/Library/Application Support/Blurt VSR Pilot/runtime/public-data-audit" \
  --output /tmp/public-data-audit.json
```
