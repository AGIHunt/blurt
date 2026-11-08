#!/usr/bin/env python3
"""Create and validate a local, prompted visual-speech pilot dataset (stdlib only)."""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import re
from prompt_profiles import tech_takes

MODES = ["silent", "exaggerated_silent", "whisper", "voiced"]
SPLITS = ["train", "validation", "test"]
# Separate semantic families, including their translations, belong to one split.
# This starter set tests plumbing, not statistical power or a full enrollment corpus.
PROMPTS = {
    "train": [
        ("meeting", "Please move our meeting to Monday morning.", "请把我们的会议改到星期一上午。"),
        ("window", "Open the window and let some fresh air in.", "打开窗户，让新鲜空气进来。"),
        ("coffee", "I would like a small coffee with milk.", "我想要一小杯加牛奶的咖啡。"),
        ("draft", "Save this draft before closing the application.", "关闭应用程序之前，请保存这份草稿。"),
        ("lunch", "We can have lunch after the presentation.", "我们可以在演示结束以后吃午饭。"),
        ("train", "The next train leaves in twenty minutes.", "下一班火车将在二十分钟后出发。"),
    ],
    "validation": [
        ("parcel", "Your parcel will arrive tomorrow afternoon.", "你的包裹将在明天下午送到。"),
        ("garden", "The flowers in the garden need more water.", "花园里的花需要多浇一些水。"),
        ("lights", "Turn off the lights when you leave the room.", "离开房间时，请把灯关掉。"),
    ],
    "test": [
        ("deadline", "The final deadline is Friday at half past three.", "最后的截止时间是星期五三点半。"),
        ("names", "Send the report to Alice and Michael.", "请把报告发给小王和小李。"),
        ("airport", "How long does it take to get to the airport?", "到机场需要多长时间？"),
        ("password", "Change the password in your account settings.", "请在账户设置中修改密码。"),
        ("delivery", "We ordered seven books and twelve blue pens.", "我们订购了七本书和十二支蓝色的笔。"),
        ("bug", "The search button stops working after the update.", "更新以后，搜索按钮就不能用了。"),
    ],
}


def read_json(path):
    return json.loads(Path(path).read_text())


def write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")
    tmp.replace(path)


def sha256(path):
    with Path(path).open("rb") as f:
        return hashlib.file_digest(f, "sha256").hexdigest()


def local_path(root, relative):
    path = (root / relative).resolve()
    if not path.is_relative_to(root.resolve()):
        raise ValueError("Dataset path escapes its root")
    return path


def validate_plan(plan):
    sessions, families, ids = {}, {}, set()
    for take in plan["takes"]:
        if take["id"] in ids:
            raise ValueError("Duplicate take ID")
        ids.add(take["id"])
        if take["split"] not in SPLITS or take["mode"] not in MODES:
            raise ValueError("Unknown split or mode")
        if take["language"] not in ("en", "zh"):
            raise ValueError("Unknown dominant language")
        for mapping, key in ((sessions, take["session_id"]), (families, take["phrase_family"])):
            if key in mapping and mapping[key] != take["split"]:
                raise ValueError("Session or phrase family crosses splits")
            mapping[key] = take["split"]
    return plan


def load_clips(root):
    root = Path(root).resolve()
    plan = validate_plan(read_json(root / "plan.json"))
    planned = {t["id"]: t for t in plan["takes"]}
    clips = []
    reference_splits = {}
    for file in sorted((root / "clips").glob("*.json")):
        clip = read_json(file)
        take = planned.get(clip["id"])
        if take is None or file.stem != clip["id"]:
            raise ValueError(f"Unplanned clip: {file}")
        for field in ("id", "speaker_id", "session_id", "split", "phrase_family", "language", "mode", "prompt"):
            if clip[field] != take[field]:
                raise ValueError(f"Manifest differs from plan: {file}: {field}")
        for field in ("language_profile", "domain", "target_terms"):
            if field in take and clip.get(field) != take[field]:
                raise ValueError(f"Profile metadata differs from plan: {file}: {field}")
        if clip.get("reference_verified") is not True or not clip.get("reference_text", "").strip():
            raise ValueError(f"Unverified reference: {file}")
        normalized = "".join(c for c in clip["reference_text"].casefold() if c.isalnum())
        if not normalized:
            raise ValueError(f"Reference contains no words/characters: {file}")
        if normalized in reference_splits and reference_splits[normalized] != clip["split"]:
            raise ValueError("Identical reference text crosses splits")
        reference_splits[normalized] = clip["split"]
        if clip.get("consent_scope") != "local_research":
            raise ValueError(f"Unexpected consent scope: {file}")
        if clip["mode"] in ("silent", "exaggerated_silent") and clip.get("audio_recorded") is not False:
            raise ValueError(f"Silent take has audio enabled: {file}")
        if not 0 < clip["duration_seconds"] <= 32:
            raise ValueError(f"Take must be at most 30 seconds (plus stop delay): {file}")
        datetime.fromisoformat(clip["captured_at"].replace("Z", "+00:00"))
        if not local_path(root, clip["video"]).is_file():
            raise ValueError(f"Missing video: {file}")
        clips.append(clip)
    return plan, clips


