#!/usr/bin/env python3
"""Compare matched stock/adapted English pilot reports, preserving failed clips."""
import argparse
from dataset import read_json, write_json


def compare(stock, adapted):
    if stock["split"] != "test" or adapted["split"] != "test":
        raise ValueError("Use held-out test reports for the comparison")
    for key in ("base_model_sha256", "lm_sha256", "beam", "language_model"):
        if stock["checkpoint"][key] != adapted["checkpoint"][key]:
            raise ValueError("Model/decoder settings differ beyond personalization")
    if "adapter" in stock["checkpoint"] or "adapter" not in adapted["checkpoint"]:
        raise ValueError("Pass a stock report first, adapted report second")
    a, b = ({x["id"]: x for x in report["clips"]} for report in (stock, adapted))
    if a.keys() != b.keys():
        raise ValueError("Reports must contain exactly the same clip IDs")
    for key in a:
        for field in ("reference_text", "mode", "language", "speaker_id", "source_sha256", "rois_sha256"):
            if a[key].get(field) != b[key].get(field):
                raise ValueError(f"Mismatched comparison input: {key} {field}")
    groups = {(x["language"], x["mode"]): x for x in stock["summary"]}
    deltas = []
    for new in adapted["summary"]:
        old = groups[(new["language"], new["mode"])]
        deltas.append({"language": new["language"], "mode": new["mode"], "clips": new["clips"],
                       "stock_wer": old["word_error_rate"], "adapted_wer": new["word_error_rate"],
                       "wer_change_percentage_points": 100 * (new["word_error_rate"] - old["word_error_rate"]),
                       "stock_failures": old["failures"], "adapted_failures": new["failures"],
                       "stock_exact_match": old["exact_match_rate"], "adapted_exact_match": new["exact_match_rate"]})
    return {"scope": "Matched descriptive comparison; small pilot, no statistical significance claim",
            "direction": "Negative WER change is better", "comparison": deltas,
            "planned_english_test_takes": stock["planned_english_takes"],
            "evaluated_english_test_takes": stock["verified_english_takes"]}


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("stock"); p.add_argument("adapted"); p.add_argument("--output", required=True)
    args = p.parse_args()
    from pathlib import Path
    if Path(args.output).exists():
        p.error("Output already exists")
    result = compare(read_json(args.stock), read_json(args.adapted))
    write_json(args.output, result)
    import json
    print(json.dumps(result, indent=2))
