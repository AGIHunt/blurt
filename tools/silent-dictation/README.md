# Silent dictation experiments

Isolated research tools for [the feasibility report](../../docs/design/silent-dictation.md). No changes to Blurt's production dictation or model settings. The offline tools do not open the microphone/camera, import personal history, send text to an LLM, or insert text into another application.

The [local pilot recorder and evaluation workflow](pilot/README.md) adds explicit, user-started camera recording, reviewed references, separate dataset splits, bounded adaptation, and stock/adapted comparisons. See that guide to collect actual silent-mouthing data.

## Apple Vision probe

Compile with Xcode Command Line Tools on macOS 14 or newer:

```sh
swiftc -O tools/silent-dictation/vision_probe.swift -o /tmp/blurt-vision-probe
/tmp/blurt-vision-probe --devices
/tmp/blurt-vision-probe /absolute/path/normalized-video.mp4 250
```

`--devices` enumerates formats without starting capture. The video mode reads only the video track and reports landmark latency, face coverage and mouth width. It does not decode speech. Input orientation must be baked into pixels, not metadata; the probe rejects transformed video. Use the same crop/resize/orientation conventions as the eventual recognizer when measuring production performance.

## Recognition benchmark

Research checkout used: [Lipflow](https://github.com/amywork777/lipflow), commit `e37453b1e1e125ca7130e4abf2635117635f6e0b`. Its source and models live outside this repository, at `/tmp/blurt-vsr-research/lipflow` for this run. Downloaded weights are not shipped with Blurt. Inspect the upstream NOTICE and model terms before reuse.

Reproduce with a separate Python 3.11 environment:

```sh
git clone https://github.com/amywork777/lipflow.git /tmp/blurt-vsr-research/lipflow
git -C /tmp/blurt-vsr-research/lipflow checkout e37453b1e1e125ca7130e4abf2635117635f6e0b
uv venv --python 3.11 /tmp/blurt-vsr-research/venv
uv pip install --python /tmp/blurt-vsr-research/venv/bin/python \
  'torch==2.14.1' 'numpy<2' 'opencv-python<4.11' 'mediapipe==0.10.21' requests sentencepiece
```

Review `scripts/download-models.sh` in that checkout, then run it there. It downloads about 1.2 GB of weights plus optional sample videos. The complete desktop installer is unnecessary for this benchmark.

```sh
/tmp/blurt-vsr-research/venv/bin/python tools/silent-dictation/benchmark.py \
  --checkout /tmp/blurt-vsr-research/lipflow \
  --video /absolute/path/clip.mp4 \
  --reference 'verified words actually articulated' \
  --output /tmp/blurt-vsr-result.json
```

Use `--no-lm` for a language-model ablation; `--device cpu` for a CPU comparison. Default: MPS when available, CPU beam search, beam 10, 4 CPU threads, three warm runs after one cold run. Weights are loaded with PyTorch's restricted weights-only loader. Personal adapters are disabled. Only video frames enter the recognizer even if the file has an audio track. `--unit character` changes scoring to CER; it does **not** turn the English checkpoint into a Mandarin model.

For a training timing experiment, add `--save-rois /tmp/blurt-mouth.npy` to the benchmark, then run:

```sh
/tmp/blurt-vsr-research/venv/bin/python tools/silent-dictation/training_probe.py \
  --checkout /tmp/blurt-vsr-research/lipflow --rois /tmp/blurt-mouth.npy \
  --reference 'verified words actually articulated' --output /tmp/blurt-training.json
```

This uses upstream frontend-plus-first-encoder-layer adaptation, not LoRA. It performs four actual forward/backward/optimizer steps with CTC and attention losses, discards the adapted weights and reports a throughput projection. One repeated public clip cannot measure generalization, convergence or useful personalization. The projection excludes preprocessing, validation, augmentation, varied clip lengths and sustained thermal effects.

The output separates preprocessing, model loading and inference. Warm inference excludes camera startup, post-release capture, preprocessing and insertion; it is not end-to-end interactive latency. Peak RSS is the process high-water mark and does not fully account for accelerator allocations. `p95` from the Vision tool describes frame-processing latency, not user-level dictation latency.

For the public test clip, download the first Wikimedia address linked in upstream `scripts/download-models.sh --samples`, then normalize and remove audio:

```sh
ffmpeg -ss 20.4 -i sample.mov -t 7.7 -an -vf 'fps=25,setpts=PTS-STARTPTS' -c:v libx264 -crf 18 clip-silent.mp4
```

Upstream's test reference is `BORN IN NEW YORK CITY AND RAISED MOSTLY IN CHICAGO NANCY DAVIS GRADUATED FROM SMITH COLLEGE`. The published sentence continues with a year, which this fixture omits. Independently check clip boundaries before scoring WER. The saved native result explicitly labels the fixture score as unvalidated. A selected broadcast sentence is only a smoke test; do not extrapolate its error rate to silent mouthing or users.

## Completed native path

The first public-video experiment used Apple Vision anchors because the MediaPipe installation was delayed. On November 7 the MediaPipe environment was completed and both crop pipelines were evaluated on 40 participant clips. See the [participant experiments](../../docs/design/silent-dictation-zh-tech.md) for multilingual recognition and actual saved adaptation runs. The native crop path remains an experimental alternative, not an assertion of reference-frontend parity.

```sh
uv venv --python 3.11 /tmp/blurt-vsr-research/model-venv
uv pip install --python /tmp/blurt-vsr-research/model-venv/bin/python \
  -r tools/silent-dictation/results/model-requirements.txt
/tmp/blurt-vision-probe /absolute/path/clip-silent.mp4 1000 --anchors > /tmp/blurt-anchors.json
python3 tools/silent-dictation/native_rois.py \
  --video /absolute/path/clip-silent.mp4 --anchors /tmp/blurt-anchors.json \
  --mean-face /tmp/blurt-vsr-research/lipflow/lipflow/mean_face.npy --output /tmp/blurt-native-rois.npy
/tmp/blurt-vsr-research/model-venv/bin/python tools/silent-dictation/benchmark.py \
  --checkout /tmp/blurt-vsr-research/lipflow --rois /tmp/blurt-native-rois.npy \
  --output /tmp/blurt-native-inference.json
```

The crop script requires FFmpeg, FFprobe, NumPy and OpenCV; the host's existing Python supplied NumPy/OpenCV in this run, with versions in `results/environment.json`. The model environment is separately pinned in `results/model-requirements.txt`. Use short input clips; the crop script decodes the entire clip into memory. Normalized video must start at timestamp zero, be 25 fps, and contain exactly the same frames that the Vision probe processed. It fails on frame-count mismatch instead of silently shifting labels. `--rois` timing includes only loading the crops, not prior capture/tracking/alignment.

The same model environment ran `training_probe.py` on `/tmp/blurt-vsr-research/native-rois.npy`. Its result in `results/training.json` is a timing experiment, not a saved user model. Existing caches were warm for some stages; three inference repeats and three warm training steps do not characterize long-running thermal behavior.

## User evaluation data

Each clip should have: `speaker_id`, `session_id`, `phrase_family`, `language`, `mode` (voiced/whisper/silent/exaggerated_silent), capture timestamps, reference text and its provenance, camera settings, consent scope, and split (train/validation/test). Separate test sessions and phrases before adaptation. Confirm prompted silent takes rather than assuming the prompt was mouthed correctly. The later participant pilot now contains 40 verified training clips and 40 separate-session validation clips. The frozen validation comparison and a subsequent validation-selected adaptation are complete; final test remains unrecorded.
