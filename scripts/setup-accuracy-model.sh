#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_dir"
# Keep a pinned file-size ceiling to reject unexpected download contents.
expected_bytes=3095033483
maximum_bytes=$expected_bytes
expected_sha=64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2
model_path=tools/whisper.cpp/models/ggml-large-v3.bin
mkdir -p tools/whisper.cpp/models
if [ ! -f "$model_path" ]; then
    curl --fail --location --retry 2 --continue-at - --max-filesize "$maximum_bytes" 'https://huggingface.co/ggerganov/whisper.cpp/resolve/362722b3fdcd2300b58a8286933ead1c48619667/ggml-large-v3.bin' -o "$model_path.download"
    model_path="$model_path.download"
fi
actual_bytes=$(wc -c < "$model_path" | tr -d ' ')
actual_sha=$(shasum -a 256 "$model_path" | cut -d ' ' -f 1)
if [ "$actual_bytes" -ne "$expected_bytes" ] || [ "$actual_sha" != "$expected_sha" ]; then
    echo "Large v3 size/checksum verification failed; model not activated." >&2
    exit 1
fi
if [ "$model_path" = "tools/whisper.cpp/models/ggml-large-v3.bin.download" ]; then
    mv "$model_path" tools/whisper.cpp/models/ggml-large-v3.bin
fi
echo "PASS: Large v3 size and SHA-256 verified (3.095 GB)"
