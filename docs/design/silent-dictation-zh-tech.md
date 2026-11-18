# Chinese-first silent dictation: language and compute follow-up

Updated November 7, 2026. User direction: roughly 90% Chinese / 10% English, initially weighted toward AI/tech users while retaining room for other groups. Eighty participant-verified clips are now recorded: 40 training and 40 validation. Local multilingual inference and personal adaptation run successfully, but natural silent dictation remains inaccurate. Cloud GPU rental is authorized when needed; current experiments fit on the Mac and incurred no cloud charges.

## Revised priority: public data and architecture comparison

The latest user direction is to reduce enrollment burden, prioritize quality for this participant, and compare different approaches before selecting an architecture. **No base model or final architecture has been selected.** ViSpeR is an executable research baseline. Lipflow, CMLR, ViSpeR and CNVSRC mostly explore related visual-frontend/sequence-recognition families; their number overstates architectural diversity. The existing `train-03` session remains available but is **optional and deferred**, not a prerequisite. No additional recordings or annotations are requested now. This supersedes the earlier enrollment-first next step below.

More public training is a plausible intervention, not an established solution. ViSpeR already learned from broad voiced audiovisual material. Severe errors on this participant's voiced-video clips as well as silent clips mean we must verify reference-pipeline behavior on public data before attributing failure solely to silent articulation or limited enrollment. The existing 80 clips support development comparisons. Repeated use makes validation a development set; retain the unrecorded final test for a frozen candidate.

### Public-data audit completed

Downloaded pinned repository cards and metadata, with no bulk audiovisual downloads, training, private uploads or cloud spend. The [audit script](../../tools/silent-dictation/pilot/public_data_audit.py) and [aggregate results](../../tools/silent-dictation/results/public-data-audit.json) record revisions and CSV hashes. Raw metadata stays in the local runtime's `public-data-audit` directory. The audit does not read participant data.

