import SwiftUI
import AVKit

private let accent = Color(red: 0.97, green: 0.66, blue: 0.35)

@MainActor
final class PlaybackControlsVisibility: ObservableObject {
    @Published private(set) var visible = true
    private var hideTask: Task<Void, Never>?
    private let delay: UInt64
    init(delayNanoseconds: UInt64 = 2_000_000_000) { delay = delayNanoseconds }
    func reveal(canHide: Bool) {
        visible = true
        scheduleHide(allowed: canHide)
    }
    func scheduleHide(allowed: Bool) {
        cancel()
        guard allowed else { return }
        let delay = delay
        hideTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: delay) } catch { return }
            guard !Task.isCancelled else { return }
            self?.visible = false
        }
    }
    func cancel() { hideTask?.cancel(); hideTask = nil }
}

struct StudyView: View {
    @ObservedObject var model: StudyModel
    @StateObject private var chrome = PlaybackControlsVisibility()
    @State private var topBarHovered = false
    @State private var controlsHovered = false
    @State private var controlsEditing = false
    private var chromeVisible: Bool { chrome.visible }
    private var canHideChrome: Bool {
        model.videoURL != nil && !topBarHovered && !controlsHovered && !controlsEditing &&
        !showTranscript && !showControlAppearance && !showCoverSettings && !showLog &&
        editing == nil && studyingCue == nil && !editingCover && controlDragOrigin == nil
    }
    @State private var showTranscript = false
    @State private var showLog = false
    @State private var showCoverSettings = false
    @State private var editingCover = false
    @State private var resumeAfterCoverEdit = false
    @State private var coverGestureOrigin: CoverRegion?
    @State private var controlDragOrigin: CGPoint?
    @State private var controlHeight: CGFloat = 120
    @State private var showControlAppearance = false
    @State private var editing: SubtitleCue?
    @State private var studyingCue: SubtitleCue?
    @State private var studyingSelection: SubtitleWordSelection?
    @State private var subtitlesVisible = true
    @State private var originalVisible = true
    @State private var volume = 1.0
    @State private var window: NSWindow?
    @AppStorage("coverBurnedSubtitles") private var coverBurnedSubtitles = true
    @AppStorage("burnedSubtitleRegionLeft") private var coverLeft = 0.0
    @AppStorage("burnedSubtitleRegionWidth") private var coverWidth = 1.0
    @AppStorage("burnedSubtitleBandHeight") private var coverHeight = 0.18
    @AppStorage("burnedSubtitleBandBottom") private var coverBottom = 0.0
    @AppStorage("subtitleFontSize") private var subtitleSize = 28.0
    @AppStorage("playbackControlsMoved") private var controlsMoved = false
    @AppStorage("playbackControlsPositionX") private var controlsX = 0.5
    @AppStorage("playbackControlsPositionY") private var controlsY = 0.0
    @AppStorage("playbackControlsWidth") private var controlsWidth = 520.0
    @AppStorage("playbackControlsTransparency") private var controlsTransparency = 0.55
    @AppStorage("whisperModel") private var recognitionModel = LocalToolDefaults.model
    @AppStorage("recognitionEngine") private var recognitionEngine = "whisper"
    @AppStorage("qwenASRModel") private var qwenASRModel = LocalToolDefaults.qwenConfiguration["asr"] ?? ""
    @AppStorage("qwenAlignerModel") private var qwenAlignerModel = LocalToolDefaults.qwenConfiguration["aligner"] ?? ""
    private var currentCue: SubtitleCue? { model.cues.first { $0.id == model.displayID } }

