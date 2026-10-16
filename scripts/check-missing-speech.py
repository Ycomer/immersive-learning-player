"""Exercise actual local ASR with real voices at measured gain and noise controls.

Reference text never enters the worker. Derived attenuation is a stress test,
not a claim that the original actors whispered. No network is allowed by worker.
"""
import argparse
import importlib.util
import json
from pathlib import Path
import time

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('worker');parser.add_argument('output');parser.add_argument('--id');parser.add_argument('--production',action='store_true')
a=parser.parse_args()
spec=importlib.util.spec_from_file_location('worker',a.worker)
w=importlib.util.module_from_spec(spec);spec.loader.exec_module(w)
import numpy as np
import soundfile as sf
root=Path('tools/real-video-evaluation/missing-speech-regression');out=[]
cases=[('erin17-very-quiet','erin17-natural-0.001.wav','ja'),('erin23-very-quiet','erin23-natural-0.001.wav','ja')]
# Subtitle-free film interval contains music/foley and non-lexical vocalizations.
audio,rate=sf.read('tools/real-video-evaluation/inputs/sintel-soft.wav',dtype='float32')
sf.write(root/'inputs'/'film-gap.wav',audio[10*rate:20*rate],rate,subtype='FLOAT')
cases.append(('film-gap','film-gap.wav','en'))
if a.production:
 cases=[(name+'-production-quiet',name+'-production-0.001.wav','ja') for name in ['erin17-natural','erin23-natural']]
for kind in ['silence','noise','tone']:
 target=root/'inputs'/(kind+'.wav');rate=16000
 x=np.zeros(6*rate,dtype=np.float32)
 if kind=='noise': x=np.random.default_rng(391).normal(0,.002,len(x)).astype(np.float32)
 if kind=='tone': x=(.001*np.sin(np.arange(len(x))*2*np.pi*330/rate)).astype(np.float32)
 sf.write(target,x,rate,subtype='FLOAT');cases.append((kind,target.name,'ja'))
for name,path,lang in cases:
 if a.id and name!=a.id: continue
 started=time.monotonic()
 result=w.transcribe(str(root/'inputs'/path),'tools/asr-candidates/qwen3-asr-1.7b-8bit','tools/asr-candidates/qwen3-forced-aligner-0.6b-8bit','tools/whisper.cpp/static-build/bin/whisper-vad-speech-segments','tools/whisper.cpp/models/ggml-silero-v6.2.0.bin',lang)
 out.append(dict(id=name,seconds=time.monotonic()-started,**result))
 Path(a.output).write_text(json.dumps(out,ensure_ascii=False,indent=2))
 print(name,result['reason'],repr(result['text']),flush=True)
