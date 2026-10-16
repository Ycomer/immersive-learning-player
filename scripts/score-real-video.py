"""Post-inference audit against publisher human captions; never supplies model input."""
from pathlib import Path
import difflib
import importlib.util
import json
import re
import statistics
import unicodedata

BASE = Path(__file__).resolve().parents[1]/'tools/real-video-evaluation'
spec = importlib.util.spec_from_file_location('metric',Path(__file__).with_name('score-asr.py'))
metric = importlib.util.module_from_spec(spec); spec.loader.exec_module(metric)


def units(text, language):
    text = unicodedata.normalize('NFKC',text).lower().replace('’',"'")
    if language == 'en':
        return re.findall(r"[a-z]+(?:'[a-z]+)?|\d+",text)
    return [c for c in text if unicodedata.category(c)[0] in 'LNM']


def assess(reference, actual):
    lang = reference['language']
    rows, expected, owners = reference['captions'], [], []
    for i,row in enumerate(rows):
        tokens = units(row['text'],lang)
        expected.extend(tokens); owners.extend([i]*len(tokens))
    hypothesis, locations, within = [], [], []
    for i,cue in enumerate(actual['cues']):
        tokens = units(cue['text'],lang)
        hypothesis.extend(tokens); locations.extend([i]*len(tokens)); within.extend(range(len(tokens)))
    # Text matching is performed BEFORE consulting either timeline, so a bad
    # timestamp cannot make a missing line appear correctly synchronized.
    mapping = {}
    for block in difflib.SequenceMatcher(None,expected,hypothesis,autojunk=False).get_matching_blocks():
        for delta in range(block.size): mapping[block.a+delta] = block.b+delta
    cursor, lines, starts = 0, [], []
    for i,row in enumerate(rows):
        tokens = units(row['text'],lang)
        matched = [(j,mapping[j]) for j in range(cursor,cursor+len(tokens)) if j in mapping]
        indices = sorted({locations[h] for _,h in matched})
        cues = [actual['cues'][j] for j in indices]
        coverage = len(matched)/len(tokens) if tokens else 0
        anchored = bool(matched and coverage >= .65 and len(tokens) >= 3
            and matched[0][0]-cursor <= 1 and within[matched[0][1]] <= 1)
        start_delta = cues[0]['start']-row['start'] if anchored else None
        if start_delta is not None: starts.append(abs(start_delta))
        lines.append({**row,'matchedTokenFraction':coverage,'matchedCueIndices':indices,
            'hypothesis':' '.join(c['text'] for c in cues),
            'captionStartDifferenceSeconds':start_delta,
            'maxGapInsideMatchedLineSeconds':max([b['start']-a['end'] for a,b in zip(cues,cues[1:])]+[0]),
            'firstMatchedStart':cues[0]['start'] if cues else None,
            'lastMatchedEnd':cues[-1]['end'] if cues else None})
        cursor += len(tokens)
    errors = metric.distance(expected,hypothesis)
    return {'id':actual['id'],'status':actual['status'],'metric':'WER' if lang == 'en' else 'strict character CER',
        'referenceUnits':len(expected),'editErrors':errors,'errorRate':errors/len(expected) if expected else None,
        'processingSeconds':actual['processingSeconds'],'audioSeconds':actual['audioSeconds'],
        'cueCount':len(actual['cues']),'captionRows':len(rows),'timingComparedRows':len(starts),
        'medianAbsoluteCaptionStartDifferenceSeconds':statistics.median(starts) if starts else None,
        'maxAbsoluteCaptionStartDifferenceSeconds':max(starts) if starts else None,'lines':lines}


def main():
    manifest = json.loads((BASE/'manifest.json').read_text())
    actual = json.loads((BASE/'asr-results.json').read_text())
    refs = {c['id']:c for c in manifest['cases']}
    assert len(actual['cases']) == len(refs) and {c['id'] for c in actual['cases']} == set(refs), 'Incomplete/duplicate corpus output; missing cases cannot be omitted'
    scored = [assess(refs[c['id']],c) for c in actual['cases']]
    result = {'method':'existing local models; real human video and publisher-authored captions; audio-only model input',
        'limits':['Japanese CER counts kana/kanji spelling variants as errors; it is not semantic accuracy.',
            'English WER is literal and counts caption edits, numeric spelling and contraction variants.',
            'Timing differences are against editorial caption starts, not independently annotated human speech onsets.',
            'Text-matched timing excludes weak matches and anchors inside a shared cue; coverage is reported.',
            'Quiet film has music/foley; low amplitude alone cannot establish whether each voice is whispered.',
            'No general 98% transcription or Chinese semantic accuracy has been established.'],
        'realVideo98PercentVerified':False,'sourceURLs':list(dict.fromkeys(c['source'] for c in manifest['cases'])),
        'audioSeconds':sum(c['audioSeconds'] for c in scored),'cases':scored}
    (BASE/'quality-summary.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
    for c in scored:
        print(f"{c['id']}: {c['status']}, {c['metric']}={c['errorRate']:.1%} ({c['editErrors']}/{c['referenceUnits']}), caption timing max={c['maxAbsoluteCaptionStartDifferenceSeconds']}")


if __name__ == '__main__': main()
