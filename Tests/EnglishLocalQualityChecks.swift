import Foundation
import AVFoundation
import Darwin

// Offline integration test using the player's production audio extraction,
// Qwen ASR/alignment, subtitle cache, playback gate and local translator.
// Reference text is loaded only after inference for the separate scorer.
@main struct EnglishLocalQualityChecks {
    struct Manifest: Decodable { var cases: [Clip] }
    struct Clip: Decodable { var id: String; var video: String; var duration: Double }

    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let base = root.appendingPathComponent("tools/english-evaluation")
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: base.appendingPathComponent("manifest.json")))
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cache) }
        let tools = TranscriptionTools(ffmpeg: "/opt/homebrew/bin/ffmpeg",
            whisper: root.appendingPathComponent("tools/whisper.cpp/static-build/bin/whisper-cli").path,
            model: root.appendingPathComponent("tools/asr-candidates/qwen3-asr-1.7b-8bit").path,
            vadModel: root.appendingPathComponent("tools/whisper.cpp/models/ggml-silero-v6.2.0.bin").path,
            engine: "qwen3-asr", python: root.appendingPathComponent("tools/mlx-asr-venv/bin/python").path,
            worker: root.appendingPathComponent("scripts/local-qwen-asr.py").path,
            alignmentModel: root.appendingPathComponent("tools/asr-candidates/qwen3-forced-aligner-0.6b-8bit").path,
            vadExecutable: root.appendingPathComponent("tools/whisper.cpp/static-build/bin/whisper-vad-speech-segments").path,
            secondaryModel: root.appendingPathComponent("tools/whisper.cpp/models/ggml-large-v3.bin").path)
        guard tools.isReady else { throw StudyError.message("Existing local English ASR dependencies missing; no downloads permitted") }
        var results: [[String: Any]] = []
        let reportURL = base.appendingPathComponent("player-results.json")
        func save() throws {
            let report: [String: Any] = ["method": "production StudyModel; local models only; no scripted reference passed to inference",
                "asr": "Qwen3-ASR 1.7B + ForcedAligner 0.6B + Whisper question punctuation",
                "translation": LocalToolDefaults.qualityTranslationModel,
                "endpoint": "http://127.0.0.1:11434", "cases": results]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: reportURL, options: .atomic)
        }
        for clip in manifest.cases {
            let started = Date()
            let dialogue = clip.id == "english-dialogue"
            let model = StudyModel(cacheDirectory: cache.appendingPathComponent(clip.id), tools: tools,
                audioOnly: true, preferredLanguage: dialogue ? "en" : "auto", translationModel: LocalToolDefaults.qualityTranslationModel)
            model.waitForSubtitles = true
            model.player.isMuted = true
            model.autoTranscribe = true
            model.loadVideo(URL(fileURLWithPath: clip.video))
            func until(_ description: String, _ predicate: () -> Bool) async throws {
                let deadline = Date().addingTimeInterval(240)
                while !predicate() {
                    if model.subtitlePreparationFailed || model.translationFailed {
                        throw StudyError.message("\(clip.id): \(description): \(model.translationError ?? model.error ?? model.status)\n\(model.taskLog)")
                    }
                    guard Date() < deadline else { throw StudyError.message("Timeout \(clip.id): \(description)") }
                    try await Task.sleep(nanoseconds: 30_000_000)
                }
            }
            try await until("duration") { model.duration > 0 }
            let total = Int(ceil(model.duration/24))
            for index in 0..<total {
                model.seek(Double(index)*24+0.01)
                try await until("audio window \(index)") { model.completedChunks.contains(index) }
            }
            try await until("all windows") { !model.busy && model.completedChunks.count == total }
            let originalSeconds = Date().timeIntervalSince(started)
            print("\(clip.id): original ready, \(model.cues.count) cues, \(originalSeconds)s")
            let resultIndex = results.count
            results.append(["id": clip.id, "language": model.language, "audioSeconds": clip.duration,
                "originalProcessingSeconds": originalSeconds, "processingSeconds": Date().timeIntervalSince(started),
                "firstChineseWaitSeconds": 0, "displayChecks": 0, "cacheReused": false,
                "cues": try JSONSerialization.jsonObject(with: JSONEncoder().encode(model.cues))])
            try save()
            var firstWait: Double = 0
            var displayChecks = 0
            if dialogue {
                guard let quiet = model.cues.first(where: { $0.text.localizedCaseInsensitiveContains("afternoon") }) else {
                    throw StudyError.message("Mixed-volume English quiet sentence missing")
                }
                model.seek(quiet.start+0.05)
                model.autoTranslate = true
                model.requestPlay()
                guard model.waitingForSubtitles && model.player.rate == 0 else {
                    throw StudyError.message("First English playback did not wait for missing Chinese")
                }
                let waiting = Date()
                try await until("first Chinese") { !model.waitingForSubtitles && model.playing }
                firstWait = Date().timeIntervalSince(waiting)
                model.pausePlayback()
                let originals = model.cues
                for (i, cue) in originals.enumerated() {
                    let target = cue.start + min(0.08, (cue.end-cue.start)/2)
                    model.seek(target)
                    model.requestPlay()
                    try await until("Chinese cue \(i)") { model.cues.first(where: { $0.id == cue.id })?.translationSignature != nil }
                    model.pausePlayback()
                    guard let translated = model.cues.first(where: { $0.id == cue.id }),
                          translated.translation?.range(of: "[\\p{Han}]", options: .regularExpression) != nil else {
                        throw StudyError.message("English cue has no Chinese translation: \(cue.text)")
                    }
                    // A deterministic playback tick checks the actual display selector.
                    model.tick(target)
                    try await until("display after seek") { model.activeID == cue.id && model.displayID == cue.id }
                    displayChecks += 1
                    results[resultIndex]["cues"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(model.cues))
                    results[resultIndex]["displayChecks"] = displayChecks
                    try save()
                    print("\(i+1)/\(originals.count) · \(cue.text) → \(translated.translation!)")
                }
            } else if clip.id == "english-normal" || clip.id == "english-quiet" {
                guard model.cues.contains(where: { $0.text.localizedCaseInsensitiveContains("afternoon") }) else {
                    throw StudyError.message("Standalone English voice missing: \(clip.id)")
                }
            } else {
                guard model.cues.isEmpty else { throw StudyError.message("Non-speech invented English subtitles: \(clip.id)") }
            }
            model.pausePlayback(); model.autoTranslate = false
            let ids = model.cues.map(\.id)
            model.loadVideo(URL(fileURLWithPath: clip.video))
            guard model.cues.map(\.id) == ids, !model.busy else { throw StudyError.message("English cache not reused: \(clip.id)") }
            let record: [String: Any] = ["id": clip.id, "language": model.language, "audioSeconds": clip.duration,
                "originalProcessingSeconds": originalSeconds, "processingSeconds": Date().timeIntervalSince(started),
                "firstChineseWaitSeconds": firstWait, "displayChecks": displayChecks, "cacheReused": true,
                "cues": try JSONSerialization.jsonObject(with: JSONEncoder().encode(model.cues))]
            results[resultIndex] = record; try save()
            model.autoTranscribe = false
        }
        print("PASS: English mixed/quiet speech, automatic language, local Chinese, first-play gate, seek/display/cache, silence/tone/noise")
    }
}