    var body: some View {
        GeometryReader { geometry in
            let width = min(geometry.size.width, geometry.size.height * model.videoAspect)
            let height = width / model.videoAspect
            let regionBottom = (geometry.size.height-height)/2 + coverRegion.pixels(in: CGSize(width: width, height: height)).maxY
            let dockControlsAtTop = coverBurnedSubtitles && regionBottom > geometry.size.height - 140
            ZStack {
                Color.black
                if model.videoURL != nil {
                    ZStack(alignment: .topLeading) {
                        NativePlayerView(player: model.player)
                        Color.clear.contentShape(Rectangle())
                            .onTapGesture(count: 2) { window?.toggleFullScreen(nil) }
                            .onTapGesture { model.togglePlay(); revealChrome() }
                            .allowsHitTesting(!editingCover)
                        if coverBurnedSubtitles {
                            coverOverlay(in: CGSize(width: width, height: height))
                        } else if subtitlesVisible, let cue = currentCue {
                            VStack { Spacer(); captions(cue, width: width).padding(.horizontal, 32).padding(.bottom, 32) }
                        }
                    }.frame(width: width, height: height).coordinateSpace(name: "movie")
                } else { emptyState }
                if !editingCover {
                VStack(spacing: 0) {
                    topBar.onHover { hovering in topBarHovered = hovering; if hovering { revealChrome() } else { scheduleHide() } }
                        .padding(.top, 12).padding(.horizontal, 22).padding(.bottom, 28)
                        .background(LinearGradient(colors: [.black.opacity(0.75), .clear], startPoint: .top, endPoint: .bottom))
                    Spacer()
                }
                .opacity(chromeVisible || model.videoURL == nil ? 1 : 0)
                .allowsHitTesting(chromeVisible || model.videoURL == nil)
                .animation(.easeInOut(duration: 0.2), value: chromeVisible)
                if model.videoURL != nil {
                    floatingControls(in: geometry.size, defaultAtTop: dockControlsAtTop)
                        .opacity(chromeVisible ? 1 : 0).allowsHitTesting(chromeVisible)
                        .animation(.easeInOut(duration: 0.2), value: chromeVisible)
                }
                } else {
                    VStack {
                        HStack(spacing: 16) {
                            Label("拖动区域移动 · 拖动四角缩放", systemImage: "move.3d").font(.callout)
                            Spacer()
                            Button("重置") { resetCover() }
                            Button("完成") { finishCoverEditing() }.buttonStyle(.borderedProminent)
                        }.padding(16).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12)).padding(.horizontal, 24).padding(.top, 46)
                        Spacer()
                    }
                }
                if !editingCover && model.waitingForSubtitles {
                    VStack {
                        Spacer()
                        HStack(spacing: 12) {
                            let failed = model.subtitleWaitReason == .original ? model.subtitlePreparationFailed : model.translationFailed
                            if !failed { ProgressView().controlSize(.small) }
                            Text(model.waitingMessage).font(.caption).lineLimit(2)
                            if failed && model.subtitleWaitReason == .original { Button("重试识别", action: model.transcribe) }
                            else if failed { Button("重试翻译", action: model.translateCurrent) }
                            Button("取消等待", action: model.pausePlayback)
                            Button("不等待字幕") { model.waitForSubtitles = false }
                        }.padding(12).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                            .padding(.horizontal, 24).padding(.bottom, 140)
                    }
                }
                if !editingCover && !model.waitingForSubtitles && model.videoURL != nil && !model.busy && (model.subtitlePreparationFailed || model.translationFailed) {
                    VStack {
                        Spacer()
                        HStack(spacing: 12) {
                            Text(model.translationFailed ? (model.translationError ?? model.status) : model.subtitlePreparationFailed ? model.status : "正在准备当前位置的原文字幕…")
                                .font(.caption).foregroundStyle(.white.opacity(0.85)).lineLimit(2)
                            if model.subtitlePreparationFailed {
                                Button("重新生成", action: model.transcribe)
                                SettingsLink { Text("模型设置") }
                            } else if model.translationFailed {
                                Button("重试翻译", action: model.translateCurrent)
                            }
                        }.buttonStyle(.plain).padding(.horizontal, 28)
                            .padding(.bottom, chromeVisible ? 145 : 40)
                    }
                }
            }
            .coordinateSpace(name: "playerWindow")
            .background(WindowProbe { window = $0 })
            .onContinuousHover { phase in
                if case .active = phase { revealChrome() }
                else { scheduleHide() }
            }
        }
        .ignoresSafeArea().background(.black).tint(accent)
        .onAppear { revealChrome() }
        .onChange(of: model.playRequested) { _, _ in revealChrome() }
        .onChange(of: model.videoURL) { _, _ in revealChrome() }
        .onChange(of: recognitionModel) { _, _ in model.reloadRecognitionConfiguration() }
        .onChange(of: recognitionEngine) { _, _ in model.reloadRecognitionConfiguration() }
        .onChange(of: qwenASRModel) { _, _ in model.reloadRecognitionConfiguration() }
        .onChange(of: qwenAlignerModel) { _, _ in model.reloadRecognitionConfiguration() }
        .onChange(of: showTranscript) { _, _ in revealChrome() }
        .onChange(of: showControlAppearance) { _, _ in revealChrome() }
        .onChange(of: showCoverSettings) { _, _ in revealChrome() }
        .onChange(of: showLog) { _, _ in revealChrome() }
        .onChange(of: editing) { _, _ in revealChrome() }
        .onChange(of: studyingCue) { _, _ in revealChrome() }
        .onExitCommand { if editingCover { finishCoverEditing() } }
        .onDisappear { chrome.cancel() }
        .alert("需要处理", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("好") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .sheet(isPresented: $showTranscript) { transcript }
        .sheet(isPresented: $showCoverSettings) {
            VStack(alignment: .leading, spacing: 20) {
                HStack { Text("原字幕遮挡区域").font(.headline); Spacer(); Button("关闭") { showCoverSettings = false } }
                Toggle("遮挡视频画面内的原字幕", isOn: $coverBurnedSubtitles)
                Text("这是播放时的遮挡，不会修改视频，也不能恢复原字幕覆盖的画面。关闭新字幕时，遮挡仍保留。").font(.caption).foregroundStyle(.secondary)
                Text("遮挡高度：\(Int(coverHeight * 100))%")
                Slider(value: $coverHeight, in: 0.08...1)
                Text("水平宽度：\(Int(coverWidth * 100))%")
                Slider(value: $coverWidth, in: 0.18...1)
                Text("水平位置：\(Int(coverLeft * 100))%")
                Slider(value: $coverLeft, in: 0...max(0.001, 1-coverWidth))
                Text("距画面底部：\(Int(coverBottom * 100))%")
                Slider(value: $coverBottom, in: 0...max(0.001, 1-coverHeight))
                Button("恢复底部默认区域") { resetCover() }
                Text("通过右上角字幕菜单切换遮挡，可以对照原画面校正区域。调整的是视频区域，窗口和全屏会同步缩放。").font(.caption).foregroundStyle(.secondary)
            }.padding(24).frame(width: 520)
        }
        .sheet(isPresented: $showLog) {
            VStack(alignment: .leading, spacing: 16) {
                HStack { Text("任务日志").font(.headline); Spacer(); Button("关闭") { showLog = false } }
                ScrollView { Text(model.taskLog.isEmpty ? model.status : model.taskLog).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            }.padding(24).frame(width: 650, height: 400)
        }
        .sheet(item: $editing) { cue in
            SubtitleEditor(cue: cue, onSave: { text in model.edit(cue.id, text: text); editing = nil; model.translateCurrent() }, onCancel: { editing = nil })
        }
    }

    private func floatingControls(in viewport: CGSize, defaultAtTop: Bool) -> some View {
        let bounds = CGRect(x: 24, y: 64, width: max(1, viewport.width-48), height: max(1, viewport.height-86))
        let panelSize = CGSize(width: min(max(420, min(740, controlsWidth)), bounds.width), height: controlHeight)
        let position = FloatingControlPosition(x: controlsMoved ? controlsX : 0.5, y: controlsMoved ? controlsY : defaultAtTop ? 0 : 1)
        let center = position.center(in: bounds, panelSize: panelSize)
        return controls {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal")
                Text("拖动控制区").font(.system(size: 10))
            }.foregroundStyle(.white.opacity(0.55))
                .frame(maxWidth: .infinity).frame(height: 14).contentShape(Rectangle())
                .help("拖动此处移动播放控制区；双击恢复默认位置")
                .accessibilityLabel("拖动播放控制区")
                .highPriorityGesture(DragGesture(minimumDistance: 2, coordinateSpace: .named("playerWindow"))
                    .onChanged { value in
                        if controlDragOrigin == nil { controlDragOrigin = center }
                        guard let origin = controlDragOrigin else { return }
                        revealChrome()
                        let target = CGPoint(x: origin.x+value.translation.width, y: origin.y+value.translation.height)
                        let next = FloatingControlPosition.at(target, in: bounds, panelSize: panelSize)
                        controlsX = next.x; controlsY = next.y; controlsMoved = true
                    }.onEnded { _ in controlDragOrigin = nil; scheduleHide() })
                .simultaneousGesture(TapGesture(count: 2).onEnded { resetControlPosition() })
                .contextMenu {
                    Button("控制区大小与透明度…") { showControlAppearance = true }
                    Button("恢复控制区默认位置", action: resetControlPosition)
                }
        }
        .frame(width: panelSize.width)
        .background(GeometryReader { proxy in Color.clear.preference(key: ControlHeightKey.self, value: proxy.size.height) })
        .onPreferenceChange(ControlHeightKey.self) { if $0 > 0 && abs(controlHeight-$0) > 0.5 { controlHeight = $0 } }
        .onHover { hovering in controlsHovered = hovering; if hovering { revealChrome() } else { scheduleHide() } }
        .position(center)
    }

    private func resetControlPosition() {
        controlDragOrigin = nil; controlsMoved = false; controlsX = 0.5; controlsY = 0
        revealChrome()
    }

    private var coverRegion: CoverRegion {
        CoverRegion(x: coverLeft, y: 1-coverBottom-coverHeight, width: coverWidth, height: coverHeight).clamped()
    }
    private func storeCover(_ region: CoverRegion) {
        let value = region.clamped()
        coverLeft = value.x; coverWidth = value.width; coverHeight = value.height
        coverBottom = max(0, 1-value.y-value.height)
    }
    private func resetCover() { storeCover(CoverRegion(x: 0, y: 0.82, width: 1, height: 0.18)) }
    private func startCoverEditing() {
        resumeAfterCoverEdit = model.playRequested || model.playing
        editingCover = true; coverBurnedSubtitles = true; originalVisible = true
        chrome.cancel(); model.pausePlayback()
    }
    private func finishCoverEditing() {
        coverGestureOrigin = nil; editingCover = false
        if resumeAfterCoverEdit { model.requestPlay() }
        resumeAfterCoverEdit = false; revealChrome()
    }
    private func coverOverlay(in videoSize: CGSize) -> some View {
        let rect = coverRegion.pixels(in: videoSize)
        return ZStack(alignment: .topLeading) {
            Color.black
            if subtitlesVisible || editingCover {
                InsideCoverCaptions(cue: currentCue, preview: editingCover, originalVisible: originalVisible, requestedSize: subtitleSize, size: rect.size, translationPending: model.waitForSubtitles && model.autoTranslate && !model.translationFailed,
                    onInteraction: { model.pausePlayback() }, onSelectWord: editingCover ? nil : { selection in
                        if let cue = currentCue { studyWord(cue, selection: selection) }
                    })
            }
            if editingCover {
                Rectangle().stroke(accent, lineWidth: 2)
                ForEach(Array(CoverRegion.Corner.allCases.enumerated()), id: \.offset) { _, corner in
                    let left = corner == .topLeft || corner == .bottomLeft
                    let top = corner == .topLeft || corner == .topRight
                    RoundedRectangle(cornerRadius: 3).fill(accent).frame(width: 16, height: 16)
                        .position(x: left ? 8 : rect.width-8, y: top ? 8 : rect.height-8)
                        .help("拖动调整遮挡区域大小")
                        .highPriorityGesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("movie"))
                            .onChanged { value in
                                if coverGestureOrigin == nil { coverGestureOrigin = coverRegion }
                                if let origin = coverGestureOrigin { storeCover(origin.resized(corner, by: value.translation, in: videoSize)) }
                            }.onEnded { _ in coverGestureOrigin = nil })
                }
            }
        }
        .frame(width: rect.width, height: rect.height)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("movie"))
            .onChanged { value in
                guard editingCover else { return }
                if coverGestureOrigin == nil { coverGestureOrigin = coverRegion }
                if let origin = coverGestureOrigin { storeCover(origin.moved(by: value.translation, in: videoSize)) }
            }.onEnded { _ in coverGestureOrigin = nil })
        .allowsHitTesting(editingCover)
        .position(x: rect.midX, y: rect.midY)
    }

    func captions(_ cue: SubtitleCue, width: Double) -> some View {
        let size = min(subtitleSize, max(18, width / 28))
        return VStack(spacing: 8) {
            if originalVisible {
                SelectableSubtitleText(text: cue.displayOriginal, fontSize: cue.translation == nil ? size : size * 0.72,
                    color: .white.withAlphaComponent(0.92), onInteraction: { model.pausePlayback() },
                    onSelect: cue.displayOriginal == cue.text ? { studyWord(cue, selection: $0) } : nil)
                    .shadow(color: .black, radius: 2, x: 0, y: 1)
            }
            if let translated = cue.translation {
                CaptionText(text: translated, size: size, color: .white)
            }
            if cue.translation == nil && model.waitForSubtitles && model.autoTranslate && !model.translationFailed {
                Text("正在准备中文译文…").font(.system(size: 11)).foregroundStyle(.white.opacity(0.7)).shadow(color: .black, radius: 2)
            } else if cue.translation == nil && !originalVisible && model.waitForSubtitles {
                Text("暂无中文译文").font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
            }
            if let title = cue.studyWarningTitle {
                Label(title, systemImage: "exclamationmark.bubble").font(.system(size: 11)).foregroundStyle(accent)
            }
        }.frame(maxWidth: width * 0.88)
    }

    var emptyState: some View {
        VStack(spacing: 22) {
            Image(systemName: "play.rectangle").font(.system(size: 56, weight: .ultraLight)).foregroundStyle(.white.opacity(0.65))
            Text("打开视频，沉浸学习").font(.system(size: 24, weight: .medium))
            Text("原文与中文译文，直接呈现在画面中").foregroundStyle(.secondary)
            Button(action: model.openVideo) {
                Label("打开本地视频", systemImage: "folder").padding(.horizontal, 22).padding(.vertical, 12).background(.white.opacity(0.12), in: Capsule())
            }.buttonStyle(.plain)
            Text("⌘O · MP4 / MOV").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func studyWord(_ cue: SubtitleCue, selection: SubtitleWordSelection) {
        guard selection.isValid(in: cue.text), cue.displayOriginal == cue.text else { return }
        model.pausePlayback(); studyingSelection = selection; studyingCue = cue; revealChrome()
    }

    var topBar: some View {
        HStack(spacing: 18) {
            // Leave room for the native window buttons.
            Text(model.videoURL?.lastPathComponent ?? "Immersive Learning Player").font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.8)).lineLimit(1).padding(.leading, 68)
            Spacer()
            if let cue = currentCue {
                Button {
                    model.pausePlayback(); studyingSelection = nil; studyingCue = cue
                } label: {
                    Label("语境学习", systemImage: "text.book.closed")
                        .font(.caption).foregroundStyle(accent)
                }.help("暂停并结合前后对白学习背景、用词和替换说法")
                    .popover(item: $studyingCue, arrowEdge: .top) { StudyNotesView(model: model, originalCue: $0, initialSelection: studyingSelection) }
            }
            if model.translating || model.busy { ProgressView().controlSize(.small).help("字幕和翻译在后台生成，不影响视频播放") }
            Button(action: model.openVideo) { Image(systemName: "folder") }.help("打开视频 ⌘O")
            Menu {
                Button("从日语音频重建原文", action: model.rebuildJapaneseFromAudio).disabled(model.videoURL == nil)
                Toggle("原文来自音频（忽略已有中文字幕）", isOn: Binding(get: { model.audioOnly }, set: { model.chooseAudioSource($0) }))
                Button("导入原文字幕…", action: model.chooseSubtitle).disabled(model.videoURL == nil || model.busy)
                Button("重新生成字幕", action: model.transcribe).disabled(model.videoURL == nil || model.busy)
                Picker("当前视频识别语言", selection: Binding(get: { model.language }, set: { model.chooseRecognitionLanguage($0) })) {
                    Text("自动识别").tag("auto"); Text("日语").tag("ja"); Text("韩语").tag("ko"); Text("英语").tag("en"); Text("中文").tag("zh")
                }.disabled(model.busy || model.videoURL == nil)
                Text("语言按视频分别记忆，新视频默认自动识别").font(.caption).foregroundStyle(.secondary)
                Divider()
                Toggle("随播放分段生成字幕", isOn: $model.autoTranscribe)
                Toggle("等待字幕再播放（学习模式）", isOn: $model.waitForSubtitles)
                Toggle("逐句停顿学习（空格继续）", isOn: $model.pauseAfterSentence)
                Menu("原文识别模型") {
                    Button(recognitionEngine == "qwen3-asr" ? "✓ Qwen3-ASR 1.7B · 推荐" : "Qwen3-ASR 1.7B · 推荐") { recognitionEngine = "qwen3-asr" }
                    if let large = Bundle.main.url(forResource: "ggml-large-v3", withExtension: "bin", subdirectory: "Models") {
                        Button(recognitionEngine == "whisper" && recognitionModel == large.path ? "✓ Whisper Large v3" : "Whisper Large v3") { recognitionModel = large.path; recognitionEngine = "whisper" }
                    }
                    if let small = Bundle.main.url(forResource: "ggml-small", withExtension: "bin", subdirectory: "Models") {
                        Button(recognitionEngine == "whisper" && recognitionModel == small.path ? "✓ 快速 · Small" : "快速 · Small") { recognitionModel = small.path; recognitionEngine = "whisper" }
                    }
                }
                Picker("短句阅读停留", selection: $model.readingHoldSeconds) {
                    Text("关闭").tag(0.0); Text("1.5 秒").tag(1.5); Text("2.5 秒（默认）").tag(2.5); Text("4 秒").tag(4.0)
                }
                Toggle("遮挡画面内原字幕", isOn: $coverBurnedSubtitles)
                Button("在画面中拖动调整遮挡区域") { startCoverEditing() }.disabled(model.videoURL == nil)
                Button("遮挡区域数值设置…") { showCoverSettings = true }
                Toggle("显示字幕", isOn: $subtitlesVisible)
                Toggle("同时显示原文", isOn: $originalVisible)
                Toggle("自动翻译当前及后两句", isOn: $model.autoTranslate)
                Button("翻译当前句 / 重试", action: model.translateCurrent).disabled(currentCue == nil || model.translating)
                if let cue = currentCue {
                    Button("语境与用词解析…") { model.pausePlayback(); studyingSelection = nil; studyingCue = cue }
                }
                if let cue = currentCue { Button("修改当前字幕…") { editing = cue } }
                Button("字幕列表与时间校正…") { showTranscript = true }
                Menu("字幕字号") { ForEach([22.0, 28, 34, 40], id: \.self) { size in Button("\(Int(size)) pt") { subtitleSize = size } } }
                Button("导出字幕…", action: model.exportSubtitle).disabled(model.cues.isEmpty)
                Divider()
                Button("播放控制区大小与透明度…") { showControlAppearance = true }.disabled(model.videoURL == nil)
                Button("恢复播放控制区默认位置", action: resetControlPosition)
                if model.busy { Button("暂停字幕生成", action: model.cancelWork) }
                Button("任务状态与日志…") { showLog = true }
                SettingsLink { Text("本地模型设置…") }
            } label: { Image(systemName: "captions.bubble") }.menuStyle(.borderlessButton).fixedSize().help("字幕与翻译")
            Button { window?.toggleFullScreen(nil) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }.help("全屏")
        }.buttonStyle(.plain).foregroundStyle(.white)
    }

    func controls<Handle: View>(@ViewBuilder handle: () -> Handle) -> some View {
        let backgroundOpacity = 1-max(0, min(1, controlsTransparency))
        return VStack(spacing: 4) {
            handle()
            HStack(spacing: 8) {
                Text(SubtitleCodec.clock(model.currentTime)).font(.system(size: 11).monospacedDigit()).frame(width: 44)
                Slider(value: Binding(get: { model.currentTime }, set: { model.seek($0); revealChrome() }), in: 0...max(1, model.duration), onEditingChanged: controlsEditingChanged)
                    .controlSize(.small).accessibilityLabel("播放进度")
                Text(SubtitleCodec.clock(model.duration)).font(.system(size: 11).monospacedDigit()).foregroundStyle(.white.opacity(0.75)).frame(width: 44)
            }.frame(height: 18)
            HStack(spacing: 10) {
                Image(systemName: volume == 0 ? "speaker.slash" : "speaker.wave.2").foregroundStyle(.white.opacity(0.75))
                Slider(value: $volume, in: 0...1, onEditingChanged: controlsEditingChanged).controlSize(.small).frame(width: 56).accessibilityLabel("音量").onChange(of: volume) { _, value in model.player.volume = Float(value) }
                Spacer()
                Button { model.moveSentence(-1); revealChrome() } label: { Image(systemName: "backward.end.fill").frame(width: 28, height: 28) }.help("上一句 ⌘←")
                Button { model.togglePlay(); revealChrome() } label: { Image(systemName: model.playRequested || model.playing ? "pause.fill" : "play.fill").font(.system(size: 20)).frame(width: 28, height: 28) }.help(model.waitingForSubtitles ? "取消等待并暂停 空格" : "播放 / 暂停 空格")
                Button { model.moveSentence(1); revealChrome() } label: { Image(systemName: "forward.end.fill").frame(width: 28, height: 28) }.help("下一句 ⌘→")
                Spacer()
                Button { model.toggleLoop(); revealChrome() } label: { Image(systemName: "repeat.1").foregroundStyle(model.repeatSentence ? accent : .white).frame(width: 28, height: 28) }.disabled(model.selectedCue == nil).help("单句循环 ⌘R")
                Menu {
                    ForEach([Float(0.5), 0.75, 1, 1.25, 1.5, 2], id: \.self) { value in Button(String(format: "%g×", value)) { model.changeSpeed(value) } }
                } label: { Text(String(format: "%g×", model.speed)).font(.caption.monospacedDigit()) }.menuStyle(.borderlessButton).fixedSize()
                Button { showControlAppearance.toggle() } label: { Image(systemName: "slider.horizontal.3").frame(width: 28, height: 28) }
                    .help("控制区大小与透明度").accessibilityLabel("控制区外观")
                    .popover(isPresented: $showControlAppearance) { controlAppearance }
            }.buttonStyle(.plain)
        }.font(.system(size: 12)).foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.black.opacity(backgroundOpacity), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.16*backgroundOpacity)))
    }

    private var controlAppearance: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("播放控制区").font(.headline); Spacer(); Button("完成") { showControlAppearance = false } }
            Text("宽度：\(Int(controlsWidth)) pt").font(.caption.monospacedDigit())
            Slider(value: $controlsWidth, in: 420...740, step: 10).accessibilityLabel("控制区宽度")
            Text("背景透明度：\(Int((controlsTransparency*100).rounded()))%").font(.caption.monospacedDigit())
            Slider(value: $controlsTransparency, in: 0...1, step: 0.05).accessibilityLabel("控制区背景透明度")
            Text("透明度越高，画面越清晰；按钮与文字保持可见。").font(.caption).foregroundStyle(.secondary)
            Button("恢复默认外观") { controlsWidth = 520; controlsTransparency = 0.55 }
        }.padding(18).frame(width: 300).foregroundStyle(.primary)
    }

    var transcript: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("字幕与时间校正").font(.headline); Spacer(); Button("关闭") { showTranscript = false } }
            HStack {
                Text("时间偏移")
                Button("−0.2s") { model.offset -= 0.2 }
                Text(String(format: "%+.1fs", model.offset)).monospacedDigit()
                Button("+0.2s") { model.offset += 0.2 }
                Button("重置") { model.offset = 0 }
                Spacer(); Text("\(model.cues.count) 句").foregroundStyle(.secondary)
            }.font(.caption)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(model.cues) { cue in
                        Button { model.select(cue); showTranscript = false } label: {
                            HStack(alignment: .top, spacing: 16) {
                                Text(SubtitleCodec.clock(cue.start)).font(.caption.monospaced()).foregroundStyle(accent)
                                VStack(alignment: .leading, spacing: 6) { Text(cue.text); if let translation = cue.translation { Text(translation).foregroundStyle(.secondary) } }.frame(maxWidth: .infinity, alignment: .leading)
                            }.padding(12).background(.white.opacity(model.activeID == cue.id ? 0.1 : 0.03), in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain)
                    }
                }
            }
            if model.cues.isEmpty { Text("导入 SRT / VTT 或生成字幕后，即可逐句跳转。").foregroundStyle(.secondary) }
        }.padding(24).frame(width: 620, height: 480)
    }

    private func controlsEditingChanged(_ editing: Bool) {
        controlsEditing = editing
        revealChrome()
    }
    func revealChrome() { chrome.reveal(canHide: canHideChrome) }
    func scheduleHide() { chrome.scheduleHide(allowed: canHideChrome) }

}

