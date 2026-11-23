// 背景ツール: スクショのまわりに背景（グラデーション・単色・ぼかし・壁紙・画像）を敷いて、
// 余白・角の丸み・影・位置・縦横比を付ける。編集画面の「背景」ボタンから使う。

import AppKit
import CoreImage

// MARK: - 設定の中身

struct BackdropStyle: Equatable {
    enum Kind: String { case gradient, color, blur, wallpaper, image }

    var enabled = false
    var kind: Kind = .gradient
    /// グラデーションの番号
    var gradient = 0
    /// 単色のときの色（sRGB の 0〜1）
    var rgb: [Double] = [0.95, 0.95, 0.97]
    /// 画像を敷くときのファイル
    var imagePath = ""
    /// どれも 0〜1
    var padding: Double = 0.3
    var inset: Double = 0
    var corners: Double = 0.25
    var shadow: Double = 0.5
    /// 置く場所。0〜8（左上から右へ、上の段から下の段へ）。4 が真ん中
    var alignment = 4
    /// 仕上がりの縦横比（幅÷高さ）。0 は自動
    var ratio: Double = 0

    static let ratios: [(String, Double)] = [("自動", 0), ("16:9", 16.0 / 9), ("4:3", 4.0 / 3), ("3:2", 1.5), ("1:1", 1),
                                              ("4:5", 0.8), ("9:16", 9.0 / 16)]

    /// 2色と向き（度）。自前で決めた配色
    static let gradients: [(UInt32, UInt32, Double)] = [
        (0xFF7A59, 0xFFC371, 45), (0xF857A6, 0xFF5858, 30), (0x8E2DE2, 0x4A00E0, 60), (0x4FACFE, 0x00F2FE, 20),
        (0x43E97B, 0x38F9D7, 40), (0xFAD961, 0xF76B1C, 70), (0x30CFD0, 0x330867, 50), (0xA18CD1, 0xFBC2EB, 35),
        (0x2C3E50, 0x4CA1AF, 25), (0xE0EAFC, 0xCFDEF3, 90), (0x232526, 0x414345, 45), (0xFDFBFB, 0xEBEDEE, 90),
    ]

    var color: NSColor {
        get { NSColor(srgbRed: rgb.count > 0 ? rgb[0] : 1, green: rgb.count > 1 ? rgb[1] : 1, blue: rgb.count > 2 ? rgb[2] : 1, alpha: 1) }
        set {
            guard let c = newValue.usingColorSpace(.sRGB) else { return }
            rgb = [Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent)]
        }
    }

    func toDictionary() -> [String: Any] {
        ["enabled": enabled, "kind": kind.rawValue, "gradient": gradient, "rgb": rgb, "imagePath": imagePath,
         "padding": padding, "inset": inset, "corners": corners, "shadow": shadow, "alignment": alignment, "ratio": ratio]
    }

    init() {}
    init(dictionary d: [String: Any]) {
        enabled = d["enabled"] as? Bool ?? false
        kind = Kind(rawValue: d["kind"] as? String ?? "") ?? .gradient
        gradient = min(max(0, d["gradient"] as? Int ?? 0), Self.gradients.count - 1)
        if let v = d["rgb"] as? [Double], v.count == 3 { rgb = v }
        imagePath = d["imagePath"] as? String ?? ""
        padding = d["padding"] as? Double ?? 0.3
        inset = d["inset"] as? Double ?? 0
        corners = d["corners"] as? Double ?? 0.25
        shadow = d["shadow"] as? Double ?? 0.5
        alignment = min(max(0, d["alignment"] as? Int ?? 4), 8)
        ratio = d["ratio"] as? Double ?? 0
    }

    /// 仕上がりの大きさと、その中のどこにスクショを置くか（左下が原点・ピクセル）。scale は1ポイントあたりのピクセル数。
    func layout(content: CGSize, scale k: CGFloat) -> BackgroundLayout {
        let pad = (CGFloat(padding) * 200 * k).rounded()
        let ins = (CGFloat(inset) * 80 * k).rounded()
        let fw = content.width + ins * 2, fh = content.height + ins * 2
        var ow = fw + pad * 2, oh = fh + pad * 2
        if ratio > 0 {
            if ow / oh < CGFloat(ratio) { ow = (oh * CGFloat(ratio)).rounded() } else { oh = (ow / CGFloat(ratio)).rounded() }
        }
        // 端に寄せたときは、その端にぴったり付ける
        let column = alignment % 3, rowFromTop = alignment / 3
        let x = column == 0 ? 0 : column == 2 ? ow - fw : ((ow - fw) / 2).rounded()
        let y = rowFromTop == 0 ? oh - fh : rowFromTop == 2 ? 0 : ((oh - fh) / 2).rounded()
        let framed = CGRect(x: x, y: y, width: fw, height: fh)
        let radius = min(CGFloat(corners) * 48 * k, fw / 2, fh / 2)
        return BackgroundLayout(outer: CGSize(width: ow, height: oh), framed: framed,
                                content: framed.insetBy(dx: ins, dy: ins), radius: radius, shadowBlur: CGFloat(shadow) * 60 * k)
    }
}

