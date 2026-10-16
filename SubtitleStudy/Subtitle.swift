import Foundation
import NaturalLanguage
import CoreGraphics

// Fractions of available travel keep a fixed-size control panel inside the window after resizing.
struct FloatingControlPosition: Equatable {
    var x: Double
    var y: Double
    private static func fraction(_ value: Double) -> Double { value.isFinite ? min(1, max(0, value)) : 0.5 }
    func center(in bounds: CGRect, panelSize: CGSize) -> CGPoint {
        let width = min(bounds.width, max(0, panelSize.width))
        let height = min(bounds.height, max(0, panelSize.height))
        return CGPoint(x: bounds.minX + width/2 + (bounds.width-width)*Self.fraction(x),
                       y: bounds.minY + height/2 + (bounds.height-height)*Self.fraction(y))
    }
    static func at(_ center: CGPoint, in bounds: CGRect, panelSize: CGSize) -> Self {
        let width = min(bounds.width, max(0, panelSize.width))
        let height = min(bounds.height, max(0, panelSize.height))
        let travelX = bounds.width-width
        let travelY = bounds.height-height
        return Self(x: travelX > 0 ? fraction((center.x-bounds.minX-width/2)/travelX) : 0.5,
                    y: travelY > 0 ? fraction((center.y-bounds.minY-height/2)/travelY) : 0.5)
    }
}

struct SubtitleCue: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var start: Double
    var end: Double
    var text: String
    var translation: String?
    var annotations: [StudyAnnotation]? = nil
    var translationWarning: String? = nil
    var translationSignature: String? = nil
    var recognitionConfidence: Double? = nil
    var recognitionWarning: String? = nil
    var plainMeaning: String? = nil
    var translationModelUsed: String? = nil
    var wordStudies: [WordStudyCache]? = nil
    var contextStudy: ContextStudy? = nil
    var contextStudySignature: String? = nil
    var studyWarning: String? { recognitionWarning ?? translationWarning }
    var studyWarningTitle: String? { recognitionWarning != nil ? "识别待核对" : translationWarning != nil ? "含义待确认" : nil }
    var displayOriginal: String { (recognitionConfidence ?? 1) < 0.45 && recognitionWarning != nil ? "（这句原文暂未识别清楚）" : text }
}

enum TranslationCoverage {
    struct Term: Codable, Equatable { var source: String; var target: String }
    static func directAddresses(_ text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern:"\\b(?:good\\s+(?:morning|afternoon|evening|night)|hello|hi)\\s*,\\s*([a-z][a-z'’−-]*)[.!?]*\\s*$",options:.caseInsensitive),
              let match = regex.firstMatch(in:text,range:NSRange(text.startIndex...,in:text)),
              let range = Range(match.range(at:1),in:text) else { return [] }
        let value = String(text[range])
        let generic = ["everyone","everybody","all","folks","guys","friends","class","boys","girls","you"]
        return generic.contains(value.lowercased()) ? [] : [value]
    }
    static func directAddressIssues(source: String, translation: String) -> [String] {
        guard !directAddresses(source).isEmpty else { return [] }
        let body = translation.replacingOccurrences(of:"[\\p{P}\\s]",with:"",options:.regularExpression)
        if ["各位","大家","诸位","你们"].contains(where:translation.contains) || ["晚安","你好","早上好","晚上好"].contains(body) {
            return ["原句在称呼一个明确的对象，请保留其称呼或中文音译，不改成各位、大家，也不省略称呼。"]
        }
        return []
    }
    static func sourceTerms(_ text: String) -> [String] {
        guard let pattern = try? NSRegularExpression(pattern: "[\\p{Katakana}ー]+(?:・[\\p{Katakana}ー]+)*") else { return [] }
        var seen: Set<String> = []
        let japanese: [String] = Array(pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match -> String? in
            guard let range = Range(match.range, in: text) else { return nil }
            let term = String(text[range])
            return term.count >= 2 && seen.insert(term).inserted ? term : nil
        }.prefix(12))
        return japanese + directAddresses(text)
    }
    static func missing(source: String, translation: String, terms: [Term]?) -> [String] {
        sourceTerms(source).filter { expected in
            !(terms ?? []).contains { term in
                let target = term.target.trimmingCharacters(in: .whitespacesAndNewlines)
                return term.source == expected && ChineseTranslationCheck.isValid(target) && translation.contains(target)
            }
        }
    }
}

