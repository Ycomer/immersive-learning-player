# Contributing

Bug reports and focused pull requests are welcome. The app is an early macOS/Apple Silicon development preview, with a Chinese interface and a local-only inference architecture.

1. Describe the specific playback/subtitle/learning behavior you want to change.
2. Keep model setup/download operations separate from runtime inference. Runtime must not add a cloud API dependency.
3. Run `sh scripts/check.sh` on macOS with Xcode and FFmpeg. For inference changes, also use opt-in local model tests and document the exact model digests and sample provenance.
4. Explain what changed, how it was checked, and remaining limitations. Never claim a recognition or semantic accuracy percentage without an independent, appropriate reference.

Use fabricated or consented minimal examples. Do not commit videos, full publisher caption files, model weights, environments, generated reports, local absolute paths, credentials, or personal caches. For timing issues, include the speech onset, subtitle onset, and whether replaying a processed interval changes the behavior. Distinguish recognition errors, translation errors, and generation latency.

Project contributions are provided under the repository's MIT license. Third-party components and media keep their own licenses.
