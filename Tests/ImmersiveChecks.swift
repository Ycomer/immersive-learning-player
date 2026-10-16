import Foundation

@main struct ImmersiveChecks {
    @MainActor static func main() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = StudyModel(cacheDirectory: folder.appendingPathComponent("cache"))
        let video = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Samples/Japanese.mp4")
        model.loadVideo(video)
        model.cues = [
            SubtitleCue(start: 0, end: 2, text: "今日はいい天気ですね。"),
            SubtitleCue(start: 2, end: 4, text: "私は日本語を勉強しています。"),
            SubtitleCue(start: 4, end: 6.5, text: "もう一度聞いてみましょう。"),
            SubtitleCue(start: 7, end: 9, text: "ありがとうございます。")
        ]
        model.tick(0)
        model.autoTranslate = true
        for _ in 0..<200 {
            if model.translationFailed { throw StudyError.message(model.status) }
            if !model.translating && model.cues.prefix(3).allSatisfy({ $0.translation != nil }) { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard model.cues.prefix(3).allSatisfy({ $0.translation != nil }), model.cues[3].translation == nil else {
            throw StudyError.message("Current cue plus two-cue prefetch failed")
        }
        model.autoTranslate = false
        model.tick(3)
        guard model.activeID == model.cues[1].id else { throw StudyError.message("Wrong on-screen subtitle after seek") }
        model.tick(6.7)
        guard model.activeID == nil else { throw StudyError.message("Subtitle persists in a gap") }
        model.loadVideo(video)
        guard model.cues.prefix(3).allSatisfy({ $0.translation != nil }) else { throw StudyError.message("Translations were not cached") }
        print("PASS: real Qwen3 automatic translation, bounded two-cue prefetch, seek, gaps and cache")
    }
}