enum TranslationParagraphs {
    static func source(_ lines: [String]) -> String {
        lines.enumerated().map { index, text in
            let escaped = text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            return "<p id=\"s\(index)\">\(escaped)</p>"
        }.joined(separator: "\n")
    }
    static func current(_ response: String, count: Int, index: Int) throws -> String {
        var document = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if document.hasPrefix("```"), document.hasSuffix("```") {
            let lines = document.components(separatedBy: "\n")
            guard lines.count >= 3 else { throw invalid() }
            document = lines.dropFirst().dropLast().joined(separator: "\n")
        }
        let regex = try NSRegularExpression(pattern: "<p\\s+id\\s*=\\s*[\"']s([0-9]+)[\"']\\s*>([\\s\\S]*?)</p>")
        let matches = regex.matches(in: document, range: NSRange(document.startIndex..., in: document))
        guard matches.count == count, index >= 0, index < count else { throw invalid() }
        var paragraphs: [Int: String] = [:]
        for match in matches {
            guard let idRange = Range(match.range(at: 1), in: document), let id = Int(document[idRange]),
                  id >= 0, id < count, paragraphs[id] == nil,
                  let textRange = Range(match.range(at: 2), in: document) else { throw invalid() }
            let content = String(document[textRange])
            guard content.range(of: "<[^>]+>", options: .regularExpression) == nil else { throw invalid() }
            paragraphs[id] = content.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'").replacingOccurrences(of: "&amp;", with: "&")
        }
        let outside = regex.stringByReplacingMatches(in: document, range: NSRange(document.startIndex..., in: document), withTemplate: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard outside.isEmpty, let selected = paragraphs[index] else { throw invalid() }
        return selected.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static func invalid() -> StudyError {
        StudyError.message("专用模型未保持字幕分段，已阻止把前后文显示成当前字幕。请重试翻译。")
    }
}

enum RecognitionQuality {
    static let revision = "speech-v12-language-evidence"
    // Gain is capped, and near-silence is not amplified. No noise gate: quiet speech stays.
    static let audioFilter = "highpass=f=60,dynaudnorm=f=150:g=15:p=0.9:m=25:r=0.1:t=0.0001"
    static func whisperArguments(model: String, audio: String, language: String, output: String, vad: String) -> [String] {
        ["-m", model, "-f", audio, "-l", language, "--vad", "-vm", vad, "-vt", "0.35", "-vspd", "150", "-vsd", "350", "-vp", "150", "-sns", "-nf", "-ojf", "-of", output, "-pp"]
    }
}

enum QwenAlignedTranscript {
    private struct Word: Decodable {
        var text: String; var start: Double; var end: Double
        var block: Int?; var confidence: Double?; var warning: String?
    }
    private struct Document: Decodable { var text: String; var words: [Word]; var language: String? }
    static func detectedLanguage(in data: Data) throws -> String? {
        let language = try JSONDecoder().decode(Document.self, from: data).language
        return ["Japanese":"ja", "English":"en", "Korean":"ko", "Chinese":"zh"][language ?? ""]
    }
    static func parse(_ data: Data, ownedStart: Double, ownedEnd: Double) throws -> [SubtitleCue] {
        let document = try JSONDecoder().decode(Document.self, from: data)
        guard document.words.map(\.text).joined() == document.text else { throw StudyError.message("时间对齐未覆盖完整识别文字，请重试。") }
        var cues: [SubtitleCue] = []
        var group: [Word] = []
        var previous = -Double.infinity
        func flush() {
            guard let first = group.first, let last = group.last else { return }
            defer { group = [] }
            let start = max(ownedStart, first.start), end = min(ownedEnd, max(first.start+0.05,last.end))
            let text = group.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
            if end > start && !text.isEmpty {
                var cue = SubtitleCue(start: start, end: end, text: text)
                cue.recognitionConfidence = group.compactMap(\.confidence).min()
                cue.recognitionWarning = group.compactMap(\.warning).first(where: { !$0.isEmpty })
                cues.append(cue)
            }
        }
        for word in document.words {
            guard word.start.isFinite, word.end.isFinite, word.start >= 0, word.end >= word.start, word.start >= previous-0.02 else {
                throw StudyError.message("本地模型返回了无效的字幕时间，请重试。")
            }
            previous = word.start
            // Duration estimates can differ in overlapping windows: a short word
            // can have its midpoint on opposite sides and disappear from both.
            // Its onset is the more stable ownership anchor (English "it" case).
            guard word.start >= ownedStart, word.start < ownedEnd else { flush(); continue }
            let hasCJK = (group.map(\.text).joined()+word.text).range(of: "[\\p{Han}\\p{Hiragana}\\p{Katakana}가-힣]", options: .regularExpression) != nil
            if let last = group.last, let first = group.first,
               word.start-last.end > 1.35 || word.end-first.start > 12 || group.map(\.text).joined().count+word.text.count > (hasCJK ? 84 : 240) { flush() }
            group.append(word)
            if word.text.range(of: "[。！？!?]|[.]\\s*$", options: .regularExpression) != nil { flush() }
        }
        flush()
        return WhisperTranscript.mergeFragments(cues)
    }

    static func mergeBoundary(_ cues: [SubtitleCue], at boundary: Double) -> [SubtitleCue] {
        guard let rightIndex = cues.firstIndex(where: { $0.start >= boundary }), rightIndex > 0 else { return cues }
        let left = cues[rightIndex-1], right = cues[rightIndex]
        let boundaryDuplicate = left.text == right.text && left.end-left.start <= 0.08 && right.start-boundary <= 0.08
        // Only join an unfinished sentence cut by this processing boundary.
        // Separate utterances across a pause or a full stop remain separate.
        guard abs(left.end-boundary) <= 0.25, right.start-boundary <= 0.85,
              right.end-left.start <= 12, left.text.count+right.text.count <= 240,
              boundaryDuplicate || left.text.range(of: "[。！？!?]|[.]\\s*$", options: .regularExpression) == nil else { return cues }
        var merged = left
        let space = left.text.last?.isASCII == true && right.text.first?.isASCII == true ? " " : ""
        // A word starting a few milliseconds on either side can appear as a
        // clipped sliver in the left window and a full cue in the right one.
        // Do not remove real repeated utterances of ordinary speech duration.
        if !boundaryDuplicate { merged.text += space + right.text }
        merged.end = right.end
        merged.recognitionConfidence = min(left.recognitionConfidence ?? 1,right.recognitionConfidence ?? 1)
        merged.recognitionWarning = left.recognitionWarning ?? right.recognitionWarning
        // The old translation covered only a fragment. Keep its identity for
        // playback selection, but regenerate all content derived from its text.
        merged.translation = nil; merged.translationSignature = nil
        merged.annotations = nil; merged.translationWarning = nil
        merged.translationModelUsed = nil; merged.plainMeaning = nil
        var result = cues
        result.replaceSubrange((rightIndex-1)...rightIndex, with: [merged])
        return result
    }
}

enum SentenceReadiness {
    static func needsContinuation(_ cue: SubtitleCue, span: Double, duration: Double, completed: Set<Int>) -> Bool {
        guard span > 0, cue.text.range(of:"[。！？!?]|[.]\\s*$", options:.regularExpression) == nil else { return false }
        let boundary = (cue.end/span).rounded()*span
        guard boundary > 0, boundary < duration-0.05, abs(cue.end-boundary) <= 0.25 else { return false }
        return !completed.contains(Int((boundary/span).rounded()))
    }
}

enum QuestionPunctuation {
    private static func body(_ text: String) -> String {
        String(text.precomposedStringWithCompatibilityMapping.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }
    static func reconcile(_ primary: [SubtitleCue], with secondary: [SubtitleCue]) -> [SubtitleCue] {
        primary.map { original in
            let text = original.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.hasSuffix("?"), !text.hasSuffix("？"), !text.hasSuffix("!"), !text.hasSuffix("！"),
                  secondary.contains(where: { candidate in
                      let other = candidate.text.trimmingCharacters(in: .whitespacesAndNewlines)
                      let overlap = min(original.end,candidate.end)-max(original.start,candidate.start)
                      return (other.hasSuffix("?") || other.hasSuffix("？")) && overlap > 0 &&
                          overlap/max(0.05,min(original.end-original.start,candidate.end-candidate.start)) >= 0.5 && body(text) == body(other)
                  }) else { return original }
            var cue = original
            cue.text = text.trimmingCharacters(in: CharacterSet(charactersIn: "。.")) + "？"
            return cue
        }
    }
}

enum AcousticTranscriptReview {
    private static func body(_ text: String) -> String {
        String(text.precomposedStringWithCompatibilityMapping.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }
    static func reconcile(_ primary: [SubtitleCue], with secondary: [SubtitleCue]) -> [SubtitleCue] {
        primary.map { original in
            let normalized = body(original.text)
            guard normalized.hasPrefix("うん"), !normalized.hasPrefix("ううん"),
                  secondary.contains(where: { candidate in
                      let other = body(candidate.text)
                      let overlap = min(original.end,candidate.end)-max(original.start,candidate.start)
                      return (candidate.recognitionConfidence ?? 0) >= 0.45 && other.hasPrefix("ううん") &&
                          other.dropFirst(3) == normalized.dropFirst(2) &&
                          overlap/max(0.05,min(original.end-original.start,candidate.end-candidate.start)) >= 0.5
                  }), let range = original.text.range(of: "うん"), range.lowerBound == original.text.startIndex else { return original }
            var cue = original
            cue.text.replaceSubrange(range, with: "ううん")
            cue.recognitionConfidence = min(cue.recognitionConfidence ?? 1,0.65)
            cue.recognitionWarning = "两个本地模型对应答的肯定/否定不一致，已采用语音复核结果，请复听核对。"
            return cue
        }
    }
}

enum WhisperTranscript {
    struct SpeechRange: Equatable { var start: Double; var end: Double }
    private struct Span: Decodable { var from: Double; var to: Double }
    private struct Voice: Decodable { var offsets: Span }
    private struct Token: Decodable { var text: String; var p: Double; var offsets: Span? }
    private struct Segment: Decodable { var text: String; var offsets: Span; var tokens: [Token]; var no_speech_prob: Double? }
    private struct Document: Decodable { var subtitle_study_json_revision: Int?; var vad_segments: [Voice]?; var transcription: [Segment] }

    static func missingSpeechRanges(_ data: Data, cues: [SubtitleCue], ownedStart: Double, ownedEnd: Double) throws -> [SpeechRange] {
        // Do not force text from wholly rejected/nonverbal windows. Recover a skipped
        // speech block only when this window already contains credible dialogue.
        guard cues.contains(where: { ($0.recognitionConfidence ?? 0) >= 0.45 }) else { return [] }
        let document = try JSONDecoder().decode(Document.self, from: data)
        return Array((document.vad_segments ?? []).compactMap { voice in
            let start = max(ownedStart, voice.offsets.from/1000)
            let end = min(ownedEnd, voice.offsets.to/1000)
            guard end-start >= 0.6, !cues.contains(where: { $0.end > start && $0.start < end }) else { return nil }
            return SpeechRange(start: start, end: end)
        }.prefix(3))
    }

    static func parse(_ data: Data, ownedStart: Double, ownedEnd: Double, allowEndPadding: Bool = false) throws -> [SubtitleCue] {
        let document = try JSONDecoder().decode(Document.self, from: data)
        guard document.subtitle_study_json_revision == 1, let voices = document.vad_segments else {
            throw StudyError.message("语音检测时间数据不完整，请在设置中使用新版应用自带的 Whisper 工具。")
        }
        // A successfully processed window with no voice is an empty subtitle window.
        guard !voices.isEmpty else { return [] }
        var output: [SubtitleCue] = []
        for segment in document.transcription {
            let description = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "[]()（）【】♪♫ ")).lowercased()
            if ["music", "background music", "silence", "noise", "applause", "音楽", "拍手", "音乐", "静音", "杂音"].contains(description) { continue }
            var group: [Token] = []
            func flush() {
                guard !group.isEmpty else { return }
                defer { group = [] }
                let text = group.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
                guard text.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) else { return }
                let timed = group.compactMap(\.offsets)
                guard let first = timed.first, let last = timed.last else { return }
                let confidence = group.map(\.p).reduce(0, +)/Double(group.count)
                // Do not turn weak but plausible quiet dialogue into an empty subtitle.
                if (segment.no_speech_prob ?? 0) > 0.95 && confidence < 0.2 { return }
                let start = max(ownedStart, first.from/1000)
                let end = min(ownedEnd, max(start+0.05, last.to/1000))
                guard end > start else { return }
                var cue = SubtitleCue(start: start, end: end, text: text)
                cue.recognitionConfidence = confidence
                if confidence < 0.45 { cue.recognitionWarning = "这句音频识别把握较低，可能有错字或漏词。请先复听原声；中文译文也可能受影响。" }
                output.append(cue)
            }
            for token in segment.tokens {
                if token.text.hasPrefix("[_") || token.text.hasPrefix("<|") { continue }
                guard let span = token.offsets, span.from.isFinite, span.to.isFinite, span.from >= 0, span.to >= span.from else { continue }
                let middle = (span.from+span.to)/2000
                // Own each token once across overlapping extraction windows.
                let ownsEndToken = allowEndPadding && span.from/1000 <= ownedEnd+0.05 && middle <= ownedEnd+0.1
                guard middle >= ownedStart && (middle < ownedEnd || ownsEndToken),
                      voices.contains(where: { span.to >= $0.offsets.from-80 && span.from <= $0.offsets.to+80 }) else { flush(); continue }
                if let previous = group.last?.offsets, span.from-previous.to > 650 { flush() }
                group.append(token)
                if token.text.range(of: "[。！？!?]|[.]$", options: .regularExpression) != nil { flush() }
            }
            flush()
        }
        return mergeFragments(output)
    }

    static func mergeFragments(_ cues: [SubtitleCue]) -> [SubtitleCue] {
        var result: [SubtitleCue] = []
        for cue in cues {
            if let last = result.last, cue.start-last.end >= -0.05, cue.start-last.end <= 0.3,
               last.end-last.start < 1.1, last.text.range(of: "[。！？!?]$|[.]$", options: .regularExpression) == nil,
               last.text.count+cue.text.count <= 100, cue.end-last.start <= 7 {
                var merged = result.removeLast()
                let space = last.text.last?.isASCII == true && cue.text.first?.isASCII == true ? " " : ""
                merged.text += space + cue.text; merged.end = cue.end
                merged.recognitionConfidence = min(last.recognitionConfidence ?? 1, cue.recognitionConfidence ?? 1)
                merged.recognitionWarning = last.recognitionWarning ?? cue.recognitionWarning
                result.append(merged)
            } else { result.append(cue) }
        }
        return result
    }
}

enum SubtitlePresentation {
    static func heldIndex(time: Double, cues: [SubtitleCue], minimum: Double, speed: Float, duration: Double) -> Int? {
        guard minimum > 0 else { return nil }
        var low = 0; var high = cues.count
        while low < high { let mid = (low+high)/2; if cues[mid].start <= time { low = mid+1 } else { high = mid } }
        let index = low-1
        guard index >= 0 else { return nil }
        let cue = cues[index]
        let end = min(cue.start+minimum*Double(speed), cue.end+1.2*Double(speed), index+1 < cues.count ? cues[index+1].start : duration)
        return time >= cue.end && time < end ? index : nil
    }
}

struct StudyAnnotation: Codable, Equatable {
    var expression: String
    var kind: String
    var meaning: String
    var usage: String
    var sourceURL: String? = nil
}

enum JapaneseExpressionGuide {
    // A conservative glossary coverage signal, not a semantic accuracy score.
    // Unusual valid paraphrases can miss this list: retry once, then visibly warn.
    static func translationIssues(in source: String, translation: String) -> [String] {
        let concepts: [String: [String]] = [
            "猫を被る-594791": ["装", "假", "伪", "掩饰", "佯"],
            "空気を読む-482319": ["气氛", "察言", "眼力", "眼色", "场合", "分寸", "脸色"],
            "油を注ぐ-426547": ["火上浇油", "恶化", "激化", "加剧", "更糟", "拱火"],
            "Intermediate_DAY4-IDIOMSSAYING.pdf": ["人脉", "交际", "认识", "社交", "熟人", "交友", "朋友多", "朋友广", "结识", "路子广", "关系广", "关系多"],
            "水に流す-637742": ["过去", "翻篇", "既往", "计较", "追究", "不再提", "不提", "忘", "没发生", "一笔勾销", "算了", "原谅", "宽恕", "放下", "抛在", "别在意", "别再", "不要再"],
            "二の足を踏む-592531": ["犹豫", "迟疑", "踌躇", "不敢", "顾虑", "举棋", "踟蹰", "却步", "观望"]
        ]
        var issues = notes(in: source).compactMap { note -> String? in
            guard let key = concepts.keys.first(where: { note.sourceURL?.hasSuffix($0) == true }),
                  let terms = concepts[key], !terms.contains(where: { translation.contains($0) }) else { return nil }
            return "\(note.expression)：\(note.meaning) \(note.usage)"
        }
        if source.range(of:"(?:私|わたし|僕|ぼく|俺|おれ)の",options:.regularExpression) != nil,
           !translation.contains("我"), translation.contains("你") {
            issues.append("原文是说话者自己的所有关系，保留第一人称，不要换成你或对方。")
        }
        return issues
    }
    // Short Chinese paraphrases checked against dictionary entries, not verbatim dictionary text.
    private static let entries: [(forms: [String], meaning: String, usage: String, source: String)] = [
        (["猫をかぶっている", "猫をかぶっていた", "猫をかぶって", "猫をかぶった", "猫をかぶる", "猫を被っている", "猫を被って", "猫を被る", "猫かぶり"], "通常指装乖、装老实，隐藏真实个性。", "这是一种比喻，常带批评或调侃；一般不是真的戴猫或披猫。", "https://kotobank.jp/word/猫を被る-594791"),
        (["空気を読んで", "空気を読め", "空気を読む", "空気を読んだ"], "看懂现场气氛、察言观色，知道此刻该怎么做。", "提醒别人察言观色时可带不满或责备；具体强弱要结合句尾和语境。不是字面上的读空气。", "https://kotobank.jp/word/空気を読む-482319"),
        (["火に油を注ぐ", "火に油を注いで", "火に油を注いだ"], "火上浇油，进一步激化情绪或矛盾。", "在争执等语境下指让事情恶化；本来是往火上倒油使火更旺的比喻。", "https://kotobank.jp/word/油を注ぐ-426547"),
        (["顔が広い", "顔が広く", "顔の広い"], "认识的人多、交际广，人脉广。", "中文可说‘认识的人多’或‘人脉广’。不是‘人缘好/受欢迎’，也不是脸大或脸皮厚。", "https://homestay-in-japan.com/ja/wp-content/uploads/2021/02/Intermediate_DAY4-IDIOMSSAYING.pdf"),
        (["水に流そう", "水に流す", "水に流して", "水に流した"], "不再计较以前的纠纷或不愉快，让过去的事情过去。", "在人际矛盾中相当于既往不咎，不是真的往水里扔东西。常用于和解。", "https://kotobank.jp/word/水に流す-637742"),
        (["二の足を踏んでいる", "二の足を踏んで", "二の足を踏んだ", "二の足を踏む"], "犹豫、迟疑，不敢继续行动。", "比喻迈出第一步后，第二步却迟疑不前，不是在同时踩两只脚。", "https://kotobank.jp/word/二の足を踏む-592531")
    ]
    static func notes(in source: String) -> [StudyAnnotation] {
        var result = entries.compactMap { entry -> StudyAnnotation? in
            guard let form = entry.forms.sorted(by: { $0.count > $1.count }).first(where: source.contains) else { return nil }
            return StudyAnnotation(expression: form, kind: "惯用语", meaning: entry.meaning, usage: entry.usage, sourceURL: entry.source)
        }
        let retorts = ["私のセリフでしょ", "私のせりふでしょ", "私の台詞でしょ", "こっちのセリフ", "こっちのせりふ", "こちらの台詞", "こちらのせりふ"]
        if let surface = retorts.first(where: source.contains) {
            result.append(StudyAnnotation(expression: surface, kind: "口语", meaning: "在回嘴的语境中，表示这话应该由我来说、我才想这么说呢。", usage: "せりふ除了戏剧台词，也指对别人说的话。回应对方同样的不满时，用中文自然表达为‘这话该我说吧’；若确实在排练戏剧，按台词的本义理解。", sourceURL: "https://kotobank.jp/word/台詞-87790"))
        }
        return result
    }
    static func merge(_ generated: [StudyAnnotation], with verified: [StudyAnnotation]) -> [StudyAnnotation] {
        verified + generated.filter { generated in
            !verified.contains { $0.expression.contains(generated.expression) || generated.expression.contains($0.expression) }
        }
    }
    static func referenceNotes(from annotations: [StudyAnnotation], in source: String) -> [StudyAnnotation] {
        let known = notes(in: source)
        return annotations.filter { known.contains($0) }
    }
}

enum EnglishExpressionGuide {
    // Chinese paraphrases of the linked dictionary senses. Matching is bounded
    // by English word boundaries and keeps the original inflected surface text.
    private struct Entry {
        var pattern: String; var kind = "惯用语"; var meaning: String; var usage: String
        var source: String; var concepts: [String]
    }
    private static let entries: [Entry] = [
        Entry(pattern: "\\b(?:spill|spills|spilled|spilling|spilt)\\s+the\\s+beans\\b", meaning: "泄露秘密，把原本保密的事说出来。", usage: "日常口语中常指说漏嘴；否定或劝阻时，要保留‘别泄密’的意思。若场景真的是豆子洒了，需要按字面理解。", source: "https://dictionary.cambridge.org/us/dictionary/english/spill-the-beans", concepts: ["秘密", "泄", "透露", "说漏", "保密"]),
        Entry(pattern: "\\b(?:pull|pulls|pulled|pulling)\\s+(?:my|your|his|her|our|their|someone['’]s)\\s+leg\\b", meaning: "逗人、开玩笑，让对方暂时信以为真。", usage: "通常是熟人间的玩笑，不是在真的拉腿；若涉及身体动作，需要结合场景区分。", source: "https://dictionary.cambridge.org/us/dictionary/english/pull-leg", concepts: ["玩笑", "逗", "闹着玩", "骗你玩", "耍"]),
        Entry(pattern: "\\b(?:call|calls|called|calling)\\s+it\\s+a\\s+day\\b", meaning: "结束眼前的工作或活动，今天先到这里。", usage: "常用于收工或决定暂时停下；本身不表示永远放弃这件事。", source: "https://dictionaryblog.cambridge.org/2023/07/12/phrases-with-day-part-2/", concepts: ["收工", "到此", "到这", "结束", "就这样", "今天就", "今天先", "停"]),
        Entry(pattern: "\\bunder\\s+the\\s+weather\\b", meaning: "身体不舒服，感觉有些不适。", usage: "非正式表达，通常说身体状况；不是在描述天气，也不能仅凭这句话判断具体疾病。", source: "https://dictionary.cambridge.org/us/dictionary/english/under-the-weather", concepts: ["不舒服", "不太舒服", "不适", "生病", "欠佳", "身体不好", "不太好"]),
        Entry(pattern: "\\b(?:i|he|she|we|they|you)\\s+(?:wasn['’]t|weren['’]t|was\\s+not|were\\s+not)\\s+serious\\b", kind: "口语", meaning: "通常说明刚才的话不是认真的，可能是在开玩笑。", usage: "这里的 serious 描述说话的态度或用意；不是说一个人不存在或不真实。涉及工作态度等情境时，也可能是在说当时不够认真。", source: "https://dictionary.cambridge.org/dictionary/english/serious", concepts: ["认真", "玩笑", "当真", "随口", "逗"]),
        Entry(pattern: "\\b(?:in|into)\\s+high\\s+gear\\b", meaning: "用于工作或活动时，表示加大力度、加紧推进，进入高强度或全力运转的状态。", usage: "描述工作进度时按比喻义翻译，不是换到汽车高速挡；如果确实在谈驾驶或变速箱，则按字面理解。", source: "https://www.oxfordlearnersdictionaries.com/definition/english/high-gear", concepts: ["高强度", "加紧", "全力", "加速", "加大", "高效", "忙碌", "高速运转"]),
        Entry(pattern: "\\ball[-\\s]nighters?\\b", kind: "口语", meaning: "通宵不睡，通常为了工作、学习或参加活动。", usage: "pull an all-nighter 表示熬一个通宵。保留原句的数量、否定和语气，词语本身不包含‘不应该熬夜’的评价。", source: "https://dictionary.cambridge.org/us/dictionary/english/all-nighter", concepts: ["通宵", "整夜", "整晚", "彻夜", "一夜没", "一夜未"])
    ]
    private static func matches(_ source: String) -> [(Entry, String)] {
        entries.compactMap { entry in
            guard let regex = try? NSRegularExpression(pattern: entry.pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
                  let range = Range(match.range, in: source) else { return nil }
            return (entry, String(source[range]))
        }
    }
    static func notes(in source: String) -> [StudyAnnotation] {
        matches(source).map { entry, surface in
            StudyAnnotation(expression: surface, kind: entry.kind, meaning: entry.meaning, usage: entry.usage, sourceURL: entry.source)
        }
    }
    static func translationIssues(in source: String, translation: String) -> [String] {
        matches(source).compactMap { entry, surface in
            entry.concepts.contains(where: translation.contains) ? nil : "\(surface)：\(entry.meaning) \(entry.usage)"
        }
    }
}

enum StudyExpressionGuide {
    static func notes(in source: String) -> [StudyAnnotation] { JapaneseExpressionGuide.notes(in: source) + EnglishExpressionGuide.notes(in: source) }
    static func translationIssues(in source: String, translation: String) -> [String] {
        JapaneseExpressionGuide.translationIssues(in: source, translation: translation) + EnglishExpressionGuide.translationIssues(in: source, translation: translation)
    }
    static func merge(_ generated: [StudyAnnotation], with verified: [StudyAnnotation]) -> [StudyAnnotation] { JapaneseExpressionGuide.merge(generated, with: verified) }
    static func referenceNotes(from annotations: [StudyAnnotation], in source: String) -> [StudyAnnotation] {
        let known = notes(in: source)
        return annotations.filter { known.contains($0) }
    }
}

enum ChineseTranslationCheck {
    // Han characters are shared by Chinese and Japanese; kana are an unambiguous leak.
    static func containsKana(_ text: String) -> Bool {
        // ICU includes some shared punctuation in Japanese scripts; test letters only.
        let letters = text.unicodeScalars.filter { [.otherLetter, .modifierLetter].contains($0.properties.generalCategory) }
        return String(String.UnicodeScalarView(letters)).range(of: "[\\p{Hiragana}\\p{Katakana}]", options: .regularExpression) != nil
    }
    static func isValid(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !value.isEmpty && value.count <= 4000 && !value.contains("<think>") && !value.contains("</think>") && !containsKana(value)
    }
}

// Kept separately from translations: optional learning notes never replace the subtitle.
struct SubtitleWordSelection: Codable, Equatable, Hashable {
    var expression: String
    var location: Int
    var length: Int
    var range: NSRange { NSRange(location: location, length: length) }
    func isValid(in source: String) -> Bool {
        let count = (source as NSString).length
        guard location >= 0, length > 0, location <= count, length <= count-location,
              let range = Range(range, in: source), !expression.isEmpty, expression.count <= 100 else { return false }
        return String(source[range]) == expression && expression.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }
    static func selected(in source: String, range: NSRange) -> Self? {
        guard let swiftRange = Range(range, in: source) else { return nil }
        let trimmed = source[swiftRange].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let bounded = (source as NSString).range(of: trimmed, options: [], range: range)
        let value = Self(expression: trimmed, location: bounded.location, length: bounded.length)
        return value.isValid(in: source) ? value : nil
    }
    static func word(in source: String, atUTF16 offset: Int) -> Self? {
        guard offset >= 0, offset < (source as NSString).length,
              let character = Range(NSRange(location: offset, length: 0), in: source)?.lowerBound,
              character < source.endIndex,
              source[character].unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) else { return nil }
        let tokenizer = NLTokenizer(unit: .word); tokenizer.string = source
        if !ChineseTranslationCheck.containsKana(source) {
            return selected(in: source, range: NSRange(tokenizer.tokenRange(at: character), in: source))
        }
        // NLTokenizer splits Japanese auxiliary endings (e.g. 付き合っ / た).
        // Join common inflections only at real tokenizer boundaries; never cut the next word.
        var tokens: [Range<String.Index>] = []
        tokenizer.enumerateTokens(in: source.startIndex..<source.endIndex) { range, _ in tokens.append(range); return true }
        let endings = ["ていませんでした", "でいませんでした", "ていなかった", "でいなかった", "ていました", "でいました", "ていません", "でいません",
                       "ませんでした", "たくなかった", "ている", "でいる", "ていた", "でいた", "ていない", "でいない", "じゃなかった", "じゃない",
                       "たくない", "たかった", "なかった", "ました", "ません", "ましょう", "ます", "ない", "たい", "たく", "れる", "られる", "させる", "た", "て", "る"]
        var index = 0
        while index < tokens.count {
            let start = tokens[index].lowerBound
            var end = tokens[index].upperBound
            let stem = String(source[start..<end])
            if stem.unicodeScalars.contains(where: { (0x3040...0x30ff).contains(Int($0.value)) || (0x4e00...0x9fff).contains(Int($0.value)) }) {
                let suffixes = endings + (stem.hasSuffix("ん") ? ["だ", "で"] : [])
                let remaining = source[end...]
                if let suffix = suffixes.filter({ remaining.hasPrefix($0) }).sorted(by: { $0.count > $1.count }).first(where: { suffix in
                    let candidate = source.index(end, offsetBy: suffix.count)
                    return tokens[(index+1)...].contains { $0.upperBound == candidate }
                }) { end = source.index(end, offsetBy: suffix.count) }
            }
            let group = start..<end
            if group.contains(character) { return selected(in: source, range: NSRange(group, in: source)) }
            index += 1
            while index < tokens.count && tokens[index].lowerBound < end { index += 1 }
        }
        return nil
    }
}

struct WordStudyCache: Codable, Equatable {
    var selection: SubtitleWordSelection
    var comparison: String?
    var signature: String
    var result: ContextStudy
}

struct ContextStudyLine: Codable, Equatable, Identifiable {
    var id: String
    var start: Double
    var text: String
    var isCurrent: Bool
}

enum StudyComparison {
    // Constrain the lexeme, not whether a form fits the sentence. Unknown forms
    // stay literal: the model must explain an awkward replacement, not swap words.
    static func forms(of input: String) -> [String] {
        let term = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var forms = [term]
        func append(_ suffix: String, removing count: Int = 1) { forms.append(String(term.dropLast(count)) + suffix) }
        if term.hasSuffix("する") {
            for suffix in ["した", "して", "しない", "しなかった", "します", "しました", "しません", "しませんでした", "している", "していた"] { append(suffix, removing: 2) }
        } else if term.hasSuffix("くる") || term.hasSuffix("来る") {
            // Irregular verbs are intentionally literal rather than guessed.
        } else if let last = term.last, "うつるむぶぬくぐす".contains(last), ChineseTranslationCheck.containsKana(term) {
            let endings: [Character: (String, String, String, String)] = [
                "う": ("った", "って", "わ", "い"), "つ": ("った", "って", "た", "ち"),
                "る": ("った", "って", "ら", "り"), "む": ("んだ", "んで", "ま", "み"),
                "ぶ": ("んだ", "んで", "ば", "び"), "ぬ": ("んだ", "んで", "な", "に"),
                "く": ("いた", "いて", "か", "き"), "ぐ": ("いだ", "いで", "が", "ぎ"), "す": ("した", "して", "さ", "し")]
            if let (past, te, negative, polite) = endings[last] {
                append(past); append(te); append(negative+"ない"); append(negative+"なかった")
                for ending in ["いる", "いた", "る", "た"] { append(te+ending) }
                append(polite+"ます"); append(polite+"ました")
            }
            // る may be ichidan or godan. These are candidates, not a grammar verdict.
            if last == "る" { for suffix in ["た", "て", "ない", "なかった", "ます", "ました", "ている", "ていた", "てる", "てた"] { append(suffix) } }
            if term == "行く" { forms += ["行った", "行って"] }
        }
        return Array(Set(forms)).sorted()
    }
    static func matches(_ replacement: String, requested: String) -> Bool {
        forms(of: requested).contains { $0.compare(replacement, options: [.caseInsensitive, .widthInsensitive]) == .orderedSame }
    }
    static func allowedForms(of requested: String, replacing original: String) -> [String] {
        // When comparing two forms of the SAME verb (笑わない vs 笑う), the
        // explicitly requested form is the experiment, not another inflection.
        let values = matches(original, requested: requested) ? [requested] : forms(of: requested)
        return values.filter { $0.compare(original, options: [.caseInsensitive, .widthInsensitive]) != .orderedSame }
    }
}

struct ContextStudy: Codable, Equatable {
    struct Evidence: Codable, Equatable { var cueID: String; var quote: String }
    struct WordChoice: Codable, Equatable {
        var expression: String
        var meaning: String
        var reason: String
        var alternative: String
        var difference: String
        var replacement: String? = nil
        var replacementFit: String? = nil
    }
    var background: String
    var intent: String
    var evidence: [Evidence]
    var words: [WordChoice]
    var uncertainty: String
    var referenceOnly: Bool? = nil
    var referenceURLs: [String]? = nil

