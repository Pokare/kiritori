// 設定画面: メニューに並べていた切り替えを1つの窓にまとめる。ショートカットもここで変えられる。

import AppKit
import AVFoundation
import Carbon.HIToolbox
import ServiceManagement

/// ボタンやメニューが押されたときに動かす中身を持っておく入れ物。
private final class ActionBox: NSObject {
    let run: (NSControl) -> Void
    init(_ run: @escaping (NSControl) -> Void) { self.run = run }
    @objc func fire(_ sender: NSControl) { run(sender) }
}

/// ショートカットを打ち込んで決める欄。押すと「キーを押す…」になり、次に押した組み合わせを覚える。
final class ShortcutField: NSButton {
    let spec: HotKeySpec
    /// 変えた・やめたあとに呼ぶ。引数は、うまくいかなかったときの説明
    var onChange: ((String?) -> Void)?
    private var monitor: Any?
    private(set) var isRecording = false

    init(spec: HotKeySpec) {
        self.spec = spec
        super.init(frame: .zero)
        bezelStyle = .rounded
        target = self
        action = #selector(clicked)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 130).isActive = true
        toolTip = "押してから、使いたいキーの組み合わせを押します。delete で「なし」、esc でやめる"
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    func refresh() {
        let hk = Prefs.hotKey(spec.name, defaultKey: spec.defaultKey)
        title = isRecording ? "キーを押す…" : shortcutText(key: hk.key, mods: hk.mods)
    }

    @objc private func clicked() {
        if isRecording { stop(nil) } else { start() }
    }

    /// いま入力待ちの欄（同時に1つだけ）
    private static weak var recording: ShortcutField?
    private var resignObserver: Any?

    // タブを切り替えた・窓から外れたときは入力待ちをやめる
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil, isRecording { stop(nil) }
    }
    override func viewDidHide() {
        super.viewDidHide()
        if isRecording { stop(nil) }
    }

    func start() {
        guard !isRecording else { return }
        Self.recording?.stop(nil)   // ほかの欄が入力待ちならやめさせる
        Self.recording = self
        isRecording = true
        // ほかのアプリへ移ったら入力待ちをやめる（ショートカットが止まったままにならないように）
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            if self?.isRecording == true { self?.stop(nil) }
        }
        HotKeys.unregisterAll()   // 打ち込んでいる間は、今のショートカットが動かないようにする
        refresh()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.apply(keyCode: UInt32(event.keyCode), flags: event.modifierFlags)
            return nil
        }
    }

    /// 押された組み合わせを覚える。使えないときは理由を返して、打ち込みを続ける。
    @discardableResult
    func apply(keyCode: UInt32, flags: NSEvent.ModifierFlags) -> String? {
        if Int(keyCode) == kVK_Escape { stop(nil); return nil }
        if Int(keyCode) == kVK_Delete || Int(keyCode) == kVK_ForwardDelete {
            Prefs.setHotKey(spec.name, key: hotKeyDisabled, mods: 0)
            stop(nil)
            return nil
        }
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        func refuse(_ reason: String) -> String {
            NSSound.beep()
            onChange?(reason)
            return reason
        }
        guard keyNames[Int(keyCode)] != nil else { return refuse("そのキーは使えません（数字・英字・F1〜F12・space が使えます）") }
        guard mods & UInt32(cmdKey | controlKey | optionKey) != 0 else { return refuse("⌘ ⌃ ⌥ のどれかと一緒に押してください") }
        for other in HotKeys.specs where other.name != spec.name {
            let o = Prefs.hotKey(other.name, defaultKey: other.defaultKey)
            if o.key == keyCode, o.mods == mods { return refuse("その組み合わせは「\(other.title)」で使っています") }
        }
        let old = Prefs.hotKey(spec.name, defaultKey: spec.defaultKey)
        Prefs.setHotKey(spec.name, key: keyCode, mods: mods)
        isRecording = false
        if HotKeys.enabled, HotKeys.registerAll()[spec.name] == false {
            // macOS に断られた（ほかのアプリが先に使っている）ので、元に戻す
            Prefs.setHotKey(spec.name, key: old.key, mods: old.mods)
            stop("その組み合わせは、ほかのアプリが使っているため登録できませんでした")
            return "登録できない"
        }
        stop(nil)
        return nil
    }

    func stop(_ note: String?) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        if Self.recording === self { Self.recording = nil }
        isRecording = false
        HotKeys.registerAll()
        refresh()
        log("ショートカット \(spec.name)=\(title)\(note.map { "（\($0)）" } ?? "")")
        onChange?(note)
    }
}

