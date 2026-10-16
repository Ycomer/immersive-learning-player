import SwiftUI

@main
struct SubtitleStudyApp: App {
    @StateObject private var model = StudyModel()
    var body: some Scene {
        Window("Immersive Learning Player", id: "main") {
            StudyView(model: model)
                .frame(minWidth: 760, minHeight: 460)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1100, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("打开视频…", action: model.openVideo).keyboardShortcut("o")
                Button("导入字幕…", action: model.chooseSubtitle).keyboardShortcut("i")
                Button("导出字幕…", action: model.exportSubtitle).keyboardShortcut("e", modifiers: [.command, .shift])
            }
            CommandMenu("播放") {
                Button("播放 / 暂停", action: model.togglePlay).keyboardShortcut(" ", modifiers: [])
                Button("上一句") { model.moveSentence(-1) }.keyboardShortcut(.leftArrow, modifiers: [.command])
                Button("下一句") { model.moveSentence(1) }.keyboardShortcut(.rightArrow, modifiers: [.command])
                Button("单句循环", action: model.toggleLoop).keyboardShortcut("r")
            }
        }
        Settings { SettingsView().preferredColorScheme(.dark) }
    }
}
