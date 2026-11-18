# Silent dictation feasibility

Research date: 6 November 2026. Scope: camera-only dictation for Blurt on Apple silicon, with English and Mandarin assessed separately.

November 7 follow-up: [actual participant and multilingual experiments](silent-dictation-zh-tech.md) now include 40 verified recordings, MediaPipe/native comparisons, Mandarin and multilingual inference, and three saved personalization runs. The historical public-video measurements below remain smoke-test results. Local adaptation is fast, but natural silent recognition has not improved reliably; separate-session validation is next.

**Decision: pursue an experimental silent mode with a measured acceptance test. Do not replace audio dictation yet.** Local computation is feasible on the inspected M5 Max. Recognition of genuinely silent, spontaneous speech, especially names and mixed-language technical content, is the unresolved product risk. Personal adaptation is a promising experiment; it cannot restore information that never appears in the video.

## What Apple supplies

| Component | Useful capability | Boundary |
|---|---|---|
| AVFoundation | Camera frames, timestamps, frame rate and exposure configuration | Screen recording alone does not capture the user's mouth. Collect a separate camera track. |
| Vision `VNDetectFaceLandmarksRequest` | Face, eye and lip landmarks; `outerLips` and `innerLips` | Geometry and tracking, not a speech recognizer. |
| ARKit `ARFaceTrackingConfiguration` | Face mesh and expression coefficients on supported iPhone/iPad hardware | Not a native Mac face-tracking backend. Face ID authentication is also not speech decoding. |
| Core ML | Deploy a converted model across supported CPU/GPU/Neural Engine operations | Conversion and actual device placement must be profiled. Selecting all compute units does not prove an entire model runs on the Neural Engine. |
| PyTorch MPS | Fast route to experiment with existing models on the Mac GPU | Inference support does not establish that every training operation is supported. |

