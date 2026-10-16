# Third-party components and models

The root MIT license covers project-authored source only. This source repository does not include third-party runtime binaries, model weights, downloaded corpora, or evaluation videos. Downloaded components retain their upstream copyrights and terms.

| Component | Source / terms | How it is used |
| --- | --- | --- |
| whisper.cpp | [Repository and MIT license](https://github.com/ggml-org/whisper.cpp) | A pinned checkout is patched locally for JSON evidence/time mapping and built by setup. Its license is copied when the CLI is bundled. |
| Whisper weights | [OpenAI Whisper, MIT](https://github.com/openai/whisper) | Downloaded separately in GGML format for local recognition/review. |
| Silero VAD | [Repository and MIT license](https://github.com/snakers4/silero-vad) | Downloaded separately; model license copied into app resources. |
| MLX / MLX Audio | [MLX](https://github.com/ml-explore/mlx), [MLX Audio](https://github.com/Blaizzy/mlx-audio), MIT | Installed in the local Python environment; not vendored here. |
| Qwen3 ASR 1.7B and ForcedAligner 0.6B | [ASR conversion](https://huggingface.co/mlx-community/Qwen3-ASR-1.7B-8bit), [aligner conversion](https://huggingface.co/mlx-community/Qwen3-ForcedAligner-0.6B-8bit), model cards identify Apache-2.0 | Separate model downloads. Review upstream/conversion terms before redistribution. |
| Qwen3 4B Instruct | [Ollama model page](https://ollama.com/library/qwen3:4b-instruct) | Local explanation/fallback model; keep the license supplied with the selected weights. |
| TranslateGemma | [Google model card and terms](https://huggingface.co/google/translategemma-12b-it), [Ollama distribution](https://ollama.com/library/translategemma:12b) | Separate download subject to Gemma terms; not relicensed under MIT. |
| Ollama | [Repository and MIT license](https://github.com/ollama/ollama) | User-installed local model service. Model licenses are separate. |
| FFmpeg | [Legal and license information](https://ffmpeg.org/legal.html) | User-installed command-line executable. Licensing depends on build options; it is not bundled. |
| Python packages | Package metadata and bundled notices | Installed dependencies retain their own licenses. `requirements-local-asr.txt` is not a redistribution license. |

Dictionary/source URLs in the app identify references used for short, project-authored learning explanations. No dictionary database is bundled. Audio/video from third-party publishers and their captions are not redistributed. Evaluation utilities require separately obtained lawful inputs; source availability is not permission to republish a media file or transcript.
