// 編集画面の追加機能: 画像の回転・反転・サイズ変更、ほかの画像の追加、自由な色、文字スタイルの見本。

import AppKit
import Vision
import ImageIO

// MARK: - 回転と反転

enum CanvasOp {
    case rotateLeft, rotateRight, flipHorizontal, flipVertical

    var swapsAxes: Bool { self == .rotateLeft || self == .rotateRight }

    var label: String {
        switch self {
        case .rotateLeft: return "左に90度回転"
        case .rotateRight: return "右に90度回転"
        case .flipHorizontal: return "左右反転"
        case .flipVertical: return "上下反転"
        }
    }

    /// 大きさ size の画像の中の点（左下が原点）が、変えたあとにどこへ行くか。
    func map(_ p: CGPoint, in size: CGSize) -> CGPoint {
        switch self {
        case .rotateLeft: return CGPoint(x: size.height - p.y, y: p.x)
        case .rotateRight: return CGPoint(x: p.y, y: size.width - p.x)
        case .flipHorizontal: return CGPoint(x: size.width - p.x, y: p.y)
        case .flipVertical: return CGPoint(x: p.x, y: size.height - p.y)
        }
    }

    /// 画像そのものを回す・裏返す。
    func apply(to image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        let (nw, nh) = swapsAxes ? (h, w) : (w, h)
        guard let ctx = makeBitmapContext(width: nw, height: nh, like: image) else { return nil }
        ctx.interpolationQuality = .none
        switch self {
        case .rotateLeft:
            ctx.translateBy(x: CGFloat(h), y: 0)
            ctx.rotate(by: .pi / 2)
        case .rotateRight:
            ctx.translateBy(x: 0, y: CGFloat(w))
            ctx.rotate(by: -.pi / 2)
        case .flipHorizontal:
            ctx.translateBy(x: CGFloat(w), y: 0)
            ctx.scaleBy(x: -1, y: 1)
        case .flipVertical:
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: 1, y: -1)
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}

/// 元の画像と同じ色空間の、透明を持てる描き先を作る。
func makeBitmapContext(width: Int, height: Int, like image: CGImage?) -> CGContext? {
    guard width > 0, height > 0 else { return nil }
    let space: CGColorSpace
    if let s = image?.colorSpace, s.model == .rgb { space = s } else { space = CGColorSpace(name: CGColorSpace.sRGB)! }
    return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                     space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
}

/// 画像を指定の大きさに作り直す。
func resampled(_ image: CGImage, width: Int, height: Int) -> CGImage? {
    guard let ctx = makeBitmapContext(width: width, height: height, like: image) else { return nil }
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return ctx.makeImage()
}

extension Annotation {
    /// 回転・反転に合わせて場所を移す。
    /// 文字と番号は、回転では一緒に回す。反転では鏡文字にせず、読める向きのまま場所だけ移す。
    func transformed(by op: CanvasOp, in size: CGSize) -> Annotation {
        var a = self
        let map: (CGPoint) -> CGPoint = { op.map($0, in: size) }
        let turn = op == .rotateLeft ? 1 : op == .rotateRight ? 3 : 0
        switch tool {
        case .text:
            let c = CGPoint(x: bounds.midX, y: bounds.midY)
            a.p0 = p0 + (map(c) - c)
            a.p1 = a.p0
            a.turns = (turns + turn) % 4
        case .counter:
            a.p0 = map(p0)
            a.p1 = a.p0
            a.turns = (turns + turn) % 4
        default:
            a.p0 = map(p0)
            a.p1 = map(p1)
            a.ctrl = ctrl.map(map)
            a.points = points.map(map)
            if tool == .image, let img = image { a.image = op.apply(to: img) ?? img }
            a.normalizeBox()
        }
        return a
    }

    /// サイズ変更に合わせて場所と太さを変える。
    func scaled(x sx: CGFloat, y sy: CGFloat) -> Annotation {
        var a = self
        let map: (CGPoint) -> CGPoint = { CGPoint(x: $0.x * sx, y: $0.y * sy) }
        a.p0 = map(p0)
        a.p1 = map(p1)
        a.ctrl = ctrl.map(map)
        a.points = points.map(map)
        a.scale = scale * (sx * sy).squareRoot()
        return a
    }

