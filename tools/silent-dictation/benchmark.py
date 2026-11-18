#!/usr/bin/env python3
"""Benchmark a separately installed Lipflow checkout; no live capture or cloud calls.

Example: python benchmark.py --checkout /tmp/blurt-vsr-research/lipflow \
  --video clip.mp4 --reference 'words actually spoken' --output result.json
Only video frames enter the recognizer. Use verified references for accuracy claims.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import resource
import statistics
import subprocess
import sys
import time


def tokens(text, unit):
    text = text.casefold()
    if unit == "character":
        return [c for c in text if c.isalnum()]
    return re.findall(r"\w+(?:'\w+)?", text)


def error_rate(reference, hypothesis, unit="word"):
    a, b = tokens(reference, unit), tokens(hypothesis, unit)
    if not a:
        raise ValueError("Reference must contain at least one token")
    previous = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        current = [i]
        for j, y in enumerate(b, 1):
            current.append(min(current[-1] + 1, previous[j] + 1, previous[j-1] + (x != y)))
        previous = current
    return {"unit": unit, "errors": previous[-1], "reference_tokens": len(a),
            "rate": previous[-1] / len(a)}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--checkout", type=Path, required=True)
    inputs = p.add_mutually_exclusive_group(required=True)
    inputs.add_argument("--video", type=Path)
    inputs.add_argument("--rois", type=Path, help="Precomputed (T,96,96) uint8 crops at 25 fps")
    p.add_argument("--reference")
    p.add_argument("--unit", choices=["word", "character"], default="word")
    p.add_argument("--start", type=float, default=0)
    p.add_argument("--end", type=float)
    p.add_argument("--repeats", type=int, default=3)
    p.add_argument("--beam", type=int, default=10)
    p.add_argument("--threads", type=int, default=4)
    p.add_argument("--device", choices=["auto", "cpu", "mps"], default="auto")
    p.add_argument("--no-lm", action="store_true")
    p.add_argument("--output", type=Path, required=True)
    p.add_argument("--save-rois", type=Path, help="Optional local mouth crops for a separate training timing probe")
    args = p.parse_args()
    if args.repeats < 1 or args.threads < 1 or args.start < 0 or (args.end is not None and args.end <= args.start):
        p.error("Invalid repeats, threads or clip interval")
    checkout = args.checkout.resolve()
    sys.path.insert(0, str(checkout))
    # PyTorch's restricted tensor loader, also for the upstream LM loader.
    os.environ["TORCH_FORCE_WEIGHTS_ONLY_LOAD"] = "1"
    import torch
    from lipflow.vsr import LipReader
    torch.set_num_threads(args.threads)
    t = time.perf_counter()
    if args.rois:
        import numpy as np
        if args.start or args.end is not None:
            p.error("--start/--end only apply to video input")
        rois = np.load(args.rois, allow_pickle=False)
        if rois.ndim != 3 or rois.shape[1:] != (96, 96) or rois.dtype != np.uint8:
            raise ValueError("Expected uint8 mouth crops with shape (T,96,96)")
        frames, anchors = rois, None
    else:
        from lipflow.face import FaceTracker, mouth_rois
        from lipflow.offline import load_clip
        tracker = FaceTracker()
        try:
            timestamps, frames, anchors = load_clip(str(args.video.resolve()), tracker, args.start, args.end)
        finally:
            tracker.close()
        idx = LipReader.resample(timestamps, len(timestamps))
        rois = mouth_rois([frames[i] for i in idx], [anchors[i] for i in idx])
    if rois is None or len(rois) == 0:
        raise RuntimeError("No usable face frames")
    if args.save_rois:
        import numpy as np
        np.save(args.save_rois, rois, allow_pickle=False)
    preprocessing = time.perf_counter() - t
    t = time.perf_counter()
    model = LipReader(device=args.device, beam_size=args.beam, use_lm=not args.no_lm, personal=False)
    load_seconds = time.perf_counter() - t

    def sync():
        if model.enc_device.type == "mps":
            torch.mps.synchronize()

    runs = []
    for _ in range(args.repeats + 1):
        sync()
        t0 = time.perf_counter()
        encoded = model.encode(rois)
        sync()
        t1 = time.perf_counter()
        hypothesis = model.beam_search(encoded)
        t2 = time.perf_counter()
        runs.append({"encoder_seconds": t1 - t0, "decoder_seconds": t2 - t1,
                     "inference_seconds": t2 - t0, "hypothesis": hypothesis})
    weights = checkout / "models/vsr/model.pth"
    with weights.open("rb") as f:
        weight_hash = hashlib.file_digest(f, "sha256").hexdigest()
    result = {
        "scope": "Offline prerecorded video; no audio, no personalization, no LLM cleanup; not silent-mouthing validation",
        "platform": platform.platform(), "torch": torch.__version__,
        "checkout_commit": subprocess.check_output(["git", "-C", str(checkout), "rev-parse", "HEAD"], text=True).strip(),
        "model_sha256": weight_hash, "encoder_device": str(model.enc_device),
        "decoder_device": str(model.device), "cpu_threads": args.threads,
        "beam": args.beam, "language_model": not args.no_lm,
        "model_parameters": sum(x.numel() for x in model.model.parameters()),
        "input_frames": len(frames), "model_frames": len(rois), "model_fps": 25,
        "face_fraction": sum(a is not None for a in anchors) / len(anchors) if anchors is not None else None,
        "video": str(args.video.resolve()) if args.video else None,
        "precomputed_rois": str(args.rois.resolve()) if args.rois else None,
        "preprocessing_note": "ROI loading only; upstream tracking/alignment excluded" if args.rois else "MediaPipe tracking and alignment included",
        "start": args.start, "end": args.end,
        "preprocessing_seconds": preprocessing, "model_load_seconds": load_seconds,
        "first_inference": runs[0], "warm_runs": runs[1:],
        "warm_median_seconds": statistics.median(r["inference_seconds"] for r in runs[1:]),
        "peak_process_rss_bytes": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss * (1 if sys.platform == "darwin" else 1024),
    }
    result["warm_real_time_factor"] = result["warm_median_seconds"] / (len(rois) / 25)
    if args.reference:
        result["reference"] = args.reference
        result["accuracy"] = error_rate(args.reference, runs[-1]["hypothesis"], args.unit)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps(result, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
