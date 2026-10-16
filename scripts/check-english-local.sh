#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_dir"
mkdir -p build
if [ ! -f tools/english-evaluation/manifest.json ]; then
    python3 scripts/make-english-quality-fixtures.py
fi
swiftc -module-cache-path build/ModuleCache -parse-as-library SubtitleStudy/Subtitle.swift SubtitleStudy/LocalServices.swift SubtitleStudy/StudyModel.swift Tests/EnglishLocalQualityChecks.swift -o build/english-local-quality-checks
build/english-local-quality-checks
python3 Tests/EnglishMetricChecks.py
python3 scripts/score-english-quality.py --strict
