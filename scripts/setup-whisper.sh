#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_dir"
mkdir -p tools
python3 -m pip install --target tools/python cmake==4.4.4
if [ ! -d tools/whisper.cpp/.git ]; then
    git init tools/whisper.cpp
    git -C tools/whisper.cpp remote add origin https://github.com/ggml-org/whisper.cpp.git
    git -C tools/whisper.cpp fetch --depth 1 origin 0c7be696371069e0baa2515ed7aa08d5a5473aa6
    git -C tools/whisper.cpp checkout --detach FETCH_HEAD
fi
if [ ! -f tools/whisper.cpp/models/Silero-VAD-LICENSE.txt ]; then
    curl -L --fail --retry 2 https://raw.githubusercontent.com/snakers4/silero-vad/master/LICENSE -o tools/whisper.cpp/models/Silero-VAD-LICENSE.txt
fi
cmake_bin="$project_dir/tools/python/cmake/data/bin/cmake"
python3 scripts/patch-whisper-json.py
"$cmake_bin" -S tools/whisper.cpp -B tools/whisper.cpp/static-build -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DWHISPER_BUILD_TESTS=OFF -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0
"$cmake_bin" --build tools/whisper.cpp/static-build --config Release -j 4
if [ ! -f tools/whisper.cpp/models/ggml-tiny.bin ]; then
    curl -L --fail --retry 2 https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.bin -o tools/whisper.cpp/models/ggml-tiny.bin
fi
if [ ! -f tools/whisper.cpp/models/ggml-silero-v6.2.0.bin ]; then
    curl -L --fail --retry 2 https://huggingface.co/ggml-org/whisper-vad/resolve/9ffd54a1e1ee413ddf265af9913beaf518d1639b/ggml-silero-v6.2.0.bin -o tools/whisper.cpp/models/ggml-silero-v6.2.0.bin.download
    vad_hash=$(shasum -a 256 tools/whisper.cpp/models/ggml-silero-v6.2.0.bin.download | cut -d ' ' -f 1)
    if [ "$vad_hash" != "2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987" ]; then
        echo "Silero VAD checksum mismatch" >&2
        exit 1
    fi
    mv tools/whisper.cpp/models/ggml-silero-v6.2.0.bin.download tools/whisper.cpp/models/ggml-silero-v6.2.0.bin
fi
if [ ! -f tools/whisper.cpp/models/ggml-small.bin ]; then
    curl -L --fail --retry 3 https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin -o tools/whisper.cpp/models/ggml-small.bin.download
    small_hash=$(shasum -a 256 tools/whisper.cpp/models/ggml-small.bin.download | cut -d ' ' -f 1)
    if [ "$small_hash" != "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b" ]; then
        echo "Whisper Small checksum mismatch" >&2
        exit 1
    fi
    mv tools/whisper.cpp/models/ggml-small.bin.download tools/whisper.cpp/models/ggml-small.bin
fi
