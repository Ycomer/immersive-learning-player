#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_dir"
mkdir -p build
sh scripts/prepare-check-media.sh
python3 Tests/ASRMetricChecks.py
python3 Tests/EnglishMetricChecks.py
if [ -x tools/mlx-asr-venv/bin/python ]; then
    tools/mlx-asr-venv/bin/python Tests/QwenAudioGateChecks.py
    tools/mlx-asr-venv/bin/python Tests/QwenAlignmentTextChecks.py
    tools/mlx-asr-venv/bin/python Tests/AcousticAnchorChecks.py
    tools/mlx-asr-venv/bin/python Tests/QuietSpeechRecoveryChecks.py
    tools/mlx-asr-venv/bin/python Tests/ASRLanguageEvidenceChecks.py
fi
swiftc -module-cache-path build/ModuleCache -parse-as-library SubtitleStudy/Subtitle.swift SubtitleStudy/LocalServices.swift Tests/CoreChecks.swift -o build/core-checks
build/core-checks
swiftc -module-cache-path build/ModuleCache -parse-as-library SubtitleStudy/Subtitle.swift Tests/EnglishExpressionChecks.swift -o build/english-expression-checks
build/english-expression-checks
swiftc -module-cache-path build/ModuleCache -parse-as-library SubtitleStudy/Subtitle.swift SubtitleStudy/LocalServices.swift SubtitleStudy/StudyModel.swift Tests/ChineseTranslationChecks.swift -o build/chinese-translation-checks
build/chinese-translation-checks
swiftc -module-cache-path build/ModuleCache -parse-as-library SubtitleStudy/Subtitle.swift Tests/CoverRegionChecks.swift -o build/cover-region-checks
build/cover-region-checks
swiftc -module-cache-path build/ModuleCache -parse-as-library SubtitleStudy/Subtitle.swift Tests/FloatingControlChecks.swift -o build/floating-control-checks
build/floating-control-checks
swiftc -module-cache-path build/ModuleCache -parse-as-library SubtitleStudy/Subtitle.swift SubtitleStudy/LocalServices.swift SubtitleStudy/StudyModel.swift Tests/PlaybackChecks.swift -o build/playback-checks
build/playback-checks
swiftc -module-cache-path build/ModuleCache -parse-as-library SubtitleStudy/Subtitle.swift SubtitleStudy/LocalServices.swift SubtitleStudy/StudyModel.swift Tests/PlaybackBufferChecks.swift -o build/playback-buffer-checks
build/playback-buffer-checks
swiftc -module-cache-path build/ModuleCache -parse-as-library SubtitleStudy/Subtitle.swift SubtitleStudy/LocalServices.swift SubtitleStudy/StudyModel.swift Tests/RecognitionQualityChecks.swift -o build/recognition-quality-checks
build/recognition-quality-checks
swiftc -module-cache-path build/ModuleCache -parse-as-library SubtitleStudy/Subtitle.swift SubtitleStudy/LocalServices.swift SubtitleStudy/StudyModel.swift Tests/ContextLearningChecks.swift -o build/context-learning-checks
build/context-learning-checks
swiftc -module-cache-path build/ModuleCache -parse-as-library SubtitleStudy/Subtitle.swift Tests/ContextReferenceChecks.swift -o build/context-reference-checks
build/context-reference-checks
swiftc -module-cache-path build/ModuleCache -parse-as-library SubtitleStudy/Subtitle.swift Tests/SubtitleWordSelectionChecks.swift -o build/subtitle-word-selection-checks
build/subtitle-word-selection-checks
swiftc -module-cache-path build/ModuleCache -parse-as-library SubtitleStudy/Subtitle.swift SubtitleStudy/LocalServices.swift SubtitleStudy/StudyModel.swift SubtitleStudy/StudyView.swift Tests/SubtitleTextLayoutChecks.swift -o build/subtitle-text-layout-checks
build/subtitle-text-layout-checks
swiftc -module-cache-path build/ModuleCache -parse-as-library SubtitleStudy/Subtitle.swift SubtitleStudy/LocalServices.swift SubtitleStudy/StudyModel.swift SubtitleStudy/StudyView.swift Tests/PlaybackControlsVisibilityChecks.swift -o build/playback-controls-visibility-checks
build/playback-controls-visibility-checks
swiftc -module-cache-path build/ModuleCache -parse-as-library SubtitleStudy/Subtitle.swift SubtitleStudy/LocalServices.swift SubtitleStudy/StudyModel.swift Tests/VideoLanguagePreferenceChecks.swift -o build/video-language-preference-checks
build/video-language-preference-checks
xcodebuild -project SubtitleStudy.xcodeproj -scheme SubtitleStudy -configuration Debug -derivedDataPath build build
