import Foundation
import AVFoundation
import Darwin

final class DelayedSubtitleProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var plan: [(Double, String)] = []
    private var work: DispatchWorkItem?
    static func configure(_ items: [(Double, String)]) { lock.lock(); plan = items; lock.unlock() }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "127.0.0.1" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let next = Self.plan.isEmpty ? nil : Self.plan.removeFirst(); Self.lock.unlock()
        guard let next else { client?.urlProtocol(self, didFailWithError: StudyError.message("Unexpected request")); return }
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.work?.isCancelled == false else { return }
            let data = try! JSONSerialization.data(withJSONObject: ["message": ["content": next.1]])
            self.client?.urlProtocol(self, didReceive: HTTPURLResponse(url: self.request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data); self.client?.urlProtocolDidFinishLoading(self)
        }
        work = item; DispatchQueue.global().asyncAfter(deadline: .now()+next.0, execute: item)
    }
    override func stopLoading() { work?.cancel() }
}

@main struct PlaybackBufferChecks {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        func check(_ value: Bool, _ message: String) throws { if !value { throw StudyError.message(message) } }
        let cues = [SubtitleCue(start: 1, end: 2, text: "first", translation: "第一句"), SubtitleCue(start: 3, end: 5, text: "second")]
        func readiness(_ time: Double, _ done: Set<Int>, _ originals: Bool = true, _ translation: Bool = true) -> SubtitleWaitReason? {
            SubtitlePlaybackBuffer.reason(time: time, duration: 8, lookahead: 0.4, span: 2, completed: done, needsOriginal: originals, cues: cues, maximumEnds: [2,5], needsTranslation: translation)
        }
        try check(readiness(0, []) == .original, "Cold audio starts without preparation")
        try check(readiness(0, [0]) == nil, "Prepared silence needlessly blocks")
        try check(readiness(1.7, [0]) == .original, "Upcoming unprocessed chunk not buffered")
        try check(readiness(2.7, [0,1]) == .translation, "Upcoming dialogue starts without Chinese")
        try check(readiness(2.1, [0,1]) == nil, "Gap needlessly requires future translation")
        try check(readiness(3, [], false, false) == nil, "Disabled processing cannot wait forever")
        try check(readiness(8, [3]) == nil, "End-of-video requests nonexistent chunk")
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [DelayedSubtitleProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let video = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Samples/Japanese.mp4")
        func model(_ name: String, waiting: Bool = true) async throws -> StudyModel {
            let value = StudyModel(cacheDirectory: folder.appendingPathComponent(name), audioOnly: false, translationModel: "fixture", translationSession: session)
            try check(!value.waitForSubtitles, "New player defaults to waiting")
            value.waitForSubtitles = waiting
            value.player.isMuted = true; value.loadVideo(video)
            for _ in 0..<100 { if value.duration > 0 { break }; try await Task.sleep(nanoseconds: 20_000_000) }
            try check(value.duration > 0, "Sample video not ready")
            value.cues = [SubtitleCue(start: 0, end: 6, text: "これはテストです。")]
            value.tick(0); return value
        }
        func until(_ condition: () -> Bool) async throws {
            for _ in 0..<200 { if condition() { return }; try await Task.sleep(nanoseconds: 20_000_000) }
            throw StudyError.message("Timed out waiting for playback state")
        }
        let translated = "{\"translation\":\"这是测试。\",\"warning\":\"\",\"terms\":[{\"source\":\"テスト\",\"target\":\"测试\"}]}"
        let notes = "{\"annotations\":[]}"
        let immediate = try await model("immediate", waiting: false)
        DelayedSubtitleProtocol.configure([(2.0, translated), (0.1, notes)])
        immediate.autoTranslate = true; immediate.requestPlay()
        try check(!immediate.waitingForSubtitles && immediate.player.rate > 0, "Untranslated cue blocked immediate play")
        // AVPlayer startup varies with codec initialization and the host. Assert
        // that video advances before translation, rather than within 180 ms.
        try await until { immediate.currentTime > 0.05 }
        try check(immediate.currentTime > 0.05 && immediate.cues[0].translation == nil, "Video waited for the delayed Chinese translation")
        immediate.seek(2)
        try await until { immediate.playing && immediate.currentTime >= 2 }
        try check(!immediate.waitingForSubtitles, "Seek re-enabled subtitle waiting")
        immediate.pausePlayback(); immediate.autoTranslate = false
        let first = try await model("first")
        DelayedSubtitleProtocol.configure([(0.35, translated), (1.2, notes)])
        first.autoTranslate = true; first.requestPlay()
        try check(first.waitingForSubtitles && first.playRequested && first.player.rate == 0, "First play did not hold audio")
        try await Task.sleep(nanoseconds: 120_000_000)
        try check(first.currentTime < 0.05, "Audio advanced while Chinese was still preparing")
        try await until { !first.waitingForSubtitles && first.playing }
        try check(first.translating, "Playback waited for learning annotations")
        first.pausePlayback()
        try await until { !first.translating }
        try check(!first.playRequested && first.player.rate == 0, "Finishing notes resumed manual pause")
        let cancelled = try await model("cancelled")
        DelayedSubtitleProtocol.configure([(0.35, translated), (0.1, notes)])
        cancelled.autoTranslate = true; cancelled.requestPlay(); cancelled.togglePlay()
        try await until { !cancelled.translating }
        try check(!cancelled.waitingForSubtitles && !cancelled.playRequested && cancelled.player.rate == 0, "Cancel wait later auto-resumed")
        let seeking = try await model("seeking")
        seeking.cues = [SubtitleCue(start: 0, end: 2, text: "最初です。"), SubtitleCue(start: 3, end: 6, text: "次です。")]
        seeking.tick(0)
        DelayedSubtitleProtocol.configure([(0.1, translated), (0.15, notes), (0.6, translated), (0.1, notes)])
        seeking.autoTranslate = true; seeking.requestPlay()
        try await until { !seeking.waitingForSubtitles && seeking.playing }
        seeking.seek(3); seeking.seek(4)
        try check(seeking.waitingForSubtitles && seeking.player.rate == 0, "Seek into untranslated speech did not pause")
        try await Task.sleep(nanoseconds: 150_000_000)
        try check(abs(seeking.currentTime-4) < 0.1, "Old playback tick or seek completion changed the new target")
        try await until { !seeking.waitingForSubtitles && seeking.playing }
        try check(seeking.currentTime >= 3.9, "Playback resumed at obsolete seek position")
        seeking.pausePlayback(); seeking.autoTranslate = false
        let overlap = try await model("overlap")
        overlap.cues = [SubtitleCue(start: 0, end: 6, text: "長い字幕です。"), SubtitleCue(start: 1, end: 6, text: "重なる字幕です。", translation: "重叠字幕。")]
        overlap.tick(2)
        overlap.requestPlay()
        DelayedSubtitleProtocol.configure([(0.15, translated), (0.1, notes)])
        overlap.autoTranslate = true
        try await until { !overlap.waitingForSubtitles && overlap.playing && overlap.cues[0].translation != nil }
        overlap.pausePlayback(); overlap.autoTranslate = false
        let switched = try await model("switched")
        DelayedSubtitleProtocol.configure([(0.35, translated), (0.1, notes)])
        switched.autoTranslate = true; switched.requestPlay()
        switched.loadVideo(video)
        try await Task.sleep(nanoseconds: 500_000_000)
        try check(!switched.playRequested && switched.player.rate == 0, "Old job resumed a newly opened video")
        let bypass = try await model("bypass")
        DelayedSubtitleProtocol.configure([(0.5, translated), (0.1, notes)])
        bypass.autoTranslate = true; bypass.requestPlay(); bypass.waitForSubtitles = false
        try await until { bypass.playing }
        try check(!bypass.waitingForSubtitles, "Explicit bypass still waits")
        bypass.pausePlayback(); bypass.autoTranslate = false
        print("PASS: ahead-of-speech buffering, silence, delayed first translation, early resume before notes, cancel, successive seeks, overlaps, new-video isolation and bypass")
    }
}
