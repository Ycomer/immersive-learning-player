#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_dir"
if [ "$(uname -s)" != Darwin ] || [ "$(uname -m)" != arm64 ]; then
    echo 'The MLX recognition stack requires an Apple Silicon Mac.' >&2
    exit 1
fi
python_bin=${PYTHON:-python3}
"$python_bin" -c 'import sys; assert sys.version_info >= (3, 10), "Python 3.10+ required (tested on 3.14)"'
if [ ! -x tools/mlx-asr-venv/bin/python ]; then
    "$python_bin" -m venv tools/mlx-asr-venv
fi
tools/mlx-asr-venv/bin/python -m pip install -r requirements-local-asr.txt
echo 'Runtime ready. Model weights are separate: see docs/SETUP.md.'
