// Kiritori のアプリアイコンを描いて Resources/Kiritori.icns を作る。
// 使い方: swift tools/make_icon.swift （kiritori フォルダで実行）
// 図柄: 朱色の地に、白い四隅の枠と、切り取った1枚。

import AppKit

func render(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let k = CGFloat(pixels) / 1024
    let scale = NSAffineTransform()
    scale.scale(by: k)
    scale.concat()

    func shadow(_ alpha: CGFloat, blur: CGFloat, dy: CGFloat) -> NSShadow {
        let s = NSShadow()
        s.shadowColor = NSColor.black.withAlphaComponent(alpha)
        s.shadowBlurRadius = blur * k   // 影は座標変換の外なので自分で縮める
        s.shadowOffset = NSSize(width: 0, height: dy * k)
        return s
    }

    // 地（macOS 標準の角丸の四角）
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = NSBezierPath(roundedRect: body, xRadius: 186, yRadius: 186)
    NSGraphicsContext.saveGraphicsState()
    shadow(0.30, blur: 26, dy: -14).set()
    NSColor.black.setFill()
    bodyPath.fill()
    NSGraphicsContext.restoreGraphicsState()

    let top = NSColor(srgbRed: 1.00, green: 0.48, blue: 0.26, alpha: 1)
    let bottom = NSColor(srgbRed: 0.84, green: 0.17, blue: 0.15, alpha: 1)
    NSGradient(colors: [top, bottom])!.draw(in: bodyPath, angle: -90)

    // 上半分のツヤ
    NSGraphicsContext.saveGraphicsState()
    bodyPath.addClip()
    let gloss = NSBezierPath(ovalIn: NSRect(x: -120, y: 560, width: 1264, height: 760))
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.26), NSColor.white.withAlphaComponent(0.0)])!
        .draw(in: gloss, angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    let rim = NSBezierPath(roundedRect: body.insetBy(dx: 3, dy: 3), xRadius: 183, yRadius: 183)
    rim.lineWidth = 6
    NSColor.white.withAlphaComponent(0.20).setStroke()
    rim.stroke()

    // 四隅の枠
    let f = NSRect(x: 276, y: 276, width: 472, height: 472)
    let arm: CGFloat = 122
    let brackets = NSBezierPath()
    for (cx, cy, sx, sy) in [(f.minX, f.minY, 1.0, 1.0), (f.maxX, f.minY, -1.0, 1.0),
                             (f.minX, f.maxY, 1.0, -1.0), (f.maxX, f.maxY, -1.0, -1.0)] {
        brackets.move(to: NSPoint(x: cx, y: cy + arm * sy))
        brackets.line(to: NSPoint(x: cx, y: cy))
        brackets.line(to: NSPoint(x: cx + arm * sx, y: cy))
    }
    brackets.lineWidth = 58
    brackets.lineCapStyle = .round
    brackets.lineJoinStyle = .round
    NSGraphicsContext.saveGraphicsState()
    shadow(0.22, blur: 14, dy: -6).set()
    NSColor.white.setStroke()
    brackets.stroke()
    NSGraphicsContext.restoreGraphicsState()

    // 切り取った1枚
    let piece = NSBezierPath(roundedRect: NSRect(x: 394, y: 424, width: 236, height: 176), xRadius: 34, yRadius: 34)
    NSGraphicsContext.saveGraphicsState()
    shadow(0.26, blur: 18, dy: -8).set()
    NSColor.white.setFill()
    piece.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let root = URL(fileURLWithPath: fm.currentDirectoryPath)
let iconset = root.appendingPathComponent("Resources/Kiritori.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try render(px).write(to: iconset.appendingPathComponent("icon_\(name).png"))
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/Kiritori.icns").path]
try task.run()
task.waitUntilExit()
try render(1024).write(to: root.appendingPathComponent("Resources/icon-preview.png"))
try? fm.removeItem(at: iconset)
print("できたもの: Resources/Kiritori.icns（終了コード \(task.terminationStatus)）")
