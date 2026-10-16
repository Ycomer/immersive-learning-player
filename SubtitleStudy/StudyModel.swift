import SwiftUI
import AVKit
import UniformTypeIdentifiers
import CryptoKit

@MainActor
final class StudyModel: ObservableObject {
    let player = AVPlayer()
    @Published var videoURL: URL?
    @Published var cues: [SubtitleCue] = [] {
        didSet {
            var maximum = 0.0
            maximumEnds = cues.map { maximum = max(maximum, $0.end); return maximum }
        }
    }
    @Published var currentTime = 0.0
    @Published var videoAspect = 16.0 / 9.0
    @Published var autoTranslate = true { didSet { if !autoTranslate { cancelTranslation() }; translationFailed = false; if autoTranslate { scheduleTranslation() }; updatePlaybackGate() } }
    @Published var translationFailed = false
    @Published var translationError: String?
    @Published var duration = 0.0
    @Published var playing = false
    @Published private(set) var playRequested = false
    @Published private(set) var subtitleWaitReason: SubtitleWaitReason?
    @Published var waitForSubtitles = false {
        didSet {
            if cacheOverride == nil { UserDefaults.standard.set(waitForSubtitles, forKey: "waitForSubtitles") }
            updatePlaybackGate()
        }
    }
    var waitingForSubtitles: Bool { playRequested && subtitleWaitReason != nil }
    var waitingMessage: String {
        if subtitleWaitReason == .original { return subtitlePreparationFailed ? status : "正在准备原文字幕，就绪后自动继续…" }
        return translationFailed ? (translationError ?? status) : "正在准备中文译文，就绪后自动继续…"
    }
    @Published var activeID: UUID?
    @Published private(set) var displayID: UUID?
    @Published var readingHoldSeconds = 2.5 {
        didSet { if cacheOverride == nil { UserDefaults.standard.set(readingHoldSeconds, forKey: "readingHoldSeconds") }; updateActive() }
    }
    @Published var pauseAfterSentence = false {
        didSet { if cacheOverride == nil { UserDefaults.standard.set(pauseAfterSentence, forKey: "pauseAfterSentence") } }
    }
    @Published var selectedID: UUID?
    @Published var followPlayback = true
    @Published var repeatSentence = false
    @Published var speed: Float = 1
    @Published var offset = 0.0 { didSet { updateActive(); if cacheURL != nil { save() } } }
    @Published var incrementalTranscription = false
    @Published var completedChunks: Set<Int> = []
    private var processingChunk: Int?
    private var chunkSeconds: Double
    var currentRegionReady: Bool {
        {
            guard incrementalTranscription else { return !cues.isEmpty }
            guard duration > 0 else { return false }
            let last = max(0, Int(ceil(duration / chunkSeconds)) - 1)
            return completedChunks.contains(min(last, ChunkTimeline.index(at: currentTime, span: chunkSeconds)))
        }()
    }
    @Published var autoTranscribe = true { didSet { if !autoTranscribe { cancelWork() } else { subtitlePreparationFailed = false; scheduleChunk() }; updatePlaybackGate() } }
    @Published var subtitlePreparationFailed = false
    @Published var busy = false
    @Published var translating = false
    @Published var status = "打开一段视频，开始你的字幕学习"
    @Published var taskLog = ""
    @Published var error: String?
    @Published var language = "auto"
    private var maximumEnds: [Double] = []
    private var observer: Any?
    private var playbackObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var job: Task<Void, Never>?
    @Published private(set) var contextStudyCueID: UUID?
    @Published private(set) var contextStudyError: String?
    private var contextStudyJob: Task<Void, Never>?
    private var contextStudyToken = UUID()
    private var contextStudyRequestSignature: String?
    private var translationJob: Task<Void, Never>?
    private var translationToken = UUID()
    private var runner: ProcessRunner?
    private var session = UUID()
    private var generationSignature: String?
    private var cacheURL: URL?
    private var looping = false
    private var loopID: UUID?
    private var isSeeking = false
    private var seekToken = UUID()
    private var readingPausedID: UUID?
    private var readingCompleted: Set<UUID> = []

    var selectedCue: SubtitleCue? { cues.first { $0.id == (selectedID ?? activeID ?? displayID) } }
    var languageName: String { ["auto": "自动识别", "ja": "日语", "ko": "韩语", "en": "英语", "zh": "中文"][language] ?? language }
    private var preferredRecognitionLanguage: String
    private var defaultRecognitionLanguage: String
    private let recognitionPreferences: UserDefaults?
    @Published var audioOnly: Bool
    private let toolsOverride: TranscriptionTools?
    private let cacheOverride: URL?
    private let translationModelOverride: String?
    private let translationSession: URLSession
    private var configuredTranslationModel: String { translationModelOverride ?? UserDefaults.standard.string(forKey: "ollamaModel") ?? LocalToolDefaults.translationModel }
    var cacheDirectory: URL {
        if let cacheOverride { return cacheOverride }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("SubtitleStudy/Subtitles", isDirectory: true)
    }

