import Foundation
import AVFoundation
import Darwin

// Uses the player's windowing, normalization, VAD, token ownership
// and bounded recovery. Reference text is never supplied to the recognizer.
@main struct ASRCorpusChecks {
    struct Corpus: Decodable { var referenceSource: String; var cases: [Case] }
    struct Case: Decodable { var id: String; var audio: String; var reference: String; var language: String? }
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        guard [4, 5].contains(CommandLine.arguments.count) else { throw StudyError.message("Usage: asr-corpus-checks manifest.json model.bin report.json [window-seconds]") }
        let span = CommandLine.arguments.count == 5 ? Double(CommandLine.arguments[4]) ?? 24 : 24
        guard span >= 2 && span <= 27 else { throw StudyError.message("Benchmark windows must be between 2 and 27 seconds") }
        let manifest = URL(fileURLWithPath: CommandLine.arguments[1])
        let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: manifest))
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = CommandLine.arguments[2]
        var tools = TranscriptionTools(ffmpeg: "/opt/homebrew/bin/ffmpeg", whisper: root.appendingPathComponent("tools/whisper.cpp/static-build/bin/whisper-cli").path, model: model)
        if FileManager.default.fileExists(atPath: model+"/model.safetensors") {
            tools.engine = "qwen3-asr"
            tools.python = root.appendingPathComponent("tools/mlx-asr-venv/bin/python").path
            tools.worker = root.appendingPathComponent("scripts/local-qwen-asr.py").path
            tools.alignmentModel = root.appendingPathComponent("tools/asr-candidates/qwen3-forced-aligner-0.6b-8bit").path
            tools.vadExecutable = root.appendingPathComponent("tools/whisper.cpp/static-build/bin/whisper-vad-speech-segments").path
            tools.vadModel = root.appendingPathComponent("tools/whisper.cpp/models/ggml-silero-v6.2.0.bin").path
            tools.secondaryModel = root.appendingPathComponent("tools/whisper.cpp/models/ggml-large-v3.bin").path
        }
        var results: [[String: Any]] = []
        for (number, test) in corpus.cases.enumerated() {
            let path = test.audio.hasPrefix("/") ? URL(fileURLWithPath: test.audio) : manifest.deletingLastPathComponent().appendingPathComponent(test.audio)
            let audio = try AVAudioFile(forReading: path)
            let duration = Double(audio.length)/audio.processingFormat.sampleRate
            var cues: [SubtitleCue] = []
            let started = Date()
            var failure: String? = nil
            do {
            for index in 0..<Int(ceil(duration/span)) {
                let range = ChunkTimeline.window(index: index, span: span, duration: duration, context: tools.engine == "qwen3-asr" ? 4 : 1.5)
                print("Starting \(test.id) window \(index) · \(range.audioStart)...\(range.audioEnd)")
                let wav = folder.appendingPathComponent("window.wav")
                let output = folder.appendingPathComponent("transcript")
                let runner = ProcessRunner()
                try await runner.run(executable: tools.ffmpeg, arguments: ["-nostdin", "-y", "-ss", String(range.audioStart), "-i", path.path, "-t", String(range.audioEnd-range.audioStart), "-vn", "-ar", "16000", "-ac", "1", "-af", RecognitionQuality.audioFilter, "-c:a", "pcm_s16le", wav.path], log: { _ in })
                let local = try await SpeechTranscriber.transcribe(audio: wav, output: output, tools: tools, language: test.language ?? "ja", ownedStart: range.start-range.audioStart, ownedEnd: range.end-range.audioStart, allowEndPadding: range.end >= duration-0.001, runner: runner, log: { FileHandle.standardError.write(Data($0.utf8)) })
                cues += ChunkTimeline.project(local, audioStart: range.audioStart, start: range.start, end: range.end)
                if tools.engine == "qwen3-asr" {
                    cues = QwenAlignedTranscript.mergeBoundary(cues, at: range.start)
                    cues = QwenAlignedTranscript.mergeBoundary(cues, at: range.end)
                }
            }
            } catch {
                failure = String(describing: error)
                print("FAILED \(test.id): \(failure!)")
            }
            let elapsed = Date().timeIntervalSince(started)
            results.append(["id": test.id, "language": test.language ?? "ja", "reference": test.reference, "hypothesis": cues.map(\.text).joined(separator: test.language == "en" ? " " : ""), "audioSeconds": duration, "processingSeconds": elapsed, "cueCount": cues.count, "status": failure == nil ? "completed" : "failed", "error": failure ?? "", "cues": try JSONSerialization.jsonObject(with: JSONEncoder().encode(cues))])
            let report: [String: Any] = ["model": model, "windowSeconds": span, "referenceSource": corpus.referenceSource, "cases": results]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[3]))
            print("\(number+1)/\(corpus.cases.count) · \(test.id) · \(Int(elapsed))s")
        }
        if results.contains(where: { $0["status"] as? String == "failed" }) { exit(EXIT_FAILURE) }
    }
}
