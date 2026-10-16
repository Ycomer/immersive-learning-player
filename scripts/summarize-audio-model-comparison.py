"""Record bounded human semantic review; model answers never grade themselves."""
import json,statistics
from pathlib import Path
root=Path('tools/real-video-evaluation/qwen2-audio-comparison')
regular=json.loads((root/'qwen2-results.json').read_text())
stock=json.loads((root/'qwen2-results-stock.json').read_text())
context=json.loads((root/'qwen2-results-context.json').read_text())
review={
'ja-laugh':('partial','Intended: showing my drawing will make you laugh. Does not preserve speaker/object clearly; stock returns Japanese instead of Chinese.'),
'ja-accompany':('incorrect','Human skit describes accompanying someone to a romance movie. Both variants invent travel/holiday or unrelated content.'),
'ja-unprepared':('failed-format-or-omission','Intended: not that, but I had not mentally prepared. Corrected frontend returns Japanese; stock is incomplete and unnatural.'),
'ja-reassure':('incorrect','Publisher Japanese is 心配すんなって, reassurance not to worry. Both variants invent color/appearance or price.'),
'ja-my-line':('acceptable','Direct Chinese matches that is my line, although separately generated Japanese transcription is inconsistent. Not proof of reliable source recognition.'),
'en-gear':('incorrect-metaphor','Talk is about ramping up thesis work, not a literal accelerator, light, weights or gears. Earlier production translator retained increasing work intensity.'),
'en-all-nighters':('partial','Understands two all-nighters in corrected frontend, but drops seventy-two hours and changes ninety pages to more than ninety; stock also loses the two all-nighters.'),
'en-dear':('incorrect','Kindred spirit means a person with similar feelings/values, not Kennedy or Kentucky/KFC.'),
'en-quiet-name':('incorrect','Scales is the addressed dragon name in original film dialogue. Candidate changes the addressee to children.'),
'context-ja-accompany':('incorrect','Longer conversation includes the movie context, yet candidate translates into unrelated or broken Chinese.'),
'context-ja-laugh':('failed-format','Requests Chinese but returns Japanese even with 28 seconds of conversation.'),
'context-en-dear':('failed-format','Requests Chinese but returns an English transcript.'),
'context-en-gear':('incorrect-and-incomplete','Still treats start off light literally; also changes the year would go to last year and truncates the ending.')}
rows=[]
for case in regular['cases']+context['cases']:
 verdict,reason=review[case['id']]
 row=dict(id=case['id'],verdict=verdict,reason=reason,correctedFrontend=case)
 other=next((x for x in stock['cases'] if x['id']==case['id']),None)
 if other:row['stockMLX']=other
 rows.append(row)
result=dict(candidate='Qwen2-Audio-7B-Instruct-4bit',downloadBytes=6574656756,weightsVerified=True,
 inference='local Metal; outbound Python socket connections forbidden',uniqueRealAudioCases=len(rows),
 evaluation='9 short dialogue clips plus 4 conversation windows of 28 seconds; publisher text excluded from inference',
 baseline='Previously saved production Qwen3-ASR + TranslateGemma 12B results on the same source videos. Fragment boundaries/context differ, so baseline latency is not directly comparable.',
 limitations=['This evaluates this quantized local model and MLX implementations, not every Qwen2-Audio deployment.','No general semantic accuracy percentage or 98% claim.','Direct audio text has no validated word timestamps; timing would still need the existing aligner.','Model memory is MLX peak allocation, not total macOS resident memory.'],
 decision='Do not integrate: semantic errors, omitted utterances and wrong output language persist with longer context and both frontends.',
 currentPlayer='Qwen3-ASR 1.7B 8bit + forced aligner; TranslateGemma 12B main translation; Qwen3 4B learning explanations',
 candidateIntegrated=False,peakMLXBytes=regular['peakMemoryBytes'],
 shortTranslationMedianSeconds=statistics.median(x['translation']['seconds'] for x in regular['cases']),
 contextTranslationMedianSeconds=statistics.median(x['translation']['seconds'] for x in context['cases']),cases=rows)
(root/'semantic-review.json').write_text(json.dumps(result,ensure_ascii=False,indent=2))
print(result['decision'])
