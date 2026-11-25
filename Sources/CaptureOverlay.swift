// スクショの範囲選び（自前の幕）。
// 画面を止めた画像の上で選ぶので、拡大鏡で1ピクセル単位に合わせられ、動いているものも撮れる。
// セルフタイマーとスクロール撮影では、画面を止めない「生」の幕として同じ部品を使う。

import AppKit
import ScreenCaptureKit

/// 範囲を選ぶビュー。frozen があれば、その画像を止めた画面として下に敷いてある前提で、拡大鏡を出す。
final class ShotSelectionView: NSView {
    /// 止めた画面の画像（無ければ生の画面の上で選ぶ）
    let frozen: CGImage?
    var hint = "ドラッグで範囲を選ぶ　／　esc か右クリックでやめる"
    var showMagnifier = true
    var showCrosshair = true
    /// 選び終わり。クリックだけ（ドラッグなし）なら nil。rect はこのビューの座標。
    var onDone: ((NSRect?) -> Void)?
    /// 右クリックでやめる（esc が効かないときの逃げ道にもなる）
    var onCancel: (() -> Void)?

    private var startPoint: NSPoint?
    private var mouse: NSPoint?

    init(frame: NSRect, frozen: CGImage?) {
        self.frozen = frozen
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError() }

    var selection: NSRect? {
        guard let a = startPoint, let b = mouse else { return nil }
        return NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y)).integral
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    private func clamp(_ p: NSPoint) -> NSPoint {
        NSPoint(x: max(0, min(bounds.maxX, p.x)), y: max(0, min(bounds.maxY, p.y)))
    }

    override func mouseMoved(with event: NSEvent) { mouse = clamp(convert(event.locationInWindow, from: nil)); needsDisplay = true }
    override func mouseExited(with event: NSEvent) { if startPoint == nil { mouse = nil; needsDisplay = true } }
    override func mouseDown(with event: NSEvent) {
        startPoint = clamp(convert(event.locationInWindow, from: nil))
        mouse = startPoint
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) { mouse = clamp(convert(event.locationInWindow, from: nil)); needsDisplay = true }
    override func rightMouseDown(with event: NSEvent) { onCancel?() }
    override func mouseUp(with event: NSEvent) {
        let sel = selection
        startPoint = nil
        needsDisplay = true
        if let sel, sel.width >= 4, sel.height >= 4 { onDone?(sel) } else { onDone?(nil) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let sel = selection.flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil }
        let dim = NSBezierPath(rect: bounds)
        if let sel {
            dim.append(NSBezierPath(rect: sel))
            dim.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(0.3).setFill()
        dim.fill()

        if let sel {
            let border = NSBezierPath(rect: sel.insetBy(dx: -0.5, dy: -0.5))
            border.lineWidth = 1
            NSColor.white.setStroke()
            border.stroke()
        }
        guard let mouse else {
            pill(hint, size: 14, at: NSPoint(x: bounds.midX, y: 72), anchor: .center)
            return
        }
        if showCrosshair, sel == nil {
            // カーソルを通る縦横の細い線
            let lines = NSBezierPath()
            lines.move(to: NSPoint(x: 0, y: mouse.y.rounded() + 0.5)); lines.line(to: NSPoint(x: bounds.maxX, y: mouse.y.rounded() + 0.5))
            lines.move(to: NSPoint(x: mouse.x.rounded() + 0.5, y: 0)); lines.line(to: NSPoint(x: mouse.x.rounded() + 0.5, y: bounds.maxY))
            lines.lineWidth = 1
            NSColor.black.withAlphaComponent(0.35).setStroke()
            lines.stroke()
            lines.setLineDash([4, 4], count: 2, phase: 0)
            NSColor.white.withAlphaComponent(0.9).setStroke()
            lines.stroke()
        }
        let info = sel.map { "\(Int($0.width)) × \(Int($0.height))" } ?? "\(Int(mouse.x)), \(Int(bounds.maxY - mouse.y))"
        if showMagnifier, frozen != nil {
            drawMagnifier(at: mouse, label: info)
        } else {
            pill(info, size: 12, at: NSPoint(x: mouse.x + 16, y: mouse.y - 30), anchor: .left)
        }
        if sel == nil { pill(hint, size: 14, at: NSPoint(x: bounds.midX, y: 72), anchor: .center) }
    }

    private enum Anchor { case center, left }

    private func pill(_ text: String, size: CGFloat, at p: NSPoint, anchor: Anchor) {
        let label = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .medium), .foregroundColor: NSColor.white,
        ])
        let s = label.size()
        var r = NSRect(x: anchor == .center ? p.x - s.width / 2 - 12 : p.x, y: p.y, width: s.width + 24, height: s.height + 10)
        r.origin.x = max(8, min(bounds.maxX - r.width - 8, r.origin.x))
        r.origin.y = max(8, min(bounds.maxY - r.height - 8, r.origin.y))
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2).fill()
        label.draw(at: NSPoint(x: r.minX + 12, y: r.minY + 5))
    }

    /// カーソルのまわりを大きく映す丸い拡大鏡。真ん中の1マスが、いま指している1ピクセル。
    private func drawMagnifier(at mouse: NSPoint, label: String) {
        guard let frozen, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let sx = CGFloat(frozen.width) / bounds.width, sy = CGFloat(frozen.height) / bounds.height
        let cells = 15                      // 縦横に映すピクセルの数（奇数）
        let cell: CGFloat = 9               // 1ピクセルを何ポイントで映すか
        let side = CGFloat(cells) * cell
        // カーソルの右下に出す。画面の端では反対側へ逃がす
        var origin = NSPoint(x: mouse.x + 22, y: mouse.y - 22 - side)
        if origin.x + side > bounds.maxX - 8 { origin.x = mouse.x - 22 - side }
        if origin.y < 40 { origin.y = mouse.y + 22 }
        let rect = NSRect(x: origin.x, y: origin.y, width: side, height: side)

        // 画像は左上が原点
        let px = Int((mouse.x * sx).rounded(.down)), py = Int(((bounds.maxY - mouse.y) * sy).rounded(.down))
        let half = cells / 2
        let source = CGRect(x: px - half, y: py - half, width: cells, height: cells)

        ctx.saveGState()
        let circle = CGPath(ellipseIn: rect, transform: nil)
        ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 10, color: NSColor.black.withAlphaComponent(0.5).cgColor)
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.addPath(circle)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(circle)
        ctx.clip()
        ctx.interpolationQuality = .none
        // 画面の端では切り出しが小さくなるので、欠けた分だけずらして描く
        let bounded = source.intersection(CGRect(x: 0, y: 0, width: frozen.width, height: frozen.height))
        if !bounded.isEmpty, let part = frozen.cropping(to: bounded) {
            let dx = (bounded.minX - source.minX) * cell
            let dyTop = (bounded.minY - source.minY) * cell
            ctx.draw(part, in: CGRect(x: rect.minX + dx, y: rect.maxY - dyTop - bounded.height * cell,
                                      width: bounded.width * cell, height: bounded.height * cell))
        }
        // マス目
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.14).cgColor)
        ctx.setLineWidth(0.5)
        for i in 1..<cells {
            let o = CGFloat(i) * cell
            ctx.move(to: CGPoint(x: rect.minX + o, y: rect.minY)); ctx.addLine(to: CGPoint(x: rect.minX + o, y: rect.maxY))
            ctx.move(to: CGPoint(x: rect.minX, y: rect.minY + o)); ctx.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + o))
        }
        ctx.strokePath()
        // 真ん中の1マス
        let center = CGRect(x: rect.minX + CGFloat(half) * cell, y: rect.minY + CGFloat(half) * cell, width: cell, height: cell)
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.7).cgColor)
        ctx.setLineWidth(2.5)
        ctx.stroke(center)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(center)
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(CGPath(ellipseIn: rect.insetBy(dx: 1, dy: 1), transform: nil))
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
        ctx.setLineWidth(2)
        ctx.strokePath()
        ctx.restoreGState()

        pill(label, size: 12, at: NSPoint(x: rect.midX, y: rect.minY - 30), anchor: .center)
    }

    /// 動作確認用：カーソルの場所と、ドラッグの途中の見た目を作る
    func testSet(mouse: NSPoint, start: NSPoint?) {
        self.mouse = mouse
        startPoint = start
        needsDisplay = true
    }
}

