"""Prepare local real-video clips and publisher captions, before model inference.

This script does not transcribe, translate, align text with a model, or download
weights. Editorial subtitle timing remains distinct from speech onset timing.
"""
from pathlib import Path
import hashlib
import html
import json
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT/'tools/real-video-evaluation'
SOURCES = BASE/'sources'
INPUTS = BASE/'inputs'
INPUTS.mkdir(parents=True, exist_ok=True)
FFMPEG = '/opt/homebrew/bin/ffmpeg'


def time_value(text):
    parts = text.replace(',', '.').split(':')
    return sum(float(x)*60**i for i, x in enumerate(reversed(parts)))


def captions(path):
    text = path.read_text(encoding='utf-8-sig').replace('\r\n', '\n')
    result = []
    for block in re.split(r'\n\s*\n', text.strip()):
        lines = block.splitlines()
        index = next((i for i, x in enumerate(lines) if '-->' in x), None)
        if index is None:
            continue
        match = re.search(r'([\d:.,]+)\s+-->\s+([\d:.,]+)', lines[index])
        if not match:
            continue
        value = html.unescape(re.sub(r'<[^>]+>', '', ' '.join(lines[index+1:]))).strip()
        if value:
            result.append({'start': time_value(match[1]), 'end': time_value(match[2]), 'text': value,
                           'publisherIndex': lines[0] if index > 0 else str(len(result)+1)})
    return result


def duration(path):
    return float(json.loads(subprocess.check_output(['/opt/homebrew/bin/ffprobe', '-v', 'error',
        '-show_entries', 'format=duration', '-of', 'json', str(path)]))['format']['duration'])


def make_clip(case_id, original, start, end, reference, translated, source, language):
    end = min(end, duration(original))
    target = INPUTS/(case_id+'.mp4')
    if not target.exists():
        subprocess.run([FFMPEG, '-v', 'error', '-nostdin', '-y', '-ss', str(start), '-i', str(original),
            '-t', str(end-start), '-map', '0:v:0', '-map', '0:a:0', '-c:v', 'libx264',
            '-preset', 'veryfast', '-crf', '26', '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-b:a', '96k',
            '-movflags', '+faststart', str(target)], check=True)
    wav = target.with_suffix('.wav')
    subprocess.run([FFMPEG, '-v', 'error', '-nostdin', '-y', '-i', str(target), '-vn',
        '-ac', '1', '-ar', '16000', '-c:a', 'pcm_s16le', str(wav)], check=True)
    rows = []
    for cue in reference:
        # A subtitle whose speech preceded the cut must not become a false
        # "missing line" simply because its editorial display lingers afterward.
        if cue['start'] < start or cue['start'] >= end:
            continue
        candidates = [t for t in translated if t['publisherIndex'] == cue['publisherIndex']]
        zh = candidates[0]['text'] if len(candidates) == 1 else None
        rows.append({**cue, 'start': cue['start']-start, 'end': min(cue['end'],end)-start,
            'endClipped': cue['end'] > end, 'humanChinese': zh})
    reference_path = INPUTS/(case_id+'.reference.json')
    reference_path.write_text(json.dumps({'source': source, 'sourceOffset': start, 'captions': rows}, ensure_ascii=False, indent=2)+'\n')
    return {'id': case_id, 'kind': 'real human performance', 'file': str(target), 'audio': str(wav),
        'language': language, 'duration': duration(target), 'source': source, 'sourceOffset': start,
        'referencePath': str(reference_path), 'reference': ' '.join(c['text'] for c in rows),
        'referenceTiming': 'publisher editorial caption intervals, not human word-onset annotations',
        'captions': rows}


def main():
    cases = []
    for lesson, start, end in [('17',14,82), ('23',15,82), ('25',40,92)]:
        original = BASE/'media'/f'erin{lesson}.mp4'
        source = f'https://www.erin.jpf.go.jp/en/lesson/{lesson}/advanced/'
        cases.append(make_clip(f'erin{lesson}-natural', original, start, end,
            captions(SOURCES/f'erin{lesson}-niho.srt'), captions(SOURCES/f'erin{lesson}-zh.srt'), source, 'ja'))
    manifest = {'referenceSource': 'publisher-authored real human video captions; separate original and Chinese references',
        'modelInput': 'audio and language only; no reference transcript, subtitle times or human Chinese supplied to inference',
        'timingLimitation': 'editorial subtitle display boundaries may include pauses or lead speech; report as caption-reference differences',
        'modelsDownloaded': False, 'cases': cases}
    (BASE/'japanese-manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n')
    english = []
    ted_reference = captions(SOURCES/'ted-en-no-intro.vtt')
    ted_chinese = captions(SOURCES/'ted-zh-no-intro.vtt')
    non_speech = [c for c in ted_reference if re.fullmatch(r'\([^)]*\)', c['text'])]
    spoken = [c for c in ted_reference if c not in non_speech]
    # TED translations have independent cue numbering. Pair only near-identical
    # intervals; do not silently treat matching indices as matching sentences.
    paired = []
    for cue in spoken:
        matches = [c for c in ted_chinese if abs(c['start']-cue['start']) < .15 and abs(c['end']-cue['end']) < .15]
        if len(matches) == 1:
            paired.append({**matches[0], 'publisherIndex': cue['publisherIndex']})
    english.append(make_clip('ted-natural', BASE/'media/ted-first120.mp4', 0, 119.97,
        spoken, paired, 'https://www.ted.com/talks/tim_urban_inside_the_mind_of_a_master_procrastinator', 'en'))
    english[-1]['sourceOffset'] = 3.504
    english[-1]['nonSpeechCaptions'] = [c for c in non_speech if c['start'] < 119.97]
    english[-1]['captionTimebase'] = 'main talk; downloaded clip excludes 3.504-second TED intro'
    for name, offset in [('dialogue',104), ('soft',205)]:
        refs = [{**c,'start':c['start']-offset,'end':c['end']-offset} for c in captions(SOURCES/'sintel-en.srt')]
        english.append(make_clip('sintel-'+name, BASE/f'media/sintel-{name}.mp4', 0, 1000,
            refs, [], 'https://durian.blender.org/wp-content/content/download.html', 'en'))
        english[-1]['sourceOffset'] = offset
        english[-1]['kind'] = 'film with real human voice actors, CG images; not TTS'
        english[-1]['humanChineseAvailable'] = False
    (BASE/'english-manifest.json').write_text(json.dumps({**manifest,'cases':english},ensure_ascii=False,indent=2)+'\n')
    (BASE/'manifest.json').write_text(json.dumps({**manifest,'cases':cases+english},ensure_ascii=False,indent=2)+'\n')
    hashes = [{'path':str(p),'bytes':p.stat().st_size,'sha256':hashlib.sha256(p.read_bytes()).hexdigest()}
        for p in sorted(INPUTS.iterdir()) if p.suffix in ['.mp4','.wav','.json']]
    (BASE/'input-integrity.json').write_text(json.dumps(hashes,indent=2)+'\n')
    print('Prepared',len(cases),'real Japanese clips;',round(sum(c['duration'] for c in cases),2),'seconds')
    print('Prepared',len(english),'real English clips;',round(sum(c['duration'] for c in english),2),'seconds')


if __name__ == '__main__':
    main()
