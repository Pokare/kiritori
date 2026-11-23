// 編集画面: 撮った画像に矢印・線・四角・丸・文字・番号・ぼかしを足す。
// 注釈は画像のピクセル座標（左下原点）で持ち、表示と書き出しで同じ描画処理を使う。
// 描いたものはいつでも選び直せて、丸いつまみで向き・長さ・大きさ・曲がりを変えられる。

import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

// MARK: - 種類

enum Tool: Int, CaseIterable {
    case select, arrow, line, rect, fillRect, ellipse, pencil, highlighter, text, counter, blur, spotlight, crop
    /// 足した画像。道具バーには出さない（「画像」のメニュー・貼り付け・ドラッグで足す）
    case image

    /// 道具バーに並べるもの
    static let drawable: [Tool] = allCases.filter { $0 != .image }

    var label: String {
        switch self {
        case .select: return "選択"
        case .arrow: return "矢印"
        case .line: return "線"
        case .rect: return "四角"
        case .fillRect: return "塗り四角"
        case .ellipse: return "丸"
        case .pencil: return "ペン"
        case .highlighter: return "蛍光ペン"
        case .text: return "文字"
        case .counter: return "番号"
        case .blur: return "ぼかし"
        case .spotlight: return "スポット"
        case .crop: return "切り抜き"
        case .image: return "画像"
        }
    }
    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .arrow: return "arrow.up.right"
        case .line: return "line.diagonal"
        case .rect: return "rectangle"
        case .fillRect: return "rectangle.fill"
        case .ellipse: return "circle"
        case .pencil: return "pencil"
        case .highlighter: return "highlighter"
        case .text: return "textformat"
        case .counter: return "1.circle"
        case .blur: return "square.grid.3x3.fill"
        case .spotlight: return "flashlight.on.fill"
        case .crop: return "crop"
        case .image: return "photo"
        }
    }
    var key: String {
        switch self {
        case .select: return "v"
        case .arrow: return "a"
        case .line: return "l"
        case .rect: return "r"
        case .fillRect: return "f"
        case .ellipse: return "o"
        case .pencil: return "p"
        case .highlighter: return "h"
        case .text: return "t"
        case .counter: return "n"
        case .blur: return "b"
        case .spotlight: return "s"
        case .crop: return "c"
        case .image: return ""
        }
    }
    var hint: String {
        switch self {
        case .select: return "描いたものをクリックで選ぶ。ドラッグで移動、delete で消す"
        case .arrow: return "ドラッグで矢印。描いたあと端の丸で向きと長さ、真ん中の丸で曲がりを変えられます"
        case .line: return "ドラッグで線。shift を押すと水平・垂直・45度にそろいます"
        case .rect: return "ドラッグで四角。shift を押すと正方形になります"
        case .ellipse: return "ドラッグで丸。shift を押すと正円になります"
        case .text: return "置きたい場所をクリックして入力。return で確定。ダブルクリックで打ち直せます"
        case .counter: return "クリックするたびに 1、2、3 と置かれます"
        case .blur: return "隠したい範囲をドラッグ。種類と強さは左で変えられます"
        case .fillRect: return "ドラッグで塗りつぶした四角。shift を押すと正方形になります"
        case .pencil: return "ドラッグで自由に描く。線は自動でなめらかになります"
        case .highlighter: return "ドラッグでなぞる。shift を押すとまっすぐ横に引けます"
        case .spotlight: return "目立たせたい範囲をドラッグ。まわりが暗くなります。暗さは左で変えられます"
        case .crop: return "残したい範囲をドラッグ。まわりの丸で調整。完了・保存・コピーのときに切り抜かれます"
        case .image: return ""
        }
    }
}

enum ArrowStyle: Int, CaseIterable {
    case filled, open, tapered, double, curved
    var label: String {
        switch self {
        case .filled: return "標準"
        case .open: return "線だけ"
        case .tapered: return "先細り"
        case .double: return "両矢印"
        case .curved: return "曲がった矢印"
        }
    }
}

enum BlurStyle: Int, CaseIterable {
    case mosaic, gaussian, solid, secure
    var label: String {
        switch self {
        case .mosaic: return "モザイク"
        case .gaussian: return "ぼかし"
        case .solid: return "塗りつぶし"
        case .secure: return "強いぼかし"
        }
    }
}

enum TextStyle: Int, CaseIterable {
    // 番号は控えのファイルに残るので、あとから足したものは後ろへ並べる
    case outline, boxed, plain, rounded, roundedBoxed, mono, monoBoxed

    /// 画面に並べる順
    static let ordered: [TextStyle] = [.plain, .outline, .boxed, .rounded, .roundedBoxed, .mono, .monoBoxed]

    var label: String {
        switch self {
        case .plain: return "標準"
        case .outline: return "縁取り"
        case .boxed: return "背景つき"
        case .rounded: return "丸文字"
        case .roundedBoxed: return "丸文字＋背景"
        case .mono: return "等幅"
        case .monoBoxed: return "等幅＋背景"
        }
    }
    var isBoxed: Bool { self == .boxed || self == .roundedBoxed || self == .monoBoxed }

    func font(ofSize size: CGFloat) -> NSFont {
        let standard = NSFont.systemFont(ofSize: size, weight: .bold)
        switch self {
        case .plain, .outline, .boxed:
            return standard
        case .rounded, .roundedBoxed:
            // 英数字はシステムの丸い書体、日本語は丸ゴシックにする
            guard let round = standard.fontDescriptor.withDesign(.rounded) else { return standard }
            let maru = NSFontDescriptor(fontAttributes: [.name: "HiraMaruProN-W4"])
            return NSFont(descriptor: round.addingAttributes([.cascadeList: [maru]]), size: size) ?? standard
        case .mono, .monoBoxed:
            return NSFont.monospacedSystemFont(ofSize: size, weight: .bold)
        }
    }
}

// MARK: - 幾何の小道具

extension CGPoint {
    static func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
    static func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
    static func * (a: CGPoint, k: CGFloat) -> CGPoint { CGPoint(x: a.x * k, y: a.y * k) }
    var length: CGFloat { hypot(x, y) }
    var unit: CGPoint { let l = length; return l > 0.0001 ? CGPoint(x: x / l, y: y / l) : CGPoint(x: 1, y: 0) }
    var normal: CGPoint { CGPoint(x: -y, y: x) }
}

func distanceToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
    let d = b - a
    let len2 = d.x * d.x + d.y * d.y
    guard len2 > 0 else { return (p - a).length }
    let t = max(0, min(1, ((p.x - a.x) * d.x + (p.y - a.y) * d.y) / len2))
    return (p - (a + d * t)).length
}

func contrastColor(for color: NSColor) -> NSColor {
    guard let c = color.usingColorSpace(.sRGB) else { return .white }
    let lum = 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
    return lum > 0.62 ? NSColor(white: 0.08, alpha: 1) : .white
}

/// shift を押しているときに、起点から見た角度を45度刻みにそろえる。
func snapAngle(from origin: CGPoint, to p: CGPoint) -> CGPoint {
    let d = p - origin
    let len = d.length
    guard len > 0 else { return p }
    let step = CGFloat.pi / 4
    let angle = (atan2(d.y, d.x) / step).rounded() * step
    return CGPoint(x: origin.x + cos(angle) * len, y: origin.y + sin(angle) * len)
}

// MARK: - 注釈

struct Annotation {
    var tool: Tool
    var p0: CGPoint
    var p1: CGPoint
    var ctrl: CGPoint? = nil          // 矢印・線の曲げ（2次ベジェの制御点）
    var color: NSColor
    var weight: CGFloat               // 0...1（太さ・大きさ・強さの共通つまみ）
    var scale: CGFloat                // 1pt あたりのピクセル数
    var arrowStyle: ArrowStyle = .filled
    var blurStyle: BlurStyle = .mosaic
    var textStyle: TextStyle = .outline
    var text: String = ""
    var number: Int = 0
    /// ペン・蛍光ペンでなぞった点の列
    var points: [CGPoint] = []
    /// 足した画像の中身（tool が .image のとき）
    var image: CGImage? = nil
    /// 文字と番号の向き。左回りに90度ずつ（画像を回したときに一緒に回る）
    var turns: Int = 0

    var lineWidth: CGFloat { (1.5 + weight * 10.5) * scale }
    /// 蛍光ペンの太さ
    var markerWidth: CGFloat { (9 + weight * 30) * scale }
    /// スポットライトのまわりの暗さ
    var dimAlpha: CGFloat { 0.35 + weight * 0.5 }
    var fontSize: CGFloat { (13 + weight * 44) * scale }
    var radius: CGFloat { (9 + weight * 17) * scale }
    var mosaicBlock: CGFloat { max(4, ((5 + weight * 22) * scale).rounded()) }
    var blurRadius: CGFloat { (4 + weight * 28) * scale }

    var isLinear: Bool { tool == .arrow || tool == .line }
    var isBox: Bool { [.rect, .fillRect, .ellipse, .blur, .spotlight, .crop, .image].contains(tool) }
    /// はみ出したときに余白を広げる対象か（ぼかし・スポット・切り抜きは画像の中だけで意味がある）
    var expandsCanvas: Bool { ![.select, .blur, .spotlight, .crop].contains(tool) }
    var isFreehand: Bool { tool == .pencil || tool == .highlighter }
    private var strokeWidth: CGFloat { tool == .highlighter ? markerWidth : lineWidth }

    var rect: CGRect {
        CGRect(x: min(p0.x, p1.x), y: min(p0.y, p1.y), width: abs(p1.x - p0.x), height: abs(p1.y - p0.y))
    }

    mutating func normalizeBox() {
        guard isBox else { return }
        let r = rect
        p0 = CGPoint(x: r.minX, y: r.minY)
        p1 = CGPoint(x: r.maxX, y: r.maxY)
    }

    // 曲線
    /// 曲げの制御点。「曲がった矢印」は、曲げていなくても最初からゆるく弓なりにする
    var bend: CGPoint? {
        if let ctrl { return ctrl }
        guard tool == .arrow, arrowStyle == .curved else { return nil }
        let d = p1 - p0
        return (p0 + p1) * 0.5 + d.normal * 0.36
    }

    func curvePoint(_ t: CGFloat) -> CGPoint {
        guard let c = bend else { return p0 + (p1 - p0) * t }
        let u = 1 - t
        return p0 * (u * u) + c * (2 * u * t) + p1 * (t * t)
    }
    /// 曲線をなぞる点の列。まっすぐでも n 分割で返す。
    func samples(_ n: Int = 40) -> [CGPoint] {
        (0...n).map { curvePoint(CGFloat($0) / CGFloat(n)) }
    }

    // 文字
    var font: NSFont { textStyle.font(ofSize: fontSize) }
    var textSize: CGSize {
        NSAttributedString(string: text.isEmpty ? " " : text, attributes: [.font: font]).size()
    }
    var textPadding: CGSize {
        textStyle.isBoxed ? CGSize(width: fontSize * 0.42, height: fontSize * 0.2) : .zero
    }

    /// 回す前の向きで見た、文字の箱（背景つきの余白を含む）
    var textBox: CGRect {
        CGRect(origin: p0, size: textSize).insetBy(dx: -textPadding.width, dy: -textPadding.height)
    }

    var bounds: CGRect {
        switch tool {
        case .text:
            let box = textBox
            guard turns % 2 != 0 else { return box }
            // 横倒しのときは、真ん中をそのままに縦横を入れ替える
            return CGRect(x: box.midX - box.height / 2, y: box.midY - box.width / 2, width: box.height, height: box.width)
        case .counter:
            return CGRect(x: p0.x - radius, y: p0.y - radius, width: radius * 2, height: radius * 2)
        case .arrow, .line:
            let pts = samples(16)
            let xs = pts.map(\.x), ys = pts.map(\.y)
            let r = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            return r.insetBy(dx: -lineWidth * 2.5, dy: -lineWidth * 2.5)
        case .pencil, .highlighter:
            guard !points.isEmpty else { return CGRect(origin: p0, size: .zero) }
            let xs = points.map(\.x), ys = points.map(\.y)
            let r = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            return r.insetBy(dx: -strokeWidth / 2, dy: -strokeWidth / 2)
        case .spotlight, .crop, .image:
            return rect
        default:
            return rect.insetBy(dx: -lineWidth / 2, dy: -lineWidth / 2)
        }
    }

    func hit(_ p: CGPoint, tolerance: CGFloat) -> Bool {
        switch tool {
        case .arrow, .line:
            let pts = samples(24)
            let reach = lineWidth * (tool == .arrow ? 1.6 : 0.5) + tolerance
            for i in 0..<(pts.count - 1) where distanceToSegment(p, pts[i], pts[i + 1]) <= reach { return true }
            return false
        case .pencil, .highlighter:
            let reach = strokeWidth / 2 + tolerance
            if points.count == 1 { return (p - points[0]).length <= reach }
            for i in 0..<max(0, points.count - 1) where distanceToSegment(p, points[i], points[i + 1]) <= reach { return true }
            return false
        case .spotlight, .crop:
            // 中に別のものを描けるよう、つかめるのは縁だけ
            let band = tolerance * 1.5
            let outer = rect.insetBy(dx: -band, dy: -band)
            let inner = rect.insetBy(dx: band, dy: band)
            if !outer.contains(p) { return false }
            return !(inner.width > 0 && inner.height > 0 && inner.contains(p))
        case .rect:
            let band = lineWidth / 2 + tolerance
            let outer = rect.insetBy(dx: -band, dy: -band)
            let inner = rect.insetBy(dx: band, dy: band)
            if !outer.contains(p) { return false }
            return !(inner.width > 0 && inner.height > 0 && inner.contains(p))
        case .ellipse:
            let rx = rect.width / 2, ry = rect.height / 2
            guard rx > 1, ry > 1 else { return bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(p) }
            let dx = (p.x - rect.midX) / rx, dy = (p.y - rect.midY) / ry
            let band = (lineWidth / 2 + tolerance) / min(rx, ry)
            return abs(hypot(dx, dy) - 1) <= band
        default:
            return bounds.insetBy(dx: -tolerance / 2, dy: -tolerance / 2).contains(p)
        }
    }

