import Foundation
import AVFoundation

@main struct RecognitionQualityChecks {
    @MainActor static func main() async throws {
        func check(_ ok: Bool, _ message: String) throws { if !ok { throw StudyError.message(message) } }
        let suite = "SpeechToolMigration-"+UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("/old/SubtitleStudy.app/Contents/Resources/Tools/whisper-cli", forKey: "whisperPath")
        LocalToolDefaults.migrateSpeechTools(defaults: defaults, bundledWhisper: "/new/whisper-cli")
        try check(defaults.string(forKey: "whisperPath") == "/new/whisper-cli", "Old bundled CLI path blocks voice output")
        defaults.removePersistentDomain(forName: suite); defaults.set("/custom/whisper-cli", forKey: "whisperPath")
        LocalToolDefaults.migrateSpeechTools(defaults: defaults, bundledWhisper: "/new/whisper-cli")
        try check(defaults.string(forKey: "whisperPath") == "/custom/whisper-cli", "Explicit custom CLI overwritten")
        defaults.set("/old/ggml-small.bin", forKey: "whisperModel")
        LocalToolDefaults.migrateAccurateRecognitionModel(defaults: defaults, largeModel: "/new/ggml-large-v3.bin")
        try check(defaults.string(forKey: "whisperModel") == "/new/ggml-large-v3.bin", "Accuracy upgrade kept old default")
        defaults.set("/chosen/ggml-small.bin", forKey: "whisperModel")
        LocalToolDefaults.migrateAccurateRecognitionModel(defaults: defaults, largeModel: "/new/ggml-large-v3.bin")
        try check(defaults.string(forKey: "whisperModel") == "/chosen/ggml-small.bin", "Later explicit fast model choice overwritten")
        func token(_ text: String, _ from: Int, _ to: Int, _ p: Double = 0.9) -> [String: Any] {
            ["text": text, "p": p, "offsets": ["from": from, "to": to]]
        }
        func json(_ tokens: [[String: Any]], voices: [[Int]], raw: String = "fixture", noSpeech: Double = 0) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["subtitle_study_json_revision": 1, "vad_segments": voices.map { ["offsets": ["from": $0[0], "to": $0[1]]] }, "transcription": [["text": raw, "offsets": ["from": 0, "to": 8000], "tokens": tokens, "no_speech_prob": noSpeech]]])
        }
        let tokens = [token("[_BEG_]", 0, 0), token("今日は", 100, 500), token("いい天気", 500, 1300), token("。", 1300, 1400), token("私は", 2400, 2700), token("勉強しています。", 2700, 4000), token("[_TT_500]", 8000, 8000)]
        let split = try WhisperTranscript.parse(json(tokens, voices: [[0, 4500]]), ownedStart: 0, ownedEnd: 5)
        try check(split.count == 2 && split[0].text == "今日はいい天気。" && split[1].start == 2.4, "Sentence text or token time changed")
        let quiet = try WhisperTranscript.parse(json([token("小さい声です。", 100, 1500, 0.3)], voices: [[0, 1600]]), ownedStart: 0, ownedEnd: 2)
        try check(quiet.count == 1 && quiet[0].recognitionWarning != nil, "Weak quiet dialogue was dropped without explanation")
        let missed = try json([token("最初です。", 100, 1500)], voices: [[0, 1700], [3000, 4500]])
        let firstOnly = try WhisperTranscript.parse(missed, ownedStart: 0, ownedEnd: 5)
        try check(try WhisperTranscript.missingSpeechRanges(missed, cues: firstOnly, ownedStart: 0, ownedEnd: 5) == [.init(start: 3, end: 4.5)], "Missing second voice block not selected for recovery")
        try check(try WhisperTranscript.missingSpeechRanges(missed, cues: [], ownedStart: 0, ownedEnd: 5).isEmpty, "Recovery forces speech from wholly rejected audio")
        try check(try WhisperTranscript.parse(json(tokens, voices: []), ownedStart: 0, ownedEnd: 8).isEmpty, "No-voice window invented subtitles")
        let outside = try WhisperTranscript.parse(json([token("noise words", 6000, 7000)], voices: [[0, 1000]]), ownedStart: 0, ownedEnd: 8)
        try check(outside.isEmpty, "Text outside voice survived")
        let music = try WhisperTranscript.parse(json([token("[Music]", 100, 1000)], voices: [[0, 1500]], raw: "[Music]"), ownedStart: 0, ownedEnd: 2)
        try check(music.isEmpty, "Sound description treated as dialogue")
        let atBoundary = try json([token("前半", 0, 1000), token("後半", 1000, 2000)], voices: [[0, 2100]])
        let left = try WhisperTranscript.parse(atBoundary, ownedStart: 0, ownedEnd: 1)
        let right = try WhisperTranscript.parse(atBoundary, ownedStart: 1, ownedEnd: 2)
        try check(left.map(\.text) == ["前半"] && right.map(\.text) == ["後半"], "Overlap duplicates entire sentences")
        let tail = try json([token("聞いて", 1500, 1950), token("みましょう。", 2000, 2010)], voices: [[0, 2020]])
        let final = try WhisperTranscript.parse(tail, ownedStart: 0, ownedEnd: 2, allowEndPadding: true)
        try check(final.map(\.text) == ["聞いてみましょう。"] && final[0].end == 2, "Final timestamp rounding dropped words")
        let merged = WhisperTranscript.mergeFragments([SubtitleCue(start: 0, end: 0.4, text: "今日は"), SubtitleCue(start: 0.5, end: 2, text: "いい天気です。")])
        try check(merged.count == 1 && merged[0].text == "今日はいい天気です。", "Short fragments still flash separately")
        let ordinary = try StudyTranslation(translation: "再听一次。", annotations: [StudyAnnotation(expression: "もう一度", kind: "惯用语", meaning: "再一次", usage: "重复")], warning: "").validated(for: "もう一度聞いてみましょう。")
        try check(ordinary.annotations.isEmpty, "Ordinary repetition word mislabeled as idiom")
        let captions = [SubtitleCue(start: 1, end: 1.4, text: "はい。"), SubtitleCue(start: 3, end: 4, text: "次です。")]
        try check(SubtitlePresentation.heldIndex(time: 1.5, cues: captions, minimum: 2.5, speed: 1, duration: 8) == 0, "Short caption disappears immediately")
        try check(SubtitlePresentation.heldIndex(time: 2.7, cues: captions, minimum: 2.5, speed: 1, duration: 8) == nil, "Caption lingers through long silence")
        try check(SubtitlePresentation.heldIndex(time: 3, cues: captions, minimum: 4, speed: 1, duration: 8) == nil, "Previous caption covers new dialogue")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = StudyModel(cacheDirectory: folder)
        model.loadVideo(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Samples/Japanese.mp4"))
        model.cues = captions; model.tick(1.2); model.pauseAfterSentence = true; model.requestPlay(); model.tick(1.5)
        try check(!model.playRequested && model.displayID == captions[0].id && model.activeID == nil, "Reading pause loses caption or shifts speech clock")
        model.tick(2); try check(model.displayID == captions[0].id, "Reading pause did not keep the sentence")
        model.requestPlay(); model.tick(2); try check(model.playRequested, "Continue immediately pauses again")
        model.seek(3.1); try check(model.displayID == captions[1].id, "Seek retained old reading sentence")
        model.pausePlayback()
        var uncertain = quiet[0]; uncertain.translation = "小声说话。"; uncertain.plainMeaning = "说明说话声音很小。"
        let restored = try JSONDecoder().decode(SubtitleCue.self, from: JSONEncoder().encode(uncertain))
        try check(restored == uncertain, "Recognition evidence or meaning not cached")
        model.cues = [uncertain]; model.edit(uncertain.id, text: "修正済み。")
        try check(model.cues[0].recognitionWarning == nil && model.cues[0].plainMeaning == nil, "Manual correction retains obsolete warning")
        let aligned = Data("{\"text\":\"前半。後半。\",\"words\":[{\"text\":\"前半。\",\"start\":0,\"end\":0.9},{\"text\":\"後半。\",\"start\":1.1,\"end\":1.9}]}".utf8)
        let qwenLeft = try QwenAlignedTranscript.parse(aligned, ownedStart: 0, ownedEnd: 1)
        let qwenRight = try QwenAlignedTranscript.parse(aligned, ownedStart: 1, ownedEnd: 2)
        try check(qwenLeft.map(\.text) == ["前半。"] && qwenRight.map(\.text) == ["後半。"], "Aligned Qwen words duplicated across windows")
        let boundaryLeft = Data("{\"text\":\"it \",\"words\":[{\"text\":\"it \",\"start\":23.94,\"end\":24.10}]}".utf8)
        let boundaryRight = Data("{\"text\":\"it \",\"words\":[{\"text\":\"it \",\"start\":3.94,\"end\":4.02}]}".utf8)
        let ownedLeft = try QwenAlignedTranscript.parse(boundaryLeft, ownedStart: 0, ownedEnd: 24)
        let ownedRight = try QwenAlignedTranscript.parse(boundaryRight, ownedStart: 4, ownedEnd: 28)
        try check(ownedLeft.map(\.text) == ["it"] && ownedRight.isEmpty, "Duration drift dropped a short English word from both overlapping windows")
        let fragment = SubtitleCue(start: 23.38, end: 24, text: "Let's call it", translation: "旧片段译文", translationSignature: "old", translationModelUsed: "old")
        let joined = QwenAlignedTranscript.mergeBoundary([fragment, SubtitleCue(start: 24.1, end: 24.58, text: "a day.")], at: 24)
        try check(joined.count == 1 && joined[0].text == "Let's call it a day." && joined[0].id == fragment.id && joined[0].end == 24.58 && joined[0].translation == nil && joined[0].translationSignature == nil && joined[0].translationModelUsed == nil, "Boundary sentence was split or retained a fragment translation")
        var finished = fragment; finished.text = "Stop."
        try check(QwenAlignedTranscript.mergeBoundary([finished, SubtitleCue(start: 24.1,end: 25,text: "New sentence.")], at: 24).count == 2, "Boundary merge combined distinct finished utterances")
        try check(QwenAlignedTranscript.mergeBoundary([fragment, SubtitleCue(start: 25,end: 26,text: "a day.")], at: 24).count == 2, "Boundary merge crossed a speech pause")
        let clippedAcknowledgment = SubtitleCue(start: 23.99, end: 24, text: "うん。")
        let deduplicated = QwenAlignedTranscript.mergeBoundary([clippedAcknowledgment, SubtitleCue(start: 24,end: 24.4,text: "うん。")], at: 24)
        try check(deduplicated.count == 1 && deduplicated[0].text == "うん。" && deduplicated[0].end == 24.4, "Millisecond onset drift duplicated a short Japanese utterance")
        try check(QwenAlignedTranscript.mergeBoundary([SubtitleCue(start: 23.5,end: 24,text: "うん。"), SubtitleCue(start: 24,end: 24.4,text: "うん。")], at: 24).count == 2, "Real repeated Japanese utterances were deduplicated")
        let primaryQuestion = SubtitleCue(start: 3,end: 5,text: "明日の会議来られそう。")
        let restoredQuestion = QuestionPunctuation.reconcile([primaryQuestion], with: [SubtitleCue(start: 3.1,end: 4.9,text: "明日の会議、来られそう？")])
        try check(restoredQuestion[0].text == "明日の会議来られそう？" && restoredQuestion[0].id == primaryQuestion.id && restoredQuestion[0].start == primaryQuestion.start, "Question restoration changed source words or clock")
        try check(QuestionPunctuation.reconcile([primaryQuestion], with: [SubtitleCue(start: 10,end: 12,text: "明日の会議来られそう？"), SubtitleCue(start: 3,end: 5,text: "別の会議来られそう？")]) == [primaryQuestion], "Different words or another turn changed question meaning")
        let longEnglish = "And so I did the only thing I could: I wrote ninety pages over seventy-two hours, pulling not one but two all-nighters."
        let englishWords = longEnglish.split(separator: " ").enumerated().map { i,word in
            ["text":String(word)+(i == longEnglish.split(separator: " ").count-1 ? "" : " "),"start":Double(i)*0.2,"end":Double(i+1)*0.2] as [String:Any]
        }
        let sentenceData = try JSONSerialization.data(withJSONObject:["text":longEnglish,"words":englishWords])
        let sentenceCues = try QwenAlignedTranscript.parse(sentenceData,ownedStart:0,ownedEnd:10)
        try check(sentenceCues.count == 1 && sentenceCues[0].text == longEnglish, "Long English idiom still translated as arbitrary 42-character fragments")
        let affirmative = SubtitleCue(start:5,end:8,text:"うん、少し驚いたよ。")
        let negative = SubtitleCue(start:5.1,end:8.1,text:"ううん、少し驚いたよ。",recognitionConfidence:0.8)
        let reviewed = AcousticTranscriptReview.reconcile([affirmative],with:[negative])
        try check(reviewed[0].text.hasPrefix("ううん") && reviewed[0].id == affirmative.id && reviewed[0].start == affirmative.start && reviewed[0].recognitionWarning != nil, "Near-identical negative audio review failed or lost timing/uncertainty")
        try check(AcousticTranscriptReview.reconcile([affirmative],with:[SubtitleCue(start:5,end:8,text:"ううん、別の話だよ。",recognitionConfidence:0.9)]) == [affirmative], "Different sentence changed an affirmative answer")
        try check(SentenceReadiness.needsContinuation(fragment,span:24,duration:60,completed:[0]), "Cut sentence translated before its next audio window")
        try check(!SentenceReadiness.needsContinuation(fragment,span:24,duration:60,completed:[0,1]), "Complete following window left translation stuck")
        try check(!SentenceReadiness.needsContinuation(finished,span:24,duration:60,completed:[0]), "Finished sentence incorrectly waits for another window")
        let nearBoundary = SubtitleCue(start:23.37,end:23.93,text:"Let's call")
        let nearJoined = QwenAlignedTranscript.mergeBoundary([nearBoundary,SubtitleCue(start:24.01,end:24.57,text:"it a day.")],at:24)
        try check(nearJoined.count == 1 && nearJoined[0].text == "Let's call it a day." && SentenceReadiness.needsContinuation(nearBoundary,span:24,duration:60,completed:[0]), "Real aligner rounding before a window edge split an idiom or translated it before continuation")
        let weakContinuation = SubtitleCue(start:24.01,end:24.57,text:"it a day.",recognitionConfidence:0.2,recognitionWarning:"后半句识别不确定")
        let uncertainJoined = QwenAlignedTranscript.mergeBoundary([nearBoundary,weakContinuation],at:24)
        try check(uncertainJoined[0].recognitionConfidence == 0.2 && uncertainJoined[0].recognitionWarning != nil,"Joining a sentence dropped the quiet continuation's uncertainty")
        let unreliable = SubtitleCue(start:1,end:2,text:"未经确认的候选原文",recognitionConfidence:0.2,recognitionWarning:"识别不一致")
        try check(unreliable.displayOriginal != unreliable.text && unreliable.text == "未经确认的候选原文", "Unconfirmed transcript is taught as reliable text or lost from review/edit data")
        for malformed in ["{\"text\":\"漏句\",\"words\":[]}", "{\"text\":\"错误\",\"words\":[{\"text\":\"错误\",\"start\":2,\"end\":1}]}"] {
            do { _ = try QwenAlignedTranscript.parse(Data(malformed.utf8), ownedStart: 0, ownedEnd: 3); throw StudyError.message("FAIL: broken Qwen alignment accepted") }
            catch StudyError.message(let message) { try check(!message.hasPrefix("FAIL:"), message) }
        }
        print("PASS: voice-only subtitles, quiet uncertainty, sentence timing, Whisper/Qwen overlap ownership, invalid alignment rejection, fragment merging, reading hold/pause and evidence cache")
    }
}
