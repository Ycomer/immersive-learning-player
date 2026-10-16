"""Export measured local-model results. Never infer semantic accuracy from CER."""
import importlib.util
import json
from pathlib import Path
import statistics

root = Path('tools/wavesubs-evaluation')
spec = importlib.util.spec_from_file_location('asr_score','scripts/score-asr.py')
score = importlib.util.module_from_spec(spec)
spec.loader.exec_module(score)
def read(name): return json.loads((root/name).read_text())
metrics = []
for filename,label in [
    ('asr-results.json','Wave Subs 1.0.9 / Whisper large-v3'),
    ('native-large-v3-results.json','Native audio pipeline / Whisper large-v3'),
    ('native-kotoba-results.json','Native audio pipeline / Kotoba Whisper v2'),
    ('qwen3-asr-raw-results.json','Qwen3-ASR 1.7B 8bit / raw'),
    ('qwen3-asr-speech-results.json','Qwen3-ASR / short speech segments'),
    ('player-qwen-final-results.json','Player Qwen3-ASR / normalized context + regional forced alignment'),
]:
    source = read(filename)
    cases = source['cases'][:20]
    for case in cases:
        case.setdefault('audioSeconds',case.get('duration',0))
        case.setdefault('cueCount',len(case.get('cues',[])))
    value = score.score({'model':label,'referenceSource':'20 human FLEURS recordings; 9 distinct reference texts','cases':cases})
    metrics.append({'inputReport':filename,**value})

actual = read('player-local-stack-results.json')
reference = read('dialogue-reference.json')
cues = actual['cues']
converted = [{**c,'startMs':round(c['start']*1000),'endMs':round(c['end']*1000)} for c in cues]
(root/'player-best-dialogue.json').write_text(json.dumps({**actual,'cues':converted},ensure_ascii=False,indent=2)+'\n')
exports = root/'exports'
exports.mkdir(exist_ok=True)
def timestamp(value):
    ms = round(value*1000)
    return f'{ms//3600000:02d}:{ms//60000%60:02d}:{ms//1000%60:02d},{ms%1000:03d}'
for kind in ['ja','zh','bilingual']:
    blocks = []
    for i,cue in enumerate(cues,1):
        text = cue['text'] if kind=='ja' else cue['translation'] if kind=='zh' else cue['text']+'\n'+cue['translation']
        blocks.append(f'{i}\n{timestamp(cue["start"])} --> {timestamp(cue["end"])}\n{text}')
    (exports/f'generated-dialogue-best-local.{kind}.srt').write_text('\n\n'.join(blocks)+'\n')

timing = []
for line in reference['lines']:
    matches = [c for c in cues if line['start']-0.3 <= c['start'] < line['end']]
    timing.append({'line':line['index'],'matchedCueCount':len(matches),
                   'startOffsetSeconds':matches[0]['start']-line['start'] if matches else None,
                   'endOffsetSeconds':matches[-1]['end']-line['end'] if matches else None})
start_offsets = [abs(x['startOffsetSeconds']) for x in timing if x['startOffsetSeconds'] is not None]
end_offsets = [abs(x['endOffsetSeconds']) for x in timing if x['endOffsetSeconds'] is not None]
final_asr = read('player-qwen-final-results.json')
stress = [{'id':c['id'],'hypothesis':c['hypothesis'],'cueCount':c['cueCount']} for c in final_asr['cases'][20:]]
report = {
    'selected': {'recognition':'Qwen3-ASR-1.7B-8bit','alignment':'Qwen3-ForcedAligner-0.6B-8bit',
                 'questionReview':'Whisper large-v3; only restore questions for identical words at overlapping times',
                 'translation':'translategemma:12b','uncertainIdiomBackup':'qwen3:4b-instruct',
                 'referenceGuide':'sourced local idiom notes; finite retry and explicit uncertainty',
                 'cloudInference':False},
    'humanTranscriptionMetrics':metrics,
    'stressCases':stress,
    'realPlayerTest':{'report':'player-local-stack-results.json','passed':actual['passed'],
                      'firstQuietTranslationWaitSeconds':actual['firstQuietTranslationWaitSeconds'],
                      'totalTestSeconds':actual['processingSeconds'],
                      'conditions':'warm installed models; seek-through test, not a pure inference speed benchmark',
                      'cueModels':[{'text':c['text'],'model':c.get('translationModelUsed'),'warning':c.get('translationWarning')} for c in cues]},
    'syntheticTiming':{'reference':'known synthesis clip boundaries, NOT human word-aligned timestamps',
                       'cases':timing,'medianAbsoluteStartOffset':statistics.median(start_offsets),
                       'maximumAbsoluteStartOffset':max(start_offsets),'maximumAbsoluteEndOffset':max(end_offsets)},
    'limits':['20 human recordings contain only 9 distinct texts; not a real film benchmark',
              'Synthetic dialogue is clear TTS plus a quiet line, not whispering/overlapping actors',
              'CER ignores punctuation and is not Chinese meaning accuracy; question review leaves scored characters unchanged',
              'Chinese examples use assistant-authored script intentions and sourced idiom meanings; no independent human semantic acceptance',
              'Stationary tone and silence tests are not a guarantee for all music or environmental noise',
              '98% real-video Japanese and Chinese accuracy remains unverified'],
    'unchangedInputIntegrity':'comparison-input-integrity.json'
}
(root/'local-model-comparison.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
print('Saved comparative metrics, actual player captions and three SRT exports')
print('human CER:',[(m['model'],round(m['cer']*100,3)) for m in metrics])
print('timing:',report['syntheticTiming']['medianAbsoluteStartOffset'],report['syntheticTiming']['maximumAbsoluteEndOffset'])