struct BackgroundLayout {
    var outer: CGSize
    /// スクショ＋内側の余白の範囲（角を丸めて影を落とす）
    var framed: CGRect
    /// スクショそのものの範囲
    var content: CGRect
    var radius: CGFloat
    var shadowBlur: CGFloat
}

// MARK: - 描く

final class BackgroundPainter {
    private var imageCache: [String: CGImage] = [:]
    private var edgeCache: (key: UnsafeMutableRawPointer, color: CGColor)?
    private static let ciContext = CIContext(options: nil)

    private func color(_ hex: UInt32) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    /// 壁紙・敷く画像を読む（大きすぎるものは縮めて覚える）。
    private func image(at path: String) -> CGImage? {
        if let hit = imageCache[path] { return hit }
        guard let loaded = loadImage(at: URL(fileURLWithPath: path))?.image else { return nil }
        let k = min(1, 2560 / CGFloat(max(loaded.width, loaded.height)))
        let small = resampled(loaded, width: max(1, Int(CGFloat(loaded.width) * k)), height: max(1, Int(CGFloat(loaded.height) * k))) ?? loaded
        imageCache[path] = small
        return small
    }

    /// 画面に出ている壁紙（カーソルのある画面のもの）。loadWallpaper で取ってくる。
    private(set) static var wallpaper: CGImage?

    /// 壁紙を取ってきて覚える。終わったら done を呼ぶ。
    static func loadWallpaper(_ done: (() -> Void)?) {
        captureWallpapers { shots in
            let here = screenUnderMouse()
            if let image = (shots.first { $0.screen == here } ?? shots.first)?.image { wallpaper = image }
            done?()
        }
    }

    /// スクショをぼかしたもの（背景に引き伸ばして敷く）。
    private func blurred(_ base: CGImage) -> CGImage? {
        let key = "blur:\(Unmanaged.passUnretained(base).toOpaque())"
        if let hit = imageCache[key] { return hit }
        let k = min(1, 480 / CGFloat(max(base.width, base.height)))
        guard let small = resampled(base, width: max(1, Int(CGFloat(base.width) * k)), height: max(1, Int(CGFloat(base.height) * k))) else { return nil }
        let input = CIImage(cgImage: small)
        let out = input.clampedToExtent().applyingGaussianBlur(sigma: 28).cropped(to: input.extent.insetBy(dx: 24, dy: 24))
        guard let result = Self.ciContext.createCGImage(out, from: out.extent) else { return nil }
        if imageCache.count > 12 { imageCache.removeAll() }
        imageCache[key] = result
        return result
    }