Apple documents [camera capture](https://developer.apple.com/documentation/avfoundation/setting-up-a-capture-session), [face landmark detection](https://developer.apple.com/documentation/vision/vndetectfacelandmarksrequest), [lip regions](https://developer.apple.com/documentation/vision/vnfacelandmarks2d), [ARKit face tracking](https://developer.apple.com/documentation/arkit/arfacetrackingconfiguration), and [Core ML compute selection](https://apple.github.io/coremltools/docs-guides/source/model-prediction.html). Camera use requires a purpose string and OS permission; see [macOS capture authorization](https://developer.apple.com/documentation/bundleresources/requesting-authorization-for-media-capture-on-macos).

The locally installed Apple SDK explicitly marks both `AVCaptureDeviceTypeBuiltInTrueDepthCamera` and `supportedDepthDataFormats` unavailable on macOS. The built-in camera enumerated as `AVCaptureDeviceTypeBuiltInWideAngleCamera`, with 1080p at 30 fps among its formats. More Mac compute does not imply iPhone depth sensors or iOS API availability. Continuity Camera can provide a better video source; it does not automatically expose ARKit blend shapes. An iPhone companion could explicitly send its own tracking results, but adds a second-device requirement. [Apple Continuity Camera documentation](https://developer.apple.com/documentation/avfoundation/supporting-continuity-camera-in-your-macos-app).

No supported Apple lip-to-text API was identified. Private APIs provide no demonstrated solution to missing speech information and create maintenance risk. App Store distribution requires public APIs under [guideline 2.5.1](https://developer.apple.com/app-store/review/guidelines/). Blurt's direct distribution does not make an undocumented API stable or provide missing hardware.

## Evidence and usable projects

| Project | Why inspect it | Evidence and commercial boundary |
|---|---|---|
| [Auto-AVSR training code](https://github.com/mpc001/auto_avsr) | Reproducible baseline and a route to training on our own data | Apache-2.0 code; pretrained model terms are separate. This repository reports 20.3% LRS3 visual WER for its setup. |
| [Multilingual VSR inference repository](https://github.com/AV-LLM/AVSR) | English and Mandarin baselines | Lists English visual WER 19.1%, audio WER 1.0%, audio-visual WER 0.9%; Mandarin CMLR visual CER 8.0%. Its code terms restrict use to noncommercial comparison/benchmarking. These are different checkpoints and tasks, not interchangeable results. |
| [Lipflow](https://github.com/amywork777/lipflow) | Closest inspectable Mac implementation: webcam, mouth crops, MPS encoder, CPU decoding, personalization | Used for the isolated benchmark here. MIT app wrapper, but its NOTICE treats LRS3 weights as research-only. No production integration. |
| [Chaplin](https://github.com/amanvirparhar/chaplin) | Simpler local silent-typing reference | Auto-AVSR based; useful interface demonstration, not independent accuracy validation. |
| [Hushkey](https://github.com/amirrsyed/hushkey) | Native Mac interface plus a proposed LoRA adaptation and motion-feature branch | Authors label it a proof of concept. No independent held-out accuracy or training-cost result established here. |
| [AV-HuBERT](https://github.com/facebookresearch/av_hubert) | Influential audiovisual pretraining baseline | Archived; custom noncommercial research license. Not the preferred commercial starting point. |
| [RAVEn and BRAVEn](https://github.com/ahaliassos/raven) | Alternative representation-learning research | MIT repository; check checkpoints, dependencies and data separately. |
| [VALLR](https://github.com/MarshallT-99/VALLR) | Newer phoneme/LLM decoding research | CC BY-NC 4.0; useful comparator, not a ready commercial dependency. |

The relevant distinction is **visible speech information versus plausible language completion**. Several sounds share similar visible articulation, and a camera does not directly observe vocal-fold vibration or all tongue positions. Sequence context helps, but a decoder can produce fluent incorrect text. Mandarin additionally depends on tone; the original [CMLR paper](https://arxiv.org/abs/1908.04917) explains the resulting ambiguity. Exaggerated articulation might help visibility or hurt by changing the training distribution: test it separately, rather than prescribing it by default.

CMLR contains 102,072 sentences from **11 newsreaders**, excludes English letters and Arabic numerals, and is offered for research use. Its score cannot predict coding dictation with English identifiers and numbers. [Dataset owner's description](https://vipazoo.cn/CMLR.html).

A September 2026 preprint, [AVSRBench](https://arxiv.org/html/2609.10366v1), reports Auto-AVSR visual-only WER of 19.10% on LRS3 and 110.07% on RoomReader-AV spontaneous conversations. WER can exceed 100% because inserted words count as errors. The study is not a test of cooperative Blurt users or a pure silent-mouthing dataset; it demonstrates how severely distribution changes can affect results. Adding visual input also did not improve every audio condition. Test audiovisual fusion against the existing audio pipeline instead of assuming it wins.

## Recommended architecture for Blurt

```text
Explicit silent-mode hotkey
  → camera frames with presentation timestamps
  → one selected face, visibility and motion checks
  → alignment and mouth image sequence matching the model's training preprocessing
  → visual temporal encoder
  → text decoder with bounded vocabulary/context bias
  → provisional text and uncertainty handling
  → existing insertion/history path
```

Keep RGB or grayscale mouth images as the main input. Landmarks are useful for cropping, alignment and quality checks; reducing input to lip outline alone discards teeth, tongue appearance and texture used by pretrained models. Do not substitute Apple landmarks for a model's existing crop pipeline without comparing accuracy: coordinate order, crop position, mirroring, smoothing and normalization matter.

Start with short, explicitly delimited 3–10 second utterances and a preview before insertion. Keep the microphone closed in silent mode. Offer an explicitly separate low-volume audiovisual mode if testing supports it. Never silently activate audio as a fallback. A no-face/no-motion state should return no transcript. Test smiles, chewing and idle video, because a language decoder may invent text from non-speech motion.

The baseline has access to the whole utterance; partial CTC output is not proof of a streaming model with bounded lookahead. Repeatedly decoding a growing clip increases cost. A later streaming version needs a causal/chunk-trained encoder, explicit lookahead, timestamp handling and endpoint evaluation. Camera startup and any post-release tail must be counted in perceived latency, alongside inference and insertion.

Existing integration points are `Capture/Dictation/Dictation.swift` for orchestration, `DictationKeys.swift` for triggering, `DictationStream.swift` for live output, `DictationInsert.swift` for insertion, `BlurtCore/WarmServer.swift` for a warm worker, and `MainWindow/DictationLab.swift` for evaluation. These paths are under `skills/blurt/recorder/macos/Sources/`. Add a distinct visual-input session rather than pretending camera frames are PCM audio. Keep experimental models outside the shipping model manifest until licensing and accuracy gates pass.

## Training data and personalization

The proposed audio-to-label method is sound: [Auto-AVSR](https://arxiv.org/abs/2303.14307) already investigates large-scale automatically labeled audiovisual training. Closed-source ASR is an optional teacher, not a requirement; compare it with Blurt's existing local ASR on manually checked examples before paying for every clip.

Collect a synchronized webcam track and microphone track during explicit enrollment. Desktop screen pixels have little value for lip recognition and can expose unrelated work. Keep timestamps, capture settings, language, articulation mode, session ID, reference provenance and model versions. Use short clips with one visible speaking face; reject frame drops, poor lighting, occlusion, off-camera speech, dubbing and audio/video misalignment. A confidently wrong teacher remains wrong, so high-value names/numbers and evaluation references need human checking.

For prompted speech, the displayed text is only a proposed label until the user actually reads or mouths it correctly. For spontaneous voiced enrollment, ASR generates a draft for correction. Do not train the visual recognizer against LLM-rewritten prose or translated text. Corrected transcription must still describe the words articulated.

Collect separate modes: normal voiced speech, gentle whisper, natural silent mouthing, and deliberately exaggerated silent mouthing. Removing the audio from voiced recordings does **not** convert their articulation into true silent speech. Silent examples can use confirmed prompts or user-corrected transcripts. Retain labeled articulation mode so transfer can be measured instead of hidden in an aggregate score.

This distinction has direct experimental support: [Petridis et al., ICASSP 2018](https://arxiv.org/abs/1802.06399) found up to an 8.5 percentage-point drop in classification accuracy when testing on silent speech. That is a constrained classification result, not a predicted WER penalty for today's models. The authors also provide a [normal/whispered/silent dataset entry point](https://ibug.doc.ic.ac.uk/resources/av-database-normal-whispered-silent-speech/) for a mode-transfer experiment, subject to its access terms.

Use a shared pretrained backbone, then compare:

1. Vocabulary/context bias with no weight update.
2. Frozen visual encoder with a small trainable head or late adapter; cache encoder features.
3. LoRA/prompt adaptation in selected visual/temporal layers if the simpler approach is insufficient.

Do not train a full model per user. Caching only works for the frozen part: changing visual layers invalidates their cached features. Small trainable parameter counts reduce optimizer storage but do not eliminate activation memory or backbone computation. Keep adapters versioned with their exact base model and roll back if the validation score worsens.

[Personalized Lip Reading, AAAI 2025](https://arxiv.org/html/2409.00986v2), uses visual and language adaptation and reports 47.3% → 40.9% WER on its setup. Results for 15, 30 and 45 minutes of adaptation data are 42.5%, 41.4% and 40.9%. This supports adaptation, but is not evidence of near-perfect recognition after a short onboarding. Our proposed 5/15/30-minute enrollment ladder is an experiment, not a promised result.

Split by recording session/day and phrase family, not random adjacent frames. A personalized model must be evaluated on new phrases and a later session. A general model also needs held-out speakers. Keep a final untouched test set distinct from the validation set used to choose adapters. Separate per-user training consent from permission to pool clips into the shared model. Store crops locally by default, offer deletion of clips and adapters, and make cloud teacher uploads an explicit option. Mouth crops and learned adapters should not be described as anonymous.

## Compute and cost model

Inspected hardware: MacBook Pro, Apple M5 Max, 18 CPU cores, 40 GPU cores, 128 GB unified memory, macOS 26.5. Local inference and supervised update steps succeeded on this machine; detailed timings follow below. This does not establish acceptable performance on a base MacBook Air, battery life, or the cost of training a shared foundation model.

For a 250-million-parameter model, parameter storage alone is about 1 GB at FP32 or 0.5 GB at FP16. Runtime also needs activations, decoder state, language model and framework allocations. A 1–5 million parameter adapter occupies approximately 2–10 MB at FP16 before metadata; optimizer states add more during training. These are arithmetic examples, not measured memory footprints.

A 96×96 grayscale stream at 25 fps is 230,400 bytes per second uncompressed: about 13.8 MB/minute or 415 MB for 30 minutes. Compression can reduce disk use; decoded tensors, cached features and temporary source video add costs. Crop early, bound the live buffer, and process while capturing. Production should profile Vision versus the baseline tracker and then Core ML versus MPS with output parity checks. Quantization must be tested for accuracy, not just speed.

Use the following auditable cost formula, with representative enrollment throughput before setting prices:

```text
label cost       = enrollment audio minutes × teacher price per minute
training seconds = epochs × enrollment seconds / training audio-seconds-per-wall-second
cloud train cost = training seconds / 3600 × compute price per hour
total cost       = labels + training + storage/transfer + retries + support + shared-model amortization
```

For illustration only, assume 20 minutes of enrollment, 10 epochs, training throughput of 5 audio-seconds per wall-second, a teacher price of $0.006/minute and compute at $2/hour. Training is 2,400 seconds (40 minutes), labels cost $0.12 and compute costs $1.33: $1.45 before other costs. At throughput 1, compute becomes $6.67; at 20, $0.33. These rates are hypothetical sensitivity inputs, **not vendor quotes**. Do not apply the measured Mac throughput to a rented GPU without benchmarking it. Local inference has zero per-request cloud charge but uses the user's power and hardware. Training locally can also remove provider GPU charges.

Sell measurable personalization benefits, convenience and privacy only once held-out improvement is demonstrated. A one-time local enrollment upgrade or an optional cloud training credit fits the cost structure better than pretending every local utterance incurs server cost. Willingness to pay remains untested. Commercial model/data rights must be resolved independently; an adapter or conversion does not erase base-model restrictions.

## Acceptance experiment

Start with 5–10 pilot users, including the owner, and repeat on another day. Use English WER and Mandarin CER separately. Include spontaneous technical requests, names, negations, numbers and mixed Chinese/English. Compare voiced video with audio discarded, whisper, natural silent and exaggerated silent conditions. Include webcam angles, low light, external displays, backlighting and idle non-speech. Evaluate stock, vocabulary-only and adapted models on the same untouched clips.

Measure mouth fatigue and willingness to maintain a camera-facing posture, particularly when users look at a second display. Exaggerated articulation can impose a speed and comfort cost even if it improves recognition. An external-monitor setup may place the laptop camera too low or off to the side. These interaction costs belong in the corrected-words-per-minute result, along with errors and latency.

Proposed product gates, not literature claims:

- Silent free dictation: median WER/CER ≤10% and p90 ≤20% on held-out sessions, reported separately by language and user.
- Median finalization under 1 second and p95 under 2 seconds for a 10-second utterance on the declared supported hardware, including endpoint tail and insertion.
- At least 20% improvement in corrected words per minute versus the user's keyboard workflow in quiet-use situations; report correction time and failures.
- Personalization: at least 20% relative error reduction on the untouched test set, with no material increase in invented names, numbers or negations.
- If unrestricted dictation fails, test a disclosed fixed-command vocabulary with ≥98% intent accuracy and explicit rejection; do not market it as arbitrary dictation.

No-go for general release if the recognizer makes fluent guesses that users must repeatedly repair. A low error rate after unconstrained LLM rewriting is not enough: score raw output, postprocessed output, critical-token errors, rejection coverage, false activations and total correction time. Report errors on all attempted utterances, including refusals and tracking failures, so abstention cannot conceal poor coverage.

## Local experiment artifacts

The completed native path uses AVFoundation/Vision landmarks, experimental alignment to the reference mean face, and Auto-AVSR via Lipflow. The input is one 7.72-second, 193-frame, 640×360 public broadcast excerpt, with audio removed and presentation timestamps reset to zero. The initial file contained an edit gap handled differently by Apple and FFmpeg; timestamp normalization eliminated the frame-count mismatch. Mouth alignment approximates the reference pipeline, especially its nose-base anchor; preprocessing parity has not been established.

| Stage | Local measurement | Interpretation |
|---|---|---|
| Vision landmark coverage | 193/193 frames | One front-facing broadcast clip; not live user coverage |
| Vision warm frame latency | Median 3.83 ms; p95 4.95 ms | Final normalized run; process first frame 49.85 ms, with system caches already warm |
| Offline decode plus Vision | 0.855 s for the clip | Mouth width median 61 pixels; crop generation is separate |
| MPS encoder + CPU beam decoder | Warm median 1.068 s | Encoder about 0.05 s; decoder about 1.02 s; three repeats |
| CPU encoder + CPU beam decoder | Warm median 1.764 s | Same crops and four CPU threads; same transcript |
| First MPS inference | 2.598 s, plus model load 0.781 s | Keep a worker warm; not a measured fresh-install cold start |
| Model size and process memory | 250,383,410 parameters; MPS run peak RSS 2.32 GB | RSS does not fully capture GPU allocations |
| Supervised adaptation timing | Warm median 0.272 s per 7.72-second example | Four steps, one repeated clip, batch 1, FP32, AdamW; first step 5.03 s |

The training probe updates 25,780,928 parameters in the visual frontend and first encoder block, using the upstream CTC/attention objective. This is **not LoRA**. It demonstrates that this particular forward/backward/optimizer path runs on MPS, with CTC computed on CPU. It saves no trained weights and measures no adaptation accuracy. At the observed warm throughput of 28.4 video-seconds per wall-second, 20 minutes of enrollment × 10 epochs projects to 422 seconds (about 7 minutes) of update compute. Preprocessing, validation, augmentation, varied lengths, convergence and sustained thermal behavior are excluded; this is not a completed 20-minute enrollment run.

The decoded sentence began with the 16 words in the upstream fixture, then continued with a year rendered as “one thousand nine hundred three.” The [published source transcript](https://obamawhitehouse.archives.gov/the-press-office/2016/03/12/weekly-address-legacy-nancy-reagan) gives 1943. The fixture omits the continuation, and the clip boundary was not independently transcribed, so its computed fixture score is **not reported as validated WER**. This example is useful evidence of running inference and fragile numbers, not an accuracy benchmark.

Raw results: [Vision](../../tools/silent-dictation/results/vision.json), [MPS inference](../../tools/silent-dictation/results/native-inference.json), [CPU inference](../../tools/silent-dictation/results/native-inference-cpu.json), [training timing](../../tools/silent-dictation/results/training.json), and [environment and source provenance](../../tools/silent-dictation/results/environment.json).

The isolated tools are in [tools/silent-dictation](../../tools/silent-dictation/README.md). Machine-readable results include model hash, checkout commit, timing, output and memory. The reference MediaPipe frontend was not executed: its dependencies downloaded too slowly, and that installation was stopped after the native path and model-only runtime succeeded. No camera/microphone was opened, user data collected, cloud inference invoked, product settings changed or shipping code integrated. Public broadcast video is a pipeline smoke test; it is not validation of this user's silent speech. Live enrollment, Mandarin inference, held-out adaptation quality, reference-preprocessing comparison and sustained training throughput remain follow-up experiments.