    func validated(lines: [ContextStudyLine], selection: SubtitleWordSelection? = nil, comparison: String? = nil) throws -> Self {
        func chinese(_ value: String, required: Bool = true) -> Bool {
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return (!required && text.isEmpty) || (!text.isEmpty && text.count <= 700
                && text.unicodeScalars.contains { (0x4e00...0x9fff).contains(Int($0.value)) })
        }
        let allowedExamples = lines.map(\.text) + words.map(\.alternative) + [comparison ?? ""]
        let currentText = lines.first(where: \.isCurrent)?.text ?? ""
        func matchingSourceLanguage(_ value: String) -> Bool {
            if ChineseTranslationCheck.containsKana(currentText) { return ChineseTranslationCheck.containsKana(value) }
            if currentText.unicodeScalars.contains(where: { (0xac00...0xd7af).contains(Int($0.value)) }) {
                return value.unicodeScalars.contains { (0xac00...0xd7af).contains(Int($0.value)) }
            }
            if currentText.range(of: "[A-Za-z]{2}", options: .regularExpression) != nil {
                return value.range(of: "[A-Za-z]{2}", options: .regularExpression) != nil
            }
            return true
        }
        func groundedQuotes(_ text: String, lexical: Bool = false) -> Bool {
            let regex = try! NSRegularExpression(pattern: "[‘“「『]([^’”」』]+)[’”」』]")
            return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).allSatisfy { match in
                guard let range = Range(match.range(at: 1), in: text) else { return false }
                let quote = String(text[range])
                let sourceLanguage = ChineseTranslationCheck.containsKana(quote) || quote.range(of: "[A-Za-z]{2}", options: .regularExpression) != nil
                func prose(_ value: String) -> String { value.replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "‘", with: "'").lowercased() }
                return !sourceLanguage || allowedExamples.contains(where: { prose($0).contains(prose(quote)) })
                    || (lexical && StudyComparison.forms(of: quote).contains(where: currentText.contains))
            }
        }
        guard let current = lines.first(where: \.isCurrent), chinese(background), chinese(intent), chinese(uncertainty, required: false),
              // Dialogue claims must quote supplied lines; focused lexical notes may introduce
              // dictionary forms and teaching examples, separate from the exact evidence list.
              [background, intent].allSatisfy({ groundedQuotes($0) }), groundedQuotes(uncertainty, lexical: true),
              (selection != nil || words.flatMap { [$0.meaning, $0.reason, $0.difference] }.allSatisfy({ groundedQuotes($0, lexical: true) })),
              !evidence.isEmpty, evidence.count <= 4, !words.isEmpty, words.count <= 3,
              evidence.allSatisfy({ item in !item.quote.isEmpty && item.quote.count <= 800 && lines.contains { $0.id == item.cueID && $0.text.contains(item.quote) } }),
              Set(words.map(\.expression)).count == words.count,
              words.allSatisfy({ !$0.expression.isEmpty && current.text.contains($0.expression) && $0.expression.count <= 100
                  && chinese($0.meaning) && chinese($0.reason) && chinese($0.difference)
                  && !$0.alternative.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.alternative.count <= 1000
                  && $0.alternative != $0.expression && $0.alternative != current.text && matchingSourceLanguage($0.alternative) }) else {
            throw StudyError.message("语境解析缺少可核对的原话依据，或解释内容不完整，请重试。")
        }
        if words.contains(where: { $0.reason.count < 10 || $0.difference.count < 12 }) {
            throw StudyError.message("用词原因和替换差别过于简略。必须具体解释所学词和候选词的差异，不能只写不确定。")
        }
        if selection == nil, words.contains(where: { word in
            current.text.components(separatedBy: word.expression).count <= word.alternative.components(separatedBy: word.expression).count
        }) {
            throw StudyError.message("整句改写必须实际替换 expression 指定的词，不能只删掉其他文字或只在说明里声称已替换。")
        }
        if selection == nil {
            let firstPerson = "私|わたし|わたくし|僕|ぼく|俺|おれ|\\b(?:I|me|my|mine|we|us|our|ours)\\b"
            if current.text.range(of: firstPerson, options: [.regularExpression, .caseInsensitive]) != nil,
               words.contains(where: { $0.alternative.range(of: firstPerson, options: [.regularExpression, .caseInsensitive]) == nil }) {
                throw StudyError.message("近义改写不能把原句的我或我们换成你、他或其他人物。请保留原说话者。")
            }
        }
        for word in words {
            if current.text.range(of: "^Good night\\b", options: [.regularExpression, .caseInsensitive]) != nil, word.meaning.contains("晚上好") {
                throw StudyError.message("Good night 在这里是晚安或临别用语，不能解释成 Good evening 的晚上好。")
            }
            if word.expression.hasSuffix("た") {
                let surface = NSRegularExpression.escapedPattern(for: word.expression)
                let wrongTense = surface + "[’”」']?(?:是|为)(?:现在时|将来时|被动式|自谦形式)"
                if [word.meaning, word.reason, word.difference].contains(where: { $0.range(of: wrongTense, options: .regularExpression) != nil }) {
                    throw StudyError.message("当前所选词是以た结尾的过去词形，请核对活用，不能称作现在时、将来时或无依据的被动、自谦形式。")
                }
            }
            if let fit = word.replacementFit, fit != "不宜直接替换", word.difference.range(of: "不宜直接替换|不能直接替换|无法直接替换", options: .regularExpression) != nil {
                throw StudyError.message("替换结论与差别说明矛盾；如果说明不能直接替换，结论也必须标不宜直接替换。")
            }
        }
        if selection == nil,
           let regex = try? NSRegularExpression(pattern: "^(?:Good night|Good morning|Good evening|Hello|Hi|Hey),\\s*([A-Za-z]+)[.!?]?$", options: .caseInsensitive),
           let match = regex.firstMatch(in: current.text, range: NSRange(current.text.startIndex..., in: current.text)),
           let range = Range(match.range(at: 1), in: current.text) {
            let address = String(current.text[range])
            if words.contains(where: { !$0.alternative.localizedCaseInsensitiveContains(address) }) {
                throw StudyError.message("自动改写问候语时必须保留原有称呼，不能猜成另一种人物、动物或身份。")
            }
        }
        // Narrow guard for an observed failure, not a general semantic truth checker.
        let dialogue = lines.map(\.text).joined(separator: "\n")
        let statedRomance = dialogue.range(of: "恋人|恋愛関係|交際中|彼氏|夫婦|\\b(?:boyfriend|girlfriend|spouse|married)\\b", options: [.regularExpression, .caseInsensitive]) != nil
        if !statedRomance {
            let assertion = try! NSRegularExpression(pattern: "(?:暗示|表明|意味着|体现).{0,10}(?:恋爱|情侣|恋人|亲密关系)|(?:可能|或许|也许)(?:存在|有|是|为)?(?:恋爱关系|情侣|恋人)|(?:两人|双方|他们|她们)(?:是|属于|处于)(?:一对)?(?:情侣|恋人|恋爱关系)")
            for text in [background, intent] + words.flatMap({ [$0.meaning, $0.reason, $0.difference] }) {
                for clause in text.components(separatedBy: CharacterSet(charactersIn: "，。；！？\n")) {
                    for match in assertion.matches(in: clause, range: NSRange(clause.startIndex..., in: clause)) {
                        let prefix = (clause as NSString).substring(to: match.range.location)
                        if String(prefix.suffix(10)).range(of: "不能|不代表|不等于|无法|没有|并不|并非|未能|不足以|是否|不确定", options: .regularExpression) == nil {
                            throw StudyError.message("对白未明确人物恋爱关系；不能仅由一起活动或某个多义词推断、暗示恋爱。请删除这项猜测，解释对白本身。")
                        }
                    }
                }
            }
        }
        if let selection {
            guard selection.isValid(in: current.text), words.count == 1,
                  let word = words.first, word.expression == selection.expression,
                  let replacement = word.replacement, !replacement.isEmpty, replacement.count <= 100,
                  replacement != selection.expression,
                  word.alternative == (current.text as NSString).replacingCharacters(in: selection.range, with: replacement),
                  ["可替换", "语气或含义有变化", "不宜直接替换"].contains(word.replacementFit ?? "") else {
                throw StudyError.message("解析没有针对选中的词，或替换对比改变了句子的其他部分，请重试。")
            }
            if let comparison {
                guard StudyComparison.allowedForms(of: comparison, replacing: selection.expression).contains(where: { $0.compare(replacement, options: [.caseInsensitive, .widthInsensitive]) == .orderedSame }),
                      [comparison, replacement].contains(where: { word.difference.localizedCaseInsensitiveContains($0) }) else {
                    throw StudyError.message("必须比较指定的近义词“\(comparison)”及其必要活用，不能换成其他词；差别说明也必须讨论这个词。")
                }
            }
        }
        return self
    }
}

