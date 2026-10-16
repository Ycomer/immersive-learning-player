import Foundation
import Darwin

@main struct StudyPipelineChecks {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let chosenModel = CommandLine.arguments.dropFirst().first ?? "qwen3:4b-instruct"
        let model = StudyModel(cacheDirectory: folder, audioOnly: false, preferredLanguage: "ja", translationModel: chosenModel)
        let video = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Samples/Japanese.mp4")
        model.loadVideo(video)
        model.cues = [SubtitleCue(start: 0, end: 2, text: "彼は猫をかぶっている。", translation: "他戴着猫。"), SubtitleCue(start: 2, end: 4, text: "普段はもっと乱暴なのにね。"), SubtitleCue(start: 4, end: 6, text: "今日は雨です。"), SubtitleCue(start: 8, end: 10, text: "ありがとうございます。")]
        model.tick(0); model.autoTranslate = true
        var sawEarlyTranslation = false
        for _ in 0..<1200 {
            if model.translationFailed { throw StudyError.message(model.translationError ?? model.status) }
            if let translation = model.cues.first?.translation, translation.contains("装"), model.cues.first?.translationSignature == nil { sawEarlyTranslation = true }
            if !model.translating && model.cues.prefix(3).allSatisfy({ $0.translationSignature != nil }) { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard sawEarlyTranslation, model.cues[0].translation?.contains("装") == true,
              !(model.cues[0].annotations ?? []).isEmpty, model.cues.prefix(3).allSatisfy({ $0.translationSignature != nil }), model.cues[3].translation == nil else { throw StudyError.message("Early publication, annotations or two-cue prefetch failed") }
        model.autoTranslate = false
        let translated = model.cues
        try JSONEncoder().encode(translated[0]).write(to: URL(fileURLWithPath: "build/study-notes-preview.json"))
        model.loadVideo(video)
        guard model.cues == translated else { throw StudyError.message("Learning annotations or translation profile not cached") }
        model.edit(model.cues[0].id, text: "彼は顔が広い。")
        guard model.cues[0].translation == nil, model.cues[0].annotations == nil, model.cues[0].translationSignature == nil else { throw StudyError.message("Editing retained old translation or notes") }
        let changedModel = StudyModel(cacheDirectory: folder, audioOnly: false, preferredLanguage: "ja", translationModel: "qwen3:1.7b")
        changedModel.autoTranslate = true
        changedModel.loadVideo(video)
        changedModel.autoTranslate = false
        guard changedModel.cues.prefix(3).allSatisfy({ $0.translation == nil && $0.annotations == nil }), changedModel.cues[0].text == "彼は顔が広い。" else { throw StudyError.message("Changed translation model reused stale translations or lost source edits") }
        print("PASS: early translation before notes, bounded prefetch, original-preserving regeneration, annotation cache, edit invalidation and model profile isolation")
    }
}
