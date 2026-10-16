import AppKit
import Foundation

// Render a review video after inference. Reference text never appears in input media.
let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent(CommandLine.arguments.count > 5 ? CommandLine.arguments[5] : "tools/wavesubs-evaluation")
func json(_ name: String) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: Data(contentsOf: base.appendingPathComponent(name))) as! [String: Any]
}
let reference = try json(CommandLine.arguments.count > 4 ? CommandLine.arguments[4] : "dialogue-reference.json")
let actual = try json(CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "gui-generated-dialogue.json")
let frameFolder = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "comparison-frames"
let candidateLabel = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : "Large v3 + Qwen3 8B"
let lines = reference["lines"] as! [[String: Any]]
let cues = actual["cues"] as! [[String: Any]]
let duration = Int(((reference["duration"] as! Double) * 1000).rounded())
let frames = base.appendingPathComponent(frameFolder)
try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
var boundaries = Set([0, duration])
for line in lines {
    boundaries.insert(Int(((line["start"] as! Double) * 1000).rounded()))
    boundaries.insert(Int(((line["end"] as! Double) * 1000).rounded()))
}
for cue in cues {
    boundaries.insert(cue["startMs"] as! Int)
    boundaries.insert(cue["endMs"] as! Int)
}
let times = boundaries.filter { $0 >= 0 && $0 <= duration }.sorted()
let white = NSColor(calibratedWhite: 0.95, alpha: 1)
let muted = NSColor(calibratedWhite: 0.65, alpha: 1)
let teal = NSColor(calibratedRed: 0.38, green: 0.85, blue: 0.78, alpha: 1)
func text(_ string: String, y: CGFloat, size: CGFloat, color: NSColor, height: CGFloat = 75) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .left
    paragraph.lineBreakMode = .byWordWrapping
    paragraph.lineSpacing = 7
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size), .foregroundColor: color, .paragraphStyle: paragraph,
    ]
    (string as NSString).draw(in: NSRect(x: 64, y: y, width: 1152, height: height), withAttributes: attributes)
}
var concat = "ffconcat version 1.0\n"
for i in 0..<(times.count - 1) {
    let midpoint = Double(times[i] + times[i+1]) / 2000
    let line = lines.first { ($0["start"] as! Double) <= midpoint && midpoint < ($0["end"] as! Double) }
    let cue = cues.first { Double($0["startMs"] as! Int) / 1000 <= midpoint && midpoint < Double($0["endMs"] as! Int) / 1000 }
    let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1280, pixelsHigh: 720,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: image)
    NSColor(calibratedRed: 0.07, green: 0.095, blue: 0.13, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: 1280, height: 720).fill()
    text(reference["language"] as? String == "en" ? "本地英语字幕测试 · 固定样本对照" : "本地日语字幕测试 · 固定样本对照", y: 642, size: 30, color: white, height: 42)
    text("\(candidateLabel) · 保留模型原始输出", y: 597, size: 20, color: muted, height: 35)
    text("参考台词（生成脚本，未提供给模型）", y: 526, size: 21, color: teal, height: 35)
    text(line?["ja"] as? String ?? line?["text"] as? String ?? "（参考：此刻无对白）", y: 436, size: 28, color: white)
    text(line?["intendedChinese"] as? String ?? "", y: 379, size: 24, color: teal, height: 52)
    text("候选流程实际输出（原样保留）", y: 292, size: 21, color: muted, height: 35)
    text(cue?["text"] as? String ?? "（此刻没有字幕）", y: 201, size: 28, color: white)
    text(cue?["translation"] as? String ?? "", y: 114, size: 29,
         color: NSColor(calibratedRed: 1, green: 0.82, blue: 0.42, alpha: 1))
    if let gain = line?["gain"] as? Double, gain < 1 {
        text("本句音量：正常音量的 2%", y: 45, size: 19, color: teal, height: 30)
    } else if let note = (cue?["annotations"] as? [[String: Any]])?.first {
        text("词义参考：\(note["meaning"] as? String ?? "")", y: 45, size: 18, color: teal, height: 30)
    }
    if let warning = cue?["translationWarning"] as? String, !warning.isEmpty {
        text("含义待确认：\(warning)", y: 12, size: 14, color: muted, height: 25)
    }
    NSGraphicsContext.restoreGraphicsState()
    let filename = String(format: "%03d.png", i)
    try image.representation(using: .png, properties: [:])!.write(to: frames.appendingPathComponent(filename))
    concat += "file '\(filename)'\nduration \(Double(times[i+1] - times[i]) / 1000)\n"
}
concat += "file '\(String(format: "%03d.png", times.count - 2))'\n"
try concat.write(to: frames.appendingPathComponent("frames.ffconcat"), atomically: true, encoding: .utf8)
print("Rendered \(times.count - 1) reference/output comparison frames")
