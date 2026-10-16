"""Prepare real human audio windows; keep publisher references out of inference manifest."""
import json
from pathlib import Path
import subprocess
root=Path('tools/real-video-evaluation');out=root/'qwen2-audio-comparison';out.mkdir(exist_ok=True)
corpus={c['id']:c for c in json.loads((root/'manifest.json').read_text())['cases']}
previous=json.loads((root/'translation-results.json').read_text())['cues']
selections=[('ja-laugh','erin17-natural',21,26,[0]),('ja-accompany','erin23-natural',9.7,13.9,[3,4,5]),('ja-unprepared','erin23-natural',48.4,54,[8]),('ja-reassure','erin23-natural',60,65,[9]),('ja-my-line','erin25-natural',45,51,[11]),('en-gear','ted-natural',56.5,65,[12]),('en-all-nighters','ted-natural',103,110.4,[18]),('en-dear','sintel-dialogue',33,38.8,[20,21]),('en-quiet-name','sintel-soft',22.3,27.8,[25])]
# Longer windows distinguish missing conversational context from model errors.
selections += [('context-ja-accompany','erin23-natural',4,32,[3,4,5,6]),('context-ja-laugh','erin17-natural',9,37,[0,1,2]),('context-en-dear','sintel-dialogue',26,54,[20,21,22]),('context-en-gear','ted-natural',50,78,[12,13,14,15,16])]
inputs=[];review=[]
for name,source,start,end,indices in selections:
 c=corpus[source];target=out/(name+'.wav')
 subprocess.run(['/opt/homebrew/bin/ffmpeg','-v','error','-nostdin','-y','-ss',str(start),'-i',c['audio'],'-t',str(end-start),'-af','highpass=f=60,dynaudnorm=f=150:g=15:p=0.9:m=25:r=0.1:t=0.0001','-ar','16000','-ac','1','-c:a','pcm_s16le',str(target)],check=True)
 inputs.append(dict(id=name,audio=str(target.resolve()),language=c['language']))
 refs=[x for x in c['captions'] if x['start']<end and x['end']>start]
 review.append(dict(id=name,source=source,start=start,end=end,publisherReference=refs,productionBaseline=[previous[i] for i in indices]))
(out/'inputs.json').write_text(json.dumps({'cases':inputs},indent=2))
(out/'references-and-baseline.json').write_text(json.dumps(review,ensure_ascii=False,indent=2))
print('Prepared',len(inputs),'bounded real-human audio clips; references isolated')
