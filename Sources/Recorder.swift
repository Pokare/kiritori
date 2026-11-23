// 画面録画。
// 録画そのものは macOS 標準の /usr/sbin/screencapture -v に任せ、
// 範囲選び・開始と停止・メニューバーの経過表示・mp4 への変換を受け持つ。

import AppKit
import AVFoundation
import Carbon.HIToolbox

// MARK: - 動画の小道具

func isVideo(_ url: URL) -> Bool {
    ["mov", "mp4", "m4v"].contains(url.pathExtension.lowercased())
}

/// 動画の最初のコマ
func videoPoster(_ url: URL, maxPixel: CGFloat = 640) -> NSImage? {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
    guard let cg = try? generator.copyCGImage(at: CMTime(seconds: 0, preferredTimescale: 600), actualTime: nil) else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
}

func videoInfo(_ url: URL) -> (seconds: Double, width: Int, height: Int)? {
    let asset = AVURLAsset(url: url)
    let seconds = CMTimeGetSeconds(asset.duration)
    guard seconds.isFinite, let track = asset.tracks(withMediaType: .video).first else { return nil }
    let size = track.naturalSize.applying(track.preferredTransform)
    return (seconds, Int(abs(size.width)), Int(abs(size.height)))
}

func clockText(_ seconds: Double) -> String {
    let t = max(0, Int(seconds.rounded()))
    return String(format: "%d:%02d", t / 60, t % 60)
}

/// サムネイルの左下に出す「▶ 0:12」
func drawVideoBadge(_ text: String, in rect: NSRect) {
    let label = NSAttributedString(string: "▶ " + text, attributes: [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
        .foregroundColor: NSColor.white,
    ])
    let size = label.size()
    let pill = NSRect(x: rect.minX + 6, y: rect.minY + 6, width: size.width + 14, height: size.height + 6)
    NSColor.black.withAlphaComponent(0.68).setFill()
    NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
    label.draw(at: NSPoint(x: pill.minX + 7, y: pill.minY + 3))
}

// MARK: - 録画する範囲を選ぶ

/// マイクの音量を測る（録画を始める前に、音が入っているかを目で確かめるため）。
final class MicMeter: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private var session: AVCaptureSession?
    private let queue = DispatchQueue(label: "local.kiritori.micmeter")
    private var lastSent = Date.distantPast
    /// 0〜1 の音量。main で呼ばれる
    var onLevel: ((CGFloat) -> Void)?

    /// choice は MicrophoneChoice.system かマイクの固有の名前。許可がまだなら何もしない（許可は切り替えボタンで求める）。
    func start(choice: String) {
        stop()
        guard choice != MicrophoneChoice.none, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        let device = choice == MicrophoneChoice.system ? AVCaptureDevice.default(for: .audio) : AVCaptureDevice(uniqueID: choice)
        guard let device, let input = try? AVCaptureDeviceInput(device: device) else { return }
        let s = AVCaptureSession()
        let output = AVCaptureAudioDataOutput()
        guard s.canAddInput(input), s.canAddOutput(output) else { return }
        s.addInput(input)
        s.addOutput(output)
        output.setSampleBufferDelegate(self, queue: queue)
        session = s
        queue.async { s.startRunning() }
    }

    func stop() {
        guard let s = session else { return }
        session = nil
        queue.async { s.stopRunning() }
        DispatchQueue.main.async { self.onLevel?(0) }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard Date().timeIntervalSince(lastSent) > 0.05 else { return }   // 画面の更新は1秒に20回まで
        lastSent = Date()
        let db = connection.audioChannels.map { $0.averagePowerLevel }.max() ?? -100   // 0 が最大、小さいほど静か
        let level = CGFloat(max(0, min(1, (db + 55) / 50)))
        DispatchQueue.main.async { self.onLevel?(level) }
    }
}

/// 帯に並べる切り替えボタン。入っていると明るく、マイクは音量に合わせて下から緑が伸びる。
final class BarToggle: NSButton {
    var isOn = false { didSet { needsDisplay = true } }
    /// 0〜1。マイクのボタンだけ使う
    var level: CGFloat = 0 { didSet { if abs(oldValue - level) > 0.01 { needsDisplay = true } } }
    private var hovering = false { didSet { needsDisplay = true } }
    private let onSymbol: String
    private let offSymbol: String
    private let caption: String

    init(onSymbol: String, offSymbol: String, caption: String, width: CGFloat, target: AnyObject, action: Selector) {
        self.onSymbol = onSymbol
        self.offSymbol = offSymbol
        self.caption = caption
        super.init(frame: .zero)
        self.target = target
        self.action = action
        title = ""
        isBordered = false
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: width).isActive = true
        heightAnchor.constraint(equalToConstant: 44).isActive = true
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
        NSColor.white.withAlphaComponent(isOn ? (hovering ? 0.22 : 0.16) : (hovering ? 0.09 : 0.0)).setFill()
        shape.fill()
        if isOn, level > 0.01 {
            // NSButton は上が原点なので、下から伸ばすには y を下端から引く
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            let h = (bounds.height - 2) * min(1, level)
            NSColor(srgbRed: 0.25, green: 0.85, blue: 0.45, alpha: 0.75).setFill()
            NSRect(x: 0, y: bounds.maxY - 1 - h, width: bounds.width, height: h).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        let fg = NSColor.white.withAlphaComponent(isOn ? 1.0 : 0.42)
        let hasCaption = !caption.isEmpty
        if let icon = tintedSymbol(isOn ? onSymbol : offSymbol, pointSize: hasCaption ? 14 : 10, color: fg) {
            let y = hasCaption ? bounds.midY - icon.size.height / 2 - 7 : bounds.midY - icon.size.height / 2
            icon.draw(in: NSRect(x: bounds.midX - icon.size.width / 2, y: y, width: icon.size.width, height: icon.size.height),
                      from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        if hasCaption {
            let label = NSAttributedString(string: caption, attributes: [.font: NSFont.systemFont(ofSize: 9.5, weight: .medium), .foregroundColor: fg])
            let size = label.size()
            label.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.height - size.height - 4))
        }
    }
}

