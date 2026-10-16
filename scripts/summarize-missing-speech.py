"""Summarize actual before/after runs, retaining literal errors and silence controls."""
import hashlib,importlib.util,json
from pathlib import Path
root=Path('tools/real-video-evaluation/missing-speech-regression')
s=importlib.util.spec_from_file_location('metric','scripts/score-real-video.py');metric=importlib.util.module_from_spec(s);s.loader.exec_module(metric)
refs={c['id']:c for c in json.loads((root/'manifest.json').read_text())['cases']}
before={c['id']:c for c in json.loads((root/'baseline.json').read_text())['cases']}
after=json.loads((root/'repaired.json').read_text())['cases']
assert set(refs)==set(before)=={c['id'] for c in after} and len(after)==6
rows=[]
for c in after:
 rows.append(dict(id=c['id'],sameTranscript=before[c['id']]['hypothesis']==c['hypothesis'],before=metric.assess(refs[c['id']],before[c['id']]),after=metric.assess(refs[c['id']],c)))
quiet=[]
for prefix,label in [('', 'attenuated original real audio, direct worker'),('production-', 'attenuated real audio through player highpass/dynamic normalization and PCM16 extraction')]:
 a={c['id']:c for c in json.loads((root/(prefix+'quiet-baseline.json')).read_text())}
 b=json.loads((root/(prefix+'quiet-final.json')).read_text())
 for c in b:
  old=a.get(c['id'])
  if c['id'] in ['silence','noise','tone']:assert c['text']=='',c['id']
  quiet.append(dict(id=c['id'],path=label,beforeCharacters=len(old['text']) if old else None,afterCharacters=len(c['text']),beforeRegions=len(old['regions']) if old else None,afterRegions=len(c['regions']),text=c['text'],recoveredBlocks=[p for p in c.get('acousticBlocks',[]) if p.get('recovery')]))
result=dict(localOnly=True,recognitionRevision='speech-v11-quiet-voice-recovery',
 fixes=['Gain-limited second VAD pass, preserving original video-clock coordinates.','Very quiet full-window recognition uses gain-limited audio.','Omitted/empty global recognition can recover locally corroborated speech; contradictory negation and isolated English vocalizations are not added.','Empty windows report no recognized dialogue instead of generic subtitles ready; cache profile invalidated.'],
 limits=['Attenuation is a derived stress condition, not proof that original actors whispered.','VAD boundaries and publisher display times are not independently annotated true phoneme onsets.','Gain cannot recover words lost through quantization or masked by other sound.','The user video was unavailable; cannot claim all television dialogue is fixed or 98% accuracy.'],
 fullProductionCorpus=rows,quietAndControls=quiet)
(root/'comparison.json').write_text(json.dumps(result,ensure_ascii=False,indent=2))
worker=Path('scripts/local-qwen-asr.py');bundled=Path('build/Build/Products/Debug/SubtitleStudy.app/Contents/Resources/Tools/local-qwen-asr.py')
(root/'runtime-verification.json').write_text(json.dumps(dict(sourceWorkerSHA256=hashlib.sha256(worker.read_bytes()).hexdigest(),bundledWorkerSHA256=hashlib.sha256(bundled.read_bytes()).hexdigest(),cloudInferenceUsed=False,candidateIntegrated=False),indent=2))
for c in rows:print(c['id'],'sameTranscript=',c['sameTranscript'],'errors=',c['before']['editErrors'],'->',c['after']['editErrors'])
for c in quiet:print(c['path'],c['id'],c['beforeCharacters'],'->',c['afterCharacters'])