private func annotatedSubtitle(_ text: String, notes: [StudyAnnotation]) -> AttributedString {
    var result = AttributedString(text)
    for note in StudyExpressionGuide.referenceNotes(from: notes, in: text) {
        if let range = result.range(of: note.expression) {
            result[range].foregroundColor = accent
            result[range].underlineStyle = .single
        }
    }
    return result
}

struct StudyNotesView: View {
    @ObservedObject var model: StudyModel
    let originalCue: SubtitleCue
    private var cue: SubtitleCue { model.cues.first(where: { $0.id == originalCue.id }) ?? originalCue }
    private var lines: [ContextStudyLine] { model.contextStudyLines(for: cue.id) }
    @State private var showDrafts = false
    @State private var selection: SubtitleWordSelection?
    @State private var comparisonInput = ""
    @State private var submittedComparison: String?
    init(model: StudyModel, originalCue: SubtitleCue, initialSelection: SubtitleWordSelection? = nil) {
        self.model = model; self.originalCue = originalCue; _selection = State(initialValue: initialSelection)
    }
    private var result: ContextStudy? { model.contextStudyResult(for: cue.id, selection: selection, comparison: submittedComparison) }
    private var requestID: String { "\(cue.id)|\(selection?.location ?? -1)|\(selection?.length ?? 0)|\(selection?.expression ?? "")|\(submittedComparison ?? "")" }
    private func selectWord(_ value: SubtitleWordSelection) {
        selection = value; comparisonInput = ""; submittedComparison = nil
    }
    private func compareWord() {
        let value = comparisonInput.trimmingCharacters(in: .whitespacesAndNewlines)
        submittedComparison = value.isEmpty ? nil : value
        model.studyContext(cue.id, selection: selection, comparison: submittedComparison, refresh: true)
    }
    private var references: [StudyAnnotation] { StudyExpressionGuide.notes(in: cue.text) }
    private var drafts: [StudyAnnotation] { (cue.annotations ?? []).filter { !references.contains($0) } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(selection.map { "选词学习 · \($0.expression)" } ?? "这句怎么理解").font(.headline)
                SelectableSubtitleText(text: cue.displayOriginal, fontSize: 16, color: .labelColor, alignment: .left,
                    selection: selection, onInteraction: { model.pausePlayback() }, onSelect: cue.displayOriginal == cue.text ? selectWord : nil)
                Text("点击原文中的词，或拖选短语；也可在视频字幕上直接选词。").font(.caption).foregroundStyle(.secondary)
                if selection != nil {
                    HStack {
                        TextField("想对比的源语言近义词（可选）", text: $comparisonInput).onSubmit(compareWord)
                        Button("对比", action: compareWord).disabled(comparisonInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("整句解析") { selection = nil; submittedComparison = nil; comparisonInput = "" }
                    }
                }
                if let translation = cue.translation { Text(translation).foregroundStyle(.secondary) }
                contextLearning
                if !references.isEmpty { Text(references.map(\.meaning).joined(separator: " ")).font(.callout) }
                if let warning = cue.studyWarning {
                    Label(warning, systemImage: "questionmark.bubble").font(.callout).foregroundStyle(accent)
                    Text("可在字幕菜单中修改原文，再重新翻译。").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(Array(references.enumerated()), id: \.offset) { _, note in
                    Divider()
                    HStack { Text(note.expression).font(.headline); Text(note.kind).font(.caption).padding(.horizontal, 6).padding(.vertical, 3).background(accent.opacity(0.15), in: Capsule()) }.foregroundStyle(accent)
                    Text(note.meaning).font(.body)
                    if !note.usage.isEmpty { Text(note.usage).font(.callout).foregroundStyle(.secondary) }
                    if let source = note.sourceURL, let url = URL(string: source) { Link("常见词义参考", destination: url).font(.caption) }
                }
                if !drafts.isEmpty || (references.isEmpty && cue.plainMeaning != nil) {
                    DisclosureGroup("AI 尝试解释（未核对）", isExpanded: $showDrafts) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("可能误解原话、反转比较关系或把普通句子误判为俗语。以下内容尚不能作为确定的学习释义。").font(.caption).foregroundStyle(accent)
                            if references.isEmpty, let meaning = cue.plainMeaning { Text(meaning).font(.callout) }
                            ForEach(Array(drafts.enumerated()), id: \.offset) { _, note in
                                Text(note.expression).font(.headline)
                                Text("模型建议分类：\(note.kind)").font(.caption).foregroundStyle(.secondary)
                                Text(note.meaning).font(.callout)
                                if !note.usage.isEmpty { Text(note.usage).font(.callout).foregroundStyle(.secondary) }
                            }
                        }.padding(.top, 8)
                    }.font(.callout)
                }
                Text("有来源的条目是已核对的常见义；其他 AI 注释默认折叠。语境推断与改写仍需对照原文。").font(.caption2).foregroundStyle(.secondary)
            }.padding(20).textSelection(.enabled)
        }.frame(width: 520, height: 600).foregroundStyle(.primary)
            .task(id: requestID) { model.studyContext(originalCue.id, selection: selection, comparison: submittedComparison) }
            .onDisappear { model.cancelContextStudy() }
    }

    @ViewBuilder private var contextLearning: some View {
        Divider()
        Label(result?.referenceOnly == true ? "本地词义参考 · 按所给对白保守解释" : "本地 AI 语境推断 · 可展开原话核对", systemImage: result?.referenceOnly == true ? "book" : "sparkles").font(.caption).foregroundStyle(.secondary)
        DisclosureGroup("前后对白对照（最多前 3 句、后 2 句）") {
            ForEach(lines) { line in
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(line.isCurrent ? "当前句" : (line.start < cue.start ? "前文" : "后文")) · \(Int(line.start)/60):\(String(format: "%02d", Int(line.start)%60))")
                        .font(.caption).foregroundStyle(line.isCurrent ? accent : .secondary)
                    Text(line.text).font(.callout)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
            }
        }
        if model.contextStudyCueID == cue.id {
            HStack { ProgressView().controlSize(.small); Text("本地模型正在分析对白语境…").font(.callout) }
        }
        if let error = model.contextStudyError { Text(error).font(.callout).foregroundStyle(accent) }
        if let result {
            Text(result.referenceOnly == true ? "所给对白能支持的背景" : "这句话的背景（对白推断）").font(.headline)
            Text(result.background).font(.callout)
            Text("说话的用意与语气").font(.headline)
            Text(result.intent).font(.callout)
            DisclosureGroup("查看解析引用的原话") {
                ForEach(Array(result.evidence.enumerated()), id: \.offset) { _, evidence in
                    if let line = lines.first(where: { $0.id == evidence.cueID }) {
                        Text("\(line.isCurrent ? "当前句" : "上下文") · \(Int(line.start)/60):\(String(format: "%02d", Int(line.start)%60))  \(evidence.quote)")
                            .font(.caption).padding(.vertical, 3)
                    }
                }
            }
            ForEach(Array(result.words.enumerated()), id: \.offset) { _, word in
                Divider()
                Text(word.expression).font(.headline).foregroundStyle(accent)
                Text("在这里：\(word.meaning)").font(.callout)
                Text("为何这样用：\(word.reason)").font(.callout)
                if let replacement = word.replacement {
                    Text("\(word.expression) → \(replacement)").font(.callout).foregroundStyle(accent)
                    if let fit = word.replacementFit { Text(fit).font(.caption).foregroundStyle(fit == "不宜直接替换" ? accent : .secondary) }
                }
                Text(result.referenceOnly == true ? "替换实验 · 词义参考，非视频原话" : "替换实验 · AI 生成，需核对").font(.caption).foregroundStyle(.secondary)
                Text(word.alternative).font(.callout).italic()
                Text("对比：\(word.difference)").font(.callout)
            }
            if !result.uncertainty.isEmpty {
                Text("还不能确定：\(result.uncertainty)").font(.callout).foregroundStyle(accent)
            }
            ForEach(result.referenceURLs ?? [], id: \.self) { source in
                if let url = URL(string: source) { Link("查看词典依据", destination: url).font(.caption) }
            }
        }
        Text("本地 AI 根据对白生成，未读取画面；背景与用词解释可能有误，可对照引用复听。后文可能透露接下来的内容。")
            .font(.caption).foregroundStyle(.secondary)
        HStack {
            Button(result == nil ? "重试语境解析" : "重新解析") { model.studyContext(cue.id, selection: selection, comparison: submittedComparison, refresh: true) }
                .disabled(model.contextStudyCueID != nil)
            if model.contextStudyCueID == cue.id { Button("取消") { model.cancelContextStudy() } }
        }
    }

}

