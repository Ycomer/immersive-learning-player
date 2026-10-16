import importlib.util
from pathlib import Path

path = Path(__file__).resolve().parents[1] / "scripts/score-asr.py"
spec = importlib.util.spec_from_file_location("asr_metric", path)
metric = importlib.util.module_from_spec(spec)
spec.loader.exec_module(metric)
assert metric.distance("abc", "abc") == 0
assert metric.distance("abc", "ab") == 1
assert metric.distance("abc", "abcd") == 1
assert metric.distance("abc", "adc") == 1
assert metric.distance("", "fake") == 4
assert metric.normalize("Ｈｅｌｌｏ， 世界！") == "hello世界"
report = {"model": "fixture", "referenceSource": "synthetic", "cases": [
    {"id": "speech", "reference": "a" * 100, "hypothesis": "a" * 98, "audioSeconds": 10, "processingSeconds": 5},
    {"id": "silence", "reference": "", "hypothesis": "fake", "cueCount": 1}]}
result = metric.score(report)
assert result["cer"] == 0.02 and result["nonSpeechFalseCues"] == 1
assert not result["sampleCERAtMost2Percent"] and not result["realVideo98PercentVerified"]
assert result["realTimeFactor"] == 0.5
report["cases"][1]["hypothesis"] = ""; report["cases"][1]["cueCount"] = 0
result = metric.score(report)
assert result["sampleCERAtMost2Percent"] and not result["realVideo98PercentVerified"]
assert "human" in result["translationMeaningAccuracy"]
print("PASS: CER substitutions/deletions/insertions, Unicode, silence hallucinations, weighted corpus and no false 98% claim")
