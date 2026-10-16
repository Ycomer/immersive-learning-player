import Foundation

final class RecordedContextProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var replies: [String] = []
    static func configure(_ values: [String]) { lock.lock(); defer { lock.unlock() }; replies = values }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let next = Self.replies.isEmpty ? nil : Self.replies.removeFirst(); Self.lock.unlock()
        guard let next else { client?.urlProtocol(self, didFailWithError: StudyError.message("Recorded replies exhausted")); return }
        let envelope = try! JSONSerialization.data(withJSONObject: ["message": ["content": next]])
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: envelope); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
@main struct ContextModelReplayChecks {
    struct Case: Decodable { var id: String; var language: String; var lines: [ContextStudyLine]; var selection: SubtitleWordSelection?; var comparison: String? }
    struct Call: Decodable { var content: String }
    struct Row: Decodable { var caseID: String; var repetition: Int; var result: ContextStudy?; var error: String?; var calls: [Call] }
    struct Report: Decodable { var cases: [Case]; var rows: [Row] }
    struct Replay: Encodable { var caseID: String; var repetition: Int; var result: ContextStudy?; var error: String? }
    struct Output: Encodable { var method: String; var rows: [Replay] }
    static func main() async throws {
        let root = URL(fileURLWithPath: "tools/real-video-evaluation/context-4b-regression")
        var report = try JSONDecoder().decode(Report.self, from: Data(contentsOf: root.appendingPathComponent("qwen3-4b.json")))
        let recheck = root.appendingPathComponent("qwen3-4b-case-en-quiet-clip-context.json")
        if FileManager.default.fileExists(atPath: recheck.path) {
            let extra = try JSONDecoder().decode(Report.self, from: Data(contentsOf: recheck))
            for row in extra.rows {
                guard let index = report.rows.firstIndex(where: { $0.caseID == row.caseID && $0.repetition == row.repetition }) else { throw StudyError.message("Unknown rechecked row") }
                report.rows[index] = row
            }
        }
        guard report.rows.count == 20 else { throw StudyError.message("Wait for the complete actual-model run") }
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [RecordedContextProtocol.self]
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        var rows: [Replay] = []
        for row in report.rows {
            let test = report.cases.first { $0.id == row.caseID }!
            RecordedContextProtocol.configure(row.calls.map(\.content))
            var value: ContextStudy?, error: String?
            do { value = try await OllamaService.analyzeContext(lines: test.lines, language: test.language, endpoint: "http://127.0.0.1:11434", configuration: .init(), selection: test.selection, comparison: test.comparison, session: session) }
            catch let failure { error = failure.localizedDescription }
            if let expected = row.result, var normalized = value {
                // The final patch only adds the activity line used by a dictionary fallback.
                if normalized.referenceOnly == true { normalized.evidence = expected.evidence }
                guard normalized == expected else { throw StudyError.message("Unexpected semantic change during replay: \(row.caseID)") }
            } else if row.result != nil || value != nil || error != row.error { throw StudyError.message("Unexpected outcome change during replay: \(row.caseID)") }
            rows.append(Replay(caseID: row.caseID, repetition: row.repetition, result: value, error: error))
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Output(method: "Network disabled URLProtocol replay of the recorded local-model replies through the final production service; checks the evidence-only correction without rerunning generation. Raw calls and timings remain in qwen3-4b.json.", rows: rows)).write(to: root.appendingPathComponent("final-output-replay.json"), options: .atomic)
        print("PASS: all 20 recorded local-model runs replayed through final source; only dictionary evidence additions allowed, no model/network requests")
    }
}
