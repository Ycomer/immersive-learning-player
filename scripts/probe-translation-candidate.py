"""Local diagnostic only; Chinese reference answers are never sent to the model.

Use the official HY-MT Chinese translation prompt. Greedy temperature 0 makes
this small comparison deterministic; this is not a semantic accuracy metric.
The candidate is not compatible with the app's Qwen JSON/teacher prompt.
"""
import argparse,json,pathlib,time,urllib.request
p=argparse.ArgumentParser()
p.add_argument('references');p.add_argument('asr');p.add_argument('output');p.add_argument('--model',default='hy-mt1.5:1.8b-q8-eval')
p.add_argument('--family',choices=['hymt','translategemma'],default='hymt')
a=p.parse_args()
refs=json.load(open(a.references))['cases']
asr={c['id']:c['hypothesis'] for c in json.load(open(a.asr))['cases']}
def translate(text):
    if a.family=='translategemma':
        prompt=('You are a professional Japanese (ja) to Chinese (Simplified) (zh-Hans) translator. '
                'Your goal is to accurately convey the meaning and nuances of the original Japanese text '
                'while adhering to Chinese (Simplified) grammar, vocabulary, and cultural sensitivities.\n'
                'Produce only the Chinese (Simplified) translation, without any additional explanations or commentary. '
                'Please translate the following Japanese text into Chinese (Simplified):\n\n\n'+text)
        payload={'model':a.model,'messages':[{'role':'user','content':prompt}],'stream':False,'options':{'temperature':0,'num_ctx':4096,'num_predict':600}}
        route='chat'
    else:
        payload={'model':a.model,'prompt':'将以下文本翻译为中文，注意只需要输出翻译后的结果，不要额外解释：\n\n'+text,'stream':False,'options':{'temperature':0,'top_k':20,'top_p':0.6,'repeat_penalty':1.05,'num_ctx':8192,'num_predict':600}}
        route='generate'
    req=urllib.request.Request('http://127.0.0.1:11434/api/'+route,json.dumps(payload).encode(),{'Content-Type':'application/json'})
    with urllib.request.urlopen(req,timeout=240) as r:
        reply=json.load(r)
    if not reply.get('done') or reply.get('done_reason')=='length':raise RuntimeError('Incomplete candidate translation')
    return (reply['message']['content'] if route=='chat' else reply['response']).strip()
results=[]
for c in refs:
    recognized=asr[c['asrCaseID']]
    start=time.monotonic()
    clean=translate(c['japaneseReference'])
    actual=clean if recognized==c['japaneseReference'] else translate(recognized)
    results.append(dict(c,recognizedJapanese=recognized,fromReference=clean,fromRecognition=actual,elapsedSeconds=time.monotonic()-start))
    pathlib.Path(a.output).write_text(json.dumps({'model':a.model,'semanticAccuracyVerified':False,'referenceLeakage':False,'temperature':0,'cases':results},ensure_ascii=False,indent=2))
    print(f'{len(results)}/{len(refs)} candidate diagnostic complete',flush=True)