    /// 線の太さや影を除いた、形そのものの範囲（余白を広げるかどうかの判断に使う）。
    var coreBounds: CGRect {
        func box(_ pts: [CGPoint]) -> CGRect {
            guard let first = pts.first else { return CGRect(origin: p0, size: .zero) }
            var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
            for p in pts {
                minX = min(minX, p.x); maxX = max(maxX, p.x)
                minY = min(minY, p.y); maxY = max(maxY, p.y)
            }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
        switch tool {
        case .arrow, .line: return box(samples(16))
        case .pencil, .highlighter: return box(points)
        case .text, .counter: return bounds
        default: return rect
        }
    }
}

// MARK: - 画像の読み込み

/// ファイルから画像と解像度を読む。
func loadImage(at url: URL) -> (image: CGImage, dpi: CGFloat)? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
    let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    return (image, (props?[kCGImagePropertyDPIWidth] as? CGFloat) ?? 72)
}

/// クリップボードやドラッグの中身から画像を取り出す。
func imagesFrom(pasteboard pb: NSPasteboard) -> [(image: CGImage, dpi: CGFloat)] {
    var result: [(CGImage, CGFloat)] = []
    let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true, .urlReadingContentsConformToTypes: ["public.image"]]
    if let urls = pb.readObjects(forClasses: [NSURL.self], options: options) as? [URL] {
        for url in urls { if let loaded = loadImage(at: url) { result.append(loaded) } }
    }
    if !result.isEmpty { return result }
    for type in [NSPasteboard.PasteboardType.png, .tiff] {
        guard let data = pb.data(forType: type), let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        return [(image, (props?[kCGImagePropertyDPIWidth] as? CGFloat) ?? 72)]
    }
    return []
}

// MARK: - 色

/// 見た目が同じ色か（色空間の違いは無視する）。
func sameColor(_ a: NSColor, _ b: NSColor) -> Bool {
    guard let x = a.usingColorSpace(.sRGB), let y = b.usingColorSpace(.sRGB) else { return a == b }
    return abs(x.redComponent - y.redComponent) < 0.004 && abs(x.greenComponent - y.greenComponent) < 0.004
        && abs(x.blueComponent - y.blueComponent) < 0.004
}

/// 自分で作った色の控え（新しい順・3つまで）。
enum CustomColors {
    static let limit = 3
    private static let key = "editorCustomColors"

    static var all: [NSColor] {
        get {
            (UserDefaults.standard.stringArray(forKey: key) ?? []).compactMap { text in
                let v = text.split(separator: ",").compactMap { Double($0) }
                return v.count == 3 ? NSColor(srgbRed: v[0], green: v[1], blue: v[2], alpha: 1) : nil
            }
        }
        set {
            let list = newValue.prefix(limit).compactMap { color -> String? in
                guard let c = color.usingColorSpace(.sRGB) else { return nil }
                return String(format: "%.4f,%.4f,%.4f", c.redComponent, c.greenComponent, c.blueComponent)
            }
            UserDefaults.standard.set(Array(list), forKey: key)
        }
    }
}

/// 「色を作る」ボタン。虹色の輪に＋。
final class ColorPlusDot: NSButton {
    init(target: AnyObject, action: Selector) {
        super.init(frame: NSRect(x: 0, y: 0, width: 26, height: 26))
        self.target = target
        self.action = action
        title = ""
        isBordered = false
        toolTip = "好きな色を作る（スポイトで画面から拾うこともできます）"
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 26).isActive = true
        heightAnchor.constraint(equalToConstant: 26).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let circle = bounds.insetBy(dx: 4.5, dy: 4.5)
        let center = NSPoint(x: circle.midX, y: circle.midY)
        let steps = 24
        for i in 0..<steps {
            let wedge = NSBezierPath()
            wedge.move(to: center)
            wedge.appendArc(withCenter: center, radius: circle.width / 2,
                            startAngle: CGFloat(i) * 360 / CGFloat(steps), endAngle: CGFloat(i + 1) * 360 / CGFloat(steps) + 1)
            wedge.close()
            NSColor(hue: CGFloat(i) / CGFloat(steps), saturation: 0.85, brightness: 1, alpha: 1).setFill()
            wedge.fill()
        }
        let hole = NSBezierPath(ovalIn: circle.insetBy(dx: 3.5, dy: 3.5))
        NSColor(white: 0.135, alpha: 1).setFill()
        hole.fill()
        let plus = NSBezierPath()
        plus.move(to: NSPoint(x: center.x - 3, y: center.y)); plus.line(to: NSPoint(x: center.x + 3, y: center.y))
        plus.move(to: NSPoint(x: center.x, y: center.y - 3)); plus.line(to: NSPoint(x: center.x, y: center.y + 3))
        plus.lineWidth = 1.5
        NSColor.white.setStroke()
        plus.stroke()
    }
}

