#!/usr/bin/env python3
"""Offline preparation/evaluation for the local pilot. Never opens capture devices."""
import argparse
from collections import defaultdict
import json
import os
from pathlib import Path
import statistics
import subprocess
import sys
import time

from dataset import load_clips, local_path, read_json, sha256, split_audit, write_json

TOOLS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOLS))
from benchmark import error_rate, tokens


def run(command):
    return subprocess.check_output(list(map(str, command)), stderr=subprocess.PIPE, timeout=300)


def prepare(args):
    root = args.root.resolve()
    _, clips = load_clips(root)
    if not clips:
        raise ValueError("No verified recordings. Record and review takes first.")
    prepared = root / "prepared"
    prepared.mkdir(exist_ok=True)
    for clip in clips:
        folder = prepared / clip["id"]
        folder.mkdir(exist_ok=True)
        source = local_path(root, clip["video"])
        signature = {"source_sha256": sha256(source), "probe_sha256": sha256(args.probe),
                     "crop_script_sha256": sha256(TOOLS / "native_rois.py"),
                     "pipeline_sha256": sha256(__file__), "mean_face_sha256": sha256(args.mean_face)}
        meta = folder / "status.json"
        if meta.exists():
            old = read_json(meta)
            if old.get("signature") == signature and old.get("status") == "ready" and (folder / "rois.npy").exists():
                if old.get("rois_sha256") == sha256(folder / "rois.npy"):
                    print(f"cached {clip['id']}", flush=True)
                    continue
        started = time.perf_counter()
        result = {"id": clip["id"], "signature": signature}
        try:
            info = json.loads(run(["ffprobe", "-v", "error", "-show_streams", "-show_format", "-of", "json", source]))
            duration = float(info["format"]["duration"])
            if not 0 < duration <= 32:
                raise ValueError("Actual video duration exceeds the short-clip limit")
            has_audio = any(s["codec_type"] == "audio" for s in info["streams"])
            if has_audio != clip["audio_recorded"]:
                raise ValueError("Audio track disagrees with the manifest")
            video = folder / "video.mp4"
            # FFmpeg autorotates; bake the geometry and zero-based 25 fps timestamps.
            run(["ffmpeg", "-v", "error", "-y", "-i", source, "-map", "0:v:0", "-an",
                 "-vf", "scale='min(1280,iw)':-2,fps=25,setpts=PTS-STARTPTS,setsar=1",
                 "-c:v", "libx264", "-crf", "18", "-metadata:s:v:0", "rotate=0", video])
            anchors = json.loads(run([args.probe, video, "850", "--anchors"]))
            write_json(folder / "anchors.json", anchors)
            usable = sum(x is not None for x in anchors["anchors_image_xy"]) / anchors["frames"]
            result["quality"] = {"usable_anchor_fraction": usable,
                                 "multiple_face_frames": anchors["frames_with_multiple_faces"],
                                 "mouth_width_pixels_p50": anchors["mouth_width_pixels_p50"]}
            if usable < .95 or anchors["frames_with_multiple_faces"] > 0:
                raise ValueError("Quality gate: at least 95% usable anchors and no multiple-face frames required")
            run([args.crop_python, TOOLS / "native_rois.py", "--video", video, "--anchors", folder / "anchors.json",
                 "--mean-face", args.mean_face, "--output", folder / "rois.npy"])
            result.update(status="ready", frames=anchors["frames"], rois_sha256=sha256(folder / "rois.npy"))
        except (ValueError, KeyError, subprocess.SubprocessError) as error:
            detail = error.stderr.decode(errors="replace")[-2000:] if isinstance(error, subprocess.CalledProcessError) else str(error)
            result.update(status="failed", error=detail)
        result["preparation_seconds"] = time.perf_counter() - started
        write_json(meta, result)
        print(f"{result['status']} {clip['id']}", flush=True)


def prepared_clip(root, clip):
    folder = root / "prepared" / clip["id"]
    meta = read_json(folder / "status.json")
    if meta["status"] != "ready":
        raise ValueError(meta.get("error", "Preparation failed"))
    if sha256(local_path(root, clip["video"])) != meta["signature"]["source_sha256"]:
        raise ValueError("Source changed after preparation; prepare again")
    if sha256(folder / "rois.npy") != meta["rois_sha256"]:
        raise ValueError("ROI content changed after preparation")
    return folder / "rois.npy", meta