// Small dictionary/grammar fallbacks for recurring ambiguities. These match
// linguistic forms and supplied activities, never video IDs, names or reference captions.
enum ContextStudyReference {
    static func needsReference(_ result: ContextStudy, lines: [ContextStudyLine]) -> Bool {
        let source = lines.first(where: \.isCurrent)?.text ?? ""
        let explanation = ([result.background, result.intent] + result.words.flatMap { [$0.meaning, $0.reason, $0.difference] }).joined(separator: "\n")
        if source.contains("驚いた") && source.contains("好き") {
            return ["呆滞", "失语", "情感矛盾", "情感冲突", "物品归属"].contains(where: explanation.contains)
        }
        if source.contains("セリフ") || source.contains("せりふ") {
            return ["发言权", "话语权", "解释权", "关系归属", "分配台词"].contains(where: explanation.contains)
        }
        return false
    }

    static func make(lines: [ContextStudyLine], selection: SubtitleWordSelection?, comparison: String?) -> ContextStudy? {
        guard let current = lines.first(where: \.isCurrent),
              let prior = lines.filter({ !$0.isCurrent && $0.start < current.start }).max(by: { $0.start < $1.start }) else { return nil }
        if let selection, !selection.isValid(in: current.text) { return nil }
        let before = lines.filter { !$0.isCurrent && $0.start < current.start }
        var evidence = [ContextStudy.Evidence(cueID: prior.id, quote: prior.text), .init(cueID: current.id, quote: current.text)]
        let text = current.text
        func result(expression: String, replacement: String, background: String, intent: String, meaning: String, reason: String, difference: String, fit: String, uncertainty: String, url: String) -> ContextStudy? {
            guard selection.map({ $0.expression == expression }) ?? true else { return nil }
            let range = selection?.range ?? (text as NSString).range(of: expression)
            guard range.location != NSNotFound else { return nil }
            let alternative = (text as NSString).replacingCharacters(in: range, with: replacement)
            return ContextStudy(background: background, intent: intent, evidence: evidence,
                words: [.init(expression: expression, meaning: meaning, reason: reason, alternative: alternative, difference: difference, replacement: replacement, replacementFit: fit)],
                uncertainty: uncertainty, referenceOnly: true, referenceURLs: [url])
        }
        if text.contains("ううん"), text.contains("驚いた"),
           text.range(of: "(?:けど|けれど|でも)(?:私は|わたしは|僕は|俺は)?好き", options: .regularExpression) != nil,
           prior.text.contains("呆れ") {
            guard selection == nil || selection?.expression == "驚いた",
                  comparison == nil || ["呆れた", "呆れる", "びっくりした"].contains(comparison!) else { return nil }
            let replacement = comparison == "呆れた" || comparison == "呆れる" ? "呆れた" : "びっくりした"
            let difference = replacement == "呆れた"
                ? "呆れた通常增加无奈、无语或受不了的评价；驚いた只说明吃惊。替换会改变对前句判断的回应，不能当成原意相同。语法仍可成立，与后面说喜欢也不是逻辑上绝不能共存。"
                : "びっくりした也表达吃惊，较突出突然受到刺激的反应；驚いた可较概括地描述惊讶。这里保留后面的喜欢，不添加喜欢谁的判断。"
            return result(expression: "驚いた", replacement: replacement,
                background: "前句把反应判断为无语或受不了；当前句先否认这个判断，再说明只是有点惊讶，随后仍表达喜欢。",
                intent: "纠正前句对自己反应的理解，同时保留喜欢这一肯定态度。",
                meaning: "感到惊讶；这里与前句所说的无语、受不了作区分。",
                reason: "开头的否定应答针对前句判断，后面的惊讶和喜欢仍是说话者明确承认的内容，不能一并否定。",
                difference: difference, fit: "语气或含义有变化",
                uncertainty: "喜欢的对象在当前句中省略，不能据此补成喜欢你或他，也不能确认人物关系。",
                url: "https://kotobank.jp/word/呆れる-423258")
        }
        if text.contains("付き合った"), selection == nil || selection?.expression == "付き合った" {
            let activities = [("映画", "看电影"), ("買い物", "购物"), ("食事", "吃饭"), ("散歩", "散步")]
            guard let activity = activities.first(where: { entry in before.contains { $0.text.contains(entry.0) } }),
                  text.range(of: "年|ヶ月|か月|交際|恋人|彼氏", options: .regularExpression) == nil,
                  !lines.contains(where: { $0.text.range(of: "恋人|彼氏|交際中|恋愛関係|夫婦|演劇|台本", options: .regularExpression) != nil }),
                  comparison == nil || ["一緒に行く", "一緒に行った", "同行する", "同行した"].contains(comparison!) else { return nil }
            let replacement = comparison?.hasPrefix("同行") == true ? "同行した" : "一緒に行った"
            if let activityLine = before.last(where: { $0.text.contains(activity.0) }), !evidence.contains(where: { $0.cueID == activityLine.id }) {
                evidence.insert(.init(cueID: activityLine.id, quote: activityLine.text), at: 0)
            }
            let background = text.contains("こないだ") && text.contains("も")
                ? "前文谈到\(activity.1)，当前句用前不久也一起参与过的经历提醒对方。"
                : "前文谈到\(activity.1)，当前句回顾曾陪同或一起参与活动的经历。"
            return result(expression: "付き合った", replacement: replacement, background: background,
                intent: "提醒对方已有共同活动的经历，并请对方确认。",
                meaning: "在所给活动语境中，较有依据的是陪同、一起参与活动这一义项。",
                reason: "前文给出的线索是\(activity.1)这项活动；这个词有多种义项，不能只因为有交往义就推断恋爱。结尾的た是过去词形。",
                difference: "\(replacement)明确表达一同前往或同行；原词还可带有配合、陪对方参与活动的意思。替换保留共同活动的基本事实，但陪同的侧重点可能减弱，并不证明人物亲密程度。",
                fit: "语气或含义有变化", uncertainty: "对白未标注说话者；具体人物关系不能由一起参加活动确定。",
                url: "https://kotobank.jp/word/付合う-570957")
        }
        if text.contains("私のセリフ"), prior.text.range(of: "なんで|どうして|嫌", options: .regularExpression) != nil,
           !lines.contains(where: { $0.text.range(of: "演劇|芝居|台本|稽古|配役", options: .regularExpression) != nil }) {
            let expression = selection?.expression ?? "私のセリフ"
            guard ["私のセリフ", "セリフ"].contains(expression),
                  comparison == nil || (expression == "セリフ" && ["言葉", "ことば"].contains(comparison!)) else { return nil }
            let replacement = expression == "セリフ" ? (comparison ?? "言葉") : "私が言いたいこと"
            return result(expression: expression, replacement: replacement,
                background: "前句对与某人一起这件事表示不满，当前句把同样的话回敬给对方。",
                intent: "表示这话该我说吧，我也有同样的不满；是在回嘴。",
                meaning: "在这种回应中指自己也想说的那句话，不是决定谁有发言权。",
                reason: "这里借用台词这一说法回敬刚听到的不满，让同一句质问反过来适用于对方。没有把人物身份或任务分工当作已知。",
                difference: expression == "セリフ"
                    ? "\(replacement)泛指话语；原词在这个固定回应中带有这话该我说的回敬意味。只换成这个词，通常不能等同保留原来的回嘴语气，需要结合整句判断。"
                    : "\(replacement)把我想说的话直接说出来，保留第一人称，少了借用台词来回敬的表达方式；这是改写示例，不是视频原话。",
                fit: expression == "セリフ" ? "不宜直接替换" : "语气或含义有变化",
                uncertainty: "说话者身份和前句指的人未明确，不据此判断情侣、亲属关系或具体分工。",
                url: "https://kotobank.jp/word/此方の台詞-3241591")
        }
        return nil
    }
}

