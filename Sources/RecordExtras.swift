// 録画まわりの部品：クリックの強調・マイクの一覧・カーソル下のウィンドウ探し・GIF への変換。

import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

func isGIF(_ url: URL) -> Bool { url.pathExtension.lowercased() == "gif" }
/// 録画したもの（動画か GIF）。編集はせず、再生・ファイルとしてコピーする扱いにする
func isMotion(_ url: URL) -> Bool { isVideo(url) || isGIF(url) }

// MARK: - クリックの強調

/// 録画中、クリックした場所に輪を出す。輪は録画に写す（StreamRecorder がこの窓だけ例外で写す）。
final class ClickHighlighter {
    private var window: NSWindow?
    private var globalMonitor: Any?
    private var localMonitor: Any?

    var windowID: CGWindowID? { window.map { CGWindowID($0.windowNumber) } }

    func start(on screen: NSScreen) {
        guard window == nil else { return }
        let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.setFrame(screen.frame, display: false)
        w.isReleasedWhenClosed = false
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.level = .screenSaver
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        w.contentView = view
        w.orderFrontRegardless()
        window = w

        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            self?.ping(at: NSEvent.mouseLocation)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.ping(at: NSEvent.mouseLocation)
            return event
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        window?.orderOut(nil)
        window = nil
    }

    static let colors: [(name: String, key: String)] = [("黄", "yellow"), ("赤", "red"), ("青", "blue"), ("緑", "green"), ("白", "white")]
    static func color(_ key: String) -> NSColor {
        switch key {
        case "red": return NSColor(srgbRed: 1.0, green: 0.27, blue: 0.23, alpha: 1)
        case "blue": return NSColor(srgbRed: 0.20, green: 0.56, blue: 1.0, alpha: 1)
        case "green": return NSColor(srgbRed: 0.22, green: 0.82, blue: 0.40, alpha: 1)
        case "white": return NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        default: return NSColor(srgbRed: 1.0, green: 0.76, blue: 0.0, alpha: 1)
        }
    }

    /// global は AppKit の全画面を通した座標
    func ping(at global: NSPoint) {
        guard let window, let layer = window.contentView?.layer, NSMouseInRect(global, window.frame, false) else { return }
        let p = CGPoint(x: global.x - window.frame.minX, y: global.y - window.frame.minY)
        let ring = CAShapeLayer()
        let r: CGFloat = [14, 20, 28][Prefs.clickSize]
        let base = Self.color(Prefs.clickColor)
        ring.path = CGPath(ellipseIn: CGRect(x: -r, y: -r, width: r * 2, height: r * 2), transform: nil)
        ring.position = p
        ring.fillColor = base.withAlphaComponent(0.38).cgColor
        ring.strokeColor = base.withAlphaComponent(0.95).cgColor
        ring.lineWidth = 2.5
        layer.addSublayer(ring)

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.55
        scale.toValue = 1.5
        // 前半ははっきり見せて、後半で消す（すぐ薄くなると動画で見落とすため）
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [1.0, 1.0, 0.0]
        fade.keyTimes = [0, 0.5, 1]
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 0.6
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.isRemovedOnCompletion = false
        group.fillMode = .forwards
        CATransaction.begin()
        CATransaction.setCompletionBlock { ring.removeFromSuperlayer() }
        ring.add(group, forKey: "ping")
        CATransaction.commit()
    }
}

// MARK: - マイク

struct MicrophoneChoice {
    static let none = "none"         // 入れない
    static let system = "system"     // macOS の「サウンド」で選んである入力
}

func audioInputDevices() -> [AVCaptureDevice] {
    let types: [AVCaptureDevice.DeviceType]
    if #available(macOS 14.0, *) {
        types = [.microphone, .external]
    } else {
        types = [.builtInMicrophone, .externalUnknown]
    }
    return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .audio, position: .unspecified).devices
}

// MARK: - カーソルの下のウィンドウ

