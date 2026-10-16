import Foundation
import Darwin

final class ContextFixtureProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var replies: [String] = []
    static var inputs: [Data] = []
    static var delay = 0.0
    private var stopped = false
    private let stateLock = NSLock()
    static func configure(_ values: [String], delay: Double = 0) {
        lock.lock(); defer { lock.unlock() }; replies = values; inputs = []; self.delay = delay
    }
    static var count: Int { lock.lock(); defer { lock.unlock() }; return inputs.count }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 2048)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; body.append(contentsOf: buffer.prefix(n)) }
        }
        Self.lock.lock()
        Self.inputs.append(body)
        let value = Self.replies.isEmpty ? nil : Self.replies.removeFirst()
        let delay = Self.delay
        Self.lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now()+delay) { [self] in
            stateLock.lock(); defer { stateLock.unlock() }
            if stopped { return }
            guard let value else { client?.urlProtocol(self, didFailWithError: StudyError.message("Unexpected request")); return }
            let envelope = try! JSONSerialization.data(withJSONObject: ["message": ["content": value]])
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: envelope); client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { stateLock.lock(); stopped = true; stateLock.unlock() }
}

@main struct ContextLearningChecks {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws { if !condition() { throw StudyError.message("FAIL: \(message)") } }
        func encoded(_ value: ContextStudy) throws -> String {
            let word = value.words[0]
            var payload: [String: Any] = ["e_background": value.background, "f_intent": value.intent,
                "c_evidence": value.evidence.map(\.cueID), "a_expression": word.expression, "d_meaning": word.meaning, "g_reason": word.reason,
                "h_difference": word.difference, "j_uncertainty": value.uncertainty]
            if let replacement = word.replacement {
                payload["b_replacement"] = replacement
                if let fit = word.replacementFit { payload["i_replacementFit"] = fit }
            } else { throw StudyError.message("Fixture needs the actual replacement word") }
            return String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
        }
        func wait(_ model: StudyModel) async throws {
            for _ in 0..<200 { if model.contextStudyCueID == nil { return }; try await Task.sleep(nanoseconds: 10_000_000) }
            throw StudyError.message("Fixture did not finish")
        }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ContextFixtureProtocol.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = StudyModel(cacheDirectory: folder, audioOnly: false, preferredLanguage: "ja", translationSession: session)
        let video = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Samples/Japanese.mp4")
        model.loadVideo(video)
        let current = SubtitleCue(start: 4, end: 6, text: "こないだも付き合ったでしょ。", translation: "之前不是也陪你去了吗。")
        model.cues = [SubtitleCue(start: 0, end: 2, text: "映画に来るの久しぶりね。"), SubtitleCue(start: 2, end: 3, text: "何言ってんの。"), current, SubtitleCue(start: 6, end: 7, text: "恋愛もの。"), SubtitleCue(start: 8, end: 9, text: "そうだっけ。"), SubtitleCue(start: 10, end: 11, text: "OUTSIDE_WINDOW")]
        let lines = model.contextStudyLines(for: current.id)
        let result = ContextStudy(background: "对方说很久没一起来看电影，这句举出前一次来反驳。", intent: "提醒对方并反问确认，不是宣布恋爱关系。", evidence: [.init(cueID: lines[0].id, quote: lines[0].text), .init(cueID: "current", quote: current.text)], words: [.init(expression: "付き合った", meaning: "陪同、一起去。", reason: "前文谈一起看电影，因此这里可以理解为陪同。", alternative: "こないだも一緒に行ったでしょ。", difference: "改写直接表示一起去，弱化陪对方去的意味。", replacement: "一緒に行った")], uncertainty: "无法仅凭对白确认两人的真实关系。")
        _ = try result.validated(lines: lines)
        var bad = result; bad.evidence[0].quote = "从未说过的对白"
        do { _ = try bad.validated(lines: lines); throw StudyError.message("FAIL: fabricated quote accepted") } catch StudyError.message(let message) { try check(!message.hasPrefix("FAIL"), message) }
        bad = result; bad.words[0].expression = "恋愛"
        do { _ = try bad.validated(lines: lines); throw StudyError.message("FAIL: neighbor word attributed to current sentence") } catch StudyError.message(let message) { try check(!message.hasPrefix("FAIL"), message) }
        bad = result; bad.words[0].reason = "sounds natural"
        do { _ = try bad.validated(lines: lines); throw StudyError.message("FAIL: non-Chinese explanation accepted") } catch StudyError.message(let message) { try check(!message.hasPrefix("FAIL"), message) }
        bad = result; bad.words[0].difference = "改成‘セリ的’之后更自然。"
        do { _ = try bad.validated(lines: lines); throw StudyError.message("FAIL: invented foreign comparison accepted") } catch StudyError.message(let message) { try check(!message.hasPrefix("FAIL"), message) }
        bad = result; bad.words[0].alternative = "前几天也一起去过吧。"
        do { _ = try bad.validated(lines: lines); throw StudyError.message("FAIL: Chinese rewrite of Japanese accepted") } catch StudyError.message(let message) { try check(!message.hasPrefix("FAIL"), message) }
        bad = result; bad.words[0].alternative = bad.words[0].expression
        do { _ = try bad.validated(lines: lines); throw StudyError.message("FAIL: unchanged replacement accepted") } catch StudyError.message(let message) { try check(!message.hasPrefix("FAIL"), message) }
        bad = result; bad.words[0].alternative = "こないだも付き合ったよね。"
        do { _ = try bad.validated(lines: lines); throw StudyError.message("FAIL: learned expression unchanged in whole-sentence rewrite") } catch StudyError.message(let message) { try check(!message.hasPrefix("FAIL"), message) }
        bad = result; bad.words[0].difference = "不确定"
        do { _ = try bad.validated(lines: lines); throw StudyError.message("FAIL: empty teaching comparison accepted") } catch StudyError.message(let message) { try check(!message.hasPrefix("FAIL"), message) }
        bad = result; bad.words[0].meaning = "付き合った是现在时，表示曾经参与。"
        do { _ = try bad.validated(lines: lines); throw StudyError.message("FAIL: observed Japanese tense error accepted") } catch StudyError.message(let message) { try check(!message.hasPrefix("FAIL"), message) }
        let retort = "それは私のセリフでしょ。"
        let changedSpeaker = ContextStudy(background: "这句是在回应前句的不满。", intent: "表达自己也有相同不满。", evidence: [.init(cueID: "current", quote: retort)], words: [.init(expression: "私", meaning: "我，指说话者本人。", reason: "第一人称保留说话者本人的立场。", alternative: "それはあなたのセリフでしょ。", difference: "把我换成你会改变说话立场和原意。", replacement: "あなた")], uncertainty: "人物身份不能确定。")
        do { _ = try changedSpeaker.validated(lines: [.init(id: "current", start: 1, text: retort, isCurrent: true)]); throw StudyError.message("FAIL: synonym rewrite changed speaker") } catch StudyError.message(let message) { try check(!message.hasPrefix("FAIL"), message) }
        bad = result; bad.intent = "这句话暗示可能有恋爱关系。"
        do { _ = try bad.validated(lines: lines); throw StudyError.message("FAIL: unsupported romance inference accepted") } catch StudyError.message(let message) { try check(!message.hasPrefix("FAIL"), message) }
        bad.intent = "这句话不代表也不能暗示两人有恋爱关系。"
        _ = try bad.validated(lines: lines)
        var explicitLines = lines; explicitLines[0].text = "私の恋人です。"
        bad = result; bad.evidence = [result.evidence[1]]; bad.intent = "这句对话表达了恋人间的提醒。"
        _ = try bad.validated(lines: explicitLines)
        bad = result; bad.words[0].meaning = "‘付き合う’在这里指陪同对方参加活动。"
        _ = try bad.validated(lines: lines)
        ContextFixtureProtocol.configure([try encoded(result)])
        model.studyContext(current.id); try await wait(model)
        try check(model.contextStudyResult(for: current.id) == result && model.contextStudyError == nil, "Structured learning not published")
        try check(model.cues[2].translation == current.translation && model.cues[2].text == current.text && !model.translating && !model.translationFailed, "Learning changed playback translation/source state")
        let payload = try JSONSerialization.jsonObject(with: ContextFixtureProtocol.inputs[0]) as! [String: Any]
        try check(payload["model"] as? String == LocalToolDefaults.explanationModel && payload["think"] as? Bool == false, "Wrong local explanation model")
        try check((payload["options"] as? [String: Any])?.count == 3, "Experimental sampling changed the existing player defaults")
        let input = String(decoding: ContextFixtureProtocol.inputs[0], as: UTF8.self)
        try check(!input.contains("OUTSIDE_WINDOW") && !input.contains(current.translation!), "Unbounded context or translation contamination")
        model.studyContext(current.id); try check(ContextFixtureProtocol.count == 1, "Cache miss")
        let selection = SubtitleWordSelection.selected(in: current.text, range: (current.text as NSString).range(of: "付き合った"))!
        var focused = result
        focused.words[0].replacement = "一緒に行った"; focused.words[0].replacementFit = "语气或含义有变化"
        focused.words[0].alternative = (current.text as NSString).replacingCharacters(in: selection.range, with: "一緒に行った")
        _ = try focused.validated(lines: lines, selection: selection)
        var wrong = focused; wrong.words[0].expression = "こないだ"
        do { _ = try wrong.validated(lines: lines, selection: selection); throw StudyError.message("FAIL: model ignored selected word") } catch StudyError.message(let message) { try check(!message.hasPrefix("FAIL"), message) }
        wrong = focused; wrong.words[0].replacementFit = "可替换"; wrong.words[0].difference = "这个候选会改变活动和人物事实，不能直接替换。"
        do { _ = try wrong.validated(lines: lines, selection: selection); throw StudyError.message("FAIL: contradictory replacement verdict accepted") } catch StudyError.message(let message) { try check(!message.hasPrefix("FAIL"), message) }
        wrong = focused; wrong.words[0].alternative = "一緒に行ったでしょ。"
        do { _ = try wrong.validated(lines: lines, selection: selection); throw StudyError.message("FAIL: rewrite dropped time/also outside focus") } catch StudyError.message(let message) { try check(!message.hasPrefix("FAIL"), message) }
        let longSource = String(repeating: "The team keeps working on the project. ", count: 12) + "Then we shift into high gear."
        let longSelection = SubtitleWordSelection.selected(in: longSource, range: (longSource as NSString).range(of: "gear"))!
        let longLines = [ContextStudyLine(id: "current", start: 0, text: longSource, isCurrent: true)]
        let longStudy = ContextStudy(background: "这句承接团队工作进度的说明。", intent: "陈述工作进入高强度状态。", evidence: [.init(cueID: "current", quote: longSource)],
            words: [.init(expression: "gear", meaning: "比喻运转状态。", reason: "这里与前面的工作推进有关。", alternative: (longSource as NSString).replacingCharacters(in: longSelection.range, with: "speed"), difference: "替换后需要重新考虑整个搭配，不能只看词典义。", replacement: "speed", replacementFit: "不宜直接替换")], uncertainty: "仍需结合完整内容核对。")
        _ = try longStudy.validated(lines: longLines, selection: longSelection)
        ContextFixtureProtocol.configure([try encoded(focused)])
        model.studyContext(current.id, selection: selection); try await wait(model)
        try check(model.contextStudyResult(for: current.id, selection: selection) == focused && model.contextStudyResult(for: current.id) == result, "Word/whole-sentence cache collided")
        try check(model.cues[2].text == current.text && model.cues[2].translation == current.translation, "Focused study changed the subtitles")
        let focusedPayload = String(decoding: ContextFixtureProtocol.inputs[0], as: UTF8.self)
        try check(focusedPayload.contains("用户点选词") && focusedPayload.contains("付き合った") && focusedPayload.contains("i_replacementFit"), "Exact selected word or comparison schema not supplied")
        model.studyContext(current.id, selection: selection)
        try check(ContextFixtureProtocol.count == 1, "Focused cache missed")
        var custom = focused; custom.words[0].replacement = "同行した"
        custom.words[0].alternative = (current.text as NSString).replacingCharacters(in: selection.range, with: "同行した")
        custom.words[0].difference = "与‘同行する’相比，当前说法更口语化；替换后的过去式显得正式。"
        var ignored = custom; ignored.words[0].replacement = "会った"
        ignored.words[0].alternative = (current.text as NSString).replacingCharacters(in: selection.range, with: "会った")
        do { _ = try ignored.validated(lines: lines, selection: selection, comparison: "同行する"); throw StudyError.message("FAIL: requested synonym ignored") } catch StudyError.message(let message) { try check(!message.hasPrefix("FAIL"), message) }
        try check(StudyComparison.matches("同行した", requested: "同行する") && !StudyComparison.matches("会った", requested: "同行する"), "Japanese inflection lost requested lexeme")
        try check(StudyComparison.forms(of: "expensive") == ["expensive"] && !StudyComparison.matches("beloved", requested: "expensive"), "English comparison could switch lexeme")
        try check(StudyComparison.allowedForms(of: "笑う", replacing: "笑わない") == ["笑う"], "Explicit polarity comparison could silently preserve the negative")
        ContextFixtureProtocol.configure([try encoded(ignored), try encoded(custom)])
        _ = try await OllamaService.analyzeContext(lines: lines, language: "日语", endpoint: "http://127.0.0.1:11434", selection: selection, comparison: "同行する", session: session)
        try check(ContextFixtureProtocol.count == 2, "Wrong synonym was published without repair")
        let constrained = try JSONSerialization.jsonObject(with: ContextFixtureProtocol.inputs[0]) as! [String: Any]
        let schema = constrained["format"] as! [String: Any]
        let schemaProperties = schema["properties"] as! [String: Any]
        let allowed = (schemaProperties["b_replacement"] as! [String: Any])["enum"] as! [String]
        try check(allowed.contains("同行した") && !allowed.contains("会った"), "Requested comparison absent from constrained generation")
        try check(String(decoding: ContextFixtureProtocol.inputs[1], as: UTF8.self).contains("必须比较指定的近义词"), "Repair omitted the actual validation failure")
        ContextFixtureProtocol.configure([try encoded(custom)])
        model.studyContext(current.id, selection: selection, comparison: "同行する"); try await wait(model)
        try check(model.contextStudyResult(for: current.id, selection: selection, comparison: "同行する") == custom && model.contextStudyResult(for: current.id, selection: selection) == focused, "Custom synonym mixed with automatic comparison")
        try check(String(decoding: ContextFixtureProtocol.inputs[0], as: UTF8.self).contains("用户想比较的源语言词"), "Custom comparison absent from request")
        // Switching the target in the same subtitle cancels the first request.
        let otherSelection = SubtitleWordSelection.selected(in: current.text, range: (current.text as NSString).range(of: "こないだ"))!
        var other = focused; other.words[0].expression = "こないだ"; other.words[0].replacement = "この前"
        other.words[0].alternative = (current.text as NSString).replacingCharacters(in: otherSelection.range, with: "この前")
        ContextFixtureProtocol.configure([try encoded(focused), try encoded(other)], delay: 0.1)
        model.studyContext(current.id, selection: selection, refresh: true)
        try await Task.sleep(nanoseconds: 30_000_000)
        model.studyContext(current.id, selection: otherSelection); try await wait(model)
        try check(model.contextStudyResult(for: current.id, selection: otherSelection) == other && model.contextStudyCueID == nil, "Same-cue word change reused previous task")
        ContextFixtureProtocol.configure([try encoded(wrong), try encoded(wrong)])
        model.studyContext(current.id, selection: selection, refresh: true); try await wait(model)
        // A response cannot set the full rewrite: the production code constructs it from replacement.
        try check(model.contextStudyResult(for: current.id, selection: selection)?.words[0].alternative == focused.words[0].alternative, "Model could rewrite unselected sentence content")
        ContextFixtureProtocol.configure([])
        model.studyContext(current.id, selection: SubtitleWordSelection(expression: "stale", location: 0, length: 5))
        try check(ContextFixtureProtocol.count == 0 && model.contextStudyError?.contains("失效") == true, "Invalid selection sent to model")
        model.loadVideo(video)
        try check(model.contextStudyResult(for: current.id) == result && model.contextStudyResult(for: current.id, selection: selection) == focused && model.contextStudyResult(for: current.id, selection: selection, comparison: "同行する") == custom, "Disk cache lost full/word/custom notes")
        model.cues[0].text = "別の前文。"
        try check(model.contextStudyResult(for: current.id) == nil && model.contextStudyResult(for: current.id, selection: selection) == nil, "Changed context showed stale full/word explanation")
        // A late response must not attach to changed context.
        var currentEvidenceResult = result; currentEvidenceResult.evidence = [result.evidence[1]]
        ContextFixtureProtocol.configure([try encoded(currentEvidenceResult)], delay: 0.15)
        model.studyContext(current.id)
        try await Task.sleep(nanoseconds: 30_000_000)
        model.cues[0].text = "さらに変わった前文。"
        try await wait(model)
        try check(model.contextStudyResult(for: current.id) == nil && model.contextStudyError?.contains("更新") == true, "Late result overwrote newer context")
        ContextFixtureProtocol.configure([try encoded(currentEvidenceResult)], delay: 0.15)
        model.studyContext(current.id); try await Task.sleep(nanoseconds: 30_000_000); model.cancelContextStudy()
        try await Task.sleep(nanoseconds: 180_000_000)
        try check(model.contextStudyCueID == nil && model.contextStudyResult(for: current.id) == nil && model.contextStudyError == nil, "Closing panel failed to cancel")
        model.cues[2].recognitionConfidence = 0.2; model.cues[2].recognitionWarning = "待复听"
        ContextFixtureProtocol.configure([]); model.studyContext(current.id)
        try check(ContextFixtureProtocol.count == 0 && model.contextStudyError?.contains("识别清楚") == true && !model.contextStudyLines(for: current.id).contains(where: \.isCurrent), "Unreliable source sent to model")
        model.cues[2].recognitionConfidence = nil; model.cues[2].recognitionWarning = nil
        ContextFixtureProtocol.configure(["{}", "{}"]); model.studyContext(current.id); try await wait(model)
        try check(ContextFixtureProtocol.count == 2 && model.contextStudyError != nil && model.cues[2].translation == current.translation, "Failure retried unboundedly or affected subtitle")
        // Learning caches remain bounded even when many custom synonyms are compared.
        for index in 0..<13 {
            var candidate = focused; candidate.words[0].replacement = "候选\(index)"
            candidate.words[0].alternative = (current.text as NSString).replacingCharacters(in: selection.range, with: "候选\(index)")
            candidate.words[0].difference = "比较候选\(index)时，需要核对上下文中的语义差别。"
            ContextFixtureProtocol.configure([try encoded(candidate)])
            model.studyContext(current.id, selection: selection, comparison: "候选\(index)"); try await wait(model)
        }
        try check(model.cues[2].wordStudies?.count == 12, "Per-cue word cache grew beyond 12 entries")
        model.edit(current.id, text: "新しい原文。")
        try check(model.cues[2].wordStudies == nil && model.contextStudyResult(for: current.id, selection: selection) == nil, "Editing kept stale word study")
        ContextFixtureProtocol.configure([try encoded(result)])
        _ = try await OllamaService.analyzeContext(lines: lines, language: "日语", endpoint: "http://127.0.0.1:11434", model: "qwen3.5:9b-q4_K_M", configuration: .init(), session: session)
        let candidatePayload = try JSONSerialization.jsonObject(with: ContextFixtureProtocol.inputs[0]) as! [String: Any]
        let options = candidatePayload["options"] as! [String: Any]
        try check(candidatePayload["model"] as? String == "qwen3.5:9b-q4_K_M" && candidatePayload["think"] as? Bool == false, "Candidate override or thinking control ignored")
        try check(options["presence_penalty"] as? Int == 0 && options["repeat_penalty"] as? Int == 1 && options["seed"] as? Int == 42, "Comparison inherited different model sampling defaults")
        var wrongMeaning = result; wrongMeaning.words[0].reason = "付き合った是现在时，表示过去参与活动。"
        ContextFixtureProtocol.configure([try encoded(wrongMeaning), try encoded(wrongMeaning)])
        let reference = try await OllamaService.analyzeContext(lines: lines, language: "日语", endpoint: "http://127.0.0.1:11434", session: session)
        try check(reference.referenceOnly == true && reference.referenceURLs?.isEmpty == false && reference.words[0].meaning.contains("陪同"), "Repeated semantic error did not use a labelled dictionary fallback")
        try check(ContextFixtureProtocol.count == 2 && reference.evidence.allSatisfy({ proof in lines.contains { $0.id == proof.cueID && $0.text == proof.quote } }), "Reference fallback retried without bounds or fabricated source evidence")
        ContextFixtureProtocol.configure([])
        do {
            _ = try await OllamaService.analyzeContext(lines: lines, language: "日语", endpoint: "https://example.com", session: session)
            throw StudyError.message("FAIL: cloud endpoint accepted")
        } catch StudyError.message(let message) { try check(!message.hasPrefix("FAIL"), message) }
        try check(ContextFixtureProtocol.count == 0, "Non-local inference request attempted")
        let oldCue = try JSONDecoder().decode(SubtitleCue.self, from: Data("{\"id\":\"\(UUID().uuidString)\",\"start\":0,\"end\":1,\"text\":\"Old cache\"}".utf8))
        try check(oldCue.contextStudy == nil, "Old subtitle caches incompatible")
        print("PASS: exact evidence, current-word validation, Chinese explanations, local-only model, bounded context/retry, independent playback, disk cache, stale results, cancellation, uncertain-source refusal and old-cache compatibility")
    }
}