struct StudyTranslation: Codable {
    var translation: String
    var annotations: [StudyAnnotation]
    var warning: String
    var plainMeaning: String? = nil
    var modelUsed: String? = nil

    func validated(for source: String) throws -> StudyTranslation {
        let text = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ChineseTranslationCheck.isValid(text) else {
            if ChineseTranslationCheck.containsKana(text) { throw StudyError.message("译文仍包含日文，已阻止显示。请重试翻译或更换模型。") }
            throw StudyError.message("模型返回的译文无效，请重试或更换翻译模型。")
        }
        var expressions: Set<String> = []
        let ordinaryExpressions: Set<String> = ["もう一度", "もう一回", "ありがとうございます", "ありがとう", "こんにちは", "今日は", "明日", "お金が入ってない"]
        let notes = annotations.filter { note in
            !note.expression.isEmpty && source.contains(note.expression)
                && ["惯用语", "俗语", "口语", "俚语", "文化表达"].contains(note.kind)
                && !(ordinaryExpressions.contains(note.expression) && ["惯用语", "俗语", "俚语"].contains(note.kind))
                && !note.meaning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && note.meaning.count <= 500 && note.usage.count <= 500
                && expressions.insert(note.expression).inserted
        }
        let meaning = plainMeaning?.trimmingCharacters(in: .whitespacesAndNewlines)
        return StudyTranslation(translation: text, annotations: Array(notes.prefix(4)), warning: String(warning.prefix(500)), plainMeaning: meaning.flatMap { !$0.isEmpty && $0.count <= 400 && !ChineseTranslationCheck.containsKana($0) ? $0 : nil }, modelUsed: modelUsed)
    }
}

