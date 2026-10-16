"""Local audio -> Qwen3-ASR -> forced alignment. No network or downloads at runtime."""
import argparse
import difflib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unicodedata

os.environ.update(HF_HUB_OFFLINE='1', TRANSFORMERS_OFFLINE='1', HF_HUB_DISABLE_TELEMETRY='1')


def forbid_network(event, args):
    if event == 'socket.connect':
        raise RuntimeError('Local ASR forbids network connections')


sys.addaudithook(forbid_network)
import numpy as np
import soundfile as sf


def stationary_tone(audio, rate):
    """Reject long, stationary test tones, not low-volume speech.

    Require both a nearly constant envelope and highly concentrated spectrum.
    No absolute volume cutoff is used: quiet dialogue must remain eligible.
    """
    size = rate//4
    if len(audio) < 3*rate:
        return False
    frames = np.asarray([audio[i:i+size] for i in range(size,len(audio)-2*size,size)])
    rms = np.sqrt(np.mean(frames**2,axis=1))
    if rms.mean() < 1e-9 or rms.std()/rms.mean() > 0.025:
        return False
    power = abs(np.fft.rfft(frames*np.hanning(size),axis=1))**2
    strongest = np.partition(power,-12,axis=1)[:,-12:].sum(axis=1)
    concentration = strongest/np.maximum(power.sum(axis=1),1e-20)
    return bool(np.quantile(concentration,0.1) > 0.985)


def restore_words(alignment, text, duration, offset=0):
    words, cursor = [], 0
    for item in alignment:
        start,end = float(item.start_time),float(item.end_time)
        if not (np.isfinite(start) and np.isfinite(end) and 0 <= start <= end <= duration+0.15):
            raise ValueError(f'Invalid alignment timestamps: {start}..{end}, duration={duration}')
        position = text.find(item.text,cursor)
        end_position = position+len(item.text)
        if position < 0:
            # The aligner can join across punctuation (よし。え -> よしえ,
            # ninety-page -> ninetypage). Map those anchors back to the exact
            # original transcript, rather than replacing or dropping its text.
            indices = [i for i in range(cursor,len(text))
                       if unicodedata.category(text[i])[0] in 'LNM']
            searchable = ''.join(text[i] for i in indices)
            anchor = ''.join(c for c in item.text if unicodedata.category(c)[0] in 'LNM')
            found = searchable.find(anchor) if anchor else -1
            if found >= 0:
                position = indices[found]
                end_position = indices[found+len(anchor)-1]+1
        if position < 0:
            raise ValueError(f'Aligner text does not match transcript: item={item.text!r}, cursor={cursor}, remaining={text[cursor:]!r}')
        if words: words[-1]['text'] += text[cursor:position]
        prefix = text[cursor:position] if not words else ''
        words.append({'text':prefix+text[position:end_position],'start':start+offset,'end':end+offset})
        cursor = end_position
    if not words: raise ValueError('No aligned words for nonempty transcript')
    words[-1]['text'] += text[cursor:]
    return words


def lexical(text):
    # Folding kana script is spelling normalization, not a vocabulary correction.
    text = unicodedata.normalize('NFKC', text).casefold()
    return ''.join(chr(ord(c)-0x60) if '\u30a1' <= c <= '\u30f6' else c
                   for c in text if unicodedata.category(c)[0] in 'LNM')


def agreement(source, candidate):
    a, b = lexical(source), lexical(candidate)
    if not a or not b: return 0.0
    blocks = [x for x in difflib.SequenceMatcher(None,a,b,autojunk=False).get_matching_blocks() if x.size]
    if not blocks: return 0.0
    matched = sum(x.size for x in blocks)
    width = blocks[-1].b+blocks[-1].size-blocks[0].b
    return min(1.0,.8*matched/len(a)+.2*matched/max(1,width))


def acoustic_groups(regions, duration):
    merged = []
    for region in regions:
        # Keep connected speech together; a long silence is never absorbed to
        # satisfy a text alignment. Do not cut an utterance at a fixed word count.
        if merged and region['start']-merged[-1]['end'] <= .65:
            merged[-1]['end'] = region['end']
        else: merged.append(dict(region))
    for i,region in enumerate(merged):
        region['audioStart'] = max(0,region['start']-.35,
            (merged[i-1]['end']+region['start'])/2 if i else 0)
        region['audioEnd'] = min(duration,region['end']+.35,
            (region['end']+merged[i+1]['start'])/2 if i+1 < len(merged) else duration)
    return merged


