"""Regression against fixed audio fixtures: quiet speech stays; static tones go."""
import importlib.util
from pathlib import Path
import socket
import soundfile as sf

spec = importlib.util.spec_from_file_location('worker','scripts/local-qwen-asr.py')
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)
root = Path('tools/wavesubs-evaluation/candidate-inputs')
for name in ['speech-normal','speech-quiet','speech-separated','dialogue-normalized','silence','music-tones']:
    audio, rate = sf.read(root/(name+'.wav'),dtype='float32')
    assert worker.stationary_tone(audio,rate) == (name == 'music-tones'),name
with socket.socket() as connection:
    try:
        connection.connect(('127.0.0.1',9))
        raise AssertionError('ASR network guard failed')
    except RuntimeError as error:
        assert 'forbids network' in str(error)
print('PASS: quiet/mixed speech retained, stationary tones rejected, ASR network connections blocked')
