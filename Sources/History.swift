// 履歴の画面。
// 撮った画像と録画を新しい順に横へ並べ、選んだ1つを小窓に戻す・コピー・保存・編集（録画は再生）・削除できる。
// 画面の上に出す。

import AppKit
import Carbon.HIToolbox
import ImageIO

// MARK: - 履歴の中身

struct HistoryItem {
    let url: URL
    let date: Date
    /// 撮ったとき前面にいたアプリの bundle ID
    let source: String?
    /// 録画したもの（動画か GIF）
    var isVideo: Bool { isMotion(url) }
}

enum HistoryStore {
    static var indexURL: URL { Prefs.historyDir.appendingPathComponent("index.json") }

    static func loadIndex() -> [String: String] {
        guard let data = try? Data(contentsOf: indexURL),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return [:] }
        return dict
    }

    private static func saveIndex(_ index: [String: String]) {
        guard let data = try? JSONSerialization.data(withJSONObject: index, options: [.sortedKeys]) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    /// どのアプリを撮ったかを覚えておく。もう無い画像の分はここで捨てる。
    static func record(file: URL, source: String?) {
        guard let source, source != Bundle.main.bundleIdentifier else { return }
        let fm = FileManager.default
        var index = loadIndex().filter { fm.fileExists(atPath: Prefs.historyDir.appendingPathComponent($0.key).path) }
        index[file.lastPathComponent] = source
        saveIndex(index)
    }

    static func forget(file: URL) {
        var index = loadIndex()
        guard index.removeValue(forKey: file.lastPathComponent) != nil else { return }
        saveIndex(index)
    }

    /// ファイル名「shot yyyy-MM-dd HH.mm.ss」「rec yyyy-MM-dd HH.mm.ss」から撮った時刻を読む（編集で書き直しても変わらない）。
    static func captureDate(of url: URL) -> Date? {
        let name = url.deletingPathExtension().lastPathComponent
        guard let prefix = ["shot ", "rec "].first(where: { name.hasPrefix($0) }), name.count >= prefix.count + 19 else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f.date(from: String(name.dropFirst(prefix.count).prefix(19)))
    }

    static func items() -> [HistoryItem] {
        let index = loadIndex()
        let files = (try? FileManager.default.contentsOfDirectory(
            at: Prefs.historyDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { ["png", "mov", "mp4", "m4v", "gif"].contains($0.pathExtension.lowercased()) }.map { url in
            let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            return HistoryItem(url: url, date: captureDate(of: url) ?? modified ?? .distantPast,
                               source: index[url.lastPathComponent])
        }.sorted { $0.date > $1.date }
    }
}

func relativeTime(_ date: Date, now: Date = Date()) -> String {
    let s = Int(now.timeIntervalSince(date))
    if s < 60 { return "たった今" }
    if s < 3600 { return "\(s / 60)分前" }
    if s < 86400 { return "\(s / 3600)時間前" }
    let days = s / 86400
    return days == 1 ? "昨日" : "\(days)日前"
}

func pixelSize(of url: URL) -> (Int, Int)? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
          let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
    return (w, h)
}

/// 小さく縮めた見本を裏で作ってためておく。
final class ThumbCache {
    static let shared = ThumbCache()
    private var cache: [String: NSImage] = [:]
    private var icons: [String: NSImage] = [:]
    private var durations: [String: String] = [:]
    private let queue = DispatchQueue(label: "local.kiritori.thumbs", qos: .userInitiated, attributes: .concurrent)

    private func key(_ url: URL) -> String {
        let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
        return "\(url.path)|\(m)"
    }

    func load(_ url: URL, maxPixel: Int = 640, completion: @escaping (NSImage?) -> Void) {
        let k = key(url)
        if let hit = cache[k] { completion(hit); return }
        queue.async {
            var result: NSImage?
            var duration: String?
            if isVideo(url) {
                result = videoPoster(url, maxPixel: CGFloat(maxPixel))
                duration = videoInfo(url).map { clockText($0.seconds) }
            } else if let src = CGImageSourceCreateWithURL(url as CFURL, nil) {
                let opts: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                ]
                if let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) {
                    result = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                }
                if isGIF(url) { duration = "GIF" }
            }
            DispatchQueue.main.async {
                if let result { self.cache[k] = result }
                if let duration { self.durations[url.path] = duration }
                completion(result)
            }
        }
    }

    /// 動画の長さ（「0:12」）。サムネイルを読み終えると入る
    func duration(_ url: URL) -> String? { durations[url.path] }

    func appIcon(_ bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let hit = icons[bundleID] { return hit }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icons[bundleID] = icon
        return icon
    }
}

