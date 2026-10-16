"""Validate pinned downloaded weights and tokenizer/config bytes before local loading."""
import hashlib,json
from pathlib import Path
root=Path('tools/audio-candidates/qwen2-audio-7b-instruct-4bit')
m=json.loads((root/'download-manifest.json').read_text())
assert m['sha']=='c65570002626f41b4dc08b7b54f42f99f3e82e7f'
rows=[]
for item in m['siblings']:
 name=item['rfilename']
 if name in ['.gitattributes','README.md']: continue
 assert not Path(name).is_absolute() and '..' not in Path(name).parts
 target=root/name;source=target if target.exists() else root/(name+'.part')
 assert source.stat().st_size==item['size'],f'Incomplete file: {name}'
 h=hashlib.sha256() if item.get('lfs') else hashlib.sha1()
 if not item.get('lfs'): h.update(f'blob {item["size"]}\0'.encode())
 with source.open('rb') as stream:
  while chunk:=stream.read(8*1024*1024):h.update(chunk)
 expected=item['lfs']['sha256'] if item.get('lfs') else item['blobId']
 assert h.hexdigest()==expected,f'Checksum mismatch: {name}'
 if source!=target: source.replace(target)
 rows.append(dict(name=name,bytes=item['size'],hash=h.hexdigest(),verified=True))
(root/'verification.json').write_text(json.dumps(dict(revision=m['sha'],files=rows,totalBytes=sum(x['bytes'] for x in rows)),indent=2))
print('Verified pinned model, weights SHA256, configs Git SHA1:',sum(x['bytes'] for x in rows),'bytes')
