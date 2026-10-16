import Foundation

@main struct JapaneseAudioChecks {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let video = folder.appendingPathComponent("Japanese.mp4")
        try FileManager.default.copyItem(at: root.appendingPathComponent("Samples/Japanese.mp4"), to: video)
        let oldChinese = "这是已有的中文字幕，不是日文原文。"
        try "1\n00:00:00,000 --> 00:00:07,000\n\(oldChinese)\n".write(to: video.deletingPathExtension().appendingPathExtension("srt"), atomically: true, encoding: .utf8)
        let chosenModel = CommandLine.arguments.dropFirst().first ?? root.appendingPathComponent("tools/whisper.cpp/models/ggml-small.bin").path
        let tools = TranscriptionTools(ffmpeg: "/opt/homebrew/bin/ffmpeg", whisper: root.appendingPathComponent("tools/whisper.cpp/static-build/bin/whisper-cli").path, model: chosenModel)
        let chosenTranslation = CommandLine.arguments.dropFirst(2).first ?? LocalToolDefaults.translationModel
        let model = StudyModel(cacheDirectory: folder.appendingPathComponent("cache"), tools: tools, audioOnly: true, preferredLanguage: "ja", translationModel: chosenTranslation)
        try FileManager.default.createDirectory(at: model.cacheDirectory, withIntermediateDirectories: true)
        let stale = SubtitleDocument(source: video.path, cues: [SubtitleCue(start: 0, end: 7, text: oldChinese)], language: "ja", generationSignature: "import:Chinese.srt")
        try JSONEncoder().encode(stale).write(to: model.makeCacheURL(video))
        model.autoTranscribe = true; model.autoTranslate = true
        model.loadVideo(video)
        guard model.cues.isEmpty && model.language == "ja" else { throw StudyError.message("Reused Chinese source or wrong recognition language") }
        for _ in 0..<900 {
            if model.subtitlePreparationFailed || model.translationFailed { throw StudyError.message(model.status + model.taskLog) }
            if !model.busy && !model.translating && !model.cues.isEmpty && model.cues.allSatisfy({ $0.translation != nil && $0.translationSignature != nil }) { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard !model.cues.isEmpty, model.cues.contains(where: { $0.text.contains("天気") }),
              model.cues.allSatisfy({ $0.text != oldChinese && $0.translation?.range(of: "[\\p{Han}]", options: .regularExpression) != nil }) else {
            throw StudyError.message("Japanese Small recognition or Chinese translation failed: \(model.cues)")
        }
        let IDs = model.cues.map(\.id)
        model.loadVideo(video)
        guard model.cues.map(\.id) == IDs else { throw StudyError.message("Audio-derived Japanese cache not restored") }
        guard model.cues.allSatisfy({ $0.translation != nil && $0.translationSignature != nil }) else { throw StudyError.message("Finished Chinese translation cache not restored") }
        let tiny = TranscriptionTools(ffmpeg: tools.ffmpeg, whisper: tools.whisper, model: root.appendingPathComponent("tools/whisper.cpp/models/ggml-tiny.bin").path)
        let other = StudyModel(cacheDirectory: model.cacheDirectory, tools: tiny, preferredLanguage: "ja")
        guard other.makeCacheURL(video) != model.makeCacheURL(video) else { throw StudyError.message("Different ASR model profiles share cache") }
        for cue in model.cues { print("日文：\(cue.text)\n中文：\(cue.translation ?? "")") }
        print("PASS: ignores Chinese sidecar and imported cache, \(URL(fileURLWithPath: chosenModel).lastPathComponent) Japanese ASR, Chinese translation, profile isolation and cache reuse")
    }
}
