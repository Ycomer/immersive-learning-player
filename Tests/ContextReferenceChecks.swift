import Foundation

@main struct ContextReferenceChecks {
    static func main() throws {
        func check(_ value: @autoclosure () -> Bool, _ message: String) throws { if !value() { throw StudyError.message(message) } }
        func lines(_ before: String, _ text: String) -> [ContextStudyLine] {
            [.init(id: "before1", start: 1, text: before, isCurrent: false), .init(id: "current", start: 3, text: text, isCurrent: true)]
        }
        let reaction = lines("あきれた？呆れてるの？", "ううん少し驚いたけど私は好きです。")
        let reactionSelection = SubtitleWordSelection.selected(in: reaction[1].text, range: (reaction[1].text as NSString).range(of: "驚いた"))!
        let response = ContextStudyReference.make(lines: reaction, selection: reactionSelection, comparison: "呆れた")!
        _ = try response.validated(lines: reaction, selection: reactionSelection, comparison: "呆れた")
        try check(response.referenceOnly == true && response.background.contains("否认") && response.background.contains("仍表达喜欢"), "Reference source or response polarity lost")
        try check(response.uncertainty.contains("省略") && response.words[0].difference.contains("不是逻辑上绝不能共存"), "Reference invented an object or absolute emotional contradiction")
        try check(ContextStudyReference.make(lines: lines("呆れてるの？", "ううん少し驚いたけど私は君が好きです。"), selection: nil, comparison: nil) == nil, "Omitted-object rule ignored an explicitly stated object")
        let shopping = lines("買い物に来るのは久しぶりね。", "昨日も付き合ったでしょ。")
        let outing = ContextStudyReference.make(lines: shopping, selection: nil, comparison: nil)!
        _ = try outing.validated(lines: shopping)
        try check(outing.background.contains("购物") && outing.words[0].alternative.hasPrefix("昨日も"), "Rule memorized cinema or changed time/also")
        var interrupted = shopping; interrupted[0].id = "before2"
        interrupted.insert(.init(id: "before1", start: 2, text: "何言ってんの。", isCurrent: false), at: 1)
        let cited = ContextStudyReference.make(lines: interrupted, selection: nil, comparison: nil)!
        _ = try cited.validated(lines: interrupted)
        try check(cited.evidence.contains(where: { $0.cueID == "before2" && $0.quote.contains("買い物") }), "Activity used in explanation omitted from evidence")
        try check(ContextStudyReference.make(lines: lines("彼氏と映画に来た。", shopping[1].text), selection: nil, comparison: nil) == nil, "Accompany sense forced onto explicitly romantic context")
        try check(ContextStudyReference.make(lines: lines("一緒に映画を見た。", "彼女と三年付き合った。"), selection: nil, comparison: nil) == nil, "Single-outing sense forced onto a duration relationship")
        let retort = lines("どうして私がその人と？", "それは私のセリフでしょ。")
        let selection = SubtitleWordSelection.selected(in: retort[1].text, range: (retort[1].text as NSString).range(of: "セリフ"))!
        let reply = ContextStudyReference.make(lines: retort, selection: selection, comparison: "言葉")!
        _ = try reply.validated(lines: retort, selection: selection, comparison: "言葉")
        try check(reply.words[0].replacement == "言葉" && reply.intent.contains("同样的不满") && reply.words[0].alternative == "それは私の言葉でしょ。", "Retort attribution or explicit comparison lost")
        try check(ContextStudyReference.make(lines: retort, selection: selection, comparison: "語彙") == nil, "Reference silently substituted for an unsupported requested word")
        var theatre = retort; theatre[0].text = "演劇の台本はどうして私がその人と？"
        try check(ContextStudyReference.make(lines: theatre, selection: selection, comparison: "言葉") == nil, "Retort forced onto a theatre context")
        let invalid = SubtitleWordSelection(expression: "セリフ", location: 500, length: 3)
        try check(ContextStudyReference.make(lines: retort, selection: invalid, comparison: nil) == nil, "Invalid range reached dictionary fallback")
        let roundTrip = try JSONDecoder().decode(ContextStudy.self, from: JSONEncoder().encode(reply))
        try check(roundTrip == reply && roundTrip.referenceOnly == true, "Cached reference label lost")
        let goodNight = "Good night, scales."
        var greeting = ContextStudy(background: "这句是向对方告别。", intent: "说晚安。", evidence: [.init(cueID: "current", quote: goodNight)], words: [.init(expression: "Good night", meaning: "晚上好，晚上问候对方。", reason: "这是临别时对对方说的话，保留称呼。", alternative: "Sleep well, scales.", difference: "换成祝对方睡好，保留同一个称呼对象。", replacement: "Sleep well")], uncertainty: "称呼所指的身份不确定。")
        let greetingLines = [ContextStudyLine(id: "current", start: 1, text: goodNight, isCurrent: true)]
        do { _ = try greeting.validated(lines: greetingLines); throw StudyError.message("FAIL: Good night confused with Good evening") } catch StudyError.message(let message) { try check(!message.hasPrefix("FAIL"), message) }
        greeting.words[0].meaning = "晚安，临别用语。"; greeting.words[0].alternative = "Sleep well, fish."
        do { _ = try greeting.validated(lines: greetingLines); throw StudyError.message("FAIL: automatic greeting invented an identity") } catch StudyError.message(let message) { try check(!message.hasPrefix("FAIL"), message) }
        print("PASS: labelled local dictionary fallbacks, different activity/dialogue variants, exact custom synonym, reaction polarity, unknown referents, theatre/romance exclusions, invalid selection and cache round trip")
    }
}