// MARK: - 文字スタイルの見本

extension TextStyle {
    /// 種類を選ぶボタンに出す小さな見本。
    func preview() -> NSImage {
        let size = NSSize(width: 30, height: 18)
        let style = self
        return NSImage(size: size, flipped: false) { rect in
            let font = style.font(ofSize: 12)
            let fg = NSColor.white
            let label = NSAttributedString(string: "Aa", attributes: [.font: font, .foregroundColor: style.isBoxed ? NSColor(white: 0.1, alpha: 1) : fg])
            let s = label.size()
            let origin = NSPoint(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2)
            if style.isBoxed {
                fg.setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 1), xRadius: 4, yRadius: 4).fill()
            }
            if style == .outline {
                NSAttributedString(string: "Aa", attributes: [.font: font, .foregroundColor: NSColor.clear,
                                                               .strokeColor: fg, .strokeWidth: 5.0]).draw(at: origin)
            } else {
                label.draw(at: origin)
            }
            return true
        }
    }
}

// MARK: - 透明の所に敷く市松模様

let checkerColor: NSColor = {
    let tile = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in
        NSColor(white: 0.23, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 16, height: 16).fill()
        NSColor(white: 0.29, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 8, height: 8).fill()
        NSRect(x: 8, y: 8, width: 8, height: 8).fill()
        return true
    }
    return NSColor(patternImage: tile)
}()

// MARK: - サイズ変更の小窓

final class ResizePanelController: NSViewController, NSTextFieldDelegate {
    private let original: CGSize
    private let onApply: (CGSize) -> Void
    private let widthField = NSTextField()
    private let heightField = NSTextField()
    private let unitPicker = NSSegmentedControl(labels: ["ピクセル", "パーセント"], trackingMode: .selectOne, target: nil, action: nil)
    private let lockButton = NSButton(checkboxWithTitle: "縦横の比率を保つ", target: nil, action: nil)
    private let resultLabel = NSTextField(labelWithString: "")
    private var usesPercent = false

    init(size: CGSize, onApply: @escaping (CGSize) -> Void) {
        self.original = size
        self.onApply = onApply
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        for field in [widthField, heightField] {
            field.alignment = .right
            field.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
            field.delegate = self
            field.target = self
            field.action = #selector(applyTapped)
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 76).isActive = true
        }
        unitPicker.selectedSegment = 0
        unitPicker.target = self
        unitPicker.action = #selector(unitChanged)
        lockButton.state = .on
        lockButton.target = self
        lockButton.action = #selector(lockChanged)
        resultLabel.font = .systemFont(ofSize: 11)
        resultLabel.textColor = .secondaryLabelColor

        let fields = NSStackView(views: [NSTextField(labelWithString: "幅"), widthField, NSTextField(labelWithString: "高さ"), heightField])
        fields.orientation = .horizontal
        fields.spacing = 6
        let apply = NSButton(title: "サイズを変更", target: self, action: #selector(applyTapped))
        apply.keyEquivalent = "\r"
        apply.bezelStyle = .rounded
        let bottom = NSStackView(views: [resultLabel, NSView(), apply])
        bottom.orientation = .horizontal

        let stack = NSStackView(views: [unitPicker, fields, lockButton, bottom])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        bottom.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        view = stack
        fill(with: original)
    }

