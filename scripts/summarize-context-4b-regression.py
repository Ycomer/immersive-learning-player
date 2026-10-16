"""Compare fixed real inputs and measured behavior; do not infer semantic accuracy."""
import json
from pathlib import Path
import statistics

root = Path('tools/real-video-evaluation')
before = json.loads((root/'qwen35-comparison/qwen3-4b.json').read_text())
after = json.loads((root/'context-4b-regression/qwen3-4b.json').read_text())
recheck = root/'context-4b-regression/qwen3-4b-case-en-quiet-clip-context.json'
if recheck.exists():
    extra = json.loads(recheck.read_text())
    for updated in extra['rows']:
        index = next(i for i,r in enumerate(after['rows']) if (r['caseID'],r['repetition']) == (updated['caseID'],updated['repetition']))
        after['rows'][index] = updated
replay = root/'context-4b-regression/final-output-replay.json'
if replay.exists():
    outputs = {(r['caseID'], r['repetition']): r for r in json.loads(replay.read_text())['rows']}
    for row in after['rows']:
        output = outputs[(row['caseID'], row['repetition'])]
        row['result'] = output.get('result'); row['error'] = output.get('error')
assert len(after['rows']) == 20, 'Final real-model regression is incomplete'
assert after['model'] == before['model'] == 'qwen3:4b-instruct'
cases = {c['id']: c for c in after['cases']}
for old in before['cases']:
    new = cases[old['id']]
    for key in ['lines', 'selection', 'comparison', 'language', 'clip']:
        assert old.get(key) == new.get(key), (old['id'], key)
pairs = {(r['caseID'], r['repetition']) for r in before['rows']}
paired = [r for r in after['rows'] if (r['caseID'], r['repetition']) in pairs]
assert len(paired) == len(before['rows'])

def measured(rows):
    return {
        'runs': len(rows),
        'validatedResults': sum(r.get('result') is not None for r in rows),
        'labelledReferenceFallbacks': sum(bool(r.get('result',{}).get('referenceOnly')) for r in rows if r.get('result')),
        'failures': [{'case':r['caseID'], 'repeat':r['repetition'], 'error':r.get('error')} for r in rows if r.get('result') is None],
        'medianWallSeconds': statistics.median(r['wallSeconds'] for r in rows),
        'httpAttempts': sum(len(r['calls']) for r in rows),
        'retries': sum(len(r['calls']) > 1 for r in rows),
    }

comparisons = []
for row in after['rows']:
    case = cases[row['caseID']]
    if case.get('comparison') and row.get('result'):
        word = row['result']['words'][0]
        comparisons.append({'case':row['caseID'], 'repeat':row['repetition'], 'requested':case['comparison'], 'actual':word.get('replacement'), 'verdict':word.get('replacementFit')})
report = {
    'model':after['model'], 'revision':'context-learning-v3-grounded-comparison',
    'actualModelRechecks':[str(recheck)] if recheck.exists() else [],
    'baseline':measured(before['rows']), 'sameScenarioRegression':measured(paired),
    'allRegression':measured(after['rows']),
    'sameASRWindowsAndSelectionsVerified':True,
    'explicitComparisonsReturned':comparisons,
    'additionalCases':[c['id'] for c in after['cases'] if c['id'] not in {b['id'] for b in before['cases']}],
    'notes':[
        'JSON/content validation success is not a semantic accuracy percentage.',
        'Main production service and existing local 4B; no reference captions or review points in model prompts.',
        'Prompt/schema and ordinary dictionary/grammar hints changed; this is a same-corpus engineering regression, not an unseen benchmark.',
        'Additional scenarios were also inspected during tuning; their holdout IDs do not imply that final outputs are from an unseen evaluation.',
        'Wall times include bounded retries. The historical baseline overlapped a model download and is not a controlled speed comparison.',
        'Source ASR/timestamps and subtitle translation engine are unchanged; this evaluates optional context learning.',
        'Reference fallback results are local dictionary/grammar rules, explicitly labelled in the player and counted separately from model explanations.',
        'The evidence-only final correction is checked by replaying recorded replies through the final production source; no additional model/network requests in that replay.',
    ],
    'semanticAccuracyPercent':None,
}
(root/'context-4b-regression/measurement-summary.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
print(json.dumps(report,ensure_ascii=False,indent=2))
