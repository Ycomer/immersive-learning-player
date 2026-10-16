#!/bin/sh
set -eu
resources="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
mkdir -p "$resources/Tools" "$resources/Models"
cp "$SRCROOT/scripts/local-qwen-asr.py" "$resources/Tools/local-qwen-asr.py"
/usr/bin/python3 - "$SRCROOT" "$resources/LocalASR.json" <<'PY'
import json,sys
from pathlib import Path
root = Path(sys.argv[1])
Path(sys.argv[2]).write_text(json.dumps({
    'python': str(root/'tools/mlx-asr-venv/bin/python'),
    'asr': str(root/'tools/asr-candidates/qwen3-asr-1.7b-8bit'),
    'aligner': str(root/'tools/asr-candidates/qwen3-forced-aligner-0.6b-8bit'),
}))
PY
if [ -x "$SRCROOT/tools/whisper.cpp/static-build/bin/whisper-vad-speech-segments" ]; then
    cp "$SRCROOT/tools/whisper.cpp/static-build/bin/whisper-vad-speech-segments" "$resources/Tools/whisper-vad-speech-segments"
    codesign --force --sign - "$resources/Tools/whisper-vad-speech-segments"
fi
if [ -f "$SRCROOT/tools/whisper.cpp/models/ggml-large-v3.bin" ]; then
    cp "$SRCROOT/tools/whisper.cpp/models/ggml-large-v3.bin" "$resources/Models/ggml-large-v3.bin"
fi
if [ -f "$SRCROOT/tools/whisper.cpp/models/ggml-silero-v6.2.0.bin" ]; then
    cp "$SRCROOT/tools/whisper.cpp/models/ggml-silero-v6.2.0.bin" "$resources/Models/ggml-silero-v6.2.0.bin"
    cp "$SRCROOT/tools/whisper.cpp/models/Silero-VAD-LICENSE.txt" "$resources/Models/Silero-VAD-LICENSE.txt"
fi
if [ -x "$SRCROOT/tools/whisper.cpp/static-build/bin/whisper-cli" ]; then
    cp "$SRCROOT/tools/whisper.cpp/static-build/bin/whisper-cli" "$resources/Tools/whisper-cli"
    codesign --force --sign - "$resources/Tools/whisper-cli"
    cp "$SRCROOT/tools/whisper.cpp/LICENSE" "$resources/Tools/Whisper-LICENSE.txt"
fi
if [ -f "$SRCROOT/tools/whisper.cpp/models/ggml-tiny.bin" ]; then
    cp "$SRCROOT/tools/whisper.cpp/models/ggml-tiny.bin" "$resources/Models/ggml-tiny.bin"
fi

if [ -f "$SRCROOT/tools/whisper.cpp/models/ggml-small.bin" ]; then
    cp "$SRCROOT/tools/whisper.cpp/models/ggml-small.bin" "$resources/Models/ggml-small.bin"
fi
