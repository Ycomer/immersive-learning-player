import Foundation
import AVFoundation
import Darwin

// Real video, production StudyModel, real local ASR and translation. No references
// are injected. The corpus script remains the separate transcription scorer.
@main struct LocalQualityPlaybackChecks {
    @MainActor static func main() async throws {
        setbuf(stdout,nil)
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let tools = TranscriptionTools(ffmpeg: "/opt/homebrew/bin/ffmpeg", whisper: root.appendingPathComponent("tools/whisper.cpp/static-build/bin/whisper-cli").path,
            model: root.appendingPathComponent("tools/asr-candidates/qwen3-asr-1.7b-8bit").path,
            vadModel: root.appendingPathComponent("tools/whisper.cpp/models/ggml-silero-v6.2.0.bin").path,
            engine: "qwen3-asr", python: root.appendingPathComponent("tools/mlx-asr-venv/bin/python").path,
            worker: root.appendingPathComponent("scripts/local-qwen-asr.py").path,
            alignmentModel: root.appendingPathComponent("tools/asr-candidates/qwen3-forced-aligner-0.6b-8bit").path,
            vadExecutable: root.appendingPathComponent("tools/whisper.cpp/static-build/bin/whisper-vad-speech-segments").path,
            secondaryModel: root.appendingPathComponent("tools/whisper.cpp/models/ggml-large-v3.bin").path)
        let model = StudyModel(cacheDirectory: folder, tools: tools, audioOnly: true, preferredLanguage: "ja", translationModel: LocalToolDefaults.qualityTranslationModel)
        model.waitForSubtitles = true
        model.player.isMuted = true; model.autoTranscribe = true
        let started = Date()
        model.loadVideo(root.appendingPathComponent("tools/wavesubs-evaluation/inputs/generated-dialogue.mp4"))
        func until(_ message: String, _ predicate: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(240)
            while !predicate() {
                if model.subtitlePreparationFailed || model.translationFailed { throw StudyError.message(model.translationError ?? model.error ?? model.status) }
                guard Date() < deadline else { throw StudyError.message("Timed out: \(message)") }
                try await Task.sleep(nanoseconds: 30_000_000)
            }
        }
        try await until("original preparation") { model.completedChunks.count == 3 && !model.busy }
        guard model.cues.contains(where: { $0.text.contains("夕方") }) else { throw StudyError.message("Quiet sentence missing") }
        print("Real player original complete: \(model.cues.count) cues, \(Date().timeIntervalSince(started))s")
        model.seek(15.8); model.autoTranslate = true; model.requestPlay()
        guard model.waitingForSubtitles && model.player.rate == 0 else { throw StudyError.message("First quiet playback did not buffer missing Chinese") }
        let waitingStart = Date()
        try await until("first quiet Chinese") { !model.waitingForSubtitles && model.playing }
        let firstWait = Date().timeIntervalSince(waitingStart)
        model.pausePlayback()
        print("Real first quiet Chinese ready after \(firstWait)s; playback resumed")
        let originals = model.cues
        for (i,cue) in originals.enumerated() {
            model.seek(cue.start + min(0.08,(cue.end-cue.start)/2))
            model.requestPlay()
            try await until("cue \(i)") { model.cues.first(where: { $0.id == cue.id })?.translationSignature != nil }
            model.pausePlayback()
            print("\(i+1)/\(originals.count): \(cue.text) → \(model.cues.first(where: { $0.id == cue.id })!.translation!)")
        }
        model.autoTranslate = false; model.autoTranscribe = false
        let face = model.cues.first { $0.text.contains("顔が広") }
        let cat = model.cues.first { $0.text.contains("猫を") }
        guard face?.translation?.contains("人脉") == true || face?.translation?.contains("交际") == true,
              cat?.translation?.contains("装") == true,
              cat?.annotations?.first?.sourceURL != nil,
              model.cues.allSatisfy({ ChineseTranslationCheck.isValid($0.translation ?? "") }) else { throw StudyError.message("Idiom meaning, sourced annotation or complete Chinese check failed") }
        let report: [String: Any] = ["id":"generated-dialogue", "method":"real StudyModel; source video; local Qwen ASR/aligner + local TranslateGemma + sourced idiom guide",
            "firstQuietTranslationWaitSeconds":firstWait, "processingSeconds":Date().timeIntervalSince(started),
            "cues":try JSONSerialization.jsonObject(with: JSONEncoder().encode(model.cues)),
            "passed":["all 3 audio windows", "quiet speech retained", "first playback buffered until Chinese", "seek and resume", "idiom meanings and sourced notes", "no kana in Chinese"]]
        try JSONSerialization.data(withJSONObject: report,options:[.prettyPrinted,.sortedKeys]).write(to: root.appendingPathComponent("tools/wavesubs-evaluation/player-local-stack-results.json"),options:.atomic)
        print("PASS: real local stack playback, quiet buffering, seeks, idioms, all translations")
    }
}
