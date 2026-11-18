#!/usr/bin/env python3
"""Time actual supervised adaptation steps on one public clip; never save a model.

This measures the upstream frontend+encoder1 training path, NOT LoRA, generalization,
or a user enrollment run. Repeated use of one clip makes accuracy uninterpretable.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import resource
import statistics
import sys
import time


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--checkout", type=Path, required=True)
    p.add_argument("--rois", type=Path, required=True)
    p.add_argument("--reference", required=True)
    p.add_argument("--steps", type=int, default=4)
    p.add_argument("--output", type=Path, required=True)
    a = p.parse_args()
    if a.steps < 2:
        p.error("At least two steps are needed for a warm measurement")
    sys.path.insert(0, str(a.checkout.resolve()))
    os.environ["TORCH_FORCE_WEIGHTS_ONLY_LOAD"] = "1"
    import numpy as np
    import torch
    from lipflow.vsr import LipReader
    from lipflow.train_vsr import trainable, _targets, clip_loss
    torch.set_num_threads(4)
    torch.manual_seed(0)
    rois = np.load(a.rois, allow_pickle=False)
    reader = LipReader(use_lm=False, personal=False, beam_size=10)
    m, device = reader.model, reader.enc_device
    m.to(device)
    params = trainable(reader, "frontend+encoder1")
    m.train()
    for module in m.modules():
        if isinstance(module, (torch.nn.BatchNorm1d, torch.nn.BatchNorm2d, torch.nn.BatchNorm3d)):
            module.eval()
    targets = _targets(reader, a.reference)
    if not targets:
        raise ValueError("Empty target tokens")
    x = reader.to_tensor(rois)
    optimizer = torch.optim.AdamW(params, lr=1e-4, weight_decay=1e-4)

    def sync():
        if device.type == "mps":
            torch.mps.synchronize()

    steps = []
    for i in range(a.steps):
        sync()
        start = time.perf_counter()
        optimizer.zero_grad(set_to_none=True)
        loss = clip_loss(reader, x, targets)
        if not torch.isfinite(loss):
            raise RuntimeError("Non-finite training loss")
        loss.backward()
        torch.nn.utils.clip_grad_norm_(params, 5.0, error_if_nonfinite=True)
        optimizer.step()
        sync()
        steps.append({"seconds": time.perf_counter() - start, "loss": float(loss.detach().cpu())})
        print(f"step {i+1}: {steps[-1]}", file=sys.stderr, flush=True)
    median = statistics.median(s["seconds"] for s in steps[1:])
    duration = len(rois) / 25
    result = {
        "scope": "Single public clip, batch 1, repeated supervised timing only; no adaptation accuracy measured; no weights saved",
        "method": "Lipflow frontend+encoder1, 0.1 CTC on CPU + 0.9 attention, AdamW; no data augmentation",
        "device": str(device), "torch": torch.__version__, "dtype": "float32",
        "reference": a.reference, "target_tokens": len(targets),
        "rois_sha256": hashlib.sha256(a.rois.read_bytes()).hexdigest(),
        "trainable_parameters": sum(p.numel() for p in params),
        "clip_seconds": duration, "steps": steps, "warm_step_median_seconds": median,
        "training_audio_seconds_per_wall_second": duration / median,
        "projected_20min_10epochs_seconds_excluding_preprocessing_validation": 1200 * 10 / duration * median,
        "peak_process_rss_bytes": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss * (1 if sys.platform == "darwin" else 1024),
        "projection_limit": "Extrapolation from one clip, excludes thermal throttling, varying lengths, augmentation, validation and IO"
    }
    a.output.parent.mkdir(parents=True, exist_ok=True)
    a.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
