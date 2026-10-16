"""Local CLI adapter: preserve VAD time mapping and expose recognition evidence.

Applies only to the pinned whisper.cpp checkout. The adapter is maintained locally
and is not part of upstream whisper.cpp. It uses public timestamp APIs without changing the recognition model.
"""
from pathlib import Path

path = Path(__file__).resolve().parents[1] / "tools/whisper.cpp/examples/cli/cli.cpp"
source = path.read_text()
if 'value_i("subtitle_study_json_revision", 1, false);' in source:
    raise SystemExit(0)

def replace(old, new):
    global source
    if source.count(old) != 1:
        raise SystemExit("Pinned Whisper JSON adapter does not match source")
    source = source.replace(old, new)

replace('    start_obj(nullptr);\n        value_s("systeminfo",',
        '    start_obj(nullptr);\n        value_i("subtitle_study_json_revision", 1, false);\n        value_s("systeminfo",')
replace('        start_arr("transcription");', '''        start_arr("vad_segments");
            const int n_vad_segments = whisper_full_n_vad_segments(ctx);
            for (int i = 0; i < n_vad_segments; ++i) {
                start_obj(nullptr);
                    times_o(whisper_full_get_vad_segment_t0(ctx, i), whisper_full_get_vad_segment_t1(ctx, i), true);
                end_obj(i == n_vad_segments - 1);
            }
        end_arr(false);
        start_arr("transcription");''')
replace('                    value_s("text", text, !params.diarize && !params.tinydiarize && !full);',
        '                    value_f("no_speech_prob", whisper_full_get_segment_no_speech_prob(ctx, i), false);\n                    value_s("text", text, !params.diarize && !params.tinydiarize && !full);')
replace('                            merged_token m{ whisper_token_to_str(ctx, tok.id), tok, tok.t1 };', '''                            const int token_index = j;
                            if (tok.t0 >= 0) tok.t0 = whisper_full_get_token_t0(ctx, i, token_index);
                            const int64_t mapped_t1 = tok.t1 >= 0 ? whisper_full_get_token_t1(ctx, i, token_index) : tok.t1;
                            merged_token m{ whisper_token_to_str(ctx, tok.id), tok, mapped_t1 };''')
replace('                                    m.t1 = tok_next.t1;',
        '                                    m.t1 = whisper_full_get_token_t1(ctx, i, j);')
path.write_text(source)