final class SettingsController: NSObject, NSWindowDelegate {
    static let shared = SettingsController()
    /// 動作確認のときは画面に出さない
    static var headless = false

    private(set) var window: NSWindow?
    private var boxes: [ActionBox] = []
    /// 画面の状態を、いまの設定に合わせ直す処理の一覧
    private var refreshers: [() -> Void] = []
    private(set) var shortcutFields: [ShortcutField] = []
    private var shortcutNote: NSTextField!
    private(set) var tabs: NSTabViewController!
    private static let size = NSSize(width: 620, height: 470)

    func show() {
        if window == nil { build() }
        refresh()
        guard !Self.headless, let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func refresh() { refreshers.forEach { $0() } }

    /// 「ショートカット」のタブを開く
    func showShortcuts() {
        show()
        tabs.selectedTabViewItemIndex = 2
    }

    func windowWillClose(_ notification: Notification) {
        shortcutFields.filter(\.isRecording).forEach { $0.stop(nil) }
    }

    // MARK: 部品

    private func box(_ run: @escaping (NSControl) -> Void) -> ActionBox {
        let b = ActionBox(run)
        boxes.append(b)
        return b
    }

    private func check(_ title: String, tip: String? = nil, indent: Bool = false, enabled: (() -> Bool)? = nil,
                       get: @escaping () -> Bool, set: @escaping (Bool) -> Void) -> NSView {
        let action = box { [weak self] sender in
            set((sender as? NSButton)?.state == .on)
            self?.refresh()   // 許可が無くて入れられなかったときに、チェックを戻す
        }
        let button = NSButton(checkboxWithTitle: title, target: action, action: #selector(ActionBox.fire(_:)))
        button.toolTip = tip
        refreshers.append {
            button.state = get() ? .on : .off
            button.isEnabled = enabled?() ?? true
        }
        guard indent else { return button }
        let row = NSStackView(views: [button])
        row.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)
        return row
    }

    private func popup<T: Equatable>(_ options: @escaping () -> [(String, T)], get: @escaping () -> T, set: @escaping (T) -> Void) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        let action = box { [weak self] sender in
            let list = options()
            let i = (sender as? NSPopUpButton)?.indexOfSelectedItem ?? -1
            if list.indices.contains(i) { set(list[i].1) }
            self?.refresh()
        }
        button.target = action
        button.action = #selector(ActionBox.fire(_:))
        refreshers.append {
            let list = options()
            button.removeAllItems()
            button.addItems(withTitles: list.map(\.0))
            if let i = list.firstIndex(where: { $0.1 == get() }) { button.selectItem(at: i) }
        }
        return button
    }

