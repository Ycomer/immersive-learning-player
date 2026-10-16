import Foundation

@main struct EnglishExpressionChecks {
    static func main() throws {
        func check(_ value: Bool, _ message: String) throws { if !value { throw StudyError.message(message) } }
        let source = "Are you PULLING MY LEG? Don't spill the beans. Let's call it a day."
        let notes = StudyExpressionGuide.notes(in: source)
        try check(notes.count == 3 && notes.allSatisfy { source.contains($0.expression) && $0.sourceURL != nil }, "English references lost source spelling, inflection or citation")
        try check(notes.contains { $0.expression == "PULLING MY LEG" }, "Case-insensitive match rewrote original expression")
        try check(StudyExpressionGuide.notes(in: "The bean counter called today. The weather is nice.").isEmpty, "Ordinary English was falsely annotated")
        try check(StudyExpressionGuide.notes(in: "Outspill the beansprout.").isEmpty, "Partial English words matched an idiom")
        let contraction = StudyExpressionGuide.notes(in: "I wasn’t serious.")
        try check(contraction.count == 1 && contraction[0].kind == "口语" && contraction[0].expression == "I wasn’t serious", "Curly apostrophe or spoken-expression classification failed")
        try check(!StudyExpressionGuide.translationIssues(in: "I wasn't serious.", translation: "我不是真的。").isEmpty, "Wrong sincerity meaning passed")
        try check(StudyExpressionGuide.translationIssues(in: "I wasn't serious.", translation: "我不是认真的。").isEmpty, "Natural sincerity meaning was rejected")
        try check(StudyExpressionGuide.translationIssues(in: "I'm under the weather.", translation: "我身体不太舒服。").isEmpty, "Valid health paraphrase was rejected")
        var invented = notes[0]; invented.meaning = "模型编造的意思"
        try check(StudyExpressionGuide.referenceNotes(from: [notes[0], invented], in: source) == [notes[0]], "Copied dictionary URL promoted an unverified definition")
        try check(StudyExpressionGuide.notes(in: "彼は猫をかぶっている。").first?.meaning.contains("装") == true, "English reference integration regressed Japanese")
        try check(!StudyExpressionGuide.translationIssues(in:"I kicked it into high gear.",translation:"我换到了高速挡。").isEmpty, "Figurative work intensity accepted as literal gearbox")
        try check(StudyExpressionGuide.translationIssues(in:"I pulled two all-nighters.",translation:"我熬了两个通宵。").isEmpty, "Full all-nighter meaning rejected")
        try check(!StudyExpressionGuide.translationIssues(in:"two all-nighters",translation:"熬夜是不应该的。").isEmpty, "A noun phrase was accepted as an invented judgement")
        try check(StudyExpressionGuide.notes(in:"それは私のセリフでしょ。").first?.kind == "口语", "Retort is missing a sourced spoken meaning")
        print("PASS: sourced English expressions, literal-word boundaries, surface forms, contractions, meaning coverage and Japanese compatibility")
    }
}
