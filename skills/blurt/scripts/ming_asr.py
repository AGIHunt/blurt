"""Opt-in Ming ASR worker in a separate CUDA Python environment."""
from __future__ import annotations

import base64
import contextlib
import json
import os
from pathlib import Path
import queue
import subprocess
import sys
import threading


MODEL_ID = "ming-3.0-asr-tiny"
SETUP_HINT = "Set BLURT_MING_ASR_PYTHON and BLURT_MING_ASR_MODEL_DIR; on Windows also set BLURT_MING_ASR_WSL"
SR = 16000
REQUIRED_FILES = (
    "config.json", "tokenizer.json", "model.safetensors.index.json", "asr_request.py",
    "modeling_ming_v3_asr.py", "processing_ming_v3_asr.py",
)


def model_dir() -> Path | None:
    python = os.environ.get("BLURT_MING_ASR_PYTHON")
    directory = os.environ.get("BLURT_MING_ASR_MODEL_DIR")
    if not python or not directory or (os.name == "nt" and not os.environ.get("BLURT_MING_ASR_WSL")):
        return None
    path = Path(directory)
    if not path.is_absolute() or not all((path / name).is_file() for name in REQUIRED_FILES):
        return None
    return path


def worker_command(directory: Path) -> list[str]:
    python = os.environ["BLURT_MING_ASR_PYTHON"]
    script = Path(__file__).resolve()
    if os.name != "nt":
        return [python, "-u", str(script), str(directory)]
    wsl = ["wsl.exe", "--distribution", os.environ["BLURT_MING_ASR_WSL"], "--exec"]
    paths = [
        subprocess.check_output(wsl + ["wslpath", "-a", "-u", path.as_posix()], encoding="utf-8", timeout=15,
                                creationflags=subprocess.CREATE_NO_WINDOW).strip()
        for path in (script, directory)
    ]
    return wsl + [python, "-u", *paths]


class MingASR:
    """Keep the CUDA worker warm between pieces. Audio passes only through its stdin."""

    max_chunk = 20
    model = MODEL_ID

    def __init__(self, args):
        self.language = args.language
        self.lock = threading.Lock()
        self.child = None
        self._start()

    def _start(self):
        directory = model_dir()
        if directory is None:
            raise RuntimeError(SETUP_HINT)
        self.responses = queue.Queue()
        self.child = subprocess.Popen(
            worker_command(directory), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            encoding="utf-8", bufsize=1, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )
        threading.Thread(target=self._read, args=(self.child.stdout, self.responses), daemon=True).start()
        try:
            self._receive(180)
        except Exception:
            self.close()
            raise

    @staticmethod
    def _read(stream, responses):
        try:
            with stream:
                for line in stream:
                    responses.put(json.loads(line))
        except (OSError, ValueError):
            pass
        finally:
            responses.put({"error": "Ming ASR worker stopped. Check the CUDA environment and model files."})

    def _receive(self, timeout):
        try:
            response = self.responses.get(timeout=timeout)
        except queue.Empty as exc:
            raise RuntimeError("Ming ASR worker timed out") from exc
        if not response.get("ok"):
            raise RuntimeError(response["error"])
        return response

    def transcribe(self, samples):
        hint = (self.language or "").lower().split("-")[0]
        audio = base64.b64encode(samples.astype("<f4", copy=False).tobytes()).decode("ascii")
        with self.lock:
            if self.child is None or self.child.poll() is not None:
                self.close()
                self._start()
            try:
                self.child.stdin.write(json.dumps({"audio": audio, "language": hint}) + "\n")
                self.child.stdin.flush()
                response = self._receive(60)
            except (OSError, RuntimeError):
                self.close()
                raise
        return [(0.0, len(samples) / SR, response["text"])]

    def close(self):
        child, self.child = self.child, None
        if child is None:
            return
        with contextlib.suppress(OSError):
            child.stdin.close()
        try:
            child.wait(timeout=2)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait()


def run_worker(directory: str):
    """Load only the explicitly prepared local snapshot, using InclusionAI's request helpers."""
    os.environ["HF_HUB_OFFLINE"] = "1"
    os.environ["TRANSFORMERS_OFFLINE"] = "1"
    os.environ["TQDM_DISABLE"] = "1"
    replies = sys.stdout
    with contextlib.redirect_stdout(sys.stderr):
        import numpy as np
        import torch
        from transformers import AutoModelForCausalLM, AutoProcessor

        sys.path.insert(0, directory)
        from asr_request import decode_transcript, prepare_asr_request

        if not torch.cuda.is_available():
            raise RuntimeError("Ming ASR requires a CUDA GPU")
        options = {"trust_remote_code": True, "local_files_only": True}
        processor = AutoProcessor.from_pretrained(directory, **options)
        model = AutoModelForCausalLM.from_pretrained(
            directory, **options, dtype=torch.bfloat16, device_map="cuda:0", attn_implementation="sdpa",
        ).eval()
        eos = model.config.text_config.eos_token_id
    print('{"ok":true}', file=replies, flush=True)
    for line in sys.stdin:
        try:
            request = json.loads(line)
            samples = np.frombuffer(base64.b64decode(request["audio"], validate=True), dtype="<f4").copy()
            hint = request["language"]
            with contextlib.redirect_stdout(sys.stderr), torch.inference_mode():
                inputs = prepare_asr_request(
                    processor, (samples, SR), language_hint=hint if hint in ("zh", "en") else None,
                ).to(model.device)
                output = model.generate(
                    **inputs, max_new_tokens=256, do_sample=False, eos_token_id=eos,
                    pad_token_id=eos, no_repeat_ngram_size=10,
                )
                generated = output[0, inputs.input_ids.shape[1]:].tolist()
                response = {"ok": True, "text": decode_transcript(processor.tokenizer, generated)}
        except (KeyError, ValueError, RuntimeError) as exc:
            response = {"ok": False, "error": f"Ming ASR: {exc}"}
        print(json.dumps(response), file=replies, flush=True)


if __name__ == "__main__":
    run_worker(sys.argv[1])