private struct ControlHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 120
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

// Native text layout provides exact glyph hit testing, word clicks and phrase dragging.
struct SelectableSubtitleText: NSViewRepresentable {
    let text: String
    let fontSize: Double
    var color: NSColor = .white
    var alignment: NSTextAlignment = .center
    var lineLimit: Int = 0
    var selection: SubtitleWordSelection? = nil
    var onInteraction: (() -> Void)? = nil
    var onSelect: ((SubtitleWordSelection) -> Void)?
    func makeNSView(context: Context) -> SubtitleWordTextView {
        let view = SubtitleWordTextView()
        view.isEditable = false; view.isSelectable = true; view.drawsBackground = false
        view.isVerticallyResizable = false; view.isHorizontallyResizable = false
        view.textContainerInset = .zero; view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true; view.textContainer?.heightTracksTextView = false
        view.focusRingType = .none; view.usesFindPanel = false
        view.selectedTextAttributes = [.backgroundColor: NSColor.systemTeal.withAlphaComponent(0.4), .foregroundColor: NSColor.white]
        view.setAccessibilityHelp("点击选词；拖选短语；键盘选中后按回车进行语境学习")
        return view
    }
    func updateNSView(_ view: SubtitleWordTextView, context: Context) {
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = alignment; paragraph.lineSpacing = 3
        let rendered = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: color, .paragraphStyle: paragraph])
        if view.attributedString() != rendered {
            let changedText = view.string != text
            view.textStorage?.setAttributedString(rendered)
            if changedText { view.setSelectedRange(NSRange(location: 0, length: 0)) }
        }
        view.textContainer?.maximumNumberOfLines = lineLimit
        view.textContainer?.lineBreakMode = lineLimit > 0 ? .byTruncatingTail : .byWordWrapping
        view.onInteraction = onInteraction; view.onSelectWord = onSelect
        if let selection, selection.isValid(in: text), view.selectedRange() != selection.range { view.setSelectedRange(selection.range) }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SubtitleWordTextView, context: Context) -> CGSize? {
        let width = max(1, proposal.width ?? 480)
        nsView.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        if let container = nsView.textContainer { nsView.layoutManager?.ensureLayout(for: container) }
        var height = fontSize*1.4
        if let container = nsView.textContainer, let manager = nsView.layoutManager { height = manager.usedRect(for: container).height }
        return CGSize(width: width, height: ceil(max(fontSize*1.2, height)))
    }
}