    mutating func move(by d: CGPoint) {
        p0 = p0 + d
        p1 = p1 + d
        if let c = ctrl { ctrl = c + d }
        if !points.isEmpty { points = points.map { $0 + d } }
    }

    /// つまみ。0=始点 1=終点 2=曲げ / 10〜17=四隅と辺（左下から反時計回り）
    func handles() -> [(id: Int, point: CGPoint)] {
        if isLinear {
            return [(0, p0), (1, p1), (2, curvePoint(0.5))]
        }
        if tool == .image {
            // 画像は比率を保つので、つまみは四隅だけ
            let r = rect
            return [(10, CGPoint(x: r.minX, y: r.minY)), (12, CGPoint(x: r.maxX, y: r.minY)),
                    (14, CGPoint(x: r.maxX, y: r.maxY)), (16, CGPoint(x: r.minX, y: r.maxY))]
        }
        if isBox {
            let r = rect
            return [
                (10, CGPoint(x: r.minX, y: r.minY)), (11, CGPoint(x: r.midX, y: r.minY)),
                (12, CGPoint(x: r.maxX, y: r.minY)), (13, CGPoint(x: r.maxX, y: r.midY)),
                (14, CGPoint(x: r.maxX, y: r.maxY)), (15, CGPoint(x: r.midX, y: r.maxY)),
                (16, CGPoint(x: r.minX, y: r.maxY)), (17, CGPoint(x: r.minX, y: r.midY)),
            ]
        }
        return []
    }

    mutating func moveHandle(_ id: Int, to raw: CGPoint, constrain: Bool) {
        if tool == .image, let img = image, [10, 12, 14, 16].contains(id) {
            // 向かいの角を止めて、縦横の比率を保ったまま大きさを変える
            let r = rect
            let left = id == 10 || id == 16, bottom = id == 10 || id == 12
            let anchor = CGPoint(x: left ? r.maxX : r.minX, y: bottom ? r.maxY : r.minY)
            let aspect = CGFloat(img.width) / CGFloat(max(1, img.height))
            let w = max(16 * scale, abs(raw.x - anchor.x), abs(raw.y - anchor.y) * aspect)
            let h = w / aspect
            p0 = CGPoint(x: left ? anchor.x - w : anchor.x, y: bottom ? anchor.y - h : anchor.y)
            p1 = CGPoint(x: p0.x + w, y: p0.y + h)
            return
        }
        switch id {
        case 0: p0 = constrain && ctrl == nil ? snapAngle(from: p1, to: raw) : raw
        case 1: p1 = constrain && ctrl == nil ? snapAngle(from: p0, to: raw) : raw
        case 2:
            let chordMid = (p0 + p1) * 0.5
            // まっすぐの位置に近づけたら直線へ戻す
            if (raw - chordMid).length < max(lineWidth * 1.2, (p1 - p0).length * 0.03) {
                ctrl = nil
            } else {
                ctrl = raw * 2 - chordMid
            }
        case 10: p0 = raw
        case 11: p0.y = raw.y
        case 12: p1.x = raw.x; p0.y = raw.y
        case 13: p1.x = raw.x
        case 14: p1 = raw
        case 15: p1.y = raw.y
        case 16: p0.x = raw.x; p1.y = raw.y
        case 17: p0.x = raw.x
        default: break
        }
    }
}

// MARK: - 描画

/// 矢印と線。色はあらかじめ ctx に設定しておく。
func drawLinear(_ a: Annotation, in ctx: CGContext) {
    let pts = a.samples(48)
    let total = zip(pts, pts.dropFirst()).reduce(CGFloat(0)) { $0 + ($1.1 - $1.0).length }
    guard total > 0.5 else { return }
    let w = a.lineWidth
    ctx.setLineWidth(w)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)

    if a.tool == .line {
        ctx.addLines(between: pts)
        ctx.strokePath()
        return
    }

    let headLength = min(max(w * (a.arrowStyle == .tapered ? 4.8 : 4.2), 11 * a.scale), total * 0.6)
    let halfWidth = headLength * (a.arrowStyle == .tapered ? 0.5 : 0.44)

    /// 端から distance だけ戻った点と、そこまでの点列
    func cut(_ points: [CGPoint], fromEnd distance: CGFloat) -> (base: CGPoint, body: [CGPoint]) {
        var remaining = distance
        var i = points.count - 1
        while i > 0 {
            let seg = (points[i] - points[i - 1]).length
            if seg >= remaining {
                let t = seg > 0 ? remaining / seg : 0
                let base = points[i] + (points[i - 1] - points[i]) * t
                return (base, Array(points[0..<i]) + [base])
            }
            remaining -= seg
            i -= 1
        }
        return (points[0], [points[0]])
    }

    func fillHead(tip: CGPoint, base: CGPoint) {
        let u = (tip - base).unit
        let n = u.normal
        let back = tip - u * headLength
        ctx.move(to: tip)
        ctx.addLine(to: back + n * halfWidth)
        ctx.addLine(to: back + u * (headLength * 0.12))
        ctx.addLine(to: back - n * halfWidth)
        ctx.closePath()
        ctx.fillPath()
    }

    switch a.arrowStyle {
    case .filled, .curved:
        let end = cut(pts, fromEnd: headLength)
        let u = (a.p1 - end.base).unit
        ctx.addLines(between: end.body + [end.base + u * (headLength * 0.3)])
        ctx.strokePath()
        fillHead(tip: a.p1, base: end.base)

    case .double:
        let end = cut(pts, fromEnd: headLength)
        let start = cut(Array(end.body.reversed()), fromEnd: headLength)
        let uEnd = (a.p1 - end.base).unit
        let uStart = (a.p0 - start.base).unit
        var body = Array(start.body.reversed())
        body.insert(start.base + uStart * (headLength * 0.3), at: 0)
        body.append(end.base + uEnd * (headLength * 0.3))
        ctx.addLines(between: body)
        ctx.strokePath()
        fillHead(tip: a.p1, base: end.base)
        fillHead(tip: a.p0, base: start.base)

    case .open:
        ctx.addLines(between: pts)
        ctx.strokePath()
        let end = cut(pts, fromEnd: headLength)
        let u = (a.p1 - end.base).unit
        let n = u.normal
        let back = a.p1 - u * headLength
        ctx.move(to: back + n * (halfWidth * 1.15))
        ctx.addLine(to: a.p1)
        ctx.addLine(to: back - n * (halfWidth * 1.15))
        ctx.strokePath()

    case .tapered:
        let end = cut(pts, fromEnd: headLength)
        let body = end.body
        guard body.count >= 2 else { fillHead(tip: a.p1, base: end.base); return }
        var left: [CGPoint] = [], right: [CGPoint] = []
        for (i, p) in body.enumerated() {
            let t = CGFloat(i) / CGFloat(body.count - 1)
            let dir = (i < body.count - 1 ? body[i + 1] - p : p - body[i - 1]).unit
            let half = (w * 0.18 + (w * 1.25 - w * 0.18) * t) / 2
            left.append(p + dir.normal * half)
            right.append(p - dir.normal * half)
        }
        ctx.addLines(between: left + right.reversed())
        ctx.closePath()
        ctx.fillPath()
        fillHead(tip: a.p1, base: end.base)
    }
}

final class Renderer {
    /// 台紙の状態。元の画像と、それを台紙のどこに置くかと、台紙の大きさ。
    /// 台紙は元の画像と同じ大きさで始まり、画像を足したりはみ出して描いたりすると広がる。
    struct CanvasState {
        var base: CGImage
        var baseOrigin: CGPoint
        var size: CGSize
    }

    private(set) var base: CGImage
    let dpiScale: CGFloat
    /// 台紙の大きさ（ピクセル）
    private(set) var width: CGFloat
    private(set) var height: CGFloat
    private(set) var baseOrigin: CGPoint = .zero
    private var blurCache: [String: CGImage] = [:]
    private var displayCache: (key: String, image: CGImage)?
    private static let ciContext = CIContext(options: nil)

    init(base: CGImage, dpiScale: CGFloat) {
        self.base = base
        self.dpiScale = dpiScale
        self.width = CGFloat(base.width)
        self.height = CGFloat(base.height)
    }

    /// 背景ツールの設定と、それを描く係
    var background = BackdropStyle()
    let backgroundPainter = BackgroundPainter()

    /// 描いたもの・切り抜き・背景まで全部反映した、書き出し用の画像。
    func renderFinal(_ annotations: [Annotation]) -> CGImage? {
        guard let content = renderImage(annotations) else { return nil }
        guard background.enabled else { return content }
        return backgroundPainter.composite(content, style: background, scale: dpiScale, base: base) ?? content
    }

    var fullRect: CGRect { CGRect(x: 0, y: 0, width: width, height: height) }
    /// 元の画像が台紙の中で占める範囲
    var baseRect: CGRect { CGRect(x: baseOrigin.x, y: baseOrigin.y, width: CGFloat(base.width), height: CGFloat(base.height)) }
    /// 台紙が元の画像より広がっている
    var isExpanded: Bool { baseRect != fullRect }

    var state: CanvasState {
        get { CanvasState(base: base, baseOrigin: baseOrigin, size: CGSize(width: width, height: height)) }
        set {
            base = newValue.base
            baseOrigin = newValue.baseOrigin
            width = newValue.size.width
            height = newValue.size.height
            invalidate()
        }
    }

    private func invalidate() {
        blurCache.removeAll()
        darkCache.removeAll()
        displayCache = nil
        backdropCache = nil
        layerKey = ""
    }

    // MARK: 台紙の広さ

    /// 足した画像と、はみ出して描いたものが全部入るように台紙の広さを決め直す。
    /// 左や下へ広がるときは、全部を同じだけずらして台紙の左下を原点に保つ。
    func layout(_ all: inout [Annotation]) {
        let content = all.filter { $0.tool == .image }.reduce(baseRect) { $0.union($1.rect) }
        let inside = content.insetBy(dx: -0.5, dy: -0.5)
        var union = content
        // 画像の中に描いたものは、線の太さの分だけ縁からはみ出しても広げない（今までどおり縁で切る）
        for a in all where a.expandsCanvas && a.tool != .image && !inside.contains(a.coreBounds) {
            union = union.union(a.bounds)
        }
        union = union.integral
        guard union != fullRect, union.width <= 30000, union.height <= 30000 else { return }
        let shift = CGPoint(x: -union.minX, y: -union.minY)
        if shift != .zero {
            for i in all.indices { all[i].move(by: shift) }
            baseOrigin = baseOrigin + shift
        }
        width = union.width
        height = union.height
        invalidate()
    }

    // MARK: 下地（元の画像＋足した画像）

    private var layers: [Annotation] = []
    private var layerKey = ""
    private var backdropCache: CGImage?

    /// 描く前に呼ぶ。足した画像の並びが変わっていたら、ぼかしの材料を作り直す。
    func prepare(_ all: [Annotation]) {
        let images = all.filter { $0.tool == .image && $0.image != nil }
        let key = images.map { a in
            "\(Unmanaged.passUnretained(a.image!).toOpaque())@\(a.rect.minX),\(a.rect.minY),\(a.rect.width),\(a.rect.height)"
        }.joined(separator: "|")
        guard key != layerKey || layers.count != images.count else { return }
        layerKey = key
        layers = images
        backdropCache = nil
        blurCache.removeAll()
        darkCache.removeAll()
    }

    /// 台紙と同じ大きさの下地。ぼかしと「暗い所か」の判断は、これを材料にする。
    private var backdrop: CGImage? {
        if layers.isEmpty && !isExpanded { return base }
        if let cached = backdropCache { return cached }
        guard let ctx = makeBitmapContext(width: Int(width), height: Int(height), like: base) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(base, in: baseRect)
        for layer in layers { if let image = layer.image { ctx.draw(image, in: layer.rect) } }
        backdropCache = ctx.makeImage()
        return backdropCache
    }

    func drawBase(in ctx: CGContext) {
        ctx.saveGState()
        ctx.interpolationQuality = .high
        ctx.draw(base, in: baseRect)
        ctx.restoreGState()
    }