/// 帯に置く、幅・高さの数字の欄。
final class SizeField: NSTextField {
    init(target: AnyObject, action: Selector) {
        super.init(frame: .zero)
        self.target = target
        self.action = action
        isBordered = false
        isBezeled = false
        drawsBackground = true
        backgroundColor = NSColor.white.withAlphaComponent(0.12)
        textColor = .white
        alignment = .center
        focusRingType = .none
        font = .monospacedDigitSystemFont(ofSize: 12.5, weight: .medium)
        let f = NumberFormatter()
        f.numberStyle = .none
        f.minimum = 1
        f.maximum = 99999
        f.allowsFloats = false
        formatter = f
        cell?.usesSingleLineMode = true
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 52).isActive = true
        heightAnchor.constraint(equalToConstant: 20).isActive = true
        toolTip = "数字を打って return で、その大きさになります"
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// 範囲選びの下に出る操作の帯（大きさ・録画の設定・画面全体・やめる・録画開始）。
/// 範囲選びの幕の使い方。record＝録画の範囲選び、allInOne＝撮り方をあとから選ぶ
enum SelectorMode { case record, allInOne }
/// オールインワンで選べる操作（録画は帯を録画用に切り替えるので、ここには入らない）
enum SelectorAction { case shot, scroll, timer, ocr }

final class SelectionBar: NSView {
    /// 録画のときだけ出す部品と、オールインワンのときだけ出す部品
    private(set) var recordViews: [NSView] = []
    private(set) var allInOneViews: [NSView] = []
    let label = NSTextField(labelWithString: "")
    private(set) var widthField: SizeField!
    private(set) var heightField: SizeField!
    private(set) var sizeBox: NSStackView!
    private(set) var keysButton: BarToggle!
    private(set) var cameraButton: BarToggle!
    private(set) var micButton: BarToggle!
    private(set) var micMenuButton: BarToggle!
    private(set) var audioButton: BarToggle!
    private(set) var clicksButton: BarToggle!
    private(set) var cursorButton: BarToggle!
    private(set) var videoButton: PillButton!
    private(set) var gifButton: PillButton!
    private let stack = NSStackView()

    init(target: AnyObject, size: Selector, mic: Selector, micMenu: Selector, audio: Selector, clicks: Selector, cursor: Selector,
         keys: Selector, camera: Selector, full: Selector, cancel: Selector, video: Selector, gif: Selector,
         shot: Selector, scroll: Selector, timer: Selector, ocr: Selector, record: Selector) {
        super.init(frame: .zero)
        widthField = SizeField(target: target, action: size)
        heightField = SizeField(target: target, action: size)
        widthField.nextKeyView = heightField
        heightField.nextKeyView = widthField
        let times = NSTextField(labelWithString: "×")
        times.textColor = NSColor.white.withAlphaComponent(0.7)
        times.font = .systemFont(ofSize: 12.5, weight: .medium)
        sizeBox = NSStackView(views: [widthField, times, heightField])
        sizeBox.orientation = .horizontal
        sizeBox.spacing = 5
        keysButton = BarToggle(onSymbol: "command", offSymbol: "command", caption: "キー", width: 46, target: target, action: keys)
        cameraButton = BarToggle(onSymbol: "video.fill", offSymbol: "video.slash", caption: "カメラ", width: 46, target: target, action: camera)
        keysButton.toolTip = "押したキー（⌘⇧4 など）を画面の下に出す／出さない"
        cameraButton.toolTip = "カメラの映像を丸く重ねる／重ねない。録画中にドラッグで動かせます"
        label.font = .monospacedDigitSystemFont(ofSize: 12.5, weight: .medium)
        label.textColor = NSColor.white.withAlphaComponent(0.92)
        label.lineBreakMode = .byTruncatingTail
        micButton = BarToggle(onSymbol: "mic.fill", offSymbol: "mic.slash", caption: "マイク", width: 50, target: target, action: mic)
        micMenuButton = BarToggle(onSymbol: "chevron.down", offSymbol: "chevron.down", caption: "", width: 18, target: target, action: micMenu)
        audioButton = BarToggle(onSymbol: "speaker.wave.2.fill", offSymbol: "speaker.slash", caption: "PCの音", width: 50, target: target, action: audio)
        clicksButton = BarToggle(onSymbol: "cursorarrow.rays", offSymbol: "cursorarrow.rays", caption: "クリック", width: 50, target: target, action: clicks)
        cursorButton = BarToggle(onSymbol: "cursorarrow", offSymbol: "cursorarrow", caption: "カーソル", width: 50, target: target, action: cursor)
        micButton.toolTip = "マイクの音を入れる／入れない。入っていると、声の大きさに合わせて緑が上下します"
        micMenuButton.toolTip = "使うマイクを選ぶ"
        micMenuButton.isOn = true
        audioButton.toolTip = "パソコンから出る音を入れる／入れない"
        clicksButton.toolTip = "クリックした場所に輪を出す／出さない"
        cursorButton.toolTip = "カーソルを写す／写さない"
        let fullButton = PillButton(caption: "画面全体", primary: false, target: target, action: full)
        let cancelButton = PillButton(caption: "やめる", primary: false, target: target, action: cancel)
        gifButton = PillButton(caption: "GIFで録画", primary: false, target: target, action: gif)
        videoButton = PillButton(caption: "動画で録画", primary: true, target: target, action: video)
        fullButton.toolTip = "この画面全体を範囲にします（F キー）"
        cancelButton.toolTip = "esc キー"
        gifButton.toolTip = "音なしの GIF で録ります（option + return）"
        videoButton.toolTip = "MP4 の動画で録ります（return）"
        // オールインワンの部品
        func action(_ symbol: String, _ caption: String, _ tip: String, _ selector: Selector) -> BarToggle {
            let b = BarToggle(onSymbol: symbol, offSymbol: symbol, caption: caption, width: 58, target: target, action: selector)
            b.isOn = true
            b.toolTip = tip
            return b
        }
        let scrollButton = action("arrow.up.and.down", "スクロール", "この範囲を、下へスクロールしながら1枚の縦長の画像にします", scroll)
        let timerButton = action("timer", "タイマー", "数秒待ってから、この範囲を撮ります", timer)
        let ocrButton = action("text.viewfinder", "文字", "この範囲の文字を読み取ってコピーします", ocr)
        let recordButton = action("record.circle", "録画", "この範囲を録画します。押すと録画の設定が出ます", record)
        let shotButton = PillButton(caption: "撮る", primary: true, target: target, action: shot)
        shotButton.toolTip = "この範囲を撮ります（return）"
        let recordSeparator = separatorView(), allInOneSeparator = separatorView()
        recordViews = [recordSeparator, micButton, micMenuButton, audioButton, clicksButton, cursorButton, keysButton, cameraButton,
                       gifButton, videoButton]
        allInOneViews = [allInOneSeparator, scrollButton, timerButton, ocrButton, recordButton, shotButton]
        let views: [NSView] = [sizeBox, label, recordSeparator, micButton, micMenuButton, audioButton, clicksButton, cursorButton,
                               keysButton, cameraButton, allInOneSeparator, scrollButton, timerButton, ocrButton, recordButton,
                               separatorView(), fullButton, cancelButton, gifButton, videoButton, shotButton]
        views.forEach { stack.addArrangedSubview($0) }
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.setCustomSpacing(12, after: label)
        stack.setCustomSpacing(0, after: micButton)
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 16, bottom: 6, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12)
        NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 0.94).setFill()
        path.fill()
        let edge = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
        edge.lineWidth = 1
        NSColor.white.withAlphaComponent(0.16).setStroke()
        edge.stroke()
    }

    /// 今の設定をボタンに映す
    func syncSettings() {
        micButton.isOn = Prefs.microphoneChoice != MicrophoneChoice.none
        audioButton.isOn = Prefs.recordSystemAudio
        clicksButton.isOn = Prefs.highlightClicks
        cursorButton.isOn = Prefs.showCursor
        keysButton.isOn = Prefs.showKeystrokes
        cameraButton.isOn = Prefs.showCamera
    }

    func resize() {
        layoutSubtreeIfNeeded()
        setFrameSize(stack.fittingSize)
    }
}

