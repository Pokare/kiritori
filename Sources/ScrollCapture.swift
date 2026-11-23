// スクロール撮影。
// 範囲を決めたあと、下へスクロールしていく画面を細かく撮り続け、
// 前のコマと重なっている所を探して、増えた分だけを下へ継ぎ足して1枚の縦長の画像にする。

import AppKit
import ScreenCaptureKit

/// コマをつなぎ合わせる処理（撮り方とは切り離してあるので、単独で試せる）。
final class ScrollStitcher {
    private(set) var strips: [CGImage] = []
    private(set) var totalHeight = 0
    private(set) var width = 0
    private var lastSignature: [UInt8] = []
    private var lastHeight = 0
    /// つなげなかったコマが続いた数（速く動かしすぎたときに増える）
    private(set) var misses = 0
    static let columns = 48
    static let maxHeight = 40000

    /// 各行を、横に 48 個へ縮めた明るさの列にする（行ごとの特徴）。
    static func signature(of image: CGImage) -> [UInt8] {
        let h = image.height
        var data = [UInt8](repeating: 0, count: columns * h)
        data.withUnsafeMutableBytes { buffer in
            if let ctx = CGContext(data: buffer.baseAddress, width: columns, height: h, bitsPerComponent: 8, bytesPerRow: columns,
                                   space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) {
                ctx.interpolationQuality = .low
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: columns, height: h))
            }
        }
        return data   // 先頭が画像のいちばん上の行
    }

    /// 前のコマが上へ何行ずれたら、新しいコマと重なるかを探す。分からなければ nil、動いていなければ 0。
    static func findShift(previous: [UInt8], current: [UInt8], height h: Int) -> Int? {
        let c = columns
        guard previous.count == c * h, current.count == c * h, h > 40 else { return nil }
        func rowDiff(_ a: Int, _ b: Int) -> Int {   // 前のコマの a 行目と、新しいコマの b 行目の違い
            var d = 0
            let pa = a * c, pb = b * c
            for k in 0..<c { d += abs(Int(previous[pa + k]) - Int(current[pb + k])) }
            return d
        }
        // 模様のない行（真っ白など）はどこにでも合ってしまうので、判断に使わない
        var informative = [Bool](repeating: false, count: h)
        var informativeCount = 0
        for r in 0..<h {
            var lo = 255, hi = 0
            for k in 0..<c { let v = Int(current[r * c + k]); lo = min(lo, v); hi = max(hi, v) }
            if hi - lo > 10 { informative[r] = true; informativeCount += 1 }
        }
        guard informativeCount >= max(12, h / 40) else { return nil }
        let tolerance = c * 4

        func score(_ s: Int) -> Double {   // s 行ずれたと仮定したときに、合う行の割合
            var used = 0, matched = 0
            var i = 0
            while i < h - s {
                if informative[i] {
                    used += 1
                    if rowDiff(i + s, i) <= tolerance { matched += 1 }
                }
                i += 1
            }
            return used >= 8 ? Double(matched) / Double(used) : 0
        }
        if score(0) >= 0.97 { return 0 }
        var best = (shift: 0, score: 0.0)
        for s in 1..<Int(Double(h) * 0.92) {
            let sc = score(s)
            if sc > best.score + 0.001 { best = (s, sc) }
        }
        return best.score >= 0.8 ? best.shift : nil
    }

    /// コマを足す。つなげたら true。
    @discardableResult
    func add(_ frame: CGImage) -> Bool {
        let sig = Self.signature(of: frame)
        if strips.isEmpty {
            strips = [frame]
            totalHeight = frame.height
            width = frame.width
            lastSignature = sig
            lastHeight = frame.height
            return true
        }
        guard frame.width == width, frame.height == lastHeight, totalHeight < Self.maxHeight else { return false }
        guard let shift = Self.findShift(previous: lastSignature, current: sig, height: lastHeight) else {
            misses += 1
            return false
        }
        misses = 0
        guard shift > 0 else { return true }   // 動いていない
        // 新しく見えた下の shift 行だけを継ぎ足す
        if let strip = frame.cropping(to: CGRect(x: 0, y: frame.height - shift, width: frame.width, height: shift)) {
            strips.append(strip)
            totalHeight += shift
        }
        lastSignature = sig
        return true
    }

    /// つないだ1枚の画像
    func result() -> CGImage? {
        guard width > 0, totalHeight > 0,
              let ctx = CGContext(data: nil, width: width, height: totalHeight, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        var y = totalHeight   // 上から順に置いていく（描く座標は下が原点）
        for strip in strips {
            y -= strip.height
            ctx.draw(strip, in: CGRect(x: 0, y: y, width: strip.width, height: strip.height))
        }
        return ctx.makeImage()
    }
}

/// スクロール撮影中に出す操作の帯
final class ScrollBarView: NSView {
    let label = NSTextField(labelWithString: "")
    private let stack = NSStackView()

    init(target: AnyObject, done: Selector, cancel: Selector) {
        super.init(frame: .zero)
        label.font = .monospacedDigitSystemFont(ofSize: 12.5, weight: .medium)
        label.textColor = NSColor.white.withAlphaComponent(0.92)
        let cancelButton = PillButton(caption: "やめる", primary: false, target: target, action: cancel)
        let doneButton = PillButton(caption: "完了", primary: true, target: target, action: done)
        for v in [label, cancelButton, doneButton] as [NSView] { stack.addArrangedSubview(v) }
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.setCustomSpacing(14, after: label)
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 0.94).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill()
    }

    var fitting: NSSize { layoutSubtreeIfNeeded(); return stack.fittingSize }
}

