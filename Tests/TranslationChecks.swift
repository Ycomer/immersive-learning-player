import Foundation

@main struct TranslationChecks {
    static func main() async throws {
        let samples = [
            ("日语", "今日はいい天気ですね。私は日本語を勉強しています。もう一度聞いてみましょう。"),
            ("韩语", "저는 한국어를 공부하고 있어요."),
            ("英语", "Could you say that again, a little more slowly?")
        ]
        for (language, source) in samples {
            let started = Date()
            let translated = try await OllamaService.translate(text: source, model: LocalToolDefaults.translationModel, endpoint: "http://127.0.0.1:11434", language: language)
            guard translated.range(of: "[\\p{Han}]", options: .regularExpression) != nil,
                  !translated.contains("<think>"), !translated.contains("</think>") else {
                throw StudyError.message("没有获得有效中文译文：\(translated)")
            }
            print("\(language) → \(translated) [\(String(format: "%.2f", Date().timeIntervalSince(started)))s]")
        }
        print("PASS: real Qwen3 local translation for Japanese, Korean and English")
    }
}