// MARK: - 1枚ぶんの札

final class HistoryCard: NSView, NSDraggingSource {
    static let size = NSSize(width: 228, height: 188)
    static let tile = NSRect(x: 4, y: 34, width: 220, height: 150)

    let item: HistoryItem
    var thumb: NSImage? { didSet { needsDisplay = true } }
    var appIcon: NSImage?
    var isSelected = false { didSet { if oldValue != isSelected { needsDisplay = true } } }
    private var hovering = false { didSet { needsDisplay = true } }
    private var downPoint: NSPoint?

    var onSelect: (() -> Void)?
    var onOpen: (() -> Void)?
    var onDragStart: (() -> Void)?
    var onDragEnd: ((_ dropped: Bool) -> Void)?

    init(item: HistoryItem) {
        self.item = item
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        appIcon = ThumbCache.shared.appIcon(item.source)
        toolTip = "クリックで選ぶ。ダブルクリックで小窓に戻す。ドラッグで他のアプリへ"
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
        ThumbCache.shared.load(item.url) { [weak self] image in self?.thumb = image }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    /// 札の中で画像が収まる場所
    private var imageRect: NSRect {
        let inner = Self.tile.insetBy(dx: 8, dy: 8)
        guard let s = thumb?.size, s.width > 0, s.height > 0 else { return inner }
        let scale = min(inner.width / s.width, inner.height / s.height, 1.0)
        let w = s.width * scale, h = s.height * scale
        return NSRect(x: inner.midX - w / 2, y: inner.midY - h / 2, width: w, height: h)
    }

    override func draw(_ dirtyRect: NSRect) {
        let tile = Self.tile
        NSColor.white.withAlphaComponent(isSelected ? 0.13 : hovering ? 0.10 : 0.06).setFill()
        NSBezierPath(roundedRect: tile, xRadius: 10, yRadius: 10).fill()

        if let thumb {
            let r = imageRect
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
            shadow.shadowBlurRadius = 6
            shadow.shadowOffset = NSSize(width: 0, height: -2)
            shadow.set()
            NSColor.black.setFill()
            NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).fill()
            NSGraphicsContext.restoreGraphicsState()

            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).addClip()
            NSGraphicsContext.current?.imageInterpolation = .high
            thumb.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1.0)
            NSGraphicsContext.restoreGraphicsState()
            if item.isVideo, let d = ThumbCache.shared.duration(item.url) { drawVideoBadge(d, in: r) }
        }

        let border: NSBezierPath
        if isSelected {
            border = NSBezierPath(roundedRect: tile.insetBy(dx: 1.5, dy: 1.5), xRadius: 9, yRadius: 9)
            border.lineWidth = 3
            NSColor.controlAccentColor.setStroke()
        } else {
            border = NSBezierPath(roundedRect: tile.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
            border.lineWidth = 1
            NSColor.white.withAlphaComponent(hovering ? 0.32 : 0.12).setStroke()
        }
        border.stroke()

        if let appIcon {
            let r = NSRect(x: tile.maxX - 32, y: tile.minY + 6, width: 26, height: 26)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
            shadow.shadowBlurRadius = 4
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            shadow.set()
            appIcon.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1.0)
            NSGraphicsContext.restoreGraphicsState()
        }

        let label = NSAttributedString(string: relativeTime(item.date), attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: isSelected ? .semibold : .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(isSelected ? 0.95 : 0.55),
        ])
        let size = label.size()
        label.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: 9))
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onSelect?()
        if event.clickCount == 2 {
            downPoint = nil
            onOpen?()
            return
        }
        downPoint = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downPoint else { return }
        let now = convert(event.locationInWindow, from: nil)
        guard hypot(now.x - start.x, now.y - start.y) > 4 else { return }
        downPoint = nil
        let dragItem = NSDraggingItem(pasteboardWriter: item.url as NSURL)
        dragItem.setDraggingFrame(imageRect, contents: thumb)
        onDragStart?()
        beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        onDragEnd?(operation != [])
    }
}

