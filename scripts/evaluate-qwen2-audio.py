"""Direct audio transcription/translation, fixed local weights, outbound sockets forbidden."""
import os
os.environ.update(HF_HUB_OFFLINE='1',TRANSFORMERS_OFFLINE='1',HF_HUB_DISABLE_TELEMETRY='1')
import argparse,json,sys,time
from pathlib import Path

def offline(event,args):
 if event=='socket.connect': raise RuntimeError('Audio evaluation forbids network connections')
sys.addaudithook(offline)
from mlx_audio.stt import load
import mlx.core as mx
p=argparse.ArgumentParser();p.add_argument('--id');p.add_argument('--stock',action='store_true');p.add_argument('--context-only',action='store_true');args=p.parse_args()
root=Path('tools/real-video-evaluation/qwen2-audio-comparison')
start=time.monotonic();model=load(str(Path('tools/audio-candidates/qwen2-audio-7b-instruct-4bit').resolve()))
# Keep this benchmark adapter isolated from the player's ASR dependency. Match
# the official Whisper feature extractor and valid-frame audio attention. The
# installed MLX port uses HTK mel filters and casts projected audio to packed
# quantized embedding weight dtype; neither matches the official HF pipeline.
if not args.stock:
 import numpy as np
 import mlx.nn as nn
 valid_length=[0]
 def official_features(audio):
  batch=model._processor.feature_extractor(np.asarray(audio),sampling_rate=16000,return_attention_mask=True,return_tensors='np')
  frames=int(batch.attention_mask[0].sum())
  valid_length[0]=(frames-1)//2+1
  tokens=(valid_length[0]-2)//2+1
  return mx.array(batch.input_features,dtype=model.audio_tower.conv1.weight.dtype),tokens
 def official_audio_features(features):
  enc=model.audio_tower
  x=nn.gelu(enc.conv1(features.transpose(0,2,1)))
  x=nn.gelu(enc.conv2(x))[:,:valid_length[0]]
  x=x+enc.embed_positions[:x.shape[1]]
  for layer in enc.layers:x=layer(x)
  b,t,d=x.shape
  x=x[:,:t//2*2].reshape(b,t//2,2,d).mean(axis=2)
  return model.multi_modal_projector(enc.layer_norm(x))
 model._extract_features=official_features
 model.get_audio_features=official_audio_features
report=dict(model='Qwen2-Audio-7B-Instruct-4bit',frontend='stock-mlx' if args.stock else 'official-feature-extractor-valid-frame-attention-float-audio',outboundSocketsForbidden=True,loadSeconds=time.monotonic()-start,cases=[])
for c in json.loads((root/'inputs.json').read_text())['cases']:
 if args.id and c['id']!=args.id: continue
 if args.context_only and not c['id'].startswith('context-'): continue
 if not args.context_only and not args.id and c['id'].startswith('context-'): continue
 row=dict(c)
 lang='Japanese' if c['language']=='ja' else 'English'
 for task,prompt in [('transcription',f'Transcribe the {lang} speech verbatim in {lang}. Output only the spoken words, without explanation.'),('translation',f'Translate ALL the spoken {lang} dialogue in this audio into natural Simplified Chinese. Do not omit any utterance. Preserve the meaning and tone. Output only the Chinese translation, without explanation.')]:
  start=time.monotonic()
  result=model.generate(c['audio'],prompt=prompt,temperature=0,max_tokens=256,verbose=False)
  row[task]=dict(text=result.text,seconds=time.monotonic()-start,tokens=result.generation_tokens)
  print(c['id'],task,row[task],flush=True);mx.clear_cache()
 report['cases'].append(row);report['peakMemoryBytes']=mx.get_peak_memory()
 (root/('qwen2-results'+('-context' if args.context_only else '')+('-stock' if args.stock else '')+('-'+args.id if args.id else '')+'.json')).write_text(json.dumps(report,ensure_ascii=False,indent=2))