/// AppKit の全画面を通した座標 point の下にある、いちばん手前のウィンドウの枠（AppKit の座標）。
func windowFrame(under point: NSPoint) -> NSRect? {
    guard let primaryHeight = NSScreen.screens.first?.frame.height else { return nil }
    let cgPoint = CGPoint(x: point.x, y: primaryHeight - point.y)
    let myPID = ProcessInfo.processInfo.processIdentifier
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    for info in list {   // 手前から順に並んでいる
        guard (info[kCGWindowLayer as String] as? Int) == 0,
              (info[kCGWindowOwnerPID as String] as? Int32) != myPID,
              ((info[kCGWindowAlpha as String] as? Double) ?? 1) > 0.05,
              let b = info[kCGWindowBounds as String] as? [String: CGFloat],
              let x = b["X"], let y = b["Y"], let w = b["Width"], let h = b["Height"], w >= 60, h >= 40 else { continue }
        let cgRect = CGRect(x: x, y: y, width: w, height: h)
        if cgRect.contains(cgPoint) {
            return NSRect(x: x, y: primaryHeight - y - h, width: w, height: h)
        }
    }
    return nil
}

// MARK: - GIF

/// 動画を GIF に作り替える。できたら main で GIF の場所を返す（失敗したら nil）。
func makeGIF(from video: URL, fps: Double = 15, completion: @escaping (URL?) -> Void) {
    DispatchQueue.global(qos: .userInitiated).async {
        let asset = AVURLAsset(url: video)
        let duration = CMTimeGetSeconds(asset.duration)
        let pixelWidth = videoInfo(video).map { CGFloat($0.width) } ?? 960
        // 録画は画面の2倍の細かさなので、半分にして、横は 1000 まで
        let target = min(1000, max(320, pixelWidth / 2))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: target, height: target * 4)
        let tolerance = CMTime(seconds: 0.5 / fps, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        let count = max(1, Int((duration * fps).rounded(.down)))
        let out = video.deletingPathExtension().appendingPathExtension("gif")
        guard duration.isFinite,
              let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.gif.identifier as CFString, count, nil) else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / fps,
                                                           kCGImagePropertyGIFUnclampedDelayTime: 1.0 / fps]] as CFDictionary
        var added = 0
        for i in 0..<count {
            let time = CMTime(seconds: Double(i) / fps, preferredTimescale: 600)
            if let cg = try? generator.copyCGImage(at: time, actualTime: nil) {
                CGImageDestinationAddImage(dest, cg, frameProps)
                added += 1
            }
        }
        let ok = added > 0 && CGImageDestinationFinalize(dest)
        DispatchQueue.main.async {
            log("GIF に変換 コマ=\(added)/\(count) 成功=\(ok)")
            if !ok { try? FileManager.default.removeItem(at: out) }
            completion(ok ? out : nil)
        }
    }
}

// MARK: - キー表示

/// 録画中に押したキーを画面の下に出す（⌘⇧4 のような操作を見せるため）。録画に写す。
/// ほかのアプリで押したキーを知るには、macOS の「入力監視」の許可が要る。
final class KeystrokeOverlay {
    private var window: NSWindow?
    private var view: KeyCapView?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var hide: DispatchWorkItem?

    var windowID: CGWindowID? { window.map { CGWindowID($0.windowNumber) } }

    static var hasPermission: Bool { CGPreflightListenEventAccess() }
    /// 動作確認用：許可を見ず、キーの監視もせずに、表示の窓だけ出す
    static var testWithoutMonitor = false