struct SubtitleDocument: Codable {
    var version = 1
    var source: String
    var cues: [SubtitleCue]
    var language: String? = nil
    var offset: Double? = nil
    var generationSignature: String? = nil
    var chunkSeconds: Double? = nil
    var completedChunks: [Int]? = nil
}

enum SubtitleCodec {
    static func parse(_ source: String) throws -> [SubtitleCue] {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var cues: [SubtitleCue] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            guard line.contains("-->") else { index += 1; continue }
            let times = line.components(separatedBy: "-->")
            guard times.count == 2, let start = timestamp(times[0]), let end = timestamp(times[1]), end > start else {
                throw StudyError.message("字幕时间格式无效：\(line)")
            }
            index += 1
            var body: [String] = []
            while index < lines.count && !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                body.append(lines[index]); index += 1
            }
            let text = body.joined(separator: "\n").replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            if !text.isEmpty { cues.append(SubtitleCue(start: start, end: end, text: text)) }
        }
        guard !cues.isEmpty else { throw StudyError.message("没有找到字幕，请导入 UTF-8 编码的 SRT 或 VTT 文件。") }
        return cues.sorted { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
    }

    static func timestamp(_ value: String) -> Double? {
        let token = value.trimmingCharacters(in: .whitespaces).components(separatedBy: .whitespaces).first ?? ""
        let parts = token.replacingOccurrences(of: ",", with: ".").split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2 || parts.count == 3, parts.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
        if parts.count == 3 { return parts[0] * 3600 + parts[1] * 60 + parts[2] }
        return parts[0] * 60 + parts[1]
    }

    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.isFinite ? seconds : 0))
        if total >= 3600 { return String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60) }
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    static func srt(_ cues: [SubtitleCue]) -> String {
        func stamp(_ value: Double) -> String {
            let ms = max(0, Int((value * 1000).rounded()))
            return String(format: "%02d:%02d:%02d,%03d", ms / 3600000, ms / 60000 % 60, ms / 1000 % 60, ms % 1000)
        }
        return cues.enumerated().map { index, cue in
            "\(index + 1)\n\(stamp(cue.start)) --> \(stamp(cue.end))\n\(cue.text)\n"
        }.joined(separator: "\n")
    }
}