final class SubtitleWordTextView: NSTextView {
    var onInteraction: (() -> Void)?
    var onSelectWord: ((SubtitleWordSelection) -> Void)?
    func characterOffset(at point: NSPoint) -> Int? {
        guard let layout = layoutManager, let container = textContainer else { return nil }
        layout.ensureLayout(for: container)
        let point = NSPoint(x: point.x-textContainerOrigin.x, y: point.y-textContainerOrigin.y)
        guard layout.usedRect(for: container).contains(point) else { return nil }
        let glyph = layout.glyphIndex(for: point, in: container)
        guard glyph < layout.numberOfGlyphs, layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(point) else { return nil }
        let truncated = layout.truncatedGlyphRange(inLineFragmentForGlyphAt: glyph)
        guard truncated.location == NSNotFound || !NSLocationInRange(glyph, truncated) else { return nil }
        return layout.characterIndexForGlyph(at: glyph)
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard onSelectWord != nil, characterOffset(at: convert(point, from: superview)) != nil else { return nil }
        return super.hitTest(point)
    }
    override func mouseDown(with event: NSEvent) {
        guard onSelectWord != nil, let offset = characterOffset(at: convert(event.locationInWindow, from: nil)) else { return }
        let original = string
        onInteraction?() // Freeze the video before tracking a drag or a double click.
        super.mouseDown(with: event)
        guard string == original else { return }
        let selected = selectedRange().length > 0 ? SubtitleWordSelection.selected(in: original, range: selectedRange()) : SubtitleWordSelection.word(in: original, atUTF16: offset)
        if let selected { setSelectedRange(selected.range); onSelectWord?(selected) }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76,
           let selected = SubtitleWordSelection.selected(in: string, range: selectedRange()) {
            onInteraction?(); onSelectWord?(selected)
        } else { super.keyDown(with: event) }
    }
}

