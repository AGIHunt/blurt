"""polish.py CPUEmbedding: a quantized embedding table read from its safetensors file and gathered on the CPU gives
exactly what mlx's QuantizedEmbedding gives (Gemma 4's per-layer embeddings are served this way: 1.26 GB out of Metal
memory). Runs the check under `uv run --with` the pinned mlx-lm (polish.MLX_PACKAGE), so a bump that changes the
layout fails here. Apple Silicon only."""
from __future__ import annotations

import platform
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "skills" / "blurt" / "scripts"
sys.path.insert(0, str(SCRIPTS))
import polish  # noqa: E402

CHECK = r"""
import sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import mlx.core as mx
import mlx.nn as nn
import polish
d = Path(sys.argv[2])
for bits in (4, 8):
    mx.random.seed(bits)
    emb = nn.QuantizedEmbedding.from_embedding(nn.Embedding(300, 128), group_size=64, bits=bits)
    w = {"model.embed_tokens_per_layer." + k: v for k, v in emb.parameters().items()}
    w["model.other.weight"] = mx.zeros((4, 4))
    f = d / f"m{bits}.safetensors"
    mx.save_safetensors(str(f), w)
    cpu = polish.CPUEmbedding([f], "embed_tokens_per_layer", 64, bits, "affine")
    ids = mx.array([[0, 5, 299, 5], [17, 1, 2, 3]])
    assert mx.array_equal(emb(ids), cpu(ids)).item(), bits
print("ok")
"""


@unittest.skipUnless(platform.system() == "Darwin" and platform.machine() == "arm64" and shutil.which("uv"),
                     "MLX: Apple Silicon only")
class CPUEmbeddingMatches(unittest.TestCase):
    def test_same_rows_as_mlx(self):
        with tempfile.TemporaryDirectory() as d:
            p = subprocess.run(["uv", "run", "-q", "--no-project", "--with", polish.MLX_PACKAGE, "python", "-c", CHECK,
                                str(SCRIPTS), d], capture_output=True, text=True, timeout=600)
        self.assertEqual(p.stdout.strip(), "ok", p.stderr[-2000:])

    def test_other_models_are_left_alone(self):
        class Plain:
            language_model = None
        self.assertFalse(polish.offload_per_layer_embeddings(Plain(), Path("/nonexistent")))


if __name__ == "__main__":
    unittest.main()
