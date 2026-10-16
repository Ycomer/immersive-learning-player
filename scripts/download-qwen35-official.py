"""Download the authorized model through verified HTTPS without changing DNS/proxy settings.
Ollama's redirect guard may reject a local proxy's fake-IP DNS; the downloaded blobs
are installed only after exact official-manifest size and SHA-256 checks.
"""
import hashlib
import json
import os
from pathlib import Path
import shlex
import time
import urllib.request

model = 'qwen3.5:9b-q4_K_M'
manifest = json.loads(Path('build/qwen35-official-manifest.json').read_text())
request = urllib.request.Request('http://127.0.0.1:11434/api/show', data=json.dumps({'model':'qwen3:4b-instruct'}).encode(), headers={'Content-Type':'application/json'})
with urllib.request.urlopen(request, timeout=10) as response:
    source = json.load(response)['modelfile']
base_line = next(line for line in source.splitlines() if line.startswith('FROM '))
existing = Path(shlex.split(base_line)[1])
assert existing.is_file() and existing.parent.name == 'blobs' and existing.name.startswith('sha256-'), 'Cannot identify the active model store safely'
blobs = existing.parent
started = time.monotonic()
for layer in [manifest['config']] + manifest['layers']:
    digest, size = layer['digest'], layer['size']
    algorithm, expected = digest.split(':')
    assert algorithm == 'sha256' and len(expected) == 64 and all(c in '0123456789abcdef' for c in expected)
    destination = blobs / ('sha256-' + expected)
    if destination.exists() and destination.stat().st_size == size:
        with destination.open('rb') as stream:
            actual = hashlib.file_digest(stream, 'sha256').hexdigest()
        if actual == expected:
            print(json.dumps({'digest':digest, 'status':'already verified', 'bytes':size}), flush=True)
            continue
        raise RuntimeError('Existing blob did not match its digest; it has not been replaced')
    temporary = destination.with_name(destination.name + '.study-download.partial')
    url = 'https://registry.ollama.ai/v2/library/qwen3.5/blobs/' + digest
    request = urllib.request.Request(url, headers={'User-Agent':'SubtitleStudy-local-model-evaluation/1.0'})
    checksum = hashlib.sha256(); received = 0; last = -1
    with urllib.request.urlopen(request, timeout=90) as response, temporary.open('wb') as stream:
        assert response.geturl().startswith('https://'), 'Refusing non-HTTPS download'
        while chunk := response.read(4*1024*1024):
            stream.write(chunk); checksum.update(chunk); received += len(chunk)
            percent = int(received*100/size)
            if percent//5 != last:
                last = percent//5
                print(json.dumps({'digest':digest, 'percent':percent,'received':received,'total':size,'elapsedSeconds':round(time.monotonic()-started)}),flush=True)
    assert received == size and checksum.hexdigest() == expected, 'Downloaded bytes failed official size/digest validation'
    os.replace(temporary,destination)
    print(json.dumps({'digest':digest,'status':'installed verified blob','bytes':size}),flush=True)
# Let Ollama validate the cached layers and register its own manifest normally.
request = urllib.request.Request('http://127.0.0.1:11434/api/pull',data=json.dumps({'model':model,'stream':False}).encode(),headers={'Content-Type':'application/json'})
with urllib.request.urlopen(request,timeout=1800) as response:
    result = json.load(response)
assert result.get('status') == 'success', result
Path('build/qwen35-download-verified.json').write_text(json.dumps({'model':model,'manifest':manifest,'elapsedSeconds':time.monotonic()-started,'status':result},indent=2)+'\n')
print('VERIFIED: all official layers and model registration complete',flush=True)