struct CaptionText: View {
    let text: String
    let size: Double
    let color: Color
    var annotations: [StudyAnnotation] = []
    var body: some View {
        Text(annotatedSubtitle(text, notes: annotations)).font(.system(size: size, weight: .semibold))
            .foregroundStyle(color).multilineTextAlignment(.center).lineSpacing(4)
            .shadow(color: .black, radius: 1, x: 1, y: 1)
            .shadow(color: .black, radius: 1, x: -1, y: -1)
            .shadow(color: .black, radius: 3, x: 0, y: 2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct WindowProbe: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void
    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView(); view.onWindow = onWindow; return view
    }
    func updateNSView(_ view: ProbeView, context: Context) { view.onWindow = onWindow }
    final class ProbeView: NSView {
        var onWindow: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if let window { DispatchQueue.main.async { [weak self, weak window] in if let window { self?.onWindow?(window) } } } }
    }
}
struct SettingsView: View {
    @AppStorage("ffmpegPath") private var ffmpeg = "/opt/homebrew/bin/ffmpeg"
    @AppStorage("whisperPath") private var whisper = LocalToolDefaults.whisper
    @AppStorage("whisperModel") private var model = LocalToolDefaults.model
    @AppStorage("ollamaURL") private var endpoint = "http://127.0.0.1:11434"
    @AppStorage("ollamaModel") private var ollamaModel = LocalToolDefaults.translationModel
    @AppStorage("recognitionEngine") private var recognitionEngine = "whisper"
    @AppStorage("qwenPython") private var qwenPython = LocalToolDefaults.qwenConfiguration["python"] ?? ""
    @AppStorage("qwenASRModel") private var qwenASRModel = LocalToolDefaults.qwenConfiguration["asr"] ?? ""
    @AppStorage("qwenAlignerModel") private var qwenAlignerModel = LocalToolDefaults.qwenConfiguration["aligner"] ?? ""
    @AppStorage("audioTrack") private var audioTrack = 0
    @AppStorage("additionalAIStudyNotes") private var additionalAIStudyNotes = false
    var body: some View {
        Form {
            Section("离线字幕识别") {
                Picker("识别模型", selection: $recognitionEngine) {
                    Text("Qwen3-ASR 1.7B + 时间对齐（推荐）").tag("qwen3-asr")
                    Text("Whisper（可选原有模型）").tag("whisper")
                }
                pathField("ffmpeg", value: $ffmpeg)
                if recognitionEngine == "qwen3-asr" {
                    pathField("本地 Python", value: $qwenPython)
                    pathField("Qwen ASR 模型目录", value: $qwenASRModel, directory: true)
                    pathField("Qwen 时间对齐模型目录", value: $qwenAlignerModel, directory: true)
                    Text("自动调整小声对白音量，结合人声检测与逐词时间对齐。识别完全在本机完成；模型目录与 Python 环境需保留。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    pathField("whisper-cli", value: $whisper)
                    pathField("Whisper 模型", value: $model)
                }
                Stepper("音轨索引：\(audioTrack)（0 是第一条音轨）", value: $audioTrack, in: 0...20)
                Text("选择多语言 .bin 模型；.en 模型仅适用于英语。工具和模型准备好后，识别可完全离线运行。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("本地中文翻译") {
                TextField("Ollama 地址", text: $endpoint)
                TextField("模型名称", text: $ollamaModel)
                Text("填写已下载的模型名称，并启动本地服务。播放器自动翻译当前及后两句，可在字幕菜单关闭。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("推荐使用本机 TranslateGemma 12B，结合前后对话与有来源的惯用语词义。仍可选择其他已安装的本地模型。原文有误时，中文含义也可能受影响。")
                    .font(.caption).foregroundStyle(.secondary)
                if ollamaModel.lowercased().hasPrefix("translategemma") {
                    Text("TranslateGemma 校验字幕段落，并结合有来源的惯用语词义。少数含义不完整的俗语由本机 Qwen3 4B 复核；仍不确定会显示提示，需保留该备用模型。")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("生成额外 AI 表达说明（本地，耗时）", isOn: $additionalAIStudyNotes)
                    Text("额外说明由本机 Qwen3 4B 生成，用于词典未覆盖的表达，需人工核对。开启会增加模型切换与等待时间。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("使用说明") {
                Text("⌘O 打开视频 · ⌘I 导入字幕 · 空格播放 / 暂停\n⌘← / ⌘→ 切换句子 · ⌘R 单句循环\n字幕与修改保存至 Application Support/SubtitleStudy。")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }.formStyle(.grouped).padding(12).frame(width: 620, height: 520)
    }
    func pathField(_ title: String, value: Binding<String>, directory: Bool = false) -> some View {
        HStack {
            TextField(title, text: value)
            Button("选择…") {
                let panel = NSOpenPanel(); panel.showsHiddenFiles = true
                panel.canChooseDirectories = directory; panel.canChooseFiles = !directory
                if panel.runModal() == .OK, let url = panel.url { value.wrappedValue = url.path }
            }
        }
    }
}


struct NativePlayerView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) { if view.player !== player { view.player = player } }
}


struct SubtitleEditor: View {
    let onSave: (String) -> Void
    let onCancel: () -> Void
    @State private var text: String
    init(cue: SubtitleCue, onSave: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.onSave = onSave; self.onCancel = onCancel
        _text = State(initialValue: cue.text)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("修改原文字幕").font(.headline)
            TextEditor(text: $text).font(.title3).frame(height: 150)
            Text("保存后将清除这句的旧译文，可重新翻译。").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消", action: onCancel)
                Button("保存") { onSave(text) }.buttonStyle(.borderedProminent)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 500)
    }
}


struct InsideCoverCaptions: View {
    let cue: SubtitleCue?
    let preview: Bool
    let originalVisible: Bool
    let requestedSize: Double
    let size: CGSize
    var translationPending = false
    var onInteraction: (() -> Void)? = nil
    var onSelectWord: ((SubtitleWordSelection) -> Void)? = nil
    private var original: String? {
        guard originalVisible else { return nil }
        return cue?.displayOriginal ?? (preview ? "日文原文 · 拖动区域调整位置" : nil)
    }
    private var translated: String? {
        if let translated = cue?.translation { return translated }
        if preview { return "中文字幕 · 拖动四角调整大小" }
        if cue != nil && !originalVisible && translationPending { return "正在准备中文译文…" }
        return nil
    }
    private var padding: Double { min(12, min(size.width * 0.04, size.height * 0.08)) }
    private var warningHeight: Double { cue?.studyWarningTitle == nil ? 0 : 18 }
    private func fittedFont() -> Double {
        let width = max(1, size.width-2*padding)
        let height = max(1, size.height-2*padding-warningHeight)
        func textHeight(_ text: String, fontSize: Double) -> Double {
            let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 3
            return NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: fontSize, weight: .semibold), .paragraphStyle: paragraph])
                .boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading]).height
        }
        var font = max(8, min(48, requestedSize))
        while font > 8 {
            let originalHeight = original.map { textHeight($0, fontSize: translated == nil ? font : font*0.75) } ?? 0
            let translatedHeight = translated.map { textHeight($0, fontSize: font) } ?? 0
            if originalHeight + translatedHeight + (original != nil && translated != nil ? 5 : 0) <= height { break }
            font -= 1
        }
        return font
    }
    var body: some View {
        let font = fittedFont()
        let rows = original != nil && translated != nil ? 2.0 : 1.0
        let availableHeight: Double = Double(size.height) - 2.0 * padding - 5.0 - warningHeight
        let lineLimit = max(1, Int(availableHeight / (font * 1.3 * rows)))
        VStack(spacing: 5) {
            if let original {
                SelectableSubtitleText(text: original, fontSize: translated == nil ? font : font*0.75,
                    color: .white.withAlphaComponent(0.9), lineLimit: lineLimit, onInteraction: onInteraction,
                    onSelect: !preview && cue?.displayOriginal == cue?.text ? onSelectWord : nil)
            }
            if let translated {
                Text(translated).font(.system(size: font, weight: .semibold)).foregroundStyle(.white).lineLimit(lineLimit)
            }
            if let title = cue?.studyWarningTitle {
                Label(title, systemImage: "exclamationmark.bubble").font(.system(size: 10)).foregroundStyle(accent).lineLimit(1)
            }
        }.multilineTextAlignment(.center).padding(padding)
            .frame(width: size.width, height: size.height, alignment: .center).clipped()
    }
}