/// スクロール撮影の1回分。macOS 14 以上。
@available(macOS 14.0, *)
final class ScrollCaptureSession: NSObject {
    private let rect: NSRect        // 全画面を通した AppKit の座標
    private let screen: NSScreen
    private let stitcher = ScrollStitcher()
    private var filter: SCContentFilter?
    private var config = SCStreamConfiguration()
    private var timer: Timer?
    private var busy = false
    private var frameWindow: NSWindow?
    private var barWindow: NSPanel?
    private var bar: ScrollBarView?
    private let work = DispatchQueue(label: "local.kiritori.scroll")
    /// 終わったら呼ぶ（やめた・失敗したときは nil）
    var onFinish: ((CGImage?) -> Void)?

    init(rect: NSRect, screen: NSScreen) {
        self.rect = rect
        self.screen = screen
    }

    func start() {
        showChrome()
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
                guard let display = content.displays.first(where: { $0.displayID == id }) ?? content.displays.first else { throw NSError(domain: "Kiritori", code: 2) }
                let mine = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
                let filter = SCContentFilter(display: display, excludingApplications: mine, exceptingWindows: [])
                let scale = screen.backingScaleFactor
                let config = SCStreamConfiguration()
                config.sourceRect = CGRect(x: rect.minX - screen.frame.minX, y: screen.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
                config.width = Int(rect.width * scale)
                config.height = Int(rect.height * scale)
                config.showsCursor = false
                await MainActor.run {
                    self.filter = filter
                    self.config = config
                    let t = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in self?.tick() }
                    RunLoop.main.add(t, forMode: .common)
                    self.timer = t
                }
            } catch {
                log("スクロール撮影: 始められない \(error)")
                await MainActor.run { self.finish(nil) }
            }
        }
    }

    private func tick() {
        guard !busy, let filter else { return }
        busy = true
        SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { [weak self] image, _ in
            guard let self else { return }
            guard let image else { DispatchQueue.main.async { self.busy = false }; return }
            self.work.async {
                self.stitcher.add(image)
                let height = self.stitcher.totalHeight, misses = self.stitcher.misses
                DispatchQueue.main.async {
                    self.busy = false
                    let scale = self.screen.backingScaleFactor
                    self.bar?.label.stringValue = misses >= 3
                        ? "速すぎます。少し戻して、ゆっくりスクロールしてください"
                        : "下へゆっくりスクロール　高さ \(Int(CGFloat(height) / scale))"
                    self.layoutBar()
                    if height >= ScrollStitcher.maxHeight { self.doneTapped() }
                }
            }
        }
    }

    @objc func doneTapped() {
        timer?.invalidate()
        timer = nil
        work.async {
            let image = self.stitcher.result()
            DispatchQueue.main.async {
                log("スクロール撮影: 完了 コマの帯=\(self.stitcher.strips.count) 高さ=\(self.stitcher.totalHeight)px")
                self.finish(image)
            }
        }
    }

    @objc func cancelTapped() {
        timer?.invalidate()
        timer = nil
        finish(nil)
    }

    private func finish(_ image: CGImage?) {
        frameWindow?.orderOut(nil)
        barWindow?.orderOut(nil)
        frameWindow = nil
        barWindow = nil
        onFinish?(image)
        onFinish = nil
    }

    /// 撮っている範囲の青い枠と、操作の帯。どちらも自分の窓なので画像には写らない。
    private func showChrome() {
        let m: CGFloat = 4
        let f = NSWindow(contentRect: rect.insetBy(dx: -m, dy: -m), styleMask: .borderless, backing: .buffered, defer: false)
        f.setFrame(rect.insetBy(dx: -m, dy: -m), display: false)
        f.isReleasedWhenClosed = false
        f.isOpaque = false
        f.backgroundColor = .clear
        f.hasShadow = false
        f.ignoresMouseEvents = true   // スクロールやクリックは下のアプリへ通す
        f.level = .statusBar
        f.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let outline = OutlineView(frame: NSRect(origin: .zero, size: f.frame.size))
        f.contentView = outline
        f.orderFrontRegardless()
        frameWindow = f

        let view = ScrollBarView(target: self, done: #selector(doneTapped), cancel: #selector(cancelTapped))
        view.label.stringValue = "下へゆっくりスクロールして、終わったら「完了」"
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isReleasedWhenClosed = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .statusBar
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = view
        barWindow = p
        bar = view
        layoutBar()
        p.orderFrontRegardless()
    }

    private func layoutBar() {
        guard let bar, let barWindow else { return }
        let size = bar.fitting
        let vf = screen.frame
        var origin = NSPoint(x: rect.midX - size.width / 2, y: rect.minY - size.height - 14)
        if origin.y < vf.minY + 8 { origin.y = rect.maxY + 14 }                       // 下に入らなければ上
        if origin.y + size.height > vf.maxY - 8 { origin.y = rect.minY + 14 }        // それも無理なら範囲の中の下寄り
        origin.x = max(vf.minX + 8, min(vf.maxX - size.width - 8, origin.x))
        barWindow.setFrame(NSRect(origin: origin, size: size), display: true)
    }
}

final class OutlineView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 4, yRadius: 4)
        path.lineWidth = 2
        NSColor.controlAccentColor.setStroke()
        path.stroke()
    }
}