/// 録画する範囲を選ぶ幕。選んだあと、まわりのつまみで大きさを変えたり、中をつかんで動かしたりできる。
final class SelectionView: NSView, NSTextFieldDelegate {
    /// 選んである範囲（このビューの座標）
    private(set) var selection: NSRect? { didSet { needsDisplay = true; layoutBar() } }
    /// 録画の範囲選びか、オールインワンか
    var mode: SelectorMode = .record { didSet { layoutBar() } }
    /// オールインワンで操作を選んだ。rect が nil ならこの画面全体（rect はこのビューの座標）
    var onAction: ((SelectorAction, NSRect?) -> Void)?
    /// オールインワンで「録画」を押した（全部の画面の帯を録画用に切り替えてもらう）
    var onRecordMode: (() -> Void)?
    /// カーソルの下にあるウィンドウの枠（このビューの座標）。クリックするとここを選ぶ
    private var hoverRect: NSRect?
    /// このビューが覆っている画面の枠（全画面を通した座標）
    var screenFrame: NSRect = .zero
    /// 録画開始。rect が nil ならこの画面全体（rect はこのビューの座標）。gif＝GIF で録る
    var onDone: ((NSRect?, _ gif: Bool) -> Void)?
    /// 帯で録画の設定を変えた（ほかの画面の帯と、音量の計測に知らせる）
    var onSettingsChanged: (() -> Void)?
    var onCancel: (() -> Void)?
    /// この画面で範囲を選び始めた（ほかの画面の選択を消してもらう）
    var onSelectionBegan: (() -> Void)?

    private enum Drag {
        case none
        case creating(start: NSPoint)
        case moving(offset: NSPoint)
        case resizing(handle: Int, original: NSRect)
    }
    private var drag: Drag = .none
    private var didDrag = false
    private var bar: SelectionBar!
    private static let minSide: CGFloat = 40

    override init(frame: NSRect) {
        super.init(frame: frame)
        bar = SelectionBar(target: self, size: #selector(sizeEdited), mic: #selector(micTapped), micMenu: #selector(micMenuTapped(_:)),
                           audio: #selector(audioTapped), clicks: #selector(clicksTapped), cursor: #selector(cursorTapped),
                           keys: #selector(keysTapped), camera: #selector(cameraTapped), full: #selector(fullTapped),
                           cancel: #selector(cancelTapped), video: #selector(startTapped), gif: #selector(startGIFTapped),
                           shot: #selector(shotTapped), scroll: #selector(scrollTapped), timer: #selector(timerTapped),
                           ocr: #selector(ocrTapped), record: #selector(recordModeTapped))
        bar.widthField.delegate = self
        bar.heightField.delegate = self
        bar.syncSettings()
        addSubview(bar)
        layoutBar()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    // MARK: 帯

    private var isFull: Bool { selection.map { $0.width >= bounds.width - 1 && $0.height >= bounds.height - 1 } ?? false }

    private func layoutBar() {
        guard let bar else { return }
        if let sel = selection {
            // 打っている途中の欄は書き換えない
            if bar.widthField.currentEditor() == nil { bar.widthField.integerValue = Int(sel.width) }
            if bar.heightField.currentEditor() == nil { bar.heightField.integerValue = Int(sel.height) }
            bar.sizeBox.isHidden = false
            bar.label.stringValue = "画面全体"
            bar.label.isHidden = !isFull
        } else {
            bar.sizeBox.isHidden = true
            bar.label.isHidden = false
            bar.label.stringValue = "ドラッグで範囲、クリックでウィンドウを選ぶ"
        }
        // 録画の部品は録画のときだけ、オールインワンの操作は範囲を決めてから出す
        let chosen = selection != nil
        bar.recordViews.forEach { $0.isHidden = mode != .record }
        bar.allInOneViews.forEach { $0.isHidden = mode != .allInOne || !chosen }
        if mode == .record {
            bar.videoButton.isHidden = !chosen
            bar.gifButton.isHidden = !chosen
        }
        bar.resize()
        layoutBarPosition()
    }

    private func layoutBarPosition() {
        guard let bar else { return }
        let size = bar.frame.size
        var origin = NSPoint(x: bounds.midX - size.width / 2, y: 64)
        if let sel = selection, !isFull {
            origin.x = sel.midX - size.width / 2
            let below = sel.minY - size.height - 14
            let above = sel.maxY + 14
            // 範囲の下 → 入らなければ上 → それも無理なら範囲の中の下寄り
            origin.y = below >= 8 ? below : (above + size.height <= bounds.maxY - 8 ? above : sel.minY + 14)
        }
        origin.x = max(8, min(bounds.maxX - size.width - 8, origin.x))
        bar.setFrameOrigin(NSPoint(x: origin.x.rounded(), y: origin.y.rounded()))
    }

    func clearSelection() {
        selection = nil
        drag = .none
    }

    @objc func fullTapped() {
        onSelectionBegan?()
        selection = bounds
    }
    @objc func cancelTapped() { onCancel?() }
    @objc func startTapped() { start(gif: false) }
    @objc func startGIFTapped() { start(gif: true) }

    // オールインワンの操作
    @objc func shotTapped() { act(.shot) }
    @objc func scrollTapped() { act(.scroll) }
    @objc func timerTapped() { act(.timer) }
    @objc func ocrTapped() { act(.ocr) }
    @objc func recordModeTapped() { onRecordMode?() }

    func act(_ action: SelectorAction) {
        guard let sel = selection else { return }
        onAction?(action, isFull ? nil : sel)
    }

    /// 前に選んだ範囲を最初から出す（このビューの座標）
    func preselect(_ rect: NSRect) {
        let r = rect.intersection(bounds).integral
        guard r.width >= Self.minSide, r.height >= Self.minSide else { return }
        selection = r
    }

    /// return やダブルクリックで実行する。オールインワンなら撮る、録画なら動画で録り始める
    func confirm(gif: Bool) {
        if mode == .allInOne { act(.shot) } else { start(gif: gif) }
    }

    func start(gif: Bool) {
        guard let sel = selection else { return }
        onDone?(isFull ? nil : sel, gif)
    }

    // MARK: 録画の設定

    /// 設定が変わったあと、帯の見た目を合わせる
    func syncSettings() {
        bar.syncSettings()
        if !bar.micButton.isOn { bar.micButton.level = 0 }
    }

    func setMicLevel(_ level: CGFloat) {
        // 上がるときはすぐ、下がるときはゆっくり（針が落ちるように）
        bar.micButton.level = max(level, bar.micButton.level * 0.82)
    }

    @objc func micTapped() {
        if Prefs.microphoneChoice != MicrophoneChoice.none {
            Prefs.lastMicrophoneChoice = Prefs.microphoneChoice
            Prefs.microphoneChoice = MicrophoneChoice.none
            onSettingsChanged?()
        } else {
            chooseMicrophone(Prefs.lastMicrophoneChoice)
        }
    }

    /// マイクを入れる。初めてなら、ここで macOS の許可を求める
    private func chooseMicrophone(_ choice: String) {
        guard choice != MicrophoneChoice.none else {
            Prefs.microphoneChoice = choice
            onSettingsChanged?()
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            Prefs.microphoneChoice = choice
            onSettingsChanged?()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] ok in
                DispatchQueue.main.async {
                    if ok { Prefs.microphoneChoice = choice } else { log("マイクが許可されなかった") }
                    self?.onSettingsChanged?()
                }
            }
        default:
            log("マイクの許可がない（システム設定 → プライバシーとセキュリティ → マイク で Kiritori をオンにする）")
            NSSound.beep()
            showNotice("マイクの許可がありません（システム設定 → プライバシーとセキュリティ → マイク）")
        }
    }