    init(cacheDirectory: URL? = nil, tools: TranscriptionTools? = nil, chunkSeconds: Double = 24, audioOnly: Bool? = nil, preferredLanguage: String? = nil, translationModel: String? = nil, translationSession: URLSession = .shared, recognitionPreferences: UserDefaults? = nil) {
        if cacheDirectory == nil { LocalToolDefaults.migrateJapaneseAudioSourceDefaults(); LocalToolDefaults.migrateImmediatePlayback() }
        self.audioOnly = audioOnly ?? (cacheDirectory == nil ? (UserDefaults.standard.object(forKey: "preferAudioOriginal") as? Bool ?? true) : true)
        // A global language left over from another video can make Qwen produce
        // translations instead of original speech. New files start in auto;
        // explicit language choices belong to the current video only.
        defaultRecognitionLanguage = preferredLanguage ?? "auto"
        preferredRecognitionLanguage = preferredLanguage ?? "auto"
        self.recognitionPreferences = recognitionPreferences ?? (cacheDirectory == nil ? .standard : nil)
        self.chunkSeconds = max(2, chunkSeconds)
        toolsOverride = tools
        cacheOverride = cacheDirectory
        translationModelOverride = translationModel
        self.translationSession = translationSession
        waitForSubtitles = cacheDirectory == nil ? (UserDefaults.standard.object(forKey: "waitForSubtitles") as? Bool ?? false) : false
        readingHoldSeconds = cacheDirectory == nil ? (UserDefaults.standard.object(forKey: "readingHoldSeconds") as? Double ?? 2.5) : 2.5
        pauseAfterSentence = cacheDirectory == nil ? UserDefaults.standard.bool(forKey: "pauseAfterSentence") : false
        if cacheDirectory != nil { autoTranslate = false; autoTranscribe = false }
        if cacheDirectory == nil { LocalToolDefaults.migrateTranslationModel(); LocalToolDefaults.migrateRecognitionModel(); LocalToolDefaults.migrateAccurateRecognitionModel(); LocalToolDefaults.migrateSpeechTools(); LocalToolDefaults.migrateLocalQualityStack() }
        player.appliesMediaSelectionCriteriaAutomatically = false
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.08, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in self?.tick(time.seconds) }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] note in
            guard let item = note.object as? AVPlayerItem else { return }
            Task { @MainActor in
                guard let self, self.player.currentItem === item else { return }
                if self.repeatSentence, let cue = self.cues.first(where: { $0.id == self.loopID }) { self.looping = false; self.select(cue) }
                else {
                    self.pausePlayback()
                    if let last = self.cues.last, last.end+self.offset >= self.duration-1.2 {
                        self.readingPausedID = last.id; self.displayID = last.id
                    }
                }
            }
        }
        playbackObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor in
                guard let self else { return }
                self.playing = self.player.timeControlStatus == .playing
            }
        }
    }

    func tick(_ value: Double) {
        guard value.isFinite, !isSeeking else { return }
        let previousID = activeID
        currentTime = value
        if let d = player.currentItem?.duration.seconds, d.isFinite { duration = d }
        if repeatSentence, playRequested, !looping,
           let cue = cues.first(where: { $0.id == loopID }), currentTime >= cue.end + offset {
            looping = true
            seek(cue.start + offset)
            return
        }
        if pauseAfterSentence, playRequested, !repeatSentence,
           let cue = cues.first(where: { $0.id == previousID }), currentTime >= cue.end+offset,
           !readingCompleted.contains(cue.id) {
            pausePlayback(); readingCompleted.insert(cue.id); readingPausedID = cue.id
        }
        updateActive()
    }

    func updateActive() {
        let time = currentTime - offset
        // Binary search the most recent cue, then examine overlaps.
        var low = 0; var high = cues.count
        while low < high {
            let mid = (low + high) / 2
            if cues[mid].start <= time { low = mid + 1 } else { high = mid }
        }
        var index = low - 1
        var match: UUID?
        while index >= 0 {
            if maximumEnds[index] <= time { break }
            if cues[index].start <= time && time < cues[index].end { match = cues[index].id; break }
            // Imported subtitles may overlap; do not assume their end times are sorted.
            index -= 1
        }
        if activeID != match { activeID = match }
        let held = SubtitlePresentation.heldIndex(time: time, cues: cues, minimum: readingHoldSeconds, speed: speed, duration: duration-offset).map { cues[$0].id }
        let shown = readingPausedID ?? match ?? held
        if displayID != shown { displayID = shown }
        scheduleTranslation()
        scheduleChunk()
        updatePlaybackGate()
    }

    func openVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadVideo(url, autoplay: true)
    }

    static func recognitionLanguageKey(for url: URL) -> String {
        let identity = url.standardizedFileURL.path
        let hash = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return "videoAudioLanguage.v1." + hash
    }

    func loadVideo(_ url: URL, autoplay: Bool = false) {
        let savedLanguage = recognitionPreferences?.string(forKey: Self.recognitionLanguageKey(for: url))
        if let savedLanguage, ["auto", "ja", "en", "ko", "zh"].contains(savedLanguage) { preferredRecognitionLanguage = savedLanguage }
        else { preferredRecognitionLanguage = defaultRecognitionLanguage }
        readingPausedID = nil; readingCompleted = []; displayID = nil
        pausePlayback(); isSeeking = false; seekToken = UUID()
        cancelWork(); cancelTranslation(); cancelContextStudy(); translationFailed = false; subtitlePreparationFailed = false
        session = UUID(); incrementalTranscription = false; completedChunks = []; processingChunk = nil; cacheURL = nil; generationSignature = nil; taskLog = ""; player.pause(); playing = false
        videoURL = url; cues = []; selectedID = nil; activeID = nil; loopID = nil; looping = false
        repeatSentence = false; offset = 0; currentTime = 0; duration = 0; language = preferredRecognitionLanguage
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        cacheURL = makeCacheURL(url)
        if let file = cacheURL, let data = try? Data(contentsOf: file), let document = try? JSONDecoder().decode(SubtitleDocument.self, from: data), (!document.cues.isEmpty || document.completedChunks != nil), acceptsCachedDocument(document) {
            cues = document.cues; generationSignature = document.generationSignature
            if let span = document.chunkSeconds, let done = document.completedChunks, span >= 2 && span <= 60 {
                chunkSeconds = span
                incrementalTranscription = true
                completedChunks = Set(done.filter { $0 >= 0 })
            }
            if let cachedLanguage = document.language { language = cachedLanguage }
            // Invalid Chinese must not be displayed, even with auto-translation disabled.
            for index in cues.indices {
                if let translated = cues[index].translation, !ChineseTranslationCheck.isValid(translated) {
                    cues[index].translation = nil; cues[index].annotations = nil; cues[index].translationWarning = nil; cues[index].translationSignature = nil; cues[index].plainMeaning = nil; cues[index].translationModelUsed = nil
                }
            }
            if autoTranslate {
                for index in cues.indices where cues[index].translationSignature != translationSignature(for: cues[index], at: index) {
                    cues[index].translation = nil; cues[index].annotations = nil; cues[index].translationWarning = nil; cues[index].translationSignature = nil; cues[index].plainMeaning = nil; cues[index].translationModelUsed = nil
                }
            }
            offset = document.offset ?? 0
            status = "已加载缓存字幕 · \(cues.count) 句"
        } else {
            status = "准备字幕：正在检查视频音轨…"
            let sidecar = url.deletingPathExtension().appendingPathExtension("srt")
            if !audioOnly && FileManager.default.fileExists(atPath: sidecar.path) { importSubtitle(sidecar) }
        }
        // Request playback before subtitle work or asynchronous media inspection.
        // A later metadata result must not override a manual pause.
        if autoplay { requestPlay() }
        let token = session
        Task {
            do {
                guard let asset = player.currentItem?.asset else { return }
                let playable = try await asset.load(.isPlayable)
                let length = try await asset.load(.duration).seconds
                if let group = try await asset.loadMediaSelectionGroup(for: .legible), session == token {
                    player.currentItem?.select(nil, in: group)
                }
                var aspect = 16.0 / 9.0
                if let track = try await asset.loadTracks(withMediaType: .video).first {
                    let size = try await track.load(.naturalSize)
                    let transform = try await track.load(.preferredTransform)
                    let rendered = size.applying(transform)
                    if abs(rendered.height) > 0 { aspect = abs(rendered.width / rendered.height) }
                }
                guard session == token else { return }
                if length.isFinite { duration = length }; videoAspect = aspect
                if !playable {
                    subtitlePreparationFailed = true
                    self.error = "这个视频的编码无法由系统播放器播放，请换用 H.264 / HEVC 编码的视频。"
                } else if (cues.isEmpty || incrementalTranscription) && autoTranscribe && !busy && !subtitlePreparationFailed {
                    incrementalTranscription = true
                    scheduleChunk()
                } else { updateActive() }
                updatePlaybackGate()
            } catch { if session == token { subtitlePreparationFailed = true; self.error = error.localizedDescription; status = "字幕准备失败：\(error.localizedDescription)" } }
        }
    }

    func chooseAudioSource(_ enabled: Bool) {
        guard enabled != audioOnly else { return }
        let oldTime = currentTime; let wasPlaying = playRequested || playing
        audioOnly = enabled
        if cacheOverride == nil { UserDefaults.standard.set(enabled, forKey: "preferAudioOriginal") }
        if let video = videoURL {
            loadVideo(video); seek(oldTime)
            if wasPlaying { requestPlay() }
        }
    }

    func rebuildJapaneseFromAudio() {
        preferredRecognitionLanguage = "ja"; language = "ja"
        if cacheOverride == nil {
            UserDefaults.standard.set("ja", forKey: "audioRecognitionLanguage")
            UserDefaults.standard.set(true, forKey: "preferAudioOriginal")
        }
        audioOnly = true
        if let video = videoURL {
            cancelWork(); subtitlePreparationFailed = false; cacheURL = makeCacheURL(video)
            transcribe()
        }
    }

    private func acceptsCachedDocument(_ document: SubtitleDocument) -> Bool {
        guard audioOnly else { return true }
        guard document.language == preferredRecognitionLanguage else { return false }
        let signature = document.generationSignature ?? ""
        return signature.hasPrefix("chunk-v") || signature.hasPrefix("whisper:")
    }

    func chooseRecognitionLanguage(_ value: String) {
        guard value != language else { return }
        preferredRecognitionLanguage = value; language = value
        if let video = videoURL { recognitionPreferences?.set(value, forKey: Self.recognitionLanguageKey(for: video)) }
        else { defaultRecognitionLanguage = value }
        if let video = videoURL {
            cancelWork(); subtitlePreparationFailed = false
            cacheURL = makeCacheURL(video)
            transcribe()
        }
    }

    func reloadRecognitionConfiguration() {
        let tools = toolsOverride ?? TranscriptionTools.configured
        guard audioOnly, let video = videoURL, FileManager.default.fileExists(atPath: tools.model), makeCacheURL(video) != cacheURL else { return }
        let position = currentTime; let resume = playRequested || playing
        loadVideo(video); seek(position)
        if resume { requestPlay() }
    }

    func makeCacheURL(_ url: URL) -> URL {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let identity = "\(url.standardizedFileURL.path)|\(attrs?[.size] ?? 0)|\(attrs?[.modificationDate] ?? Date.distantPast)"
        let tools = toolsOverride ?? TranscriptionTools.configured
        let modelSize = (try? FileManager.default.attributesOfItem(atPath: tools.model)[.size]) ?? 0
        let profile = audioOnly ? "audio-v4|\(tools.engine)|\(RecognitionQuality.revision)|\(preferredRecognitionLanguage)|\(tools.model)|\(modelSize)|aligner:\(tools.alignmentModel ?? "")|track:\(UserDefaults.standard.integer(forKey: "audioTrack"))" : "external-v1"
        let hash = SHA256.hash(data: Data((identity + "|" + profile).utf8)).map { String(format: "%02x", $0) }.joined()
        return cacheDirectory.appendingPathComponent(hash + ".json")
    }

    func save() {
        guard let file = cacheURL, let source = videoURL?.path else { return }
        do {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try JSONEncoder().encode(SubtitleDocument(source: source, cues: cues, language: language, offset: offset, generationSignature: generationSignature, chunkSeconds: incrementalTranscription ? chunkSeconds : nil, completedChunks: incrementalTranscription ? completedChunks.sorted() : nil)).write(to: file, options: .atomic)
        } catch { self.error = "字幕缓存保存失败：\(error.localizedDescription)" }
    }

    func chooseSubtitle() {
        guard videoURL != nil else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "srt") ?? .plainText, UTType(filenameExtension: "vtt") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if audioOnly { chooseAudioSource(false) }
        importSubtitle(url)
    }

    func importSubtitle(_ url: URL) {
        do {
            let parsed = try SubtitleCodec.parse(String(contentsOf: url, encoding: .utf8))
            cancelWork(); cancelTranslation(); cancelContextStudy(); translationFailed = false
            subtitlePreparationFailed = false
            incrementalTranscription = false; completedChunks = []; processingChunk = nil
            generationSignature = "import:\(url.lastPathComponent)"
            cues = parsed; selectedID = nil; loopID = nil; repeatSentence = false
            save(); updateActive(); status = "已导入字幕 · \(cues.count) 句"
        } catch { self.error = error.localizedDescription }
    }

    func togglePlay() {
        guard videoURL != nil else { return }
        if playRequested || playing { pausePlayback() }
        else {
            if duration > 0 && currentTime >= duration - 0.1 { seek(0) }
            requestPlay()
        }
    }

    func pausePlayback() {
        playRequested = false; subtitleWaitReason = nil
        player.pause(); playing = false
    }

    func requestPlay() {
        guard videoURL != nil else { return }
        readingPausedID = nil
        playRequested = true
        updateActive()
    }

    private func updatePlaybackGate() {
        guard playRequested else { subtitleWaitReason = nil; return }
        let lookahead = 0.4 * Double(max(1, speed))
        let loopEnd = repeatSentence ? cues.first(where: { $0.id == loopID }).map { max(currentTime, $0.end+offset-0.001) } : nil
        let effectiveLookahead = loopEnd.map { min(lookahead, $0-currentTime) } ?? lookahead
        let reason = waitForSubtitles ? SubtitlePlaybackBuffer.reason(time: currentTime-offset, duration: duration-offset, lookahead: effectiveLookahead, span: chunkSeconds, completed: completedChunks, needsOriginal: false, cues: cues, maximumEnds: maximumEnds, needsTranslation: autoTranslate) : nil
        // ASR windows follow the video clock, independent of the user's subtitle offset.
        let originalReason = waitForSubtitles && autoTranscribe && (incrementalTranscription || cues.isEmpty) ? SubtitlePlaybackBuffer.reason(time: currentTime, duration: duration, lookahead: effectiveLookahead, span: chunkSeconds, completed: completedChunks, needsOriginal: true, cues: [], maximumEnds: [], needsTranslation: false) : nil
        subtitleWaitReason = originalReason ?? reason
        if subtitleWaitReason != nil {
            if player.rate != 0 { player.pause() }
            playing = false
        } else if !isSeeking && player.rate == 0 {
            player.playImmediately(atRate: speed); playing = true
        }
    }

    func changeSpeed(_ value: Float) {
        speed = value
        if playing { player.rate = value }
        updatePlaybackGate()
    }

    func seek(_ time: Double) {
        guard time.isFinite else { return }
        readingPausedID = nil; readingCompleted = []
        let token = session; let requestToken = UUID(); seekToken = requestToken; isSeeking = true
        player.pause(); playing = false
        currentTime = max(0, time); updateActive()
        player.seek(to: CMTime(seconds: currentTime, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.session == token, self.seekToken == requestToken else { return }
                self.isSeeking = false; self.looping = false; self.updatePlaybackGate()
            }
        }
    }

    func select(_ cue: SubtitleCue, play: Bool = true) {
        selectedID = cue.id; loopID = cue.id
        seek(cue.start + offset)
        if play { requestPlay() }
    }

    func moveSentence(_ delta: Int) {
        guard !cues.isEmpty else { return }
        let index = cues.firstIndex { $0.id == (activeID ?? selectedID) } ?? (delta > 0 ? -1 : cues.count)
        select(cues[min(cues.count - 1, max(0, index + delta))])
    }

    func toggleLoop() {
        if repeatSentence { repeatSentence = false }
        else if let cue = selectedCue { repeatSentence = true; loopID = cue.id; select(cue) }
    }

    func edit(_ id: UUID, text: String) {
        guard let index = cues.firstIndex(where: { $0.id == id }), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        cancelTranslation(); cancelContextStudy()
        cues[index].contextStudy = nil; cues[index].contextStudySignature = nil; cues[index].wordStudies = nil
        cues[index].text = text; cues[index].translation = nil
        cues[index].annotations = nil; cues[index].translationWarning = nil; cues[index].translationSignature = nil
        cues[index].translationModelUsed = nil
        cues[index].recognitionWarning = nil; cues[index].recognitionConfidence = nil
        cues[index].plainMeaning = nil
        save(); updateActive()
    }

    func exportSubtitle() {
        guard !cues.isEmpty else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = (videoURL?.deletingPathExtension().lastPathComponent ?? "subtitles") + ".srt"
        panel.allowedContentTypes = [UTType(filenameExtension: "srt") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let adjusted = cues.map { cue -> SubtitleCue in var copy = cue; copy.start = max(0, cue.start + offset); copy.end = max(copy.start + 0.001, cue.end + offset); return copy }
            try SubtitleCodec.srt(adjusted).write(to: url, atomically: true, encoding: .utf8)
        } catch { self.error = error.localizedDescription }
    }

    func cancelWork() {
        job?.cancel(); runner?.cancel(); job = nil; runner = nil; busy = false; processingChunk = nil
        if videoURL != nil { subtitlePreparationFailed = true; status = "任务已取消 · 可以重试" }
    }

    func transcribe() {
        guard videoURL != nil, !busy else { return }
        readingPausedID = nil; readingCompleted = []; displayID = nil
        cancelTranslation(); cancelContextStudy(); translationFailed = false; subtitlePreparationFailed = false
        incrementalTranscription = true; completedChunks = []; cues = []; activeID = nil; selectedID = nil
        repeatSentence = false; loopID = nil; offset = 0
        autoTranscribe = true
        scheduleChunk()
    }

    private func scheduleChunk() {
        guard incrementalTranscription, autoTranscribe, !subtitlePreparationFailed,
              let video = videoURL, duration > 0 else { return }
        let total = Int(ceil(duration / chunkSeconds))
        let current = min(total - 1, ChunkTimeline.index(at: currentTime, span: chunkSeconds))
        if busy {
            if let processingChunk, !completedChunks.contains(current), abs(processingChunk - current) > 1 {
                job?.cancel(); runner?.cancel(); job = nil; runner = nil; busy = false; self.processingChunk = nil
            } else { return }
        }
        // Only process the playhead and the next two windows; a seek reprioritizes this queue.
        guard let index = (current..<min(total, current + 3)).first(where: { !completedChunks.contains($0) }) else {
            status = completedChunks.count >= total ? "字幕全部准备完成" : "播放位置附近字幕已准备好"
            return
        }
        let tools = toolsOverride ?? TranscriptionTools.configured
        guard tools.isReady else {
            subtitlePreparationFailed = true; status = "字幕准备失败：请检查设置中的本地识别工具、模型与时间对齐依赖"
            error = status; return
        }
        guard tools.resolvedVADModel != nil else {
            subtitlePreparationFailed = true; status = "语音检测模型缺失，请使用新版完整应用，或重新运行项目依赖安装脚本。"
            error = status; return
        }
        let audioTrack = max(0, UserDefaults.standard.integer(forKey: "audioTrack"))
        let token = session; let lang = language; let span = chunkSeconds
        let bounds = ChunkTimeline.window(index: index, span: span, duration: duration, context: tools.engine == "qwen3-asr" ? 4 : 1.5)
        let worker = ProcessRunner(); runner = worker; processingChunk = index; busy = true
        status = "正在准备 \(SubtitleCodec.clock(bounds.start))–\(SubtitleCodec.clock(bounds.end)) 的字幕…"
        job = Task {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer {
                try? FileManager.default.removeItem(at: directory)
                if session == token && runner === worker {
                    busy = false; runner = nil; job = nil; processingChunk = nil
                    scheduleChunk()
                }
            }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let wav = directory.appendingPathComponent("audio.wav")
                let output = directory.appendingPathComponent("transcript")
                let report: @Sendable (String) -> Void = { [weak self] line in
                    Task { @MainActor in
                        guard let self, self.session == token, self.runner === worker else { return }
                        self.taskLog = String((self.taskLog + line).suffix(16000))
                    }
                }
                try await worker.run(executable: tools.ffmpeg, arguments: ["-nostdin", "-y", "-ss", String(bounds.audioStart), "-i", video.path, "-t", String(bounds.audioEnd - bounds.audioStart), "-map", "0:a:\(audioTrack)", "-vn", "-ar", "16000", "-ac", "1", "-af", RecognitionQuality.audioFilter, "-c:a", "pcm_s16le", wav.path], log: report)
                try Task.checkCancellation()
                let local = try await SpeechTranscriber.transcribe(audio: wav, output: output, tools: tools, language: lang, ownedStart: bounds.start-bounds.audioStart, ownedEnd: bounds.end-bounds.audioStart, allowEndPadding: bounds.end >= duration-0.001, runner: worker, log: report)
                try Task.checkCancellation()
                let global = ChunkTimeline.project(local, audioStart: bounds.audioStart, start: bounds.start, end: bounds.end)
                guard session == token, runner === worker else { return }
                generationSignature = "chunk-v3|engine:\(tools.engine)|quality:\(RecognitionQuality.revision)|span:\(span)|model:\(tools.model)|language:\(lang)|track:\(audioTrack)"
                // Existing cue IDs, edits and translations in other windows stay intact.
                var combined = (cues + global).sorted { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
                if tools.engine == "qwen3-asr" {
                    combined = QwenAlignedTranscript.mergeBoundary(combined, at: bounds.start)
                    combined = QwenAlignedTranscript.mergeBoundary(combined, at: bounds.end)
                }
                cues = combined
                completedChunks.insert(index)
                save(); updateActive()
                status = "\(SubtitleCodec.clock(bounds.start))–\(SubtitleCodec.clock(bounds.end)) " + (global.isEmpty ? "此段未识别到对白，可检查音轨或重新识别" : "字幕已就绪")
                if lang != "auto", !global.isEmpty,
                   global.filter({ ($0.recognitionConfidence ?? 1) < 0.45 && $0.recognitionWarning != nil }).count * 2 > global.count {
                    status = "多数原文未确认 · 当前按\(languageName)识别，请检查语言或切换为自动识别"
                }
            } catch is CancellationError { }
            catch {
                if session == token && runner === worker {
                    subtitlePreparationFailed = true; self.error = error.localizedDescription
                    status = "分段字幕准备失败：\(error.localizedDescription)"
                }
            }
        }
    }

    private func cancelTranslation() {
        translationToken = UUID(); translationJob?.cancel(); translationJob = nil; translating = false
    }

    func translateSelected() {
        guard let cue = selectedCue, !translating else { return }
        translationFailed = false
        translate(cue, automatic: false)
    }

    func translateCurrent() {
        guard let cue = cues.first(where: { $0.id == activeID }) ?? cues.first(where: { $0.id == displayID }) ?? cues.first(where: { $0.start > currentTime - offset }), !translating else { return }
        translationFailed = false
        translate(cue, automatic: false)
    }

    private func scheduleTranslation() {
        guard autoTranslate, !translating, !translationFailed else { return }
        // Match the buffering range, including earlier overlapping imported cues.
        // Otherwise a missing overlapping translation could hold playback forever.
        let time = max(0, currentTime-offset)
        if playRequested && waitForSubtitles,
           let pending = SubtitlePlaybackBuffer.pendingTranslationIndex(start: time, end: time+0.4*Double(max(1, speed)), cues: cues, maximumEnds: maximumEnds) {
            translate(cues[pending], automatic: true)
            return
        }
        let index = cues.firstIndex(where: { $0.id == activeID }) ?? cues.firstIndex(where: { $0.start > currentTime - offset })
        guard let index else { return }
        let candidates = cues[index..<min(cues.count, index + 3)]
        if let cue = candidates.first(where: { cue in
            guard let translated = cue.translation else { return true }
            return !ChineseTranslationCheck.isValid(translated) || cue.translationSignature != translationSignature(for: cue)
        }) { translate(cue, automatic: true) }
    }

    // Fixed local window, with no unreliable recognition candidates supplied as evidence.
    func contextStudyLines(for id: UUID) -> [ContextStudyLine] {
        guard let index = cues.firstIndex(where: { $0.id == id }) else { return [] }
        let current = cues[index]
        return (max(0, index-3)..<min(cues.count, index+3)).compactMap { position in
            let cue = cues[position]
            guard cue.start <= current.end+30, cue.end >= current.start-30,
                  !((cue.recognitionConfidence ?? 1) < 0.45 && cue.recognitionWarning != nil) else { return nil }
            let label = position == index ? "current" : position < index ? "before\(index-position)" : "after\(position-index)"
            return ContextStudyLine(id: label, start: cue.start, text: String(cue.text.prefix(800)), isCurrent: position == index)
        }
    }

    private func contextStudySignature(for cue: SubtitleCue, selection: SubtitleWordSelection? = nil, comparison: String? = nil) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let endpoint = UserDefaults.standard.string(forKey: "ollamaURL") ?? "http://127.0.0.1:11434"
        let profile = [OllamaService.contextStudyRevision, LocalToolDefaults.explanationModel, endpoint, languageName,
                       String(decoding: (try? encoder.encode(contextStudyLines(for: cue.id))) ?? Data(), as: UTF8.self),
                       cue.text, cue.recognitionWarning ?? "", String(cue.recognitionConfidence ?? 1),
                       String(decoding: (try? encoder.encode(selection)) ?? Data(), as: UTF8.self), comparison ?? ""]
        return SHA256.hash(data: (try? JSONEncoder().encode(profile)) ?? Data()).map { String(format: "%02x", $0) }.joined()
    }

    func contextStudyResult(for id: UUID, selection: SubtitleWordSelection? = nil, comparison: String? = nil) -> ContextStudy? {
        guard let cue = cues.first(where: { $0.id == id }) else { return nil }
        let trimmed = comparison?.trimmingCharacters(in: .whitespacesAndNewlines)
        let comparison = trimmed?.isEmpty == false ? trimmed : nil
        let signature = contextStudySignature(for: cue, selection: selection, comparison: comparison)
        if let selection {
            guard selection.isValid(in: cue.text) else { return nil }
            return cue.wordStudies?.last(where: { $0.selection == selection && $0.comparison == comparison && $0.signature == signature })?.result
        }
        return cue.contextStudySignature == signature ? cue.contextStudy : nil
    }

    func cancelContextStudy() {
        contextStudyToken = UUID(); contextStudyJob?.cancel(); contextStudyJob = nil
        contextStudyCueID = nil; contextStudyError = nil; contextStudyRequestSignature = nil
    }

    func studyContext(_ id: UUID, selection: SubtitleWordSelection? = nil, comparison: String? = nil, refresh: Bool = false) {
        guard let cue = cues.first(where: { $0.id == id }) else { cancelContextStudy(); return }
        let trimmed = comparison?.trimmingCharacters(in: .whitespacesAndNewlines)
        let comparison = trimmed?.isEmpty == false ? trimmed : nil
        let signature = contextStudySignature(for: cue, selection: selection, comparison: comparison)
        if contextStudyCueID == id && contextStudyRequestSignature == signature && !refresh { return }
        cancelContextStudy()
        if let selection, !selection.isValid(in: cue.text) { contextStudyError = "选词已失效，请在原文中重新选择。"; return }
        if let comparison, selection == nil || comparison.count > 80 { contextStudyError = "请输入不超过 80 字的源语言近义词。"; return }
        guard !((cue.recognitionConfidence ?? 1) < 0.45 && cue.recognitionWarning != nil) else {
            contextStudyError = "这句原声暂未识别清楚，请先复听或修改原文，再分析用词。"; return
        }
        if !refresh && contextStudyResult(for: id, selection: selection, comparison: comparison) != nil { return }
        guard cue.text.count <= 800 else { contextStudyError = "当前句过长，请先把原文拆成较短的句子。"; return }
        let lines = contextStudyLines(for: id)
        let sessionToken = session, requestToken = contextStudyToken
        let endpoint = UserDefaults.standard.string(forKey: "ollamaURL") ?? "http://127.0.0.1:11434"
        let language = languageName
        contextStudyCueID = id; contextStudyRequestSignature = signature
        contextStudyJob = Task { [weak self] in
            guard let self else { return }
            defer { if contextStudyToken == requestToken { contextStudyCueID = nil; contextStudyJob = nil; contextStudyRequestSignature = nil } }
            do {
                let result = try await OllamaService.analyzeContext(lines: lines, language: language, endpoint: endpoint, selection: selection, comparison: comparison, session: translationSession)
                try Task.checkCancellation()
                guard session == sessionToken, contextStudyToken == requestToken,
                      let index = cues.firstIndex(where: { $0.id == id }) else { return }
                guard contextStudySignature(for: cues[index], selection: selection, comparison: comparison) == signature else {
                    contextStudyError = "前后字幕已更新，请重新解析。"; return
                }
                if let selection {
                    var cached = cues[index].wordStudies ?? []
                    cached.removeAll { $0.selection == selection && $0.comparison == comparison }
                    cached.append(WordStudyCache(selection: selection, comparison: comparison, signature: signature, result: result))
                    cues[index].wordStudies = Array(cached.suffix(12))
                } else { cues[index].contextStudy = result; cues[index].contextStudySignature = signature }
                save()
            } catch is CancellationError { }
            catch {
                if session == sessionToken && contextStudyToken == requestToken {
                    contextStudyError = "语境解析失败：\(error.localizedDescription)"
                }
            }
        }
    }

    private func translationContext(for cue: SubtitleCue, at knownIndex: Int? = nil) -> (before: [String], after: [String]) {
        guard let index = knownIndex ?? cues.firstIndex(where: { $0.id == cue.id }) else { return ([], []) }
        let before = cues[max(0, index-3)..<index].filter { cue.start-$0.end <= 30 }.map { String($0.text.prefix(600)) }
        let after = cues[(index+1)..<min(cues.count, index+3)].filter { $0.start-cue.end <= 30 }.map { String($0.text.prefix(600)) }
        return (before, after)
    }

    private func translationSignature(for cue: SubtitleCue, at index: Int? = nil) -> String {
        let context = translationContext(for: cue, at: index)
        let defaults = UserDefaults.standard
        let unresolved = (cue.recognitionConfidence ?? 1) < 0.45 && cue.recognitionWarning != nil
        var profile: [String] = [
            OllamaService.translationRevision, configuredTranslationModel,
            defaults.string(forKey: "ollamaURL") ?? "http://127.0.0.1:11434",
            "extra-notes:\(defaults.bool(forKey: "additionalAIStudyNotes"))",
            "source-unresolved:\(unresolved)", languageName, cue.text, cue.recognitionWarning ?? ""
        ]
        profile.append(contentsOf: context.before)
        profile.append("<after>")
        profile.append(contentsOf: context.after)
        let encoded = (try? JSONEncoder().encode(profile)) ?? Data()
        return SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
    }

    private func translate(_ cue: SubtitleCue, automatic: Bool) {
        if automatic && incrementalTranscription && autoTranscribe &&
            SentenceReadiness.needsContinuation(cue,span:chunkSeconds,duration:duration,completed:completedChunks) {
            scheduleChunk()
            return
        }
        let token = session
        let defaults = UserDefaults.standard
        let model = configuredTranslationModel
        let endpoint = defaults.string(forKey: "ollamaURL") ?? "http://127.0.0.1:11434"
        let sourceLanguage = languageName
        let context = translationContext(for: cue)
        let signature = translationSignature(for: cue)
        if let index = cues.firstIndex(where: { $0.id == cue.id }), cues[index].translationSignature != signature {
            cues[index].translation = nil; cues[index].annotations = nil; cues[index].translationWarning = nil
            cues[index].translationSignature = nil
            cues[index].translationModelUsed = nil
            cues[index].plainMeaning = nil
        }
        translationError = nil
        let requestToken = UUID(); translationToken = requestToken
        translating = true
        translationJob = Task {
            defer {
                if session == token && translationToken == requestToken {
                    translating = false
                    scheduleTranslation()
                }
            }
            do {
                let result = try await OllamaService.translateStudy(text: cue.text, before: context.before, after: context.after, model: model, endpoint: endpoint, language: sourceLanguage, sourceWarning: cue.recognitionWarning, sourceConfidence: cue.recognitionConfidence, session: translationSession, onTranslation: { [weak self] partial in
                    await self?.publishTranslation(partial, cue: cue, sessionToken: token, requestToken: requestToken, signature: signature, complete: false)
                }, includeAIStudyNotes: defaults.bool(forKey: "additionalAIStudyNotes"))
                try Task.checkCancellation()
                publishTranslation(result, cue: cue, sessionToken: token, requestToken: requestToken, signature: signature, complete: true)
            } catch is CancellationError { }
            catch {
                if session == token && translationToken == requestToken {
                    translationFailed = true
                    translationError = "自动翻译已暂停：\(error.localizedDescription)"
                    if automatic { status = "自动翻译已暂停：\(error.localizedDescription)" }
                    else { self.error = error.localizedDescription }
                }
            }
        }
    }

    private func publishTranslation(_ result: StudyTranslation, cue: SubtitleCue, sessionToken: UUID, requestToken: UUID, signature: String, complete: Bool) {
        guard session == sessionToken, translationToken == requestToken,
              let index = cues.firstIndex(where: { $0.id == cue.id }), cues[index].text == cue.text,
              translationSignature(for: cues[index]) == signature else { return }
        cues[index].translation = result.translation; cues[index].annotations = result.annotations
        cues[index].translationWarning = result.warning.isEmpty ? nil : result.warning
        cues[index].translationSignature = complete ? signature : nil
        cues[index].plainMeaning = result.plainMeaning
        cues[index].translationModelUsed = result.modelUsed
        save()
        updatePlaybackGate()
    }
}
