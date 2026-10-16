#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_dir"
if [ "$(uname -s)" != Darwin ] || [ "$(uname -m)" != arm64 ]; then
    echo 'The MLX recognition stack requires an Apple Silicon Mac.' >&2
    exit 1
fi
python_bin=${PYTHON:-python3}
"$python_bin" -c 'import sys; assert sys.version_info >= (3, 12), "Python 3.12+ required (tested on 3.14)"'
if [ ! -x tools/mlx-asr-venv/bin/python ]; then
    "$python_bin" -m venv tools/mlx-asr-venv
fi
tools/mlx-asr-venv/bin/python -m pip install -r requirements-local-asr.txt
HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 tools/mlx-asr-venv/bin/python - <<'PY'
from mlx_audio.stt.models.qwen3_asr.qwen3_forced_aligner import ForceAlignProcessor
processor = ForceAlignProcessor()
assert processor.tokenize_japanese('日本語を勉強しています。'), 'Japanese tokenizer failed'
assert processor.tokenize_korean('한국어 공부'), 'Korean tokenizer failed'
print('PASS: forced-aligner language tokenizers available; no ASR weights loaded')
PY
echo 'Runtime ready. Model weights are separate: see docs/SETUP.md.'
