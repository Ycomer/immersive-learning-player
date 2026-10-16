import Foundation
import AVFoundation
import Darwin

@main struct QualityAudioChecks {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let ffmpeg = "/opt/homebrew/bin/ffmpeg"
        let whisper = root.appendingPathComponent("tools/whisper.cpp/static-build/bin/whisper-cli").path
        let model = CommandLine.arguments.dropFirst().first ?? root.appendingPathComponent("tools/whisper.cpp/models/ggml-small.bin").path
        let vad = root.appendingPathComponent("tools/whisper.cpp/models/ggml-silero-v6.2.0.bin").path
        let sample = root.appendingPathComponent("Samples/Japanese.mp4").path
        func check(_ ok: Bool, _ message: String) throws { if !ok { throw StudyError.message(message) } }
        func command(_ executable: String, _ arguments: [String]) async throws {
            try await ProcessRunner().run(executable: executable, arguments: arguments, log: { _ in })
        }
        let cases: [(String, [String])] = [
            ("normal", ["-i", sample]),
            ("quiet", ["-i", sample, "-af", "volume=0.02"]),
            ("music", ["-f", "lavfi", "-i", "aevalsrc=0.12*sin(2*PI*220*t)+0.06*sin(2*PI*330*t)+0.04*sin(2*PI*440*t):s=16000:d=6"]),
            ("noise", ["-f", "lavfi", "-i", "anoisesrc=color=pink:amplitude=0.02:sample_rate=16000:duration=6"]),
            ("silence", ["-f", "lavfi", "-i", "anullsrc=r=16000:cl=mono", "-t", "6"]),
            ("separated", ["-i", sample, "-filter_complex", "anullsrc=r=16000:cl=mono,atrim=duration=3[lead];[0:a]volume=0.02,asplit=2[a][b];anullsrc=r=16000:cl=mono,atrim=duration=3.5[gap];[lead][a][gap][b]concat=n=4:v=0:a=1[out]", "-map", "[out]"])
        ]
        var results: [[String: Any]] = []
        let reference = "今日はいい天気ですね。私は日本語を勉強しています。もう一度聞いてみましょう。"
        for (name, input) in cases {
            let raw = folder.appendingPathComponent(name+"-raw.wav")
            let wav = folder.appendingPathComponent(name+".wav")
            let output = folder.appendingPathComponent(name)
            try await command(ffmpeg, ["-nostdin", "-y", "-loglevel", "error"]+input+["-vn", "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", raw.path])
            try await command(ffmpeg, ["-nostdin", "-y", "-loglevel", "error", "-i", raw.path, "-af", RecognitionQuality.audioFilter, "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", wav.path])
            let audio = try AVAudioFile(forReading: wav)
            let duration = Double(audio.length)/audio.processingFormat.sampleRate
            let started = Date()
            let cues = try await SpeechTranscriber.transcribe(audio: wav, output: output, tools: TranscriptionTools(ffmpeg: ffmpeg, whisper: whisper, model: model, vadModel: vad), language: "ja", ownedStart: 0, ownedEnd: duration, allowEndPadding: true, runner: ProcessRunner(), log: { _ in })
            let elapsed = Date().timeIntervalSince(started)
            try Data(contentsOf: output.appendingPathExtension("json")).write(to: root.appendingPathComponent("build/quality-debug-\(URL(fileURLWithPath: model).lastPathComponent)-\(name).json"))
            let text = cues.map(\.text).joined()
            if ["music", "noise", "silence"].contains(name) {
                try check(cues.isEmpty, "\(name) fabricated speech: \(text)")
            } else {
                try check(text.contains("日本語") && text.contains("勉強"), "\(name) lost the quiet Japanese dialogue: \(text)")
                try check(text.contains("みましょう"), "\(name) dropped final boundary words: \(text)")
                try check(cues.count >= (name == "separated" ? 6 : 3), "\(name) lost sentence boundaries: \(cues.map { "\($0.start)-\($0.end): \($0.text)" })")
                if name == "separated" {
                    try check(cues.allSatisfy { $0.start >= 2.8 }, "VAD removed intro silence from the video clock")
                    try check(cues.contains { $0.start > 13 }, "Second speech block drifted onto removed silence")
                    try check(!cues.contains { $0.start > 10 && $0.start < 12.8 }, "Silent gap contains hallucinated captions")
                }
            }
            print("PASS: \(name) · \(cues.count) sentences · \(text)")
            results.append(["id": name, "hypothesis": text, "reference": ["music", "noise", "silence"].contains(name) ? "" : name == "separated" ? reference+reference : reference, "audioSeconds": duration, "processingSeconds": elapsed, "cueCount": cues.count, "cues": try JSONSerialization.jsonObject(with: JSONEncoder().encode(cues))])
        }
        let report: [String: Any] = ["model": model, "referenceSource": "synthetic", "cases": results]
        let name = URL(fileURLWithPath: model).deletingPathExtension().lastPathComponent
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("build/quality-audio-\(name).json"))
    }
}
