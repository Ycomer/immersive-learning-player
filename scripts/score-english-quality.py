"""Score English outputs after inference; never feed references to the models."""
import argparse
import importlib.util
import json
from pathlib import Path
import re
import statistics
import unicodedata

BASE = Path(__file__).resolve().parents[1] / 'tools/english-evaluation'
spec = importlib.util.spec_from_file_location('asr_metric', Path(__file__).with_name('score-asr.py'))
metric = importlib.util.module_from_spec(spec); spec.loader.exec_module(metric)


def words(text):
    return re.findall(r"[a-z]+(?:'[a-z]+)?|\d+", unicodedata.normalize('NFKC', text).lower().replace('’', "'"))


# Scripted meaning checks are regression tripwires, not a semantic accuracy score.
# Alternative valid translations may require manual inspection.
EXPECTATIONS = {
    "Can you send me the report before five?": [['五点', '5点'], ['前', '之前'], ['报告']],
    "Sure. I'll send it this afternoon.": [['下午'], ['发', '发送', '送']],
    "I didn't say he stole the money.": [['没说', '没有说', '没讲', '并未说'], ['偷']],
    "Don't spill the beans.": [['别', '不要', '不许'], ['泄', '透露', '说漏', '保密']],
    "It's still a secret.": [['秘密', '保密']],
    "I was pulling your leg.": [['逗', '玩笑', '闹着玩', '骗你玩']],
    "I wasn't serious.": [['不是认真', '不认真', '没当真', '没有当真', '开玩笑', '没认真', '没有认真']],
    "Let's call it a day.": [['到此', '到这', '收工', '结束', '就这样', '今天就', '今天先']],
    "We can finish tomorrow.": [['明天'], ['完', '做']],
    "I'm feeling under the weather.": [['不舒服', '不太舒服', '不适', '生病', '欠佳', '身体不好', '不太好']],
    "I won't come in today.": [['今天'], ['不来', '不会来', '不去', '不会去', '不能来', '不上班']],
    "Could you turn down the music?": [['音乐'], ['小', '低']],
    "I can barely hear you.": [['听'], ['不清', '几乎', '难', '很难', '勉强']],
    "It costs fifteen dollars, not fifty.": [['十五', '15'], ['五十', '50'], ['不是', '而非', '不', '非']],
    "Meet me at half past three.": [['三点半', '3点半', '三点三十', '3点30']],
}


def score(manifest, outputs):
    references = {c['id']: c for c in manifest['cases']}
    cases, total_words, total_errors, false_cues = [], 0, 0, 0
    for actual in outputs['cases']:
        ref = references[actual['id']]
        expected = words(ref['reference'])
        hypothesis = ' '.join(c['text'] for c in actual['cues'])
        errors = metric.distance(expected, words(hypothesis))
        false = len(actual['cues']) if not expected else 0
        false_cues += false
        total_words += len(expected); total_errors += errors if expected else 0
        lines = []
        # Assign each cue to its greatest reference-interval overlap, only here
        # after recognition. A cue crossing two scripted lines is explicitly kept
        # as an issue rather than silently dropped from the overall WER above.
        ownership = [[] for _ in ref['lines']]
        for cue in actual['cues']:
            overlaps = [max(0, min(cue['end'], r['end'])-max(cue['start'], r['start'])) for r in ref['lines']]
            if overlaps and max(overlaps) > 0:
                ownership[overlaps.index(max(overlaps))].append(cue)
        for line, cues in zip(ref['lines'], ownership):
            transcript = ' '.join(c['text'] for c in cues)
            chinese = ' '.join(c.get('translation') or '' for c in cues)
            checks = EXPECTATIONS.get(line['text'], [])
            meanings_pass = None if not actual.get('displayChecks') else all(any(t in chinese for t in group) for group in checks)
            lines.append({'reference': line['text'], 'intendedChinese': line['intendedChinese'],
                'gain': line['gain'], 'hypothesis': transcript, 'translation': chinese,
                'wordErrors': metric.distance(words(line['text']), words(transcript)),
                'scriptedMeaningCheck': meanings_pass,
                'startErrorSeconds': min(c['start'] for c in cues)-line['start'] if cues else None,
                'endErrorSeconds': max(c['end'] for c in cues)-line['end'] if cues else None,
                'annotations': [n for c in cues for n in (c.get('annotations') or [])],
                'warnings': [c.get('translationWarning') for c in cues if c.get('translationWarning')]})
        cases.append({'id': actual['id'], 'referenceWords': len(expected), 'wordErrors': errors,
            'wer': errors/len(expected) if expected else None, 'nonSpeechFalseCues': false,
            'originalProcessingSeconds': actual['originalProcessingSeconds'], 'lines': lines})
    dialogue = next(c for c in cases if c['id'] == 'english-dialogue')
    starts = [abs(l['startErrorSeconds']) for l in dialogue['lines'] if l['startErrorSeconds'] is not None]
    ends = [abs(l['endErrorSeconds']) for l in dialogue['lines'] if l['endErrorSeconds'] is not None]
    return {'referenceSource': manifest['referenceSource'], 'scope': 'synthetic English corpus only',
        'referenceWords': total_words, 'wordErrors': total_errors, 'wer': total_errors/total_words,
        'nonSpeechFalseCues': false_cues, 'scriptedDialogueLinesPresent': sum(bool(l['hypothesis']) for l in dialogue['lines']),
        'scriptedMeaningChecksPassed': sum(l['scriptedMeaningCheck'] is True for l in dialogue['lines']),
        'scriptedMeaningChecksTotal': len(dialogue['lines']),
        'timing': {'reference': 'synthesis speech-clip bounds; not independent human word alignment',
            'medianAbsoluteStartSeconds': statistics.median(starts) if starts else None,
            'maxAbsoluteStartSeconds': max(starts) if starts else None,
            'maxAbsoluteEndSeconds': max(ends) if ends else None},
        'realVideo98PercentVerified': False, 'limits': manifest['limits'], 'cases': cases}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base', type=Path, default=BASE)
    parser.add_argument('--strict', action='store_true', help='Fail on missing lines, false cues, incomplete run or scripted meaning regression')
    args = parser.parse_args()
    result = score(json.loads((args.base/'manifest.json').read_text()), json.loads((args.base/'player-results.json').read_text()))
    (args.base/'quality-summary.json').write_text(json.dumps(result, ensure_ascii=False, indent=2)+'\n')
    print(json.dumps({k: v for k, v in result.items() if k not in ['cases', 'limits']}, ensure_ascii=False, indent=2))
    for case in result['cases']:
        for line in case['lines']:
            if line['scriptedMeaningCheck'] is False or not line['hypothesis']:
                print('REVIEW:', line['reference'], '→', line['hypothesis'], '→', line['translation'])
    if args.strict:
        manifest = json.loads((args.base/'manifest.json').read_text())
        assert {c['id'] for c in result['cases']} == {c['id'] for c in manifest['cases']}, 'Incomplete English run'
        assert result['nonSpeechFalseCues'] == 0, 'Non-speech hallucination'
        assert result['scriptedDialogueLinesPresent'] == result['scriptedMeaningChecksTotal'], 'Missing dialogue line'
        assert result['scriptedMeaningChecksPassed'] == result['scriptedMeaningChecksTotal'], 'Scripted Chinese meaning needs review'


if __name__ == '__main__':
    main()
