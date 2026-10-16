import Foundation
import Darwin

// Diagnostic only: references are never sent to the translation model and no
// automated "meaning accuracy percentage" is inferred from text similarity.
@main struct ParallelTranslationProbe {
    struct References: Decodable {
        var cases: [Reference]
        struct Reference: Decodable {
            var id: String
            var japaneseReference: String
            var chineseReference: String
            var asrCaseID: String
        }
    }
    struct ASR: Decodable {
        var cases: [Case]
        struct Case: Decodable { var id: String; var hypothesis: String }
    }
    struct Result: Codable {
        var id: String
        var japaneseReference: String
        var chineseReference: String
        var recognizedJapanese: String
        var fromReference: StudyTranslation
        var fromRecognition: StudyTranslation
    }
    static func main() async throws {
        setbuf(stdout, nil)
        guard (4...5).contains(CommandLine.arguments.count) else { throw StudyError.message("Usage: parallel-translation-probe references.json asr.json result.json [model]") }
        let chosenModel = CommandLine.arguments.dropFirst(4).first ?? LocalToolDefaults.translationModel
        let refs = try JSONDecoder().decode(References.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        let asr = try JSONDecoder().decode(ASR.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
        let byID = Dictionary(uniqueKeysWithValues: asr.cases.map { ($0.id, $0.hypothesis) })
        var results: [Result] = []
        for reference in refs.cases {
            guard let recognized = byID[reference.asrCaseID] else { throw StudyError.message("Missing ASR case \(reference.asrCaseID)") }
            let clean = try await OllamaService.translateStudy(text: reference.japaneseReference, before: [], after: [], model: chosenModel, endpoint: "http://127.0.0.1:11434", language: "日语")
            let actual = recognized == reference.japaneseReference ? clean : try await OllamaService.translateStudy(text: recognized, before: [], after: [], model: chosenModel, endpoint: "http://127.0.0.1:11434", language: "日语")
            results.append(Result(id: reference.id, japaneseReference: reference.japaneseReference, chineseReference: reference.chineseReference, recognizedJapanese: recognized, fromReference: clean, fromRecognition: actual))
            try JSONEncoder().encode(results).write(to: URL(fileURLWithPath: CommandLine.arguments[3]), options: .atomic)
            print("\(results.count)/\(refs.cases.count) paired diagnostic complete; semantic accuracy remains unverified")
        }
    }
}
