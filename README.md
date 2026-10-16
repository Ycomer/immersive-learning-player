# Immersive Learning Player

A native macOS player for learning Japanese and English from local videos, with on-device speech recognition, Chinese translation, and contextual vocabulary explanations.

[中文说明](docs/README.zh-CN.md) · [Setup](docs/SETUP.md) · [Contributing](CONTRIBUTING.md)

**Early development preview.** The interface is currently in Simplified Chinese. Build from source; no signed installer is provided yet. Speech recognition and translation can be wrong, especially with quiet, overlapping, or music-backed dialogue. This project does not claim 98% accuracy.

## What it does

- Plays local MP4/MOV files through AVPlayer; playback starts while subtitles are prepared in the background.
- Generates original-language subtitles from the audio, then translates them into Chinese using local models.
- Displays bilingual subtitles inside the video. A movable, resizable cover can hide burned-in captions and hold the new subtitles; it does not remove pixels from the source video.
- Provides compact, movable playback controls with adjustable opacity and automatic hiding.
- Supports subtitle navigation, sentence looping, SRT import/export, source corrections, and per-video language selection.
- Lets you select subtitle words for context explanations and compare a chosen synonym using surrounding dialogue.
- Caches subtitles and translations locally for later playback.

## Local model stack

| Task | Current configuration |
| --- | --- |
| Speech recognition | Qwen3-ASR 1.7B, MLX 8-bit |
| Word timing | Qwen3 ForcedAligner 0.6B, MLX 8-bit |
| Voice detection | Silero VAD through whisper.cpp |
| Auxiliary recognition review / alternative engine | Whisper large-v3 through the project's patched whisper.cpp CLI |
| Chinese translation | TranslateGemma 12B through local Ollama |
| Context explanations and translation fallback | Qwen3 4B Instruct through local Ollama |

Model weights are downloaded separately and have their own terms. The repository contains no weights, runtime environments, personal videos, or generated evaluation data. See [third-party notices](THIRD_PARTY_NOTICES.md).

The reference development machine is an Apple Silicon Mac with 24 GB unified memory. This is a tested configuration, not a guarantee for every Mac. The full stack needs substantial disk space; allow roughly **25–35 GB or more** for weights, Python packages, build products, and caches. The build may copy Whisper weights into the app, increasing storage use.

## Build and run

Requirements: an Apple Silicon Mac, macOS 14+, Xcode with command-line tools, Python 3.12+ (development runtime: 3.14), FFmpeg, and Ollama for translation.

```sh
git clone https://github.com/Ycomer/immersive-learning-player.git
cd immersive-learning-player
xcodebuild -project SubtitleStudy.xcodeproj -scheme SubtitleStudy \
  -configuration Debug -derivedDataPath build build
open "build/Build/Products/Debug/Immersive Learning Player.app"
```

A source-only build can play video and import subtitles. **Automatic recognition and translation require the separate setup steps in [docs/SETUP.md](docs/SETUP.md).** The Xcode scheme retains the internal name `SubtitleStudy`.

After setting up the tools/models, rebuild the app so it discovers the local paths. Open a video with **⌘O**. Select the video's audio language in the subtitle menu if automatic detection is wrong. Default playback does not wait for inference; new subtitles may arrive after the first playback reaches their time. Enable “等待字幕再播放（学习模式）” when you prefer synchronized prepared subtitles over uninterrupted playback.

## How it works

```text
Local video → FFmpeg audio windows → voice detection + Qwen ASR
           → acoustic review + forced alignment → cached original subtitles
           → local Ollama translation → in-video bilingual overlay
                                          ↓
                             word selection / context learning
```

Processing prioritizes the current playback position and prepares nearby chunks. It is background processing of a local file, not a guarantee of live or zero-latency transcription. Recognition text and timing are checked before display; uncertain speech may be marked as unresolved rather than given a guessed translation.

## Tests

```sh
# Python/Swift regression checks and an Xcode build; no model download/inference.
# Requires FFmpeg; creates a silent seven-second playback fixture if absent.
sh scripts/check.sh
```

Some additional Python checks run only when `tools/mlx-asr-venv` is installed. Model-dependent tests and real-video evaluation are opt-in; see [testing notes](docs/TESTING.md). Passing unit tests does not establish recognition or translation accuracy on real dialogue.

## Privacy and limitations

- Runtime ASR disables model-hub networking. Translation and context explanations use a loopback Ollama endpoint; cloud endpoints are rejected by the application.
- Installing packages and downloading models requires network access. Once prepared, inference runs locally.
- Subtitle text, translations, corrections, and video identifiers are stored under `~/Library/Application Support/SubtitleStudy`; application preferences use `com.local.SubtitleStudy`.
- Original subtitles come from audio, not from reverse-translating existing Chinese captions. Burned-in captions can only be covered in the player.
- MP4/MOV playback depends on AVFoundation codec support. MKV/AVI support and online video are not implemented.
- Quiet speech, accents, multiple speakers, slang, and short ambiguous replies remain difficult. Explanations can still misinterpret the scene and should be checked.
- The app is not self-contained: the MLX environment and model folders must stay in place. Rebuild or update Settings if the checkout moves. The app is not sandboxed because it launches local tools; review tools you configure before running them.

## License

Project-authored source is released under the [MIT License](LICENSE). Dependencies, models, and test media retain their respective licenses; the MIT license does not relicense them.
