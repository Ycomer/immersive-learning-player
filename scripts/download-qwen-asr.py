"""Pinned local research model download with resumable disjoint HTTP ranges."""
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import threading
import time
import urllib.request
import argparse

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--aligner', action='store_true')
args = parser.parse_args()
repo = 'mlx-community/Qwen3-ForcedAligner-0.6B-8bit' if args.aligner else 'mlx-community/Qwen3-ASR-1.7B-8bit'
root = Path('tools/asr-candidates')/('qwen3-forced-aligner-0.6b-8bit' if args.aligner else 'qwen3-asr-1.7b-8bit')
root.mkdir(parents=True, exist_ok=True)
revision = '0e1a68e91d815300c7c9754b2a7639378b23db15' if args.aligner else 'a8379a2e2f9e313c9292cdf1af4055ab56d50d55'
if not (root/'download-manifest.json').exists():
    with urllib.request.urlopen('https://huggingface.co/api/models/'+repo+'/revision/'+revision+'?blobs=true',timeout=60) as response:
        (root/'download-manifest.json').write_text(json.dumps(json.load(response),indent=2))
manifest = json.loads((root/'download-manifest.json').read_text())
if manifest.get('sha') != revision:
    raise ValueError('Cached manifest revision differs from pinned model; remove download-manifest.json and retry')
base = f'https://huggingface.co/{repo}/resolve/{revision}/'
for item in manifest['siblings']:
    name, size = item['rfilename'], item['size']
    if name == '.gitattributes':
        continue
    target = root/name
    if target.exists() and target.stat().st_size == size:
        continue
    partial = root/(name+'.part')
    ledger = root/(name+'.ranges.json')
    if size < 10_000_000:
        with urllib.request.urlopen(base+name, timeout=90) as r:
            partial.write_bytes(r.read())
    else:
        if ledger.exists():
            state = json.loads(ledger.read_text())
        else:
            prefix = partial.stat().st_size if partial.exists() else 0
            state = {'prefix': prefix, 'done': []}
            ledger.write_text(json.dumps(state))
        fd = os.open(partial, os.O_CREAT | os.O_RDWR, 0o644)
        os.ftruncate(fd, size)
        lock = threading.Lock()
        def download(bounds):
            start, end = bounds
            if start in state['done']:
                return
            for attempt in range(5):
                try:
                    req = urllib.request.Request(base+name+f'?range_start={start}&attempt={attempt}&session={int(time.time())}', headers={'Range': f'bytes={start}-{end}'})
                    begun = time.monotonic()
                    with urllib.request.urlopen(req, timeout=30) as response:
                        if response.status != 206 or response.headers.get('Content-Range') != f'bytes {start}-{end}/{size}':
                            raise ValueError('Server did not honor exact range')
                        offset = start
                        while chunk := response.read(256*1024):
                            os.pwrite(fd, chunk, offset)
                            offset += len(chunk)
                            if time.monotonic()-begun > 90: raise TimeoutError('Slow range; retry with a fresh connection')
                        if offset != end+1:
                            raise ValueError('Truncated range')
                    with lock:
                        state['done'].append(start)
                        temp = ledger.with_suffix('.tmp')
                        temp.write_text(json.dumps(state))
                        temp.replace(ledger)
                        complete = state['prefix'] + sum(min(32*1024*1024, size-s) for s in state['done'])
                        print(f'{name}: {complete/size:.1%}', flush=True)
                    return
                except Exception:
                    if attempt == 4: raise
                    time.sleep(1+attempt)
        try:
            with ThreadPoolExecutor(max_workers=6) as pool:
                list(pool.map(download, [(s, min(size-1,s+32*1024*1024-1)) for s in range(state['prefix'], size, 32*1024*1024)]))
        finally:
            os.close(fd)
    if partial.stat().st_size != size:
        raise ValueError('Size mismatch')
    if item.get('lfs', {}).get('sha256'):
        h = hashlib.sha256()
        with partial.open('rb') as stream:
            while chunk := stream.read(8*1024*1024): h.update(chunk)
        if h.hexdigest() != item['lfs']['sha256']: raise ValueError('SHA256 mismatch')
        print('SHA256 verified', h.hexdigest(), flush=True)
    partial.replace(target)
    print('Ready', name, flush=True)
