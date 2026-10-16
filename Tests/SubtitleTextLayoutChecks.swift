import SwiftUI
import AppKit
import Darwin

@main struct SubtitleTextLayoutChecks {
    @MainActor static func main() throws {
        func check(_ value: Bool, _ message: String) throws { if !value { throw StudyError.message("FAIL: \(message)") } }
        func descendant(_ root: NSView) -> SubtitleWordTextView? {
            if let found = root as? SubtitleWordTextView { return found }
            return root.subviews.compactMap(descendant).first
        }
        _ = NSApplication.shared
        let source = "😀 Start in low gear, then shift into high gear."
        let host = NSHostingView(rootView: SelectableSubtitleText(text: source, fontSize: 24, onSelect: { _ in }).frame(width: 420))
        host.frame = NSRect(x: 0, y: 0, width: 420, height: max(100, host.fittingSize.height))
        host.layoutSubtreeIfNeeded()
        guard let native = descendant(host), let manager = native.layoutManager, let container = native.textContainer else { throw StudyError.message("Missing production native subtitle view") }
        native.layoutSubtreeIfNeeded(); manager.ensureLayout(for: container)
        let range = (source as NSString).range(of: "gear", options: .backwards)
        let glyph = manager.glyphIndexForCharacter(at: range.location)
        let rect = manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        let point = NSPoint(x: rect.midX+native.textContainerOrigin.x, y: rect.midY+native.textContainerOrigin.y)
        let offset = native.characterOffset(at: point)
        try check(offset == range.location, "Centered wrapped caption glyph mapped to wrong occurrence")
        try check(SubtitleWordSelection.word(in: source, atUTF16: offset!)?.range == range, "Glyph to Unicode word selection failed")
        let parentPoint = native.convert(point, to: native.superview)
        try check(native.hitTest(parentPoint) === native, "Caption glyph not clickable through native view")
        try check(native.characterOffset(at: NSPoint(x: native.bounds.maxX+100, y: 1)) == nil, "Blank video area intercepted")
        try check(host.fittingSize.height > 25 && host.fittingSize.height < 160, "Caption vertical layout invalid")
        let japanese = "この文章は折り返しと字幕の省略を調べるための長い文章です。もう一度この文章を読みます。"
        let coveredHost = NSHostingView(rootView: SelectableSubtitleText(text: japanese, fontSize: 20, lineLimit: 2, onSelect: { _ in }).frame(width: 220))
        coveredHost.frame = NSRect(x: 0, y: 0, width: 220, height: 90); coveredHost.layoutSubtreeIfNeeded()
        guard let covered = descendant(coveredHost), let layout = covered.layoutManager, let textContainer = covered.textContainer else { throw StudyError.message("Missing covered-caption view") }
        layout.ensureLayout(for: textContainer)
        let drawnHeight = layout.usedRect(for: textContainer).height
        try check(drawnHeight > 20 && drawnHeight < 65, "Covered subtitle ignored line limit")
        let highlighted = SubtitleWordSelection.selected(in: source, range: range)!
        let highlightHost = NSHostingView(rootView: SelectableSubtitleText(text: source, fontSize: 24, selection: highlighted, onSelect: { _ in }).frame(width: 420))
        highlightHost.frame = NSRect(x: 0, y: 0, width: 420, height: 100); highlightHost.layoutSubtreeIfNeeded()
        guard let highlightedView = descendant(highlightHost) else { throw StudyError.message("Missing highlighted word view") }
        try check(highlightedView.selectedRange() == range, "Chosen word highlight lost in popover")
        highlightHost.rootView = SelectableSubtitleText(text: "Next line.", fontSize: 24, onSelect: { _ in }).frame(width: 420)
        highlightHost.layoutSubtreeIfNeeded()
        try check(highlightedView.selectedRange().length == 0, "New subtitle kept a highlight from the previous line")
        native.onSelectWord = nil
        try check(native.hitTest(parentPoint) == nil, "Disabled original/cover preview intercepted controls")
        print("PASS: production SwiftUI/native text layout, centered wrapped glyph hit testing, repeated Unicode word offsets, blank video pass-through and cover line limits")
    }
}
