"""Conservative recovery and interval union contracts, independent of GPU."""
import importlib.util
import sys
spec=importlib.util.spec_from_file_location('worker',sys.argv[1] if len(sys.argv)>1 else 'scripts/local-qwen-asr.py')
w=importlib.util.module_from_spec(spec);spec.loader.exec_module(w)
assert w.confirmed_recovery('心配すんなって。','心配すんなって！')
assert not w.confirmed_recovery('うん。','ううん。'), 'must preserve affirmation vs negation'
assert not w.confirmed_recovery('あ。','あ。'), 'single syllables cannot justify new dialogue'
assert not w.confirmed_recovery('[Music]','Music')
for value in ['Oh.','Um.','Huh.','Hmm. Hm hm.']:
 assert not w.confirmed_recovery(value,value), 'isolated vocalization is not recovered dialogue'
assert not w.confirmed_recovery('見せて。','見てて。')
assert w.merge_regions([dict(start=1,end=2),dict(start=8,end=9)],[dict(start=1.5,end=3),dict(start=5,end=6)],10)==[dict(start=1,end=3),dict(start=5,end=6),dict(start=8,end=9)]
assert w.merge_regions([], [dict(start=-1,end=2),dict(start=4,end=20)],5)==[dict(start=0,end=2),dict(start=4,end=5)]
print('PASS: quiet VAD union preserves silence; acoustic recovery rejects conflicting negation, single syllables and tags')

# Model-independent integration: a locally heard sentence must survive even if
# the full-window pass omitted it, but conflicting views must never add words.
from pathlib import Path
from types import SimpleNamespace
import tempfile
import types
import numpy as np
import soundfile as sf

class Recognizer:
    def __init__(self,texts): self.texts=iter(texts)
    def generate(self,*args,**kwargs): return SimpleNamespace(text=next(self.texts),language='Japanese')
class Aligner:
    def generate(self,*,audio,text,language): return [SimpleNamespace(text=text,start_time=.2,end_time=.6)]

saved={name:sys.modules.get(name) for name in ['mlx_audio','mlx_audio.stt','mlx','mlx.core']}
mlx=types.ModuleType('mlx');core=types.ModuleType('mlx.core');core.clear_cache=lambda:None;mlx.core=core
package=types.ModuleType('mlx_audio');stt=types.ModuleType('mlx_audio.stt');package.stt=stt
sys.modules.update({'mlx':mlx,'mlx.core':core,'mlx_audio':package,'mlx_audio.stt':stt})
old_detect=w.detect_regions
w.detect_regions=lambda *args:[dict(start=1,end=2),dict(start=7,end=8)]
try:
 with tempfile.TemporaryDirectory() as folder:
    path=Path(folder)/'audio.wav';sf.write(path,np.random.default_rng(2).normal(0,.01,160000).astype(np.float32),16000,subtype='FLOAT')
    for global_text,second,expected in [('こんにちは。','待って。',True),('こんにちは。','帰って。',False),('','待って。',True)]:
        responses=[global_text,'こんにちは。','待って。']
        if not global_text: responses+=['こんにちは。']
        responses+=[second]
        recognizer=Recognizer(responses)
        stt.load=lambda path: recognizer if path=='asr' else Aligner()
        result=w.transcribe(str(path),'asr','aligner','vad','model','ja')
        assert ('待って。' in result['text'])==expected,result
        assert ''.join(x['text'] for x in result['words'])==result['text']
    for tighter,expected in [('少し待ってください。',True),('少し待たないでください。',False)]:
        recognizer=Recognizer(['こんにちは。','こんにちは。','少し待ってください。','先に行ってください。',tighter])
        stt.load=lambda path: recognizer if path=='asr' else Aligner()
        result=w.transcribe(str(path),'asr','aligner','vad','model','ja')
        assert ('少し待ってください。' in result['text'])==expected,result
finally:
 w.detect_regions=old_detect
 for name,previous in saved.items():
    if previous is None: sys.modules.pop(name,None)
    else: sys.modules[name]=previous
print('PASS: missing full-window line and empty full-window result recover from matching local views; disagreement remains unresolved')
