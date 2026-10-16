import Foundation
import AVFoundation
import Darwin

// Reproduce the user's real file through StudyModel, including cached settings,
// cue visibility and the production local Chinese translator. No forced ja hint.
@main struct RealJapaneseLanguageChecks {
    @MainActor static func main() async throws {
        setbuf(stdout,nil)
        let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
        let folder=root.appendingPathComponent("tools/real-video-evaluation/language-mismatch-regression/repaired-cache")
        let video=URL(fileURLWithPath:CommandLine.arguments[1])
        let tools=TranscriptionTools(ffmpeg:"/opt/homebrew/bin/ffmpeg",whisper:root.appendingPathComponent("tools/whisper.cpp/static-build/bin/whisper-cli").path,model:root.appendingPathComponent("tools/asr-candidates/qwen3-asr-1.7b-8bit").path,vadModel:root.appendingPathComponent("tools/whisper.cpp/models/ggml-silero-v6.2.0.bin").path,engine:"qwen3-asr",python:root.appendingPathComponent("tools/mlx-asr-venv/bin/python").path,worker:root.appendingPathComponent("scripts/local-qwen-asr.py").path,alignmentModel:root.appendingPathComponent("tools/asr-candidates/qwen3-forced-aligner-0.6b-8bit").path,vadExecutable:root.appendingPathComponent("tools/whisper.cpp/static-build/bin/whisper-vad-speech-segments").path,secondaryModel:root.appendingPathComponent("tools/whisper.cpp/models/ggml-large-v3.bin").path)
        let model=StudyModel(cacheDirectory:folder,tools:tools,translationModel:LocalToolDefaults.qualityTranslationModel)
        model.player.isMuted=true;model.autoTranscribe=true
        model.loadVideo(video)
        guard model.language=="auto" else { throw StudyError.message("Actual playback still inherited English") }
        func until(_ name:String,_ condition:()->Bool) async throws {
            let deadline=Date().addingTimeInterval(240)
            while !condition() {
                if model.subtitlePreparationFailed || model.translationFailed { throw StudyError.message(model.error ?? model.translationError ?? model.status) }
                if Date()>deadline { throw StudyError.message("Timeout: \(name)") }
                try await Task.sleep(nanoseconds:50_000_000)
            }
        }
        try await until("all original windows") { model.completedChunks.count==3 && !model.busy }
        guard model.cues.count>=10 else { throw StudyError.message("Most original dialogue missing") }
        let hidden=model.cues.filter{$0.displayOriginal != $0.text}.count
        guard hidden*2<model.cues.count else { throw StudyError.message("Most original cues still hidden") }
        guard let cue=model.cues.first(where:{$0.text.contains("映画") && $0.displayOriginal==$0.text}) else { throw StudyError.message("Japanese original not visible") }
        model.tick((cue.start+cue.end)/2)
        guard model.activeID==cue.id,model.displayID==cue.id else { throw StudyError.message("Actual player did not show recognized cue") }
        model.select(cue,play:false);model.translateSelected()
        try await until("Chinese meaning") { model.cues.first(where:{$0.id==cue.id})?.translationSignature != nil }
        guard let result=model.cues.first(where:{$0.id==cue.id}),let chinese=result.translation,ChineseTranslationCheck.isValid(chinese),result.translationModelUsed != "unresolved-source" else { throw StudyError.message("Chinese subtitle remained unresolved") }
        let report:[String:Any] = ["source":video.path,"recognitionLanguage":model.language,"cueCount":model.cues.count,"hiddenOriginalCount":hidden,"visibleOriginalCount":model.cues.count-hidden,"completedChunks":model.completedChunks.sorted(),"cacheFile":model.makeCacheURL(video).path,"visibleJapanese":result.text,"chinese":chinese,"translationModel":result.translationModelUsed ?? "","checkedPlaybackDisplay":true,"localOnly":true,"cues":try JSONSerialization.jsonObject(with:JSONEncoder().encode(model.cues))]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:folder.deletingLastPathComponent().appendingPathComponent("actual-player-result.json"))
        model.pausePlayback();model.autoTranscribe=false
        print("PASS: actual player auto-language, \(model.cues.count-hidden)/\(model.cues.count) visible originals, Chinese: \(chinese)")
    }
}
