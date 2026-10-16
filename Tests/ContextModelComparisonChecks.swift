import Foundation
import CryptoKit
import Darwin

struct ModelCallTrace: Codable, Sendable {
    var model: String
    var inputHash: String
    var wallSeconds: Double
    var totalSeconds: Double?
    var loadSeconds: Double?
    var promptTokens: Int?
    var outputTokens: Int?
    var promptSeconds: Double?
    var decodeSeconds: Double?
    var doneReason: String?
    var thinkingCharacters: Int
    var content: String
}
actor ModelTraceCollector {
    var traces: [ModelCallTrace] = []
    func append(_ value: ModelCallTrace) { traces.append(value) }
    func take() -> [ModelCallTrace] { defer { traces = [] }; return traces }
}
final class ModelTimingProtocol: URLProtocol, @unchecked Sendable {
    static let collector = ModelTraceCollector()
    static let forwarding: URLSession = {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = []
        config.timeoutIntervalForRequest = 240; config.timeoutIntervalForResource = 300
        return URLSession(configuration: config)
    }()
    private var work: Task<Void, Never>?
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "127.0.0.1" && request.url?.path == "/api/chat" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&bytes, maxLength: bytes.count); if n <= 0 { break }; body.append(contentsOf: bytes.prefix(n)) }
        }
        var forwarded = request; forwarded.httpBody = body
        let payload = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        let model = payload["model"] as? String ?? "unknown"
        var normalized = payload; normalized.removeValue(forKey: "model")
        let encoded = (try? JSONSerialization.data(withJSONObject: normalized, options: [.sortedKeys])) ?? body
        let hash = SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
        let started = Date()
        work = Task {
            do {
                let (data, response) = try await Self.forwarding.data(for: forwarded)
                let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
                func seconds(_ key: String) -> Double? { (object[key] as? NSNumber).map { $0.doubleValue/1e9 } }
                let message = object["message"] as? [String: Any] ?? [:]
                await Self.collector.append(ModelCallTrace(model: model, inputHash: hash, wallSeconds: Date().timeIntervalSince(started), totalSeconds: seconds("total_duration"), loadSeconds: seconds("load_duration"), promptTokens: object["prompt_eval_count"] as? Int, outputTokens: object["eval_count"] as? Int, promptSeconds: seconds("prompt_eval_duration"), decodeSeconds: seconds("eval_duration"), doneReason: object["done_reason"] as? String, thinkingCharacters: (message["thinking"] as? String)?.count ?? 0, content: String((message["content"] as? String ?? "").prefix(16000))))
                try Task.checkCancellation()
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
            } catch { if !Task.isCancelled { client?.urlProtocol(self, didFailWithError: error) } }
        }
    }
    override func stopLoading() { work?.cancel() }
}