// MARK: - 帯の部品

/// 暗い角丸の下地
final class HistoryBackdrop: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 16, yRadius: 16)
        NSColor(srgbRed: 0.10, green: 0.10, blue: 0.11, alpha: 0.97).setFill()
        path.fill()
        let edge = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 16, yRadius: 16)
        edge.lineWidth = 1
        NSColor.white.withAlphaComponent(0.14).setStroke()
        edge.stroke()
    }
}

/// マウスのホイール（縦）でも横に送れるスクロール
final class WheelScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        guard let doc = documentView else { return }
        let step: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 14
        let raw = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
        var origin = contentView.bounds.origin
        let maxX = max(0, doc.frame.width - contentView.bounds.width)
        origin.x = max(0, min(maxX, origin.x - raw * step))
        contentView.setBoundsOrigin(origin)
        reflectScrolledClipView(contentView)
    }
}

final class HistoryPanel: NSPanel {
    var onKey: ((NSEvent) -> Bool)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, event.modifierFlags.contains(.command), onKey?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - 履歴の画面

final class HistoryController: NSObject, NSWindowDelegate {
    static let shared = HistoryController()
    /// 動作確認のときは画面に出さず、前面も奪わない。
    static var headless = false

    private var panel: HistoryPanel?
    private var allItems: [HistoryItem] = []
    private var items: [HistoryItem] = []
    /// 0=すべて 1=スクショ 2=録画（開き直しても覚えておく）
    private var filter = 0
    private var filterControl: NSSegmentedControl!
    private var playButton: PillButton?
    private var cards: [HistoryCard] = []
    private(set) var selected = 0
    private var scroll: WheelScrollView!
    private var docView: NSView!
    private var detailLabel: NSTextField!
    private var countLabel: NSTextField!
    private var emptyLabel: NSTextField!
    private var actionRow: NSStackView!
    private var dragging = false
    private var lostKeyWhileDragging = false

    var count: Int { items.count }
    var isOpen: Bool { panel != nil }
    private var current: HistoryItem? { items.indices.contains(selected) ? items[selected] : nil }

    static let height: CGFloat = 296
    static let gap: CGFloat = 10

    func toggle() {
        if panel == nil { show() } else { close() }
    }

