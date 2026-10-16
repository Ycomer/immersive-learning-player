"""Export review materials only after local inference; do not alter model output."""
import json
from pathlib import Path
import subprocess
import sys

BASE = Path(__file__).resolve().parents[1] / 'tools/english-evaluation'
manifest = json.loads((BASE/'manifest.json').read_text())
results = json.loads((BASE/'player-results.json').read_text())
reference = next(c for c in manifest['cases'] if c['id'] == 'english-dialogue')
actual = next(c for c in results['cases'] if c['id'] == 'english-dialogue')
assert actual['displayChecks'] == len(actual['cues']) and actual['cacheReused'], 'Cannot export an incomplete test as a completed review video'
(BASE/'dialogue-reference.json').write_text(json.dumps(reference, ensure_ascii=False, indent=2)+'\n')
converted = {'cues': [{**cue, 'startMs': round(cue['start']*1000), 'endMs': round(cue['end']*1000)} for cue in actual['cues']]}
(BASE/'dialogue-actual.json').write_text(json.dumps(converted, ensure_ascii=False, indent=2)+'\n')


def timestamp(seconds):
    millis = round(seconds*1000)
    return f'{millis//3600000:02}:{millis//60000%60:02}:{millis//1000%60:02},{millis%1000:03}'


for suffix in ['en', 'zh', 'bilingual']:
    entries = []
    for i, cue in enumerate(actual['cues'], 1):
        text = cue['text'] if suffix == 'en' else cue['translation'] if suffix == 'zh' else cue['text']+'\n'+cue['translation']
        entries.append(f"{i}\n{timestamp(cue['start'])} --> {timestamp(cue['end'])}\n{text}\n")
    (BASE/f'english-dialogue.{suffix}.srt').write_text('\n'.join(entries))
print('Exported English/Chinese/bilingual SRT and unchanged comparison outputs')
if '--render' in sys.argv:
    root = BASE.parents[1]
    renderer = root/'build/render-subs-comparison'
    subprocess.run(['swiftc', '-module-cache-path', str(root/'build/ModuleCache'),
        str(root/'scripts/RenderWaveSubsComparison.swift'), '-o', str(renderer)], check=True)
    subprocess.run([str(renderer), 'dialogue-actual.json', 'comparison-frames',
        'Qwen3-ASR + 时间对齐 / TranslateGemma + 本地备用', 'dialogue-reference.json',
        'tools/english-evaluation'], cwd=root, check=True)
    subprocess.run(['/opt/homebrew/bin/ffmpeg', '-v', 'error', '-nostdin', '-y',
        '-f', 'concat', '-safe', '0', '-i', str(BASE/'comparison-frames/frames.ffconcat'),
        '-i', str(BASE/'english-dialogue.wav'), '-vf',
        f"fps=25,tpad=stop_mode=clone:stop_duration={reference['duration']}",
        '-c:v', 'libx264', '-preset', 'fast', '-crf', '22', '-pix_fmt', 'yuv420p',
        '-c:a', 'aac', '-b:a', '128k', '-movflags', '+faststart', '-t',
        str(reference['duration']), str(BASE/'english-dialogue-comparison.mp4')], check=True)
    print('Rendered full-length English comparison video')
