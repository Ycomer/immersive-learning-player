import SwiftUI

// A development-only host of the production learning view, using existing real ASR cues.
// Never included in the player target; no model weights or reference answers embedded.
@main struct ContextLearningPreviewApp: App {
    @StateObject private var model: StudyModel
    private let cue: SubtitleCue
    init() {
        struct Corpus: Decodable { struct Sample: Decodable { var id: String; var cues: [SubtitleCue] }; var cases: [Sample] }
        let corpus = try! JSONDecoder().decode(Corpus.self, from: Data(contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tools/real-video-evaluation/asr-results.json")))
        let sample = corpus.cases.first { $0.id == "erin25-natural" }!
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("SubtitleStudyContextPreview")
        let model = StudyModel(cacheDirectory: folder, preferredLanguage: "ja")
        model.language = "ja"; model.cues = sample.cues
        let cue = sample.cues.first { $0.text.contains("私のセリフ") }!
        self.cue = cue; _model = StateObject(wrappedValue: model)
    }
    var body: some Scene {
        Window("语境学习界面检查", id: "context-preview") {
            StudyNotesView(model: model, originalCue: cue).preferredColorScheme(.dark)
        }.defaultSize(width: 520, height: 600)
    }
}
