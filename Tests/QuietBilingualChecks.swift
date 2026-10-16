import Foundation
import Darwin

// Actual recovered audio output -> production cue parser -> local translator.
@main struct QuietBilingualChecks {
    static func main() async throws {
        setbuf(stdout,nil)
        let base = URL(fileURLWithPath: "tools/real-video-evaluation/missing-speech-regression")
        let data = try Data(contentsOf: base.appendingPathComponent("production-quiet-final.json"))
        let documents = try JSONSerialization.jsonObject(with:data) as! [[String:Any]]
        let first = documents.first!
        let cues = try QwenAlignedTranscript.parse(JSONSerialization.data(withJSONObject:first),ownedStart:0,ownedEnd:28)
        guard let index = cues.firstIndex(where:{$0.text.contains("でき")}) else { throw StudyError.message("Recovered first utterance did not reach subtitle cues") }
        let cue = cues[index]
        guard cue.start < 6, cue.end > cue.start, cue.displayOriginal == cue.text else { throw StudyError.message("Recovered subtitle not visible or misplaced") }
        let result = try await OllamaService.translateStudy(text:cue.text,before:Array(cues.prefix(index).suffix(2)).map(\.text),after:Array(cues.dropFirst(index+1).prefix(2)).map(\.text),model:LocalToolDefaults.qualityTranslationModel,endpoint:"http://127.0.0.1:11434",language:"日语",sourceWarning:cue.recognitionWarning,sourceConfidence:cue.recognitionConfidence)
        guard ChineseTranslationCheck.isValid(result.translation),result.modelUsed != "unresolved-source" else { throw StudyError.message("Recovered subtitle failed local Chinese translation") }
        let row:[String:Any] = ["source":cue.text,"displayOriginal":cue.displayOriginal,"start":cue.start,"end":cue.end,"translation":result.translation,"model":result.modelUsed ?? LocalToolDefaults.qualityTranslationModel,"localEndpoint":"http://127.0.0.1:11434","result":"passed","limitation":"Pipeline visibility check, not proof that every recognized Japanese word or Chinese meaning is correct"]
        try JSONSerialization.data(withJSONObject:row,options:[.prettyPrinted,.sortedKeys]).write(to:base.appendingPathComponent("bilingual-visibility.json"))
        print("PASS: recovered original -> timestamped cue -> local Chinese translation: \(cue.text) -> \(result.translation)")
    }
}
