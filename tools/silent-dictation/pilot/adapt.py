#!/usr/bin/env python3
"""Bounded single-speaker adaptation. Select by validation loss; never use test clips."""
import argparse
from datetime import datetime, timezone
import os
from pathlib import Path
import random
import re
import sys
import time

from dataset import load_clips, sha256, split_audit, write_json
from pipeline import model_setup, prepared_clip


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("root", type=Path)
    p.add_argument("--checkout", required=True, type=Path)
    p.add_argument("--output", required=True, type=Path, help="New .pth path; no production/user model is overwritten")
    p.add_argument("--device", choices=["auto", "mps", "cpu"], default="auto")
    p.add_argument("--language", choices=["en"], help="Explicit English-only baseline; required for the Chinese-first profile")
    p.add_argument("--epochs", type=int, default=6)
    p.add_argument("--max-seconds", type=int, default=1800, help="Training/validation budget checked between clips; excludes loading")
    p.add_argument("--modes", nargs="+", choices=["silent", "exaggerated_silent", "whisper", "voiced"], default=["silent"])
    args = p.parse_args()
    if not 1 <= args.epochs <= 30 or not 1 <= args.max_seconds <= 3600:
        p.error("Use 1–30 epochs and 1–3600 seconds")
    if args.output.suffix != ".pth" or args.output.exists() or args.output.with_suffix(".json").exists():
        p.error("Choose a new .pth output path")
    root = args.root.resolve()
    plan, all_clips = load_clips(root)
    if plan.get("profile") == "tech_zh90_v1" and args.language != "en":
        raise ValueError("This adapter trains English only. Select --language en explicitly for a baseline; Mandarin/mixed adaptation needs a compatible checkpoint.")
    # Validate collection structure without using any test video for fitting or selection.
    audit = split_audit(root, all_clips)
    clips = [c for c in all_clips if c["split"] in ("train", "validation") and c["language"] == "en" and c["mode"] in args.modes]
    if {c["split"] for c in clips} != {"train", "validation"}:
        raise ValueError("Verified English training AND validation clips are required")
    if len({c["speaker_id"] for c in clips}) != 1:
        raise ValueError("This adapter must belong to exactly one speaker")
    if sum(c["duration_seconds"] for c in clips) > 1800:
        raise ValueError("Pilot adaptation is limited to 30 minutes of input")
    for c in clips:
        if not re.fullmatch(r"[A-Za-z'\s.,!?;:\-]+", c["reference_text"]):
            raise ValueError(f"English checkpoint requires spoken words in references (spell numbers out): {c['id']}")
    # Resolve and validate all inputs before allocating the model.
    prepared = [(c, *prepared_clip(root, c)) for c in clips]
    seen = {}
    for c, _, meta in prepared:
        key = meta["signature"]["source_sha256"]
        if key in seen and seen[key] != c["split"]:
            raise ValueError("Identical video content crosses training/validation splits")
        seen[key] = c["split"]
    reader, provenance = model_setup(args, use_lm=False)
    import numpy as np
    import torch
    from lipflow.train_vsr import trainable, _targets, clip_loss, _augment
    torch.manual_seed(0); random.seed(0)
    reader.model.to(reader.enc_device)
    params = trainable(reader, "frontend+encoder1")
    optimizer = torch.optim.AdamW(params, lr=1e-4, weight_decay=1e-4)
    sets = {"train": [], "validation": []}
    for c, path, meta in prepared:
        rois = np.load(path, allow_pickle=False)
        targets = _targets(reader, c["reference_text"])
        if rois.dtype != np.uint8 or rois.ndim != 3 or rois.shape[1:] != (96, 96) or not 0 < len(targets) <= len(rois) <= 850:
            raise ValueError(f"Invalid crops or target length: {c['id']}")
        sets[c["split"]].append((rois, targets))
    prefixes = ("encoder.frontend.", "encoder.embed.", "encoder.encoders.0.")
    start = time.perf_counter()
    deadline = start + args.max_seconds

    def check_budget():
        if time.perf_counter() >= deadline:
            raise TimeoutError("Time budget reached between clips")

    def validation():
        reader.model.eval()
        losses = []
        with torch.no_grad():
            for rois, targets in sets["validation"]:
                check_budget()
                loss = clip_loss(reader, reader.to_tensor(rois), targets)
                if not torch.isfinite(loss):
                    raise RuntimeError("Non-finite validation loss")
                losses.append(float(loss.cpu()))
        return sum(losses) / len(losses)

    def snapshot():
        return {k: v.detach().cpu().clone() for k, v in reader.model.state_dict().items() if k.startswith(prefixes)}

    best = validation()  # If the budget cannot cover baseline validation, no adapter is saved.
    best_epoch, best_state = 0, snapshot()
    history = [{"epoch": 0, "validation_loss": best}]
    stop_reason = "epochs_complete"
    try:
        for epoch in range(1, args.epochs + 1):
            reader.model.train()
            for mod in reader.model.modules():
                if isinstance(mod, (torch.nn.BatchNorm1d, torch.nn.BatchNorm2d, torch.nn.BatchNorm3d)):
                    mod.eval()
            random.shuffle(sets["train"])
            losses = []
            for rois, targets in sets["train"]:
                check_budget()
                optimizer.zero_grad(set_to_none=True)
                loss = clip_loss(reader, _augment(rois), targets)
                if not torch.isfinite(loss):
                    raise RuntimeError("Non-finite training loss")
                loss.backward()
                torch.nn.utils.clip_grad_norm_(params, 5, error_if_nonfinite=True)
                optimizer.step()
                losses.append(float(loss.detach().cpu()))
            val = validation()
            history.append({"epoch": epoch, "training_loss": sum(losses)/len(losses), "validation_loss": val})
            print(history[-1], flush=True)
            if val < best:
                best, best_epoch, best_state = val, epoch, snapshot()
    except TimeoutError:
        stop_reason = "time_budget"
    args.output.parent.mkdir(parents=True, exist_ok=True)
    temporary = args.output.with_suffix(".tmp")
    torch.save(best_state, temporary)
    temporary.replace(args.output)
    metadata = {**provenance, "adapter_sha256": sha256(args.output), "speaker_id": clips[0]["speaker_id"],
                "created_at": datetime.now(timezone.utc).isoformat(), "scope": "frontend+encoder1", "modes": args.modes, "split_audit": audit,
                "trainable_parameters": sum(x.numel() for x in params), "epochs_requested": args.epochs,
                "max_seconds": args.max_seconds, "elapsed_training_validation_seconds": time.perf_counter()-start,
                "stop_reason": stop_reason, "best_epoch": best_epoch, "history": history,
                "selection": "Minimum mean per-clip validation loss, including stock epoch zero; not a WER improvement claim",
                "used_sessions": sorted({c["session_id"] for c in clips}),
                "used_families": sorted({c["phrase_family"] for c in clips}),
                "used_clips": [{"id": c["id"], "split": c["split"], "reference_text": c["reference_text"],
                                "source_sha256": m["signature"]["source_sha256"], "rois_sha256": m["rois_sha256"]} for c, _, m in prepared],
                "license_note": "Research checkpoint derivative; commercial model rights are not cleared."}
    write_json(args.output.with_suffix(".json"), metadata)
    print(f"Saved {args.output}; selected epoch {best_epoch}. Evaluate on untouched test sessions next.")


if __name__ == "__main__":
    main()