enum StudyError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

enum SubtitleWaitReason: Equatable { case original, translation }

enum SubtitlePlaybackBuffer {
    static func reason(time: Double, duration: Double, lookahead: Double, span: Double, completed: Set<Int>, needsOriginal: Bool, cues: [SubtitleCue], maximumEnds: [Double], needsTranslation: Bool) -> SubtitleWaitReason? {
        let start = max(0, time)
        let end = duration > 0 ? min(max(start, duration-0.001), start+max(0, lookahead)) : start+max(0, lookahead)
        if needsOriginal {
            guard duration > 0 else { return .original }
            let last = max(0, Int(ceil(duration/span))-1)
            let firstChunk = min(last, ChunkTimeline.index(at: start, span: span))
            let lastChunk = min(last, ChunkTimeline.index(at: end, span: span))
            if (firstChunk...lastChunk).contains(where: { !completed.contains($0) }) { return .original }
        }
        guard needsTranslation else { return nil }
        return pendingTranslationIndex(start: start, end: end, cues: cues, maximumEnds: maximumEnds) == nil ? nil : .translation
    }

    static func pendingTranslationIndex(start: Double, end: Double, cues: [SubtitleCue], maximumEnds: [Double]) -> Int? {
        guard cues.count == maximumEnds.count else { return nil }
        // Bound the search to cues overlapping the buffer, including imported overlaps.
        var low = 0; var high = cues.count
        while low < high {
            let mid = (low+high)/2
            if maximumEnds[mid] <= start { low = mid+1 } else { high = mid }
        }
        var index = low
        while index < cues.count && cues[index].start <= end {
            if cues[index].end > start && !(cues[index].translation.map(ChineseTranslationCheck.isValid) ?? false) { return index }
            index += 1
        }
        return nil
    }
}