def model_setup(args, use_lm=True):
    os.environ["TORCH_FORCE_WEIGHTS_ONLY_LOAD"] = "1"
    sys.path.insert(0, str(args.checkout.resolve()))
    import torch
    from lipflow.vsr import LipReader
    torch.set_num_threads(4)
    started = time.perf_counter()
    reader = LipReader(device=args.device, beam_size=10, use_lm=use_lm, personal=False)
    provenance = {"base_model_sha256": sha256(args.checkout / "models/vsr/model.pth"),
                  "checkout_commit": run(["git", "-C", args.checkout, "rev-parse", "HEAD"]).decode().strip(),
                  "language_model": use_lm, "beam": 10, "torch": torch.__version__,
                  "model_load_seconds": time.perf_counter() - started,
                  "encoder_device": str(reader.enc_device)}
    if use_lm:
        provenance["lm_sha256"] = sha256(args.checkout / "models/lm/model.pth")
    return reader, provenance


def summarize(rows):
    groups = defaultdict(list)
    for row in rows:
        groups[(row["split"], row["language"], row["mode"])].append(row)
    output = []
    for (split, language, mode), items in groups.items():
        errors = sum(x["accuracy"]["errors"] for x in items)
        total = sum(x["accuracy"]["reference_tokens"] for x in items)
        times = sorted(x["inference_seconds"] for x in items if x["status"] == "ok")
        output.append(dict(split=split, language=language, mode=mode, clips=len(items),
                           failures=sum(x["status"] != "ok" for x in items), errors=errors, reference_tokens=total,
                           word_error_rate=errors / total, exact_match_rate=sum(x["exact_match"] for x in items) / len(items),
                           inference_median_seconds=statistics.median(times) if times else None,
                           inference_p95_seconds=times[min(len(times)-1, int(.95 * len(times)))] if times else None))
    return output


