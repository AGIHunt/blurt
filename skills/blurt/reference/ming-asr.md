# Ming-3.0-ASR-Tiny (experimental)

Ming is an opt-in local dictation model for x64 Linux with NVIDIA CUDA and Windows with a CUDA-enabled WSL 2 distribution. It recognises Chinese, English and Chinese dialects. The BF16 snapshot is about 17.75 GB. Use a GPU with at least 24 GB of available VRAM for initial testing.

1. Download the complete [InclusionAI snapshot on ModelScope](https://www.modelscope.cn/models/inclusionAI/Ming-3.0-asr-tiny). With the ModelScope CLI, use `modelscope download --model inclusionAI/Ming-3.0-asr-tiny --local_dir /path/to/Ming-3.0-asr-tiny`. On Windows, save it on a drive WSL can access.
2. In Linux or WSL, prepare a dedicated Python environment with CUDA-enabled PyTorch and the matching torchaudio. Use the snapshot's `requirements.txt` and the [publisher's inference example](https://github.com/inclusionAI/Ming-3.0-asr) to verify the environment. Blurt loads the custom model code from this snapshot, so use a copy you trust.
3. Start Blurt with `BLURT_MING_ASR_PYTHON` set to the dedicated environment's Python executable and `BLURT_MING_ASR_MODEL_DIR` set to the absolute path to the checkpoint. On Windows, set `BLURT_MING_ASR_WSL` to the installed distribution name, use a Linux path for the Python executable and a Windows path for the checkpoint.
4. In **Settings → Models → Dictation**, choose **Ming-3.0-ASR-Tiny (CUDA, experimental)**. The entry appears once the checkpoint is available and the environment variables are set.

Blurt runs the model offline in a child process while the speech server is active. Setup and weight downloads are manual. Auto selection keeps using Blurt's existing defaults. This integration handles complete audio pieces and uses Chinese or English hints when selected. It does not expose Ming's prompt or vocabulary features.
