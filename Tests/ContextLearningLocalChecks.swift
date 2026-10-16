import Foundation
import Darwin

// Uses only the existing ASR output, never human reference captions as model input.
@main struct ContextLearningLocalChecks {
    struct Corpus: Decodable { var cases: [Case] }
    struct Case: Decodable { var id: String; var language: String; var cues: [SubtitleCue] }
    struct Row: Encodable { var id: String; var input: [ContextStudyLine]; var result: ContextStudy; var seconds: Double }
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: URL(fileURLWithPath: "tools/real-video-evaluation/asr-results.json")))
        let picks = [("erin23-natural", "付き合った"), ("erin25-natural", "私のセリフ"), ("ted-natural", "high gear")]
        var rows: [Row] = []
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        for (id, needle) in picks {
            let sample = corpus.cases.first { $0.id == id }!
            let cue = sample.cues.first { $0.text.contains(needle) }!
            let model = StudyModel(cacheDirectory: folder, preferredLanguage: sample.language)
            model.language = sample.language; model.cues = sample.cues
            let lines = model.contextStudyLines(for: cue.id)
            let start = Date()
            let result = try await OllamaService.analyzeContext(lines: lines, language: model.languageName, endpoint: "http://127.0.0.1:11434")
            rows.append(Row(id: id, input: lines, result: result, seconds: Date().timeIntervalSince(start)))
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(rows).write(to: URL(fileURLWithPath: "tools/real-video-evaluation/context-learning-results.json"), options: .atomic)
            print("PASS structured local context: \(id) (\(Int(Date().timeIntervalSince(start)))s)")
        }
        print("Saved three actual-model analyses for manual semantic review; schema/evidence checks are not an accuracy percentage.")
    }
}
