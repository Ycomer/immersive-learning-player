import Foundation
import Darwin

@main struct SelectedWordLocalChecks {
    struct Corpus: Decodable { var cases: [Sample] }
    struct Sample: Decodable { var id: String; var language: String; var cues: [SubtitleCue] }
    struct Row: Encodable { var id: String; var selection: SubtitleWordSelection; var comparison: String?; var lines: [ContextStudyLine]; var result: ContextStudy; var seconds: Double }
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: URL(fileURLWithPath: "tools/real-video-evaluation/asr-results.json")))
        let picks: [(String, String, String?, Bool)] = [("erin23-natural", "付き合った", nil, true), ("erin25-natural", "セリフ", "言葉", false), ("ted-natural", "high gear", "full speed", false), ("ted-natural", "gear", "speed", true)]
        var rows: [Row] = []
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        for (id, expression, comparison, click) in picks {
            let sample = corpus.cases.first { $0.id == id }!
            let cue = sample.cues.first { $0.text.contains(expression) }!
            let range = (cue.text as NSString).range(of: expression)
            let selection = click ? SubtitleWordSelection.word(in: cue.text, atUTF16: range.location)! : SubtitleWordSelection.selected(in: cue.text, range: range)!
            let model = StudyModel(cacheDirectory: directory, preferredLanguage: sample.language)
            model.language = sample.language; model.cues = sample.cues
            let lines = model.contextStudyLines(for: cue.id)
            let start = Date()
            let result = try await OllamaService.analyzeContext(lines: lines, language: model.languageName, endpoint: "http://127.0.0.1:11434", selection: selection, comparison: comparison)
            _ = try result.validated(lines: lines, selection: selection)
            rows.append(Row(id: id, selection: selection, comparison: comparison, lines: lines, result: result, seconds: Date().timeIntervalSince(start)))
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(rows).write(to: URL(fileURLWithPath: "tools/real-video-evaluation/selected-word-results.json"), options: .atomic)
            print("PASS selected local word: \(id), \(selection.expression) → \(result.words[0].replacement ?? "missing"), \(Int(Date().timeIntervalSince(start)))s")
        }
        print("Actual local inference complete; exact selection and replacement checks do not certify semantic accuracy.")
    }
}
