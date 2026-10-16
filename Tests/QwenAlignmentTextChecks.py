"""Real-video regression: punctuation removed by aligner must not crash ASR."""
import importlib.util
from types import SimpleNamespace

spec = importlib.util.spec_from_file_location('worker', 'scripts/local-qwen-asr.py')
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)

def item(text, start, end):
    return SimpleNamespace(text=text, start_time=start, end_time=end)

for text, tokens in [
    ('よし。え、もうできたの？', ['よしえ', 'もう', 'できたの']),
    ('my ninety-page senior thesis.', ['my', 'ninetypage', 'senior', 'thesis']),
    ("pulling two all-nighters -- really?", ['pulling', 'two', 'allnighters', 'really']),
]:
    result = worker.restore_words([item(t,i,i+.4) for i,t in enumerate(tokens)],text,10,2)
    assert ''.join(w['text'] for w in result) == text
    assert result[0]['start'] == 2
    assert all(w['end'] >= w['start'] for w in result)

for tokens in [[item('different',0,1)], [item('my',-1,1)], [item('my',0,100)]]:
    try:
        worker.restore_words(tokens,'my text',10)
        raise AssertionError('Invalid alignment accepted')
    except ValueError:
        pass
print('PASS: real Japanese and English punctuation anchors preserve exact ASR text; mismatched words and invalid times rejected')