    private func text(_ v: CGFloat) -> String { String(Int(v.rounded())) }

    private func fill(with size: CGSize) {
        if usesPercent {
            widthField.stringValue = text(size.width / original.width * 100)
            heightField.stringValue = text(size.height / original.height * 100)
        } else {
            widthField.stringValue = text(size.width)
            heightField.stringValue = text(size.height)
        }
        updateResult()
    }

    /// 入力されている値を、ピクセルの大きさにして返す。
    var target: CGSize {
        let w = CGFloat(Double(widthField.stringValue) ?? 0), h = CGFloat(Double(heightField.stringValue) ?? 0)
        let size = usesPercent ? CGSize(width: original.width * w / 100, height: original.height * h / 100) : CGSize(width: w, height: h)
        return CGSize(width: size.width.rounded(), height: size.height.rounded())
    }

    private func updateResult() {
        let t = target
        resultLabel.stringValue = "\(Int(original.width)) × \(Int(original.height)) → \(Int(t.width)) × \(Int(t.height))"
    }

    @objc private func unitChanged() {
        let current = target
        usesPercent = unitPicker.selectedSegment == 1
        fill(with: current.width >= 1 && current.height >= 1 ? current : original)
    }

    @objc private func lockChanged() {
        if lockButton.state == .on { edited(widthField) }
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        edited(field)
    }

    /// 片方を打ったら、比率を保つときはもう片方を合わせる。
    func edited(_ field: NSTextField) {
        if lockButton.state == .on, let v = Double(field.stringValue), v > 0 {
            if usesPercent {
                (field === widthField ? heightField : widthField).stringValue = text(CGFloat(v))
            } else if field === widthField {
                heightField.stringValue = text(CGFloat(v) * original.height / original.width)
            } else {
                widthField.stringValue = text(CGFloat(v) * original.width / original.height)
            }
        }
        updateResult()
    }

    /// 動作確認用: 幅を打ち込んだことにする。
    func testType(width: String) {
        widthField.stringValue = width
        edited(widthField)
    }

    @objc func applyTapped() {
        let t = target
        guard t.width >= 8, t.height >= 8, t.width <= 20000, t.height <= 20000 else {
            NSSound.beep()
            return
        }
        onApply(t)
    }
}

// MARK: - 道具の設定を覚える

/// 最後に使った色・太さ・種類。次に編集画面を開いたときの出発点にする。
enum ToolMemory {
    private static let d = UserDefaults.standard

    static var color: NSColor {
        get {
            guard let v = d.array(forKey: "editorColor") as? [Double], v.count == 3 else { return EditorController.palette[0] }
            return NSColor(srgbRed: v[0], green: v[1], blue: v[2], alpha: 1)
        }
        set {
            guard let c = newValue.usingColorSpace(.sRGB) else { return }
            d.set([Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent)], forKey: "editorColor")
        }
    }
    static var weight: CGFloat {
        get { d.object(forKey: "editorWeight") == nil ? 0.25 : CGFloat(max(0, min(1, d.double(forKey: "editorWeight")))) }
        set { d.set(Double(newValue), forKey: "editorWeight") }
    }
    static var arrowStyle: ArrowStyle {
        get { ArrowStyle(rawValue: d.integer(forKey: "editorArrowStyle")) ?? .filled }
        set { d.set(newValue.rawValue, forKey: "editorArrowStyle") }
    }
    static var blurStyle: BlurStyle {
        get { BlurStyle(rawValue: d.integer(forKey: "editorBlurStyle")) ?? .mosaic }
        set { d.set(newValue.rawValue, forKey: "editorBlurStyle") }
    }
    static var textStyle: TextStyle {
        get { TextStyle(rawValue: d.integer(forKey: "editorTextStyle")) ?? .outline }
        set { d.set(newValue.rawValue, forKey: "editorTextStyle") }
    }
}

// MARK: - 道具の設定の保存

/// 道具・色・太さ・種類をひとまとめにして、名前を付けて残したもの。
struct ToolPreset {
    var name: String
    var tool: Tool
    var color: NSColor
    var weight: CGFloat
    var arrowStyle: ArrowStyle
    var blurStyle: BlurStyle
    var textStyle: TextStyle

