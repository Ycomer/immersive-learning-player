import SwiftUI

// Small isolated UI fixture: does not change the user's player, video or preferences.
@main struct StudyNotesPreview: App {
    @StateObject private var model = StudyModel(cacheDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("StudyNotesPreview"), audioOnly: false, preferredLanguage: "ja", translationModel: "qwen3:4b-instruct")
    var body: some Scene {
        Window("表达注释检查", id: "preview") {
            StudyView(model: model).preferredColorScheme(.dark)
                .frame(minWidth: 760, minHeight: 460)
                .onAppear {
                    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    model.loadVideo(root.appendingPathComponent("Samples/Japanese.mp4"))
                    if let data = try? Data(contentsOf: root.appendingPathComponent("build/study-notes-preview.json")), let cue = try? JSONDecoder().decode(SubtitleCue.self, from: data) {
                        model.cues = [cue]; model.tick(0)
                    }
                }
        }.windowStyle(.hiddenTitleBar).defaultSize(width: 1000, height: 650)
    }
}
