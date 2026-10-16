"""Translate existing ASR output with a local-only model; never read references.

Run after ASR. No expected Chinese, script, or glossary is provided to the model.
Keep raw responses and exact input so meaning checks are independently reviewable.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import time
import urllib.request
import html


class LocalOnly(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise RuntimeError("Redirects forbidden during local inference")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--id")
    parser.add_argument("--window", action="store_true", help="Translate each cue with three preceding and two following cues")
    args = parser.parse_args()
    source = json.loads(args.input.read_text())
    cases = source.get("cases", [source])
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), LocalOnly())
    report = {"model": "translategemma:12b", "endpoint": "http://127.0.0.1:11434",
              "inputSHA256": hashlib.sha256(args.input.read_bytes()).hexdigest(),
              "method": "whole ASR paragraph window; no reference or glossary",
              "cases": []}
    for case in cases:
        if args.id and case.get("id") != args.id:
            continue
        cues = case.get("cues", [])
        if args.window and cues:
            outputs = []
            started = time.monotonic()
            all_attempts = []
            for current in range(len(cues)):
                lo, hi = max(0,current-3), min(len(cues),current+3)
                subset = cues[lo:hi]
                document = "\n".join(f'<p id="s{i}">{html.escape(c["text"])}</p>' for i,c in enumerate(subset))
                prompt = ("You are a professional Japanese (ja) to Chinese (Simplified) (zh-Hans) translator. "
                          "Accurately convey the meaning and nuances while adhering to Chinese grammar. "
                          "Render idioms and figurative expressions by their intended meaning. Preserve who requests, gives or receives things, negation, and social nuance. "
                          "Preserve every HTML paragraph and its id exactly, including short utterances. "
                          "Do not merge, split, reorder or renumber paragraphs. Translate every paragraph, without commentary.\n\n" + document)
                payload = {"model": report["model"], "stream": False, "keep_alive": "5m",
                           "messages": [{"role": "user", "content": prompt}],
                           "options": {"temperature": 0, "num_ctx": 2048, "num_predict": 768}}
                req = urllib.request.Request(report["endpoint"]+'/api/chat', data=json.dumps(payload).encode(),
                                             headers={"Content-Type":"application/json"})
                with opener.open(req, timeout=300) as response: result = json.load(response)
                raw = result['message']['content']
                matches = re.findall(r'<p\s+id=[\"\x27]s(\d+)[\"\x27]\s*>(.*?)</p>',raw,re.S)
                parsed = {int(i):html.unescape(re.sub('<[^>]+>','',t)).strip() for i,t in matches}
                attempt = {'cueIndex':current,'prompt':prompt,'rawResponse':raw}
                all_attempts.append(attempt)
                if result.get('done_reason')=='length' or len(matches)!=len(subset) or set(parsed)!=set(range(len(subset))):
                    report['failure'] = {'id':case.get('id'),'attempts':all_attempts,'reason':'Invalid paragraph mapping; no shifted subtitles accepted'}
                    args.output.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
                    raise RuntimeError(f'Invalid local paragraph mapping, saved raw result: {current}')
                outputs.append({**cues[current],'translation':parsed[current-lo]})
                print(case.get('id'),'cue',current+1,len(cues),flush=True)
            report['cases'].append({'id':case.get('id'),'cues':outputs,'attempts':all_attempts,
                                    'processingSeconds':time.monotonic()-started,
                                    'kanaRemaining':[i for i,c in enumerate(outputs) if re.search('[ぁ-ゖァ-ヺ]',c['translation'])]})
            args.output.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
            continue
        if not cues:
            report["cases"].append({"id": case.get("id"), "cues": [], "processingSeconds": 0})
            continue
        document = "\n".join(f'<p id="s{i}">{html.escape(c["text"])}</p>' for i, c in enumerate(cues))
        prompt = ("You are a professional Japanese (ja) to Chinese (Simplified) (zh-Hans) translator. "
                  "Your goal is to accurately convey the meaning and nuances of the original Japanese "
                  "text while adhering to Chinese (Simplified) grammar, vocabulary, and cultural sensitivities.\n"
                  "Preserve all HTML paragraph tags and their id attributes exactly.\n"
                  "Produce only the Chinese (Simplified) translation, without any additional explanations "
                  "or commentary. Please translate the following Japanese text into Chinese (Simplified):\n\n\n" + document)
        payload = {"model": report["model"], "stream": False, "keep_alive": "5m",
                   "messages": [{"role": "user", "content": prompt}],
                   "options": {"temperature": 0, "num_ctx": 2048, "num_predict": 1024}}
        req = urllib.request.Request(report["endpoint"] + "/api/chat", data=json.dumps(payload).encode(),
                                     headers={"Content-Type": "application/json"})
        start = time.monotonic()
        with opener.open(req, timeout=300) as response:
            result = json.load(response)
        raw = result["message"]["content"]
        matches = re.findall(r'<p\s+id=[\"\x27]s(\d+)[\"\x27]\s*>(.*?)</p>', raw, re.S)
        parsed = {int(i): html.unescape(re.sub('<[^>]+>', '', text)).strip() for i, text in matches}
        if result.get("done_reason") == "length" or len(parsed) != len(cues) or set(parsed) != set(range(len(cues))) or len(matches) != len(cues):
            report['failure'] = {'id':case.get('id'),'prompt':prompt,'rawResponse':raw,'reason':'Invalid paragraph mapping; rejected'}
            args.output.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
            raise RuntimeError(f'Incomplete or invalid paragraph mapping: {case.get("id")}: {raw}')
        translated = [{**c, "translation": parsed[i]} for i, c in enumerate(cues)]
        report["cases"].append({"id": case.get("id"), "cues": translated, "prompt": prompt,
                                "rawResponse": raw, "processingSeconds": time.monotonic()-start,
                                "modelEvalCount": result.get("eval_count"),
                                "kanaRemaining": [i for i,t in parsed.items() if re.search('[ぁ-ゖァ-ヺ]',t)]})
        args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2)+"\n")
        print(case.get("id"), f'{report["cases"][-1]["processingSeconds"]:.1f}s', flush=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2)+"\n")


if __name__ == "__main__":
    main()
