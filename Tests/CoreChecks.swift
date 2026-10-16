import Foundation

final class MemoryDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Any]
    init(values: [String: Any] = [:]) {
        self.values = values
        super.init(suiteName: "SubtitleStudy.MemoryChecks")!
    }
    override func string(forKey key: String) -> String? { values[key] as? String }
    override func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
}

@main struct CoreChecks {
    static func main() async throws {
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw StudyError.message("FAIL: \(message)") }
        }
        let playback = MemoryDefaults(values: ["waitForSubtitles": true])
        LocalToolDefaults.migrateImmediatePlayback(defaults: playback)
        try check(!playback.bool(forKey: "waitForSubtitles"), "Existing installation switches to immediate playback")
        playback.set(true, forKey: "waitForSubtitles")
        LocalToolDefaults.migrateImmediatePlayback(defaults: playback)
        try check(playback.bool(forKey: "waitForSubtitles"), "Later explicit learning-mode choice is preserved")
        let fresh = MemoryDefaults()
        LocalToolDefaults.migrateTranslationModel(in: fresh)
        try check(fresh.string(forKey: "ollamaModel") == "qwen3:4b-instruct", "New install uses Qwen3 Instruct")
        let old = MemoryDefaults(values: ["ollamaModel": "qwen2.5:1.5b"])
        LocalToolDefaults.migrateTranslationModel(in: old)
        try check(old.string(forKey: "ollamaModel") == "qwen3:4b-instruct", "Old default upgrades")
        let small = MemoryDefaults(values: ["ollamaModel": "qwen3:1.7b", "qwen3TranslationDefaultV1": true])
        LocalToolDefaults.migrateTranslationModel(in: small)
        try check(small.string(forKey: "ollamaModel") == "qwen3:4b-instruct", "Existing 1.7B default upgrades")
        small.set("qwen3:1.7b", forKey: "ollamaModel")
        LocalToolDefaults.migrateTranslationModel(in: small)
        try check(small.string(forKey: "ollamaModel") == "qwen3:1.7b", "Explicit later choice is preserved")
        old.set("qwen2.5:1.5b", forKey: "ollamaModel")
        LocalToolDefaults.migrateTranslationModel(in: old)
        try check(old.string(forKey: "ollamaModel") == "qwen2.5:1.5b", "Migration runs once and permits later override")
        let custom = MemoryDefaults(values: ["ollamaModel": "qwen3:4b"])
        LocalToolDefaults.migrateTranslationModel(in: custom)
        try check(custom.string(forKey: "ollamaModel") == "qwen3:4b", "Preserves custom model")
        let source = "1\r\n00:00:01,250 --> 00:00:03,500\r\n今日はいい天気ですね。\r\n二行目\r\n\r\n2\r\n00:00:04,000 --> 00:00:05,000\r\nHello\r\n"
        let cues = try SubtitleCodec.parse(source)
        try check(cues.count == 2 && cues[0].start == 1.25 && cues[0].end == 3.5, "SRT timing and count")
        try check(cues[0].text == "今日はいい天気ですね。\n二行目", "Unicode and multiline")
        let vtt = try SubtitleCodec.parse("WEBVTT\n\n00:01.000 --> 00:02.000 align:start\n<i>Hello</i>\n")
        try check(vtt[0].start == 1 && vtt[0].text == "Hello", "VTT settings and markup")
        let roundTrip = try SubtitleCodec.parse(SubtitleCodec.srt(cues))
        try check(roundTrip.map(\.text) == cues.map(\.text) && roundTrip.map(\.start) == cues.map(\.start), "SRT round trip")
        let decoded = try JSONDecoder().decode(SubtitleDocument.self, from: JSONEncoder().encode(SubtitleDocument(source: "test", cues: cues)))
        try check(decoded.cues == cues, "Cache preserves stable IDs")
        do { _ = try SubtitleCodec.parse("1\n00:00:03 --> 00:00:01\nBad\n"); throw StudyError.message("FAIL: malformed timestamp accepted") }
        catch StudyError.message(let message) { try check(!message.hasPrefix("FAIL"), message) }
        let process = ProcessRunner()
        try await process.run(executable: "/usr/bin/true", arguments: [], log: { _ in })
        do { try await ProcessRunner().run(executable: "/usr/bin/false", arguments: [], log: { _ in }); throw StudyError.message("FAIL: process failure accepted") }
        catch StudyError.message(let message) { try check(!message.hasPrefix("FAIL"), message) }
        let cancellation = ProcessRunner()
        let started = Date()
        let task = Task { try await cancellation.run(executable: "/bin/sleep", arguments: ["10"], log: { _ in }) }
        try await Task.sleep(nanoseconds: 100_000_000)
        cancellation.cancel()
        do { try await task.value; throw StudyError.message("FAIL: cancellation accepted") } catch is CancellationError { }
        try check(Date().timeIntervalSince(started) < 3, "Cancellation stops subprocess promptly")
        let oddPath = "/tmp/study-path-空 格-'\(UUID().uuidString).txt"
        try Data("ok".utf8).write(to: URL(fileURLWithPath: oddPath))
        defer { try? FileManager.default.removeItem(atPath: oddPath) }
        try await ProcessRunner().run(executable: "/bin/test", arguments: ["-f", oddPath], log: { _ in })
        print("PASS: Qwen3 default migration, subtitle formats, timing, Unicode, cache round trip, subprocess errors and cancellation")
    }
}
