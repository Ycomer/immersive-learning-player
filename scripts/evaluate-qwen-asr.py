"""Fixed corpus, local weights, no hotwords or reference transcript prompting.

Raw mode isolates model recognition. Speech mode uses acoustic VAD boundaries and
dynamic normalization, never script timestamps. Chunk boundaries are not claimed
to be word alignment. References are copied only for scoring after recognition.
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time

os.environ.update(HF_HUB_OFFLINE='1', TRANSFORMERS_OFFLINE='1', HF_HUB_DISABLE_TELEMETRY='1')


def no_network(event, args):
    if event == 'socket.connect':
        raise RuntimeError('Network connections forbidden during ASR evaluation')


sys.addaudithook(no_network)

from mlx_audio.stt import load
import mlx.core as mx
import soundfile as sf

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('output', type=Path)
parser.add_argument('--pipeline', choices=['raw', 'speech', 'context'], default='raw')
parser.add_argument('--id')
args = parser.parse_args()
root = Path('tools/wavesubs-evaluation')
manifest = json.loads((root/'native-corpus-manifest.json').read_text())
started = time.monotonic()
model = load(str(Path('tools/asr-candidates/qwen3-asr-1.7b-8bit').resolve()))
report = {'model': 'Qwen3-ASR-1.7B-8bit', 'revision': 'a8379a2e2f9e313c9292cdf1af4055ab56d50d55',
          'pipeline': args.pipeline, 'outboundConnectionsForbidden': True,
          'loadSeconds': time.monotonic()-started, 'referenceSource': manifest['referenceSource'],
          'timingMethod': 'input chunk boundaries, not forced alignment', 'cases': []}
vad_root = Path('/Applications/Wave Subs.app/Contents/Resources/vendor')
with tempfile.TemporaryDirectory(prefix='qwen-eval-') as temporary:
    normalized = Path(temporary)/'normalized.wav'
    for case in manifest['cases']:
        if args.id and case['id'] != args.id:
            continue
        started = time.monotonic()
        audio, rate = sf.read(case['audio'], dtype='float32')
        duration = len(audio)/rate
        assert rate == 16000 and audio.ndim == 1
        if args.pipeline in ['speech','context']:
            subprocess.run(['/opt/homebrew/bin/ffmpeg','-v','error','-nostdin','-y','-i',case['audio'],
                            '-af','highpass=f=60,dynaudnorm=f=150:g=15:p=0.9:m=25:r=0.1:t=0.0001',
                            '-ac','1','-ar','16000','-c:a','pcm_s16le',str(normalized)], check=True)
            audio, rate = sf.read(normalized, dtype='float32')
            vad = subprocess.run([str(vad_root/'bin/whisper-vad-speech-segments'),'-np','-f',str(normalized),
                                  '-vm',str(vad_root/'vad/ggml-silero-v5.1.2.bin'),'-vt','0.35','-vp','80',
                                  '-vsd','400','-vmsd','15'], capture_output=True, text=True, check=True)
            regions = [(float(a)/100,float(b)/100) for a,b in re.findall(r'start = ([\d.]+), end = ([\d.]+)', vad.stdout)]
            merged = []
            for start,end in regions:
                if merged and start-merged[-1][1] <= 0.85 and end-merged[-1][0] <= 15:
                    merged[-1][1] = end
                else:
                    merged.append([start,end])
            regions = merged
            if args.pipeline == 'context' and regions:
                regions = [[0,duration]]
        else:
            regions = [[0,duration]]
        cues = []
        raw_results = []
        for start,end in regions:
            result = model.generate(audio[int(start*rate):int(end*rate)], language='Japanese',
                                    temperature=0, max_tokens=768, verbose=False)
            text = result.text.strip()
            raw_results.append({'start': start, 'end': end, 'text': text, 'generationTokens': result.generation_tokens})
            if text:
                cues.append({'start': start, 'end': end, 'startMs': round(start*1000),
                             'endMs': round(end*1000), 'text': text})
            mx.clear_cache()
        report['cases'].append({'id': case['id'], 'reference': case['reference'],
                                 'hypothesis': ''.join(c['text'] for c in cues), 'cues': cues,
                                 'rawResults': raw_results, 'cueCount': len(cues),
                                 'audioSeconds': duration, 'processingSeconds': time.monotonic()-started})
        args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2)+'\n')
        print(case['id'], f'{report["cases"][-1]["processingSeconds"]:.1f}s', len(cues), flush=True)
