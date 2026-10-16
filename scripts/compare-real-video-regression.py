"""Compare the untouched human-caption corpus with v8. No reference is model input.

Meaning checks here are targeted regression tripwires, NOT a semantic accuracy score.
"""
import json
from pathlib import Path
import re
import statistics

BASE = Path(__file__).resolve().parents[1]/'tools/real-video-evaluation'


def main():
    baseline = json.loads((BASE/'baseline-v8/quality-summary.json').read_text())
    current = json.loads((BASE/'quality-summary.json').read_text())
    asr = json.loads((BASE/'asr-results.json').read_text())
    translated = json.loads((BASE/'translation-results.json').read_text())
    targets = json.loads((BASE/'translation-targets.json').read_text())
    previous = {c['id']:c for c in baseline['cases']}
    assert len(asr['cases']) == 6 and all(c['status']=='completed' for c in asr['cases'])
    selected = {(c['id'],i) for c in asr['cases'] for i,cue in enumerate(c['cues'])
        if any(cue['start'] < b and cue['end'] > a for target in targets['cases'] if target['id']==c['id'] for a,b in target['ranges'])}
    assert selected == {(c['id'],c['cueIndex']) for c in translated['cues']}, 'Missing/duplicate selected translation'
    comparisons = []
    for case in current['cases']:
        old = previous[case['id']]
        old_rows = {r['publisherIndex']:r for r in old['lines']}
        pairs = [(old_rows[r['publisherIndex']],r) for r in case['lines']
            if r['captionStartDifferenceSeconds'] is not None and old_rows[r['publisherIndex']]['captionStartDifferenceSeconds'] is not None]
        comparisons.append({'id':case['id'],'metric':case['metric'],'beforeErrorRate':old['errorRate'],'afterErrorRate':case['errorRate'],
            'referenceUnits':case['referenceUnits'],'beforeEditErrors':old['editErrors'],'afterEditErrors':case['editErrors'],
            'beforeCueCount':old['cueCount'],'afterCueCount':case['cueCount'],
            'sameCaptionTimingRows':len(pairs),
            'beforeMaxStartDifferenceOnCommonRows':max((abs(a['captionStartDifferenceSeconds']) for a,b in pairs),default=None),
            'afterMaxStartDifferenceOnCommonRows':max((abs(b['captionStartDifferenceSeconds']) for a,b in pairs),default=None)})
    clips = {c['id']:c for c in asr['cases']}
    summaries = {c['id']:c for c in current['cases']}
    rows = translated['cues']
    def matching(case,needle):
        return [r for r in rows if r['id']==case and needle.lower() in r['text'].lower()]
    checks = {}
    quiet = matching('sintel-soft','good night')
    checks['quietSentenceNoPrematureDisplay'] = bool(quiet and all(22<r['start']<24.5 and r['end']-r['start']<3 for r in quiet))
    checks['quietAddressPreserved'] = bool(quiet and all('晚安' in r['translation'] and not any(x in r['translation'] for x in ['各位','大家','你们']) for r in quiet))
    checks['quietEnglishAuxiliaryRecovered'] = any("we're" in c['text'].lower() or 'we are' in c['text'].lower() for c in clips['sintel-soft']['cues'])
    phrase = next(r for r in summaries['erin23-natural']['lines'] if 'そうだっけ' in r['text'])
    checks['shortJapaneseNoEightSecondInternalGap'] = phrase['matchedTokenFraction'] >= .9 and phrase['maxGapInsideMatchedLineSeconds'] < 1
    uncertain = [r for r in rows if r['id']=='erin23-natural' and r['start']>61]
    checks['unresolvedQuietJapaneseNotInventedChinese'] = bool(uncertain and all(r['modelUsed']=='unresolved-source' and r.get('warning') for r in uncertain))
    negative = [c for c in clips['erin17-natural']['cues'] if '驚いた' in c['text']]
    checks['negativeReplyReviewedAndVisible'] = bool(negative and negative[0]['text'].startswith('ううん') and negative[0].get('recognitionWarning'))
    accompany = matching('erin23-natural','付き合')
    checks['accompanyingNotMistakenForDating'] = bool(accompany and all(not any(w in c['translation'] for w in ['交往','约会','谈恋爱']) for c in accompany))
    retort = matching('erin25-natural','私のセリフ')
    checks['retortSpeakerPreserved'] = bool(retort and all('我' in r['translation'] for r in retort))
    gear = matching('ted-natural','high gear')
    checks['figurativeIntensityNotGearbox'] = bool(gear and all(any(w in r['translation'] for w in ['强度','全力','加速','加紧','加大']) and not any(w in r['translation'] for w in ['高速档','高速挡']) for r in gear))
    nights = [r for r in matching('ted-natural','all-nighters') if 'not one' in r['text']]
    checks['wholeNightSentenceNoFutureJudgement'] = bool(nights and all('通宵' in r['translation'] and not any(w in r['translation'] for w in ['不应该','不应当','不要熬']) for r in nights))
    checks['ordinaryEnglishNoWordRegression'] = summaries['sintel-dialogue']['editErrors'] <= previous['sintel-dialogue']['editErrors']
    checks['allSelectedRequestsFinished'] = all(r['status']=='completed' for r in rows)
    result = {'method':'Same real videos, publisher captions and fixed stress ranges; v8 retained. Timing maxima use only the same reference rows comparable in BOTH versions.',
        'limits':['Word/character edit rates include editorial spelling differences; no semantic accuracy percentage.',
            'Timing is relative to publisher editorial subtitles, not independently annotated human speech onsets.',
            'Recognition confidence is an acoustic-reading agreement heuristic, not a calibrated probability.',
            'Unresolved-source placeholders are explicitly NOT counted as successful translations.',
            'This is a development regression corpus, not held-out generalization evidence or 98% acceptance.'],
        'cloudInferenceUsed':False,'newModelDownloads':False,'realVideo98PercentVerified':False,
        'selectedCueCount':len(rows),'translatedCueCount':sum(r.get('sourceResolved',True) for r in rows),
        'unresolvedCueCount':sum(not r.get('sourceResolved',True) for r in rows),
        'targetedRegressionChecks':checks,'comparisons':comparisons}
    (BASE/'regression-comparison.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
    for check,passed in checks.items(): print(('PASS' if passed else 'FAIL')+': '+check)
    assert all(checks.values()), 'Real-video regression unresolved; inspect regression-comparison.json'


if __name__ == '__main__': main()
