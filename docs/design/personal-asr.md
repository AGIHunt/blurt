# Personal speech recognition: fine-tuning on a user's own dictations

Status: experiment, November 8, 2026. Code in `tools/personal-asr/`. Nothing shipped.

## Why

The user dictates all day and still corrects names and English terms by hand. Blurt already keeps every dictation's
audio and what it typed (`~/.blurt/dictation/history.jsonl`, `audio/`), so a person's own speech is free training data.
This builds a LoRA for the Qwen3-ASR 1.7B that Blurt runs locally, from that history alone.

## Pipeline

All of it runs on the user's own machines: the Mac, and their RTX 4090 on the LAN for training. No cloud speech or
language model sees the data.

1. `collect.py`: cut each dictation into the pieces the app found at pauses, and transcribe each piece with Whisper
   large-v3 (MLX) and Qwen3-ASR 0.6B, both given the word list. The app's 1.7B text is already in the history.
2. `batches.py split` and `LABELING.md`: Claude Sonnet subagents read the three transcripts, the app and field text,
   and the typed text, and write what was said (`said`, in recognizer style, fillers kept), whether they are sure, and
   the intended clean text. About 53 dictations per agent.
3. `review.py`: the user checks the unsure pieces in the browser, test pieces first.
4. `export.py`: one training piece per app piece, with the same system prompt the app sends (word list, field text,
   the dictation's text so far; `skills/blurt/scripts/transcribe.py`).
5. `train_lora.py`: LoRA rank 16 on the text decoder and the audio encoder, context parts dropped at random 30% of the
   time, 3 epochs. Testing decodes each held-out dictation's pieces in order, with the model's own earlier output as the
   text so far, as in the app.
6. `lora_export.py`: the LoRA as named safetensors (MLX module paths, about 50 MB).
7. `to_mlx_lora.py` (Mac): fold it into the app's stock 8-bit MLX build. `merge_lora.py` writes a full-precision merged
   model instead, for other runtimes.
8. `eval_mlx.py` (Mac): score stock and personal builds through the app's own decoder before deploying.

## First run

History: 829 dictations with audio, 3,561 pieces, 4.8 hours. Sixteen Sonnet agents labeled them; 198 pieces (5.6%)
were marked unsure and 99 pieces were noise or a model reciting the word list. The newest 15% of dictations (125,
1.3 hours) are the test set. Typical fixes the labels make are the speaker's recurring mishearings: product and English
terms turned into Chinese sound-alikes, and Chinese words heard as similar-sounding ones.

Training on the 2,302 sure training pieces took about 5 minutes an epoch on the 4090.

| Test pieces (847, labeler-sure only) | CER | English and product terms found (159) |
| --- | --- | --- |
| What the app typed at the time, before polishing (801 with text logged) | 2.33% | |
| Stock Qwen3-ASR 1.7B (bf16, transformers), app's prompt | 2.80% | 138 |
| Same with the LoRA, epoch 3 | **1.61%** | **152** |

Character errors fall by about 43% and term recall goes from 87% to 96%. With the correct earlier text as context
instead of the model's own, the numbers are 2.71% and 1.49%.

Then the user checked 197 of the 198 unsure pieces (122 kept, 46 edited, mostly names of people and companies, and
31 dropped), and the run was repeated on 2,429 training pieces with the full test set:

| Test pieces (885, all reviewed or sure) | CER | English and product terms found (178) |
| --- | --- | --- |
| What the app typed at the time, before polishing (834 with text logged) | 2.56% | |
| Stock Qwen3-ASR 1.7B, app's prompt | 2.93% | 151 (85%) |
| With the LoRA, epochs 1 / 2 / 3 | 1.90 / 1.83 / **1.77%** | **168 (94%)** |

About 40% fewer character errors, and term misses fall from 27 to 10. These are the numbers to use.

Caveats: the references for pieces the agents were sure of come from the agents, not the user; the labels lean on
the same three models whose errors they fix.

### Overfitting check

Memorization: the people's names the user corrected in review, and two other corrected words, occur only in test
pieces, never in training labels, and the LoRA does not get the names either (0 of 5). The gain is broad rather than in a few words:

| Test pieces | Pieces | Stock | LoRA |
| --- | --- | --- | --- |
| No English term | 752 | 2.49% | 1.72% |
| English terms all seen in training | 100 | 3.97% | 1.74% |
| An English term never in training | 33 | 8.32% | 2.72% |
| Chinese, over 30% of character pairs unseen in training | 339 | 2.26% | 2.13% |
| All, fillers, particles and 儿 removed from both sides | 885 | 2.84% | 1.69% |

Unseen English terms: 28 of 35 found by stock, 30 by the LoRA. So most of the gain is on the user's voice and recurring
vocabulary and topics; on content far from the training set it is small (2.26 → 2.13%). Fillers are not the source.

Other speakers (300 Chinese-LiPS validation clips, no context): stock 1.09%, LoRA 3.30%. Most of that is formatting the
metric counts as errors: the LoRA writes numbers as digits (2024, 25%, 2V) because the labeling rules asked for digits
when transcripts disagreed (62 training labels have digits; the app's own text had them in 1), and it drops stutters
the references keep (a repeated character in a stutter). Without the 38 clips where either output has digits: 0.87% vs 1.04%. One real
error comes from the digit habit: a count of cities came out as a percentage. 180 of 300 outputs are identical.

The user wants digits from the recognizer (versions such as 1.0.13 came out in Chinese and had to be fixed by hand),
so the fix went the other way: a second Sonnet pass (`numbers/`, rule in `LABELING.md`) rewrote every number in the
labels as digits, consistently, keeping numerals that are part of words (一些, 一下, 一点儿, 三五个).

## Final model and deployment (November 9)

Retrained on the unified labels (v3), then folded into the app's 8-bit MLX build on the Mac (`lora_export.py`,
`to_mlx_lora.py`: decoder weights dequantized, delta added, requantized 8-bit group 64; encoder float16), so only the
49 MB LoRA crossed the slow LAN. Scored with `eval_mlx.py` through the app's own `Qwen3Mlx` decoder (word list, field
text, the model's own text so far, language-tag handling), on the 885 reviewed test pieces with digit labels:

| Model | CER |
| --- | --- |
| Stock 1.7B, bf16, plain decode (4090) | 3.41% |
| LoRA, bf16, plain decode (4090), epochs 1 / 2 / 3 | 1.81 / 1.72 / 1.75% |
| **Stock 8-bit MLX, the app's decoder** | **2.48%** |
| LoRA v2 (older number labels) folded into 8-bit MLX | 2.09% |
| **LoRA v3 folded into 8-bit MLX, the app's decoder** | **1.66%** |

About a third fewer errors in the app itself. Merging costs nothing at inference: the folded model has the same tensors,
shapes and size (2.46 GB) as the stock build, and the full-precision merge (`merge_lora.py`) scored 1.75% against 1.77%
with the LoRA attached.

Deployed on the user's Mac by replacing `~/.blurt/models/asr/Qwen3-ASR-1.7B-8bit` (stock kept beside it as
`Qwen3-ASR-1.7B-8bit.stock`; its manifest is rewritten so `folder_complete` accepts it). To revert, swap the folders
back. Shipping personal models to other users is not built: Blurt would need its own model slot instead of overwriting
the stock folder.

Backups are in two private Hugging Face repos of the user's: the dataset (pieces, labels, reviews, candidates) and the
model (LoRA, the 8-bit MLX build, the scripts). Polishing was not part of these tests.