    /// 画面表示用に、表示サイズへ縮めた元画像を使い回す（ドラッグ中の描き直しを軽くする）。
    func displayImage(pixelWidth: Int, pixelHeight: Int) -> CGImage? {
        let key = "\(pixelWidth)x\(pixelHeight)"
        if let cached = displayCache, cached.key == key { return cached.image }
        guard pixelWidth > 0, pixelHeight > 0,
              let ctx = CGContext(data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        guard let image = ctx.makeImage() else { return nil }
        displayCache = (key, image)
        return image
    }

    func draw(_ a: Annotation, in ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }

        if a.tool == .blur {
            drawBlur(a, in: ctx)
            return
        }
        if a.tool == .image {
            if let image = a.image {
                ctx.interpolationQuality = .high
                ctx.draw(image, in: a.rect)
            }
            return
        }
        if a.tool == .spotlight || a.tool == .crop { return }   // まとめて別に描く
        if a.tool == .highlighter {
            // 明るい地では「乗算」でのせて下の文字を残す。暗い地では乗算だと見えなくなるので、薄く重ねる
            if isDark(under: a.bounds) {
                ctx.setBlendMode(.normal)
                ctx.setAlpha(0.42)
            } else {
                ctx.setBlendMode(.multiply)
                ctx.setAlpha(0.6)
            }
            ctx.setStrokeColor(a.color.cgColor)
            ctx.setLineWidth(a.markerWidth)
            ctx.setLineCap(.butt)
            ctx.setLineJoin(.round)
            ctx.addPath(smoothPath(a.points))
            ctx.strokePath()
            return
        }

        ctx.setShadow(offset: CGSize(width: 0, height: -1 * dpiScale), blur: 3.5 * dpiScale,
                      color: NSColor.black.withAlphaComponent(0.38).cgColor)
        ctx.setStrokeColor(a.color.cgColor)
        ctx.setFillColor(a.color.cgColor)
        ctx.setLineWidth(a.lineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        switch a.tool {
        case .rect:
            let r = a.rect
            let corner = min(a.lineWidth * 1.2, r.width / 2, r.height / 2)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: corner, cornerHeight: corner, transform: nil))
            ctx.strokePath()
        case .fillRect:
            let r = a.rect
            let corner = min(3 * dpiScale, r.width / 2, r.height / 2)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: corner, cornerHeight: corner, transform: nil))
            ctx.fillPath()
        case .pencil:
            ctx.addPath(smoothPath(a.points))
            ctx.strokePath()
        case .ellipse:
            ctx.strokeEllipse(in: a.rect)
        case .line, .arrow:
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            drawLinear(a, in: ctx)
            ctx.endTransparencyLayer()
        case .text:
            if a.turns % 4 != 0 {
                let box = a.textBox
                ctx.translateBy(x: box.midX, y: box.midY)
                ctx.rotate(by: CGFloat(a.turns) * .pi / 2)
                ctx.translateBy(x: -box.midX, y: -box.midY)
            }
            drawText(a, in: ctx)
        case .counter:
            drawCounter(a, in: ctx)
        case .select, .blur, .highlighter, .spotlight, .crop, .image:
            break
        }
    }

    private var darkCache: [String: Bool] = [:]

    /// 元の画像のその場所が暗いか（平均の明るさで判断）。
    private func isDark(under rect: CGRect) -> Bool {
        let r = rect.integral.intersection(fullRect)
        guard r.width >= 1, r.height >= 1 else { return false }
        // なぞっている途中は範囲が変わり続けるので、粗く丸めた範囲で覚える
        let key = "\(Int(r.minX / 24)),\(Int(r.minY / 24)),\(Int(r.width / 24)),\(Int(r.height / 24))"
        if let hit = darkCache[key] { return hit }
        var pixel = [UInt8](repeating: 0, count: 4)
        var dark = false
        if let part = backdrop?.cropping(to: CGRect(x: r.minX, y: height - r.maxY, width: r.width, height: r.height)),
           let one = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            one.interpolationQuality = .medium
            one.draw(part, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            let lum = (0.299 * Double(pixel[0]) + 0.587 * Double(pixel[1]) + 0.114 * Double(pixel[2])) / 255
            dark = lum < 0.45
        }
        if darkCache.count > 400 { darkCache.removeAll() }
        darkCache[key] = dark
        return dark
    }

    /// スポットライト：囲んだ所だけ明るく残して、ほかを暗くする。いくつあっても1枚の幕にまとめる。
    func drawSpotlights(_ all: [Annotation], in ctx: CGContext) {
        let spots = all.filter { $0.tool == .spotlight && $0.rect.width >= 2 && $0.rect.height >= 2 }
        guard !spots.isEmpty else { return }
        ctx.saveGState()
        let path = CGMutablePath()
        path.addRect(fullRect)
        for s in spots {
            let corner = min(6 * dpiScale, s.rect.width / 2, s.rect.height / 2)
            path.addPath(CGPath(roundedRect: s.rect, cornerWidth: corner, cornerHeight: corner, transform: nil))
        }
        ctx.addPath(path)
        ctx.setFillColor(NSColor.black.withAlphaComponent(spots.map(\.dimAlpha).max() ?? 0.6).cgColor)
        ctx.fillPath(using: .evenOdd)
        ctx.restoreGState()
    }

    /// 切り抜く範囲（画像の座標）。無ければ nil。
    func cropRect(_ all: [Annotation]) -> CGRect? {
        guard let c = all.last(where: { $0.tool == .crop }) else { return nil }
        let r = c.rect.integral.intersection(fullRect)
        return r.width >= 4 && r.height >= 4 ? r : nil
    }

    private func withNSContext(_ ctx: CGContext, _ body: () -> Void) {
        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        body()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawText(_ a: Annotation, in ctx: CGContext) {
        guard !a.text.isEmpty else { return }
        switch a.textStyle {
        case .plain, .rounded, .mono:
            // 影だけを付けた素の文字
            let label = NSAttributedString(string: a.text, attributes: [.font: a.font, .foregroundColor: a.color])
            withNSContext(ctx) { label.draw(at: a.p0) }
        case .outline:
            let outline = NSAttributedString(string: a.text, attributes: [
                .font: a.font, .foregroundColor: a.color,
                .strokeColor: contrastColor(for: a.color), .strokeWidth: 16.0,
            ])
            let fill = NSAttributedString(string: a.text, attributes: [.font: a.font, .foregroundColor: a.color])
            withNSContext(ctx) {
                outline.draw(at: a.p0)
                ctx.setShadow(offset: .zero, blur: 0, color: nil)
                fill.draw(at: a.p0)
            }
        case .boxed, .roundedBoxed, .monoBoxed:
            let box = a.textBox
            let corner = min(a.fontSize * 0.3, box.height / 2)
            ctx.addPath(CGPath(roundedRect: box, cornerWidth: corner, cornerHeight: corner, transform: nil))
            ctx.fillPath()
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            let label = NSAttributedString(string: a.text, attributes: [.font: a.font, .foregroundColor: contrastColor(for: a.color)])
            withNSContext(ctx) { label.draw(at: a.p0) }
        }
    }

    private func drawCounter(_ a: Annotation, in ctx: CGContext) {
        let r = a.bounds
        ctx.fillEllipse(in: r)
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        ctx.setStrokeColor(contrastColor(for: a.color).withAlphaComponent(0.9).cgColor)
        ctx.setLineWidth(max(1, a.radius * 0.11))
        ctx.strokeEllipse(in: r.insetBy(dx: a.radius * 0.055, dy: a.radius * 0.055))
        let label = NSAttributedString(string: String(a.number), attributes: [
            .font: NSFont.systemFont(ofSize: a.radius * 1.12, weight: .bold),
            .foregroundColor: contrastColor(for: a.color),
        ])
        let size = label.size()
        if a.turns % 4 != 0 {
            ctx.translateBy(x: a.p0.x, y: a.p0.y)
            ctx.rotate(by: CGFloat(a.turns) * .pi / 2)
            ctx.translateBy(x: -a.p0.x, y: -a.p0.y)
        }
        withNSContext(ctx) { label.draw(at: CGPoint(x: a.p0.x - size.width / 2, y: a.p0.y - size.height / 2)) }
    }

    private func drawBlur(_ a: Annotation, in ctx: CGContext) {
        let r = a.rect.integral.intersection(fullRect)
        guard r.width >= 2, r.height >= 2 else { return }
        let corner = min(3 * dpiScale, r.width / 2, r.height / 2)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: corner, cornerHeight: corner, transform: nil))
        ctx.clip()

        if a.blurStyle == .solid {
            ctx.setFillColor(a.color.cgColor)
            ctx.fill(r)
            return
        }
        let strength = a.blurStyle == .mosaic ? a.mosaicBlock : a.blurRadius.rounded()
        let key = "\(a.blurStyle.rawValue)|\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width)),\(Int(r.height))|\(Int(strength))"
        var image = blurCache[key]
        if image == nil {
            let crop = CGRect(x: r.minX, y: height - r.maxY, width: r.width, height: r.height)
            guard let part = backdrop?.cropping(to: crop) else { return }
            switch a.blurStyle {
            case .mosaic: image = mosaic(part, block: strength)
            case .secure: image = secureBlur(part, block: a.mosaicBlock * 2.2)
            default: image = gaussian(part, radius: strength)
            }
            if blurCache.count > 60 { blurCache.removeAll() }
            blurCache[key] = image
        }
        guard let image else { return }
        ctx.interpolationQuality = a.blurStyle == .mosaic ? .none : .medium
        ctx.draw(image, in: r)
    }

    /// 粗いマス目に平均化する。
    private func mosaic(_ part: CGImage, block: CGFloat) -> CGImage? {
        let sw = max(1, Int((CGFloat(part.width) / block).rounded(.up)))
        let sh = max(1, Int((CGFloat(part.height) / block).rounded(.up)))
        guard let small = CGContext(data: nil, width: sw, height: sh, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        small.interpolationQuality = .high
        small.draw(part, in: CGRect(x: 0, y: 0, width: sw, height: sh))
        return small.makeImage()
    }

    /// 元の絵を読み戻せないぼかし。大きなマス目で平均してから、マスの境目もぼかす。
    private func secureBlur(_ part: CGImage, block: CGFloat) -> CGImage? {
        guard let small = mosaic(part, block: block),
              let big = makeBitmapContext(width: part.width, height: part.height, like: part) else { return nil }
        big.interpolationQuality = .none
        big.draw(small, in: CGRect(x: 0, y: 0, width: part.width, height: part.height))
        guard let blocky = big.makeImage() else { return nil }
        return gaussian(blocky, radius: block * 0.9)
    }

    private func gaussian(_ part: CGImage, radius: CGFloat) -> CGImage? {
        let input = CIImage(cgImage: part)
        let out = input.clampedToExtent().applyingGaussianBlur(sigma: Double(radius)).cropped(to: input.extent)
        return Self.ciContext.createCGImage(out, from: input.extent)
    }

    func renderImage(_ annotations: [Annotation]) -> CGImage? {
        guard let ctx = makeBitmapContext(width: Int(width), height: Int(height), like: base) else { return nil }
        prepare(annotations)
        drawBase(in: ctx)
        drawSpotlights(annotations, in: ctx)
        for a in annotations { draw(a, in: ctx) }
        guard let image = ctx.makeImage() else { return nil }
        if let crop = cropRect(annotations) {
            // 切り抜きは左上が原点の座標で指定する
            return image.cropping(to: CGRect(x: crop.minX, y: height - crop.maxY, width: crop.width, height: crop.height)) ?? image
        }
        return image
    }
}