final class ShotSelectionPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() } else { super.keyDown(with: event) }
    }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// 全部の画面に幕を出して、スクショの範囲を選ばせる。
final class ShotSelector {
    private var panels: [ShotSelectionPanel] = []
    /// 幕は全部の画面を覆っているので、出ている間のクリックは必ず Kiritori に届くはず。
    /// よそのアプリへ行ったクリックがあれば、同じキーにほかのアプリも反応して手前に何か出している。
    private var clickMonitor: Any?
    private(set) var clickWentElsewhere = false
    private let frozen: [(screen: NSScreen, image: CGImage)]
    private let hint: String
    /// rect は全画面を通した AppKit の座標（クリックだけなら nil）。cropped は止めた画面から切り出した画像（生の幕なら nil）。
    private let onDone: (_ rect: NSRect?, _ screen: NSScreen, _ cropped: CGImage?) -> Void
    private let onCancel: () -> Void

    /// frozen が空なら、画面を止めない生の幕になる。
    init(frozen: [(screen: NSScreen, image: CGImage)], hint: String,
         onDone: @escaping (NSRect?, NSScreen, CGImage?) -> Void, onCancel: @escaping () -> Void) {
        self.frozen = frozen
        self.hint = hint
        self.onDone = onDone
        self.onCancel = onCancel
    }