    private func button(_ title: String, _ run: @escaping () -> Void) -> NSButton {
        let action = box { [weak self] _ in
            run()
            self?.refresh()
        }
        let b = NSButton(title: title, target: action, action: #selector(ActionBox.fire(_:)))
        b.bezelStyle = .rounded
        return b
    }

    private func row(_ label: String, _ views: NSView...) -> NSView {
        let name = NSTextField(labelWithString: label)
        name.alignment = .right
        name.translatesAutoresizingMaskIntoConstraints = false
        name.widthAnchor.constraint(equalToConstant: 150).isActive = true
        let row = NSStackView(views: [name] + views)
        row.orientation = .horizontal
        row.spacing = 10
        return row
    }

    /// 文字を打つ欄。return か、欄から出たときに覚える
    private func field(width: CGFloat, get: @escaping () -> String, set: @escaping (String) -> Void) -> NSTextField {
        let action = box { [weak self] sender in
            set((sender as? NSTextField)?.stringValue.trimmingCharacters(in: .whitespaces) ?? "")
            self?.refresh()
        }
        let f = NSTextField(string: "")
        f.target = action
        f.action = #selector(ActionBox.fire(_:))
        f.translatesAutoresizingMaskIntoConstraints = false
        f.widthAnchor.constraint(equalToConstant: width).isActive = true
        refreshers.append { if f.currentEditor() == nil { f.stringValue = get() } }
        return f
    }

    private func heading(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func note(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = Self.size.width - 64
        return label
    }

    private func pane(_ title: String, symbol: String, _ views: [NSView]) -> NSTabViewItem {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView(frame: NSRect(origin: .zero, size: Self.size))
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -32),
            root.widthAnchor.constraint(equalToConstant: Self.size.width),
            root.heightAnchor.constraint(equalToConstant: Self.size.height),
        ])
        let controller = NSViewController()
        controller.view = root
        controller.title = title
        let item = NSTabViewItem(viewController: controller)
        item.label = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        return item
    }

    private var delegate: AppDelegate? { NSApp.delegate as? AppDelegate }

    // MARK: 組み立て

    private func build() {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        [generalPane(), savePane(), shortcutPane(), popupPane(), shotPane(), recordPane(), recordLookPane(), editorPane(), aboutPane()].forEach(tabs.addTabViewItem)
        self.tabs = tabs

        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "Kiritori の設定"
        window.isReleasedWhenClosed = false
        window.contentViewController = tabs
        window.delegate = self
        window.setContentSize(Self.size)
        self.window = window
    }

    private func generalPane() -> NSTabViewItem {
        let path = NSTextField(labelWithString: "")
        path.lineBreakMode = .byTruncatingMiddle
        path.translatesAutoresizingMaskIntoConstraints = false
        path.widthAnchor.constraint(lessThanOrEqualToConstant: 250).isActive = true
        refreshers.append { path.stringValue = (Prefs.saveDir.path as NSString).abbreviatingWithTildeInPath }
        let days: [(String, Int)] = [1, 3, 7, 14, 30].map { ("\($0)日", $0) }
        return pane("一般", symbol: "gearshape", [
            check("ログイン時に起動する", get: { SMAppService.mainApp.status == .enabled }, set: { [weak self] _ in self?.delegate?.toggleLogin() }),
            check("シャッター音を鳴らす", get: { Prefs.playSound }, set: { Prefs.playSound = $0 }),
            check("メニューバーに印を出す", tip: "隠したあとは、Kiritori をもう一度開くとこの設定画面が出ます。ショートカットはそのまま使えます",
                  get: { Prefs.showMenuBarIcon }, set: { [weak self] on in Prefs.showMenuBarIcon = on; self?.delegate?.applyMenuBarIcon() }),
            check("新しい版を自動で確認する", tip: "新しい版が出たら知らせます。確認のときは GitHub に「いちばん新しい版」を問い合わせるだけで、撮ったものは送りません",
                  get: { Prefs.autoUpdateCheck }, set: { Prefs.autoUpdateCheck = $0; Updater.shared.start() }),
            row("保存先", path, button("変える…") { [weak self] in self?.delegate?.chooseSaveDir() },
                button("開く") { NSWorkspace.shared.open(Prefs.saveDir) }),
            NSView(),
            heading("撮ったあとにすること"),
            check("小窓を出す", tip: "画面の隅に、撮ったものの小さな窓を出します", get: { Prefs.showPopup }, set: { Prefs.showPopup = $0 }),
            check("クリップボードにコピーする", get: { Prefs.autoCopy }, set: { Prefs.autoCopy = $0 }),
            check("保存先へ保存する", get: { Prefs.autoSave }, set: { Prefs.autoSave = $0 }),
            check("編集画面を開く", tip: "画像を撮ったときだけ開きます。録画では開きません", get: { Prefs.openEditorAfterCapture }, set: { Prefs.openEditorAfterCapture = $0 }),
            NSView(),
            row("履歴に残す期間", popup({ days }, get: { Prefs.historyDays }, set: { Prefs.historyDays = $0; cleanHistory() })),
            note("期間を短くすると、それより古いものはすぐ消えます。"),
        ])
    }

    private func savePane() -> NSTabViewItem {
        let formats: [(String, String)] = [("PNG（そのまま）", "png:90"), ("JPEG（きれい）", "jpg:90"), ("JPEG（軽い）", "jpg:70")]
        let example = note("")
        refreshers.append {
            example.stringValue = "例：\(Prefs.shotPrefix) 2026-11-22 14.30.00.\(Prefs.saveFormat)　／　\(Prefs.recPrefix) 2026-11-22 14.30.00.mp4"
        }
        return pane("保存", symbol: "square.and.arrow.down", [
            row("画像の形式", popup({ formats }, get: { Prefs.saveFormat == "jpg" ? "jpg:\(Prefs.jpegQuality >= 80 ? 90 : 70)" : "png:90" },
                                set: { value in
                                    let parts = value.split(separator: ":")
                                    Prefs.saveFormat = String(parts[0])
                                    Prefs.jpegQuality = Int(parts[1]) ?? 90
                                })),
            check("画面の2倍の細かさの画像は、等倍に縮めて保存する", tip: "ファイルが軽くなり、ほかのアプリで大きく表示されなくなります",
                  get: { Prefs.saveAt1x }, set: { Prefs.saveAt1x = $0 }),
            note("形式と細かさは、保存先フォルダへ保存するときだけ変わります。小窓・履歴・コピー・ドラッグで渡す画像は PNG のままです。"),
            NSView(),
            row("スクショの名前", field(width: 150, get: { Prefs.shotPrefix }, set: { Prefs.shotPrefix = $0 })),
            row("録画の名前", field(width: 150, get: { Prefs.recPrefix }, set: { Prefs.recPrefix = $0 })),
            example,
            note("名前のうしろに、撮った日付と時刻が付きます。空にすると最初の名前に戻ります。"),
        ])
    }

    private func shortcutPane() -> NSTabViewItem {
        shortcutNote = note(" ")
        shortcutNote.textColor = .systemOrange
        var views: [NSView] = []
        for spec in HotKeys.specs {
            let field = ShortcutField(spec: spec)
            field.onChange = { [weak self] message in
                self?.shortcutNote.stringValue = message ?? ShortcutConflicts.settingsNote() ?? " "
                self?.shortcutFields.forEach { $0.refresh() }
                self?.delegate?.refreshMenuShortcuts()
            }
            shortcutFields.append(field)
            views.append(row(spec.title, field))
        }
        views.append(shortcutNote)
        views.append(row("", button("最初の設定に戻す") { [weak self] in
            HotKeys.specs.forEach { Prefs.resetHotKey($0.name) }
            HotKeys.registerAll()
            self?.shortcutFields.forEach { $0.refresh() }
            self?.shortcutNote.stringValue = ShortcutConflicts.settingsNote() ?? " "
            self?.delegate?.refreshMenuShortcuts()
        }))
        views.append(note("欄を押してから、使いたいキーの組み合わせを押します。delete で「なし」、esc でやめる。最初の設定は ⌘⇧ と数字です。macOS の標準のスクリーンショットと同じ組み合わせにするときは、システム設定のキーボード → キーボードショートカット → スクリーンショットで、macOS 側を先に切っておきます。"))
        refreshers.append { [weak self] in
            self?.shortcutFields.forEach { $0.refresh() }
            // 設定画面を開いたときにも、macOS 標準との重なりを出す
            if self?.shortcutFields.contains(where: \.isRecording) == false { self?.shortcutNote.stringValue = ShortcutConflicts.settingsNote() ?? " " }
        }
        return pane("ショートカット", symbol: "keyboard", views)
    }

    private func popupPane() -> NSTabViewItem {
        let sides: [(String, String)] = [("左下", "left"), ("右下", "right")]
        let waits: [(String, Int)] = [("閉じない", 0), ("5秒", 5), ("10秒", 10), ("30秒", 30), ("60秒", 60)]
        return pane("小窓", symbol: "rectangle.inset.bottomleft.filled", [
            row("出す場所", popup({ sides }, get: { Prefs.popupSide }, set: { Prefs.popupSide = $0; PopupController.shared.applySettings() })),
            row("自動で閉じる", popup({ waits }, get: { Prefs.popupAutoClose }, set: { Prefs.popupAutoClose = $0 })),
            note("閉じても、撮ったものは履歴に残ります。カーソルを乗せている間と、編集している間は閉じません。"),
            check("ほかのアプリへドラッグで渡したら閉じる", get: { Prefs.popupCloseAfterDrag }, set: { Prefs.popupCloseAfterDrag = $0 }),
        ])
    }

    private func shotPane() -> NSTabViewItem {
        let seconds: [(String, Int)] = [3, 5, 10].map { ("\($0)秒", $0) }
        let backdrops: () -> [(String, String)] = {
            var list: [(String, String)] = [("付けない", ""), ("壁紙", "wallpaper")]
            list += BackgroundStore.presets.map { ("保存した背景：\($0.name)", $0.name) }
            let current = Prefs.windowBackdrop
            if !list.contains(where: { $0.1 == current }) { list.append(("（\(current)：削除済み）", current)) }
            return list
        }
        return pane("スクショ", symbol: "camera.viewfinder", [
            check("範囲は画面を止めて選ぶ", tip: "切ると、macOS 標準の選び方になります", get: { Prefs.ownAreaCapture }, set: { Prefs.ownAreaCapture = $0 }),
            check("拡大鏡を出す", indent: true, enabled: { Prefs.ownAreaCapture }, get: { Prefs.showMagnifier }, set: { Prefs.showMagnifier = $0 }),
            check("十字線を出す", indent: true, enabled: { Prefs.ownAreaCapture }, get: { Prefs.showCrosshair }, set: { Prefs.showCrosshair = $0 }),
            check("カーソルを写す", get: { Prefs.shotCursor }, set: { Prefs.shotCursor = $0 }),
            check("ウィンドウに影を付ける", get: { Prefs.windowShadow }, set: { Prefs.windowShadow = $0 }),
            row("ウィンドウの後ろ", popup(backdrops, get: { Prefs.windowBackdrop }, set: { Prefs.windowBackdrop = $0 })),
            note("「ウィンドウを撮る」で撮ったときだけ、後ろに壁紙か背景を敷きます。付けたあとでも、編集画面の「背景」で外したり変えたりできます。"),
            row("セルフタイマー", popup({ seconds }, get: { Prefs.timerSeconds }, set: { Prefs.timerSeconds = $0 })),
            NSView(),
            heading("オールインワン"),
            check("前に選んだ範囲を最初から出す", get: { Prefs.allInOneRemember }, set: { Prefs.allInOneRemember = $0 }),
        ])
    }

    private func recordPane() -> NSTabViewItem {
        let microphones: () -> [(String, String)] = {
            var list: [(String, String)] = [("入れない", MicrophoneChoice.none), ("Mac の設定に合わせる", MicrophoneChoice.system)]
            let devices = audioInputDevices()
            list += devices.map { ($0.localizedName, $0.uniqueID) }
            let current = Prefs.microphoneChoice
            if !list.contains(where: { $0.1 == current }) { list.append(("（選んであるマイクがつながっていません）", current)) }
            return list
        }
        let dndNote = note("")
        refreshers.append {
            dndNote.stringValue = Prefs.recordDND
                ? "「ショートカット」アプリに「\(FocusSwitch.onName)」「\(FocusSwitch.offName)」の2つを用意してあるときだけ切り替わります。"
                : "「ショートカット」アプリに、集中モードを入れるものと切るものを2つ用意して使います（作り方は手順書にあります）。"
        }
        return pane("録画", symbol: "record.circle", [
            check("パソコンの音を入れる", tip: "macOS 15 以上で使えます", get: { Prefs.recordSystemAudio }, set: { Prefs.recordSystemAudio = $0 }),
            row("マイク", popup(microphones, get: { Prefs.microphoneChoice }, set: { Prefs.microphoneChoice = $0 })),
            row("コマ数", popup({ [("60コマ（なめらか）", 60), ("30コマ（軽い）", 30)] }, get: { Prefs.recordFPS }, set: { Prefs.recordFPS = $0 })),
            row("細かさ", popup({ [("画面と同じ（きれい）", false), ("等倍に縮める（軽い）", true)] }, get: { Prefs.recordScale1x }, set: { Prefs.recordScale1x = $0 })),
            row("始める前に数える", popup({ [("数えない", 0), ("3秒", 3), ("5秒", 5), ("10秒", 10)] }, get: { Prefs.recordCountdown }, set: { Prefs.recordCountdown = $0 })),
            check("録る範囲の外を暗くする", tip: "暗くした部分は録画には写りません。範囲を決めて録るときだけ", get: { Prefs.recordDim }, set: { Prefs.recordDim = $0 }),
            check("録画中はおやすみモードにする", get: { Prefs.recordDND }, set: { on in
                if on, !FocusSwitch.isReady {
                    ToastHUD.show("ショートカットが2つ要ります", detail: "「\(FocusSwitch.onName)」と「\(FocusSwitch.offName)」")
                }
                Prefs.recordDND = on
            }),
            dndNote,
            note("一時停止は、録画中にメニューバーに出る ⏸ のボタンか、「ショートカット」のタブで決めたキーで行います。クリック・キー・カメラの出し方は「録画の表示」のタブにあります。"),
        ])
    }

    private func recordLookPane() -> NSTabViewItem {
        let sizes: [(String, Int)] = [("小", 0), ("中", 1), ("大", 2)]
        let colors: [(String, String)] = ClickHighlighter.colors.map { ($0.name, $0.key) }
        return pane("録画の表示", symbol: "eye", [
            check("カーソルを写す", get: { Prefs.showCursor }, set: { Prefs.showCursor = $0 }),
            NSView(),
            check("クリックした場所を強調する", get: { Prefs.highlightClicks }, set: { Prefs.highlightClicks = $0 }),
            row("輪の色", popup({ colors }, get: { Prefs.clickColor }, set: { Prefs.clickColor = $0 })),
            row("輪の大きさ", popup({ sizes }, get: { Prefs.clickSize }, set: { Prefs.clickSize = $0 })),
            NSView(),
            check("押したキーを表示する", tip: "初めて入れるときに、macOS が「入力監視」の許可を求めます",
                  get: { Prefs.showKeystrokes }, set: { [weak self] _ in self?.delegate?.toggleShowKeystrokes() }),
            check("ふつうのキーも表示する（切ると ⌘ などを使う操作だけ）", indent: true, enabled: { Prefs.showKeystrokes },
                  get: { Prefs.keystrokesAll }, set: { Prefs.keystrokesAll = $0 }),
            row("キーの大きさと場所", popup({ sizes }, get: { Prefs.keySize }, set: { Prefs.keySize = $0 }),
                popup({ [("下", "bottom"), ("上", "top")] }, get: { Prefs.keyPosition }, set: { Prefs.keyPosition = $0 })),
            NSView(),
            check("カメラを重ねる", tip: "初めて入れるときに、macOS がカメラの許可を求めます",
                  get: { Prefs.showCamera }, set: { [weak self] _ in self?.delegate?.toggleShowCamera() }),
            row("カメラの形と大きさ", popup({ [("丸", "circle"), ("四角", "rounded")] }, get: { Prefs.cameraShape }, set: { Prefs.cameraShape = $0 }),
                popup({ sizes }, get: { Prefs.cameraSize }, set: { Prefs.cameraSize = $0 })),
            row("カメラを出す隅", popup({ [("左下", "bl"), ("右下", "br"), ("左上", "tl"), ("右上", "tr")] }, get: { Prefs.cameraCorner }, set: { Prefs.cameraCorner = $0 }),
                check("鏡のように映す", get: { Prefs.cameraMirror }, set: { Prefs.cameraMirror = $0 })),
            note("カメラは録画中にドラッグで動かせます。同じ切り替えの一部は、録画の範囲を選ぶときの帯にも出ます。"),
        ])
    }

    private func editorPane() -> NSTabViewItem {
        let presets: () -> [(String, String)] = {
            var list: [(String, String)] = [("付けない", "")]
            list += BackgroundStore.presets.map { ($0.name, $0.name) }
            let current = BackgroundStore.autoPreset
            if !list.contains(where: { $0.1 == current }) { list.append(("（\(current)：削除済み）", current)) }
            return list
        }
        return pane("編集", symbol: "pencil.tip.crop.circle", [
            check("余白を自動で広げる", tip: "画像の外へはみ出したものが全部入るように、まわりに透明の余白を足します",
                  get: { Prefs.editorAutoExpand }, set: { Prefs.editorAutoExpand = $0 }),
            note("切ると、画像の外へはみ出した分は縁で切れます。編集画面の「画像」のメニューでも切り替えられます。"),
            NSView(),
            row("撮ったら背景を付ける", popup(presets, get: { BackgroundStore.autoPreset }, set: { BackgroundStore.autoPreset = $0 })),
            note("編集画面の「背景」で作って保存した組み合わせから選びます。付けたあとでも、編集画面で外したり変えたりできます。"),
        ])
    }

    private func aboutPane() -> NSTabViewItem {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let name = NSTextField(labelWithString: "Kiritori \(version)")
        name.font = .systemFont(ofSize: 18, weight: .semibold)
        let logFile = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/Kiritori.log")
        return pane("情報", symbol: "info.circle", [
            name,
            note("自分用のスクリーンショットアプリです。撮ったものはこの Mac の中だけに置かれ、どこにも送られません。新しい版の確認のときだけ GitHub に問い合わせます。"),
            row("更新", button("更新を確認する") { Updater.shared.check(manual: true) }, button("配布ページを開く") { NSWorkspace.shared.open(Updater.pageURL) }),
            row("履歴の置き場所", button("フォルダを開く") { NSWorkspace.shared.open(Prefs.historyDir) }),
            row("動作の記録", button("ログを開く") { NSWorkspace.shared.open(logFile) }),
        ])
    }

    // MARK: 動作確認用

    /// 指定のタブを画像にする。
    func snapshot(tab index: Int, to url: URL) {
        guard let window, tabs.tabViewItems.indices.contains(index) else { return }
        tabs.selectedTabViewItemIndex = index
        refresh()
        _ = window
        guard let view = tabs.tabViewItems[index].viewController?.view else { return }
        view.frame = NSRect(origin: .zero, size: Self.size)
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        // 文字が見えるよう、窓の地の色を敷いてから重ねる
        let image = NSImage(size: view.bounds.size)
        image.lockFocus()
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            view.bounds.fill()
        }
        rep.draw(in: view.bounds)
        image.unlockFocus()
        if let tiff = image.tiffRepresentation, let out = NSBitmapImageRep(data: tiff) {
            try? out.representation(using: .png, properties: [:])?.write(to: url)
        }
    }
}