func pngData(_ image: CGImage, dpi: CGFloat) -> Data? {
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
    let props: [CFString: Any] = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
    CGImageDestinationAddImage(dest, image, props as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { return nil }
    return data as Data
}

// MARK: - キャンバス

final class CanvasView: NSView, NSTextFieldDelegate {
    let renderer: Renderer
    let dpi: CGFloat
    private(set) var annotations: [Annotation] = []
    /// 取り消し用の控え。描いたものと、台紙（元の画像・位置・広さ）を一緒に持つ。
    private struct Snapshot {
        var annotations: [Annotation]
        var canvas: Renderer.CanvasState
    }
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    private var snapshot: Snapshot { Snapshot(annotations: annotations, canvas: renderer.state) }
    /// 回転・反転・サイズ変更で元の画像そのものを変えた
    private(set) var baseTransformed = false
    /// 背景ツールの設定。変えるとすぐ画面に出る
    var background: BackdropStyle {
        get { renderer.background }
        set {
            guard newValue != renderer.background else { return }
            renderer.background = newValue
            backgroundChanged = true
            BackgroundStore.last = newValue   // 次に背景を入れるときの出発点にする
            updateGeometry()
            needsDisplay = true
            onStateChange?()
        }
    }
    private(set) var backgroundChanged = false
    /// 前の編集の控えから背景を戻す（変更としては数えない）
    func restoreBackground(_ style: BackdropStyle) {
        renderer.background = style
        updateGeometry()
        needsDisplay = true
    }
    /// 背景を付けているときの、仕上がりの中での置き場所
    private var backgroundLayout: BackgroundLayout? {
        renderer.background.enabled
            ? renderer.background.layout(content: CGSize(width: renderer.width, height: renderer.height), scale: dpiScale) : nil
    }
    /// 背景まで含めた全体が、ビューの中で占める範囲
    private var outerRectInView: CGRect = .zero

    /// はみ出したものに合わせて余白を広げる
    var autoExpand = Prefs.editorAutoExpand {
        didSet {
            Prefs.editorAutoExpand = autoExpand
            relayout()
            onStateChange?()
        }
    }

    // いま選んでいる道具と、次に描くものの見た目
    private(set) var tool: Tool = .arrow
    // 色・太さ・種類は、次に編集画面を開いたときも同じものから始める
    private(set) var color: NSColor = ToolMemory.color { didSet { ToolMemory.color = color } }
    private(set) var weight: CGFloat = ToolMemory.weight { didSet { ToolMemory.weight = weight } }
    private(set) var arrowStyle: ArrowStyle = ToolMemory.arrowStyle { didSet { ToolMemory.arrowStyle = arrowStyle } }
    private(set) var blurStyle: BlurStyle = ToolMemory.blurStyle { didSet { ToolMemory.blurStyle = blurStyle } }
    private(set) var textStyle: TextStyle = ToolMemory.textStyle { didSet { ToolMemory.textStyle = textStyle } }

    private(set) var selected: Int? {
        didSet {
            if oldValue != selected { styleSessionOpen = false }
            needsDisplay = true
        }
    }
    var selectedAnnotation: Annotation? {
        guard let i = selected, annotations.indices.contains(i) else { return nil }
        return annotations[i]
    }

    private enum Drag {
        case none
        case creating
        case moving(last: CGPoint)
        case handle(id: Int)
    }
    private var drag: Drag = .none
    private var isDragging: Bool {
        if case .none = drag { return false }
        return true
    }
    private var draft: Annotation?
    private var dragChanged = false
    private var styleSessionOpen = false

    private var editingField: NSTextField?
    private var editingTemplate: Annotation?
    private var editingIsRetype = false

    var onStateChange: (() -> Void)?
    var onSave: (() -> Void)?
    var onToolKey: ((Tool) -> Void)?

    init(renderer: Renderer, dpi: CGFloat) {
        self.renderer = renderer
        self.dpi = dpi
        super.init(frame: .zero)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .cursorUpdate],
                                       owner: self, userInfo: nil))
        registerForDraggedTypes([.fileURL, .png, .tiff])
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    private var dpiScale: CGFloat { renderer.dpiScale }

    // MARK: 表示倍率と位置

    private(set) var viewScale: CGFloat = 1
    private var imageOrigin: CGPoint = .zero

    private func updateGeometry() {
        let pad: CGFloat = 28
        // 背景を付けているときは、背景まで含めた全体が収まるように縮める
        let layout = backgroundLayout
        let outer = layout?.outer ?? CGSize(width: renderer.width, height: renderer.height)
        let fit = min((bounds.width - pad * 2) / outer.width, (bounds.height - pad * 2) / outer.height)
        viewScale = max(0.01, min(fit, 1.5 / dpiScale))
        let origin = CGPoint(x: ((bounds.width - outer.width * viewScale) / 2).rounded(),
                             y: ((bounds.height - outer.height * viewScale) / 2).rounded())
        outerRectInView = CGRect(x: origin.x, y: origin.y, width: outer.width * viewScale, height: outer.height * viewScale)
        let inner = layout?.content.origin ?? .zero
        imageOrigin = CGPoint(x: (origin.x + inner.x * viewScale).rounded(), y: (origin.y + inner.y * viewScale).rounded())
    }
    private var imageRectInView: CGRect {
        CGRect(x: imageOrigin.x, y: imageOrigin.y, width: renderer.width * viewScale, height: renderer.height * viewScale)
    }
    func toImage(_ p: NSPoint) -> CGPoint {
        CGPoint(x: (p.x - imageOrigin.x) / viewScale, y: (p.y - imageOrigin.y) / viewScale)
    }
    func toView(_ p: CGPoint) -> NSPoint {
        NSPoint(x: p.x * viewScale + imageOrigin.x, y: p.y * viewScale + imageOrigin.y)
    }
    private func toView(_ r: CGRect) -> CGRect {
        CGRect(origin: toView(r.origin), size: CGSize(width: r.width * viewScale, height: r.height * viewScale))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateGeometry()
    }

    // MARK: 描画

    override func draw(_ dirtyRect: NSRect) {
        updateGeometry()
        NSColor(white: 0.105, alpha: 1).setFill()
        bounds.fill()
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let frame = imageRectInView

        if let layout = backgroundLayout {
            // 背景を敷いて、スクショの影と内側の余白を描き、角丸の形で切り抜いてから中身を描く
            let outer = outerRectInView
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 24, color: NSColor.black.withAlphaComponent(0.55).cgColor)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fill(outer)
            ctx.restoreGState()
            renderer.backgroundPainter.drawFill(renderer.background, in: outer, base: renderer.base, ctx: ctx)
            let framed = CGRect(x: outer.minX + layout.framed.minX * viewScale, y: outer.minY + layout.framed.minY * viewScale,
                                width: layout.framed.width * viewScale, height: layout.framed.height * viewScale)
            ctx.saveGState()
            ctx.clip(to: outer)
            let shape = renderer.backgroundPainter.drawFrame(renderer.background, framed: framed, radius: layout.radius * viewScale,
                                                             blur: layout.shadowBlur * viewScale, base: renderer.base, ctx: ctx)
            ctx.addPath(shape)
            ctx.clip()
        } else {
            // 画像の下に影を落とす
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 24, color: NSColor.black.withAlphaComponent(0.55).cgColor)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fill(frame)
            ctx.restoreGState()
            ctx.saveGState()
        }

        renderer.prepare(annotations + (draft.map { [$0] } ?? []))
        // 透明の所（広げた余白）は市松模様にする
        if renderer.isExpanded || renderer.base.alphaInfo != .none && renderer.base.alphaInfo != .noneSkipLast
            && renderer.base.alphaInfo != .noneSkipFirst {
            checkerColor.setFill()
            frame.fill()
        }
        let baseFrame = toView(renderer.baseRect)
        let backing = window?.backingScaleFactor ?? 2
        if !inLiveResize, let cached = renderer.displayImage(pixelWidth: Int((baseFrame.width * backing).rounded()),
                                                              pixelHeight: Int((baseFrame.height * backing).rounded())) {
            ctx.saveGState()
            ctx.interpolationQuality = .none
            ctx.draw(cached, in: baseFrame)
            ctx.restoreGState()
        } else {
            ctx.saveGState()
            ctx.interpolationQuality = .low
            ctx.draw(renderer.base, in: baseFrame)
            ctx.restoreGState()
        }

        ctx.saveGState()
        // 余白を広げる設定のときは、ドラッグの途中だけ台紙の外も見せる（離したときに台紙が広がる）
        if !(autoExpand && isDragging) { ctx.clip(to: frame) }
        ctx.translateBy(x: imageOrigin.x, y: imageOrigin.y)
        ctx.scaleBy(x: viewScale, y: viewScale)
        renderer.drawSpotlights(annotations + (draft.map { [$0] } ?? []), in: ctx)
        for a in annotations { renderer.draw(a, in: ctx) }
        if let draft { renderer.draw(draft, in: ctx) }
        ctx.restoreGState()
        ctx.restoreGState()   // 背景の角丸の切り抜きを外す

        // 切り抜き：残す範囲の外を暗くして、縁を白で囲む
        if let crop = (draft?.tool == .crop ? draft : annotations.last(where: { $0.tool == .crop })),
           crop.rect.width > 1, crop.rect.height > 1 {
            let r = toView(crop.rect).intersection(frame)
            let dim = NSBezierPath(rect: frame)
            dim.append(NSBezierPath(rect: r))
            dim.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.6).setFill()
            dim.fill()
            let edge = NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5))
            edge.lineWidth = 1
            NSColor.white.setStroke()
            edge.stroke()
        }
        if let draft, draft.tool == .blur || draft.tool == .spotlight { strokeOutline(toView(draft.rect), dashed: true) }
        if let a = selectedAnnotation { drawSelection(a) }
    }

    private func strokeOutline(_ r: CGRect, dashed: Bool) {
        let path = NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2)
        path.lineWidth = 1
        NSColor.black.withAlphaComponent(0.45).setStroke()
        path.stroke()
        if dashed { path.setLineDash([4, 3], count: 2, phase: 0) }
        NSColor.controlAccentColor.setStroke()
        path.stroke()
    }

    private func drawSelection(_ a: Annotation) {
        if a.isBox {
            strokeOutline(toView(a.rect), dashed: false)
        } else if !a.isLinear {
            strokeOutline(toView(a.bounds).insetBy(dx: -4, dy: -4), dashed: true)
        }
        if a.isLinear, a.ctrl != nil {
            // 曲げのつまみが曲線のどこに付いているか分かるように、細い補助線を引く
            let guide = NSBezierPath()
            guide.move(to: toView(a.p0))
            guide.line(to: toView(a.curvePoint(0.5)))
            guide.line(to: toView(a.p1))
            guide.lineWidth = 1
            guide.setLineDash([3, 3], count: 2, phase: 0)
            NSColor.white.withAlphaComponent(0.45).setStroke()
            guide.stroke()
        }
        for h in a.handles() {
            let c = toView(h.point)
            let size: CGFloat = h.id == 2 || (h.id >= 10 && h.id % 2 == 1) ? 8 : 10
            let dot = NSBezierPath(ovalIn: CGRect(x: c.x - size / 2, y: c.y - size / 2, width: size, height: size))
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
            shadow.shadowBlurRadius = 3
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            shadow.set()
            (h.id == 2 ? NSColor.controlAccentColor : NSColor.white).setFill()
            dot.fill()
            NSGraphicsContext.restoreGraphicsState()
            (h.id == 2 ? NSColor.white : NSColor.controlAccentColor).setStroke()
            dot.lineWidth = 1.5
            dot.stroke()
        }
    }

    // MARK: 状態の変更（道具バーから呼ぶ）

    func setTool(_ t: Tool) {
        commitText()
        tool = t
        if t != .select { selected = nil }
        needsDisplay = true
        onStateChange?()
    }

    private func mutateSelection(_ body: (inout Annotation) -> Void) {
        guard let i = selected, annotations.indices.contains(i) else { return }
        if !styleSessionOpen {
            pushUndo()
            styleSessionOpen = true
        }
        body(&annotations[i])
        relayout()
    }

    /// 描いたものの位置が変わったあとに呼ぶ。余白を広げる設定なら、台紙の広さを決め直す。
    private func relayout() {
        if autoExpand { renderer.layout(&annotations) }
        updateGeometry()
        needsDisplay = true
    }

    func setColor(_ c: NSColor) {
        color = c
        mutateSelection { $0.color = c }
        editingField?.textColor = c
        editingTemplate?.color = c
    }
    func setWeight(_ w: CGFloat) {
        let clamped = max(0, min(1, w))
        weight = clamped
        mutateSelection { $0.weight = clamped }
    }
    func setArrowStyle(_ s: ArrowStyle) {
        arrowStyle = s
        styleSessionOpen = false
        mutateSelection { $0.arrowStyle = s }
    }
    func setBlurStyle(_ s: BlurStyle) {
        blurStyle = s
        styleSessionOpen = false
        mutateSelection { $0.blurStyle = s }
    }
    func setTextStyle(_ s: TextStyle) {
        textStyle = s
        styleSessionOpen = false
        mutateSelection { $0.textStyle = s }
        editingTemplate?.textStyle = s
        if let field = editingField, let size = field.font?.pointSize { field.font = s.font(ofSize: size) }
    }

    // MARK: 履歴

    /// 開いてから何か変えたか（閉じるときの確認に使う）
    var hasChanges: Bool { !undoStack.isEmpty || editingField != nil || backgroundChanged }

    private func pushUndo() {
        undoStack.append(snapshot)
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    private func apply(_ s: Snapshot) {
        annotations = s.annotations
        renderer.state = s.canvas
        selected = nil
        updateGeometry()
        needsDisplay = true
        onStateChange?()
    }

    @objc func undo(_ sender: Any?) {
        commitText()
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(snapshot)
        apply(prev)
    }

    @objc func redo(_ sender: Any?) {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(snapshot)
        apply(next)
    }

    /// ペースト: クリップボードの画像を足す。
    @objc func paste(_ sender: Any?) {
        let found = imagesFrom(pasteboard: .general)
        guard !found.isEmpty else {
            NSSound.beep()
            return
        }
        for item in found { addImage(item.image, dpi: item.dpi, center: nil) }
    }

    // MARK: 画像を足す

    /// ほかの画像を足す。center は台紙の座標。nil なら元の画像の真ん中に置く。
    func addImage(_ image: CGImage, dpi imageDPI: CGFloat, center: CGPoint?) {
        commitText()
        // 解像度をそろえた大きさで置く。元の画像より大きいときは収まる大きさに縮める
        let k = dpi / max(1, imageDPI)
        var size = CGSize(width: CGFloat(image.width) * k, height: CGFloat(image.height) * k)
        let limit = renderer.baseRect.size
        let fit = min(1, limit.width / size.width, limit.height / size.height)
        size = CGSize(width: (size.width * fit).rounded(), height: (size.height * fit).rounded())
        let origin: CGPoint
        if let c = center {
            origin = CGPoint(x: (c.x - size.width / 2).rounded(), y: (c.y - size.height / 2).rounded())
        } else if autoExpand, size.width > limit.width * 0.6 || size.height > limit.height * 0.6 {
            // 大きい画像は元の画像を隠してしまうので、右どなりに上をそろえて並べる
            let content = annotations.filter { $0.tool == .image }.reduce(renderer.baseRect) { $0.union($1.rect) }
            origin = CGPoint(x: content.maxX, y: renderer.baseRect.maxY - size.height)
        } else {
            origin = CGPoint(x: (renderer.baseRect.midX - size.width / 2).rounded(), y: (renderer.baseRect.midY - size.height / 2).rounded())
        }
        var a = Annotation(tool: .image, p0: origin, p1: CGPoint(x: origin.x + size.width, y: origin.y + size.height),
                           color: color, weight: weight, scale: dpiScale)
        a.image = image
        pushUndo()
        // 画像は描いたものの下に入れる（足した画像どうしは、あとから足したものが上）
        let index = annotations.filter { $0.tool == .image }.count
        annotations.insert(a, at: index)
        tool = .select   // 足した直後は動かしたいので「選択」に切り替える
        selected = index
        relayout()
        onStateChange?()
        log("編集画面: 画像を足した \(image.width)x\(image.height) → \(Int(size.width))x\(Int(size.height))")
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        imagesFrom(pasteboard: sender.draggingPasteboard).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let found = imagesFrom(pasteboard: sender.draggingPasteboard)
        guard !found.isEmpty else { return false }
        let p = toImage(convert(sender.draggingLocation, from: nil))
        for (n, item) in found.enumerated() {
            addImage(item.image, dpi: item.dpi, center: CGPoint(x: p.x + CGFloat(n) * 24 * dpiScale, y: p.y - CGFloat(n) * 24 * dpiScale))
        }
        window?.makeFirstResponder(self)
        return true
    }

    // MARK: 回転・反転・サイズ変更

    /// 元の画像も描いたものも一緒に回す・裏返す。
    func transform(_ op: CanvasOp) {
        commitText()
        pushUndo()
        let size = CGSize(width: renderer.width, height: renderer.height)
        var state = renderer.state
        let old = renderer.baseRect
        let a = op.map(old.origin, in: size), b = op.map(CGPoint(x: old.maxX, y: old.maxY), in: size)
        state.base = op.apply(to: state.base) ?? state.base
        state.baseOrigin = CGPoint(x: min(a.x, b.x), y: min(a.y, b.y))
        if op.swapsAxes { state.size = CGSize(width: size.height, height: size.width) }
        renderer.state = state
        annotations = annotations.map { $0.transformed(by: op, in: size) }
        baseTransformed = true
        selected = nil
        relayout()
        onStateChange?()
        log("編集画面: \(op.label) → \(Int(renderer.width))x\(Int(renderer.height))")
    }

    /// 全体の大きさを変える。描いたものも同じ割合で大きさが変わる。
    func resize(to target: CGSize) {
        commitText()
        let size = CGSize(width: renderer.width, height: renderer.height)
        guard target.width >= 1, target.height >= 1, target != size else { return }
        let sx = target.width / size.width, sy = target.height / size.height
        var state = renderer.state
        let newBase = CGSize(width: max(1, (CGFloat(state.base.width) * sx).rounded()),
                             height: max(1, (CGFloat(state.base.height) * sy).rounded()))
        guard let scaledBase = resampled(state.base, width: Int(newBase.width), height: Int(newBase.height)) else {
            NSSound.beep()
            return
        }
        pushUndo()
        state.base = scaledBase
        state.baseOrigin = CGPoint(x: (state.baseOrigin.x * sx).rounded(), y: (state.baseOrigin.y * sy).rounded())
        state.size = target
        renderer.state = state
        annotations = annotations.map { $0.scaled(x: sx, y: sy) }
        baseTransformed = true
        selected = nil
        relayout()
        onStateChange?()
        log("編集画面: サイズ変更 \(Int(size.width))x\(Int(size.height)) → \(Int(renderer.width))x\(Int(renderer.height))")
    }

    @objc func copy(_ sender: Any?) {
        commitText()
        guard let image = renderer.renderFinal(annotations), let data = pngData(image, dpi: dpi) else { return }
        copyPNGDataToPasteboard(data)
        log("編集画面からコピー 注釈=\(annotations.count)")
    }

    @objc func saveDocument(_ sender: Any?) { onSave?() }

    func deleteSelected() {
        guard let i = selected, annotations.indices.contains(i) else { return }
        pushUndo()
        annotations.remove(at: i)
        selected = nil
        relayout()
        onStateChange?()
    }

    private func makeAnnotation(_ tool: Tool, at p: CGPoint) -> Annotation {
        var a = Annotation(tool: tool, p0: p, p1: p, color: color, weight: weight, scale: dpiScale,
                           arrowStyle: arrowStyle, blurStyle: blurStyle, textStyle: textStyle)
        if a.isFreehand { a.points = [p] }
        return a
    }

    /// 前に編集したときの注釈を戻す（取り消しの履歴には積まない）。
    func restore(_ list: [Annotation], baseOrigin: CGPoint? = nil, size: CGSize? = nil) {
        annotations = list
        if let baseOrigin, let size {
            var state = renderer.state
            state.baseOrigin = baseOrigin
            state.size = size
            renderer.state = state
        }
        selected = nil
        updateGeometry()
        needsDisplay = true
    }

    /// 注釈を足して選択状態にする。
    func add(_ a: Annotation) {
        pushUndo()
        var a = a
        if a.tool == .crop { annotations.removeAll { $0.tool == .crop } }   // 切り抜きは1つだけ
        a.normalizeBox()
        annotations.append(a)
        selected = annotations.count - 1
        relayout()
        // 台紙がずれても、足したものが選ばれたままになるようにする
        onStateChange?()
    }

    /// いくつもまとめて足す（取り消しは1回で全部戻る）。
    func addMany(_ list: [Annotation]) {
        guard !list.isEmpty else { return }
        pushUndo()
        for var a in list {
            a.normalizeBox()
            annotations.append(a)
        }
        selected = nil
        relayout()
        onStateChange?()
    }

    /// いまの色・太さ・種類で、新しい注釈のひな形を作る
    func template(_ tool: Tool, p0: CGPoint, p1: CGPoint) -> Annotation {
        var a = makeAnnotation(tool, at: p0)
        a.p1 = p1
        return a
    }

    /// 道具の設定をまとめて変える（保存した設定を呼び出すとき）
    func applyPreset(tool: Tool, color: NSColor, weight: CGFloat, arrow: ArrowStyle, blur: BlurStyle, text: TextStyle) {
        setTool(tool)
        self.color = color
        self.weight = weight
        arrowStyle = arrow
        blurStyle = blur
        textStyle = text
        needsDisplay = true
        onStateChange?()
    }

    /// 画面に見えている範囲の真ん中（画像の座標）
    var visibleCenter: CGPoint { toImage(NSPoint(x: bounds.midX, y: bounds.midY)) }

    private func nextCounterNumber() -> Int {
        (annotations.filter { $0.tool == .counter }.map(\.number).max() ?? 0) + 1
    }

    // MARK: マウス

    private func handleHit(_ a: Annotation, at p: CGPoint) -> Int? {
        let reach = 9 / viewScale
        // 端のつまみを曲げのつまみより優先する
        let ordered = a.handles().sorted { ($0.id == 2 ? 1 : 0) < ($1.id == 2 ? 1 : 0) }
        return ordered.first { ($0.point - p).length <= reach }?.id
    }

    private func topmostHit(_ p: CGPoint) -> Int? {
        let tolerance = 6 / viewScale
        // 足した画像は「選択」の道具のときだけつかめる（ほかの道具のときは、画像の上にも描けるように素通しにする）
        return annotations.indices.reversed().first {
            (tool == .select || annotations[$0].tool != .image) && annotations[$0].hit(p, tolerance: tolerance)
        }
    }

    private func constrained(_ p: CGPoint, for a: Annotation, shift: Bool) -> CGPoint {
        guard shift else { return p }
        if a.isLinear { return snapAngle(from: a.p0, to: p) }
        if a.isBox {
            let d = p - a.p0
            let side = max(abs(d.x), abs(d.y))
            return CGPoint(x: a.p0.x + (d.x < 0 ? -side : side), y: a.p0.y + (d.y < 0 ? -side : side))
        }
        return p
    }

    override func mouseDown(with event: NSEvent) {
        if editingField != nil {
            commitText()
            return
        }
        window?.makeFirstResponder(self)
        let vp = convert(event.locationInWindow, from: nil)
        let p = toImage(vp)
        dragChanged = false
        styleSessionOpen = false

        // ① 選んでいるもののつまみ
        if let a = selectedAnnotation, let id = handleHit(a, at: p) {
            drag = .handle(id: id)
            return
        }
        // ② 描いてあるものをつかむ（選んでいるものは内側でもつかめる）
        var target = topmostHit(p)
        if target == nil, let i = selected, let a = selectedAnnotation, a.bounds.contains(p) { target = i }
        if let i = target {
            if event.clickCount == 2, annotations[i].tool == .text {
                editText(at: i)
                return
            }
            selected = i
            annotations[i].normalizeBox()
            drag = .moving(last: p)
            NSCursor.closedHand.set()
            onStateChange?()
            return
        }
        // ③ 何もない所: 新しく描く
        let hadSelection = selected != nil
        selected = nil
        switch tool {
        case .select:
            drag = .none
        case .text:
            beginText(at: vp, template: nil)
        case .counter:
            var a = makeAnnotation(.counter, at: p)
            a.number = nextCounterNumber()
            add(a)
            drag = .moving(last: p)
            dragChanged = true   // 置いた直後のドラッグは同じ操作として扱う
        default:
            draft = makeAnnotation(tool, at: p)
            drag = .creating
        }
        if hadSelection { onStateChange?() }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = toImage(convert(event.locationInWindow, from: nil))
        let shift = event.modifierFlags.contains(.shift)
        switch drag {
        case .creating:
            guard let d = draft else { return }
            if d.isFreehand {
                if d.tool == .highlighter && shift {
                    // shift でまっすぐ横に引く
                    draft?.points = [d.p0, CGPoint(x: p.x, y: d.p0.y)]
                } else if let last = d.points.last, (p - last).length >= 1.5 / viewScale {
                    draft?.points.append(p)
                }
                draft?.p1 = p
            } else {
                draft?.p1 = constrained(p, for: d, shift: shift)
            }
        case .moving(let last):
            guard let i = selected, annotations.indices.contains(i) else { return }
            if !dragChanged {
                pushUndo()
                dragChanged = true
            }
            annotations[i].move(by: p - last)
            drag = .moving(last: p)
        case .handle(let id):
            guard let i = selected, annotations.indices.contains(i) else { return }
            if !dragChanged {
                pushUndo()
                dragChanged = true
            }
            annotations[i].moveHandle(id, to: p, constrain: shift)
        case .none:
            return
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        switch drag {
        case .creating:
            if let d = draft, d.isFreehand ? d.points.count >= 2 : (d.p1 - d.p0).length > 5 / viewScale {
                draft = nil
                add(d)
            } else {
                draft = nil
            }
        case .handle, .moving:
            if let i = selected, annotations.indices.contains(i) { annotations[i].normalizeBox() }
        case .none:
            break
        }
        let wasDragging = isDragging
        drag = .none
        if wasDragging { relayout() }
        needsDisplay = true
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    private func updateCursor(at vp: NSPoint) {
        guard bounds.contains(vp) else { return }
        let p = toImage(vp)
        if let a = selectedAnnotation, handleHit(a, at: p) != nil {
            NSCursor.crosshair.set()
        } else if topmostHit(p) != nil || (selectedAnnotation?.bounds.contains(p) ?? false) {
            NSCursor.openHand.set()
        } else {
            switch tool {
            case .select: NSCursor.arrow.set()
            case .text: NSCursor.iBeam.set()
            default: NSCursor.crosshair.set()
            }
        }
    }

    // MARK: キーボード

    override func keyDown(with event: NSEvent) {
        let step: CGFloat = (event.modifierFlags.contains(.shift) ? 10 : 1) * dpiScale
        switch event.keyCode {
        case 51, 117: deleteSelected()
        case 53: selected = nil; onStateChange?()
        case 123: nudge(CGPoint(x: -step, y: 0))
        case 124: nudge(CGPoint(x: step, y: 0))
        case 125: nudge(CGPoint(x: 0, y: -step))
        case 126: nudge(CGPoint(x: 0, y: step))
        default:
            let mods = event.modifierFlags.intersection([.command, .control, .option])
            if mods.isEmpty, let ch = event.charactersIgnoringModifiers?.lowercased(),
               let t = Tool.drawable.first(where: { $0.key == ch }) {
                onToolKey?(t)
            } else {
                super.keyDown(with: event)
            }
        }
    }

    private func nudge(_ d: CGPoint) {
        mutateSelection { $0.move(by: d) }
    }

    // MARK: 文字入力

    private func beginText(at vp: NSPoint, template: Annotation?) {
        let style = template ?? makeAnnotation(.text, at: toImage(vp))
        let font = style.textStyle.font(ofSize: max(9, style.fontSize * viewScale))
        let lineHeight = (font.ascender - font.descender + font.leading).rounded(.up)
        let origin: NSPoint
        if let template {
            let o = toView(template.p0)
            origin = NSPoint(x: o.x - 2, y: o.y - 2)
        } else {
            origin = NSPoint(x: vp.x, y: vp.y - lineHeight / 2)
        }
        // 欄は画像の右はしまで（画像の外の余白へはみ出さない）
        let width = max(160, min(bounds.maxX, imageRectInView.maxX) - origin.x - 6)
        let field = NSTextField(frame: NSRect(x: origin.x, y: origin.y, width: width, height: lineHeight + 4))
        field.font = font
        field.textColor = style.color
        field.stringValue = template?.text ?? ""
        field.isBordered = false
        field.drawsBackground = true
        field.backgroundColor = NSColor.black.withAlphaComponent(0.22)
        field.wantsLayer = true
        field.layer?.borderWidth = 1
        field.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.9).cgColor
        field.layer?.cornerRadius = 3
        field.focusRingType = .none
        field.placeholderString = "文字を入力して return"
        field.delegate = self
        field.target = self
        field.action = #selector(textFieldReturned)
        field.cell?.isScrollable = true
        field.cell?.usesSingleLineMode = true
        addSubview(field)
        editingField = field
        editingTemplate = style
        editingIsRetype = template != nil
        window?.makeFirstResponder(field)
    }

    private func editText(at index: Int) {
        let original = annotations[index]
        pushUndo()
        annotations.remove(at: index)
        selected = nil
        beginText(at: toView(original.p0), template: original)
        needsDisplay = true
    }

    @objc private func textFieldReturned() { commitText() }

    func controlTextDidEndEditing(_ obj: Notification) { commitText() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {   // esc: 入力を取りやめる
            editingField?.stringValue = editingIsRetype ? (editingTemplate?.text ?? "") : ""
            commitText()
            return true
        }
        return false
    }

    /// 動作確認用: 入力中の文字欄に文字を入れて確定する。欄が出ていなければ false。
    func testTypeText(_ string: String) -> Bool {
        guard let field = editingField else { return false }
        field.stringValue = string
        commitText()
        return true
    }

    func commitText() {
        guard let field = editingField, var a = editingTemplate else { return }
        let retype = editingIsRetype
        editingField = nil
        editingTemplate = nil
        editingIsRetype = false
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let origin = toImage(NSPoint(x: field.frame.minX + 2, y: field.frame.minY + 2))
        field.removeFromSuperview()
        if !text.isEmpty {
            a.text = text
            a.p0 = origin
            a.p1 = origin
            if retype {
                // 打ち直しは editText が履歴を積んでいるので、ここでは積まない
                annotations.append(a)
                selected = annotations.count - 1
                relayout()
                onStateChange?()
            } else {
                add(a)
            }
        }
        window?.makeFirstResponder(self)
        needsDisplay = true
    }
}

// MARK: - 道具バーの部品

func tintedSymbol(_ name: String, pointSize: CGFloat, color: NSColor, weight: NSFont.Weight = .medium) -> NSImage? {
    guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)) else { return nil }
    return NSImage(size: base.size, flipped: false) { rect in
        base.draw(in: rect)
        color.set()
        rect.fill(using: .sourceAtop)
        return true
    }
}