    func show() {
        for screen in NSScreen.screens {
            // 画面は番号で照らし合わせる（NSScreen は呼ぶたびに別の入れ物になることがある）
            func number(_ s: NSScreen) -> UInt32? { (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value }
            let image = frozen.first { number($0.screen) == number(screen) }?.image
            if !frozen.isEmpty { log("範囲選びの幕: 画面 \(Int(screen.frame.width))x\(Int(screen.frame.height)) 止めた絵=\(image.map { "\($0.width)x\($0.height)" } ?? "なし")") }
            let panel = ShotSelectionPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                           backing: .buffered, defer: false)
            panel.setFrame(screen.frame, display: false)
            panel.isReleasedWhenClosed = false
            panel.level = .screenSaver
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.animationBehavior = .none
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.acceptsMouseMovedEvents = true
            panel.onCancel = { [weak self] in self?.close(); self?.onCancel() }

            let size = screen.frame.size
            let container = NSView(frame: NSRect(origin: .zero, size: size))
            if let image {
                // 止めた画面を下に敷く（選んでいる間、画面は動かない）
                // 画像ビューで敷く。幕全体をレイヤーつきにして、カーソルを動かすたびにこの大きな絵を描き直さずに済むようにする
                container.wantsLayer = true
                let still = NSImageView(frame: container.bounds)
                still.image = NSImage(cgImage: image, size: size)
                still.imageScaling = .scaleAxesIndependently
                still.imageFrameStyle = .none
                still.wantsLayer = true
                container.addSubview(still)
            }
            let view = ShotSelectionView(frame: container.bounds, frozen: image)
            view.hint = hint
            view.showMagnifier = Prefs.showMagnifier
            view.showCrosshair = Prefs.showCrosshair
            view.onCancel = { [weak self] in self?.close(); self?.onCancel() }
            view.wantsLayer = image != nil
            view.onDone = { [weak self, weak view] rect in
                guard let self else { return }
                // 止めた画面の幕では、クリックだけなら何もしない（そのまま選び直せる）
                if rect == nil, image != nil { return }
                var cropped: CGImage?
                if let rect, let image, let view {
                    let sx = CGFloat(image.width) / view.bounds.width, sy = CGFloat(image.height) / view.bounds.height
                    cropped = image.cropping(to: CGRect(x: (rect.minX * sx).rounded(), y: ((view.bounds.maxY - rect.maxY) * sy).rounded(),
                                                        width: (rect.width * sx).rounded(), height: (rect.height * sy).rounded()))
                }
                self.close()
                self.onDone(rect?.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY), screen, cropped)
            }
            container.addSubview(view)
            panel.contentView = container
            panels.append(panel)
        }
        let mouse = NSEvent.mouseLocation
        for panel in panels { panel.orderFrontRegardless() }
        (panels.first { NSMouseInRect(mouse, $0.frame, false) } ?? panels.first)?.makeKey()
        if clickMonitor == nil {
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in self?.clickWentElsewhere = true }
        }
    }

    func close() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        panels.forEach { $0.orderOut(nil) }
        panels = []
    }

    /// 動作確認用：最初の画面の幕で、マウスでドラッグしたことにする（点はその画面の左下からの位置）
    func testDrag(from a: NSPoint, to b: NSPoint) {
        guard let panel = panels.first, let view = panel.contentView?.subviews.compactMap({ $0 as? ShotSelectionView }).first else { return }
        func event(_ type: NSEvent.EventType, _ p: NSPoint) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        if let e = event(.leftMouseDown, a) { view.mouseDown(with: e) }
        if let e = event(.leftMouseDragged, b) { view.mouseDragged(with: e) }
        if let e = event(.leftMouseUp, b) { view.mouseUp(with: e) }
    }
}

