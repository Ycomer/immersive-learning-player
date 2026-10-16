#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_dir"
expected_bytes=1519521155
expected_sha=eff70a8a236e731abba774ba71e1f6d0fce53302137208c32207e694e0bf4546
model_path=tools/whisper.cpp/models/ggml-kotoba-whisper-v2.0.bin
mkdir -p tools/whisper.cpp/models
if [ ! -f "$model_path" ]; then
    partial="$model_path.download"
    partial_bytes=0
    if [ -f "$partial" ]; then partial_bytes=$(wc -c < "$partial" | tr -d ' '); fi
    if [ "$partial_bytes" -lt "$expected_bytes" ]; then
        curl --fail --location --retry 2 --continue-at - --max-filesize "$expected_bytes" 'https://huggingface.co/kotoba-tech/kotoba-whisper-v2.0-ggml/resolve/e3a0cf6a62b95911703cfb97d819292e058f12c3/ggml-kotoba-whisper-v2.0.bin' -o "$partial"
    fi
    model_path="$partial"
fi
actual_bytes=$(wc -c < "$model_path" | tr -d ' ')
actual_sha=$(shasum -a 256 "$model_path" | cut -d ' ' -f 1)
if [ "$actual_bytes" -ne "$expected_bytes" ] || [ "$actual_sha" != "$expected_sha" ]; then
    echo 'Kotoba size/SHA-256 verification failed; not activated.' >&2
    exit 1
fi
if [ "$model_path" = 'tools/whisper.cpp/models/ggml-kotoba-whisper-v2.0.bin.download' ]; then mv "$model_path" tools/whisper.cpp/models/ggml-kotoba-whisper-v2.0.bin; fi
echo 'PASS: Kotoba official Japanese model verified (1.520 GB); default model unchanged.'