def split_acoustic_span(text, probes):
    if len(probes) == 1: return [text]
    characters, offsets = [],[]
    for position,c in enumerate(text):
        for unit in lexical(c): characters.append(unit); offsets.append(position)
    heard,owners = [],[]
    for i,probe in enumerate(probes):
        units = lexical(probe['text']); heard.extend(units); owners.extend([i]*len(units))
    matched = []
    for block in difflib.SequenceMatcher(None,characters,heard,autojunk=False).get_matching_blocks():
        matched.extend((block.a+d,owners[block.b+d]) for d in range(block.size))
    cuts = [0]
    for boundary in range(1,len(probes)):
        anchors = [a for a,owner in matched if owner >= boundary]
        cut = offsets[min(anchors)] if anchors else len(text)
        # Do not create English fragments inside an orthographic word.
        if 0 < cut < len(text) and text[cut-1].isascii() and text[cut-1].isalnum() and text[cut].isascii() and text[cut].isalnum():
            while cut > cuts[-1] and not text[cut-1].isspace(): cut -= 1
        cuts.append(max(cuts[-1],cut))
    cuts.append(len(text))
    return [text[a:b] for a,b in zip(cuts,cuts[1:])]


def sentence_units(text):
    return [s for s in re.findall(r'.+?(?:[。！？!?，,;；]|[.](?=\s|$)|$)\s*',text,re.S) if s]


def assign_sentences(text, probes, priors=None):
    # A sentence may span several real speech blocks. Ownership comes from
    # independent local audio readings, never from global guessed timestamps.
    sentences = sentence_units(text)
    if ''.join(sentences) != text: raise ValueError('Sentence split changed transcript')
    count = len(probes)
    previous,history = [0.0]*count,[]
    for i,sentence in enumerate(sentences):
        current,parents = [-float('inf')]*count,[None]*count
        weak = max(agreement(sentence,p['text']) for p in probes) < .72
        prior = priors[i] if priors else None
        for a in range(count):
            parent = max(range(a+1),key=lambda j:previous[j])
            for b in range(a,count):
                candidate = ''.join(p['text'] for p in probes[a:b+1])
                score = agreement(sentence,candidate)-.045*(b-a)
                if weak and prior is not None:
                    distance = max(probes[a]['start']-prior,prior-probes[b]['end'],0)
                    score += .8*max(0,1-distance/1.5)
                silence = sum(max(0,probes[k+1]['start']-probes[k]['end']-1) for k in range(a,b))
                order = abs(i/max(1,len(sentences)-1)-(a+b)/2/max(1,count-1))
                value = previous[parent]+max(2,len(lexical(sentence)))*(score-.07*silence-.02*order)
                if value > current[b]: current[b],parents[b] = value,(parent,a,b)
        previous = current;history.append(parents)
    chosen = max(range(count),key=lambda j:previous[j])
    spans = []
    for i in reversed(range(len(sentences))):
        chosen,a,b = history[i][chosen];spans.append((a,b))
    spans.reverse()
    groups,confidence = ['']*count,[[] for _ in probes]
    for sentence,(a,b) in zip(sentences,spans):
        pieces = split_acoustic_span(sentence,probes[a:b+1])
        for j,piece in enumerate(pieces,a):
            if piece:
                groups[j] += piece;confidence[j].append(agreement(piece,probes[j]['text']))
    return groups,confidence


def boosted(audio):
    if not len(audio): return audio
    rms,peak = float(np.sqrt(np.mean(audio**2))),float(np.max(np.abs(audio)))
    gain = max(1.0,min(25.0,.12/max(rms,1e-9),.9/max(peak,1e-9)))
    return audio*gain


def preserves_letters(source, candidate):
    remaining = iter(lexical(candidate))
    return all(any(c == target for c in remaining) for target in lexical(source))


