import importlib.util
from pathlib import Path

path = Path(__file__).resolve().parents[1] / 'scripts/score-english-quality.py'
spec = importlib.util.spec_from_file_location('english_metric', path)
metric = importlib.util.module_from_spec(spec); spec.loader.exec_module(metric)
assert metric.words("I CAN’T hear you!") == ["i", "can't", 'hear', 'you']
assert metric.words('fifteen, not fifty') != metric.words('fifty, not fifteen')
negative = metric.EXPECTATIONS["I wasn't serious."]
assert all(any(term in '我刚才不是认真说的。' for term in group) for group in negative)
assert not all(any(term in '我刚才是认真说的。' for term in group) for group in negative)
manifest = {'referenceSource': 'synthetic fixture', 'limits': [], 'cases': [
    {'id': 'english-dialogue', 'reference': "Don't spill the beans. Sure. I'll send it this afternoon.", 'lines': [
        {'text': "Don't spill the beans.", 'intendedChinese': '别泄密。', 'start': 1, 'end': 3, 'gain': 1},
        {'text': "Sure. I'll send it this afternoon.", 'intendedChinese': '下午发给你。', 'start': 4, 'end': 6, 'gain': .02}]},
    {'id': 'silence', 'reference': '', 'lines': []}]}
outputs = {'cases': [
    {'id': 'english-dialogue', 'displayChecks': 1, 'originalProcessingSeconds': 1, 'cues': [
        {'start': 1.02, 'end': 3.01, 'text': "Don't spill the beans.", 'translation': '不要把豆子撒出去。'}]},
    {'id': 'silence', 'originalProcessingSeconds': .1, 'cues': [
        {'start': 0, 'end': 1, 'text': 'Fake subtitle.'}]}]}
result = metric.score(manifest, outputs)
assert result['wordErrors'] == 6 and result['nonSpeechFalseCues'] == 1
assert result['scriptedDialogueLinesPresent'] == 1
assert result['scriptedMeaningChecksPassed'] == 0
assert result['cases'][0]['lines'][1]['hypothesis'] == ''
assert not result['realVideo98PercentVerified']
outputs['cases'][0]['cues'][0]['translation'] = '不要泄露秘密。'
outputs['cases'][0]['cues'].append({'start': 4, 'end': 6, 'text': "Sure. I'll send it this afternoon.", 'translation': '好的，下午发给你。'})
outputs['cases'][1]['cues'] = []
result = metric.score(manifest, outputs)
assert result['wordErrors'] == 0 and result['nonSpeechFalseCues'] == 0
assert result['scriptedMeaningChecksPassed'] == 2 and not result['realVideo98PercentVerified']
print('PASS: English WER, apostrophes, numeric differences, missing quiet line, literal idiom error and silence false cues')