@main struct ContextModelComparisonChecks {
    struct Corpus: Decodable { var cases: [Sample] }
    struct Sample: Decodable { var id: String; var language: String; var cues: [SubtitleCue] }
    struct TestCase: Codable {
        var id: String; var clip: String; var language: String
        var lines: [ContextStudyLine]; var selection: SubtitleWordSelection?; var comparison: String?
        var reviewPoints: [String] // Not passed to inference.
    }
    struct Row: Codable {
        var caseID: String; var model: String; var repetition: Int; var wallSeconds: Double
        var result: ContextStudy?; var error: String?; var calls: [ModelCallTrace]
        var residentModels: String
    }
    struct Report: Codable {
        var model: String; var warmup: String; var cases: [TestCase]; var rows: [Row]
        var downloadCompletedAtStart: Bool
        var generationConfigurationDescription = "think=false; num_predict=2200; temperature=0; top_p=0.8; presence_penalty=0; top_k=20; min_p=0; repeat_penalty=1; frequency_penalty=0; seed=42; num_ctx=8192"
        var protocolDescription = "Production analyzeContext, identical text/selection/schema/options except model; local HTTP only; references/reviewPoints excluded from prompts. First attempts must have paired input hashes. Model warmup kept separate; retries included in wall times. No semantic accuracy percentage."
    }
    static func call(_ path: String, _ value: [String: Any]? = nil) async throws -> Data {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/"+path)!)
        request.timeoutInterval = 240
        if let value { request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject: value); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw StudyError.message(String(decoding: data.prefix(2000), as: UTF8.self)) }
        return data
    }
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let chosen = CommandLine.arguments.dropFirst().first ?? "qwen3:4b-instruct"
        guard ["qwen3:4b-instruct", "qwen3.5:9b-q4_K_M"].contains(chosen) else { throw StudyError.message("Only the two authorized local candidates are allowed") }
        let regression = CommandLine.arguments.contains("--regression")
        let out = URL(fileURLWithPath: regression ? "tools/real-video-evaluation/context-4b-regression" : "tools/real-video-evaluation/qwen35-comparison")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: URL(fileURLWithPath: "tools/real-video-evaluation/asr-results.json")))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        var cases: [TestCase] = []
        func add(_ id: String, _ clip: String, _ index: Int, word: String? = nil, compare: String? = nil, click: Bool = false, points: [String]) {
            let sample = corpus.cases.first { $0.id == clip }!, cue = sample.cues[index]
            let model = StudyModel(cacheDirectory: folder, preferredLanguage: sample.language)
            model.cues = sample.cues; model.language = sample.language
            let selection = word.map { word -> SubtitleWordSelection in
                let range = (cue.text as NSString).range(of: word)
                return click ? SubtitleWordSelection.word(in: cue.text, atUTF16: range.location)! : SubtitleWordSelection.selected(in: cue.text, range: range)!
            }
            cases.append(TestCase(id: id, clip: clip, language: model.languageName, lines: model.contextStudyLines(for: cue.id), selection: selection, comparison: compare, reviewPoints: points))
        }
        add("ja-reassurance-context", "erin17-natural", 16, points: ["Reject the prior assumption of disapproval, while retaining liking the picture.", "Do not invent romance, apology, or compliment recipient."])
        add("ja-surprise-disappointment", "erin17-natural", 16, word: "驚いた", compare: "呆れた", points: ["Surprise is not necessarily disappointment; prior context contrasts the two.", "Past form and positive liking remain; do not reverse ううん or けど."])
        add("ja-cinema-context", "erin23-natural", 4, points: ["Counter the claim that they have not come to the cinema together for a while.", "Accompanying is supported; dating is not established."])
        add("ja-accompany-word", "erin23-natural", 4, word: "付き合った", click: true, points: ["Explain accompanying in this cinema conversation; do not assert dating.", "A replacement should not be presented as an equivalent if it adds only/alone or removes company."])
        add("ja-retort-context", "erin25-natural", 15, points: ["The preceding person objects to being paired with the other.", "This is a reciprocal retort: that is my line / I should be saying that, not a theatre plot."])
        add("ja-line-versus-words", "erin25-natural", 15, word: "セリフ", compare: "言葉", points: ["Preserve the retort meaning and first person.", "Generic words does not automatically preserve the idiomatic that-is-my-line retort."])
        add("en-plan-context", "ted-natural", 15, points: ["Narrating a past intended plan, not giving advice to the audience.", "Figurative work intensity, not actual driving."])
        add("en-high-gear-full-speed", "ted-natural", 15, word: "high gear", compare: "full speed", points: ["Judge the actual unchanged structure kick it up into full speed; a different collocation may be needed.", "Do not claim all other stages/time markers changed."])
        add("en-gear-speed", "ted-natural", 15, word: "gear", compare: "speed", click: true, points: ["into high gear is a fixed figurative construction; replacing just gear does not automatically yield natural phrasing.", "Explain the selected noun's role, not solely a dictionary list."])
        add("en-dear-context", "sintel-dialogue", 8, points: ["Someone dear is cherished, not necessarily expensive.", "Next lines mention a kindred spirit/dragon; do not assert a spouse, child or specific backstory."])
        add("en-dear-expensive", "sintel-dialogue", 8, word: "dear", compare: "expensive", points: ["The cherished versus costly senses differ; expensive is not equivalent here.", "The phrase Someone very must remain unchanged in the actual experiment."])
        add("en-quiet-clip-context", "sintel-soft", 2, points: ["Good night addresses someone/something; scales may be an address/nickname.", "Do not invent unseen care actions, family relationship, location or plot."])
        add("en-still-quiet", "sintel-soft", 1, word: "still", compare: "quiet", click: true, points: ["sit still concerns movement; quiet concerns noise/calmness, so not an equivalent instruction.", "Do not confidently invent visual scene details."])
        if regression {
            add("ja-negated-promise-holdout", "erin17-natural", 9, word: "笑わない", compare: "笑う", points: ["The original promises not to laugh; the requested positive replacement changes the promise, and must not be presented as equivalent.", "No invented romance or visual action."])
            add("ja-explicit-family-holdout", "erin23-natural", 9, points: ["母親 explicitly mentions the speaker's mother; retain this stated relationship without inventing other relationships.", "なのに contrasts with prior context; do not invent jealousy or gender."])
            add("ja-letter-promise-holdout", "erin25-natural", 5, points: ["Follows asking for an address and gives writing letters as a reason.", "Cannot establish romance, exact recipient identity, or permanent separation from the local window."])
            add("en-alone-lonely-holdout", "sintel-dialogue", 12, word: "alone", compare: "lonely", points: ["Alone describes being by oneself; lonely adds a feeling of loneliness not asserted by alone.", "Do not turn lone hunter into family history or a romance."])
        }
        let casesData = try JSONEncoder().encode(cases)
        try casesData.write(to: out.appendingPathComponent("cases.json"), options: .atomic)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ModelTimingProtocol.self]
        let measured = URLSession(configuration: config); defer { measured.invalidateAndCancel() }
        // Unload only this player's known models, keeping all files/configuration intact.
        for model in ["translategemma:12b", "qwen3:4b-instruct", "qwen3.5:9b-q4_K_M"] {
            _ = try? await call("generate", ["model": model, "stream": false, "keep_alive": 0])
        }
        let warmup = try await call("chat", ["model": chosen, "stream": false, "think": false, "keep_alive": "10m", "messages": [["role": "user", "content": "只回复：就绪"]], "options": ["num_ctx": 8192, "num_predict": 16, "temperature": 0]])
        var report = Report(model: chosen, warmup: String(decoding: warmup, as: UTF8.self), cases: cases, rows: [], downloadCompletedAtStart: FileManager.default.fileExists(atPath: "build/qwen35-download-verified.json"))
        if regression {
            report.protocolDescription = "4B context-learning regression on the same real-video ASR text windows and selections; revised production prompt and requested-synonym constraints, fixed generation configuration matching the historical 4B run. References/reviewPoints excluded from prompts. Prior results preserved in qwen35-comparison. No accuracy percentage."
        }
        let smoke = CommandLine.arguments.contains("--smoke")
        let recommended = CommandLine.arguments.contains("--recommended")
        let diagnostic = CommandLine.arguments.contains("--diagnostic")
        let reasoning = CommandLine.arguments.contains("--reasoning")
        let generation: StudyGenerationConfiguration = reasoning ? .reasoning : recommended ? .recommended : .init()
        if reasoning || recommended {
            report.protocolDescription = "Additional candidate-only diagnostic using the production context service; sampling/thinking differs from the controlled two-model comparison. References/reviewPoints excluded from prompts. No semantic accuracy percentage."
            report.generationConfigurationDescription = "think=\(generation.thinking); num_predict=\(generation.tokenLimit); temperature=\(generation.temperature); top_p=\(generation.topP); presence_penalty=\(generation.presencePenalty); top_k=20; min_p=0; repeat_penalty=1; frequency_penalty=0; seed=42; num_ctx=8192"
        }
        let timingOnly = CommandLine.arguments.contains("--timing-only")
        let caseArgument = CommandLine.arguments.firstIndex(of: "--case-id")
        let selectedCase = caseArgument.flatMap { $0+1 < CommandLine.arguments.count ? CommandLine.arguments[$0+1] : nil }
        if let selectedCase, !cases.contains(where: { $0.id == selectedCase }) { throw StudyError.message("Unknown case ID") }
        let label = (chosen.hasPrefix("qwen3.5") ? "qwen35-9b" : "qwen3-4b") + (reasoning ? "-reasoning" : recommended ? "-recommended" : "") + (selectedCase.map { "-case-"+$0 } ?? (smoke ? "-smoke" : timingOnly ? "-timing" : diagnostic ? "-diagnostic" : ""))
        func save() throws { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; try encoder.encode(report).write(to: out.appendingPathComponent(label+".json"), options: .atomic) }
        let repeats = ["ja-accompany-word", "ja-line-versus-words", "en-high-gear-full-speed"]
        let schedule = smoke ? [(cases[0], 0)] : diagnostic ? cases.filter { ["ja-accompany-word", "ja-retort-context", "ja-reassurance-context"].contains($0.id) }.map { ($0, 4) } : timingOnly ? cases.filter { repeats.contains($0.id) }.map { ($0,3) } : cases.map { ($0,1) } + cases.filter { repeats.contains($0.id) }.map { ($0,2) }
        for (test, repetition) in schedule where selectedCase == nil || test.id == selectedCase {
            _ = await ModelTimingProtocol.collector.take()
            let start = Date()
            var result: ContextStudy?, failure: String?
            do { result = try await OllamaService.analyzeContext(lines: test.lines, language: test.language, endpoint: "http://127.0.0.1:11434", model: chosen, configuration: generation, selection: test.selection, comparison: test.comparison, session: measured) }
            catch { failure = error.localizedDescription }
            let elapsed = Date().timeIntervalSince(start)
            let traces = await ModelTimingProtocol.collector.take()
            let resident = (try? await call("ps")) ?? Data()
            report.rows.append(Row(caseID: test.id, model: chosen, repetition: repetition, wallSeconds: elapsed, result: result, error: failure, calls: traces, residentModels: String(decoding: resident, as: UTF8.self)))
            try save()
            print("\(label) \(report.rows.count)/\(schedule.count) \(test.id) #\(repetition) \(result == nil ? "FAIL" : "OK") \(String(format: "%.2f", elapsed))s requests=\(traces.count)")
        }
        print("COMPLETE \(chosen): \(report.rows.count) measured cases, warmup separate; inspect semantic results before deciding integration")
    }
}
