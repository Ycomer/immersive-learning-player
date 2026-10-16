"""Score local ASR output against reference text; never infer translation accuracy.

Usage: python3 scripts/score-asr.py build/quality-audio-ggml-small.json ...
Input: {model, referenceSource: human|synthetic, cases: [{id, reference,
hypothesis, processingSeconds, audioSeconds, cueCount}]}.
This reports the measured corpus only. Synthetic pass is not real-video acceptance.
"""
import argparse
import json
import unicodedata
from pathlib import Path


def normalize(text):
    return "".join(c for c in unicodedata.normalize("NFKC", text).lower()
                   if not c.isspace() and unicodedata.category(c)[0] not in "PZ")


def distance(reference, hypothesis):
    # Two rows bound memory; preserve insertions, including hallucinated repetitions.
    previous = list(range(len(hypothesis) + 1))
    for row, expected in enumerate(reference, 1):
        current = [row]
        for col, actual in enumerate(hypothesis, 1):
            current.append(min(previous[col] + 1, current[-1] + 1,
                               previous[col - 1] + (expected != actual)))
        previous = current
    return previous[-1]


def score(report):
    total_characters = errors = false_cues = 0
    records = []
    elapsed = duration = 0.0
    for case in report["cases"]:
        reference, hypothesis = normalize(case["reference"]), normalize(case["hypothesis"])
        if max(len(reference), len(hypothesis)) > 10000:
            raise ValueError("Split references longer than 10000 characters into clips")
        count = distance(reference, hypothesis)
        if reference:
            total_characters += len(reference)
            errors += count
        else:
            false_cues += case.get("cueCount", int(bool(hypothesis)))
        elapsed += case.get("processingSeconds", 0)
        duration += case.get("audioSeconds", 0)
        records.append({"id": case["id"], "referenceCharacters": len(reference),
                        "editErrors": count, "cer": count / len(reference) if reference else None,
                        "nonSpeechFalseCues": 0 if reference else case.get("cueCount", int(bool(hypothesis)))})
    cer = errors / total_characters if total_characters else None
    source = report.get("referenceSource", "unknown")
    return {"model": report.get("model"), "referenceSource": source,
            "scope": "this corpus only; Japanese character transcription, not semantic translation",
            "referenceCharacters": total_characters, "editErrors": errors, "cer": cer,
            "nonSpeechFalseCues": false_cues, "processingSeconds": elapsed,
            "realTimeFactor": elapsed / duration if duration else None,
            "sampleCERAtMost2Percent": cer is not None and cer <= 0.02 and false_cues == 0,
            "realVideo98PercentVerified": False,
            "translationMeaningAccuracy": "requires independent human sentence review",
            "timingAccuracy": "requires independently aligned reference timestamps",
            "cases": records}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("reports", nargs="+", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    results = [score(json.loads(path.read_text())) for path in args.reports]
    data = json.dumps(results, ensure_ascii=False, indent=2)
    if args.output:
        args.output.write_text(data + "\n")
    for result in results:
        value = result["cer"]
        label = "unavailable" if value is None else f"{value:.2%}"
        factor = result["realTimeFactor"]
        rtf = "unavailable" if factor is None else f"{factor:.3f}"
        print(f'{Path(result["model"] or "unknown").name}: CER={label}, errors={result["editErrors"]}/{result["referenceCharacters"]}, non-speech false cues={result["nonSpeechFalseCues"]}, RTF={rtf}')
        print(f'  Reference: {result["referenceSource"]}; real-video 98% is unverified; translation and timing are separate.')
    if not args.output:
        print(data)


if __name__ == "__main__":
    main()