/// 全部の画面を1枚ずつ撮る（画面を止めた画像にする）。終わったら main で返す。
/// macOS 14 以上は画面の絵をメモリで直接もらう（速い）。もらえなかった画面があれば、ファイル経由の古いやり方でやり直す。
/// hide に渡した窓（先に出してある仮の幕）は絵に写さない。
func captureAllScreens(hide: [NSWindow] = [], completion: @escaping ([(screen: NSScreen, image: CGImage)]) -> Void) {
    let started = Date()
    func ms() -> Int { Int(Date().timeIntervalSince(started) * 1000) }
    // 確認用：KIRITORI_FREEZE_FILE=1 で古いやり方に固定する（速さを比べるため）
    if #available(macOS 14.0, *), ProcessInfo.processInfo.environment["KIRITORI_FREEZE_FILE"] == nil {
        let count = NSScreen.screens.count
        captureAllScreensDirect(hide: hide.map { $0.windowNumber }) { shots in
            if shots.count == count, count > 0 {
                log("画面を止めた（直接）\(count)枚 \(ms())ms")
                completion(shots)
            } else {
                log("画面を直接もらえなかった（\(shots.count)/\(count)枚）。ファイル経由でやり直す")
                captureAllScreensByFile { shots in
                    log("画面を止めた（ファイル経由）\(shots.count)枚 \(ms())ms")
                    completion(shots)
                }
            }
        }
    } else {
        captureAllScreensByFile { shots in
            log("画面を止めた（ファイル経由）\(shots.count)枚 \(ms())ms")
            completion(shots)
        }
    }
}

