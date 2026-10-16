"""Generate local Japanese dialogue with known script and acoustic boundaries.

No subtitle/reference text is embedded in the input video. References are kept
separately and never supplied to the transcription or translation model.
"""
from pathlib import Path
import array
import json
import subprocess
import wave

base = Path(__file__).resolve().parents[1] / 'tools/wavesubs-evaluation'
fixtures = base / 'fixtures/dialogue'
fixtures.mkdir(parents=True, exist_ok=True)
ffmpeg = '/opt/homebrew/bin/ffmpeg'
lines = [
    ('明日の会議、来られそう？', '明天的会议能来吗？'),
    ('ちょっと厳しいかも。今日は朝から手が離せなくて。', '可能有点困难。今天从早上起就忙得脱不开身。'),
    ('じゃあ、資料だけ先に送ってもらえる？', '那能先把资料发给我吗？'),
    ('わかった。夕方までには送るよ。', '知道了，傍晚之前发给你。'),
    ('ところで、田中さんって顔が広いよね。', '说起来，田中的人脉很广呢。'),
    ('うん。でも、部長の前では猫をかぶってる。', '嗯，不过他在部长面前装乖。'),
    ('この前の失敗は、もう水に流そう。', '之前那次失误就既往不咎吧。'),
    ('そうだね。余計なことを言うと、火に油を注ぐだけだし。', '是啊，再多说什么只会火上浇油。'),
    ('コーヒー、もう一杯どう？', '咖啡再来一杯怎么样？'),
    ('ありがとう。でも、もういいです。お腹がいっぱいなので。', '谢谢，不过不用了，我已经饱了。'),
    ('それじゃ、また明日。', '那明天见。'),
    ('うん、お疲れさま。', '嗯，辛苦了。'),
]
sr = 16000
audio = array.array('h', [0]) * (3 * sr)
reference = []
for i, (ja, zh) in enumerate(lines):
    voice = 'Kyoko' if i % 2 == 0 else 'Reed (Japanese (Japan))'
    aiff = fixtures / f'{i+1:02}.aiff'
    subprocess.run(['/usr/bin/say', '-v', voice, '-r', '165', '-o', str(aiff), ja], check=True)
    raw = subprocess.check_output([ffmpeg, '-v', 'error', '-i', str(aiff), '-f', 's16le', '-ar', str(sr), '-ac', '1', '-'])
    samples = array.array('h'); samples.frombytes(raw)
    # Trim only the voice engine's leading/trailing silence, not internal pauses.
    threshold = max(30, max(map(abs, samples)) * 0.008)
    active = [j for j, value in enumerate(samples) if abs(value) > threshold]
    samples = samples[max(0, active[0]-320):min(len(samples), active[-1]+321)]
    gain = 0.02 if i == 3 else 1.0
    samples = array.array('h', (round(x * gain) for x in samples))
    start = len(audio) / sr
    audio.extend(samples)
    reference.append({'index': i+1, 'start': start, 'end': len(audio)/sr,
                      'ja': ja, 'intendedChinese': zh, 'voice': voice, 'gain': gain})
    audio.extend(array.array('h', [0]) * round(sr * (6 if i == 5 else 1.2)))
audio.extend(array.array('h', [0]) * (3 * sr))
wav = fixtures / 'dialogue.wav'
with wave.open(str(wav), 'wb') as f:
    f.setnchannels(1); f.setsampwidth(2); f.setframerate(sr); f.writeframes(audio.tobytes())
video = base / 'inputs/generated-dialogue.mp4'
subprocess.run([ffmpeg, '-v', 'error', '-nostdin', '-y', '-f', 'lavfi', '-i',
                'color=c=0x18202b:s=960x540:r=25', '-i', str(wav), '-shortest',
                '-c:v', 'libx264', '-preset', 'ultrafast', '-crf', '30', '-pix_fmt',
                'yuv420p', '-c:a', 'aac', '-b:a', '128k', str(video)], check=True)
(base / 'dialogue-reference.json').write_text(json.dumps({
    'kind': 'synthetic; scripted intended meanings, not an independent human translation assessment',
    'sourceTextNotEmbeddedInVideo': True, 'duration': len(audio)/sr, 'lines': reference,
}, ensure_ascii=False, indent=2))
manifest_path = base / 'evaluation-manifest.json'
manifest = json.loads(manifest_path.read_text())
manifest['cases'] = [c for c in manifest['cases'] if c['id'] != 'generated-dialogue']
manifest['cases'].append({'id': 'generated-dialogue', 'kind': 'synthetic',
    'file': str(video), 'reference': ''.join(ja for ja, _ in lines), 'duration': len(audio)/sr})
manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2))
print('Generated', video, 'duration', len(audio)/sr, 'seconds; 12 dialogue lines')