    /// rect は録画する範囲（AppKit の全画面を通した座標）。その下寄りに出す。
    func start(in rect: NSRect) {
        guard window == nil, Self.hasPermission || Self.testWithoutMonitor else { return }
        let fontSize: CGFloat = [18, 24, 32][Prefs.keySize]
        let size = NSSize(width: min(520 * fontSize / 24, rect.width - 24), height: fontSize * 2.5)
        let gap = max(18, min(60, rect.height * 0.08))
        let y = Prefs.keyPosition == "top" ? rect.maxY - gap - size.height : rect.minY + gap
        let frame = NSRect(x: rect.midX - size.width / 2, y: y, width: size.width, height: size.height)
        let w = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.setFrame(frame, display: false)
        w.isReleasedWhenClosed = false
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.level = .screenSaver
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let v = KeyCapView(frame: NSRect(origin: .zero, size: size))
        v.fontSize = fontSize
        w.contentView = v
        w.orderFrontRegardless()
        window = w
        view = v

        if Self.testWithoutMonitor { return }
        // 見るだけの監視（キー入力を止めたり変えたりはしない）
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            if type == .keyDown, let refcon, let ns = NSEvent(cgEvent: event) {
                let me = Unmanaged<KeystrokeOverlay>.fromOpaque(refcon).takeUnretainedValue()
                DispatchQueue.main.async { me.show(ns) }
            }
            return Unmanaged.passUnretained(event)
        }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                           eventsOfInterest: mask, callback: callback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            log("キー表示: 監視を始められない（入力監視の許可がない）")
            return
        }
        tap = port
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        source = src
        CGEvent.tapEnable(tap: port, enable: true)
    }

    func stop() {
        hide?.cancel()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        window?.orderOut(nil)
        window = nil
        view = nil
    }

    func show(_ event: NSEvent) {
        guard let text = Self.describe(event, all: Prefs.keystrokesAll) else { return }
        show(text: text)
    }

    func show(text: String) {
        view?.text = text
        hide?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.view?.text = "" }
        hide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
    }

    /// 「⌘ ⇧ 4」のような表示にする。all が false のときは ⌘・⌃・⌥ を使った操作だけ（打った文章や合言葉を写さないため）。
    static func describe(_ event: NSEvent, all: Bool) -> String? {
        let flags = event.modifierFlags
        let hasCommandKey = !flags.intersection([.command, .control, .option]).isEmpty
        guard all || hasCommandKey else { return nil }
        var parts: [String] = []
        if flags.contains(.control) { parts.append("⌃") }
        if flags.contains(.option) { parts.append("⌥") }
        if flags.contains(.shift) { parts.append("⇧") }
        if flags.contains(.command) { parts.append("⌘") }
        let special: [UInt16: String] = [36: "↩", 76: "↩", 48: "⇥", 49: "Space", 51: "⌫", 117: "⌦", 53: "esc",
                                         123: "←", 124: "→", 125: "↓", 126: "↑", 116: "PageUp", 121: "PageDown", 115: "Home", 119: "End",
                                         122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"]
        if let name = special[event.keyCode] {
            parts.append(name)
        } else if let ch = event.charactersIgnoringModifiers, !ch.isEmpty, ch.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value < 0xF700 }) {
            parts.append(ch.uppercased())
        } else {
            return nil
        }
        return parts.joined(separator: " ")
    }
}

final class KeyCapView: NSView {
    var text = "" { didSet { needsDisplay = true } }
    var fontSize: CGFloat = 24
    override func draw(_ dirtyRect: NSRect) {
        guard !text.isEmpty else { return }
        let label = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold), .foregroundColor: NSColor.white, .kern: 1.5,
        ])
        let s = label.size()
        let k = fontSize / 24
        let pill = NSRect(x: bounds.midX - s.width / 2 - 22 * k, y: bounds.midY - s.height / 2 - 9 * k, width: s.width + 44 * k, height: s.height + 18 * k)
        NSColor.black.withAlphaComponent(0.78).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 14 * k, yRadius: 14 * k).fill()
        label.draw(at: NSPoint(x: pill.minX + 22 * k, y: pill.minY + 9 * k))
    }
}

// MARK: - カメラ

/// 録画に自分の顔を丸く重ねる。録画に写す。録画中にドラッグで動かせる。
final class CameraOverlay {
    private var window: NSWindow?
    private var session: AVCaptureSession?
    private let queue = DispatchQueue(label: "local.kiritori.camera")

    var windowID: CGWindowID? { window.map { CGWindowID($0.windowNumber) } }

    /// rect は録画する範囲（AppKit の全画面を通した座標）。その左下に出す。カメラの許可が無ければ何もしない。
    func start(in rect: NSRect) {
        guard window == nil, AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
              let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device) else {
            log("カメラ: 使えない（許可がないか、カメラが見つからない）")
            return
        }
        let s = AVCaptureSession()
        guard s.canAddInput(input) else { return }
        s.addInput(input)

