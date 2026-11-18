# Ming-3.0-ASR-Tiny (experimental)

Ming is an opt-in local dictation model for x64 Linux with NVIDIA CUDA and Windows with a CUDA-enabled WSL 2 distribution. It recognises Chinese, English and Chinese dialects. The BF16 snapshot is about 17.75 GB. Use a GPU with at least 24 GB of available VRAM for initial testing.

1. Download the complete [InclusionAI snapshot on ModelScope](https://www.modelscope.cn/models/inclusionAI/Ming-3.0-asr-tiny). With the ModelScope CLI, use `modelscope download --model inclusionAI/Ming-3.0-asr-tiny --local_dir /path/to/Ming-3.0-asr-tiny`. On Windows, save it on a drive WSL can access.
2. In Linux or WSL, prepare a dedicated Python environment with CUDA-enabled PyTorch and the matching torchaudio. Use the snapshot's `requirements.txt` and the [publisher's inference example](https://github.com/inclusionAI/Ming-3.0-asr) to verify the environment. Blurt loads the custom model code from this snapshot, so use a copy you trust.
3. Start Blurt with `BLURT_MING_ASR_PYTHON` set to the dedicated environment's Python executable and `BLURT_MING_ASR_MODEL_DIR` set to the absolute path to the checkpoint. On Windows, set `BLURT_MING_ASR_WSL` to the installed distribution name, use a Linux path for the Python executable and a Windows path for the checkpoint.
4. In **Settings → Models → Dictation**, choose **Ming-3.0-ASR-Tiny (CUDA, experimental)**. The entry appears once the checkpoint is available and the environment variables are set.

Blurt runs the model offline in a child process while the speech server is active. Setup and weight downloads are manual. Auto selection keeps using Blurt's existing defaults. This integration handles complete audio pieces and uses Chinese or English hints when selected. It does not expose Ming's prompt or vocabulary features.

## Smaller 4-bit checkpoint

The [MLX community 4-bit export on ModelScope](https://modelscope.cn/models/mlx-community/Ming-3.0-asr-tiny-4bit) is about 5.75 GB. Use a separate Linux or WSL environment with `mlx-audio==0.6.3` and `mlx[cuda12]==0.32.4`. MLX on CUDA needs the CUDA headers as well as the runtime libraries. Set `CUDA_HOME` to a compatible CUDA toolkit when the environment cannot find its headers. Supply a Python executable or launcher that configures CUDA in that same environment.

Set `BLURT_MING_ASR_MLX_PYTHON` and `BLURT_MING_ASR_MLX_MODEL_DIR` in place of the BF16 variables, then choose **Ming-3.0-ASR-Tiny (4-bit, experimental)**. The first use may spend extra time compiling CUDA kernels. Separate Chinese and English samples were verified on RTX 5090 with WSL 2. Mixed-language accuracy is still under evaluation.