def evaluate(args):
    import numpy as np
    import torch
    root = args.root.resolve()
    plan, all_clips = load_clips(root)
    if plan.get("profile") == "tech_zh90_v1" and args.language != "en":
        raise ValueError("This installed model covers only the 10% English baseline. Select --language en explicitly; Mandarin/mixed recognition is not implemented.")
    audit = split_audit(root, all_clips)
    selected = [c for c in all_clips if c["split"] == args.split and c["language"] == "en"]
    if not selected:
        raise ValueError("No verified English clips in this split. This checkpoint cannot evaluate Mandarin.")
    if args.output.exists():
        raise ValueError("Output already exists; choose a new run filename")
    reader, provenance = model_setup(args)
    if args.adapter:
        metadata = read_json(args.adapter.with_suffix(".json"))
        if metadata["base_model_sha256"] != provenance["base_model_sha256"] or metadata["adapter_sha256"] != sha256(args.adapter):
            raise ValueError("Adapter or base checkpoint hash mismatch")
        if {c["speaker_id"] for c in selected} != {metadata["speaker_id"]}:
            raise ValueError("Adapter belongs to a different speaker")
        # Session/family checks apply even when a different plan is used for evaluation.
        if args.split == "test":
            used_hashes = {x["source_sha256"] for x in metadata["used_clips"]}
            for c in selected:
                if c["session_id"] in metadata["used_sessions"] or c["phrase_family"] in metadata["used_families"]:
                    raise ValueError("Test session/family overlaps adaptation data")
                if sha256(local_path(root, c["video"])) in used_hashes:
                    raise ValueError("Test media was used for adaptation")
        state = torch.load(args.adapter, map_location="cpu", weights_only=True)
        current = reader.model.state_dict()
        expected = {k for k in current if k.startswith(("encoder.frontend.", "encoder.embed.", "encoder.encoders.0."))}
        if set(state) != expected or any(state[k].shape != current[k].shape for k in state):
            raise ValueError("Adapter tensors do not match the supported adaptation scope")
        reader.model.load_state_dict(state, strict=False)
        provenance["adapter"] = metadata
    warmup_start = time.perf_counter()
    reader.warmup()
    provenance["warmup_seconds"] = time.perf_counter() - warmup_start
    rows = []
    for clip in selected:
        row = {k: clip[k] for k in ("id", "speaker_id", "session_id", "split", "language", "mode", "phrase_family", "reference_text")}
        row["reference_provenance"] = clip.get("reference_provenance", "unspecified")
        row["language_profile"] = clip.get("language_profile", clip["language"])
        row["domain"] = clip.get("domain", "unspecified")
        try:
            path, meta = prepared_clip(root, clip)
            rois = np.load(path, allow_pickle=False)
            if rois.dtype != np.uint8 or rois.ndim != 3 or rois.shape[1:] != (96, 96) or not 0 < len(rois) <= 850:
                raise ValueError("Invalid mouth crops")
            start = time.perf_counter()
            hypothesis = reader.beam_search(reader.encode(rois))
            if reader.enc_device.type == "mps":
                torch.mps.synchronize()
            row.update(status="ok", hypothesis=hypothesis, inference_seconds=time.perf_counter() - start,
                       preparation_seconds=meta["preparation_seconds"], video_seconds=len(rois) / 25,
                       rois_sha256=meta["rois_sha256"], source_sha256=meta["signature"]["source_sha256"], quality=meta["quality"])
        except (ValueError, OSError, RuntimeError, KeyError) as error:
            row.update(status="failed", hypothesis="", error=str(error))
        row["accuracy"] = error_rate(clip["reference_text"], row["hypothesis"])
        row["exact_match"] = row["status"] == "ok" and tokens(clip["reference_text"], "word") == tokens(row["hypothesis"], "word")
        rows.append(row)
        print(f"{row['status']} {clip['id']}: {row['hypothesis']}", flush=True)
    result = {"scope": "Offline prompted pilot; English checkpoint; no audio or LLM cleanup",
              "dataset_purpose": plan.get("purpose"),
              "failure_policy": "All selected verified clips counted. Pipeline failure = empty hypothesis (all reference words deleted).",
              "normalization": "Case-insensitive word tokens; punctuation removed. Numbers are not converted; no name/number-specific score.",
              "latency_scope": "Warm model inference only; preparation reported separately; excludes user correction, capture and insertion.",
              "checkpoint": provenance, "split_audit": audit, "split": args.split, "clips": rows, "summary": summarize(rows),
              "planned_english_takes": sum(t["split"] == args.split and t["language"] == "en" for t in plan["takes"]),
              "verified_english_takes": len(selected),
              "unsupported_mandarin_recordings": sum(c["split"] == args.split and c["language"] == "zh" for c in all_clips)}
    result["coverage_by_language_profile"] = {
        lang: {"planned": sum(t["split"] == args.split and t.get("language_profile", t["language"]) == lang for t in plan["takes"]),
               "recorded": sum(c["split"] == args.split and c.get("language_profile", c["language"]) == lang for c in all_clips),
               "checkpoint_supported": lang == "en"}
        for lang in ("zh", "zh_en_mixed", "en")}
    result["overall_target_population_quality_established"] = False
    write_json(args.output, result)
    print(json.dumps(result["summary"], indent=2))


def main():
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest="command", required=True)
    prep = sub.add_parser("prepare")
    prep.add_argument("root", type=Path)
    prep.add_argument("--probe", required=True, type=Path)
    prep.add_argument("--mean-face", required=True, type=Path)
    prep.add_argument("--crop-python", default="python3")
    ev = sub.add_parser("evaluate")
    ev.add_argument("root", type=Path)
    ev.add_argument("--checkout", required=True, type=Path)
    ev.add_argument("--split", choices=["train", "validation", "test"], default="test")
    ev.add_argument("--device", choices=["auto", "mps", "cpu"], default="auto")
    ev.add_argument("--language", choices=["en"], help="Explicit English-only baseline; required for the Chinese-first profile")
    ev.add_argument("--adapter", type=Path)
    ev.add_argument("--output", required=True, type=Path)
    args = p.parse_args()
    (prepare if args.command == "prepare" else evaluate)(args)


if __name__ == "__main__":
    main()