    /// メニューに出す小さな見本（道具の絵をその色で）
    func swatch() -> NSImage? { tintedSymbol(tool.symbol, pointSize: 13, color: color) }
}

enum ToolPresets {
    private static let d = UserDefaults.standard
    private static let key = "editorPresets"
    static let limit = 20

    static var all: [ToolPreset] {
        (d.array(forKey: key) as? [[String: Any]] ?? []).compactMap { v in
            guard let name = v["name"] as? String, let toolName = v["tool"] as? String,
                  let tool = Tool.allCases.first(where: { String(describing: $0) == toolName }),
                  let rgb = v["color"] as? [Double], rgb.count == 3, let weight = v["weight"] as? Double else { return nil }
            return ToolPreset(name: name, tool: tool, color: NSColor(srgbRed: rgb[0], green: rgb[1], blue: rgb[2], alpha: 1), weight: CGFloat(weight),
                              arrowStyle: ArrowStyle(rawValue: v["arrow"] as? Int ?? 0) ?? .filled,
                              blurStyle: BlurStyle(rawValue: v["blur"] as? Int ?? 0) ?? .mosaic,
                              textStyle: TextStyle(rawValue: v["text"] as? Int ?? 0) ?? .outline)
        }
    }

    private static func write(_ list: [ToolPreset]) {
        d.set(list.map { p -> [String: Any] in
            let c = p.color.usingColorSpace(.sRGB) ?? .red
            return ["name": p.name, "tool": String(describing: p.tool),
                    "color": [Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent)], "weight": Double(p.weight),
                    "arrow": p.arrowStyle.rawValue, "blur": p.blurStyle.rawValue, "text": p.textStyle.rawValue]
        }, forKey: key)
    }

    /// 同じ名前があれば置き換える
    static func save(_ preset: ToolPreset) {
        var list = all.filter { $0.name != preset.name }
        list.append(preset)
        if list.count > limit { list.removeFirst(list.count - limit) }
        write(list)
    }

    static func remove(at index: Int) {
        var list = all
        guard list.indices.contains(index) else { return }
        list.remove(at: index)
        write(list)
    }
}

// MARK: - 隠したい文字を探す

enum SensitiveText {
    /// メールアドレス・電話番号や口座のような数字の並び・鍵のような長い英数字
    static let patterns: [NSRegularExpression] = [
        "[A-Za-z0-9._%+\\-]+@[A-Za-z0-9.\\-]+\\.[A-Za-z]{2,}",
        "[0-9０-９][0-9０-９\\- ‐－ー()]{6,}[0-9０-９]",
        "[A-Za-z0-9_\\-]*[0-9][A-Za-z0-9_\\-]{19,}",
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    /// 文字列の中の、隠したい部分
    static func ranges(in text: String) -> [Range<String.Index>] {
        let whole = NSRange(text.startIndex..., in: text)
        return patterns.flatMap { $0.matches(in: text, range: whole) }.compactMap { Range($0.range, in: text) }
    }

    /// 画像の中の文字の場所を返す（0〜1・左下が原点）。onlySensitive が false なら文字を全部。終わったら main で返す。
    static func find(in image: CGImage, onlySensitive: Bool, completion: @escaping ([CGRect]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["ja-JP", "en-US"]
            request.usesLanguageCorrection = false   // 番号や記号を勝手に直させない
            do {
                try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            } catch {
                log("文字を隠す: 読み取りに失敗 \(error)")
            }
            var boxes: [CGRect] = []
            for observation in request.results ?? [] {
                guard let top = observation.topCandidates(1).first else { continue }
                if !onlySensitive { boxes.append(observation.boundingBox); continue }
                for range in ranges(in: top.string) {
                    if let box = try? top.boundingBox(for: range) { boxes.append(box.boundingBox) }
                }
            }
            DispatchQueue.main.async {
                log("文字を隠す: \(onlySensitive ? "当てはまる所" : "全部") \(boxes.count)か所")
                completion(boxes)
            }
        }
    }
}