    private func drawAspectFill(_ image: CGImage, in rect: CGRect, ctx: CGContext) {
        let s = max(rect.width / CGFloat(image.width), rect.height / CGFloat(image.height))
        let w = CGFloat(image.width) * s, h = CGFloat(image.height) * s
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h))
    }

    private func drawGradient(_ index: Int, in rect: CGRect, ctx: CGContext) {
        let g = BackdropStyle.gradients[min(max(0, index), BackdropStyle.gradients.count - 1)]
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(g.0), color(g.1)] as CFArray,
                                        locations: [0, 1]) else { return }
        let angle = CGFloat(g.2) * .pi / 180
        let dx = cos(angle) * rect.width / 2, dy = sin(angle) * rect.height / 2
        ctx.drawLinearGradient(gradient, start: CGPoint(x: rect.midX - dx, y: rect.midY - dy), end: CGPoint(x: rect.midX + dx, y: rect.midY + dy),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    /// 背景を rect いっぱいに敷く。base は「ぼかし」の材料にするスクショ。
    func drawFill(_ style: BackdropStyle, in rect: CGRect, base: CGImage, ctx: CGContext) {
        ctx.saveGState()
        ctx.clip(to: rect)
        switch style.kind {
        case .gradient:
            drawGradient(style.gradient, in: rect, ctx: ctx)
        case .color:
            ctx.setFillColor(style.color.cgColor)
            ctx.fill(rect)
        case .blur:
            if let image = blurred(base) { drawAspectFill(image, in: rect, ctx: ctx) } else { drawGradient(0, in: rect, ctx: ctx) }
        case .wallpaper:
            if let image = Self.wallpaper { drawAspectFill(image, in: rect, ctx: ctx) }
            else { drawGradient(8, in: rect, ctx: ctx) }
        case .image:
            if let image = image(at: style.imagePath) { drawAspectFill(image, in: rect, ctx: ctx) } else { drawGradient(0, in: rect, ctx: ctx) }
        }
        ctx.restoreGState()
    }

    /// 内側の余白に塗る色。スクショの角の色に合わせる。
    func edgeColor(of base: CGImage) -> CGColor {
        let key = Unmanaged.passUnretained(base).toOpaque()
        if let hit = edgeCache, hit.key == key { return hit.color }
        var pixel = [UInt8](repeating: 255, count: 4)
        if let part = base.cropping(to: CGRect(x: 0, y: 0, width: min(6, base.width), height: min(6, base.height))),
           let one = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            one.draw(part, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        let a = max(1, CGFloat(pixel[3]))
        let color = pixel[3] < 8 ? CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
            : CGColor(srgbRed: CGFloat(pixel[0]) / a, green: CGFloat(pixel[1]) / a, blue: CGFloat(pixel[2]) / a, alpha: 1)
        edgeCache = (key, color)
        return color
    }

    /// 影を落として、内側の余白を塗る。返すのは、スクショを切り抜くための角丸の形。
    /// framed・radius・blur は ctx の座標での大きさ。
    func drawFrame(_ style: BackdropStyle, framed: CGRect, radius: CGFloat, blur: CGFloat, base: CGImage, ctx: CGContext) -> CGPath {
        let path = CGPath(roundedRect: framed, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.saveGState()
        if blur > 0.5 {
            ctx.setShadow(offset: CGSize(width: 0, height: -blur * 0.3), blur: blur,
                          color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.2 + 0.3 * CGFloat(style.shadow)))
        }
        ctx.setFillColor(edgeColor(of: base))
        ctx.addPath(path)
        ctx.fillPath()
        ctx.restoreGState()
        return path
    }

    /// 仕上がった画像（描いたものと切り抜きを反映したあと）に背景を付ける。
    func composite(_ content: CGImage, style: BackdropStyle, scale: CGFloat, base: CGImage) -> CGImage? {
        let l = style.layout(content: CGSize(width: content.width, height: content.height), scale: scale)
        guard l.outer.width <= 30000, l.outer.height <= 30000,
              let ctx = makeBitmapContext(width: Int(l.outer.width), height: Int(l.outer.height), like: content) else { return nil }
        drawFill(style, in: CGRect(origin: .zero, size: l.outer), base: base, ctx: ctx)
        let path = drawFrame(style, framed: l.framed, radius: l.radius, blur: l.shadowBlur, base: base, ctx: ctx)
        ctx.addPath(path)
        ctx.clip()
        ctx.interpolationQuality = .high
        ctx.draw(content, in: l.content)
        return ctx.makeImage()
    }
}

// MARK: - 覚えておくもの（前回の設定・保存した組み合わせ・自動で付ける設定）

enum BackgroundStore {
    private static let d = UserDefaults.standard

    /// 最後に使った設定（次に「背景」を入れたときの出発点）
    static var last: BackdropStyle {
        get { (d.dictionary(forKey: "backgroundLast")).map { BackdropStyle(dictionary: $0) } ?? BackdropStyle() }
        set { d.set(newValue.toDictionary(), forKey: "backgroundLast") }
    }

    /// 名前を付けて保存した組み合わせ
    static var presets: [(name: String, style: BackdropStyle)] {
        get {
            (d.array(forKey: "backgroundPresets") as? [[String: Any]] ?? []).compactMap { item in
                guard let name = item["name"] as? String, let style = item["style"] as? [String: Any] else { return nil }
                return (name, BackdropStyle(dictionary: style))
            }
        }
        set { d.set(newValue.map { ["name": $0.name, "style": $0.style.toDictionary()] as [String: Any] }, forKey: "backgroundPresets") }
    }

    /// 撮ったら自動で付ける組み合わせの名前。空なら付けない
    static var autoPreset: String {
        get { d.string(forKey: "backgroundAutoPreset") ?? "" }
        set { d.set(newValue, forKey: "backgroundAutoPreset") }
    }

    /// 撮った直後の画像に、決めてある組み合わせの背景を付ける。編集画面で開けば外したり変えたりできる。
    static func applyAuto(to file: URL) {
        let name = autoPreset
        guard !name.isEmpty, let style = presets.first(where: { $0.name == name })?.style else { return }
        apply(style, label: name, to: file)
    }

    /// ウィンドウを撮ったときに、設定してある背景を後ろに付ける。付けたら true。
    @discardableResult
    static func applyWindowBackdrop(to file: URL) -> Bool {
        let name = Prefs.windowBackdrop
        guard !name.isEmpty else { return false }
        if name == "wallpaper" {
            var style = BackdropStyle()
            style.kind = .wallpaper
            style.padding = 0.3
            style.corners = 0        // ウィンドウの角と影は、撮った画像にもう入っている
            style.shadow = Prefs.windowShadow ? 0 : 0.5
            return apply(style, label: "壁紙", to: file)
        }
        guard let style = presets.first(where: { $0.name == name })?.style else { return false }
        return apply(style, label: name, to: file)
    }

    @discardableResult
    private static func apply(_ original: BackdropStyle, label: String, to file: URL) -> Bool {
        var style = original
        guard !isMotion(file), let loaded = loadImage(at: file) else { return false }
        style.enabled = true
        let scale = max(1, loaded.dpi / 72)
        guard let out = BackgroundPainter().composite(loaded.image, style: style, scale: scale, base: loaded.image),
              let data = pngData(out, dpi: loaded.dpi) else { return false }
        EditProject.keepBase(of: file)
        guard (try? data.write(to: file, options: .atomic)) != nil else { return false }
        let renderer = Renderer(base: loaded.image, dpiScale: scale)
        renderer.background = style
        EditProject.save(for: file, annotations: [], renderer: renderer, dpi: loaded.dpi)
        log("背景を自動で付けた 「\(label)」 \(out.width)x\(out.height)")
        return true
    }
}

// MARK: - 「背景」の小窓

/// 背景の見本を描くボタン。
final class SwatchButton: NSButton {
    var style: BackdropStyle
    var isOn = false { didSet { needsDisplay = true } }
    private let symbol: String?
    private static let painter = BackgroundPainter()

    init(style: BackdropStyle, symbol: String?, tip: String, target: AnyObject, action: Selector) {
        self.style = style
        self.symbol = symbol
        super.init(frame: .zero)
        self.target = target
        self.action = action
        title = ""
        isBordered = false
        toolTip = tip
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 38).isActive = true
        heightAnchor.constraint(equalToConstant: 28).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let box = bounds.insetBy(dx: 3, dy: 3)
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: box, cornerWidth: 5, cornerHeight: 5, transform: nil))
        ctx.clip()
        if symbol == nil || style.kind == .color {
            // グラデーションと単色は、そのままの見た目を出す
            if let dummy = makeBitmapContext(width: 1, height: 1, like: nil)?.makeImage() {
                Self.painter.drawFill(style, in: box, base: dummy, ctx: ctx)
            }
        } else {
            ctx.setFillColor(NSColor(white: 0.28, alpha: 1).cgColor)
            ctx.fill(box)
        }
        ctx.restoreGState()
        if let symbol, let icon = tintedSymbol(symbol, pointSize: 12, color: style.kind == .color ? contrastColor(for: style.color) : .white) {
            icon.draw(in: NSRect(x: bounds.midX - icon.size.width / 2, y: bounds.midY - icon.size.height / 2,
                                 width: icon.size.width, height: icon.size.height))
        }
        let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7)
        ring.lineWidth = 2
        (isOn ? NSColor.controlAccentColor : NSColor.clear).setStroke()
        ring.stroke()
    }
}

