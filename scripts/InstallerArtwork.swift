import AppKit
let width = 660, height = 430
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width * 2, pixelsHigh: height * 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: width, height: height)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGradient(starting: NSColor(calibratedRed: 0.93, green: 0.92, blue: 1, alpha: 1), ending: NSColor(calibratedWhite: 0.99, alpha: 1))!.draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: 35)
func label(_ text: String, y: CGFloat, size: CGFloat, color: NSColor, bold: Bool = false) {
    let style = NSMutableParagraphStyle(); style.alignment = .center
    (text as NSString).draw(in: NSRect(x: 20, y: y, width: 620, height: size * 2), withAttributes: [.font: bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size), .foregroundColor: color, .paragraphStyle: style])
}
label("KongVox", y: 330, size: 34, color: .labelColor, bold: true)
label("让整篇文字，自然开口。", y: 300, size: 16, color: .secondaryLabelColor)
label("→", y: 162, size: 42, color: .systemIndigo)
label("将 KongVox 拖入 Applications 文件夹", y: 76, size: 17, color: .labelColor, bold: true)
label("安装后，从“应用程序”打开 · 退出旧版后再替换", y: 44, size: 12, color: .secondaryLabelColor)
NSGraphicsContext.restoreGraphicsState()
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