def detect_regions(audio_path, vad_bin, vad_model):
    detection = subprocess.run([vad_bin,'-np','-f',str(audio_path),'-vm',vad_model,'-vt','0.35',
        '-vspd','150','-vsd','350','-vp','150'],text=True,capture_output=True,check=True)
    return [{'start':float(a)/100,'end':float(b)/100}
        for a,b in re.findall(r'start = ([\d.]+), end = ([\d.]+)',detection.stdout)]


def merge_regions(original, extra, duration):
    result = []
    for item in sorted(original+extra,key=lambda x:x['start']):
        start,end = max(0,item['start']),min(duration,item['end'])
        if end <= start: continue
        if result and start <= result[-1]['end']:
            result[-1]['end'] = max(result[-1]['end'],end)
        else: result.append({'start':start,'end':end})
    return result


def confirmed_recovery(candidate, second):
    # Require literal acoustic agreement, not agreement with publisher text or
    # an LLM rewrite. Single interjections alone are too ambiguous to add.
    first,other = lexical(candidate),lexical(second)
    vocalization = first in {'oh','um','uh','huh'} or re.fullmatch(r'(?:h+m+|m+h*|u+h+|u+m+)+',first)
    return len(first) >= 2 and first == other and not vocalization and not re.search(r'[\[<【]',candidate)


def script_language_evidence(text):
    # Some MLX Qwen responses omit the language tag and the library then reports
    # English unconditionally. Kana/Hangul in a substantial transcript provides
    # strong contrary evidence. Han-only names and short interjections do not.
    units = [c for c in text if unicodedata.category(c)[0] in 'LNM']
    kana = sum('\u3041' <= c <= '\u3096' or '\u30a1' <= c <= '\u30fa' for c in units)
    hangul = sum('\uac00' <= c <= '\ud7a3' for c in units)
    if kana >= 4 and kana/max(1,len(units)) >= .2: return 'Japanese'
    if hangul >= 4 and hangul/max(1,len(units)) >= .4: return 'Korean'
    return None


