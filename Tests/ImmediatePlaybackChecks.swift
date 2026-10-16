import Foundation
import AVFoundation
import Darwin

@main struct ImmediatePlaybackChecks {
    @MainActor static func main() async throws {
        setbuf(stdout,nil)
        let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:folder) }
        let video=URL(fileURLWithPath:CommandLine.arguments[1])
        let tools=TranscriptionTools(ffmpeg:"/opt/homebrew/bin/ffmpeg",whisper:root.appendingPathComponent("tools/whisper.cpp/static-build/bin/whisper-cli").path,model:root.appendingPathComponent("tools/asr-candidates/qwen3-asr-1.7b-8bit").path,vadModel:root.appendingPathComponent("tools/whisper.cpp/models/ggml-silero-v6.2.0.bin").path,engine:"qwen3-asr",python:root.appendingPathComponent("tools/mlx-asr-venv/bin/python").path,worker:root.appendingPathComponent("scripts/local-qwen-asr.py").path,alignmentModel:root.appendingPathComponent("tools/asr-candidates/qwen3-forced-aligner-0.6b-8bit").path,vadExecutable:root.appendingPathComponent("tools/whisper.cpp/static-build/bin/whisper-vad-speech-segments").path,secondaryModel:root.appendingPathComponent("tools/whisper.cpp/models/ggml-large-v3.bin").path)
        let model=StudyModel(cacheDirectory:folder,tools:tools)
        model.player.isMuted=true;model.autoTranscribe=true
        let start=Date();model.loadVideo(video,autoplay:true)
        guard model.playRequested && !model.waitForSubtitles && !model.waitingForSubtitles else { throw StudyError.message("Cold file did not request immediate playback") }
        func until(_ name:String,_ condition:()->Bool) async throws {
            let end=Date().addingTimeInterval(90)
            while !condition() {
                if model.subtitlePreparationFailed { throw StudyError.message(model.error ?? model.status) }
                if Date()>end { throw StudyError.message("Timeout: \(name)") }
                try await Task.sleep(nanoseconds:30_000_000)
            }
        }
        try await until("cold play") { model.currentTime > 0.3 && model.playing }
        let firstMotion=Date().timeIntervalSince(start)
        guard model.completedChunks.isEmpty && model.busy else { throw StudyError.message("Video only started after original subtitles finished") }
        model.pausePlayback()
        try await until("background original") { model.completedChunks.contains(0) }
        guard !model.playRequested && model.player.rate==0 && !model.cues.isEmpty else { throw StudyError.message("Background subtitles resumed manual pause or were not generated") }
        model.autoTranscribe=false
        let count=model.cues.count
        model.loadVideo(video,autoplay:true)
        guard model.cues.count==count && !model.waitingForSubtitles else { throw StudyError.message("Cached open waited or discarded original subtitles") }
        try await until("cached play") { model.currentTime > 0.15 && model.playing }
        model.autoTranscribe=true
        model.seek(42)
        try await until("seek into unprocessed window") { model.currentTime>42.15 && model.playing }
        guard !model.waitingForSubtitles && !model.completedChunks.contains(1) else { throw StudyError.message("Unprocessed seek blocked video") }
        model.pausePlayback();model.autoTranscribe=false
        model.loadVideo(video,autoplay:true);model.pausePlayback()
        try await until("media metadata") { model.duration>0 }
        try await Task.sleep(nanoseconds:150_000_000)
        guard !model.playRequested && model.player.rate==0 else { throw StudyError.message("Late media readiness undid manual pause") }
        let report:[String:Any] = ["firstMotionSeconds":firstMotion,"coldFilePlayedBeforeASRCompleted":true,"backgroundOriginalCues":count,"cachedOpenPlayedImmediately":true,"seekDidNotWait":true,"manualPausePreserved":true,"localOnly":true]
        let target=root.appendingPathComponent("tools/real-video-evaluation/immediate-playback-result.json")
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:target)
        print("PASS: cold video moved in \(firstMotion)s before subtitles; background ASR, cache replay, unprocessed seek and manual pause")
    }
}
