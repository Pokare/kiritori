// ピン留め（撮った画像を画面のいちばん手前に浮かべておく）と、文字認識（画像の中の文字を読み取ってコピーする）。

import AppKit
import Vision

// MARK: - ピン留め

final class PinView: NSView {
    var image: NSImage
    var hovering = false { didSet { needsDisplay = true } }
    var onClose: (() -> Void)?
    var onMenu: ((NSEvent) -> Void)?

    init(frame: NSRect, image: NSImage) {
        self.image = image
        super.init(frame: frame)
        toolTip = "ドラッグで移動。ホイールで大きさ、option＋ホイールで濃さ。右クリックでメニュー"
    }
    required init?(coder: NSCoder) { fatalError() }

    private var closeRect: NSRect { NSRect(x: 6, y: bounds.maxY - 28, width: 22, height: 22) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let edge = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        edge.lineWidth = 1
        (hovering ? NSColor.controlAccentColor : NSColor.black.withAlphaComponent(0.25)).setStroke()
        edge.stroke()
        if hovering {   // 閉じるボタン
            let r = closeRect
            NSColor.black.withAlphaComponent(0.7).setFill()
            NSBezierPath(ovalIn: r).fill()
            let x = NSBezierPath()
            x.move(to: NSPoint(x: r.minX + 7, y: r.minY + 7)); x.line(to: NSPoint(x: r.maxX - 7, y: r.maxY - 7))
            x.move(to: NSPoint(x: r.minX + 7, y: r.maxY - 7)); x.line(to: NSPoint(x: r.maxX - 7, y: r.minY + 7))
            x.lineWidth = 1.6
            x.lineCapStyle = .round
            NSColor.white.setStroke()
            x.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if closeRect.contains(p) { onClose?(); return }
        window?.makeKey()
        window?.performDrag(with: event)
    }

    override func rightMouseDown(with event: NSEvent) { onMenu?(event) }
}

final class PinPanel: NSPanel {
    let fileURL: URL
    /// 等倍のときの大きさ（ポイント）
    let naturalSize: NSSize
    private(set) var zoom: CGFloat = 1
    private(set) var isLocked = false

