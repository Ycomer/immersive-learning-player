import Foundation
import AVFoundation
import Darwin

// Real-video integration: actual StudyModel / AVPlayer, isolated cache and local models.
@main struct RealVideoPlaybackChecks {
    @MainActor static func main() async throws {
        setbuf(stdout,nil)
        let root = URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:folder) }
        let tools = TranscriptionTools(ffmpeg: "/opt/homebrew/bin/ffmpeg",
            whisper: root.appendingPathComponent("tools/whisper.cpp/static-build/bin/whisper-cli").path,
            model: root.appendingPathComponent("tools/asr-candidates/qwen3-asr-1.7b-8bit").path,
            vadModel: root.appendingPathComponent("tools/whisper.cpp/models/ggml-silero-v6.2.0.bin").path,
            engine: "qwen3-asr", python: root.appendingPathComponent("tools/mlx-asr-venv/bin/python").path,
            worker: root.appendingPathComponent("scripts/local-qwen-asr.py").path,
            alignmentModel: root.appendingPathComponent("tools/asr-candidates/qwen3-forced-aligner-0.6b-8bit").path,
            vadExecutable: root.appendingPathComponent("tools/whisper.cpp/static-build/bin/whisper-vad-speech-segments").path,
            secondaryModel: root.appendingPathComponent("tools/whisper.cpp/models/ggml-large-v3.bin").path)

        let model = StudyModel(cacheDirectory:folder,tools:tools,audioOnly:true,preferredLanguage:CommandLine.arguments.contains("--auto") ? "auto" : "en",translationModel:LocalToolDefaults.qualityTranslationModel)
        model.waitForSubtitles = true
        model.player.isMuted = true
        model.autoTranscribe = true
        let video = CommandLine.arguments.dropFirst().first(where: { $0 != "--auto" }).map { URL(fileURLWithPath:$0) } ?? root.appendingPathComponent("tools/real-video-evaluation/inputs/sintel-soft.mp4")
        model.loadVideo(video)
        func until(_ label:String,_ condition:()->Bool) async throws {
            let deadline = Date().addingTimeInterval(240)
            while !condition() {
                if model.subtitlePreparationFailed || model.translationFailed { throw StudyError.message(model.translationError ?? model.error ?? model.status) }
                guard Date() < deadline else { throw StudyError.message("Timeout: \(label)") }
                try await Task.sleep(nanoseconds:30_000_000)
            }
        }
        try await until("originals") { model.completedChunks.count == 2 && !model.busy }
        guard let night = model.cues.first(where: { $0.text.localizedCaseInsensitiveContains("good night") && $0.text.localizedCaseInsensitiveContains("scales") }), night.start > 22,night.start < 24.5 else { throw StudyError.message("Quiet whole sentence still missing or early") }
        model.tick(10.4)
        guard model.activeID != night.id && model.displayID != night.id else { throw StudyError.message("Night sentence displayed during earlier foley") }
        model.seek(night.start+0.05)
        try await until("seek") { abs(model.currentTime-night.start-0.05) < 0.15 }
        model.autoTranslate = true
        model.requestPlay()
        guard model.waitingForSubtitles && model.player.rate == 0 else { throw StudyError.message("First playback did not buffer missing Chinese") }
        let wait = Date()
        try await until("first Chinese") { !model.waitingForSubtitles && model.playing }
        let seconds = Date().timeIntervalSince(wait)
        model.pausePlayback()
        try await until("complete Chinese") { model.cues.first(where: { $0.id == night.id })?.translationSignature != nil }
        guard model.cues.first(where: { $0.id == night.id })?.translation?.contains("晚安") == true else { throw StudyError.message("Quiet Chinese meaning missing") }
        model.tick(night.start+0.05)
        guard model.activeID == night.id && model.displayID == night.id else { throw StudyError.message("Seek display chose a different sentence") }
        model.autoTranslate = false
        let ids = model.cues.map(\.id)
        model.loadVideo(video)
        guard model.cues.map(\.id) == ids && !model.busy else { throw StudyError.message("New recognition revision/cache was not reused") }
        try await until("cached duration") { model.duration > 0 }
        model.seek(night.start+0.05)
        try await until("cached seek") { abs(model.currentTime-night.start-0.05) < 0.15 }
        model.autoTranslate = true
        model.requestPlay()
        guard !model.waitingForSubtitles else { throw StudyError.message("Replay retranslated a complete cached sentence") }
        try await until("cached replay") { model.playing }
        model.pausePlayback(); model.autoTranslate = false; model.autoTranscribe = false
        let report:[String:Any] = ["method":"actual StudyModel / AVPlayer on real human-voiced film; isolated cache; local models only", "recognitionRevision":RecognitionQuality.revision,"translationRevision":OllamaService.translationRevision,"firstChineseWaitSeconds":seconds,"quietSentenceStart":night.start,"quietSentenceEnd":night.end,
            "passed":["both audio windows","quiet complete sentence","no 13-second premature caption","first-play Chinese buffer and resume","seek display","cache reuse and replay"],"cues":try JSONSerialization.jsonObject(with:JSONEncoder().encode(model.cues))]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent(CommandLine.arguments.contains("--auto") ? "tools/real-video-evaluation/language-mismatch-regression/english-player-result.json" : "tools/real-video-evaluation/player-regression.json"),options:.atomic)
        print("PASS: real video playback, quiet sentence \(night.start)...\(night.end), first Chinese wait \(seconds)s, seek/cache/replay")
    }
}