| Source | Practical role | Access and limitations |
|---|---|---|
| [Chinese-LiPS](https://huggingface.co/datasets/BAAI/Chinese-LiPS) | Mandarin lecture video; 100.84 h, 207 speakers; technical-language coverage | Processed mouth-video archives exist. CC BY-NC-SA plus detailed terms explicitly exclude commercial product development. Not approved as product-training data. |
| [ViSpeR](https://huggingface.co/datasets/tiiuae/visper) | Author-reported 787 h Chinese; reference-pipeline comparator | Metadata/source-video lists require media reconstruction. CC BY-NC-2.0; source-media rights also matter. |
| [MultiVSR](https://huggingface.co/datasets/sindhuhegde/multivsr) | Chinese and English confirmed among 13 languages; VTP visual features and multilingual Transformer | HF metadata tag is MIT; original videos must be obtained separately. The tag does not establish source-video or checkpoint rights. |
| [ASCEND](https://huggingface.co/datasets/CAiRE/ASCEND) | Spontaneous Chinese–English language/ASR component; 10.62 h | Audio/text, no face video. CC BY-SA-4.0 card. Cannot directly supervise a visual encoder. |
| [CN-CVS](https://www.cnceleb.org/) | Broader Mandarin visual-speech comparison | Over 300 h; registration/agreement; no commercial use. |

Chinese-LiPS metadata matches the published split counts and shows no shared speaker-ID prefixes across splits. Of 30,341 training rows, 1,652 contain both Han characters and Latin letters. Latin-token occurrences include AI 570, ChatGPT 101, NLP 50 and OpenAI 27. These are written labels, not verified pronunciations or spontaneous code-switching. There are 3,543 science/technology training rows. Exact normalized transcript overlap exists across splits (1 train/validation, 2 train/test). Media, synchrony, label quality and semantic near-duplicates remain uninspected.

MultiVSR's downloaded `val_major.csv` contains 2,073 Chinese rows from 44 source-video IDs, including 309 rows with Latin letters. These are **public validation** rows, not training examples or 44 verified speakers. Its downloaded minor-language training file contains no Chinese. The 850 MB major training CSV and approximately 42 GB metadata tar were not downloaded in this bounded audit. Keep validation out of training; use speaker/source-video separation rather than random clip splits.

A static source audit pinned MultiVSR to `af28d8c4b687ee7e41942732eb240e0cdfff3ccd`. Its supplied inference loads separate visual-feature and sequence checkpoints, reads RGB frames at assumed 25 fps, resizes face tracks to 160×160 and center-crops 96×96 with values divided by 255. This is incompatible with simply feeding the existing normalized grayscale mouth tensors. It uses a multilingual GPT2-style tokenizer and contains a CUDA autocast path; Mac execution needs a deliberate port and verification. The inspected source tree contains no LICENSE file. No weights were downloaded or inference executed for this candidate in this audit.

Muting voiced video does not create naturally silent articulation. [Petridis et al.](https://arxiv.org/abs/1802.06399) directly studied the difference. Some Mandarin “silent speech” datasets instead contain EEG, EMG or ultrasound, which cannot replace ordinary webcam input. The [AVE Speech paper](https://arxiv.org/html/2501.16780v1) describes repeated readings of 100 sentences with audio, lip video and EMG; closed-set results there cannot establish free-form silent dictation. We have not verified a large, accessible, genuinely silent Mandarin–English webcam corpus suitable for this product. That is a search result, not a claim that none exists.

### Three approaches to compare

1. **Direct bilingual video-to-text.** Keep ViSpeR as a control and audit [MultiVSR](https://github.com/Sindhu-Hegde/multivsr)'s author preprocessing, vocabulary and checkpoints. Compare a shared model with and without a personal adapter. Switching language at sentence boundaries does not solve English words inside a Chinese sentence.
2. **Audio-assisted training, video-only inference.** Compare the same student with and without audio-teacher supervision, informed by [RAVEn/BRAVEn](https://github.com/ahaliassos/raven). Paired, aligned video/audio and active-speaker verification are necessary. Closed-source ASR can supply transcripts but may not expose internal features. English-trained encoders still need Mandarin/bilingual adaptation; code licenses do not settle weight/data rights.
3. **Phonetic and text prediction.** Compare Pinyin plus an English-capable text head, followed by constrained candidate rescoring. [VALLR-Pin v2](https://arxiv.org/html/2512.20032v2) motivates this direction but is not reproduced here. A newly located [independent implementation](https://github.com/mousewu/VALLR-Pin) departs from the paper and provides no weights; it is not an author-released checkpoint and its reuse terms remain unverified. Measure raw phonetic, raw text and rescored errors separately, including invented terms, numbers and negation. Current text-derived Pinyin errors remain high, so language-model correction alone is not justified.

These compare supervision and decoding choices; controlled ablations can share an encoder. Training a new foundation model from scratch is not the next step. Synthetic talking faces are at most an augmentation experiment, never evidence of real silent-speech accuracy.

### Execution order and decision rules

- Resolve reproducible artifacts and usable terms, then verify inference on an author example and a small public held-out sample. Inspect timing, normalization, tokenization and decoding. A smoke sample verifies integration, not a paper's full benchmark.
- Run viable candidates against the existing personal development data, comparing Chinese, embedded English and English separately, plus voiced versus natural-silent modes. Publish failures and keep preprocessing/compute budgets comparable.
- For promising training routes, start with a fixed public subset (proposed 5–20 h, not acquired), aligned video/audio/text and speaker/source separation. No slides, subtitles or reference answers enter inference. Profile throughput/memory before a larger local or GPU run. No paid job has started.
- Select a route only after gains survive unseen phrases and another session, preserve technical terms, and reduce correction effort. Track CER/MER/WER separately, term recall, incorrect inserted terms, numbers/negation, latency and corrected text throughput. Lower training loss or fluent output is insufficient; no current route meets useful dictation quality.
- Request personal effort only for a specific remaining gap: a short label review or targeted silent/voiced examples. The prepared 50 takes are not a required minimum. Preserve unfamiliar prompts for final evaluation.

The working product hypothesis is a shared bilingual visual model plus optional inexpensive personal adaptation and an explicit technical vocabulary. Measure zero-enrollment quality and the marginal benefit of adaptation separately. Before promising quality for other users, evaluate held-out speakers. Neither zero enrollment nor a particular enrollment duration is supported yet.

## Separate session validation

The 40 validation takes were recorded on November 7, six hours after the training session. They contain 152.81 seconds of media across ten new phrase families. All 40 passed native preparation: 100% anchor coverage, zero multiple-face frames, and at most 0.20 seconds difference between media and capture duration. MediaPipe and the additional five-point crop experiment also produced all 40 sequences. No test clips have been recorded or consumed.

A saved protocol fixed the stock model, existing all-mode adapter, existing silent-only adapter, beam 10, and strict plus OpenCC script-normalized scoring before decoding validation. The first three rows below are this frozen comparison. The fourth is a subsequent experiment: gradients use all 40 training clips, while the 40 validation clips select an epoch. It is therefore a validation-selected result, not an untouched final test. The fifth changes only preprocessing for the stock model.

| Configuration | Natural silent Mandarin CER | Exaggerated silent Mandarin CER | Natural silent mixed MER | Natural silent English WER |
|---|---:|---:|---:|---:|
| Stock ViSpeR | 89.5% | 75.6% | 105.4% | 188.9% |
| Frozen all-mode adapter | 84.9% | 66.3% | 100.0% | 88.9% |
| Frozen silent-only adapter | 96.5% | 80.2% | 86.5% | 100.0% |
| All 40 training clips, validation-selected epoch 7 | 88.4% | 73.3% | 75.7% | 111.1% |
| Stock with author five-point crop geometry | 88.4% | 73.3% | 108.1% | 177.8% |

Each Mandarin cell covers six phrases/86 reference characters, mixed covers three phrases/37 units, and English covers one phrase/nine words. Values above 100% include inserted words/characters. None of these five configurations decoded any of the 40 validation sentences exactly. These small results do not establish population accuracy, but they clearly fail the proposed product threshold. Broader training improved mixed output without producing reliable natural-silent Mandarin. The additional ten-epoch adaptation took 92.1 seconds for training and validation, excluding model load and final decoding.

The five-point experiment invokes ViSpeR's author-provided face-resize and mouth-alignment functions with MediaPipe-derived eye centers, nose base, lip corners and face bounding boxes. It is closer to the author crop geometry but does not reproduce the original detector. Mouth sequences were visually inspected and all frame counts matched. Its failure to materially improve recognition reduces the likelihood that the four-point wrapper geometry alone explains the results.

A text-derived toneless-Pinyin diagnostic on the frozen all-mode model reduces natural-silent Mandarin error from 84.9% character error to 82.6% syllable error. This is not an independently annotated phonetic score and does not isolate encoder versus decoder faults; it suggests that simple same-sounding-character replacement cannot explain most of the decoded errors. The personal training references contain only nine Chinese-dominant phrase families and 80 unique toneless syllables. Of 86 unique validation syllables, 39 occur in training; just six of 108 validation syllable bigrams occur there. This describes narrow personal enrollment, not missing coverage in the pretrained foundation model or proof that adding data alone will solve the problem.

The additional model comparator is the [official CNVSRC 2025 baseline](https://github.com/liu12366262626/CNVSRC2025/tree/main/VSR), whose public checkpoint uses broader Chinese training data. Its supplied vocabulary has 4,470 entries including blank/end markers and no ASCII alphabet tokens, so it cannot directly spell English identifiers. Its publisher-verified checkpoint completed all 24 Mandarin validation clips with beam 40 and CTC weight 0.3: natural-silent CER 91.9%, exaggerated-silent 77.9%, voiced-video 75.6%, and whisper-video 88.4%, with zero exact sentences and zero execution failures. It remains an isolated Mandarin benchmark with research/noncommercial restrictions. The source commit is `e5c4454016ba4eef9e586e77dd58e8981bb5c3e1`; checkpoint SHA256 is `577cd9558eea111683a406bc25d69c7161cdb79534c2273fc0d0f044c356231c`. The [VALLR-Pin paper](https://arxiv.org/html/2512.20032v1) proposes character/Pinyin decoding and error-aware language-model refinement, but this is an architectural lead, not a locally reproduced result or a substitute for visual evidence.

All five ViSpeR configurations retained zero of twelve literal validation occurrences of Git, JSON and token. A separate English-language-tag ablation also retained none and yielded 105.4% natural-silent mixed MER. These terms are explicitly held out from the initial personal training corpus, and acronym spelling remains strict; the result identifies a target-user failure, not merely an aggregate metric issue.

Preserve the final test set until a materially stronger candidate exists. The current data requires no re-annotation. A new `train-03` session is now prepared in the recorder: 40 distinct natural-silent phrases plus ten matched voiced takes, with exactly 90% Chinese-dominant and 70% technical takes. All 80 existing verified clips and every validation/test plan entry remain unchanged; the prior plan is backed up. Camera and microphone are off. This increases unique enrollment phrases from ten to fifty when completed, without repeating every sentence in four modes.

The saved prospective expansion protocol uses the same ViSpeR base, 10-epoch/600-second training-validation budget, training-only gradients and validation-loss epoch selection. Its proposed development progress gate is at least 20% relative reduction against the best current natural-silent Mandarin CER (73/86), without worsening natural-silent mixed MER beyond 28/37; report literal technical-term retention as well. This is a progress criterion, not the product acceptance threshold or a prediction that extra data will work. The final test remains untouched. No cloud compute or paid inference was used.

## Initial training session diagnostics

The active corpus contains 122.43 seconds across 40 clips: 24 Mandarin, 12 mixed, and 4 English, with ten takes in each articulation mode. Capture timing passed inspection, all 40 mouth-crop sequences are ready, and native tracking found usable anchors in every frame. Validation and test were unrecorded at this initial stage; the subsequent validation results are above.

Three visual-only paths were executed: Lipflow's English baseline, the CMLR Mandarin checkpoint with and without its external language model, and [ViSpeR](https://github.com/YasserdahouML/visper)'s multilingual checkpoint. No audio, answer prompt, candidate reference, or LLM correction enters free-form decoding. ViSpeR receives the planned dominant-language tag; automatic language selection is not tested. Lipflow's MediaPipe preprocessing was compared with the Apple Vision crop pipeline; this is not claimed to reproduce the original authors' full landmark pipeline. Switching the crops did not resolve the English or Mandarin failures.

ViSpeR's unadapted natural-silent Mandarin CER is **77.1%** after traditional-to-simplified normalization, versus **90.4%** under the original script-sensitive metric, across six phrases. Mixed-language natural-silent MER is **92.3%** after the same normalization, across three phrases. No complete training sentence was recognized exactly. OpenCC `t2s` was added after observing traditional outputs; both strict and normalized results are retained, with the same conversion applied to reference and hypothesis. It does not rewrite meaning, numbers, or acronyms.

Personalization reserved two entire Mandarin families, document summarization and carrying an umbrella, before examining ViSpeR hypotheses. They supply eight development clips, two per mode. The other eight families supply 32 fit clips for the all-mode runs or 16 for the silent-only run. The visual frontend, embedding and first encoder block (25,780,928 parameters) are updated with AdamW at 1e-5; decoder weights and BatchNorm statistics remain frozen. Epoch selection uses development loss, including the original model as epoch zero. These are repeated, same-session development experiments, not independent validation or product accuracy.

| Configuration | Natural silent CER | Exaggerated silent CER | Voiced video CER | Whisper video CER | Training and validation time |
|---|---:|---:|---:|---:|---:|
| Stock ViSpeR on the eight reserved clips | 77.8% | 81.5% | 96.3% | 92.6% | — |
| All modes, 3 epochs, selected epoch 3 | 85.2% | 48.1% | 51.9% | 85.2% | 29.2 s |
| All modes, 10 epochs, selected epoch 3 | 77.8% | 51.9% | 51.9% | 92.6% | 60.7 s |
| Natural and exaggerated silent only, 10 epochs, selected epoch 2 | 81.5% | 59.3% | 66.7% | 85.2% | 34.4 s |

All table scores use script-normalized CER; each cell has only two clips and 27 reference characters. No adapted reserved sentence was exact. All attempted configurations are shown, rather than selecting the best decoded score. Even with a fixed seed, MPS runs were not bit-identical. The longer run's fit loss continued to fall while development loss worsened after epoch three: adding epochs does not solve the present data limitation. The strongest individual example changed “请把这份文档总结成三个重点” to “请把这份文章总结成三个重点”, with one character wrong, using only a voiced clip's video. Natural silent decoding has not improved reliably.

The CMLR checkpoint, with its Mandarin language model and beam 20, scored 110.8% natural-silent CER across six phrases; its news-like output does not fit this task. A separate ten-command retrieval diagnostic using one voiced-video template per command recognized 2/10 natural-silent, 6/10 exaggerated-silent, and 7/10 whisper queries with MediaPipe crops. This is closed-vocabulary matching, not free-form transcription, and is also below a useful product threshold.

On the M5 Max, ViSpeR beam-10 warm decoding medians were 0.662 s for 4.08 s of Mandarin, 0.447 s for 3.64 s of mixed speech, and 0.576 s for 3.56 s of English. Each uses three repeats of one selected clip; these are offline inference timings, excluding capture, cropping, UI and correction, and are not a latency distribution for users. Training times above exclude loading and final beam decoding. The 40-clip corpus is too small for a pricing estimate or a generalization claim, but local compute is sufficient to continue enrollment experiments.

Provenance: ViSpeR checkout `772fe4688fad5cea104308f51ccbfe3141b440a1`, publisher-verified checkpoint SHA256 `d6b45e0a9988ae3e747496dd0f24c7b3f5e019358e743df8e66579a38e755608`; multilingual CMLR checkout `5e1405db0ae816509fb312f9a578724c2e0de0c7`; Lipflow checkout `e37453b1e1e125ca7130e4abf2635117635f6e0b`. Model weights, personal adapters, detailed hypotheses and video stay under the local pilot Application Support directory. The [probe commands](../../tools/silent-dictation/pilot/README.md#multilingual-research-probes) reproduce these runs. These research models have noncommercial/research restrictions and are not integrated into the shipping product.

That planned next step is now complete: the 40-take `validation-02` session was recorded and the frozen models were compared before further adaptation. Preserve `test-02` for a later untouched final evaluation. No re-annotation of verified training clips is needed. If the fresh comparison confirms the present gap, expand unique natural-silent Chinese and code-switched phrases across sessions before another adaptation experiment; repeating ten prompts or renting a larger GPU would not establish general dictation quality.

## Implemented collection changes

The new `tech_zh90_v1` profile uses **utterances** as the initial sampling unit:

| Group | Takes | Share |
|---|---:|---:|
| Mandarin-only | 72 | 60% |
| Mandarin with English terms | 36 | 30% |
| English-only | 12 | 10% |

Chinese is the dominant language in 90% of takes. This interprets the user's usage mix; it does not assert that 90% of recorded seconds or tokens will be Chinese. Domain sampling is 70% AI/tech and 30% everyday language. Both ratios hold in every split and articulation mode. The corpus has 30 phrase families, each recorded in silent, exaggerated-silent, whisper and voiced modes. Each split has 40 takes.

Examples include “这次训练先用一张 GPU 跑起来”, “把这个 API 的超时时间改成十秒”, and “这个 prompt 太长了，先删掉重复的要求”. The held-out set includes different terms and tasks, ordinary requests, names, numbers, and a negated instruction. AI bias is for collection and later decoder experiments, not a license for a language model to rewrite uncertain output into plausible technical prose. General language remains a tracked group.

The recorder preserves `language_profile`, `domain`, and `target_terms` with each verified take. Original plans/data remain intact; the new dataset is `speaker-01-tech-zh90-v1`, with sessions `train-02`, `validation-02`, and `test-02`. Reopening the updated app selects the new training session. An already-running app is not interrupted and retains its old plan until reopened.

## Experiment results, November 7

All numbers are character error rate on a development set, not an independent test. `test-02` stays out of training. Chinese-LiPS is CC BY-NC-SA and is used for research only.

### Public training

Stock ViSpeR was trained on Chinese-LiPS on one rented GPU. A high learning rate that also trained the decoder (v1) drifted toward the dataset's topic language. v2 used a frozen decoder and an auxiliary toneless Pinyin CTC head.

| Model | Val, 120 clips | Test, 300 clips |
| --- | --- | --- |
| Stock | 63.9% | 73.5% |
| v1, epoch 3 | 61.3% | 65.5% |
| v2, epoch 3 | 48.4% | 54.9% |

`cloud/train.py` scores this table without the OpenCC conversion that `eval_personal.py` uses, and Traditional output cost stock 2 to 13 points on participant clips. So v2's lead may be overstated. The pack is gone, so this cannot be re-measured.

The VM and its disk were deleted after about 10 hours (rough cost $14, an estimate from an unverified $1.4/h rate). No participant video went to the cloud. The 79 GB Chinese-LiPS pack was on that disk and is gone.

### Personal fine-tuning

Eighty clips, 5-fold, unseen phrase families, zh only. Rows ending in LLM add Gemini rescoring of the 10-best with Pinyin, no glossary. The best row takes its Pinyin from v2 + all.

| Pipeline | Exaggerated silent | Silent | Voiced | Whisper |
| --- | --- | --- | --- | --- |
| Stock | 72.2 | 82.8 | 80.5 | 79.9 |
| v2, no fine-tune | 84.0 | 89.3 | 72.8 | 84.0 |
| Stock + encoder, 15 epochs | 63.9 | 71.0 | 64.5 | 74.0 |
| Stock + all, 15 epochs | 59.2 | 68.0 | 60.9 | 74.6 |
| Stock + all, 30 epochs | 64.5 | 76.3 | 69.8 | 76.9 |
| v2 + all | 66.9 | 71.6 | 62.7 | 79.9 |
| v1 + fine-tune | 85.2 | 87.0 | 86.4 | 85.8 |
| Stock + encoder + LLM | 57.4 | 60.9 | 55.6 | 66.9 |
| **Stock + all + LLM** | **55.0** | **62.1** | **49.7** | **74.0** |
| Two models fused + LLM | 58.6 | 60.4 | 55.6 | 66.3 |

Mixed Chinese-English on the best row: 64.5 / 76.3 / 65.8 / 76.3. With a glossary, enc15 reached 46.1 on mixed exaggerated and 55.3 on mixed silent, but that glossary came from the test vocabulary, so these are upper bounds only. They still show context is worth testing.

Findings:

- A small amount of personal data moved results more than a large public run. v2 beat stock on public data and lost to it on this participant before fine-tuning.
- Fifteen epochs are enough; 30 overfits at this data size.
- Silent is the gap. On one same-light session the public model's Pinyin error is .679 voiced and .878 silent.
- Lighting is unproven. Sharpness was 190 in the training session against 87 in validation, with voiced Pinyin error going from .68 to .80, but that compares sessions. Within the rapid sessions, the 7 to 8 low-sharpness clips scored better, not worse. Crop zoom, AdaBN and sharpening did not help.
- This table counts 24 truncated clips. Complete clips only, voiced is 58.2 and whisper 63.2 (n=4); silent is unchanged.

### Paired recording: does voiced data help silent recognition?

Two rapid sessions gave 92 clips (46 voiced, 46 silent, 384 s, sharpness 185 to 199). Each sentence was said aloud and then silently. Stock base, scope all, 30 epochs, 5 folds with held-out sentences, scored on the 46 silent clips. Each fold fit about 37 clips of one mode. CER can exceed 100% because of insertions.

| Fit on | Overall | zh (34) | Mixed (12) |
| --- | --- | --- | --- |
| Nothing (stock) | 102.2 | 104.3 | 96.0 |
| Voiced only | 78.2 | 75.0 | 87.5 |
| Silent only | 75.2 | 68.9 | 93.5 |

Paired bootstrap on clips: stock minus voiced-fit is 24 points (95% CI 11 to 39), stock minus silent-fit is 27 points (14 to 41), voiced-fit minus silent-fit is 3 points (-1.2 to 7.5). So voiced data carries to silent recognition and gives most of the gain at this data size. The difference between them is not resolved by 46 clips, and silent-only won on 25 clips against 15. Both remain far from the 10% product gate. All clips come from one short sitting in the same light, so this says nothing about other days or lighting.

### Combined training: does more data help?

All 172 clips (80 pilot, 92 rapid), stock base, scope all, 15 epochs, 5 folds, each fold fitting 123 to 140 clips. The run took 86 minutes on the Mac. Rapid folds hold out the same sentences as the runs above, so these are paired.

| Scored clips | Earlier run | Combined |
| --- | --- | --- |
| Rapid silent (46) | 75.2 silent-only, 78.2 voiced-only | 75.3 |
| Rapid voiced (46) | 86.5 stock | 55.4 |
| Pilot, all modes (80) | 76.0 fit on pilot alone | 74.1 |

Combined against silent-only on rapid silent is -0.1 points (95% CI -4.2 to 4.1). Against pilot-only on pilot clips it is 1.9 points (-2.7 to 6.6). Roughly four times the training data did not move silent error, while voiced error fell to 55%. So the voiced-to-silent gap is about 20 points and more mixed data alone is not closing it at this size. The epoch counts differ (30 against 15), so this is not a clean learning curve; a clean one needs more clips scored on the same held-out set.

### Local language models

Small local models do not replace the cloud correction step yet. On the same 80 pilot clips with the same 10-best and Pinyin, zh CER:

| Step | Exaggerated silent | Silent | Voiced | Whisper |
| --- | --- | --- | --- | --- |
| Raw, all 15 epochs | 59.2 | 68.0 | 60.9 | 74.6 |
| Gemini | 55.0 | 62.1 | 49.7 | 74.0 |
| Qwen 3.5 4B (Ollama) | 56.2 | 68.0 | 58.6 | 72.2 |
| Qwen 3 8B (Ollama) | 60.4 | 72.2 | 63.9 | 73.4 |

Each group is 12 clips, so only large differences mean anything. Local latency was about 0.7 s per clip with training running at the same time. On the combined run's 66 silent clips, Qwen 3.5 4B left zh at 70.2 (raw 70.3) and mixed at 84.8 (raw 83.3); that run has no Pinyin, because the stock model has no Pinyin head. Qwen 3.5 4B kept the top candidate on 37 of those 66 clips. Rapid sentences come from the user's own messages, so they were scored only on the local models.

### Paired alignment

`--pair-weight 1` adds a loss that pulls each silent clip's encoder frames toward the DTW-aligned frames of the same sentence said aloud. Rapid clips only, stock base, scope all, 15 epochs, each fold fitting about 74 clips of both modes. Same held-out sentences as above.

| Scored clips | Both modes | Both modes + alignment |
| --- | --- | --- |
| Silent (46) | 75.8 | 76.2 |
| Voiced (46) | 58.3 | 64.0 |

The silent difference is -0.4 points (95% CI -4.3 to 3.4), with 17 clips better and 16 worse. Voiced got worse by 5.7 points (-9.6 to -1.6). This single weight did not help, and no other weight was tried.

Silent error stayed near 75% at about 37, 74 and 123 to 140 training clips, while voiced reached 55 to 58%. Epoch counts differ, so this is a reading across runs, not a controlled curve. The likely explanations are that natural silent articulation carries less visual information, or that more silent data from new sessions is needed. On the pilot's paired zh families, exaggerated silent is 59.2 against 68.0 for natural silent, 12 clips each, so articulation style is the next thing to test directly.

## Strategy review, November 7

Five reviews covered prior art, architecture, data, a code audit and an articulation measurement. Web figures come from those reviews and were not each re-checked. Estimates are marked.

**Conclusion.** The pipeline is sound, and free-form dictation stays the goal. Public results are a reference, not a ceiling, but the current signal is too weak: at 10% CER, free-form natural silent dictation from vision alone has no supporting evidence: no camera system has a measured result near it, the best one-speaker voiced result is about 30% CER on 94 h, and silent sensors still reach only 12 to 26% WER on open text. Estimated odds of reaching the gate this way are under 15%.

**What the current model can already do.** Picking the true held-out sentence from a list, using saved 10-best text and toneless Pinyin edit distance (34 zh silent clips from one sitting; re-measured independently):

| Pool | Combined top-1 / top-5 | Fit-silent top-1 | Stock top-1 |
| --- | --- | --- | --- |
| 682 older personal sentences | 76% / 94% | 79% | 15% |
| 155 unseen newest sentences | 91% / 100% | 88% | 35% |

A shuffled control gives 3%. The true sentence is always in the list, which is the limit of this test. Against older history alone, none of 155 new messages came within 40% edit distance (median 0.78), though the script may already exclude near-duplicates. So old messages will not supply candidates, and generating them from context is the real unknown.

**Information limits.** Perfect input through Qwen3-4B constrained beam search over 46 sentences gives 12.7% CER from toneless Pinyin, 23.9% from 139 viseme classes, and 74.3% from 30 lip-only classes. Current silent Pinyin error is 68%. The best of the 10-best is 64% against 71% raw, so rescoring a short list has a low ceiling.

**Articulation.** 45 pairs: silent is 0.83 of voiced duration, 0.62 of lip-gap range, and 0.45 to 0.68 of jaw opening, with sealed-lip frames rising from 22% to 41%. Trajectories stay close (correlation 0.82 after warp, against 0.65 for unrelated sentences and 0.84 for same-mode repeats). So silent is mostly the voiced movement made smaller and faster, plus more lip contact. Per-clip size of this difference did not predict error, with low power at these CERs. Silent always followed voiced, so order cannot be separated out.

**Audit.** No serious defect. A public English clip through our crop and decode path scored 29% WER. Open items:

- Fine-tuning has no dropout, time masking or early stopping.
- Silent takes are rushed and always recorded second.
- `ctc_weight` 0.1 beat 0.3 by 3.4 points on voiced, chosen from many conditions, so it needs re-tuning on held-out clips.
- Camera pitch is 10 to 15 degrees against about 0 on public clips; rectification is untested on fine-tuned models.

**Licensing.** Verified Mandarin corpora and ViSpeR's data are research-only, so nothing derived from them, ViSpeR adapters included, should ship. Scraping video for a corpus breaches site terms and is out. No large public silent Mandarin corpus exists.

**Revised by the user, November 7.** Picking from a list is not the product: daily messages are new each time, and the zero-coverage check above agrees. Selection is kept as evidence that the signal is real and as a measure of it, not as the interaction. The target is an information budget. Silent output carries about 20 bits per sentence; a strong language model probably leaves 40 to 70 bits to supply (both rough estimates). So the plan is to double the signal or halve the uncertainty with context.

**Speed.** Measured on these pairs, this person speaks 6.3 syllables a second aloud, about 380 characters a minute, and 7.3 when mouthing.

**Passive sound in silent takes.** Silent segments sit at -41.8 dB against a take floor of -44 to -46 dB, and voiced at -28.5 dB. Whisper on amplified silent audio gave 111.8% CER. Correlation between audio envelope and mouth motion did not beat mismatched clips, but the voiced control failed too, so that part of the probe is too weak to conclude anything. This was mono AAC from normal recording, not a capture designed for this.

**Plan, in order:**

1. Mouthing test: 20 pairs with the cue to part the lips on every vowel, drop the jaw and slow down. It works if the lip-gap ratio reaches 0.9 and sealed frames land within 5 points of voiced; then compare CER.
2. Main line, end-to-end personal model: free talk on a second day, 1 h voiced and 20 min silent, ASR-labelled with review of uncertain segments. Compare a frozen Qwen3-ASR decoder against ViSpeR's, then feed app and surrounding text into the decoder as context. Estimated silent 45 to 60% at 5 to 20 h. Stop this architecture if voiced stays above 45%.
3. New signal: test active acoustic sensing with the Mac's own speakers and microphones. Inaudible tones reflected off the mouth may show movement a camera misses. Unproven at laptop distance.
4. Lattice decoding with an error-aware LLM, from v2 Pinyin posteriors.

Landmarks, new backbones and generative methods rank lower.

## Main line: video into a frozen speech decoder

Qwen3-ASR's audio encoder emits 1024-dimensional features at about 13 frames a second, and those replace placeholder tokens in the input of its Qwen3 text decoder, with app and text context in the system prompt. So a visual encoder that predicts those features reuses a strong language decoder and takes context natively. This also means no one has to read every character: the decoder already knows the language.

Measured on the 46 rapid voiced clips, on this Mac:

| Decoder input | CER |
| --- | --- |
| Real audio features | 3.5% |
| Per-frame noise, cosine 0.9 | 3.5% |
| Cosine 0.8 | 6.0% |
| Cosine 0.7 | 43.2% |
| Cosine 0.6 | 95.9% |
| Blur over 3 / 5 / 9 frames | 7.1 / 20.5 / 73.5% |

About 0.2 s per clip. This noise is kinder than real prediction error: a first mapping from stock ViSpeR encoder frames through a small GRU head, fit on about 36 voiced clips per fold, reached cosine 0.757 on held-out voiced clips (0.635 for always predicting the mean frame), yet decoded at 101.2% CER with almost no output. Silent, not time-aligned, stayed at 0.636 and 110.4%. So this size of data cannot train the mapping, as expected. It says nothing yet about the method at scale. The next step is pretraining on public Mandarin audio-video, where the teacher features come free from the audio, then fine-tuning on the participant.

Plan: start from the ViSpeR or v2 visual encoder, train it to predict Qwen3-ASR features on Chinese-LiPS on one rented GPU, adding a loss through the frozen decoder, then fine-tune on personal data in the same way. The earlier run took about 10 hours, about $14 at an unverified $1.4/h, so one pass is estimated at $15 to $25. The VM and its data are deleted afterwards. Chinese-LiPS and CN-CVS are research-only, so this is an experiment path, and a shipped model needs another base. Personal mouth crops only go to a rented machine with the user's explicit OK for that run; whole-face video and sentence text stay local.

Personal capture is built: free talk with no script or per-sentence key, `talk.sh` for labels, review and mouthing your own sentences. Checked on the two scripted takes against their scripts: with review below 0.85 Pinyin agreement between Qwen3-ASR and Whisper, 6 of 52 clips were flagged and the rest had 2 to 4% CER.

### First free-talk take, November 8

The take ran 9 minutes 47 seconds: 106 sentences at pauses, 452 s of speech, 2,603 characters, about 320 characters a minute. Both ASRs now get a list of the participant's names and terms (口喷鸡, Blurt, Claude Code, Codex and others), and Qwen3-ASR also gets the previous sentence. That fixed mishearings of the product name that both models shared, but it also biased some: one product name was replaced by another from the list. So sentences whose text changed with the context also go to review: 31 of 106. The participant edited 24 of them, mostly English names and product terms. Pinyin agreement between two ASRs misses errors both make, and those are concentrated in English terms. 102 sentences were kept (473 s, sharpness 314); 36 were mouthed silently afterwards (165 s, sharpness 117, just under the 120 warning at the same brightness).

Mouthing, with the cue to part the lips, drop the jaw and slow down. Same measure as before, inner lip gap normalized by eye distance, idle frames trimmed:

| Silent / voiced | Paired takes, Nov 7 (41 pairs) | Free talk shadow, Nov 8 (36 pairs) |
| --- | --- | --- |
| Lip-gap range, median | 0.63 (IQR 0.51–0.78) | 0.92 (0.80–1.09), p 0.41 |
| Jaw range, median | 0.73 | 0.64 (0.46–0.96) |
| Duration, median | 0.90 | 1.19 |
| Sealed-lip frames | 26% → 38% | 27% → 23% |

The pass bar (lip-gap ratio at least 0.9, sealed frames within 5 points of voiced) is met. The jaw still moves less, and silent runs slower. The two columns differ in more than the cue: the November 8 voiced side is spontaneous speech rather than reading, and the silent side reads the participant's own words. So it shows that silent articulation can match voiced lip gaps, not that the cue alone caused it.

### Public pretraining on the participant's 4090, November 8

Run on the user's own RTX 4090 on the LAN (`tools/silent-dictation/gpu/`), so no cloud spend. Other jobs on it were paused for the runs. Chinese-LiPS's `processed_*.zip` already hold 96×96 mouth clips at 25 fps with 16 kHz mono audio, so the 69 GB raw archive was not needed: 10 GB downloaded from a Hugging Face mirror at about 13 MB/s with eight connections. `pack.py` stores frames plus the Qwen3-ASR audio-encoder output for each clip (30,341 training clips, 85 h). `v2a_train.py` starts from the v2 ViSpeR encoder, resamples its output to the audio frame count through a small Transformer bridge, and trains with cosine and MSE to the audio features plus cross-entropy of the transcript through the frozen decoder. About 6,700 video frames a second, 21 minutes an epoch, 14–18 GB of memory.

Same 200 validation clips throughout (Chinese-LiPS val, a development set):

| Decoder input | CER |
| --- | --- |
| Real audio features | 0.8% |
| Mean feature frame | 99.9% |
| v2 ViSpeR, beam 5 (the bar) | 47.5% |
| Video, epochs 1 / 2 / 3 / 4 / 5 / 6 | 77.9 / 67.0 / 61.2 / 56.3 / 52.0 / 51.8% |
| Then decoder LoRA rank 16, feature weight 0.2, one epoch | 58.5% |

Cosine to the real features rose only from 0.70 to 0.73 while CER fell, so the gain came through the decoder loss. Training cross-entropy (0.85 per token) is far below what validation implies, so the student overfits training speakers and topics; LoRA added capacity and made it worse, and was stopped after one epoch. The run missed the bar by 4 points. Zero-shot on the participant's clips (epoch 3 checkpoint, on the Mac) it reads 98% CER silent (82 clips) and 98% voiced (148), mostly fluent unrelated sentences, with an occasional near hit (one at 41%). Stock ViSpeR zero-shot on the rapid set was 102% silent and 86.5% voiced, so public training does not transfer to this webcam by itself; personal fine-tuning is the next step.

Personal fine-tuning from the epoch 6 checkpoint (`--personal`, five folds keeping each sentence and its silent shadow on one side, 20 epochs, all four rapid and free-talk sessions: 148 voiced and 82 silent clips, mouth crops only, on the 4090 with the user's OK). Clip-weighted CER at the last epoch, pooled over folds: silent 85%, voiced 69% (fold range 82–96% and 64–72%); before fine-tuning 95% and 93%. The best epoch per fold was not better by more than a few points. The earlier ViSpeR fine-tune reached 75% silent and 55% voiced on the rapid set, so at this data size the frozen-decoder route is worse, not better, and the go/no-go bar (silent under 70%) is missed by 15 points. Camera-only silent dictation stops here for now.

Whispered audio, measured on the 20 pilot whisper takes (camera mic, about 13 dB quieter than voiced): stock Qwen3-ASR reads them at 57% CER, against 26% on the 20 voiced pilot takes recorded the same way (both short and quiet; the rapid voiced takes read at 3.5%). Errors are mostly dropped or substituted syllables, not invented sentences, so audio carries much of what lips lack.

## Model decision

The original `run.sh` Lipflow checkpoint and adapter remain English-only and require `--language en`. Separate research probes now run CMLR and ViSpeR; the latter supports Mandarin and English in one vocabulary and was used for the local adaptation experiments above. English-only results must not be interpreted as covering the user's 90% Chinese workload.

The author's [multilingual VSR repository](https://github.com/mpc001/Visual_Speech_Recognition_for_Multiple_Languages) provides a separate CMLR Mandarin visual checkpoint, reported at 8.0% CER, with a Mandarin language model. This is a candidate for an isolated Mandarin baseline, not evidence of a shared bilingual recognizer. Its config uses checkpoint-specific `char_list` tokens; inspect that vocabulary before deciding whether its output head can represent English acronyms/words. Switching between separate Chinese/English models at an utterance boundary will not solve language switches inside a sentence.

The [CMLR dataset description](https://www.vipazoo.cn/CMLR.html) explicitly excludes English letters and Arabic numerals and describes 11 newsreaders. Its dataset access is research-oriented; the repository also limits use to separate research/comparison contexts. These conditions and the domain mismatch rule out assuming this checkpoint is a ready commercial Chinese/English typing model.

The CMLR vocabulary audit found no ASCII alphabet tokens. ViSpeR's 21,460-token output vocabulary can represent Chinese and English, but mixed recognition was poor. Its SentencePiece model needs the upstream Chinese character-splitting step; the probe preserves English word/acronym groups inside mixed targets. Chinese and code-switched targets therefore reach valid vocabulary indices, but this is not evidence of accurate code switching. The initial internal development holdout was Mandarin-only; the subsequent separate-session validation measured all three language groups and exposed severe mixed-language and English errors. Keep the planned English, mixed and general-language groups.

## Measurement and data expansion

`language_metrics.py` implements character error rate for Mandarin, word error rate for English, and mixed error rate for Chinese characters plus English words/digit strings. It normalizes Unicode width and case, ignores punctuation, and does not silently expand acronyms, translate, or convert spoken numbers to digits. E.g. `API` versus `A P I` remains a discrepancy under the strict policy. Both multilingual inference probes use these metrics. `score_probe.py` separately reports the disclosed OpenCC script-normalized comparison without overwriting strict results.

Keep the three error rates separate: averaging CER and WER produces an unclear denominator. A later overall product score can weight normalized utterance success or corrected input throughput by the intended usage mixture, while still showing each stratum. Report technical-term accuracy, numeric/negation errors, latency, corrections and fatigue separately. The pilot has only one English family per split; it is not sufficient to conclude that English quality is preserved.

Scale collection through new phonetic/task families and session days, including spontaneous Chinese-dominant tech descriptions. Verified audio ASR labels may bootstrap voiced data; genuinely silent prompts still need participant confirmation. Store what was articulated separately from desired editor formatting (for example, spoken identifier names versus literal source-code spelling). Do not use a spelling-normalization model to manufacture training references.

## Google Cloud readiness and bounded compute plan

Read-only local preflight found `gcloud`, existing user authentication, and local Application Default Credentials. The configured project's Compute Engine read returned `compute.googleapis.com` disabled. GPU quota, billing readiness and capacity therefore remain unverified. No credentials were copied into the repository, no API was enabled, no VM was created, and cloud-training spending for this task is **$0**. See the sanitized [readiness record](../../tools/silent-dictation/results/cloud-readiness.json). Compute authentication uses the existing cloud identity; a generic model API key is not itself proof of VM provisioning rights. [Google authentication documentation](https://docs.cloud.google.com/compute/docs/authentication).

A provisional first candidate is **one L4 with 24 GB VRAM**, subject to a representative memory/throughput check. Google lists L4 on G2 and A100 40 GB on A2; the latter is an escalation candidate if the actual training job cannot fit efficiently. These are planning choices, not measured CUDA performance. [Google GPU specifications](https://docs.cloud.google.com/compute/docs/gpus).

Before a paid run, resolve the actual model and training data, verify the selected region's quota and current total VM price, and start with a short bounded profiling job. Include CPU/RAM, disk and network costs, rather than quoting GPU-only pricing. Use a fixed maximum VM runtime, checkpoint results before termination, and clean up the job's own temporary resources. Google supports `--max-run-duration` and an explicit termination action; persistent storage still needs its own lifecycle. [Total GPU VM pricing](https://cloud.google.com/products/compute/pricing/accelerator-optimized), [VM runtime limits](https://docs.cloud.google.com/compute/docs/instances/limit-vm-runtime).

A VM was rented and deleted on November 7 for the public training recorded above. English and multilingual adaptation both run on the user's Mac, so a rented GPU is not currently necessary. The participant corpus now has 40 training and 40 validation clips. The user's authorization to rent when needed is retained. A large shared-model training run would need a concrete dataset/model/compute estimate before its cost could be justified.

## Validation

The updated Swift recorder compiled and passed the documented recording/playback checks. Seventeen automated dataset, metric and enrollment-plan checks pass. The current audit has 170 planned takes (including 50 pending `train-03` takes) and 80 verified takes across training and validation. Real checkpoints completed inference; four multilingual adaptation experiments completed and saved separate adapters. The newer adapter loader verifies the base checkpoint, saved weights, preprocessing and speaker, and rejects evaluation footage used for gradient updates. The frozen separate-session validation comparison is now complete; final test accuracy remains unmeasured.
