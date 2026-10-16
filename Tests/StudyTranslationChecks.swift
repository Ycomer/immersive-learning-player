import Foundation
import Darwin

@main struct StudyTranslationChecks {
    static func main() async throws {
        setbuf(stdout, nil)
        let chosenModel = CommandLine.arguments.dropFirst().first ?? LocalToolDefaults.translationModel
        func check(_ value: Bool, _ message: String) throws { if !value { throw StudyError.message(message) } }
        let source = "彼は猫をかぶっている。"
        let note = StudyAnnotation(expression: "猫をかぶっている", kind: "惯用语", meaning: "装乖", usage: "比喻掩饰本性。")
        let invalid = StudyAnnotation(expression: "空気を読む", kind: "惯用语", meaning: "看气氛", usage: "")
        let result = try StudyTranslation(translation: "他在装乖。", annotations: [note, note, invalid], warning: "").validated(for: source)
        try check(result.annotations == [note], "Unrelated or duplicate expressions accepted")
        let legacy = "{\"start\":0,\"end\":2,\"text\":\"hello\",\"id\":\"00000000-0000-0000-0000-000000000001\",\"translation\":\"你好\"}"
        let old = try JSONDecoder().decode(SubtitleCue.self, from: Data(legacy.utf8))
        try check(old.annotations == nil && old.translationSignature == nil, "Old caches no longer decode")
        let new = SubtitleCue(start: 0, end: 2, text: source, translation: result.translation, annotations: result.annotations, translationWarning: nil, translationSignature: "new-profile")
        let restored = try JSONDecoder().decode(SubtitleCue.self, from: JSONEncoder().encode(new))
        try check(restored == new, "Annotation cache round-trip lost data")
        let samples: [(String, [String], [String], [String])] = [
            (source, [], ["普段はもっと乱暴なのにね。"], ["装", "伪装"]),
            ("空気を読んでよ。", ["みんな真剣に話しているんだよ。"], [], ["气氛", "眼力", "场合", "察言"]),
            ("いいです。", ["もうお腹いっぱいです。", "もう一杯いかがですか？"], [], ["不用", "不需要", "不必", "不了", "不要"]),
            ("それは火に油を注ぐだけだ。", ["相手はもう怒っているよ。"], [], ["火上浇油", "更生气", "激怒", "加剧"]),
            ("彼女は顔が広い。", [], [], ["人脉", "认识的人", "交际", "交游"]),
            ("彼は二の足を踏んでいる。", [], [], ["犹豫", "迟疑", "踌躇"]),
            ("それは水に流そう。", ["もう謝ったんだから。"], [], ["过去", "忘", "算了", "既往", "计较", "没发生过", "不提", "一笔勾销"]),
            ("調子に乗るなよ。", ["褒められたからって、何をしてもいいわけじゃない。"], [], ["得意", "忘形", "得瑟", "自满"]),
            ("全然お金が入ってないもん。", [], [], ["钱", "到账", "进账", "收入"]),
            ("明日はタカシとカフェに行く。", [], [], ["明天", "咖啡"]),
            ("「やばい」ってどういう意味？", [], [], ["意思", "含义"]),
            ("今日は雨です。", [], [], ["雨"]),
            ("もう一度聞いてみましょう。", ["私は日本語を勉強しています。"], [], ["听"]),
            ("普段はもっと乱暴なのにね。", [source], [], ["粗暴", "粗鲁", "野蛮", "暴躁", "凶"])
        ]
        let startIndex = Int(CommandLine.arguments.dropFirst(2).first ?? "0") ?? 0
        guard samples.indices.contains(startIndex) else { throw StudyError.message("Invalid first sample index") }
        for (text, before, after, expected) in samples.dropFirst(startIndex) {
            let started = Date()
            let translated = try await OllamaService.translateStudy(text: text, before: before, after: after, model: chosenModel, endpoint: "http://127.0.0.1:11434", language: "日语")
            print("\(text) → \(translated.translation) [\(Int(Date().timeIntervalSince(started)))s]", terminator: "\n")
            print(String(decoding: try JSONEncoder().encode(translated), as: UTF8.self))
            try check(expected.contains(where: translated.translation.contains), "Meaning check failed for \(text)")
            try check(ChineseTranslationCheck.isValid(translated.translation), "Japanese leaked into Chinese translation")
            if text == source || text.contains("空気") { try check(!translated.annotations.isEmpty, "Missing idiom annotation for \(text)") }
            if text == source { try check(translated.plainMeaning?.contains("装") == true, "Missing plain Chinese meaning") }
            if text == source { try check(!translated.translation.contains("可怜") && !translated.translation.contains("粗暴") && !translated.translation.contains("平时"), "Wrong idiom sense or context text leaked into current cue") }
            if text == "いいです。" { try check(!translated.translation.contains("吃饱"), "Context fact was inserted into the current refusal") }
            if text == "普段はもっと乱暴なのにね。" {
                try check(!["不是这样粗鲁", "不这么粗鲁", "没有这么粗暴", "不是这样粗暴"].contains(where: translated.translation.contains), "Comparative contrast reversed into the opposite meaning")
                try check(JapaneseExpressionGuide.referenceNotes(from: translated.annotations, in: text).isEmpty, "Ordinary comparative clause promoted to a verified idiom")
                if !translated.annotations.isEmpty || translated.plainMeaning != nil { print("DRAFT-UNVERIFIED: generated explanation is not validated learning content") }
            }
            if text.contains("水に流") { try check(translated.plainMeaning?.contains("计较") == true && translated.plainMeaning?.contains("水里") != true, "Plain idiom meaning reverted to literal water") }
            if text.contains("タカシ") { try check(!translated.translation.contains("高桥"), "Phonetic first name invented a different surname") }
            if text.contains("お金が入ってない") { try check(!translated.annotations.contains { $0.kind == "俗语" && $0.expression.contains("お金が入ってない") }, "Ordinary predicate mislabeled as proverb") }
            if text == "今日は雨です。" { try check(translated.annotations.isEmpty, "Ordinary sentence incorrectly marked as idiom") }
        }
        print("PASS: samples \(startIndex+1)-\(samples.count), idiom/context checks, source-bound annotations, legacy and new caches; not a semantic accuracy percentage")
    }
}
