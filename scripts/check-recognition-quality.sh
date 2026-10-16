#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_dir"
mkdir -p build
swiftc -module-cache-path build/ModuleCache -parse-as-library SubtitleStudy/Subtitle.swift SubtitleStudy/LocalServices.swift Tests/QualityAudioChecks.swift -o build/quality-audio-checks
build/quality-audio-checks "$@"
