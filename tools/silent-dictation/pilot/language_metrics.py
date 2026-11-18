"""Explicit transcript scoring units for a future Mandarin/bilingual checkpoint.

This module scores supplied text; it does not add language support to a model.
No translation, number expansion, acronym expansion, or LLM correction is applied.
"""
import re
import unicodedata

HAN = r"[\u3400-\u4dbf\u4e00-\u9fff\U00020000-\U0002fa1f]"
LATIN_WORD = r"[a-z]+(?:'[a-z]+)?"
MIXED_PATTERN = re.compile(HAN + "|" + LATIN_WORD + r"|[0-9]+|[^\W_]")


def units(text, profile):
    text = unicodedata.normalize("NFKC", text).casefold()
    if profile == "zh":
        # CER: every alphanumeric character, including any unexpected Latin text.
        return [c for c in text if c.isalnum()]
    if profile == "en":
        # Keep Han characters too: unexpected Chinese output is not silently removed.
        return MIXED_PATTERN.findall(text)
    if profile == "zh_en_mixed":
        # MER: one Han character, English word, or contiguous digit string per unit.
        return MIXED_PATTERN.findall(text)
    raise ValueError("Unsupported language profile")


def score(reference, hypothesis, profile):
    a, b = units(reference, profile), units(hypothesis, profile)
    if not a:
        raise ValueError("Empty reference after normalization")
    previous = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        current = [i]
        for j, y in enumerate(b, 1):
            current.append(min(current[-1] + 1, previous[j] + 1, previous[j-1] + (x != y)))
        previous = current
    return {"metric": {"zh": "CER", "en": "WER", "zh_en_mixed": "MER"}[profile],
            "errors": previous[-1], "reference_units": len(a), "rate": previous[-1] / len(a),
            "normalized_exact_match": a == b}