    @objc func micMenuTapped(_ sender: NSButton) {
        let menu = NSMenu()
        let current = Prefs.microphoneChoice
        func add(_ title: String, _ value: String) {
            let item = NSMenuItem(title: title, action: #selector(micMenuChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value
            item.state = value == current ? .on : .off
            menu.addItem(item)
        }
        add("入れない", MicrophoneChoice.none)
        add("Mac の設定に合わせる", MicrophoneChoice.system)
        let devices = audioInputDevices()
        if !devices.isEmpty { menu.addItem(.separator()) }
        devices.forEach { add($0.localizedName, $0.uniqueID) }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 6), in: sender)
    }

    @objc func micMenuChosen(_ sender: NSMenuItem) {
        chooseMicrophone((sender.representedObject as? String) ?? MicrophoneChoice.none)
    }

    /// 数字の欄で return。左上を動かさずに、打った大きさにする
    @objc func sizeEdited() {
        let w = min(bounds.width, max(Self.minSide, CGFloat(bar.widthField.integerValue)))
        let h = min(bounds.height, max(Self.minSide, CGFloat(bar.heightField.integerValue)))
        let old = selection ?? NSRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h)
        let x = max(0, min(bounds.maxX - w, old.minX))
        let y = max(0, min(bounds.maxY - h, old.maxY - h))
        window?.makeFirstResponder(nil)   // 入力を終える（このあと return で録画を始められるように）
        onSelectionBegan?()
        selection = NSRect(x: x.rounded(), y: y.rounded(), width: w, height: h)
    }

    /// 数字の欄で esc：範囲選びごとやめるのではなく、打ちかけを取り消すだけにする
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        control.abortEditing()
        window?.makeFirstResponder(nil)
        layoutBar()
        return true
    }

    private func showNotice(_ text: String) {
        bar.label.stringValue = text
        bar.label.isHidden = false
        bar.resize()
        layoutBarPosition()
    }

    @objc func keysTapped() {
        if Prefs.showKeystrokes {
            Prefs.showKeystrokes = false
        } else if KeystrokeOverlay.hasPermission {
            Prefs.showKeystrokes = true
        } else {
            // 初めて：macOS に「入力監視」の許可を求める（許可したあと Kiritori を開き直すと使える）
            CGRequestListenEventAccess()
            log("キー表示: 入力監視の許可がない")
            showNotice("キー表示には「入力監視」の許可が要ります（システム設定 → プライバシーとセキュリティ）")
            return
        }
        onSettingsChanged?()
    }

    @objc func cameraTapped() {
        if Prefs.showCamera {
            Prefs.showCamera = false
            onSettingsChanged?()
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            Prefs.showCamera = true
            onSettingsChanged?()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] ok in
                DispatchQueue.main.async {
                    if ok { Prefs.showCamera = true } else { log("カメラが許可されなかった") }
                    self?.onSettingsChanged?()
                }
            }
        default:
            NSSound.beep()
            showNotice("カメラの許可がありません（システム設定 → プライバシーとセキュリティ → カメラ）")
        }
    }

    @objc func audioTapped() { Prefs.recordSystemAudio.toggle(); onSettingsChanged?() }
    @objc func clicksTapped() { Prefs.highlightClicks.toggle(); onSettingsChanged?() }
    @objc func cursorTapped() { Prefs.showCursor.toggle(); onSettingsChanged?() }

    // MARK: つまみ

    /// 0〜7＝左下から反時計回りに、角と辺の真ん中
    private func handlePoints(_ r: NSRect) -> [NSPoint] {
        [NSPoint(x: r.minX, y: r.minY), NSPoint(x: r.midX, y: r.minY), NSPoint(x: r.maxX, y: r.minY), NSPoint(x: r.maxX, y: r.midY),
         NSPoint(x: r.maxX, y: r.maxY), NSPoint(x: r.midX, y: r.maxY), NSPoint(x: r.minX, y: r.maxY), NSPoint(x: r.minX, y: r.midY)]
    }

    private func handle(at p: NSPoint) -> Int? {
        guard let sel = selection else { return nil }
        return handlePoints(sel).firstIndex { hypot($0.x - p.x, $0.y - p.y) <= 11 }
    }

    private func resized(_ original: NSRect, handle: Int, to p: NSPoint) -> NSRect {
        var minX = original.minX, minY = original.minY, maxX = original.maxX, maxY = original.maxY
        let x = max(0, min(bounds.maxX, p.x)), y = max(0, min(bounds.maxY, p.y))
        if [0, 6, 7].contains(handle) { minX = min(x, maxX - Self.minSide) }
        if [2, 3, 4].contains(handle) { maxX = max(x, minX + Self.minSide) }
        if [0, 1, 2].contains(handle) { minY = min(y, maxY - Self.minSide) }
        if [4, 5, 6].contains(handle) { maxY = max(y, minY + Self.minSide) }
        return NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).integral
    }

    // MARK: 描画

    override func draw(_ dirtyRect: NSRect) {
        let dim = NSBezierPath(rect: bounds)
        if let sel = selection {
            dim.append(NSBezierPath(rect: sel))
            dim.windingRule = .evenOdd
        } else if let hoverRect {
            dim.append(NSBezierPath(rect: hoverRect))
            dim.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(0.34).setFill()
        dim.fill()

        if let sel = selection {
            let border = NSBezierPath(rect: sel.insetBy(dx: 0.75, dy: 0.75))
            border.lineWidth = 1.5
            NSColor.white.setStroke()
            border.stroke()
            for p in handlePoints(sel) {
                // 画面の端に付いたつまみも見えるよう、少し内側へ寄せる
                let c = NSPoint(x: max(5, min(bounds.maxX - 5, p.x)), y: max(5, min(bounds.maxY - 5, p.y)))
                let dot = NSBezierPath(ovalIn: NSRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10))
                NSColor.white.setFill()
                dot.fill()
                NSColor.controlAccentColor.setStroke()
                dot.lineWidth = 1.5
                dot.stroke()
            }
        } else if let hoverRect {
            let border = NSBezierPath(rect: hoverRect.insetBy(dx: 1.5, dy: 1.5))
            border.lineWidth = 3
            NSColor.controlAccentColor.setStroke()
            border.stroke()
            drawPill("クリックでこのウィンドウを選ぶ", size: 13, centerX: hoverRect.midX, y: hoverRect.midY - 12)
        }
    }

    private func drawPill(_ text: String, size: CGFloat, centerX: CGFloat, y: CGFloat) {
        let label = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .medium), .foregroundColor: NSColor.white,
        ])
        let s = label.size()
        var pill = NSRect(x: centerX - s.width / 2 - 12, y: y, width: s.width + 24, height: s.height + 10)
        pill.origin.x = max(8, min(bounds.maxX - pill.width - 8, pill.origin.x))
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        label.draw(at: NSPoint(x: pill.minX + 12, y: pill.minY + 5))
    }

    // MARK: マウス

    override func mouseMoved(with event: NSEvent) { updateHover() }
    override func mouseExited(with event: NSEvent) { hoverRect = nil; needsDisplay = true }

    private func updateHover() {
        var found: NSRect?
        if selection == nil, let frame = windowFrame(under: NSEvent.mouseLocation) {
            let local = frame.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY).intersection(bounds)
            if !local.isEmpty { found = local }
        }
        if found != hoverRect { hoverRect = found; needsDisplay = true }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(nil)   // 数字を打っている途中なら、そこで確定する
        let p = convert(event.locationInWindow, from: nil)
        didDrag = false
        if event.clickCount == 2, let sel = selection, sel.contains(p) {   // 範囲の中をダブルクリック＝実行
            confirm(gif: false)
            return
        }
        if let h = handle(at: p), let sel = selection {
            drag = .resizing(handle: h, original: sel)
        } else if let sel = selection, sel.contains(p), !isFull {
            drag = .moving(offset: NSPoint(x: p.x - sel.minX, y: p.y - sel.minY))
        } else {
            drag = .creating(start: p)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let raw = convert(event.locationInWindow, from: nil)
        let p = NSPoint(x: max(0, min(bounds.maxX, raw.x)), y: max(0, min(bounds.maxY, raw.y)))
        switch drag {
        case .creating(let start):
            guard didDrag || hypot(p.x - start.x, p.y - start.y) > 4 else { return }
            if !didDrag { onSelectionBegan?() }
            didDrag = true
            hoverRect = nil
            selection = NSRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(start.x - p.x), height: abs(start.y - p.y)).integral
        case .moving(let offset):
            guard let sel = selection else { return }
            didDrag = true
            let x = max(0, min(bounds.maxX - sel.width, p.x - offset.x)), y = max(0, min(bounds.maxY - sel.height, p.y - offset.y))
            selection = NSRect(x: x.rounded(), y: y.rounded(), width: sel.width, height: sel.height)
        case .resizing(let handle, let original):
            didDrag = true
            selection = resized(original, handle: handle, to: p)
        case .none:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { drag = .none }
        guard case .creating = drag else { return }
        if didDrag {
            // 小さすぎる範囲は選ばなかったことにする
            if let sel = selection, sel.width < Self.minSide || sel.height < Self.minSide { selection = nil }
        } else {
            // 動かさずに離した＝クリック。カーソルの下のウィンドウを選ぶ
            let hadSelection = selection != nil
            if hadSelection { selection = nil }
            updateHover()
            if let hoverRect {
                onSelectionBegan?()
                selection = hoverRect
                self.hoverRect = nil
            }
        }
    }

    // MARK: 動作確認用

    func testDrag(from a: NSPoint, to b: NSPoint) {
        selection = NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y)).integral
    }

    func testSetSize(width: Int, height: Int) {
        bar.widthField.integerValue = width
        bar.heightField.integerValue = height
        sizeEdited()
    }

    func testHover(_ rect: NSRect) {
        selection = nil
        hoverRect = rect
        needsDisplay = true
    }
}