    init(fileURL: URL, image: NSImage, naturalSize: NSSize, origin: NSPoint, zoom: CGFloat) {
        self.fileURL = fileURL
        self.naturalSize = naturalSize
        self.zoom = zoom
        let size = NSSize(width: naturalSize.width * zoom, height: naturalSize.height * zoom)
        super.init(contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        level = .floating
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = PinView(frame: NSRect(origin: .zero, size: size), image: image)
        view.autoresizingMask = [.width, .height]
        view.onClose = { [weak self] in self.map { PinController.shared.close($0) } }
        view.onMenu = { [weak self] event in self?.showMenu(with: event) }
        contentView = view
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// 真ん中を動かさずに大きさを変える
    func setZoom(_ z: CGFloat) {
        zoom = max(0.2, min(4, z))
        let size = NSSize(width: (naturalSize.width * zoom).rounded(), height: (naturalSize.height * zoom).rounded())
        let c = NSPoint(x: frame.midX, y: frame.midY)
        setFrame(NSRect(x: (c.x - size.width / 2).rounded(), y: (c.y - size.height / 2).rounded(), width: size.width, height: size.height), display: true)
    }

    func setOpacity(_ a: CGFloat) { alphaValue = max(0.15, min(1, a)) }

    /// ロック：クリックを下のアプリへ通す（見ながら下で作業するため）。外すのはメニューバーから。
    func setLocked(_ locked: Bool) {
        isLocked = locked
        ignoresMouseEvents = locked
        (contentView as? PinView)?.hovering = false
    }

    override func scrollWheel(with event: NSEvent) {
        let d = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.004 : 0.04)
        guard d != 0 else { return }
        if event.modifierFlags.contains(.option) { setOpacity(alphaValue + d) } else { setZoom(zoom * (1 + d)) }
    }

    override func keyDown(with event: NSEvent) {
        let cmd = event.modifierFlags.contains(.command)
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        switch event.keyCode {
        case 53: PinController.shared.close(self)                                   // esc
        case 123: setFrameOrigin(NSPoint(x: frame.minX - step, y: frame.minY))      // ←
        case 124: setFrameOrigin(NSPoint(x: frame.minX + step, y: frame.minY))      // →
        case 125: setFrameOrigin(NSPoint(x: frame.minX, y: frame.minY - step))      // ↓
        case 126: setFrameOrigin(NSPoint(x: frame.minX, y: frame.minY + step))      // ↑
        case 24, 69: setZoom(zoom * 1.1)                                            // ＋
        case 27, 78: setZoom(zoom / 1.1)                                            // −
        case 29: setZoom(1)                                                         // 0＝等倍
        case 33: setOpacity(alphaValue - 0.1)                                       // [
        case 30: setOpacity(alphaValue + 0.1)                                       // ]
        case 37: setLocked(true)                                                    // L
        case 8 where cmd: copyImageToPasteboard(fileURL)                            // ⌘C
        case 1 where cmd: saveToFolder(fileURL)                                     // ⌘S
        case 13 where cmd: PinController.shared.close(self)                         // ⌘W
        default: super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, event.modifierFlags.contains(.command), [8, 1, 13].contains(event.keyCode) {
            keyDown(with: event)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private func showMenu(with event: NSEvent) {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector, tag: Int = 0, on: Bool = false) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.tag = tag
            item.state = on ? .on : .off
            menu.addItem(item)
        }
        add("コピー", #selector(menuCopy))
        add("保存", #selector(menuSave))
        menu.addItem(.separator())
        for pct in [50, 100, 150, 200] { add("大きさ \(pct)%", #selector(menuZoom(_:)), tag: pct, on: Int((zoom * 100).rounded()) == pct) }
        menu.addItem(.separator())
        for pct in [100, 75, 50, 25] { add("濃さ \(pct)%", #selector(menuOpacity(_:)), tag: pct, on: Int((alphaValue * 100).rounded()) == pct) }
        menu.addItem(.separator())
        add("ロック（クリックを下へ通す）", #selector(menuLock))
        add("閉じる", #selector(menuClose))
        if let view = contentView { NSMenu.popUpContextMenu(menu, with: event, for: view) }
    }

    @objc private func menuCopy() { copyImageToPasteboard(fileURL) }
    @objc private func menuSave() { saveToFolder(fileURL) }
    @objc private func menuZoom(_ sender: NSMenuItem) { setZoom(CGFloat(sender.tag) / 100) }
    @objc private func menuOpacity(_ sender: NSMenuItem) { setOpacity(CGFloat(sender.tag) / 100) }
    @objc private func menuLock() { setLocked(true) }
    @objc private func menuClose() { PinController.shared.close(self) }
}

final class PinController {
    static let shared = PinController()
    private(set) var pins: [PinPanel] = []

    var hasLocked: Bool { pins.contains { $0.isLocked } }

    /// 画像を画面に留める。rect（撮った場所）が分かっていれば、その場所へぴったり重ねる。
    @discardableResult
    func pin(file: URL, at rect: NSRect? = nil) -> PinPanel? {
        guard !isMotion(file), let data = try? Data(contentsOf: file), let image = NSImage(data: data),
              let (pw, ph) = pixelSize(of: file) else {
            NSSound.beep()
            return nil
        }
        // 画像に記録された細かさ（144dpi＝画面の2倍）から、画面上の等倍の大きさを出す
        let src = CGImageSourceCreateWithData(data as CFData, nil)
        let props = src.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
        let dpi = (props?[kCGImagePropertyDPIWidth] as? CGFloat) ?? 72
        let scale = max(1, dpi / 72)
        let natural = NSSize(width: CGFloat(pw) / scale, height: CGFloat(ph) / scale)

        let screen = rect.flatMap { r in NSScreen.screens.first { $0.frame.intersects(r) } } ?? screenUnderMouse()
        let vf = screen.visibleFrame
        var zoom: CGFloat = 1
        var origin: NSPoint
        if let rect {
            // 撮った場所の左上に合わせる（編集で切り抜いて大きさが変わっていても、左上はそろえる）
            origin = NSPoint(x: rect.minX, y: rect.maxY - natural.height)
        } else {
            // 画面に収まらない大きさなら縮めて、真ん中へ
            zoom = min(1, vf.width * 0.8 / natural.width, vf.height * 0.8 / natural.height)
            origin = NSPoint(x: vf.midX - natural.width * zoom / 2, y: vf.midY - natural.height * zoom / 2)
        }
        origin = NSPoint(x: origin.x.rounded(), y: origin.y.rounded())
        let panel = PinPanel(fileURL: file, image: image, naturalSize: natural, origin: origin, zoom: zoom)
        pins.append(panel)
        panel.orderFrontRegardless()
        log("ピン留め \(file.lastPathComponent) \(Int(natural.width))x\(Int(natural.height)) 場所=\(rect == nil ? "真ん中" : "撮った場所")")
        return panel
    }

    func close(_ panel: PinPanel) {
        pins.removeAll { $0 === panel }
        panel.orderOut(nil)
    }

    func closeAll() {
        pins.forEach { $0.orderOut(nil) }
        pins = []
    }

    func unlockAll() { pins.forEach { $0.setLocked(false) } }
}

// MARK: - 文字認識

enum TextReader {
    /// 画像の中の文字（日本語・英語）と QR コードを読み取る。終わったら main で返す。
    static func read(_ image: CGImage, completion: @escaping (_ text: String, _ codes: [String]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let textRequest = VNRecognizeTextRequest()
            textRequest.recognitionLevel = .accurate
            textRequest.recognitionLanguages = ["ja-JP", "en-US"]
            textRequest.usesLanguageCorrection = true
            let codeRequest = VNDetectBarcodesRequest()
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([textRequest, codeRequest])
            } catch {
                log("文字認識に失敗 \(error)")
            }
            // 上から下、同じ高さなら左から右の順に並べる
            // QR コードの模様を文字と読み違えることがあるので、コードに重なっている所の文字は捨てる
            let codeBoxes = (codeRequest.results ?? []).map { $0.boundingBox.insetBy(dx: -0.01, dy: -0.01) }
            let lines = (textRequest.results ?? []).compactMap { obs -> (CGRect, String)? in
                guard let top = obs.topCandidates(1).first else { return nil }
                let box = obs.boundingBox
                let area = max(box.width * box.height, 0.000001)
                for code in codeBoxes {
                    let overlap = box.intersection(code)
                    if !overlap.isNull, overlap.width * overlap.height / area > 0.5 { return nil }
                }
                return (box, top.string)
            }.sorted { a, b in
                if abs(a.0.midY - b.0.midY) > min(a.0.height, b.0.height) * 0.6 { return a.0.midY > b.0.midY }
                return a.0.minX < b.0.minX
            }
            // 同じ高さに並んだものは1行にまとめる
            var rows: [(y: CGFloat, h: CGFloat, parts: [String])] = []
            for (box, text) in lines {
                if let last = rows.last, abs(last.y - box.midY) <= min(last.h, box.height) * 0.6 {
                    rows[rows.count - 1].parts.append(text)
                } else {
                    rows.append((box.midY, box.height, [text]))
                }
            }
            let text = rows.map { $0.parts.joined(separator: " ") }.joined(separator: "\n")
            let codes = (codeRequest.results ?? []).compactMap { $0.payloadStringValue }
            DispatchQueue.main.async { completion(text, codes) }
        }
    }

    static func read(file: URL, completion: @escaping (_ text: String, _ codes: [String]) -> Void) {
        guard let src = CGImageSourceCreateWithURL(file as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            completion("", [])
            return
        }
        read(image, completion: completion)
    }

    /// 読み取った結果をクリップボードへ入れて、画面に知らせる。
    static func copyResult(text: String, codes: [String]) {
        var all = text
        for code in codes where !all.contains(code) { all += (all.isEmpty ? "" : "\n") + code }
        guard !all.isEmpty else {
            log("文字認識: 文字が見つからない")
            ToastHUD.show("文字が見つかりませんでした", detail: nil)
            NSSound.beep()
            return
        }
        pasteboardForCopy.clearContents()
        pasteboardForCopy.setString(all, forType: .string)
        log("文字認識: \(all.count)文字をコピー（QR \(codes.count)件）")
        let firstLine = all.split(separator: "\n").first.map(String.init) ?? ""
        ToastHUD.show("文字をコピーしました（\(all.count)文字\(codes.isEmpty ? "" : "・QRコードあり")）", detail: firstLine)
    }
}

/// 画面の下に少しのあいだ出る知らせ
enum ToastHUD {
    private static var window: NSWindow?
    private static var hide: DispatchWorkItem?

    static func show(_ title: String, detail: String?) {
        hide?.cancel()
        window?.orderOut(nil)
        let view = ToastView(title: title, detail: detail)
        let size = view.fitting
        let vf = screenUnderMouse().visibleFrame
        let frame = NSRect(x: vf.midX - size.width / 2, y: vf.minY + 90, width: size.width, height: size.height)
        let w = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.setFrame(frame, display: false)
        w.isReleasedWhenClosed = false
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.ignoresMouseEvents = true
        w.level = .statusBar
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        view.frame = NSRect(origin: .zero, size: size)
        w.contentView = view
        w.alphaValue = 0
        w.orderFrontRegardless()
        w.animator().alphaValue = 1
        window = w
        let work = DispatchWorkItem {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                w.animator().alphaValue = 0
            }, completionHandler: { w.orderOut(nil) })
        }
        hide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4, execute: work)
    }
}

final class ToastView: NSView {
    private let title: NSAttributedString
    private let detail: NSAttributedString?

    init(title: String, detail: String?) {
        self.title = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 14, weight: .semibold), .foregroundColor: NSColor.white])
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        self.detail = detail.flatMap { $0.isEmpty ? nil : $0 }.map {
            NSAttributedString(string: $0, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.white.withAlphaComponent(0.7), .paragraphStyle: para])
        }
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    var fitting: NSSize {
        let w = min(520, max(title.size().width, min(480, detail?.size().width ?? 0)) + 44)
        return NSSize(width: w, height: detail == nil ? 44 : 64)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 0.95).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14).fill()
        let ts = title.size()
        title.draw(at: NSPoint(x: 22, y: detail == nil ? bounds.midY - ts.height / 2 : bounds.maxY - ts.height - 12))
        detail?.draw(in: NSRect(x: 22, y: 11, width: bounds.width - 44, height: 18))
    }
}