        let ratio: CGFloat = [0.18, 0.26, 0.36][Prefs.cameraSize]
        let cap: CGFloat = [150, 220, 320][Prefs.cameraSize]
        let side = min(cap, max(90, min(rect.width, rect.height) * ratio)).rounded()
        let corner = Prefs.cameraCorner
        let frame = NSRect(x: corner.hasSuffix("r") ? rect.maxX - 24 - side : rect.minX + 24,
                           y: corner.hasPrefix("t") ? rect.maxY - 24 - side : rect.minY + 24, width: side, height: side)
        let w = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.setFrame(frame, display: false)
        w.isReleasedWhenClosed = false
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.isMovableByWindowBackground = true
        w.level = .screenSaver
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        let preview = AVCaptureVideoPreviewLayer(session: s)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        preview.cornerRadius = Prefs.cameraShape == "rounded" ? side * 0.14 : side / 2
        preview.masksToBounds = true
        preview.borderWidth = 3
        preview.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
        preview.backgroundColor = NSColor.black.cgColor
        if let connection = preview.connection, connection.isVideoMirroringSupported {   // 鏡のように左右を反転する
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = Prefs.cameraMirror
        }
        view.layer?.addSublayer(preview)
        w.contentView = view
        w.orderFrontRegardless()
        window = w
        session = s
        queue.async { s.startRunning() }
    }

    func stop() {
        if let s = session { queue.async { s.stopRunning() } }
        session = nil
        window?.orderOut(nil)
        window = nil
    }
}

/// 録画中のメニューバーの印：赤い停止の丸と、マイクが入っていれば音量の小さな棒。一時停止中は丸が橙になる。
func recordingIndicatorImage(micLevel: CGFloat?, paused: Bool = false) -> NSImage {
    let stop = tintedSymbol("stop.circle.fill", pointSize: 15, color: paused ? .systemOrange : .systemRed) ?? NSImage()
    let meterWidth: CGFloat = micLevel == nil ? 0 : 9
    let size = NSSize(width: stop.size.width + meterWidth, height: max(18, stop.size.height))
    return NSImage(size: size, flipped: false) { _ in
        stop.draw(in: NSRect(x: 0, y: (size.height - stop.size.height) / 2, width: stop.size.width, height: stop.size.height))
        if let micLevel {
            let track = NSRect(x: stop.size.width + 4, y: (size.height - 13) / 2, width: 4, height: 13)
            NSColor.gray.withAlphaComponent(0.45).setFill()
            NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
            let h = max(1.5, track.height * min(1, micLevel))
            NSColor(srgbRed: 0.25, green: 0.85, blue: 0.45, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY, width: track.width, height: h), xRadius: 2, yRadius: 2).fill()
        }
        return true
    }
}

// MARK: - 範囲の外を暗くする

/// 録画中、録る範囲の外を薄暗くして、どこを録っているかを分かりやすくする。自分の窓なので録画には写らない。
final class DimOverlay {
    private var windows: [NSWindow] = []

    final class HoleView: NSView {
        /// くり抜く場所（この view の座標）
        var hole = NSRect.zero
        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath(rect: bounds)
            path.append(NSBezierPath(roundedRect: hole, xRadius: 4, yRadius: 4))
            path.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.42).setFill()
            path.fill()
        }
    }

    /// rect は AppKit の全画面を通した座標
    func show(around rect: NSRect) {
        hide()
        for screen in NSScreen.screens {
            let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.setFrame(screen.frame, display: false)
            w.isReleasedWhenClosed = false
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.ignoresMouseEvents = true
            w.level = .statusBar
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            let view = HoleView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.hole = rect.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
            w.contentView = view
            w.orderFrontRegardless()
            windows.append(w)
        }
    }

    func hide() {
        windows.forEach { $0.orderOut(nil) }
        windows = []
    }
}

// MARK: - おやすみモード

/// 録画の間だけ、おやすみモード（集中モード）にする。
/// macOS にはアプリから切り替える公開の方法が無いので、「ショートカット」アプリに用意した2つを呼ぶ。
enum FocusSwitch {
    static let onName = "Kiritori おやすみオン"
    static let offName = "Kiritori おやすみオフ"
    private static let tool = "/usr/bin/shortcuts"

    /// 用意してあるショートカットの名前（調べられなければ nil）
    static func installed() -> Set<String>? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = ["list"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else { return nil }
        return Set(text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
    }

    /// 2つとも用意してあるか
    static var isReady: Bool {
        guard let names = installed() else { return false }
        return names.contains(onName) && names.contains(offName)
    }

    static func set(_ on: Bool) {
        let name = on ? onName : offName
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = ["run", name]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { log("おやすみモード: ショートカットを呼べない"); return }
            p.waitUntilExit()
            log("おやすみモード \(on ? "入" : "切") ショートカット「\(name)」 exit=\(p.terminationStatus)")
        }
    }
}
