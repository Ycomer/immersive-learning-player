"""Ensure text matching cannot hide misplaced/missing real-video subtitles."""
import importlib.util

spec = importlib.util.spec_from_file_location('real_metric','scripts/score-real-video.py')
scorer = importlib.util.module_from_spec(spec); spec.loader.exec_module(scorer)
reference = {'language':'en','captions':[{'start':23.25,'end':27.25,'text':'Good night, Scales.'}]}
actual = {'id':'quiet-real','status':'completed','processingSeconds':1,'audioSeconds':30,'cues':[
    {'start':10.29,'end':10.61,'text':'Good night,'},
    {'start':23.41,'end':23.65,'text':'Scales.'}]}
result = scorer.assess(reference,actual)
assert result['errorRate'] == 0
assert result['maxAbsoluteCaptionStartDifferenceSeconds'] > 12
assert result['lines'][0]['maxGapInsideMatchedLineSeconds'] > 12
missing = scorer.assess(reference,{**actual,'cues':[]})
assert missing['errorRate'] == 1 and missing['timingComparedRows'] == 0
assert missing['medianAbsoluteCaptionStartDifferenceSeconds'] is None
print('PASS: correct text with 13-second misalignment is flagged; missing lines cannot count as synchronized')
