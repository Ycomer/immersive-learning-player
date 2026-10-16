"""Missing language-tag fallback must not turn Japanese local probes into English."""
import importlib.util,sys,tempfile,types
from pathlib import Path
from types import SimpleNamespace
import numpy as np
import soundfile as sf
s=importlib.util.spec_from_file_location('worker','scripts/local-qwen-asr.py');w=importlib.util.module_from_spec(s);s.loader.exec_module(w)
assert w.script_language_evidence('さきと映画に来るの久しぶりね。何言ってんの？')=='Japanese'
assert w.script_language_evidence('한국어를 공부하고 있어요.')=='Korean'
for value in ['うん。','東京 山田太郎','I went to Tokyo yesterday.','Bonjour, comment allez-vous?','']:
 assert w.script_language_evidence(value) is None,value
class Recognizer:
 def __init__(self,rows):self.rows=iter(rows);self.languages=[]
 def generate(self,*args,**kwargs):
  self.languages.append(kwargs.get('language'));text,language=next(self.rows)
  return SimpleNamespace(text=text,language=[language])
class Aligner:
 def generate(self,*,audio,text,language):return [SimpleNamespace(text=text,start_time=.2,end_time=.6)]
mlx=types.ModuleType('mlx');core=types.ModuleType('mlx.core');core.clear_cache=lambda:None;mlx.core=core
pkg=types.ModuleType('mlx_audio');stt=types.ModuleType('mlx_audio.stt');pkg.stt=stt
sys.modules.update({'mlx':mlx,'mlx.core':core,'mlx_audio':pkg,'mlx_audio.stt':stt})
w.detect_regions=lambda *args:[dict(start=1,end=2),dict(start=7,end=8)]
with tempfile.TemporaryDirectory() as folder:
 path=Path(folder)/'audio.wav';sf.write(path,np.random.default_rng(7).normal(0,.02,160000).astype(np.float32),16000,subtype='FLOAT')
 text='こんにちは。少し待ってください。'
 recognizer=Recognizer([(text,'English'),(text,'Japanese'),('こんにちは。','Japanese'),('少し待ってください。','Japanese')])
 stt.load=lambda path:recognizer if path=='asr' else Aligner()
 result=w.transcribe(str(path),'asr','aligner','vad','model','auto')
 assert recognizer.languages==[None,'Japanese','Japanese','Japanese'],recognizer.languages
 assert result['reportedLanguage']=='English' and result['language']=='Japanese'
 assert result['languageReview'] and result['text']==text
 assert all(x['confidence']>=.72 for x in result['words']),result
 recognizer=Recognizer([('Hello. Please wait.','English'),('Hello.','English'),('Please wait.','English')])
 result=w.transcribe(str(path),'asr','aligner','vad','model','auto')
 assert result['language']=='English' and result['languageReview'] is None
 assert recognizer.languages==[None,'English','English']
print('PASS: English fallback with Japanese transcript triggers audio re-read in Japanese; English remains English; short words and Han-only names never force a language')
