import Foundation
import AVFoundation

final class LanguageMemoryDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String:Any] = ["audioRecognitionLanguage":"en"]
    init() { super.init(suiteName:"SubtitleStudy.LanguageChecks")! }
    override func string(forKey key:String)->String? { values[key] as? String }
    override func set(_ value:Any?,forKey key:String) { values[key]=value }
}
@main struct VideoLanguagePreferenceChecks {
    @MainActor static func main() throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:folder) }
        let preferences=LanguageMemoryDefaults()
        let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
        let japanese=root.appendingPathComponent("tools/real-video-evaluation/inputs/erin23-natural.mp4")
        let english=root.appendingPathComponent("tools/real-video-evaluation/inputs/sintel-soft.mp4")
        let model=StudyModel(cacheDirectory:folder,recognitionPreferences:preferences)
        model.loadVideo(japanese)
        guard model.language == "auto" else { throw StudyError.message("New Japanese file inherited global English") }
        let autoCache=model.makeCacheURL(japanese)
        model.chooseRecognitionLanguage("ja");model.autoTranscribe=false
        guard model.language == "ja",model.makeCacheURL(japanese) != autoCache else { throw StudyError.message("Manual language/cache isolation failed") }
        model.loadVideo(english)
        guard model.language == "auto" else { throw StudyError.message("English file inherited Japanese override") }
        model.chooseRecognitionLanguage("en");model.autoTranscribe=false
        model.loadVideo(japanese)
        guard model.language == "ja" else { throw StudyError.message("Japanese file override lost") }
        let reopened=StudyModel(cacheDirectory:folder,recognitionPreferences:preferences)
        reopened.loadVideo(english)
        guard reopened.language == "en",preferences.string(forKey:"audioRecognitionLanguage") == "en" else { throw StudyError.message("Per-video language did not persist independently") }
        preferences.set("invalid",forKey:StudyModel.recognitionLanguageKey(for:japanese))
        reopened.loadVideo(japanese)
        guard reopened.language == "auto" else { throw StudyError.message("Invalid stored language not rejected") }
        let forced=StudyModel(cacheDirectory:folder,preferredLanguage:"ja")
        forced.loadVideo(japanese)
        guard forced.language == "ja" else { throw StudyError.message("Explicit test/initial override ignored") }
        print("PASS: stale global English ignored; new files auto-detect; per-video overrides persist and remain isolated; language-specific caches; invalid preferences rejected")
    }
}
