import Foundation

@main struct ChunkChecks {
    @MainActor static func main() async throws {
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw StudyError.message("FAIL: \(message)") }
        }
        let bounds = ChunkTimeline.window(index: 2, span: 12, duration: 80)
        try check(bounds.start == 24 && bounds.end == 36 && bounds.audioStart == 22.5, "Seek window with overlap")
        let projected = ChunkTimeline.project([SubtitleCue(start: 0, end: 4, text: "boundary"), SubtitleCue(start: 10, end: 16, text: "tail")], audioStart: bounds.audioStart, start: bounds.start, end: bounds.end)
        try check(projected[0].start == 24 && projected[0].end == 26.5 && projected[1].end == 36, "Absolute timestamps and boundary clipping")
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let tools = TranscriptionTools(ffmpeg: "/opt/homebrew/bin/ffmpeg", whisper: root.appendingPathComponent("tools/whisper.cpp/static-build/bin/whisper-cli").path, model: root.appendingPathComponent("tools/whisper.cpp/models/ggml-tiny.bin").path)
        let model = StudyModel(cacheDirectory: folder, tools: tools, chunkSeconds: 3)
        model.waitForSubtitles = true
        model.player.isMuted = true
        model.autoTranscribe = true; model.autoTranslate = true
        let video = root.appendingPathComponent("Samples/English.mp4")
        model.loadVideo(video)
        model.requestPlay()
        try check(model.waitingForSubtitles && model.player.rate == 0, "Cold playback waits for audio recognition")
        var incremental = false
        var resumedWithChinese = false
        for _ in 0..<600 {
            if model.subtitlePreparationFailed || model.translationFailed { throw StudyError.message(model.status + "\n" + model.taskLog) }
            if model.completedChunks.contains(0) && model.busy && !model.cues.isEmpty { incremental = true }
            if model.playing && model.cues.contains(where: { $0.start < 3 && $0.translation != nil }) { resumedWithChinese = true }
            if model.duration > 0 && model.completedChunks.count == min(3, Int(ceil(model.duration / 3))) && !model.busy && !model.translating { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try check(incremental, "First chunk publishes before remaining ASR finishes")
        try check(resumedWithChinese, "Cold playback resumes after real ASR and Chinese translation")
        model.pausePlayback()
        let expected = Set(0..<min(3, Int(ceil(model.duration / 3))))
        try check(model.completedChunks == expected, "Completed chunk coverage")
        try check(model.cues.contains { $0.start >= 3 }, "Later chunk uses global video clock")
        try check(model.cues.filter { $0.start < 3 }.allSatisfy { $0.translation != nil }, "First chunk translated while later chunks process")
        for cue in model.cues { try check(cue.start >= 0 && cue.end <= model.duration && cue.end > cue.start, "Valid clipped intervals") }
        let firstID = model.cues[0].id
        model.edit(firstID, text: "My edited sentence")
        model.autoTranslate = false
        model.loadVideo(video)
        try check(model.completedChunks == expected && model.cues.contains { $0.id == firstID && $0.text == "My edited sentence" }, "Resume preserves edited IDs and completed windows")
        model.player.pause()
        let jumping = StudyModel(cacheDirectory: folder.appendingPathComponent("jump"), tools: tools, chunkSeconds: 2)
        jumping.autoTranscribe = true; jumping.loadVideo(video)
        for _ in 0..<100 { if jumping.busy { break }; try await Task.sleep(nanoseconds: 50_000_000) }
        jumping.seek(4)
        for _ in 0..<300 {
            if jumping.subtitlePreparationFailed { throw StudyError.message(jumping.status) }
            if !jumping.busy && jumping.completedChunks.contains(2) { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try check(jumping.completedChunks == Set([2]), "Seek prioritizes distant chunk without publishing cancelled work")
        jumping.cancelWork()
        let done = jumping.completedChunks
        try await Task.sleep(nanoseconds: 200_000_000)
        try check(!jumping.busy && jumping.completedChunks == done, "Cancel does not restart or discard completed windows")
        jumping.loadVideo(video)
        try check(jumping.completedChunks == Set([2]), "Partial cache coverage survives reopen")
        for _ in 0..<300 {
            if jumping.subtitlePreparationFailed { throw StudyError.message(jumping.status) }
            if !jumping.busy && jumping.completedChunks == Set([0,1,2]) { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try check(jumping.completedChunks == Set([0,1,2]), "Resume fills only missing windows")
        print("PASS: real incremental Whisper, early publication and translation, global timing, clipping, partial cache and edits")
    }
}
