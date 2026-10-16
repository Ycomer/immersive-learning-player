#!/bin/sh
# Existing downloaded real clips and local models only. No setup/download step.
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_dir"
mkdir -p build
test -f tools/real-video-evaluation/manifest.json
test -f tools/asr-candidates/qwen3-asr-1.7b-8bit/model.safetensors
test -f tools/asr-candidates/qwen3-forced-aligner-0.6b-8bit/model.safetensors
python3 Tests/RealVideoMetricChecks.py
tools/mlx-asr-venv/bin/python Tests/QwenAlignmentTextChecks.py
tools/mlx-asr-venv/bin/python Tests/AcousticAnchorChecks.py
sh scripts/check-asr-corpus.sh tools/real-video-evaluation/manifest.json tools/asr-candidates/qwen3-asr-1.7b-8bit tools/real-video-evaluation/asr-results.json
python3 scripts/score-real-video.py
swiftc -module-cache-path build/ModuleCache -parse-as-library SubtitleStudy/Subtitle.swift SubtitleStudy/LocalServices.swift Tests/RealVideoTranslationChecks.swift -o build/real-video-translation-checks
build/real-video-translation-checks tools/real-video-evaluation/asr-results.json tools/real-video-evaluation/translation-targets.json tools/real-video-evaluation/translation-results.json
python3 scripts/export-real-video-review.py

if [ -f tools/real-video-evaluation/baseline-v8/quality-summary.json ]; then
    python3 scripts/compare-real-video-regression.py
fi
