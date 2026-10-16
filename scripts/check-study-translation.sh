#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_dir"
mkdir -p build
swiftc -module-cache-path build/ModuleCache -parse-as-library SubtitleStudy/Subtitle.swift SubtitleStudy/LocalServices.swift Tests/StudyTranslationChecks.swift -o build/study-translation-checks
build/study-translation-checks
swiftc -module-cache-path build/ModuleCache -parse-as-library SubtitleStudy/Subtitle.swift SubtitleStudy/LocalServices.swift SubtitleStudy/StudyModel.swift Tests/StudyPipelineChecks.swift -o build/study-pipeline-checks
build/study-pipeline-checks
