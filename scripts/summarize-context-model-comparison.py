"""Summarize measured local-model behavior; semantic review is separate from these metrics."""
import json
from pathlib import Path
import statistics

root=Path('tools/real-video-evaluation/qwen35-comparison')
reports={name:json.loads((root/(name+'.json')).read_text()) for name in ['qwen3-4b','qwen35-9b']}
def median(values):
    values=[v for v in values if v is not None]
    return statistics.median(values) if values else None

def summarize(report):
    rows=report['rows']
    unique=[r for r in rows if r['repetition']==1]
    warmup=json.loads(report['warmup'])
    throughputs=[c['outputTokens']/c['decodeSeconds'] for r in rows for c in r['calls'] if c.get('decodeSeconds',0)>0 and c.get('outputTokens')]
    resident=[]
    for row in rows:
        for model in json.loads(row['residentModels']).get('models',[]):
            if model['name']==report['model']: resident.append(model.get('size',0))
    return {
        'model':report['model'],'uniqueCases':len(unique),'measuredRuns':len(rows),
        'validatedRuns':sum(r.get('result') is not None for r in rows),
        'failedRuns':[{'case':r['caseID'],'repeat':r['repetition'],'error':r.get('error')} for r in rows if not r.get('result')],
        'medianWallSecondsAllRuns':median([r['wallSeconds'] for r in rows]),
        'medianWallSecondsUniqueCases':median([r['wallSeconds'] for r in unique]),
        'medianDecodeTokensPerSecond':median(throughputs),
        'totalHTTPRequests':sum(len(r['calls']) for r in rows),
        'runsRequiringRetry':sum(len(r['calls'])>1 for r in rows),
        'generationLimitStops':sum(c.get('doneReason')=='length' for r in rows for c in r['calls']),
        'unexpectedThinkingRuns':sum(c.get('thinkingCharacters',0)>0 for r in rows for c in r['calls']),
        'warmupTotalSeconds':warmup.get('total_duration',0)/1e9,
        'warmupModelLoadSeconds':warmup.get('load_duration',0)/1e9,
        'medianOllamaReportedResidentGB':median([size/1e9 for size in resident]),
        'downloadCompletedAtStart':report['downloadCompletedAtStart'],
    }

paired=[]
a,b=reports.values()
for row in a['rows']:
    candidate=next((r for r in b['rows'] if (r['caseID'],r['repetition'])==(row['caseID'],row['repetition'])),None)
    same=candidate is not None and bool(row['calls']) and bool(candidate['calls']) and row['calls'][0]['inputHash']==candidate['calls'][0]['inputHash']
    paired.append({'case':row['caseID'],'repeat':row['repetition'],'identicalFirstRequestExceptModel':same})
if not all(p['identicalFirstRequestExceptModel'] for p in paired): raise RuntimeError('Paired inputs are not identical')
summary={'models':[summarize(report) for report in reports.values()],'pairedInputs':paired,
 'notes':['Warmup is excluded from per-case wall times; retries remain included.','Ollama resident bytes are model allocations, not whole-system RAM usage.','Token throughput uses each model tokenizer; semantic quality is not derived from throughput or JSON validity.','Only the final timing subset is used for the no-download timing comparison.'], 'semanticAccuracyPercent':None}
if all((root/(name+'-timing.json')).exists() for name in reports):
    timings=[]
    timingReports=[json.loads((root/(name+'-timing.json')).read_text()) for name in reports]
    first, second = timingReports
    controls = []
    for row in first['rows']:
        other = next((r for r in second['rows'] if r['caseID'] == row['caseID']), None)
        same = bool(other and row['calls'] and other['calls'] and row['calls'][0]['inputHash'] == other['calls'][0]['inputHash'])
        if not same: raise RuntimeError('Timing subset inputs differ')
        controls.append({'case': row['caseID'], 'identicalFirstRequestExceptModel': same})
    for value in timingReports:
        if not value['downloadCompletedAtStart']: raise RuntimeError('Timing subset overlapped the download')
        timings.append({'model':value['model'],'medianWallSeconds':median([r['wallSeconds'] for r in value['rows']]),
            'cases':[{'case':r['caseID'],'seconds':r['wallSeconds'],'requests':len(r['calls']),'validated':bool(r.get('result'))} for r in value['rows']]})
    summary['afterDownloadTimingSubset']=timings
    summary['afterDownloadTimingPairedInputs']=controls
(root/'measurement-summary.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2)+'\n')
print(json.dumps(summary,ensure_ascii=False,indent=2))