def transcribe(audio_path, asr_path, aligner_path, vad_bin, vad_model, language):
    audio, rate = sf.read(audio_path,dtype='float32')
    if rate != 16000 or audio.ndim != 1: raise ValueError('Expected normalized 16kHz mono WAV')
    if not np.any(audio) or stationary_tone(audio,rate):
        return {'text':'','words':[],'regions':[],'reason':'silence-or-stationary-tone'}
    regions = detect_regions(audio_path,vad_bin,vad_model)
    initial_regions = list(regions)
    loud = boosted(audio)
    if np.max(np.abs(loud-audio)) > 1e-7:
        with tempfile.TemporaryDirectory(prefix='subtitle-quiet-vad-') as directory:
            path = Path(directory)/'boosted.wav'
            sf.write(path,loud,rate,subtype='FLOAT')
            regions = merge_regions(regions,detect_regions(path,vad_bin,vad_model),len(audio)/rate)
    if not regions: return {'text':'','words':[],'regions':[],'reason':'no-detected-speech-after-quiet-review'}
    from mlx_audio.stt import load
    import mlx.core as mx
    source = {'ja':'Japanese','en':'English','ko':'Korean','zh':'Chinese'}.get(language)
    recognizer = load(asr_path)
    # Quiet audio can pass VAD after gain yet remain inaudible to the main ASR.
    # Keep ordinary-volume input unchanged; never use volume to reject speech.
    recognition_audio = loud if float(np.max(np.abs(audio))) < .05 else audio
    recognized = recognizer.generate(recognition_audio,language=source,temperature=0,max_tokens=768,verbose=False)
    original = recognized.text.strip()
    detected = recognized.language
    if isinstance(detected,list): detected = detected[0] if detected else None
    reported_language = detected
    evidence = script_language_evidence(original)
    language_review = None
    if source is None and evidence is not None and evidence != detected:
        # Re-read AUDIO with the supported language hint. Do not translate or
        # rewrite the first transcript to manufacture cross-view agreement.
        source = evidence
        recognized = recognizer.generate(recognition_audio,language=source,temperature=0,max_tokens=768,verbose=False)
        original = recognized.text.strip()
        language_review = 'script-conflicts-with-reported-language; audio-retranscribed'
    source = source or detected
    groups = acoustic_groups(regions,len(audio)/rate)
    probes = []
    for region in groups:
        a,b = int(region['audioStart']*rate),int(region['audioEnd']*rate)
        result = recognizer.generate(boosted(audio[a:b]),language=source,temperature=0,max_tokens=768,verbose=False)
        probes.append({**region,'text':result.text.strip()})
    # Use the original global alignment only as a weak-phrase tie breaker.
    # Strong local AUDIO text anchors override it (e.g. the early Good night).
    # This prevents an unknown final phrase from being glued to earlier dialogue
    # just because its first syllable happens to match a common earlier word.
    aligner = load(aligner_path)
    aligned_audio = audio.copy()
    for region in regions:
        a,b = int(region['start']*rate),min(len(audio),int(region['end']*rate))
        aligned_audio[a:b] = boosted(audio[a:b])
    priors = None
    try:
        if not original: raise ValueError('Empty global recognition; inspect independent speech blocks')
        initial = aligner.generate(audio=aligned_audio,text=original,language=source or 'Japanese')
        initial_words = restore_words(initial,original,len(audio)/rate)
        positions,cursor = [],0
        for word in initial_words:
            positions.append((cursor,cursor+len(word['text']),(word['start']+word['end'])/2))
            cursor += len(word['text'])
        priors,cursor = [],0
        for sentence in sentence_units(original):
            end = cursor+len(sentence)
            centers = [(max(0,min(end,b)-max(cursor,a)),t) for a,b,t in positions if b>cursor and a<end]
            priors.append(sum(weight*t for weight,t in centers)/max(1,sum(weight for weight,t in centers)))
            cursor = end
    except ValueError:
        pass  # Unusable global alignment must not override acoustic anchors.
    texts,scores = assign_sentences(original,probes,priors)

    for i,(probe,text) in enumerate(zip(probes,texts)):
        if not text:
            candidate = probe['text']
            if len(lexical(candidate)) < 2: continue
            # Keep the second view inside neighboring voice boundaries so a
            # nearby speaker cannot corroborate a silent/foley block.
            start = max(0,probe['start']-.9,probes[i-1]['end'] if i else 0)
            end = min(len(audio)/rate,probe['end']+.9,probes[i+1]['start'] if i+1<len(probes) else len(audio)/rate)
            wider = recognizer.generate(boosted(audio[int(start*rate):int(end*rate)]),language=source,temperature=0,max_tokens=768,verbose=False).text.strip()
            probe['secondViewText'] = wider
            corroborated = confirmed_recovery(candidate,wider)
            if not corroborated and len(lexical(candidate)) >= 4 and confirmed_recovery(candidate,candidate):
                # A wide view may include another utterance. A slightly tighter
                # view retains VAD padding where available; require exact
                # text agreement, never fuzzy agreement that can erase negation.
                start,end = probe['audioStart']+.12,probe['audioEnd']-.12
                if end-start >= .5:
                    tighter = recognizer.generate(boosted(audio[int(start*rate):int(end*rate)]),language=source,temperature=0,max_tokens=768,verbose=False).text.strip()
                    probe['thirdViewText'] = tighter
                    corroborated = confirmed_recovery(candidate,tighter)
            if corroborated:
                probe.update(assignedText=candidate,agreement=.75,
                    recovery='two-acoustic-views',warning='整段识别漏句，已用两段局部音频复核补回；请结合原声核对。')
            continue
        probe['assignedText'] = text
        quality = agreement(text,probe['text'])
        probe['warning'] = ''
        candidate = probe['text']
        # A second acoustic view must corroborate additions/corrections. Never
        # replace a whole-window sentence with a short, incomplete local guess.
        # Japanese short views can expand spoken contractions (e.g. 〜てる to
        # 〜ている). Preserve the contextual Japanese transcript verbatim;
        # acoustic views anchor timing and uncertainty, not a grammar rewrite.
        if source == 'English' and lexical(candidate) != lexical(text) and agreement(text,candidate) >= .72 and preserves_letters(text,candidate):
            start = max(0,probe['start']-.9)
            end = min(len(audio)/rate,probe['end']+.9)
            wider = recognizer.generate(boosted(audio[int(start*rate):int(end*rate)]),language=source,temperature=0,max_tokens=768,verbose=False).text.strip()
            probe['secondViewText'] = wider
            if lexical(wider) == lexical(candidate):
                probe['assignedText'] = candidate + (' ' if text.endswith(' ') else '')
                probe['warning'] = '本句包含小声或省略音，已用两段音频复核，仍请结合原声核对。'
        if quality < .72:
            probe['warning'] = '整段与局部音频识别不一致，可能有错字或漏词；时间仅定位到人声片段，请复听核对。'
        probe['agreement'] = quality
    del recognizer
    mx.clear_cache()
    words,assembled = [],[]
    for i,probe in enumerate(probes):
        text = probe.get('assignedText')
        if not text: continue
        a,b = int(probe['audioStart']*rate),int(probe['audioEnd']*rate)
        def align_here(value):
            alignment = aligner.generate(audio=boosted(audio[a:b]),text=value,language=source or 'Japanese')
            return restore_words(alignment,value,(b-a)/rate,a/rate)
        try:
            local = align_here(text)
            # If the aligner compresses a complete final phrase to zero time,
            # text similarity is not acoustic support. Revisit an unused later
            # speech block, without inventing a corrected transcript.
            tail = re.search(r'[^。！？!?]+[。！？!?]?\s*$',text)
            if tail and len(lexical(tail.group())) >= 4:
                cursor,tail_words = 0,[]
                for word in local:
                    if cursor+len(word['text']) > tail.start(): tail_words.append(word)
                    cursor += len(word['text'])
                unrealized = tail_words and max(w['end'] for w in tail_words)-min(w['start'] for w in tail_words) < .08
                later = next((p for p in probes[i+1:] if not p.get('assignedText') and len(lexical(p['text'])) >= 2),None)
                if unrealized and tail.start() > 0 and later is not None:
                    later['assignedText'] = text[tail.start():]
                    later['warning'] = '这段小声人声的识别结果不一致，暂未确认原话，请复听核对。'
                    later['agreement'] = min(.3,agreement(later['assignedText'],later['text']))
                    later['ownershipReview'] = 'zero-duration-tail-to-unused-speech'
                    text = text[:tail.start()]
                    probe['assignedText'] = text
                    local = align_here(text)
            if local and len(lexical(text)) >= 4 and max(w['end'] for w in local)-min(w['start'] for w in local) < .08:
                raise ValueError('Speech text has no realizable word duration')
        except ValueError:
            # A measured block interval is a coarse fallback, not word timing.
            local = [{'text':text,'start':probe['start'],'end':min(probe['end'],len(audio)/rate)}]
            probe['warning'] = '逐词时间对齐不可靠，暂按人声片段整句显示，请复听核对。'
            probe['agreement'] = min(probe.get('agreement',0),.3)
        for word in local:
            word.update(block=i,confidence=probe['agreement'],warning=probe['warning'])
        words.extend(local); assembled.append(text)
    text = ''.join(assembled)
    if ''.join(w['text'] for w in words) != text: raise ValueError('Alignment dropped transcript text')
    return {'text':text,'originalText':original,'language':source,'requestedLanguage':language,
        'reportedLanguage':reported_language,'languageReview':language_review,'words':words,'regions':regions,
        'acousticBlocks':probes,'initialRegions':initial_regions,
        'unresolvedSpeechBlocks':[{'start':p['start'],'end':p['end']} for p in probes if not p.get('assignedText')],
        'reason':'acoustically-anchored'}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    for name in ['audio','asr','aligner','vad-bin','vad-model','output']: p.add_argument('--'+name,required=True)
    p.add_argument('--language',default='ja')
    a = p.parse_args()
    result = transcribe(a.audio,a.asr,a.aligner,a.vad_bin,a.vad_model,a.language)
    target = Path(a.output)
    temporary = target.with_suffix('.part')
    temporary.write_text(json.dumps(result,ensure_ascii=False))
    temporary.replace(target)
    recovered = sum(p.get('recovery') == 'two-acoustic-views' for p in result.get('acousticBlocks',[]))
    unresolved = len(result.get('unresolvedSpeechBlocks',[]))
    print(f'Qwen local: {len(result["words"])} aligned words; {result["reason"]}; recovered={recovered}; unresolved-VAD-blocks={unresolved}',flush=True)


if __name__ == '__main__': main()