final class SelectionPanel: NSPanel {
    var onCancel: (() -> Void)?
    /// F＝カーソルのある画面全体を範囲にする
    var onFull: (() -> Void)?
    /// return＝動画で録画開始。option + return＝GIF で録画開始
    var onStart: ((_ gif: Bool) -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case kVK_Escape: onCancel?()
        case kVK_ANSI_F: onFull?()
        case kVK_Return, kVK_ANSI_KeypadEnter: onStart?(event.modifierFlags.contains(.option))
        default: super.keyDown(with: event)
        }
    }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// 全部の画面を薄暗くして、録画する範囲を選ばせる。前面のアプリは切り替えない。
final class RegionSelector {
    private var panels: [SelectionPanel] = []
    private let onDone: (_ rect: NSRect?, _ screen: NSScreen, _ gif: Bool) -> Void
    private let onCancel: () -> Void
    private let meter = MicMeter()
    private(set) var mode: SelectorMode
    private let allInOne: Bool
    private let onAction: ((SelectorAction, NSRect?, NSScreen) -> Void)?

    init(allInOne: Bool = false, onDone: @escaping (NSRect?, NSScreen, Bool) -> Void,
         onAction: ((SelectorAction, NSRect?, NSScreen) -> Void)? = nil, onCancel: @escaping () -> Void) {
        self.allInOne = allInOne
        self.mode = allInOne ? .allInOne : .record
        self.onDone = onDone
        self.onAction = onAction
        self.onCancel = onCancel
    }

    /// オールインワンで決めた範囲を覚えておく（次に開いたときに最初から出す）
    private func remember(_ rect: NSRect?) {
        guard allInOne else { return }
        Prefs.allInOneLastRect = rect
    }