    func show() {
        guard panel == nil else { return }
        allItems = HistoryStore.items()
        applyFilter()
        selected = 0

        let screen = Self.headless ? (NSScreen.main ?? NSScreen.screens[0]) : screenUnderMouse()
        let vf = screen.visibleFrame
        let width = min(vf.width - 24, 1680)
        // 画面の上（メニューバーのすぐ下）に出す
        let frame = NSRect(x: vf.midX - width / 2, y: vf.maxY - Self.height - 10, width: width, height: Self.height)

        let p = HistoryPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isReleasedWhenClosed = false
        p.level = .floating
        p.hidesOnDeactivate = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isMovable = false
        p.animationBehavior = .none
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.appearance = NSAppearance(named: .darkAqua)
        p.delegate = self
        p.onKey = { [weak self] event in self?.handleKey(event) ?? false }

        let root = HistoryBackdrop(frame: NSRect(origin: .zero, size: frame.size))
        p.contentView = root

        let title = NSTextField(labelWithString: "履歴")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = .white
        title.frame = NSRect(x: 22, y: Self.height - 38, width: 120, height: 22)
        root.addSubview(title)

        filterControl = NSSegmentedControl(labels: ["すべて", "スクショ", "録画"], trackingMode: .selectOne,
                                           target: self, action: #selector(filterChanged))
        filterControl.selectedSegment = filter
        filterControl.frame = NSRect(x: 86, y: Self.height - 41, width: 228, height: 26)
        root.addSubview(filterControl)

        countLabel = NSTextField(labelWithString: "")
        countLabel.font = .systemFont(ofSize: 12)
        countLabel.textColor = NSColor.white.withAlphaComponent(0.5)
        countLabel.alignment = .right
        countLabel.frame = NSRect(x: width - 22 - 420, y: Self.height - 37, width: 420, height: 18)
        root.addSubview(countLabel)

        scroll = WheelScrollView(frame: NSRect(x: 12, y: 58, width: width - 24, height: HistoryCard.size.height + 4))
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.horizontalScrollElasticity = .none
        scroll.verticalScrollElasticity = .none
        docView = NSView(frame: scroll.bounds)
        scroll.documentView = docView
        root.addSubview(scroll)

        emptyLabel = NSTextField(labelWithString: "まだ履歴がありません")
        emptyLabel.font = .systemFont(ofSize: 14)
        emptyLabel.textColor = NSColor.white.withAlphaComponent(0.5)
        emptyLabel.alignment = .center
        emptyLabel.frame = NSRect(x: 0, y: scroll.frame.midY - 10, width: width, height: 20)
        root.addSubview(emptyLabel)

        detailLabel = NSTextField(labelWithString: "")
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = NSColor.white.withAlphaComponent(0.7)
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.frame = NSRect(x: 22, y: 20, width: max(120, width - 22 - 650), height: 18)
        root.addSubview(detailLabel)

        let buttons: [(String, Bool, Selector, String)] = [
            ("小窓に戻す", true, #selector(restoreSelected), "return"),
            ("コピー", false, #selector(copySelected), "⌘C"),
            ("保存", false, #selector(saveSelected), "⌘S"),
            ("編集", false, #selector(editSelected), "⌘E"),
            ("ピン留め", false, #selector(pinSelected), "⌘P"),
            ("文字", false, #selector(textSelected), "⌘T（画像の中の文字を読み取ってコピー）"),
            ("削除", false, #selector(deleteSelected), "delete"),
        ]
        actionRow = NSStackView(views: buttons.map { caption, primary, action, key in
            let b = PillButton(caption: caption, primary: primary, target: self, action: action)
            b.toolTip = key
            if caption == "編集" { playButton = b }
            return b
        })
        actionRow.orientation = .horizontal
        actionRow.spacing = 8
        actionRow.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(actionRow)
        NSLayoutConstraint.activate([
            actionRow.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            actionRow.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
        ])

        panel = p
        rebuildCards()
        select(0, scrolling: false)

        if Self.headless {
            root.layoutSubtreeIfNeeded()
            return
        }
        // 上からすっと出す
        p.setFrame(frame.offsetBy(dx: 0, dy: 18), display: false)
        p.alphaValue = 0
        p.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            p.animator().setFrame(frame, display: true)
            p.animator().alphaValue = 1
        }
        log("履歴を開いた 枚数=\(items.count)")
    }

    func close() {
        guard let p = panel else { return }
        panel = nil
        cards = []
        playButton = nil
        dragging = false
        lostKeyWhileDragging = false
        if Self.headless { p.orderOut(nil); return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            p.animator().alphaValue = 0
        }, completionHandler: {
            p.orderOut(nil)
        })
    }

    /// 帯の外をクリックしたら閉じる。画像をドラッグしている間は閉じない。
    func windowDidResignKey(_ notification: Notification) {
        guard (notification.object as? HistoryPanel) === panel else { return }
        if dragging { lostKeyWhileDragging = true; return }
        close()
    }

    private func applyFilter() {
        switch filter {
        case 1: items = allItems.filter { !$0.isVideo }
        case 2: items = allItems.filter { $0.isVideo }
        default: items = allItems
        }
    }

    @objc func filterChanged() {
        filter = filterControl.selectedSegment
        applyFilter()
        rebuildCards()
        scroll.contentView.setBoundsOrigin(.zero)
        select(0, scrolling: false)
    }

    /// 動作確認用
    func testSetFilter(_ index: Int) {
        filterControl.selectedSegment = index
        filterChanged()
    }

    private func rebuildCards() {
        docView.subviews.forEach { $0.removeFromSuperview() }
        let step = HistoryCard.size.width + Self.gap
        let needed = Self.gap + CGFloat(items.count) * step
        docView.frame = NSRect(x: 0, y: 0, width: max(scroll.contentSize.width, needed), height: HistoryCard.size.height + 4)
        cards = items.enumerated().map { index, item in
            let card = HistoryCard(item: item)
            card.frame.origin = NSPoint(x: Self.gap + CGFloat(index) * step, y: 2)
            card.onSelect = { [weak self, weak card] in
                guard let self, let card, let i = self.cards.firstIndex(where: { $0 === card }) else { return }
                self.select(i)
            }
            card.onOpen = { [weak self] in self?.restoreSelected() }
            card.onDragStart = { [weak self] in self?.dragging = true }
            card.onDragEnd = { [weak self] dropped in
                guard let self else { return }
                self.dragging = false
                if dropped || self.lostKeyWhileDragging { self.close() }
                self.lostKeyWhileDragging = false
            }
            docView.addSubview(card)
            return card
        }
        emptyLabel.isHidden = !items.isEmpty
        emptyLabel.stringValue = filter == 2 ? "まだ録画がありません" : filter == 1 ? "まだスクショがありません" : "まだ履歴がありません"
        actionRow.isHidden = items.isEmpty
        countLabel.stringValue = items.isEmpty ? "撮ったものは\(Prefs.historyDays)日間ここに残ります" : "\(items.count)件 ・ \(Prefs.historyDays)日たつと自動で消えます"
    }

    func select(_ index: Int, scrolling: Bool = true) {
        guard !items.isEmpty else { selected = 0; detailLabel.stringValue = ""; return }
        defer { playButton?.caption = (current.map { isGIF($0.url) } ?? false) ? "再生" : "編集" }
        selected = max(0, min(items.count - 1, index))
        for (i, card) in cards.enumerated() { card.isSelected = (i == selected) }
        if scrolling { cards[selected].scrollToVisible(cards[selected].bounds.insetBy(dx: -Self.gap, dy: 0)) }
        let item = items[selected]
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M月d日 HH:mm"
        var parts = [f.string(from: item.date)]
        if isGIF(item.url) {
            if let (w, h) = pixelSize(of: item.url) { parts.append("\(w) × \(h)") }
            parts.append("GIF")
        } else if item.isVideo {
            if let info = videoInfo(item.url) { parts.append("\(info.width) × \(info.height)"); parts.append("録画 " + clockText(info.seconds)) }
        } else if let (w, h) = pixelSize(of: item.url) {
            parts.append("\(w) × \(h)")
        }
        if let id = item.source, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            parts.append(FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""))
        }
        detailLabel.stringValue = parts.joined(separator: " ・ ")
    }

    func handleKey(_ event: NSEvent) -> Bool {
        let cmd = event.modifierFlags.contains(.command)
        switch Int(event.keyCode) {
        case kVK_Escape: close()
        case kVK_LeftArrow: select(selected - 1)
        case kVK_RightArrow: select(selected + 1)
        case kVK_Return, kVK_ANSI_KeypadEnter: restoreSelected()
        case kVK_Delete, kVK_ForwardDelete: deleteSelected()
        case kVK_ANSI_C where cmd: copySelected()
        case kVK_ANSI_S where cmd: saveSelected()
        case kVK_ANSI_E where cmd: editSelected()
        case kVK_ANSI_P where cmd: pinSelected()
        case kVK_ANSI_T where cmd: textSelected()
        case kVK_ANSI_W where cmd: close()
        default: return false
        }
        return true
    }

    // MARK: 選んだ1枚にすること

    @objc func restoreSelected() {
        guard let item = current else { return }
        let screen = panel?.screen ?? screenUnderMouse()
        close()
        PopupController.shared.show(file: item.url, on: screen)
        log("履歴: 小窓に戻す \(item.url.lastPathComponent)")
    }

    @objc func copySelected() {
        guard let item = current else { return }
        copyImageToPasteboard(item.url)
        close()
    }

    @objc func saveSelected() {
        guard let item = current else { return }
        if saveToFolder(item.url) != nil { close() }
    }

    @objc func editSelected() {
        guard let item = current else { return }
        let url = item.url
        close()
        if isVideo(url) {   // 動画は動画エディタで開く
            VideoEditorController.open(file: url)
            return
        }
        if item.isVideo {   // GIF は標準のアプリで開く
            NSWorkspace.shared.open(url)
            return
        }
        EditorController.open(file: url) { saved in
            if !saved { PopupController.shared.show(file: url, on: screenUnderMouse()) }
        }
    }

    @objc func pinSelected() {
        guard let item = current, !item.isVideo else { NSSound.beep(); return }
        close()
        PinController.shared.pin(file: item.url, at: CaptureController.shared.captureRect(for: item.url))
    }

    @objc func textSelected() {
        guard let item = current, !item.isVideo else { NSSound.beep(); return }
        let url = item.url
        close()
        TextReader.read(file: url) { text, codes in TextReader.copyResult(text: text, codes: codes) }
    }

    /// ゴミ箱へ移す（間違えても戻せる）。
    @objc func deleteSelected() {
        guard let item = current else { return }
        do {
            if Self.headless {
                try FileManager.default.removeItem(at: item.url)
            } else {
                try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
            }
        } catch {
            log("履歴: 削除できない \(error)")
            NSSound.beep()
            return
        }
        log("履歴: 削除 \(item.url.lastPathComponent)")
        HistoryStore.forget(file: item.url)
        PopupController.shared.remove(file: item.url)
        allItems.removeAll { $0.url == item.url }
        items.remove(at: selected)
        rebuildCards()
        select(selected)
    }

    // MARK: 動作確認用

    /// index 番目の札をマウスで押したことにする。
    func testClick(_ index: Int) {
        guard let p = panel, cards.indices.contains(index) else { return }
        let card = cards[index]
        let pt = card.convert(NSPoint(x: card.bounds.midX, y: card.bounds.midY), to: nil)
        if let e = NSEvent.mouseEvent(with: .leftMouseDown, location: pt, modifierFlags: [], timestamp: 0,
                                      windowNumber: p.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
            card.mouseDown(with: e)
        }
    }

    func testKey(_ keyCode: Int, command: Bool = false) -> Bool {
        guard let p = panel, let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: command ? [.command] : [],
                                                      timestamp: 0, windowNumber: p.windowNumber, context: nil,
                                                      characters: "", charactersIgnoringModifiers: "", isARepeat: false,
                                                      keyCode: UInt16(keyCode)) else { return false }
        return handleKey(e)
    }

    func snapshot(to url: URL) {
        guard let view = panel?.contentView else { return }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
