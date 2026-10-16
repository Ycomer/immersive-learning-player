"""Regress independent acoustic ownership, long silence and safe additions."""
import importlib.util

spec = importlib.util.spec_from_file_location('worker','scripts/local-qwen-asr.py')
worker = importlib.util.module_from_spec(spec);spec.loader.exec_module(worker)

def probes(rows):
    return [{'start':a,'end':b,'text':t} for a,b,t in rows]

text = 'Hey, almost done. Hey, sit still. Good night, Scales.'
p = probes([(1,4,"Hey, shh. We're almost done."),(5,7,'Hey, sit still.'),(10,11,'Hmm.'),(13,14,'Hmm.'),(23,25,'Nightscapes.')])
groups,_ = worker.assign_sentences(text,p)
assert ''.join(groups) == text
assert 'Good night' in groups[-1] and not groups[2] and not groups[3]
text = 'そうだっけ。あ。'
groups,_ = worker.assign_sentences(text,probes([(13,15,'そうだっけ。'),(22,23,'あ。')]))
assert groups == ['そうだっけ。','あ。']
text = 'それからサキと健太くんも仲良くね。'
groups,_ = worker.assign_sentences(text,probes([(36,38,'それからサキと'),(39,41,'健太くんも'),(41.5,43,'仲良くね。')]))
assert ''.join(groups) == text and groups[0].startswith('それから') and groups[-1].endswith('仲良くね。')
assert worker.preserves_letters('Hey, almost done.',"Hey, shh. We're almost done.")
assert not worker.preserves_letters('見せて。','見てて。')
assert not worker.preserves_letters('ううん。','うん。')
blocks = worker.acoustic_groups([{'start':1,'end':2},{'start':2.3,'end':3},{'start':20,'end':21}],30)
assert len(blocks) == 2 and blocks[0]['audioEnd'] < 4 and blocks[1]['audioStart'] > 19
print('PASS: quiet line stays after long silence; multi-block sentence preserves onset and text; no guessed lexical substitution or negative deletion')