    /// 帯を録画用に切り替えて、マイクの音量を測り始める
    func switchToRecord() {
        mode = .record
        views.forEach { $0.mode = .record }
        meter.onLevel = { [weak self] level in self?.views.forEach { $0.setMicLevel(level) } }
        meter.start(choice: Prefs.microphoneChoice)
    }

    /// 動作確認用
    var testViews: [SelectionView] { views }

    private var views: [SelectionView] { panels.compactMap { $0.contentView as? SelectionView } }

    private func viewUnderMouse() -> SelectionView? {
        let mouse = NSEvent.mouseLocation
        return (panels.first { NSMouseInRect(mouse, $0.frame, false) } ?? panels.first)?.contentView as? SelectionView
    }

    func show() {
        for screen in NSScreen.screens {
            let panel = SelectionPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                       backing: .buffered, defer: false)
            panel.setFrame(screen.frame, display: false)
            panel.isReleasedWhenClosed = false
            // メニュー（マイクの一覧）がこの幕の上に出るよう、メニューより1つ下の高さに置く
            panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)) - 1)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.animationBehavior = .none
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.acceptsMouseMovedEvents = true
            let cancel: () -> Void = { [weak self] in self?.close(); self?.onCancel() }
            panel.onCancel = cancel
            panel.onFull = { [weak self] in self?.viewUnderMouse()?.fullTapped() }
            panel.onStart = { [weak self] gif in
                // 範囲を選んである画面で始める。どこも選んでいなければ、カーソルのある画面全体
                guard let self else { return }
                if let chosen = self.views.first(where: { $0.selection != nil }) {
                    chosen.confirm(gif: gif)
                } else if self.mode == .allInOne {
                    self.viewUnderMouse()?.onAction?(.shot, nil)
                } else {
                    self.viewUnderMouse()?.onDone?(nil, gif)
                }
            }
            let view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.screenFrame = screen.frame
            view.onCancel = cancel
            view.onSelectionBegan = { [weak self, weak view] in
                // 範囲は1つの画面にだけ置く
                self?.views.filter { $0 !== view }.forEach { $0.clearSelection() }
            }
            view.onSettingsChanged = { [weak self] in
                guard let self else { return }
                self.views.forEach { $0.syncSettings() }
                self.meter.start(choice: Prefs.microphoneChoice)   // マイクを替えたら測り直す（「入れない」なら止まる）
            }
            view.onDone = { [weak self] rect, gif in
                guard let self else { return }
                self.close()
                // ビューの座標 → 画面全体を通した座標
                let global = rect?.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
                self.remember(global)
                self.onDone(global, screen, gif)
            }
            view.mode = mode
            view.onAction = { [weak self] action, rect in
                guard let self else { return }
                self.close()
                let global = rect?.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
                self.remember(global)
                self.onAction?(action, global, screen)
            }
            view.onRecordMode = { [weak self] in self?.switchToRecord() }
            // 前に選んだ範囲が、この画面の中にあれば最初から出す
            if allInOne, Prefs.allInOneRemember, let last = Prefs.allInOneLastRect, screen.frame.contains(NSPoint(x: last.midX, y: last.midY)) {
                view.preselect(last.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY))
            }
            panel.contentView = view
            panels.append(panel)
        }
        let mouse = NSEvent.mouseLocation
        for panel in panels { panel.orderFrontRegardless() }
        (panels.first { NSMouseInRect(mouse, $0.frame, false) } ?? panels.first)?.makeKey()
        // マイクの音量は、録画の設定が出ているときだけ測る
        if mode == .record {
            meter.onLevel = { [weak self] level in self?.views.forEach { $0.setMicLevel(level) } }
            meter.start(choice: Prefs.microphoneChoice)
        }
    }

    func close() {
        meter.stop()
        panels.forEach { $0.orderOut(nil) }
        panels = []
    }
}

/// 録画している範囲を示す赤い枠（範囲のすぐ外側に描くので動画には写らない）。
final class RecordFrameView: NSView {
    static let margin: CGFloat = 4
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 4, yRadius: 4)
        path.lineWidth = 2
        NSColor.systemRed.setStroke()
        path.stroke()
    }
}

// MARK: - 録画

final class RecordController {
    static let shared = RecordController()

    private var task: Process?
    /// 音つきの録画（macOS 15 以上で使う StreamRecorder）
    private var streamRecorder: AnyObject?
    private let clicks = ClickHighlighter()
    private let keys = KeystrokeOverlay()
    private let camera = CameraOverlay()
    private let meter = MicMeter()
    /// 録画中のマイクの音量（マイクを入れていなければ nil）
    private var micLevel: CGFloat?
    /// いまの録画を GIF にするか
    private var recordingAsGIF = false
    private var selector: RegionSelector?
    private var frameWindow: NSWindow?
    private var timer: Timer?
    private var startedAt: Date?
    private var source: String?
    /// 動作確認用：録画が終わって後片付けまで済んだら呼ばれる
    var onFinish: ((URL?) -> Void)?

    /// 音つき方式の録画の条件。一時停止のあと、同じ条件で続きを録るために持っておく
    private struct StreamSetup {
        let rect: NSRect?
        let screen: NSScreen
        let systemAudio: Bool
        let microphoneID: String?
        let include: [CGWindowID]
        let out: URL
    }
    private var setup: StreamSetup?
    /// 一時停止で区切られた動画（止めるたびに1本ずつ増える。最後につなぐ）
    private var segments: [URL] = []
    /// 一時停止する前までに録った秒数
    private var elapsedBefore: TimeInterval = 0
    private(set) var isPaused = false
    /// 一時停止・再開の切り替えの途中
    private var switching = false
    private var pausing = false
    private var stopRequested = false
    private let dim = DimOverlay()
    private let countdown = CountdownHUD()
    private var countingDown = false

    var isRecording: Bool { task != nil || streamRecorder != nil || setup != nil }
    /// 一時停止ができる録り方か（音つき方式だけ）
    var canPause: Bool { setup != nil }
    private var elapsed: TimeInterval { elapsedBefore + (startedAt.map { Date().timeIntervalSince($0) } ?? 0) }

    /// ショートカットとメニューから呼ぶ。録画中なら止める。範囲選びの途中ならやめる。
    func toggle() {
        if isRecording {
            stop()
        } else if countingDown {
            countdown.cancel()
            countingDown = false
        } else if let selector {
            selector.close()
            self.selector = nil
        } else {
            beginSelection()
        }
    }

