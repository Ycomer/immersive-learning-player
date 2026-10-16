import Foundation
import AVFoundation

@main struct PlaybackChecks {
    @MainActor static func main() async throws {
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw StudyError.message("FAIL: \(message)") }
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let video = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Samples/Japanese.mp4")
        let subtitles = folder.appendingPathComponent("overlap.srt")
        try "1\n00:00:00,000 --> 00:00:05,000\nFirst\n\n2\n00:00:01,000 --> 00:00:02,000\nOverlap\n\n3\n00:00:06,000 --> 00:00:08,000\nLast\n".write(to: subtitles, atomically: true, encoding: .utf8)
        let model = StudyModel(cacheDirectory: folder.appendingPathComponent("cache"), audioOnly: false)
        model.loadVideo(video); model.importSubtitle(subtitles)
        let first = model.cues[0].id; let overlapping = model.cues[1].id
        model.tick(1.5); try check(model.activeID == overlapping, "Most recent overlapping cue")
        model.tick(2.5); try check(model.activeID == first, "Earlier overlapping cue remains active")
        model.tick(5.5); try check(model.activeID == nil, "Gap clears highlighting")
        model.offset = 1; model.tick(0.5); try check(model.activeID == nil, "Positive offset delays cues")
        model.tick(1.5); try check(model.activeID == first, "Adjusted subtitle clock")
        model.edit(first, text: "Edited")
        model.loadVideo(video)
        try check(model.offset == 1 && model.cues[0].text == "Edited" && model.cues[0].id == first, "Reload restores offset, edits and stable IDs")
        for _ in 0..<30 {
            if model.duration > 0 { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try check(model.duration > 6 && model.duration < 8, "Loads real video duration while paused")
        model.tick(model.duration)
        model.togglePlay()
        try check(model.currentTime == 0, "Play at media end restarts video")
        model.player.pause(); model.playing = false
        model.offset = 0
        model.select(model.cues[2], play: false); model.toggleLoop()
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: model.player.currentItem)
        try await Task.sleep(nanoseconds: 100_000_000)
        try check(model.repeatSentence && model.playing && model.currentTime >= 6, "Final cue can loop when subtitle extends beyond media")
        model.player.pause()
        print("PASS: real media duration, overlapping cues, gaps, offset, cached edits and final-cue looping")
    }
}