/// アイコンの下に名前が付く道具ボタン。caption が空ならアイコンだけ。
final class ToolButton: NSButton {
    var isOn = false { didSet { needsDisplay = true } }
    private var hovering = false { didSet { needsDisplay = true } }
    private var symbol: String
    private let caption: String

    /// アイコンを差し替える（再生と一時停止の切り替えなど）
    func setSymbol(_ name: String) {
        guard name != symbol else { return }
        symbol = name
        needsDisplay = true
    }

    init(symbol: String, caption: String, size: NSSize, target: AnyObject, action: Selector) {
        self.symbol = symbol
        self.caption = caption
        super.init(frame: NSRect(origin: .zero, size: size))
        self.target = target
        self.action = action
        title = ""
        isBordered = false
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: size.width).isActive = true
        heightAnchor.constraint(equalToConstant: size.height).isActive = true
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func draw(_ dirtyRect: NSRect) {
        let bg = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
        if isOn {
            NSColor.controlAccentColor.setFill()
            bg.fill()
        } else if isHighlighted {
            NSColor.white.withAlphaComponent(0.16).setFill()
            bg.fill()
        } else if hovering && isEnabled {
            NSColor.white.withAlphaComponent(0.09).setFill()
            bg.fill()
        }
        let fg = isOn ? NSColor.white : NSColor(white: isEnabled ? 0.88 : 0.38, alpha: 1)
        let hasCaption = !caption.isEmpty
        // NSButton は上が原点（y が下向き）なので、アイコンを上・名前を下に置く
        if let icon = tintedSymbol(symbol, pointSize: hasCaption ? 15 : 14, color: fg) {
            let y = hasCaption ? bounds.midY - icon.size.height / 2 - 7 : bounds.midY - icon.size.height / 2
            icon.draw(in: NSRect(x: bounds.midX - icon.size.width / 2, y: y, width: icon.size.width, height: icon.size.height),
                      from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        if hasCaption {
            let label = NSAttributedString(string: caption, attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: isOn ? .semibold : .regular),
                .foregroundColor: fg.withAlphaComponent(isOn ? 1 : 0.85),
            ])
            let size = label.size()
            label.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.height - size.height - 5))
        }
    }
}

