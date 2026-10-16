"""Small offline English fixtures; no reference text is embedded in input video.

macOS built-in speech only. These are synthetic regression samples, not evidence
of accuracy on human actors. Does not download voices or model weights.
"""
from pathlib import Path
import array
import json
import math
import random
import subprocess
import wave

BASE = Path(__file__).resolve().parents[1] / 'tools/english-evaluation'
BASE.mkdir(parents=True, exist_ok=True)
RATE = 16000
FFMPEG = '/opt/homebrew/bin/ffmpeg'
LINES = [
    ("Can you send me the report before five?", "能在五点前把报告发给我吗？", 1.0),
    ("Sure. I'll send it this afternoon.", "可以，我今天下午发给你。", 0.02),
    ("I didn't say he stole the money.", "我没说他偷了钱。", 1.0),
    ("Don't spill the beans.", "别泄露秘密。", 1.0),
    ("It's still a secret.", "这件事还需要保密。", 1.0),
    ("I was pulling your leg.", "我刚才是在逗你。", 1.0),
    ("I wasn't serious.", "我不是认真的。", 1.0),
    ("Let's call it a day.", "今天就到这里吧。", 1.0),
    ("We can finish tomorrow.", "我们明天再完成。", 1.0),
    ("I'm feeling under the weather.", "我感觉身体不舒服。", 1.0),
    ("I won't come in today.", "我今天不来上班了。", 1.0),
    ("Could you turn down the music?", "能把音乐调小一点吗？", 1.0),
    ("I can barely hear you.", "我几乎听不清你说话。", 1.0),
    ("It costs fifteen dollars, not fifty.", "价格是十五美元，不是五十美元。", 1.0),
    ("Meet me at half past three.", "三点半和我见面。", 1.0),
]


def silence(seconds):
    return array.array('h', [0]) * round(seconds * RATE)


def speech(text, voice, name):
    aiff = BASE / (name + '.aiff')
    subprocess.run(['/usr/bin/say', '-v', voice, '-r', '160', '-o', str(aiff), text], check=True)
    raw = subprocess.check_output([FFMPEG, '-v', 'error', '-i', str(aiff), '-f', 's16le', '-ar', str(RATE), '-ac', '1', '-'])
    samples = array.array('h'); samples.frombytes(raw)
    threshold = max(30, max(map(abs, samples)) * 0.008)
    active = [i for i, value in enumerate(samples) if abs(value) > threshold]
    assert active, 'Voice produced no speech'
    return samples[max(0, active[0]-320):min(len(samples), active[-1]+321)]


def write_case(name, audio, lines):
    wav = BASE / (name + '.wav')
    with wave.open(str(wav), 'wb') as f:
        f.setnchannels(1); f.setsampwidth(2); f.setframerate(RATE); f.writeframes(audio.tobytes())
    video = BASE / (name + '.mp4')
    subprocess.run([FFMPEG, '-v', 'error', '-nostdin', '-y', '-f', 'lavfi', '-i',
                    'color=c=0x18202b:s=960x540:r=25', '-i', str(wav), '-shortest',
                    '-c:v', 'libx264', '-preset', 'ultrafast', '-crf', '30', '-pix_fmt',
                    'yuv420p', '-c:a', 'aac', '-b:a', '128k', '-t', str(len(audio)/RATE), str(video)], check=True)
    return {'id': name, 'video': str(video), 'audio': str(wav), 'duration': len(audio)/RATE,
            'language': 'en', 'lines': lines, 'reference': ' '.join(x['text'] for x in lines)}


audio = silence(2)
references = []
quiet_source = None
for i, (text, meaning, gain) in enumerate(LINES):
    voice = 'Samantha' if i % 2 == 0 else 'Daniel'
    samples = speech(text, voice, f'voice-{i+1:02}')
    if gain < 1:
        quiet_source = samples
    samples = array.array('h', (round(x * gain) for x in samples))
    start = len(audio)/RATE
    audio.extend(samples)
    references.append({'text': text, 'intendedChinese': meaning, 'start': start,
                       'end': len(audio)/RATE, 'voice': voice, 'gain': gain})
    audio.extend(silence(4 if i == 6 else 1.1))
audio.extend(silence(2))
cases = [write_case('english-dialogue', audio, references)]
quiet_text, quiet_meaning, _ = LINES[1]
for name, gain in [('english-normal', 1.0), ('english-quiet', 0.02)]:
    samples = array.array('h', (round(x * gain) for x in quiet_source))
    clip = silence(1) + samples + silence(1)
    cases.append(write_case(name, clip, [{'text': quiet_text, 'intendedChinese': quiet_meaning,
        'start': 1, 'end': 1+len(samples)/RATE, 'voice': 'Daniel', 'gain': gain}]))
cases.append(write_case('english-silence', silence(6), []))
tones = array.array('h', (round(1500*math.sin(2*math.pi*440*i/RATE)) for i in range(6*RATE)))
cases.append(write_case('english-tone-only', tones, []))
rng = random.Random(20261014)
noise = array.array('h', (round(rng.uniform(-1800,1800)) for _ in range(6*RATE)))
cases.append(write_case('english-noise-only', noise, []))
manifest = {'referenceSource': 'synthetic macOS TTS; script held apart from inference',
    'sourceTextNotEmbeddedInVideo': True, 'newModelDownloads': False,
    'limits': ['not human speech, overlapping actors or naturally whispered speech',
               'timing references are synthesis clip boundaries, not human word alignments',
               'intended Chinese is a scripted expectation, not independent human acceptance'],
    'cases': cases}
(BASE / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2)+'\n')
print(f'Generated {len(cases)} local English fixtures; dialogue {len(audio)/RATE:.2f}s; models unchanged')