@available(macOS 14.0, *)
private func captureAllScreensDirect(hide: [Int], completion: @escaping ([(screen: NSScreen, image: CGImage)]) -> Void) {
    // 画面の番号・大きさ・設定は main で先に読んでおく（このあとの処理は別の場所で走る）
    struct Target { let index: Int; let screen: NSScreen; let id: UInt32; let width: Int; let height: Int }
    var targets: [Target] = []
    for (i, screen) in NSScreen.screens.enumerated() {
        guard let num = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { continue }
        targets.append(Target(index: i, screen: screen, id: num,
                              width: Int((screen.frame.width * screen.backingScaleFactor).rounded()),
                              height: Int((screen.frame.height * screen.backingScaleFactor).rounded())))
    }
    let cursor = Prefs.shotCursor
    let started = Date()
    // 画面の一覧は取るのに時間がかかるので、前に取ったものを使い回す（画面のつなぎ方が変わったら取り直す）
    DisplayCache.shared.displays(for: targets.map { $0.id }, hide: hide) { displays, hidden in
        let listed = Int(Date().timeIntervalSince(started) * 1000)
        let group = DispatchGroup()
        let lock = NSLock()
        var found: [(Int, NSScreen, CGImage)] = []
        for target in targets {
            guard let display = displays.first(where: { $0.displayID == target.id }) else { continue }
            let config = SCStreamConfiguration()
            config.width = target.width
            config.height = target.height
            config.showsCursor = cursor
            config.colorSpaceName = CGColorSpace.sRGB
            config.captureResolution = .best
            let filter = SCContentFilter(display: display, excludingWindows: hidden)
            group.enter()
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { image, _ in
                if let image { lock.lock(); found.append((target.index, target.screen, image)); lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            log("画面の一覧 \(listed)ms（外す窓 \(hidden.count)/\(hide.count)）／撮る \(Int(Date().timeIntervalSince(started) * 1000) - listed)ms")
            if found.count != targets.count { DisplayCache.shared.clear() }
            completion(found.sorted { $0.0 < $1.0 }.map { (screen: $0.1, image: $0.2) })
        }
    }
}

/// 止めた絵が届くまでの仮の幕。画面を暗くしてカーソルを十字にするだけ（押してすぐ反応が見えるように）。
/// このあと撮る「止めた絵」には写さない。
final class PendingCrosshair {
    private(set) var panels: [NSPanel] = []

    func show() {
        for screen in NSScreen.screens {
            let panel = KeyablePanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.setFrame(screen.frame, display: false)
            panel.isReleasedWhenClosed = false
            panel.level = .screenSaver
            panel.isOpaque = false
            panel.backgroundColor = NSColor.black.withAlphaComponent(0.3)   // 本物の幕と同じ濃さ。透明に近いとカーソルが十字に変わらない
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.animationBehavior = .none
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.ignoresMouseEvents = false   // 透明な窓でもマウスを受ける
            panel.sharingType = .none          // 止めた絵に写さない（撮るときにも窓を名指しで外す＝二重の備え）
            panel.acceptsMouseMovedEvents = true
            panel.contentView = CrosshairCursorView(frame: NSRect(origin: .zero, size: screen.frame.size))
            panels.append(panel)
        }
        let mouse = NSEvent.mouseLocation
        for panel in panels { panel.orderFrontRegardless() }
        (panels.first { NSMouseInRect(mouse, $0.frame, false) } ?? panels.first)?.makeKey()
        NSCursor.crosshair.set()
    }

    func close() {
        panels.forEach { ($0.contentView as? CrosshairCursorView)?.stop(); $0.orderOut(nil) }
        panels = []
    }
}

final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// 仮の幕の中身。本物の幕と同じ十字の線を、カーソルの位置に描く。
/// 鍵のない窓にはマウスの動きが届かないことがあるので、短い間だけタイマーでカーソルの位置を見に行く。
final class CrosshairCursorView: NSView {
    private var timer: Timer?
    private var last = NSPoint(x: -1, y: -1)

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func viewDidMoveToWindow() {
        timer?.invalidate()
        timer = nil
        guard window != nil, Prefs.showCrosshair else { return }
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = NSEvent.mouseLocation
            if now != self.last { self.last = now; self.needsDisplay = true }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() { timer?.invalidate(); timer = nil }

    override func draw(_ dirtyRect: NSRect) {
        guard Prefs.showCrosshair, let window else { return }
        let mouse = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        guard bounds.contains(mouse) else { return }
        // 本物の幕（ShotSelectionView）と同じ線
        let lines = NSBezierPath()
        lines.move(to: NSPoint(x: 0, y: mouse.y.rounded() + 0.5)); lines.line(to: NSPoint(x: bounds.maxX, y: mouse.y.rounded() + 0.5))
        lines.move(to: NSPoint(x: mouse.x.rounded() + 0.5, y: 0)); lines.line(to: NSPoint(x: mouse.x.rounded() + 0.5, y: bounds.maxY))
        lines.lineWidth = 1
        NSColor.black.withAlphaComponent(0.35).setStroke()
        lines.stroke()
        lines.setLineDash([4, 4], count: 2, phase: 0)
        NSColor.white.withAlphaComponent(0.9).setStroke()
        lines.stroke()
    }
}

/// 画面の一覧（SCDisplay）の使い回し。起動時と、画面のつなぎ方が変わったときに取り直しておく。
@available(macOS 14.0, *)
final class DisplayCache {
    static let shared = DisplayCache()
    private var cached: [SCDisplay] = []
    private let lock = NSLock()

    func clear() { lock.lock(); cached = []; lock.unlock() }

    /// 先に取っておく（main から呼ぶ）
    func warm() {
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { [weak self] content, _ in
            guard let self, let content else { return }
            self.lock.lock(); self.cached = content.displays; self.lock.unlock()
        }
    }

    /// hide が空なら前に取った一覧をそのまま返す。hide があるときは窓を探すために取り直す（20ms ほど）。
    func displays(for ids: [UInt32], hide: [Int], completion: @escaping ([SCDisplay], [SCWindow]) -> Void) {
        lock.lock(); let have = cached; lock.unlock()
        if hide.isEmpty, !ids.isEmpty, ids.allSatisfy({ id in have.contains { $0.displayID == id } }) { completion(have, []); return }
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { [weak self] content, _ in
            let displays = content?.displays ?? []
            if let self { self.lock.lock(); self.cached = displays; self.lock.unlock() }
            completion(displays, (content?.windows ?? []).filter { hide.contains(Int($0.windowID)) })
        }
    }
}

private func captureAllScreensByFile(completion: @escaping ([(screen: NSScreen, image: CGImage)]) -> Void) {
    let screens = NSScreen.screens
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kiritori-freeze-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let group = DispatchGroup()
    var files: [(NSScreen, URL)] = []
    for (i, screen) in screens.enumerated() {
        let file = dir.appendingPathComponent("\(i).png")
        files.append((screen, file))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = (Prefs.shotCursor ? ["-C"] : []) + ["-x", "-D", String(displayIndex(for: screen)), file.path]
        group.enter()
        p.terminationHandler = { _ in group.leave() }
        do { try p.run() } catch { group.leave() }
    }
    group.notify(queue: .main) {
        var result: [(screen: NSScreen, image: CGImage)] = []
        for (screen, file) in files {
            // 画像は使うときに初めてファイルから読まれる。このあとファイルを消すので、ここで全部メモリへ読み切っておく
            if let src = CGImageSourceCreateWithURL(file as CFURL, nil), let lazy = CGImageSourceCreateImageAtIndex(src, 0, nil),
               let ctx = CGContext(data: nil, width: lazy.width, height: lazy.height, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                ctx.draw(lazy, in: CGRect(x: 0, y: 0, width: lazy.width, height: lazy.height))
                if let image = ctx.makeImage() { result.append((screen, image)) }
            }
        }
        try? FileManager.default.removeItem(at: dir)
        completion(result)
    }
}

/// セルフタイマーの数字（画面の真ん中に大きく出して、1秒ずつ減らす）。
final class CountdownHUD {
    private var window: NSWindow?
    private var timer: Timer?

    /// center は全画面を通した AppKit の座標。0 になったら窓を消してから done を呼ぶ。
    func start(seconds: Int, center: NSPoint, done: @escaping () -> Void) {
        let side: CGFloat = 150
        let frame = NSRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
        let w = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.setFrame(frame, display: false)
        w.isReleasedWhenClosed = false
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.level = .screenSaver
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = CountdownView(frame: NSRect(origin: .zero, size: frame.size))
        view.number = seconds
        w.contentView = view
        w.orderFrontRegardless()
        window = w
        var left = seconds
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] timer in
            left -= 1
            if left > 0 {
                view.number = left
            } else {
                timer.invalidate()
                self?.window?.orderOut(nil)
                self?.window = nil
                // 数字の窓が画面から消えるのを待ってから撮る
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: done)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        window?.orderOut(nil)
        window = nil
    }
}

final class CountdownView: NSView {
    var number = 0 { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 6), xRadius: 28, yRadius: 28).fill()
        let label = NSAttributedString(string: String(number), attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 84, weight: .bold), .foregroundColor: NSColor.white,
        ])
        let s = label.size()
        label.draw(at: NSPoint(x: bounds.midX - s.width / 2, y: bounds.midY - s.height / 2))
    }
}