    func beginSelection() {
        guard CaptureController.shared.ensurePermission() else { return }
        source = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let s = RegionSelector(onDone: { [weak self] rect, screen, gif in
            self?.selector = nil
            // 薄暗い幕が消えてから録り始める
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.startAfterCountdown(rect: rect, screen: screen, gif: gif) }
        }, onCancel: { [weak self] in
            self?.selector = nil
        })
        selector = s
        s.show()
    }

    /// 設定で秒数を決めてあれば、数えてから録り始める。数えている間にもう一度ショートカットを押すとやめる。
    func startAfterCountdown(rect: NSRect?, screen: NSScreen, gif: Bool, source: String? = nil) {
        let seconds = Prefs.recordCountdown
        guard seconds > 0, !isRecording, !countingDown else { start(rect: rect, screen: screen, gif: gif, source: source); return }
        countingDown = true
        if let rect { showFrame(around: rect) }
        let area = rect ?? screen.frame
        countdown.start(seconds: seconds, center: NSPoint(x: area.midX, y: area.midY)) { [weak self] in
            guard let self, self.countingDown else { return }
            self.countingDown = false
            self.hideFrame()
            self.start(rect: rect, screen: screen, gif: gif, source: source)
        }
    }

    /// rect は AppKit の座標（左下が原点）。nil ならその画面全体。
    func start(rect: NSRect?, screen: NSScreen, gif: Bool = Prefs.recordFormat == "gif", source: String? = nil) {
        guard !isRecording else { return }
        if let source { self.source = source }
        recordingAsGIF = gif
        // macOS 15 以上は音つきで録れる方式。それより前は screencapture 方式（パソコンの音は入らない）
        if #available(macOS 15.0, *), !CommandLine.arguments.contains("--legacy-recorder") {
            startStream(rect: rect, screen: screen)
        } else {
            startLegacy(rect: rect, screen: screen)
        }
    }

    @available(macOS 15.0, *)
    private func startStream(rect: NSRect?, screen: NSScreen) {
        let out = Prefs.historyDir.appendingPathComponent("rec \(timestampName()).mp4")
        let asGIF = recordingAsGIF                       // GIF に音は入らないので、音は録らない
        let systemAudio = Prefs.recordSystemAudio && !asGIF
        let micChoice = asGIF ? MicrophoneChoice.none : Prefs.microphoneChoice
        func go(microphoneID: String?) {
            if let rect { showFrame(around: rect) }
            var include: [CGWindowID] = []
            if Prefs.highlightClicks {
                clicks.start(on: screen)
                if let id = clicks.windowID { include.append(id) }
            }
            let area = rect ?? screen.frame
            if Prefs.showKeystrokes {
                keys.start(in: area)
                if let id = keys.windowID { include.append(id) }
            }
            if Prefs.showCamera {
                camera.start(in: area)
                if let id = camera.windowID { include.append(id) }
            }
            if Prefs.recordDim, let rect { dim.show(around: rect) }
            setup = StreamSetup(rect: rect, screen: screen, systemAudio: systemAudio, microphoneID: microphoneID, include: include, out: out)
            segments = []
            elapsedBefore = 0
            isPaused = false
            pausing = false
            stopRequested = false
            startSegment(first: true)
        }
        guard micChoice != MicrophoneChoice.none else { go(microphoneID: nil); return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            go(microphoneID: micChoice)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                DispatchQueue.main.async {
                    if !ok { log("マイクが許可されなかったので、マイクなしで録る") }
                    go(microphoneID: ok ? micChoice : nil)
                }
            }
        default:
            log("マイクの許可がないので、マイクなしで録る")
            go(microphoneID: nil)
        }
    }

    /// 動作確認用：クリックしたことにして輪を出す
    func testPing(at point: NSPoint) { clicks.ping(at: point) }
    /// 動作確認用：キーを押したことにして表示を出す
    func testKey(_ text: String) { keys.show(text: text) }

    /// 1本ぶんを録り始める。first が false なら一時停止からの再開。
    @available(macOS 15.0, *)
    private func startSegment(first: Bool) {
        guard let s = setup else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kiritori-seg-\(UUID().uuidString).mp4")
        let recorder = StreamRecorder(url: url)
        streamRecorder = recorder
        switching = true
        recorder.onFinished = { [weak self] error in self?.segmentFinished(error: error) }
        recorder.start(rect: s.rect, screen: s.screen, systemAudio: s.systemAudio, microphoneID: s.microphoneID,
                       showsCursor: Prefs.showCursor, includeWindowIDs: s.include, scale1x: Prefs.recordScale1x) { [weak self] error in
            guard let self else { return }
            self.switching = false
            if let error {
                log("録画を\(first ? "始められない" : "再開できない"): \(error)")
                self.streamRecorder = nil
                NSSound.beep()
                if first {
                    self.setup = nil
                    self.hideFrame()
                    self.dim.hide()
                    self.clicks.stop()
                    self.keys.stop()
                    self.camera.stop()
                    self.onFinish?(nil)
                } else {
                    self.finalizeStream()   // ここまでに録った分で終える
                }
                return
            }
            self.segments.append(url)
            if first {
                log("録画開始（音つき方式） 範囲=\(s.rect.map { "\(Int($0.width))x\(Int($0.height))" } ?? "画面全体") パソコンの音=\(s.systemAudio) マイク=\(s.microphoneID ?? "なし") クリックの強調=\(Prefs.highlightClicks) キー=\(self.keys.windowID != nil) カメラ=\(self.camera.windowID != nil) 等倍=\(Prefs.recordScale1x) 形式=\(self.recordingAsGIF ? "gif" : "mp4")")
                // 録画中も音が入っているか見えるよう、マイクの音量を測り続ける
                if let microphoneID = s.microphoneID {
                    self.micLevel = 0
                    self.meter.onLevel = { [weak self] level in
                        guard let self, let current = self.micLevel else { return }
                        self.micLevel = max(level, current * 0.82)
                        self.updateIndicator()
                    }
                    self.meter.start(choice: microphoneID)
                }
                self.beginClock()
            } else {
                log("録画を再開（\(self.segments.count) 本目）")
                self.isPaused = false
                self.startedAt = Date()
                self.updateIndicator()
            }
            if self.stopRequested { self.stop() }
        }
    }

    /// 1本ぶんが閉じられた（一時停止・停止・途中で止まった）
    @available(macOS 15.0, *)
    private func segmentFinished(error: Error?) {
        streamRecorder = nil
        if let startedAt { elapsedBefore += Date().timeIntervalSince(startedAt) }
        startedAt = nil
        if let error { log("録画が止まった error=\(error)") }
        if pausing, error == nil {
            pausing = false
            switching = false
            isPaused = true
            log("録画を一時停止（ここまで 約\(Int(elapsedBefore))秒）")
            updateIndicator()
            if stopRequested { finalizeStream() }
            return
        }
        pausing = false
        switching = false
        finalizeStream()
    }

    /// 一時停止と再開を切り替える。ショートカットと、録画中のメニューバーのボタンから呼ぶ。
    func togglePause() {
        guard #available(macOS 15.0, *), setup != nil, !switching else {
            if isRecording || switching { NSSound.beep() }
            return
        }
        if isPaused {
            startSegment(first: false)
        } else if let recorder = streamRecorder as? StreamRecorder {
            switching = true
            pausing = true
            recorder.stop()
        }
    }

    /// 録った分をつないで1本にし、履歴と小窓へ渡す。
    @available(macOS 15.0, *)
    private func finalizeStream() {
        guard let s = setup else { return }
        setup = nil
        isPaused = false
        stopRequested = false
        let seconds = elapsedBefore
        let all = segments
        segments = []
        endClock()
        let fm = FileManager.default
        let good = all.filter { ((try? fm.attributesOfItem(atPath: $0.path)[.size] as? Int) ?? 0) > 0 && videoInfo($0) != nil }
        all.filter { !good.contains($0) }.forEach { try? fm.removeItem(at: $0) }
        log("録画終了（音つき方式） 約\(Int(seconds))秒 区切り=\(all.count)本 使える=\(good.count)本")
        guard !good.isEmpty else {
            NSSound.beep()
            onFinish?(nil)
            return
        }
        joinVideos(good, to: s.out) { [weak self] ok in
            good.forEach { try? fm.removeItem(at: $0) }
            guard ok else {
                log("録画をつなげなかった")
                NSSound.beep()
                self?.onFinish?(nil)
                return
            }
            // パソコンの音とマイクが別々の2本で入るので、1本に混ぜる
            mixAudioTracksIfNeeded(s.out) { [weak self] mixed in self?.finishFormat(mixed) }
        }
    }

    private func beginClock() {
        startedAt = Date()
        if Prefs.recordDND { FocusSwitch.set(true) }
        updateIndicator()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.updateIndicator() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func endClock() {
        startedAt = nil
        let wasRunning = timer != nil
        timer?.invalidate()
        timer = nil
        elapsedBefore = 0
        if wasRunning, Prefs.recordDND { FocusSwitch.set(false) }
        hideFrame()
        dim.hide()
        clicks.stop()
        keys.stop()
        camera.stop()
        meter.stop()
        micLevel = nil
        (NSApp.delegate as? AppDelegate)?.setRecording(elapsed: nil)
    }

    /// 形式が GIF なら作り替えてから渡す
    private func finishFormat(_ file: URL) {
        guard recordingAsGIF, isVideo(file) else { deliver(file); return }
        makeGIF(from: file) { [weak self] gif in
            if let gif {
                try? FileManager.default.removeItem(at: file)
                self?.deliver(gif)
            } else {
                self?.deliver(file)   // 作れなかったら動画のまま渡す
            }
        }
    }

    /// 録り終えたファイルを履歴に載せて小窓に出す
    private func deliver(_ file: URL) {
        HistoryStore.record(file: file, source: source)
        if Prefs.autoSave { saveToFolder(file) }
        PopupController.shared.show(file: file, on: screenUnderMouse())
        onFinish?(file)
    }

    private func startLegacy(rect: NSRect?, screen: NSScreen) {
        let out = Prefs.historyDir.appendingPathComponent("rec \(timestampName()).mov")
        var args = ["-v", "-x"]
        if Prefs.microphoneChoice != MicrophoneChoice.none && !recordingAsGIF { args.append("-g") }   // この方式で入れられるのはマイクだけ
        if Prefs.highlightClicks { args.append("-k") }
        if let rect {
            // screencapture の -R は、メイン画面の左上を原点にした座標
            let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
            args += ["-R", "\(Int(rect.minX)),\(Int(primaryHeight - rect.maxY)),\(Int(rect.width)),\(Int(rect.height))"]
            showFrame(around: rect)
        } else {
            args += ["-D", String(displayIndex(for: screen))]
        }
        args.append(out.path)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async { self?.finished(out, status: proc.terminationStatus) }
        }
        do {
            try p.run()
        } catch {
            log("録画を始められない: \(error)")
            hideFrame()
            NSSound.beep()
            onFinish?(nil)
            return
        }
        task = p
        log("録画開始 \(args.dropLast().joined(separator: " "))")
        beginClock()
    }

    func stop() {
        if #available(macOS 15.0, *), setup != nil {
            if switching {
                stopRequested = true   // 切り替えが済んでから止める
            } else if let recorder = streamRecorder as? StreamRecorder {
                recorder.stop()
            } else {
                finalizeStream()       // 一時停止中
            }
            return
        }
        // 割り込み信号を送ると、screencapture が動画を書き終えてから終わる
        task?.interrupt()
    }

    private func updateIndicator() {
        guard timer != nil else { return }
        (NSApp.delegate as? AppDelegate)?.setRecording(elapsed: elapsed, micLevel: micLevel, paused: isPaused, canPause: canPause)
    }

    private func finished(_ mov: URL, status: Int32) {
        let seconds = elapsed
        task = nil
        endClock()

        let size = (try? FileManager.default.attributesOfItem(atPath: mov.path)[.size] as? Int) ?? 0
        log("録画終了 exit=\(status) 約\(Int(seconds))秒 size=\(size)")
        guard size > 0, videoInfo(mov) != nil else {
            try? FileManager.default.removeItem(at: mov)
            NSSound.beep()
            onFinish?(nil)
            return
        }
        convertToMP4(mov) { [weak self] file in self?.finishFormat(file) }
    }

    /// 映像は作り直さず、入れ物だけ mp4 に替える（貼り付け先で再生できる所が多いため）。
    private func convertToMP4(_ mov: URL, completion: @escaping (URL) -> Void) {
        let mp4 = mov.deletingPathExtension().appendingPathExtension("mp4")
        guard let export = AVAssetExportSession(asset: AVURLAsset(url: mov), presetName: AVAssetExportPresetPassthrough) else {
            completion(mov)
            return
        }
        export.outputURL = mp4
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true
        export.exportAsynchronously {
            DispatchQueue.main.async {
                if export.status == .completed {
                    try? FileManager.default.removeItem(at: mov)
                    completion(mp4)
                } else {
                    log("mp4 への変換に失敗（mov のまま残す） \(String(describing: export.error))")
                    try? FileManager.default.removeItem(at: mp4)
                    completion(mov)
                }
            }
        }
    }

    private func showFrame(around rect: NSRect) {
        let m = RecordFrameView.margin
        let w = NSWindow(contentRect: rect.insetBy(dx: -m, dy: -m), styleMask: .borderless, backing: .buffered, defer: false)
        w.setFrame(rect.insetBy(dx: -m, dy: -m), display: false)
        w.isReleasedWhenClosed = false
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.level = .statusBar
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.contentView = RecordFrameView(frame: NSRect(origin: .zero, size: w.frame.size))
        w.orderFrontRegardless()
        frameWindow = w
    }

    private func hideFrame() {
        frameWindow?.orderOut(nil)
        frameWindow = nil
    }
}
