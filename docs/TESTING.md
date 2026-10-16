# Testing

## Basic checks

`sh scripts/check.sh` runs deterministic Python metrics, Swift regression executables, UI layout/control state checks, and an Xcode Debug build. Ollama calls in these checks use stub URL protocols; no inference server or model download is required. If the local MLX environment exists, additional audio logic tests run too.

FFmpeg is needed on a clean clone. `scripts/prepare-check-media.sh` creates `Samples/Japanese.mp4`, a silent seven-second color video, only when that path is absent. It is a playback fixture, not Japanese speech and not an ASR accuracy sample. Existing local samples are preserved. Media stays ignored by Git.

## Model-dependent checks

Other test files and scripts are opt-in research/integration utilities. They may require a running local Ollama service, the full model stack, specific synthetic fixtures, or separately prepared real-video corpora. They are not all runnable on a fresh clone. Historical candidate comparisons are retained for reference and may require models or apps no longer used by the player.

- `scripts/make-english-quality-fixtures.py`: generates synthetic English dialogue, quiet speech, silence, tones, and noise using installed macOS voices and FFmpeg.
- `scripts/check-english-local.sh`: runs the English local model pipeline after those fixtures and models are available.
- `scripts/check-real-video-local.sh`: runs recognition, timing metrics, translation checks, and review exports using `tools/real-video-evaluation/manifest.json` and associated local inputs.
- `scripts/prepare-real-video-corpus.py`: documents the historical source/cut layout for separately obtained publisher videos/captions. It does not download them. It expects specific files under `tools/real-video-evaluation/media` and `sources`.
- `Tests/ImmediatePlaybackChecks.swift`, `Tests/RealJapaneseLanguageChecks.swift`: opt-in app pipeline checks that require a supplied local video and local model configuration. Read each executable's argument contract before running.

Reference sources used during development include the Japan Foundation's [Erin lessons](https://www.erin.jpf.go.jp/en/), [Sintel](https://durian.blender.org/), and a [TED talk](https://www.ted.com/talks/tim_urban_inside_the_mind_of_a_master_procrastinator). Obtain permitted test inputs directly from their publishers and respect their terms. No media, full subtitle files, private developer reports, or generated comparisons are included in the repository.

## Interpreting results

Keep reference transcripts and Chinese translations out of model inputs. Measure Japanese character error rate and English word error rate against human source transcripts, including insertions during silence. Review quiet/normal audio separately. Evaluate translations and explanations with an independent competent human; character overlap and a model grading itself are insufficient.

Publisher subtitle intervals are editorial display times, not precise human-annotated speech onsets. Report timing differences accordingly. Generation latency, timestamp alignment, and display duration are separate measurements. Unit test success and a few good examples do not establish 98% accuracy on real films.
