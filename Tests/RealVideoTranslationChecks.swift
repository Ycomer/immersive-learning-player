import Foundation
import Darwin

// Reference captions/Chinese are deliberately absent from the decoding model.
// Fixed time ranges select stress cases; all context comes from ASR output.
@main struct RealVideoTranslationChecks {
    struct Corpus: Decodable { let cases: [Clip] }
    struct Clip: Decodable { let id: String; let language: String; let status: String; let cues: [Cue] }
    struct Cue: Decodable { let start: Double; let end: Double; let text: String; let recognitionConfidence: Double?; let recognitionWarning: String? }
    struct Selection: Decodable { let cases: [Target] }
    struct Target: Decodable { let id: String; let ranges: [[Double]] }
    static func main() async throws {
        setbuf(stdout,nil)
        guard CommandLine.arguments.count == 4 else { throw StudyError.message("Usage: real-video-translation-checks asr.json targets.json report.json") }
        let corpus = try JSONDecoder().decode(Corpus.self,from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        let targets = try JSONDecoder().decode(Selection.self,from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
        var rows: [[String:Any]] = []
        let started = Date()
        for clip in corpus.cases {
            guard clip.status == "completed", let target = targets.cases.first(where: { $0.id == clip.id }) else { continue }
            for (i,cue) in clip.cues.enumerated() {
                guard target.ranges.contains(where: { $0.count == 2 && cue.start < $0[1] && cue.end > $0[0] }) else { continue }
                let before = clip.cues[max(0,i-3)..<i].map(\.text)
                let after = clip.cues[(i+1)..<min(clip.cues.count,i+3)].map(\.text)
                var row: [String:Any] = ["id":clip.id,"cueIndex":i,"start":cue.start,"end":cue.end,"text":cue.text]
                let beginning = Date()
                do {
                    let result = try await OllamaService.translateStudy(text:cue.text,before:before,after:after,
                        model:LocalToolDefaults.qualityTranslationModel,endpoint:"http://127.0.0.1:11434",language:clip.language == "en" ? "英语" : "日语", sourceWarning:cue.recognitionWarning, sourceConfidence:cue.recognitionConfidence)
                    row["translation"] = result.translation
                    row["modelUsed"] = result.modelUsed ?? LocalToolDefaults.qualityTranslationModel
                    row["warning"] = result.warning
                    row["sourceResolved"] = result.modelUsed != "unresolved-source"
                    row["recognitionConfidence"] = cue.recognitionConfidence
                    row["recognitionWarning"] = cue.recognitionWarning
                    row["annotations"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(result.annotations))
                    row["status"] = "completed"
                    print("\(clip.id) #\(i): \(cue.text) → \(result.translation)")
                } catch {
                    row["status"] = "failed"; row["error"] = String(describing:error)
                    print("FAILED \(clip.id) #\(i): \(error)")
                }
                row["processingSeconds"] = Date().timeIntervalSince(beginning)
                rows.append(row)
                let report: [String:Any] = ["method":"production translator; recognized audio text with ASR-only context; no reference Chinese",
                    "endpoint":"http://127.0.0.1:11434","primaryModel":LocalToolDefaults.qualityTranslationModel,
                    "fallbackModel":LocalToolDefaults.explanationModel,"processingSeconds":Date().timeIntervalSince(started),"cues":rows]
                try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to: URL(fileURLWithPath:CommandLine.arguments[3]),options:.atomic)
            }
        }
        if rows.contains(where: { $0["status"] as? String == "failed" }) { exit(EXIT_FAILURE) }
    }
}
