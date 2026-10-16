import Foundation
import Darwin

// Exercise the production translator on ASR output. Never load reference Chinese.
@main struct LocalQualityTranslationProbe {
    struct Corpus: Decodable { var cases: [Case] }
    struct Case: Decodable { var id: String; var language: String?; var cues: [Cue] }
    struct Cue: Decodable { var start: Double; var end: Double; var text: String }
    static func main() async throws {
        setbuf(stdout, nil)
        guard (4...6).contains(CommandLine.arguments.count) else { throw StudyError.message("Usage: local-quality-translation-probe asr.json case-id result.json [model] [contains]") }
        let chosenModel = CommandLine.arguments.count > 4 ? CommandLine.arguments[4] : LocalToolDefaults.qualityTranslationModel
        let filter = CommandLine.arguments.count > 5 ? CommandLine.arguments[5] : nil
        let input = URL(fileURLWithPath: CommandLine.arguments[1])
        let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: input))
        guard let item = corpus.cases.first(where: { $0.id == CommandLine.arguments[2] }) else { throw StudyError.message("Case not found") }
        let started = Date()
        var results: [[String: Any]] = []
        for (i,cue) in item.cues.enumerated() {
            if let filter, !cue.text.contains(filter) { continue }
            let before = item.cues[max(0,i-3)..<i].map(\.text)
            let after = item.cues[(i+1)..<min(item.cues.count,i+3)].map(\.text)
            let language = ["ja":"日语", "en":"英语", "ko":"韩语", "zh":"中文"][item.language ?? "ja"] ?? "日语"
            let result = try await OllamaService.translateStudy(text: cue.text, before: before, after: after, model: chosenModel, endpoint: "http://127.0.0.1:11434", language: language)
            let value: [String: Any] = ["startMs": Int((cue.start*1000).rounded()), "endMs": Int((cue.end*1000).rounded()), "text": cue.text,
                "translation": result.translation, "modelUsed": result.modelUsed ?? chosenModel, "annotations": try JSONSerialization.jsonObject(with: JSONEncoder().encode(result.annotations)), "plainMeaning": result.plainMeaning ?? "", "warning": result.warning]
            results.append(value)
            let report: [String: Any] = ["id": item.id, "model": chosenModel,
                "method": "production OllamaService; ASR text, context and sourced idiom guide; no reference Chinese", "endpoint": "127.0.0.1:11434", "processingSeconds": Date().timeIntervalSince(started), "cues": results]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[3]), options: .atomic)
            print("\(i+1)/\(item.cues.count) · \(cue.text) → \(result.translation)")
        }
    }
}
