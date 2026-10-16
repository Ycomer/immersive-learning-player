#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_dir"
# Exact, pinned registry layers. No application setting is changed here.
blob_dir=tools/ollama/models/blobs
mkdir -p "$blob_dir" tools/translation-candidates/translategemma-12b
while read -r digest expected_bytes; do
    blob_path="$blob_dir/sha256-$digest"
    if [ ! -f "$blob_path" ]; then
        partial="$blob_path.download"
        partial_bytes=0
        if [ -f "$partial" ]; then partial_bytes=$(wc -c < "$partial" | tr -d ' '); fi
        if [ "$partial_bytes" -lt "$expected_bytes" ]; then
            curl --fail --location --retry 2 --continue-at - --max-filesize "$expected_bytes" "https://registry.ollama.ai/v2/library/translategemma/blobs/sha256:$digest" -o "$partial"
        fi
        blob_path="$partial"
    fi
    actual_bytes=$(wc -c < "$blob_path" | tr -d ' ')
    actual_sha=$(shasum -a 256 "$blob_path" | cut -d ' ' -f 1)
    if [ "$actual_bytes" -ne "$expected_bytes" ] || [ "$actual_sha" != "$digest" ]; then
        echo 'Official model layer size/SHA-256 failed; not activated.' >&2
        exit 1
    fi
    if [ "$blob_path" = "$blob_dir/sha256-$digest.download" ]; then mv "$blob_path" "$blob_dir/sha256-$digest"; fi
done <<'LAYERS'
1b2b95e2f0eb9a98a839249ed41dfca71b300f9c389e14581210649fada910ed 8109818272
e0a42594d802e5d31cdc786deb4823edb8adff66094d49de8fffe976d753e348 358
3e2c24001f9ef57bf7ec959a3658fbb49cdad113cdf394c264da9d16f9bdd132 8431
339e884a40f6708bc761d367f0c08e448d5bb6f16b3961c340e44e0e4835a004 61
e77c8f2cf3d1d99e8c436bf03949400e0b1b4eefcec5515e299f785dca234f1a 490
LAYERS
python3 - <<'PY'
from pathlib import Path
import json
root=Path.cwd()
blobs=root/'tools/ollama/models/blobs'
folder=root/'tools/translation-candidates/translategemma-12b'
model=blobs/'sha256-1b2b95e2f0eb9a98a839249ed41dfca71b300f9c389e14581210649fada910ed'
template=(blobs/'sha256-e0a42594d802e5d31cdc786deb4823edb8adff66094d49de8fffe976d753e348').read_text()
license_text=(blobs/'sha256-3e2c24001f9ef57bf7ec959a3658fbb49cdad113cdf394c264da9d16f9bdd132').read_text()
(folder/'license').write_text(license_text)
(folder/'Modelfile').write_text(f'FROM {model}\nTEMPLATE """{template}"""\nLICENSE """{license_text}"""\nPARAMETER stop <end_of_turn>\nPARAMETER top_k 64\nPARAMETER top_p 0.95\n')
layers=[('model','1b2b95e2f0eb9a98a839249ed41dfca71b300f9c389e14581210649fada910ed',8109818272),('template','e0a42594d802e5d31cdc786deb4823edb8adff66094d49de8fffe976d753e348',358),('license','3e2c24001f9ef57bf7ec959a3658fbb49cdad113cdf394c264da9d16f9bdd132',8431),('params','339e884a40f6708bc761d367f0c08e448d5bb6f16b3961c340e44e0e4835a004',61)]
manifest={'schemaVersion':2,'mediaType':'application/vnd.docker.distribution.manifest.v2+json','config':{'mediaType':'application/vnd.docker.container.image.v1+json','digest':'sha256:e77c8f2cf3d1d99e8c436bf03949400e0b1b4eefcec5515e299f785dca234f1a','size':490},'layers':[{'mediaType':'application/vnd.ollama.image.'+kind,'digest':'sha256:'+sha,'size':size} for kind,sha,size in layers]}
target=root/'tools/ollama/models/manifests/registry.ollama.ai/library/translategemma/12b'
target.parent.mkdir(parents=True,exist_ok=True)
target.write_text(json.dumps(manifest,separators=(',',':')))
PY
echo 'PASS: Google TranslateGemma 12B official layers verified (8.110 GB); app settings unchanged.'
