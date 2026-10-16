"""Export exact publisher/generated subtitles after inference, including failures."""
import json
from pathlib import Path

BASE = Path(__file__).resolve().parents[1]/'tools/real-video-evaluation'


def timestamp(seconds):
    ms = round(seconds*1000)
    return f'{ms//3600000:02}:{ms//60000%60:02}:{ms//1000%60:02},{ms%1000:03}'


def save_srt(path, cues):
    entries = [f"{i}\n{timestamp(c['start'])} --> {timestamp(c['end'])}\n{c['text']}\n" for i,c in enumerate(cues,1)]
    path.write_text('\n'.join(entries),encoding='utf-8')


def main():
    refs = json.loads((BASE/'manifest.json').read_text())['cases']
    actual = json.loads((BASE/'asr-results.json').read_text())['cases']
    translations = json.loads((BASE/'translation-results.json').read_text())['cues']
    output = BASE/'review'; output.mkdir(exist_ok=True)
    index = []
    for ref in refs:
        item = next(c for c in actual if c['id'] == ref['id'])
        save_srt(output/(ref['id']+'.publisher.srt'),ref['captions'])
        save_srt(output/(ref['id']+'.recognized.srt'),item['cues'])
        translated = [t for t in translations if t['id'] == ref['id'] and t['status'] == 'completed']
        save_srt(output/(ref['id']+'.selected-bilingual.srt'),
            [{**t,'text':t['text']+'\n'+t['translation']} for t in translated])
        comparisons = []
        boundaries = sorted({0,ref['duration']} | {r[k] for r in ref['captions']+item['cues'] for k in ['start','end']})
        for start,end in zip(boundaries,boundaries[1:]):
            mid = (start+end)/2
            gold = [c['text'] for c in ref['captions'] if c['start'] <= mid < c['end']]
            shown = [('（待核对候选）' if c.get('recognitionConfidence',1)<.45 and c.get('recognitionWarning') else '')+c['text'] for c in item['cues'] if c['start'] <= mid < c['end']]
            chinese = [c['translation'] for c in translated if c['start'] <= mid < c['end']]
            if not gold and not shown: continue
            text = '人工字幕：'+(' '.join(gold) or '（无字幕）')+'\n本地识别：'+(' '.join(shown) or '（无字幕）')
            if chinese: text += '\n本地译文：'+' '.join(chinese)
            comparisons.append({'start':start,'end':end,'text':text})
        save_srt(output/(ref['id']+'.comparison.srt'),comparisons)
        index.append({'id':ref['id'],'video':ref['file'],'source':ref['source'],'recognitionStatus':item['status'],
            'translationCuesSelected':len(translated),'totalASRCues':len(item['cues']),
            'translationCoverage':'selected stress cues only; omitted Chinese means untested, not translation failure',
            'comparisonSubtitle':str(output/(ref['id']+'.comparison.srt'))})
    (output/'index.json').write_text(json.dumps(index,ensure_ascii=False,indent=2)+'\n')
    print('Exported publisher/recognized/selected bilingual/comparison SRT for',len(index),'real clips')


if __name__ == '__main__': main()
