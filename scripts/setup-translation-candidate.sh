#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_dir"
# Evaluation only: preparing this candidate does not change the app's model.
expected_bytes=1908528288
maximum_bytes=$expected_bytes
expected_sha=6789b06d0902f2f5312c0e1703d56ccbddfcfb6c653d22519b7c720f7db9a98e
revision=265b2e615a7dc9b06c435dc878829ad99a512ba2
candidate_dir=tools/translation-candidates/hy-mt1.5-1.8b
model_path="$candidate_dir/HY-MT1.5-1.8B-Q8_0.gguf"
mkdir -p "$candidate_dir"
if [ ! -f "$model_path" ]; then
    curl --fail --location --retry 2 --continue-at - --max-filesize "$maximum_bytes" "https://huggingface.co/tencent/HY-MT1.5-1.8B-GGUF/resolve/$revision/HY-MT1.5-1.8B-Q8_0.gguf" -o "$model_path.download"
    model_path="$model_path.download"
fi
actual_bytes=$(wc -c < "$model_path" | tr -d ' ')
actual_sha=$(shasum -a 256 "$model_path" | cut -d ' ' -f 1)
if [ "$actual_bytes" -ne "$expected_bytes" ] || [ "$actual_sha" != "$expected_sha" ]; then
    echo 'Candidate checksum/size failed; not imported or activated.' >&2
    exit 1
fi
if [ "$model_path" = "$candidate_dir/HY-MT1.5-1.8B-Q8_0.gguf.download" ]; then
    mv "$model_path" "$candidate_dir/HY-MT1.5-1.8B-Q8_0.gguf"
fi
curl --fail --location --max-filesize 1000000 "https://huggingface.co/tencent/HY-MT1.5-1.8B-GGUF/resolve/$revision/License.txt" -o "$candidate_dir/License.txt"
cat > "$candidate_dir/Modelfile" <<'EOF'
FROM ./HY-MT1.5-1.8B-Q8_0.gguf
TEMPLATE """<｜hy_begin▁of▁sentence｜>{{ if .System }}{{ .System }}<｜hy_place▁holder▁no▁3｜>{{ end }}{{ if .Prompt }}<｜hy_User｜>{{ .Prompt }}{{ end }}<｜hy_Assistant｜>"""
PARAMETER stop <｜hy_place▁holder▁no▁2｜>
PARAMETER temperature 0.7
PARAMETER top_k 20
PARAMETER top_p 0.6
PARAMETER repeat_penalty 1.05
EOF
echo 'PASS: evaluation candidate verified, 1.909 GB; app model unchanged.'
