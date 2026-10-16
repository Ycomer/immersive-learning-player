import Foundation
import Darwin

@main struct SubtitleWordSelectionChecks {
    static func main() throws {
        func check(_ value: Bool, _ message: String) throws { if !value { throw StudyError.message("FAIL: \(message)") } }
        let english = "😀 Don't kick it into high gear; keep it light."
        let gear = (english as NSString).range(of: "gear")
        let word = SubtitleWordSelection.word(in: english, atUTF16: gear.location+1)
        try check(word?.expression == "gear" && word?.range == gear, "UTF-16 emoji prefix offset or English word click failed")
        let japanese = "こないだも付き合ったでしょ。"
        let raw = (japanese as NSString).range(of: "付き合った")
        let japaneseWord = SubtitleWordSelection.word(in: japanese, atUTF16: raw.location+1)
        try check(japaneseWord?.expression == "付き合った", "Local Japanese tokenizer lost the clicked word")
        let ending = SubtitleWordSelection.word(in: japanese, atUTF16: raw.location+raw.length-1)
        try check(ending?.expression == "付き合った", "Clicking a Japanese ending selected half a verb")
        for (text, expected) in [("彼は猫をかぶっている。", "かぶっている"), ("昨日映画を見ました。", "見ました"), ("映画に行きたくなかった。", "行きたくなかった")] {
            let range = (text as NSString).range(of: expected)
            try check(SubtitleWordSelection.word(in: text, atUTF16: range.location)?.expression == expected, "Japanese auxiliary chain split: \(expected)")
        }
        try check(SubtitleWordSelection.word(in: "映画を見た。", atUTF16: 0)?.expression == "映画", "Noun absorbed case particle")
        let phrase = SubtitleWordSelection.selected(in: english, range: (english as NSString).range(of: " high gear"))
        try check(phrase?.expression == "high gear" && phrase?.location == (english as NSString).range(of: "high gear").location, "Phrase dragging trim altered selected offset")
        let repeatText = "I like this, and I like that."
        let second = (repeatText as NSString).range(of: "like", options: .backwards)
        let repeatWord = SubtitleWordSelection.word(in: repeatText, atUTF16: second.location)
        try check(repeatWord?.range == second && (repeatText as NSString).replacingCharacters(in: repeatWord!.range, with: "love") == "I like this, and I love that.", "Repeated word selection replaced the wrong occurrence")
        try check(SubtitleWordSelection.word(in: "Hi!", atUTF16: 2) == nil && SubtitleWordSelection.word(in: "Hi there", atUTF16: 2) == nil, "Punctuation/space clicked as a word")
        try check(SubtitleWordSelection.word(in: english, atUTF16: 1) == nil, "Half-surrogate offset accepted")
        try check(!SubtitleWordSelection(expression: "gear", location: Int.max, length: 4).isValid(in: english), "Overflow location accepted")
        try check(!SubtitleWordSelection(expression: "different", location: gear.location, length: gear.length).isValid(in: english), "Stale edited word accepted")
        print("PASS: English/Japanese local tokenization, Unicode and emoji, exact phrase ranges, repeated-word occurrence, punctuation, bounds and edited-source rejection")
    }
}
