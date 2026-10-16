import Foundation
import Darwin

final class TranslationFixtureProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var replies: [String] = []
    static var inputs: [String] = []
    static var doneReasons: [String?] = []
    static func configure(_ values: [String], doneReasons: [String?] = []) {
        lock.lock(); defer { lock.unlock() }; replies = values; inputs = []; self.doneReasons = doneReasons
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "127.0.0.1" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let content = Self.replies.isEmpty ? nil : Self.replies.removeFirst()
        let doneReason = Self.doneReasons.isEmpty ? nil : Self.doneReasons.removeFirst()
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 2048)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; body.append(contentsOf: buffer.prefix(count)) }
        }
        Self.inputs.append(String(decoding: body, as: UTF8.self))
        Self.lock.unlock()
        guard let content else { client?.urlProtocol(self, didFailWithError: StudyError.message("Unexpected extra request")); return }
        var envelope: [String: Any] = ["message": ["content": content]]
        if let doneReason { envelope["done_reason"] = doneReason }
        let data = try! JSONSerialization.data(withJSONObject: envelope)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

actor PublishedTranslations {
    var values: [String] = []
    func add(_ text: String) { values.append(text) }
}

@main struct ChineseTranslationChecks {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        func check(_ condition: Bool, _ message: String) throws { if !condition { throw StudyError.message(message) } }
        for text in ["下月になると初人気を入るから", "嗯，全然没钱入ってないもん", "帝都メンナーよ。", "谢谢，ｱﾘｶﾞﾄｳ", "你是ゔ吗", "他说ありがとう（谢谢）。"] {
            try check(!ChineseTranslationCheck.isValid(text), "Kana leak accepted: \(text)")
        }
        for text in ["下个月就开始了。", "没钱到账啊。", "小林说：没问题。", "123", "OK", "A・B", "😀"] {
            try check(ChineseTranslationCheck.isValid(text), "Valid Chinese/numeric/name punctuation rejected: \(text)")
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TranslationFixtureProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let collector = PublishedTranslations()
        TranslationFixtureProtocol.configure([
            "{\"translation\":\"嗯，全然没钱入ってないもん\",\"warning\":\"\"}",
            "{\"translation\":\"嗯，根本没有钱到账嘛。\",\"warning\":\"\"}",
            "{\"annotations\":[]}"
        ])
        let result = try await OllamaService.translateStudy(text: "全然お金が入ってないもん。", before: [], after: [], model: "fixture", endpoint: "http://127.0.0.1:11434", language: "日语", session: session, onTranslation: { await collector.add($0.translation) })
        let published = await collector.values
        try check(result.translation == "嗯，根本没有钱到账嘛。" && published == [result.translation], "Invalid translation published before correction")
        try check(TranslationFixtureProtocol.inputs.count == 3 && TranslationFixtureProtocol.inputs[1].contains("完整重译"), "Missing bounded full-sentence correction")
        TranslationFixtureProtocol.configure([
            "{\"translation\":\"还是だめ\",\"warning\":\"\"}",
            "{\"translation\":\"不行だめ\",\"warning\":\"\"}"
        ])
        let failedCollector = PublishedTranslations()
        do {
            _ = try await OllamaService.translateStudy(text: "だめだ。", before: [], after: [], model: "fixture", endpoint: "http://127.0.0.1:11434", language: "日语", session: session, onTranslation: { await failedCollector.add($0.translation) })
            throw StudyError.message("FAIL: repeated kana leakage accepted")
        } catch StudyError.message(let message) { try check(message.contains("日文"), "Expected visible language validation error: \(message)") }
        let failedValues = await failedCollector.values
        try check(failedValues.isEmpty && TranslationFixtureProtocol.inputs.count == 2, "Retry unbounded or invalid text published")
        TranslationFixtureProtocol.configure(["{\"translation\":\"他在装老实。\",\"warning\":\"\"}", "{\"annotations\":[]}"])
        let annotated = try await OllamaService.translateStudy(text: "彼は猫をかぶっている。", before: [], after: [], model: "fixture", endpoint: "http://127.0.0.1:11434", language: "日语", session: session)
        try check(annotated.annotations.first?.expression == "猫をかぶっている", "Japanese learning expressions incorrectly removed")
        let reference = JapaneseExpressionGuide.notes(in: "彼は猫をかぶっている。")[0]
        var falseDefinition = reference; falseDefinition.meaning = "装作可怜。"
        try check(JapaneseExpressionGuide.referenceNotes(from: [reference, falseDefinition], in: "彼は猫をかぶっている。") == [reference], "AI definition with a copied source URL was promoted to verified teaching content")
        let reversedDraft = StudyAnnotation(expression: "もっと乱暴", kind: "俗语", meaning: "现在比平时更粗鲁。", usage: "")
        try check(JapaneseExpressionGuide.referenceNotes(from: [reversedDraft], in: "普段はもっと乱暴なのにね。").isEmpty, "Unverified reversed explanation promoted to automatic subtitle annotation")
        try check(TranslationCoverage.sourceTerms("カサブランカのホテル、カサブランカ。") == ["カサブランカ", "ホテル"], "Loanword extraction or deduplication changed")
        try check(TranslationCoverage.directAddresses("Good night, Alex.") == ["Alex"] && TranslationCoverage.directAddresses("Good night, everyone.").isEmpty && TranslationCoverage.directAddresses("Hey, sit still.").isEmpty, "Singular direct address detection changed ordinary dialogue")
        try check(!TranslationCoverage.directAddressIssues(source:"Hello, Robin.",translation:"你好，各位。").isEmpty && TranslationCoverage.directAddressIssues(source:"Hello, Robin.",translation:"你好，罗宾。").isEmpty, "Unknown addressee was replaced with a plural audience")
        let naming = "ダルル・バディアとして再建されました。"
        TranslationFixtureProtocol.configure([
            "{\"translation\":\"城市重建了。\",\"warning\":\"\",\"terms\":[]}",
            "{\"translation\":\"城市被重建为达鲁尔巴迪亚。\",\"warning\":\"\",\"terms\":[{\"source\":\"ダルル・バディア\",\"target\":\"达鲁尔巴迪亚\"}]}",
            "{\"annotations\":[]}"
        ])
        let omissionCollector = PublishedTranslations()
        let restoredName = try await OllamaService.translateStudy(text: naming, before: [], after: [], model: "fixture", endpoint: "http://127.0.0.1:11434", language: "日语", session: session, onTranslation: { await omissionCollector.add($0.translation) })
        let omissionValues = await omissionCollector.values
        try check(restoredName.translation.contains("达鲁尔巴迪亚") && omissionValues == [restoredName.translation], "Omitted name was published before repair")
        TranslationFixtureProtocol.configure([
            "{\"translation\":\"城市重建了。\",\"warning\":\"\",\"terms\":[{\"source\":\"ダルル・バディア\",\"target\":\"达鲁尔巴迪亚\"}]}",
            "{\"translation\":\"城市重建了。\",\"warning\":\"\",\"terms\":[]}"
        ])
        do {
            _ = try await OllamaService.translateStudy(text: naming, before: [], after: [], model: "fixture", endpoint: "http://127.0.0.1:11434", language: "日语", session: session)
            throw StudyError.message("FAIL: metadata-only name passed without appearing in translation")
        } catch StudyError.message(let message) { try check(message.contains("遗漏"), "Expected bounded coverage failure") }
        try check(TranslationFixtureProtocol.inputs.count == 2, "Coverage retry not bounded")
        TranslationFixtureProtocol.configure(["{}", "{\"translation\":\"你好。\",\"warning\":\"\"}", "{\"annotations\":[]}"])
        let repairedJSON = try await OllamaService.translateStudy(text: "こんにちは。", before: [], after: [], model: "fixture", endpoint: "http://127.0.0.1:11434", language: "日语", session: session)
        try check(repairedJSON.translation == "你好。" && TranslationFixtureProtocol.inputs.count == 3, "Malformed primary JSON did not use one bounded repair")
        TranslationFixtureProtocol.configure(["{\"translation\":\"他在装老实。\",\"warning\":\"\"}", "{broken"])
        let optionalFailure = try await OllamaService.translateStudy(text: "彼は猫をかぶっている。", before: [], after: [], model: "fixture", endpoint: "http://127.0.0.1:11434", language: "日语", session: session)
        try check(optionalFailure.translation == "他在装老实。" && optionalFailure.annotations.first?.sourceURL != nil && optionalFailure.plainMeaning?.contains("装") == true && TranslationFixtureProtocol.inputs.count == 2, "Optional note failure discarded checked Chinese or verified guidance")
        let uncertainSource = SubtitleCue(start: 0, end: 1, text: "test", recognitionWarning: "音频较弱")
        let uncertainMeaning = SubtitleCue(start: 0, end: 1, text: "test", translationWarning: "需要更多语境")
        try check(uncertainSource.studyWarningTitle == "识别待核对" && uncertainMeaning.studyWarningTitle == "含义待确认", "Recognition and meaning warnings not distinguished")
        try check(TranslationParagraphs.source(["A < B & C"]) == "<p id=\"s0\">A &lt; B &amp; C</p>", "Source paragraph escaping changed")
        for malformed in ["<p id=\"s0\">前文</p><p id=\"s0\">重复</p>", "<p id=\"s0\">前文</p>", "额外剧情<p id=\"s0\">前文</p><p id=\"s1\">当前句</p>", "<p id=\"s0\">前文</p><p id=\"s2\">编号改变</p>"] {
            do { _ = try TranslationParagraphs.current(malformed, count: 2, index: 1); throw StudyError.message("FAIL: invalid paragraph response accepted") }
            catch StudyError.message(let message) { try check(message.contains("字幕分段"), "Wrong paragraph failure") }
        }
        TranslationFixtureProtocol.configure(["```html\n<p id=\"s0\">平时他很粗暴。</p>\n<p id=\"s1\">他在装老实。</p>\n```", "{broken"])
        let googleCollector = PublishedTranslations()
        let google = try await OllamaService.translateStudy(text: "彼は猫をかぶっている。", before: ["普段は乱暴なのにね。"], after: [], model: "translategemma:12b", endpoint: "http://127.0.0.1:11434", language: "日语", session: session, onTranslation: { await googleCollector.add($0.translation) })
        let googleValues = await googleCollector.values
        try check(google.translation == "他在装老实。" && googleValues == [google.translation] && google.annotations.first?.sourceURL != nil, "Dedicated translator lost early Chinese or verified notes after optional failure")
        let googlePayload = try JSONSerialization.jsonObject(with: Data(TranslationFixtureProtocol.inputs[0].utf8)) as! [String: Any]
        let googleMessages = googlePayload["messages"] as! [[String: String]]
        try check(googlePayload["format"] == nil && googleMessages.count == 1 && googleMessages[0]["role"] == "user" && googleMessages[0]["content"]!.hasSuffix("<p id=\"s1\">彼は猫をかぶっている。</p>"), "Google model received generic JSON/system protocol")
        try check(googleMessages[0]["content"]!.contains("Preserve all HTML paragraph tags") && googleMessages[0]["content"]!.contains("装乖") && TranslationFixtureProtocol.inputs.count == 1 && google.plainMeaning?.contains("装") == true, "Dedicated translator must retain verified guidance without switching to another model")
        TranslationFixtureProtocol.configure(["<p id=\"s0\">不行だめ。</p>", "<p id=\"s0\">不行だめ。</p>"])
        let googleFailedCollector = PublishedTranslations()
        do {
            _ = try await OllamaService.translateStudy(text: "だめだ。", before: [], after: [], model: "translategemma:12b", endpoint: "http://127.0.0.1:11434", language: "日语", session: session, onTranslation: { await googleFailedCollector.add($0.translation) })
            throw StudyError.message("FAIL: dedicated translator Japanese leakage accepted")
        } catch StudyError.message(let message) { try check(message.contains("日文"), "Dedicated translator failure not visible") }
        let googleFailedValues = await googleFailedCollector.values
        try check(googleFailedValues.isEmpty && TranslationFixtureProtocol.inputs.count == 2, "Dedicated translator retry unbounded or invalid early publication")
        TranslationFixtureProtocol.configure(["<p id=\"s0\">大型公司有自己的飞</p>", "<p id=\"s0\">大型公司有自己的飞机。</p>", "{\"annotations\":[]}"], doneReasons: ["length", "stop", "stop"])
        let truncatedCollector = PublishedTranslations()
        let completedGoogle = try await OllamaService.translateStudy(text: "大企業は自社機を持っている。", before: [], after: [], model: "translategemma:12b", endpoint: "http://127.0.0.1:11434", language: "日语", session: session, onTranslation: { await truncatedCollector.add($0.translation) })
        let truncatedValues = await truncatedCollector.values
        try check(completedGoogle.translation == "大型公司有自己的飞机。" && truncatedValues == [completedGoogle.translation] && TranslationFixtureProtocol.inputs.count == 2, "Token-limit truncation was published as a complete subtitle")
        TranslationFixtureProtocol.configure(["错误内容<p id=\"s0\">前文。当前句。</p>", "仍然合并了<p id=\"s0\">多余内容。</p>", "{}", "{\"translation\":\"我身体不太舒服。\",\"warning\":\"\"}"])
        let recoveredCollector = PublishedTranslations()
        let recoveredEnglish = try await OllamaService.translateStudy(text: "I'm feeling under the weather.", before: ["Let's go outside."], after: [], model: "translategemma:12b", endpoint: "http://127.0.0.1:11434", language: "英语", session: session, onTranslation: { await recoveredCollector.add($0.translation) })
        let recoveredValues = await recoveredCollector.values
        try check(recoveredEnglish.translation == "我身体不太舒服。" && recoveredEnglish.modelUsed == LocalToolDefaults.explanationModel && recoveredValues == [recoveredEnglish.translation] && TranslationFixtureProtocol.inputs.count == 4, "Malformed English paragraph output stopped playback or leaked context instead of bounded local recovery")
        TranslationFixtureProtocol.configure(["<p id=\"s0\">我不是真的。</p>", "<p id=\"s0\">我不是认真的。</p>"])
        let sincereEnglish = try await OllamaService.translateStudy(text: "I wasn't serious.", before: [], after: [], model: "translategemma:12b", endpoint: "http://127.0.0.1:11434", language: "英语", session: session)
        try check(sincereEnglish.translation == "我不是认真的。" && sincereEnglish.annotations.first?.kind == "口语" && sincereEnglish.annotations.first?.sourceURL?.hasSuffix("serious") == true && TranslationFixtureProtocol.inputs.count == 2, "Sourced spoken-English meaning was not repaired or was falsely labelled an idiom")
        TranslationFixtureProtocol.configure(["<p id=\"s0\">之前的失误就此打住吧。</p>", "<p id=\"s0\">之前的失误就让它过去吧。</p>"])
        let idiomRepair = try await OllamaService.translateStudy(text: "この前の失敗はもう水に流そう。", before: [], after: [], model: "translategemma:12b", endpoint: "http://127.0.0.1:11434", language: "日语", session: session)
        try check(idiomRepair.translation.contains("过去") && TranslationFixtureProtocol.inputs.count == 2, "Sourced idiom meaning was not retried")
        TranslationFixtureProtocol.configure(["<p id=\"s0\">就此打住吧。</p>", "<p id=\"s0\">到此为止吧。</p>"])
        let idiomWarning = try await OllamaService.translateStudy(text: "水に流そう。", before: [], after: [], model: "translategemma:12b", endpoint: "http://127.0.0.1:11434", language: "日语", session: session)
        try check(!idiomWarning.warning.isEmpty && idiomWarning.annotations.first?.sourceURL != nil && TranslationFixtureProtocol.inputs.count == 3, "Unavailable local backup lost uncertainty or retried without bound")
        TranslationFixtureProtocol.configure(["<p id=\"s0\">就此打住吧。</p>", "<p id=\"s0\">到此为止吧。</p>", "{}", "{\"translation\":\"让过去的事过去吧。\",\"warning\":\"\"}"])
        let localBackup = try await OllamaService.translateStudy(text: "水に流そう。", before: [], after: [], model: "translategemma:12b", endpoint: "http://127.0.0.1:11434", language: "日语", session: session)
        try check(localBackup.translation.contains("过去") && localBackup.modelUsed == LocalToolDefaults.explanationModel && localBackup.warning.isEmpty && TranslationFixtureProtocol.inputs.count == 4, "Local idiom fallback failed, published uncertain output, or generated extra explanations")
        TranslationFixtureProtocol.configure([])
        let unresolved = try await OllamaService.translateStudy(text: "无法确认的音频", before: [], after: [], model: "translategemma:12b", endpoint: "http://127.0.0.1:11434", language: "日语", sourceWarning: "两段识别不一致", sourceConfidence: 0.2, session: session)
        try check(unresolved.modelUsed == "unresolved-source" && !unresolved.warning.isEmpty && TranslationFixtureProtocol.inputs.isEmpty, "Unreliable source was turned into a fluent guessed translation")
        TranslationFixtureProtocol.configure(["<p id=\"s0\">连续熬了两个通宵。</p>"])
        let completeSentence = try await OllamaService.translateStudy(text: "I pulled two all-nighters.", before: ["I wrote a paper."], after: ["You should never do that."], model: "translategemma:12b", endpoint: "http://127.0.0.1:11434", language: "英语", session: session)
        try check(completeSentence.translation.contains("两个通宵") && !TranslationFixtureProtocol.inputs[0].contains("You should never do that.") && !TranslationFixtureProtocol.inputs[0].contains("I wrote a paper."), "Dedicated English translation still exposes unrelated dialogue that can leak into a subtitle")
        TranslationFixtureProtocol.configure(["<p id=\"s0\">嗯，只是有些吃惊。</p>","<p id=\"s0\">不是啦，只是有些吃惊。</p>"])
        let negativeResponse = try await OllamaService.translateStudy(text:"ううん、少し驚いただけ。",before:[],after:[],model:"translategemma:12b",endpoint:"http://127.0.0.1:11434",language:"日语",sourceWarning:"肯定/否定的语音复核结果不一致",sourceConfidence:0.65,session:session)
        try check(negativeResponse.translation.hasPrefix("不是") && TranslationFixtureProtocol.inputs.count == 2 && !negativeResponse.warning.isEmpty,"Acoustically corrected negative reply became affirmative Chinese or lost uncertainty")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = StudyModel(cacheDirectory: folder, audioOnly: false)
        let video = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Samples/Japanese.mp4")
        model.loadVideo(video)
        model.cues = [SubtitleCue(start: 0, end: 2, text: "お金が入ってない。", translation: "没钱入ってない。", translationSignature: "cached-profile"), SubtitleCue(start: 2, end: 4, text: "だめだ。", translation: "不行。")]
        let ids = model.cues.map(\.id); model.save(); model.loadVideo(video)
        try check(model.cues.map(\.id) == ids && model.cues[0].text == "お金が入ってない。", "Cache cleanup changed source or IDs")
        try check(model.cues[0].translation == nil && model.cues[0].translationSignature == nil && model.cues[1].translation == "不行。", "Invalid cached translation retained or valid cache discarded with auto off")
        print("PASS: kana and half-width detection, bounded correction, no invalid early publication, visible failure, preserved Japanese annotations and cache cleanup")
    }
}