def create(root, speaker, languages, profile="balanced_v1"):
    if not re.fullmatch(r"[a-zA-Z0-9_-]{1,40}", speaker):
        raise ValueError("Use a short pseudonymous speaker ID: letters, digits, underscore or dash")
    if profile not in ("balanced_v1", "tech_zh90_v1"):
        raise ValueError("Unknown prompt profile")
    if profile == "tech_zh90_v1" and set(languages) != {"en", "zh"}:
        raise ValueError("tech_zh90_v1 requires both Chinese and English")
    root.mkdir(parents=True, exist_ok=False)
    (root / "clips").mkdir()
    takes = []
    for split in SPLITS:
        for n, (family, english, chinese) in enumerate(PROMPTS[split]):
            # Rotate mode order to reduce a fixed order effect.
            for mode in MODES[n % 4:] + MODES[:n % 4]:
                for lang in languages:
                    takes.append(dict(id=f"{split}-{family}-{lang}-{mode}", speaker_id=speaker,
                                      session_id=f"{split}-01", split=split, phrase_family=family,
                                      language=lang, mode=mode, prompt=english if lang == "en" else chinese))
    plan = dict(schema_version=1, purpose="local research pilot; starter prompts, not a full training corpus",
                speaker_id=speaker, takes=takes)
    if profile == "tech_zh90_v1":
        plan["takes"] = tech_takes(speaker, MODES)
        plan["language_mix"] = {"unit": "planned utterances", "zh_dominant": .9, "en": .1,
                                "zh_only": .6, "zh_en_mixed": .3}
        plan["domain_mix"] = {"tech": .7, "general": .3}
    plan["profile"] = profile
    validate_plan(plan)
    write_json(root / "plan.json", plan)
    return plan


def split_audit(root, clips):
    """Reject copied media across splits and report same-day collection."""
    seen, dates = {}, {s: set() for s in SPLITS}
    for c in clips:
        digest = sha256(local_path(root, c["video"]))
        if digest in seen and seen[digest] != c["split"]:
            raise ValueError("Identical video content crosses dataset splits")
        seen[digest] = c["split"]
        dates[c["split"]].add(c["captured_at"][:10])
    overlap = dates["test"] & (dates["train"] | dates["validation"])
    return {"test_dates_overlapping_adaptation_dates_utc": sorted(overlap),
            "warning": "Collect held-out test footage on a different day" if overlap else None}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    init = sub.add_parser("init")
    init.add_argument("root", type=Path)
    init.add_argument("--speaker", default="speaker-01")
    init.add_argument("--languages", nargs="+", choices=["en", "zh"], default=["en", "zh"])
    init.add_argument("--profile", choices=["balanced_v1", "tech_zh90_v1"], default="tech_zh90_v1")
    audit = sub.add_parser("audit")
    audit.add_argument("root", type=Path)
    args = parser.parse_args()
    if args.command == "init":
        plan = create(args.root.expanduser(), args.speaker, list(dict.fromkeys(args.languages)), args.profile)
        print(f"Created {len(plan['takes'])} planned takes in {args.root}. Camera remains off.")
    else:
        plan, clips = load_clips(args.root.expanduser())
        print(json.dumps({"planned": len(plan["takes"]), "verified_recordings": len(clips),
                          "profile": plan.get("profile", "balanced_v1"),
                          "planned_language_profiles": {l: sum(t.get("language_profile", t["language"]) == l for t in plan["takes"]) for l in ("zh", "zh_en_mixed", "en")},
                          "by_split": {s: sum(c["split"] == s for c in clips) for s in SPLITS}}, indent=2))


if __name__ == "__main__":
    main()
