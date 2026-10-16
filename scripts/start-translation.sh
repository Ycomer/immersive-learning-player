#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
export OLLAMA_MODELS="$project_dir/tools/ollama/models"
export OLLAMA_HOST=127.0.0.1:11434
exec /usr/local/bin/ollama serve