enum ChunkTimeline {
    static func index(at time: Double, span: Double) -> Int { max(0, Int(max(0, time) / span)) }
    static func window(index: Int, span: Double, duration: Double, context: Double = 1.5) -> (start: Double, end: Double, audioStart: Double, audioEnd: Double) {
        let start = Double(index) * span
        let end = min(duration, start + span)
        return (start, end, max(0, start - context), min(duration, end + context))
    }
    static func project(_ local: [SubtitleCue], audioStart: Double, start: Double, end: Double) -> [SubtitleCue] {
        local.compactMap { cue in
            var global = cue
            global.start = max(start, cue.start + audioStart)
            global.end = min(end, cue.end + audioStart)
            return global.end > global.start ? global : nil
        }
    }
}

// Coordinates are normalized to the actual movie, not the window or its letterboxing.
struct CoverRegion: Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    enum Corner: CaseIterable { case topLeft, topRight, bottomLeft, bottomRight }
    func clamped() -> CoverRegion {
        let w = min(1, max(0.18, width.isFinite ? width : 1))
        let h = min(1, max(0.08, height.isFinite ? height : 0.18))
        return CoverRegion(x: min(1-w, max(0, x.isFinite ? x : 0)), y: min(1-h, max(0, y.isFinite ? y : 0.82)), width: w, height: h)
    }
    func pixels(in size: CGSize) -> CGRect {
        let value = clamped()
        let left: CGFloat = CGFloat(value.x) * size.width
        let top: CGFloat = CGFloat(value.y) * size.height
        let width: CGFloat = CGFloat(value.width) * size.width
        let height: CGFloat = CGFloat(value.height) * size.height
        return CGRect(x: left, y: top, width: width, height: height)
    }
    func moved(by delta: CGSize, in size: CGSize) -> CoverRegion {
        guard size.width > 0 && size.height > 0 else { return clamped() }
        var value = clamped(); value.x += delta.width / size.width; value.y += delta.height / size.height
        return value.clamped()
    }
    func resized(_ corner: Corner, by delta: CGSize, in size: CGSize) -> CoverRegion {
        guard size.width > 0 && size.height > 0 else { return clamped() }
        let value = clamped(); let dx = delta.width / size.width; let dy = delta.height / size.height
        var left = value.x; var right = value.x + value.width
        var top = value.y; var bottom = value.y + value.height
        switch corner {
        case .topLeft: left = min(right-0.18, max(0, left+dx)); top = min(bottom-0.08, max(0, top+dy))
        case .topRight: right = max(left+0.18, min(1, right+dx)); top = min(bottom-0.08, max(0, top+dy))
        case .bottomLeft: left = min(right-0.18, max(0, left+dx)); bottom = max(top+0.08, min(1, bottom+dy))
        case .bottomRight: right = max(left+0.18, min(1, right+dx)); bottom = max(top+0.08, min(1, bottom+dy))
        }
        return CoverRegion(x: left, y: top, width: right-left, height: bottom-top).clamped()
    }
}
