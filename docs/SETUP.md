# Local setup

Run commands from the repository root. Setup downloads packages/models; player inference uses local files and a loopback Ollama service. No cloud inference API key is needed.

## 1. System tools

Install Xcode and select its command-line tools. Install FFmpeg and Python through your preferred package manager. For Homebrew on Apple Silicon:

```sh
brew install ffmpeg python@3.14
```

Install [Ollama](https://ollama.com/download/mac) and start its local service. The app defaults to `http://127.0.0.1:11434`. Do not run a second `ollama serve` process if the desktop app already serves that port.

## 2. MLX recognition runtime and models

```sh
PYTHON=python3.14 sh scripts/setup-local-asr.sh
python3 scripts/download-qwen-asr.py
python3 scripts/download-qwen-asr.py --aligner
```

The setup script creates `tools/mlx-asr-venv`, using the direct dependency versions in `requirements-local-asr.txt`. It does not alter global Python packages. Python 3.14 is the development configuration; other supported Python versions have not been validated here.

The download helper uses pinned MLX community conversions:

| Model | Revision | Local folder |
| --- | --- | --- |
| `mlx-community/Qwen3-ASR-1.7B-8bit` | `a8379a2e2f9e313c9292cdf1af4055ab56d50d55` | `tools/asr-candidates/qwen3-asr-1.7b-8bit` |
| `mlx-community/Qwen3-ForcedAligner-0.6B-8bit` | `0e1a68e91d815300c7c9754b2a7639378b23db15` | `tools/asr-candidates/qwen3-forced-aligner-0.6b-8bit` |

Downloads can be several gigabytes. The helper checks sizes and available LFS SHA-256 values for downloaded files and resumes partial large files. Existing same-size files are reused, so delete a suspected corrupt file and rerun the helper. It fails rather than mixing a cached manifest from another revision. Consult the upstream model cards and terms before downloading.

## 3. Whisper and voice detection

```sh
sh scripts/setup-whisper.sh
sh scripts/setup-accuracy-model.sh
```

`setup-whisper.sh` fetches a pinned whisper.cpp commit, applies `patch-whisper-json.py`, builds static CLI tools with Metal, and downloads the Tiny, Small, and Silero VAD models. Tiny and Small are legacy alternatives; after setup, they can be removed if unused. `setup-accuracy-model.sh` separately downloads and verifies Whisper large-v3 (about 3.1 GB), used by the current quality stack.

Use the project's patched CLI: it exposes VAD regions, token evidence, and timing mapped to the original audio. An arbitrary system whisper-cli may lack this contract. The patch does not change Whisper's model weights.

## 4. Local translation and learning models

With Ollama running:

```sh
ollama pull translategemma:12b
ollama pull qwen3:4b-instruct
ollama list
```

TranslateGemma 12B is the translation model. Qwen3 4B Instruct handles explanations and some translation fallbacks; keep both. Model tags may change upstream; record the digest from your own installation when comparing results. The historical `setup-google-translation.sh` downloads exact registry layers into an alternate project store and is not needed for the standard Ollama setup above.

These weights have separate licenses. In particular, TranslateGemma uses Google's Gemma terms rather than this project's MIT license. Installing weights does not imply that you may redistribute them under MIT.

## 5. Build after setup

```sh
xcodebuild -project SubtitleStudy.xcodeproj -scheme SubtitleStudy \
  -configuration Debug -derivedDataPath build build
open "build/Build/Products/Debug/Immersive Learning Player.app"
```

The build copies available Whisper/VAD tools and weights into app resources. MLX weights and Python stay outside the app. Generated `LocalASR.json` records their absolute paths for this checkout; it is never committed. Keep the checkout in place. If you move it, rebuild and update any manually saved paths in Settings.

In Settings, check:

- Recognition: **Qwen3-ASR 1.7B + 时间对齐**.
- FFmpeg: normally `/opt/homebrew/bin/ffmpeg` on Apple Silicon Homebrew.
- Python: `tools/mlx-asr-venv/bin/python` as an absolute path.
- ASR and aligner: the two absolute model directory paths above.
- Ollama: `http://127.0.0.1:11434`; translation model `translategemma:12b`.

New installations with the complete MLX stack are migrated to the quality configuration automatically. Existing manually saved settings can override discovery, so inspect them if recognition does not start.

## Storage and redistribution

No model is downloaded during an Xcode build. An incomplete setup still builds a player, but automatic subtitles require the tools/models above. The full stack and build copies require tens of gigabytes; inference memory and file size are different constraints.

The current source build is for local development, not a portable or notarized app distribution. Before distributing binaries, audit the exact FFmpeg/tool build, bundled notices, model terms, signing, and external runtime paths. FFmpeg is used as an external executable and is not bundled by this project.