/// 文字だけの角丸ボタン（コピー・保存・完了）。
final class PillButton: NSButton {
    private var hovering = false { didSet { needsDisplay = true } }
    private let primary: Bool
    var caption: String { didSet { needsDisplay = true } }

    init(caption: String, primary: Bool, target: AnyObject, action: Selector) {
        self.caption = caption
        self.primary = primary
        super.init(frame: .zero)
        self.target = target
        self.action = action
        title = ""
        isBordered = false
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 30).isActive = true
        widthAnchor.constraint(equalToConstant: primary ? 76 : 78).isActive = true
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func draw(_ dirtyRect: NSRect) {
        let bg = NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8)
        let fill: NSColor
        if primary {
            let accent = NSColor.controlAccentColor
            fill = isHighlighted ? (accent.blended(withFraction: 0.2, of: .black) ?? accent)
                : hovering ? (accent.blended(withFraction: 0.12, of: .white) ?? accent) : accent
        } else {
            fill = NSColor.white.withAlphaComponent(isHighlighted ? 0.22 : hovering ? 0.17 : 0.11)
        }
        fill.setFill()
        bg.fill()
        let label = NSAttributedString(string: caption, attributes: [
            .font: NSFont.systemFont(ofSize: 12.5, weight: primary ? .semibold : .medium),
            .foregroundColor: NSColor.white,
        ])
        let size = label.size()
        label.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
    }
}

final class ColorDot: NSButton {
    var color: NSColor { didSet { needsDisplay = true } }
    var isOn = false { didSet { needsDisplay = true } }

    init(color: NSColor, target: AnyObject, action: Selector) {
        self.color = color
        super.init(frame: NSRect(x: 0, y: 0, width: 26, height: 26))
        self.target = target
        self.action = action
        title = ""
        isBordered = false
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 26).isActive = true
        heightAnchor.constraint(equalToConstant: 26).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let inset: CGFloat = isOn ? 5.5 : 4.5
        let dot = NSBezierPath(ovalIn: bounds.insetBy(dx: inset, dy: inset))
        color.setFill()
        dot.fill()
        NSColor.white.withAlphaComponent(0.28).setStroke()
        dot.lineWidth = 1
        dot.stroke()
        if isOn {
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 1.5, dy: 1.5))
            ring.lineWidth = 2
            NSColor.white.setStroke()
            ring.stroke()
        }
    }
}

/// 設定バーの小さな見出し。
func optionLabel(_ text: String) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = .systemFont(ofSize: 11, weight: .medium)
    label.textColor = NSColor(white: 0.62, alpha: 1)
    return label
}

func separatorView() -> NSView {
    let v = NSView()
    v.wantsLayer = true
    v.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
    v.translatesAutoresizingMaskIntoConstraints = false
    v.widthAnchor.constraint(equalToConstant: 1).isActive = true
    v.heightAnchor.constraint(equalToConstant: 22).isActive = true
    return v
}

// MARK: - 編集ウィンドウ