final class BackgroundPanelController: NSViewController {
    private let get: () -> BackdropStyle
    private let set: (BackdropStyle) -> Void
    private var enableBox: NSButton!
    private var swatches: [SwatchButton] = []
    private var colorSwatch: SwatchButton!
    private var sliders: [NSSlider] = []
    private var alignButtons: [NSButton] = []
    private var ratioPopup: NSPopUpButton!
    private var presetPopup: NSPopUpButton!
    private var body: NSStackView!
    /// 設定は同じでも絵が変わったとき（壁紙を取り直したとき）に、画面を描き直してもらう
    var onRedraw: (() -> Void)?

    init(get: @escaping () -> BackdropStyle, set: @escaping (BackdropStyle) -> Void) {
        self.get = get
        self.set = set
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func change(_ body: (inout BackdropStyle) -> Void) {
        var s = get()
        body(&s)
        set(s)
        sync()
    }

    override func loadView() {
        enableBox = NSButton(checkboxWithTitle: "背景を付ける", target: self, action: #selector(enableChanged))

        // 背景の種類
        for n in BackdropStyle.gradients.indices {
            var s = BackdropStyle()
            s.gradient = n
            swatches.append(SwatchButton(style: s, symbol: nil, tip: "グラデーション \(n + 1)", target: self, action: #selector(swatchTapped(_:))))
        }
        func special(_ kind: BackdropStyle.Kind, _ symbol: String, _ tip: String) -> SwatchButton {
            var s = BackdropStyle()
            s.kind = kind
            let b = SwatchButton(style: s, symbol: symbol, tip: tip, target: self, action: #selector(swatchTapped(_:)))
            swatches.append(b)
            return b
        }
        colorSwatch = special(.color, "paintpalette", "単色。押すと色を選べます")
        _ = special(.blur, "drop.halffull", "スクショそのものをぼかして敷く")
        _ = special(.wallpaper, "desktopcomputer", "いまのデスクトップの壁紙を敷く")
        _ = special(.image, "photo", "好きな画像を選んで敷く")
        var rows: [NSView] = []
        for start in stride(from: 0, to: swatches.count, by: 8) {
            let row = NSStackView(views: Array(swatches[start..<min(start + 8, swatches.count)]))
            row.spacing = 2
            rows.append(row)
        }
        let grid = NSStackView(views: rows)
        grid.orientation = .vertical
        grid.alignment = .leading
        grid.spacing = 2

        func slider(_ title: String, _ tag: Int) -> NSView {
            let label = NSTextField(labelWithString: title)
            label.alignment = .right
            label.translatesAutoresizingMaskIntoConstraints = false
            label.widthAnchor.constraint(equalToConstant: 76).isActive = true
            let s = NSSlider(value: 0, minValue: 0, maxValue: 1, target: self, action: #selector(sliderChanged(_:)))
            s.tag = tag
            s.controlSize = .small
            s.translatesAutoresizingMaskIntoConstraints = false
            s.widthAnchor.constraint(equalToConstant: 220).isActive = true
            sliders.append(s)
            let row = NSStackView(views: [label, s])
            row.spacing = 10
            return row
        }

        // 置く場所（3×3）
        var alignRows: [NSView] = []
        for r in 0..<3 {
            var buttons: [NSView] = []
            for c in 0..<3 {
                let b = NSButton(title: "", target: self, action: #selector(alignTapped(_:)))
                b.tag = r * 3 + c
                b.setButtonType(.pushOnPushOff)
                b.bezelStyle = .smallSquare
                b.translatesAutoresizingMaskIntoConstraints = false
                b.widthAnchor.constraint(equalToConstant: 24).isActive = true
                b.heightAnchor.constraint(equalToConstant: 18).isActive = true
                alignButtons.append(b)
                buttons.append(b)
            }
            let row = NSStackView(views: buttons)
            row.spacing = 2
            alignRows.append(row)
        }
        let alignGrid = NSStackView(views: alignRows)
        alignGrid.orientation = .vertical
        alignGrid.spacing = 2
        func labeled(_ title: String, _ view: NSView) -> NSView {
            let label = NSTextField(labelWithString: title)
            label.alignment = .right
            label.translatesAutoresizingMaskIntoConstraints = false
            label.widthAnchor.constraint(equalToConstant: 76).isActive = true
            let row = NSStackView(views: [label, view])
            row.spacing = 10
            return row
        }
        ratioPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        ratioPopup.addItems(withTitles: BackdropStyle.ratios.map(\.0))
        ratioPopup.target = self
        ratioPopup.action = #selector(ratioChanged)
        ratioPopup.controlSize = .small

        presetPopup = NSPopUpButton(frame: .zero, pullsDown: true)
        presetPopup.controlSize = .small
        presetPopup.target = self
        presetPopup.action = #selector(presetChosen(_:))

        body = NSStackView(views: [grid, slider("余白", 0), slider("内側の余白", 1), slider("角の丸み", 2), slider("影", 3),
                                   labeled("置く場所", alignGrid), labeled("縦横の比率", ratioPopup)])
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 8

        let stack = NSStackView(views: [enableBox, body, labeled("組み合わせ", presetPopup)])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 16)
        view = stack
        sync()
    }

    /// 画面の部品を、いまの設定に合わせる
    func sync() {
        guard isViewLoaded else { return }
        let s = get()
        enableBox.state = s.enabled ? .on : .off
        for b in swatches {
            b.isOn = b.style.kind == s.kind && (s.kind != .gradient || b.style.gradient == s.gradient)
        }
        colorSwatch.style.rgb = s.rgb
        colorSwatch.needsDisplay = true
        let values = [s.padding, s.inset, s.corners, s.shadow]
        for slider in sliders { slider.doubleValue = values[slider.tag] }
        for b in alignButtons { b.state = b.tag == s.alignment ? .on : .off }
        ratioPopup.selectItem(at: BackdropStyle.ratios.firstIndex { abs($0.1 - s.ratio) < 0.001 } ?? 0)
        // 入れていないときは、下の部品を薄くして触れなくする
        body.alphaValue = s.enabled ? 1 : 0.4
        rebuildPresetMenu()
    }

    private func rebuildPresetMenu() {
        let presets = BackgroundStore.presets
        presetPopup.removeAllItems()
        presetPopup.addItem(withTitle: presets.isEmpty ? "保存したものはありません" : "保存したものを使う")
        for p in presets { presetPopup.addItem(withTitle: p.name) }
        presetPopup.menu?.addItem(.separator())
        presetPopup.addItem(withTitle: "いまの設定を保存…")
        if !presets.isEmpty {
            for p in presets { presetPopup.addItem(withTitle: "「\(p.name)」を削除") }
        }
    }

    @objc private func enableChanged() { change { $0.enabled = enableBox.state == .on } }

    @objc private func swatchTapped(_ sender: SwatchButton) {
        switch sender.style.kind {
        case .color:
            change { $0.enabled = true; $0.kind = .color }
            let panel = NSColorPanel.shared
            panel.showsAlpha = false
            panel.color = get().color
            panel.setTarget(self)
            panel.setAction(#selector(colorPicked(_:)))
            panel.orderFront(nil)
        case .image:
            let open = NSOpenPanel()
            open.allowedContentTypes = [.image]
            open.message = "背景に敷く画像を選んでください"
            if open.runModal() == .OK, let url = open.url {
                change { $0.enabled = true; $0.kind = .image; $0.imagePath = url.path }
            }
        case .wallpaper:
            // いまの壁紙を取ってきてから敷く
            BackgroundPainter.loadWallpaper { [weak self] in self?.change { $0.enabled = true; $0.kind = .wallpaper }; self?.onRedraw?() }
        default:
            change { $0.enabled = true; $0.kind = sender.style.kind; $0.gradient = sender.style.gradient }
        }
    }

    @objc private func colorPicked(_ sender: NSColorPanel) {
        change { $0.kind = .color; $0.color = sender.color }
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        let v = sender.doubleValue
        change {
            $0.enabled = true
            switch sender.tag {
            case 0: $0.padding = v
            case 1: $0.inset = v
            case 2: $0.corners = v
            default: $0.shadow = v
            }
        }
    }

    @objc private func alignTapped(_ sender: NSButton) { change { $0.enabled = true; $0.alignment = sender.tag } }

    @objc private func ratioChanged() {
        let i = ratioPopup.indexOfSelectedItem
        change { $0.enabled = true; $0.ratio = BackdropStyle.ratios.indices.contains(i) ? BackdropStyle.ratios[i].1 : 0 }
    }

    @objc private func presetChosen(_ sender: NSPopUpButton) {
        let title = sender.titleOfSelectedItem ?? ""
        var presets = BackgroundStore.presets
        if title == "いまの設定を保存…" {
            let alert = NSAlert()
            alert.messageText = "この組み合わせに名前を付けて保存"
            alert.informativeText = "設定の「編集」で、撮ったら自動で付ける組み合わせに選べます。"
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
            field.stringValue = "背景 \(presets.count + 1)"
            alert.accessoryView = field
            alert.addButton(withTitle: "保存")
            alert.addButton(withTitle: "やめる")
            alert.window.initialFirstResponder = field
            if alert.runModal() == .alertFirstButtonReturn { savePreset(named: field.stringValue) }
        } else if title.hasPrefix("「"), title.hasSuffix("」を削除") {
            let name = String(title.dropFirst().dropLast(5))
            presets.removeAll { $0.name == name }
            BackgroundStore.presets = presets
            if BackgroundStore.autoPreset == name { BackgroundStore.autoPreset = "" }
        } else if let p = presets.first(where: { $0.name == title }) {
            change { $0 = p.style; $0.enabled = true }
        }
        sync()
    }

    /// いまの設定を名前を付けて保存する（同じ名前があれば上書き）。
    func savePreset(named raw: String) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        var presets = BackgroundStore.presets
        var style = get()
        style.enabled = true
        presets.removeAll { $0.name == name }
        presets.append((name, style))
        BackgroundStore.presets = presets
        sync()
    }
}
