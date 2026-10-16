import Foundation

@main struct EnglishPipelineChecks {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let tools = TranscriptionTools(ffmpeg: "/opt/homebrew/bin/ffmpeg", whisper: root.appendingPathComponent("tools/whisper.cpp/static-build/bin/whisper-cli").path, model: root.appendingPathComponent("tools/whisper.cpp/models/ggml-tiny.bin").path)
        let model = StudyModel(cacheDirectory: folder, tools: tools)
        model.autoTranscribe = true; model.autoTranslate = true
        model.language = "ja" // A previous video must not force Japanese on a new English clip.
        let video = root.appendingPathComponent("Samples/English.mp4")
        // An old empty cache must not retain a stale Japanese language or block preparation.
        let empty = SubtitleDocument(source: video.path, cues: [], language: "ja", offset: 1)
        try JSONEncoder().encode(empty).write(to: model.makeCacheURL(video))
        model.loadVideo(video)
        for _ in 0..<600 {
            if model.subtitlePreparationFailed || model.translationFailed { throw StudyError.message(model.status + "\n" + model.taskLog) }
            if !model.busy && !model.cues.isEmpty && model.cues.allSatisfy({ $0.translation != nil }) { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard model.language == "auto", !model.cues.isEmpty,
              model.cues.contains(where: { $0.text.lowercased().contains("english") }),
              model.cues.allSatisfy({ $0.translation?.range(of: "[\\p{Han}]", options: .regularExpression) != nil }) else {
            throw StudyError.message("English pipeline failed: \(model.status), \(model.cues)")
        }
        let cue = model.cues[0]
        model.tick((cue.start + cue.end) / 2)
        guard model.activeID == cue.id else { throw StudyError.message("English subtitle not selected for on-screen display") }
        print("Original: \(cue.text)\nChinese: \(cue.translation ?? "")")
        let ids = model.cues.map(\.id)
        model.loadVideo(video)
        guard model.cues.map(\.id) == ids, !model.busy else { throw StudyError.message("Cache failed to reuse English subtitles") }
        // Missing tools must produce an actionable failure, rather than silently empty subtitles.
        let broken = StudyModel(cacheDirectory: folder.appendingPathComponent("broken"), tools: TranscriptionTools(ffmpeg: "/nonexistent/ffmpeg", whisper: tools.whisper, model: tools.model))
        broken.autoTranscribe = true; broken.loadVideo(video)
        for _ in 0..<50 {
            if broken.subtitlePreparationFailed { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard broken.subtitlePreparationFailed, broken.error != nil else { throw StudyError.message("Missing tools failure remains invisible") }
        print("PASS: auto language, automatic English ASR, Chinese translation, active cue, cache reuse and visible tool failure")
    }
}