final class EditorController: NSObject, NSWindowDelegate {
    static var openEditors: [EditorController] = []
    /// 動作確認のときは画面に出さず、前面も奪わない。
    static var headless = false
    static let palette: [NSColor] = [
        NSColor(srgbRed: 1.00, green: 0.23, blue: 0.19, alpha: 1), // 赤
        NSColor(srgbRed: 1.00, green: 0.58, blue: 0.00, alpha: 1), // 橙
        NSColor(srgbRed: 1.00, green: 0.84, blue: 0.04, alpha: 1), // 黄
        NSColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1), // 緑
        NSColor(srgbRed: 0.04, green: 0.52, blue: 1.00, alpha: 1), // 青
        NSColor(srgbRed: 0.69, green: 0.32, blue: 0.87, alpha: 1), // 紫
        NSColor(srgbRed: 0.09, green: 0.09, blue: 0.10, alpha: 1), // 黒
        NSColor(srgbRed: 1.00, green: 1.00, blue: 1.00, alpha: 1), // 白
    ]

    let fileURL: URL
    let dpi: CGFloat
    let window: NSWindow
    let canvas: CanvasView
    private var toolButtons: [ToolButton] = []
    private var colorDots: [ColorDot] = []
    private var customDots: [ColorDot] = []
    private var imageButton: ToolButton!
    private var emojiButton: ToolButton!
    private var emojiPopover: NSPopover?
    private var resizePopover: NSPopover?
    private var backgroundButton: ToolButton!
    private var backgroundPopover: NSPopover?
    private(set) var backgroundPanel: BackgroundPanelController?
    /// 色のパネルで選んでいる最中か（最中は、いちばん新しい自作の色を上書きしていく）
    private var pickingCustomColor = false
    private var weightSlider: NSSlider!
    private var weightLabel: NSTextField!
    private var arrowPicker: NSSegmentedControl!
    private var blurPicker: NSSegmentedControl!
    private var textPicker: NSSegmentedControl!
    private var styleGroup: NSStackView!
    private var hintLabel: NSTextField!
    private var deleteButton: ToolButton!
    private var copyButton: PillButton!
    private var closingOnPurpose = false
    /// 前の編集の控えから開いた
    fileprivate(set) var hadProject = false
    /// saved=true は保存先フォルダへ保存して閉じた。false は「完了」で閉じた。
    private let onFinish: (_ saved: Bool) -> Void

    @discardableResult
    static func open(file: URL, onFinish: @escaping (_ saved: Bool) -> Void) -> EditorController? {
        if let existing = openEditors.first(where: { $0.fileURL == file }) {
            NSApp.activate(ignoringOtherApps: true)
            existing.window.makeKeyAndOrderFront(nil)
            return existing
        }
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            log("編集画面: 画像を読めない \(file.path)")
            NSSound.beep()
            return nil
        }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let dpi = (props?[kCGImagePropertyDPIWidth] as? CGFloat) ?? 72
        let controller: EditorController
        if let project = EditProject.load(for: file) {
            // 前に編集した画像：編集前の画像に、描いたものを動かせる状態で戻す
            controller = EditorController(file: file, image: project.base, dpi: project.dpi, onFinish: onFinish)
            controller.canvas.restore(project.annotations, baseOrigin: project.baseOrigin, size: project.size)
            if let background = project.background { controller.canvas.restoreBackground(background) }
            controller.hadProject = true
            log("編集画面: 前の編集を戻した 注釈=\(project.annotations.count) \(file.lastPathComponent)")
        } else {
            controller = EditorController(file: file, image: image, dpi: dpi, onFinish: onFinish)
        }
        openEditors.append(controller)
        if !headless {
            NSApp.activate(ignoringOtherApps: true)
            controller.window.makeKeyAndOrderFront(nil)
        }
        controller.window.makeFirstResponder(controller.canvas)
        return controller
    }

    private static let topBarHeight: CGFloat = 60
    private static let optionBarHeight: CGFloat = 44

    private init(file: URL, image: CGImage, dpi: CGFloat, onFinish: @escaping (Bool) -> Void) {
        self.fileURL = file
        self.dpi = dpi
        self.onFinish = onFinish
        let dpiScale = max(1, dpi / 72)
        let renderer = Renderer(base: image, dpiScale: dpiScale)
        // 背景は入れない状態で開く。入れたときは、前に使った設定から始まる
        renderer.background = BackgroundStore.last
        renderer.background.enabled = false
        canvas = CanvasView(renderer: renderer, dpi: dpi)

        // マウスがある画面に、その画面に収まる大きさで開く
        let screen = screenUnderMouse()
        let visible = screen.visibleFrame
        let chrome = Self.topBarHeight + Self.optionBarHeight
        let natural = CGSize(width: CGFloat(image.width) / dpiScale + 56, height: CGFloat(image.height) / dpiScale + 56 + chrome)
        let size = CGSize(width: min(max(natural.width, 940), visible.width * 0.92),
                          height: min(max(natural.height, 560), visible.height * 0.9))
        // screen: を渡すと contentRect はその画面の左下からの位置として扱われる
        let origin = CGPoint(x: visible.midX - size.width / 2 - screen.frame.minX,
                             y: visible.midY - size.height / 2 - screen.frame.minY)
        window = NSWindow(contentRect: NSRect(origin: origin, size: size),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false,
                          screen: screen)
        window.title = "Kiritori"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 940, height: 560)
        window.appearance = NSAppearance(named: .darkAqua)
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(white: 0.165, alpha: 1)
        super.init()
        window.delegate = self
        canvas.onSave = { [weak self] in self?.saveTapped() }
        canvas.onStateChange = { [weak self] in self?.syncUI() }
        canvas.onToolKey = { [weak self] tool in self?.canvas.setTool(tool) }
        buildUI()
        syncUI()
    }

    // MARK: 画面の組み立て

    private func buildUI() {
        // 上の段: 道具
        toolButtons = Tool.drawable.map { tool in
            let b = ToolButton(symbol: tool.symbol, caption: tool.label, size: NSSize(width: 46, height: 48),
                               target: self, action: #selector(toolTapped(_:)))
            b.tag = tool.rawValue
            b.toolTip = "\(tool.label)（\(tool.key.uppercased()) キー）"
            return b
        }
        imageButton = ToolButton(symbol: "photo.on.rectangle.angled", caption: "画像", size: NSSize(width: 46, height: 48),
                                 target: self, action: #selector(imageMenuTapped(_:)))
        imageButton.toolTip = "画像の追加・回転・反転・サイズ変更"
        backgroundButton = ToolButton(symbol: "rectangle.inset.filled", caption: "背景", size: NSSize(width: 46, height: 48),
                                      target: self, action: #selector(backgroundTapped))
        backgroundButton.toolTip = "まわりに背景を敷いて、余白・角の丸み・影を付ける"
        emojiButton = ToolButton(symbol: "face.smiling", caption: "絵文字", size: NSSize(width: 46, height: 48),
                                 target: self, action: #selector(emojiTapped))
        emojiButton.toolTip = "絵文字を置く。置いたあとはドラッグで動かして、左の「大きさ」で大きさを変えられます"
        let toolRow = NSStackView(views: toolButtons + [emojiButton, separatorView(), imageButton, backgroundButton])
        toolRow.orientation = .horizontal
        toolRow.spacing = 2
        toolRow.setHuggingPriority(.required, for: .horizontal)

        func iconButton(_ symbol: String, _ tip: String, _ action: Selector) -> ToolButton {
            let b = ToolButton(symbol: symbol, caption: "", size: NSSize(width: 34, height: 30), target: self, action: action)
            b.toolTip = tip
            return b
        }
        deleteButton = iconButton("trash", "選んだものを消す（delete）", #selector(deleteTapped))
        let presets = iconButton("star", "道具の設定を保存する・呼び出す", #selector(presetMenuTapped(_:)))
        let undo = iconButton("arrow.uturn.backward", "取り消す（⌘Z）", #selector(undoTapped))
        let redo = iconButton("arrow.uturn.forward", "やり直す（⇧⌘Z）", #selector(redoTapped))

        copyButton = PillButton(caption: "コピー", primary: false, target: self, action: #selector(copyTapped))
        let save = PillButton(caption: "保存", primary: false, target: self, action: #selector(saveTapped))
        let done = PillButton(caption: "完了", primary: true, target: self, action: #selector(doneTapped))
        copyButton.toolTip = "編集後の画像をコピーします（⌘C）"
        save.toolTip = "編集を反映して保存先フォルダへ保存します（⌘S）"
        done.toolTip = "編集を画像に反映して小窓に戻ります"

        // 道具が増えたので、消す・取り消す・やり直すは下の段の右端へ置く
        let topBar = NSStackView(views: [toolRow, NSView(), copyButton, save, done])
        topBar.orientation = .horizontal
        topBar.distribution = .fill
        topBar.spacing = 6
        topBar.edgeInsets = NSEdgeInsets(top: 6, left: 14, bottom: 6, right: 14)

        // 下の段: 選んでいる道具・ものの設定
        colorDots = Self.palette.map { ColorDot(color: $0, target: self, action: #selector(colorTapped(_:))) }
        // 自分で作った色（3つまで）と、色を作るボタン
        customDots = (0..<CustomColors.limit).map { _ in ColorDot(color: .clear, target: self, action: #selector(colorTapped(_:))) }
        let plus = ColorPlusDot(target: self, action: #selector(customColorTapped))
        let colorRow = NSStackView(views: colorDots + customDots + [plus])
        colorRow.orientation = .horizontal
        colorRow.spacing = 0
        colorRow.setHuggingPriority(.required, for: .horizontal)

        weightLabel = optionLabel("太さ")
        weightSlider = NSSlider(value: Double(canvas.weight), minValue: 0, maxValue: 1, target: self, action: #selector(weightChanged(_:)))
        weightSlider.controlSize = .small
        weightSlider.isContinuous = true
        weightSlider.translatesAutoresizingMaskIntoConstraints = false
        weightSlider.widthAnchor.constraint(equalToConstant: 120).isActive = true

        arrowPicker = NSSegmentedControl(images: ArrowStyle.allCases.map(Self.arrowPreview), trackingMode: .selectOne,
                                         target: self, action: #selector(arrowStyleChanged(_:)))
        for style in ArrowStyle.allCases { arrowPicker.setToolTip(style.label, forSegment: style.rawValue) }
        blurPicker = NSSegmentedControl(labels: BlurStyle.allCases.map(\.label), trackingMode: .selectOne,
                                        target: self, action: #selector(blurStyleChanged(_:)))
        textPicker = NSSegmentedControl(images: TextStyle.ordered.map { $0.preview() }, trackingMode: .selectOne,
                                        target: self, action: #selector(textStyleChanged(_:)))
        for (n, style) in TextStyle.ordered.enumerated() {
            textPicker.setToolTip(style.label, forSegment: n)
            textPicker.setWidth(36, forSegment: n)
        }

        for style in ArrowStyle.allCases { arrowPicker.setWidth(46, forSegment: style.rawValue) }
        for picker in [arrowPicker!, blurPicker!, textPicker!] {
            picker.setContentHuggingPriority(.required, for: .horizontal)
            picker.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        weightSlider.setContentHuggingPriority(.required, for: .horizontal)
        styleGroup = NSStackView(views: [separatorView(), optionLabel("種類"), arrowPicker, blurPicker, textPicker])
        styleGroup.orientation = .horizontal
        styleGroup.spacing = 8
        styleGroup.setHuggingPriority(.required, for: .horizontal)

        hintLabel = NSTextField(labelWithString: "")
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = NSColor(white: 0.55, alpha: 1)
        hintLabel.lineBreakMode = .byTruncatingTail
        hintLabel.alignment = .left
        hintLabel.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        hintLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hintLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let optionBar = NSStackView(views: [colorRow, separatorView(), weightLabel, weightSlider, styleGroup, hintLabel,
                                            presets, deleteButton, undo, redo])
        optionBar.orientation = .horizontal
        optionBar.distribution = .fill
        optionBar.spacing = 10
        optionBar.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 16)
        optionBar.wantsLayer = true
        optionBar.layer?.backgroundColor = NSColor(white: 0.135, alpha: 1).cgColor

        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(white: 0.165, alpha: 1).cgColor
        for v in [topBar, optionBar, canvas] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        window.contentView = content
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: content.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: Self.topBarHeight),
            optionBar.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            optionBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            optionBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            optionBar.heightAnchor.constraint(equalToConstant: Self.optionBarHeight),
            canvas.topAnchor.constraint(equalTo: optionBar.bottomAnchor),
            canvas.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            canvas.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }

    /// 矢印の種類を選ぶボタン用の小さな見本。
    private static func arrowPreview(_ style: ArrowStyle) -> NSImage {
        let size = NSSize(width: 40, height: 16)
        let image = NSImage(size: size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            var a = Annotation(tool: .arrow, p0: CGPoint(x: 5, y: 8), p1: CGPoint(x: 35, y: 8),
                               color: .white, weight: 0.05, scale: 1)
            a.arrowStyle = style
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setFillColor(NSColor.white.cgColor)
            drawLinear(a, in: ctx)
            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: 状態を画面へ反映

    private func syncUI() {
        let selected = canvas.selectedAnnotation
        for b in toolButtons { b.isOn = b.tag == canvas.tool.rawValue }
        backgroundButton.isOn = canvas.background.enabled
        deleteButton.isEnabled = selected != nil

        let contextTool = selected?.tool ?? canvas.tool
        let currentColor = selected?.color ?? canvas.color
        let customs = CustomColors.all
        for (n, dot) in customDots.enumerated() {
            dot.isHidden = n >= customs.count
            if n < customs.count { dot.color = customs[n] }
        }
        for dot in colorDots + customDots { dot.isOn = !dot.isHidden && sameColor(dot.color, currentColor) }
        weightSlider.doubleValue = Double(selected?.weight ?? canvas.weight)
        weightLabel.stringValue = contextTool == .blur ? "強さ" : contextTool == .spotlight ? "暗さ"
            : (contextTool == .text || contextTool == .counter) ? "大きさ" : "太さ"

        arrowPicker.isHidden = contextTool != .arrow
        blurPicker.isHidden = contextTool != .blur
        textPicker.isHidden = contextTool != .text
        styleGroup.isHidden = arrowPicker.isHidden && blurPicker.isHidden && textPicker.isHidden
        arrowPicker.selectedSegment = (selected?.arrowStyle ?? canvas.arrowStyle).rawValue
        blurPicker.selectedSegment = (selected?.blurStyle ?? canvas.blurStyle).rawValue
        textPicker.selectedSegment = TextStyle.ordered.firstIndex(of: selected?.textStyle ?? canvas.textStyle) ?? 0

        if let selected {
            switch selected.tool {
            case .arrow: hintLabel.stringValue = "端の丸で向きと長さ、真ん中の丸で曲がり。ドラッグで移動、delete で消す"
            case .line: hintLabel.stringValue = "端の丸で向きと長さ、真ん中の丸で曲がり。ドラッグで移動"
            case .rect, .fillRect, .ellipse, .blur, .spotlight: hintLabel.stringValue = "まわりの丸で大きさを変える。ドラッグで移動、delete で消す"
            case .crop: hintLabel.stringValue = "まわりの丸で残す範囲を調整。delete で切り抜きをやめる"
            case .text: hintLabel.stringValue = "ダブルクリックで打ち直し。ドラッグで移動"
            case .image: hintLabel.stringValue = "四隅の丸で大きさを変える。ドラッグで移動。外へ出すと余白が広がります"
            default: hintLabel.stringValue = "ドラッグで移動、矢印キーで少しずつ動かせます"
            }
        } else {
            hintLabel.stringValue = canvas.tool.hint
        }
    }

    // MARK: 操作

    @objc private func toolTapped(_ sender: ToolButton) {
        canvas.setTool(Tool(rawValue: sender.tag) ?? .arrow)
        window.makeFirstResponder(canvas)
    }

    @objc private func colorTapped(_ sender: ColorDot) {
        pickingCustomColor = false
        canvas.setColor(sender.color)
        syncUI()
    }

    /// 色のパネルを開く。パネルのスポイトで画面の色も拾える。
    @objc private func customColorTapped() {
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.isContinuous = true
        panel.color = canvas.selectedAnnotation?.color ?? canvas.color
        panel.setTarget(self)
        panel.setAction(#selector(colorPanelChanged(_:)))
        pickingCustomColor = false
        panel.orderFront(nil)
    }

    @objc private func colorPanelChanged(_ sender: NSColorPanel) {
        useCustomColor(sender.color)
    }

    /// 自分で作った色を使う。パネルで選び直している間は、いちばん新しい1つを上書きしていく。
    func useCustomColor(_ raw: NSColor) {
        guard let c = raw.usingColorSpace(.sRGB) else { return }
        let color = NSColor(srgbRed: c.redComponent, green: c.greenComponent, blue: c.blueComponent, alpha: 1)
        if let fixed = Self.palette.first(where: { sameColor($0, color) }) {
            canvas.setColor(fixed)   // 最初からある色と同じなら、控えは増やさない
        } else {
            var list = CustomColors.all
            if pickingCustomColor, !list.isEmpty { list.removeFirst() }
            list.removeAll { sameColor($0, color) }
            list.insert(color, at: 0)
            CustomColors.all = list
            pickingCustomColor = true
            canvas.setColor(color)
        }
        syncUI()
    }

    // MARK: 画像のメニュー

    @objc private func imageMenuTapped(_ sender: ToolButton) {
        let menu = NSMenu()
        func item(_ title: String, _ symbol: String, _ action: Selector) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
            i.target = self
            i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            menu.addItem(i)
            return i
        }
        _ = item("画像を追加…", "plus.rectangle.on.rectangle", #selector(addImageTapped))
        menu.addItem(.separator())
        _ = item(CanvasOp.rotateLeft.label, "rotate.left", #selector(rotateLeftTapped))
        _ = item(CanvasOp.rotateRight.label, "rotate.right", #selector(rotateRightTapped))
        _ = item(CanvasOp.flipHorizontal.label, "arrow.left.and.right.righttriangle.left.righttriangle.right", #selector(flipHorizontalTapped))
        _ = item(CanvasOp.flipVertical.label, "arrow.up.and.down.righttriangle.up.righttriangle.down", #selector(flipVerticalTapped))
        menu.addItem(.separator())
        _ = item("サイズ変更…", "arrow.up.left.and.arrow.down.right", #selector(resizeTapped))
        _ = item("ふちに枠線を付ける", "square", #selector(frameTapped)).toolTip = "いまの色と太さで、画像のふちに枠線を引きます。引いたあとで選んで消せます"
        menu.addItem(.separator())
        _ = item("メール・電話番号・長い数字を隠す", "eye.slash", #selector(hideSensitiveTapped)).toolTip = "写っている文字を読み取って、当てはまる所にぼかしを掛けます"
        _ = item("文字をすべて隠す", "eye.slash.fill", #selector(hideAllTextTapped))
        menu.addItem(.separator())
        let expand = item("余白を自動で広げる", "rectangle.expand.vertical", #selector(autoExpandTapped))
        expand.state = canvas.autoExpand ? .on : .off
        expand.toolTip = "画像の外へはみ出したものが全部入るように、まわりに透明の余白を足します"
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    // MARK: 絵文字

    private static let emojis = Array("😀😂🥹😍🤔😅😭😡👍👎👏🙏💪👀🔥✨🎉💡❗❓✅❌⭕⚠️🚫⭐❤️💯👉👈👆👇➡️⬅️⬆️⬇️🔒🔑📌📎✏️🗑️💬🔍⏰📅💰🚀").map(String.init)

    @objc private func emojiTapped() {
        if let emojiPopover, emojiPopover.isShown { emojiPopover.close(); return }
        let columns = 8, cell: CGFloat = 34
        let rows = Int(ceil(Double(Self.emojis.count) / Double(columns)))
        let view = NSView(frame: NSRect(x: 0, y: 0, width: CGFloat(columns) * cell + 16, height: CGFloat(rows) * cell + 40))
        for (n, emoji) in Self.emojis.enumerated() {
            let b = NSButton(title: emoji, target: self, action: #selector(emojiPicked(_:)))
            b.isBordered = false
            b.font = .systemFont(ofSize: 22)
            b.frame = NSRect(x: 8 + CGFloat(n % columns) * cell, y: view.bounds.height - 8 - CGFloat(n / columns + 1) * cell, width: cell, height: cell)
            view.addSubview(b)
        }
        let note = NSTextField(labelWithString: "ほかの絵文字は、文字の道具で ⌃⌘space")
        note.font = .systemFont(ofSize: 10.5)
        note.textColor = .secondaryLabelColor
        note.frame = NSRect(x: 12, y: 8, width: view.bounds.width - 24, height: 16)
        view.addSubview(note)
        let controller = NSViewController()
        controller.view = view
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.show(relativeTo: emojiButton.bounds, of: emojiButton, preferredEdge: .maxY)
        emojiPopover = popover
    }

    @objc private func emojiPicked(_ sender: NSButton) {
        addEmoji(sender.title)
        emojiPopover?.close()
    }

    /// 絵文字を、見えている範囲の真ん中に置く。中身は文字なので、あとから動かす・大きさを変える・打ち直すができる。
    func addEmoji(_ emoji: String) {
        var a = canvas.template(.text, p0: .zero, p1: .zero)
        a.text = emoji
        a.textStyle = .plain
        a.weight = max(a.weight, 0.5)
        let size = a.textSize
        let c = canvas.visibleCenter
        a.p0 = CGPoint(x: c.x - size.width / 2, y: c.y - size.height / 2)
        a.p1 = a.p0
        canvas.add(a)
        canvas.setTool(.select)
        window.makeFirstResponder(canvas)
    }

    // MARK: 枠線・文字を隠す

    @objc private func frameTapped() { addFrame() }

    /// 画像のふちに、いまの色と太さで枠線を引く。
    func addFrame() {
        var a = canvas.template(.rect, p0: .zero, p1: .zero)
        let inset = a.lineWidth / 2
        let r = canvas.renderer.fullRect.insetBy(dx: inset, dy: inset)
        a.p0 = CGPoint(x: r.minX, y: r.minY)
        a.p1 = CGPoint(x: r.maxX, y: r.maxY)
        canvas.add(a)
    }

    @objc private func hideSensitiveTapped() { hideText(onlySensitive: true, completion: nil) }
    @objc private func hideAllTextTapped() { hideText(onlySensitive: false, completion: nil) }

    /// 写っている文字を読み取って、ぼかしを掛ける。onlySensitive なら、メール・電話番号・長い数字や記号の並びだけ。
    func hideText(onlySensitive: Bool, completion: ((Int) -> Void)?) {
        // 描いたものは外して、元の画像と足した画像だけを読む
        guard let image = canvas.renderer.renderImage(canvas.annotations.filter { $0.tool == .image }) else { completion?(0); return }
        let size = CGSize(width: image.width, height: image.height)
        SensitiveText.find(in: image, onlySensitive: onlySensitive) { [weak self] boxes in
            guard let self else { return }
            var template = self.canvas.template(.blur, p0: .zero, p1: .zero)
            if template.blurStyle == .solid { template.blurStyle = .secure }
            template.weight = max(template.weight, 0.45)
            let pad = 3 * template.scale
            let list: [Annotation] = boxes.map { box in
                // 読み取りの枠は 0〜1・左下が原点
                let r = CGRect(x: box.minX * size.width, y: box.minY * size.height, width: box.width * size.width, height: box.height * size.height)
                    .insetBy(dx: -pad, dy: -pad).intersection(self.canvas.renderer.fullRect)
                var a = template
                a.p0 = CGPoint(x: r.minX, y: r.minY)
                a.p1 = CGPoint(x: r.maxX, y: r.maxY)
                return a
            }
            self.canvas.addMany(list)
            if !Self.headless {
                if list.isEmpty { ToastHUD.show(onlySensitive ? "隠す所が見つかりませんでした" : "文字が見つかりませんでした", detail: nil) }
                else { ToastHUD.show("\(list.count)か所を隠しました", detail: "⌘Z で戻せます。隠れていない所が無いか見てください") }
            }
            completion?(list.count)
        }
    }

    // MARK: 道具の設定の保存

    @objc private func presetMenuTapped(_ sender: ToolButton) {
        let menu = NSMenu()
        let presets = ToolPresets.all
        for (n, preset) in presets.enumerated() {
            let i = NSMenuItem(title: preset.name, action: #selector(presetPicked(_:)), keyEquivalent: n < 9 ? "\(n + 1)" : "")
            i.keyEquivalentModifierMask = [.control]
            i.target = self
            i.tag = n
            i.image = preset.swatch()
            menu.addItem(i)
        }
        if !presets.isEmpty { menu.addItem(.separator()) }
        let save = NSMenuItem(title: "いまの道具の設定を保存…", action: #selector(presetSaveTapped), keyEquivalent: "")
        save.target = self
        menu.addItem(save)
        if !presets.isEmpty {
            let remove = NSMenuItem(title: "保存した設定を消す", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for (n, preset) in presets.enumerated() {
                let i = NSMenuItem(title: preset.name, action: #selector(presetDeleteTapped(_:)), keyEquivalent: "")
                i.target = self
                i.tag = n
                sub.addItem(i)
            }
            remove.submenu = sub
            menu.addItem(remove)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func presetPicked(_ sender: NSMenuItem) { applyPreset(at: sender.tag) }

    @discardableResult
    func applyPreset(at index: Int) -> Bool {
        let presets = ToolPresets.all
        guard presets.indices.contains(index) else { return false }
        let p = presets[index]
        canvas.applyPreset(tool: p.tool, color: p.color, weight: p.weight, arrow: p.arrowStyle, blur: p.blurStyle, text: p.textStyle)
        window.makeFirstResponder(canvas)
        return true
    }

    /// いまの道具・色・太さ・種類を、名前を付けて残す。同じ名前があれば置き換える。
    func savePreset(named name: String) {
        ToolPresets.save(ToolPreset(name: name, tool: canvas.tool == .select ? .arrow : canvas.tool, color: canvas.color, weight: canvas.weight,
                                    arrowStyle: canvas.arrowStyle, blurStyle: canvas.blurStyle, textStyle: canvas.textStyle))
    }

    @objc private func presetSaveTapped() {
        let alert = NSAlert()
        alert.messageText = "いまの道具の設定を保存"
        alert.informativeText = "道具・色・太さ・種類をまとめて残します。星のボタンから呼び出せます。"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = "\(canvas.tool == .select ? Tool.arrow.label : canvas.tool.label) \(ToolPresets.all.count + 1)"
        alert.accessoryView = field
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "やめる")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard response == .alertFirstButtonReturn, !name.isEmpty else { return }
            self?.savePreset(named: name)
        }
    }

    @objc private func presetDeleteTapped(_ sender: NSMenuItem) { ToolPresets.remove(at: sender.tag) }

    @objc private func addImageTapped() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.message = "足したい画像を選んでください"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK else { return }
            for url in panel.urls {
                if let loaded = loadImage(at: url) { self.canvas.addImage(loaded.image, dpi: loaded.dpi, center: nil) }
            }
            self.window.makeFirstResponder(self.canvas)
        }
    }

    @objc private func rotateLeftTapped() { canvas.transform(.rotateLeft) }
    @objc private func rotateRightTapped() { canvas.transform(.rotateRight) }
    @objc private func flipHorizontalTapped() { canvas.transform(.flipHorizontal) }
    @objc private func flipVerticalTapped() { canvas.transform(.flipVertical) }
    @objc private func autoExpandTapped() { canvas.autoExpand.toggle() }

    @objc private func backgroundTapped() { showBackgroundPanel() }

    /// 背景の小窓を「背景」ボタンの下に出す。初めて開いたときは背景を入れた状態にする。
    @discardableResult
    func showBackgroundPanel() -> BackgroundPanelController {
        if let popover = backgroundPopover, popover.isShown {
            popover.close()
            if let panel = backgroundPanel { return panel }
        }
        if !canvas.background.enabled {
            var style = canvas.background
            style.enabled = true
            canvas.background = style
        }
        let panel = BackgroundPanelController(get: { [weak self] in self?.canvas.background ?? BackdropStyle() },
                                              set: { [weak self] in self?.canvas.background = $0 })
        panel.onRedraw = { [weak self] in self?.canvas.needsDisplay = true }
        let popover = NSPopover()
        popover.contentViewController = panel
        popover.behavior = .semitransient
        if !Self.headless { popover.show(relativeTo: backgroundButton.bounds, of: backgroundButton, preferredEdge: .maxY) }
        else { _ = panel.view }
        backgroundPopover = popover
        backgroundPanel = panel
        return panel
    }

    @objc private func resizeTapped() {
        _ = showResizePanel()
    }

    /// サイズ変更の小窓を「画像」ボタンの下に出す。
    @discardableResult
    func showResizePanel() -> ResizePanelController {
        resizePopover?.close()
        let size = CGSize(width: canvas.renderer.width, height: canvas.renderer.height)
        let popover = NSPopover()
        let panel = ResizePanelController(size: size) { [weak self, weak popover] target in
            self?.canvas.resize(to: target)
            popover?.close()
            if let self { self.window.makeFirstResponder(self.canvas) }
        }
        popover.contentViewController = panel
        popover.behavior = .transient
        if !Self.headless { popover.show(relativeTo: imageButton.bounds, of: imageButton, preferredEdge: .maxY) }
        else { _ = panel.view }
        resizePopover = popover
        return panel
    }

    @objc private func weightChanged(_ sender: NSSlider) {
        canvas.setWeight(CGFloat(sender.doubleValue))
    }

    @objc private func arrowStyleChanged(_ sender: NSSegmentedControl) {
        canvas.setArrowStyle(ArrowStyle(rawValue: sender.selectedSegment) ?? .filled)
        window.makeFirstResponder(canvas)
    }

    @objc private func blurStyleChanged(_ sender: NSSegmentedControl) {
        canvas.setBlurStyle(BlurStyle(rawValue: sender.selectedSegment) ?? .mosaic)
        window.makeFirstResponder(canvas)
    }

    @objc private func textStyleChanged(_ sender: NSSegmentedControl) {
        let n = sender.selectedSegment
        canvas.setTextStyle(TextStyle.ordered.indices.contains(n) ? TextStyle.ordered[n] : .outline)
    }

    @objc private func undoTapped() { canvas.undo(nil) }
    @objc private func redoTapped() { canvas.redo(nil) }
    @objc private func deleteTapped() { canvas.deleteSelected() }

    @objc private func copyTapped() {
        canvas.copy(nil)
        copyButton.caption = "コピー済み"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.copyButton.caption = "コピー" }
    }

    /// 編集結果を元のファイルへ書き戻す。
    func writeBack() -> Bool {
        canvas.commitText()
        guard !canvas.annotations.isEmpty || hadProject || canvas.baseTransformed || canvas.backgroundChanged else { return true }
        guard let image = canvas.renderer.renderFinal(canvas.annotations), let data = pngData(image, dpi: dpi) else {
            NSSound.beep()
            return false
        }
        do {
            if canvas.baseTransformed {
                // 回転・反転・サイズ変更をしたときは、変えたあとの画像を「編集前の画像」として控え直す
                if let baseData = pngData(canvas.renderer.base, dpi: dpi) {
                    try baseData.write(to: EditProject.baseURL(for: fileURL), options: .atomic)
                }
            } else {
                EditProject.keepBase(of: fileURL)   // 上書きの前に、編集前の画像を控える（最初の1回だけ）
            }
            try data.write(to: fileURL, options: .atomic)
            if canvas.annotations.isEmpty && !canvas.background.enabled {
                EditProject.discard(for: fileURL)   // 描いたものも背景も無ければ控えも要らない
            } else {
                EditProject.save(for: fileURL, annotations: canvas.annotations, renderer: canvas.renderer, dpi: dpi)
            }
            log("編集を反映 注釈=\(canvas.annotations.count) \(fileURL.lastPathComponent)")
            return true
        } catch {
            log("編集の書き戻し失敗 \(error)")
            NSSound.beep()
            return false
        }
    }

    @objc func doneTapped() {
        guard writeBack() else { return }
        finish(saved: false)
    }

    @objc func saveTapped() {
        guard writeBack(), saveToFolder(fileURL) != nil else { return }
        finish(saved: true)
    }

    private func finish(saved: Bool) {
        closingOnPurpose = true
        window.close()
        onFinish(saved)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if closingOnPurpose || (canvas.annotations.isEmpty && !hadProject && !canvas.baseTransformed && !canvas.backgroundChanged) || !canvas.hasChanges { return true }
        let alert = NSAlert()
        alert.messageText = "編集を捨てて閉じますか"
        alert.informativeText = "「完了」か「保存」を押すまで、編集は画像に反映されません。"
        alert.addButton(withTitle: "編集に戻る")
        alert.addButton(withTitle: "捨てて閉じる")
        return alert.runModal() == .alertSecondButtonReturn
    }

    func windowWillClose(_ notification: Notification) {
        resizePopover?.close()
        backgroundPopover?.close()
        if NSColorPanel.sharedColorPanelExists, NSColorPanel.shared.isVisible { NSColorPanel.shared.close() }
        Self.openEditors.removeAll { $0 === self }
    }

    /// 動作確認用: ウィンドウの中身を画像にする（画面を撮らずに見た目を確かめる）。
    func snapshot(to url: URL) {
        guard let view = window.contentView else { return }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
