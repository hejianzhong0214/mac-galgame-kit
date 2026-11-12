// 生成 GalBox 的图标 iconset；用法: swift make_icon.swift <输出目录.iconset>
import AppKit

let out = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

let sizes: [(Int, String)] = [
    (16, "16x16"), (32, "16x16@2x"), (32, "32x32"), (64, "32x32@2x"),
    (128, "128x128"), (256, "128x128@2x"), (256, "256x256"), (512, "256x256@2x"),
    (512, "512x512"), (1024, "512x512@2x"),
]

for (px, name) in sizes {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // macOS 图标网格：内容区约占 80%
    let inset = s * 0.1
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = NSBezierPath(roundedRect: rect, xRadius: s * 0.18, yRadius: s * 0.18)
    NSGradient(
        starting: NSColor(calibratedRed: 0.98, green: 0.56, blue: 0.70, alpha: 1),
        ending: NSColor(calibratedRed: 0.52, green: 0.42, blue: 0.95, alpha: 1)
    )!.draw(in: path, angle: -60)

    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: s * 0.46, weight: .heavy),
        .foregroundColor: NSColor.white,
    ]
    let text = "ガ" as NSString
    let ts = text.size(withAttributes: attrs)
    text.draw(at: NSPoint(x: (s - ts.width) / 2, y: (s - ts.height) / 2), withAttributes: attrs)

    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
