// Kiritori — 自分用のスクリーンショットアプリ
// 撮影そのものは macOS 標準の /usr/sbin/screencapture に任せ、
// ショートカット・撮った直後の小窓・コピー・保存・ドラッグを受け持つ。

import AppKit
import AVFoundation
import Carbon.HIToolbox
import ServiceManagement

// MARK: - ログ

let logURL: URL = {
    let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("Kiritori.log")
}()

func log(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    let line = "\(stamp) \(message)\n"
    FileHandle.standardError.write(line.data(using: .utf8)!)
    if let handle = try? FileHandle(forWritingTo: logURL) {
        handle.seekToEndOfFile()
        handle.write(line.data(using: .utf8)!)
        try? handle.close()
    } else {
        try? line.data(using: .utf8)!.write(to: logURL)
    }
}

// MARK: - 設定

enum Prefs {
    static let d = UserDefaults.standard

    static var saveDir: URL {
        get {
            if let p = d.string(forKey: "saveDir"), FileManager.default.fileExists(atPath: p) {
                return URL(fileURLWithPath: p)
            }
            return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        }
        set { d.set(newValue.path, forKey: "saveDir") }
    }
    static var autoCopy: Bool {
        get { d.bool(forKey: "autoCopy") }
        set { d.set(newValue, forKey: "autoCopy") }
    }
    static var autoSave: Bool {
        get { d.bool(forKey: "autoSave") }
        set { d.set(newValue, forKey: "autoSave") }
    }
    static var playSound: Bool {
        get { d.object(forKey: "playSound") == nil ? true : d.bool(forKey: "playSound") }
        set { d.set(newValue, forKey: "playSound") }
    }

    /// 録画にパソコンの音を入れる（macOS 15 以上）
    static var recordSystemAudio: Bool {
        get { d.object(forKey: "recordSystemAudio") == nil ? true : d.bool(forKey: "recordSystemAudio") }
        set { d.set(newValue, forKey: "recordSystemAudio") }
    }
    /// 録画に入れるマイク。MicrophoneChoice.none／.system／マイクの固有の名前
    static var microphoneChoice: String {
        get {
            if let v = d.string(forKey: "microphoneChoice") { return v }
            return d.bool(forKey: "recordMicrophone") ? MicrophoneChoice.system : MicrophoneChoice.none   // 0.6.0 の設定を引き継ぐ
        }
        set { d.set(newValue, forKey: "microphoneChoice") }
    }
    /// マイクを切る前に選んでいたもの（帯のマイクのボタンで入れ直すときに使う）
    static var lastMicrophoneChoice: String {
        get { d.string(forKey: "lastMicrophoneChoice") ?? MicrophoneChoice.system }
        set { d.set(newValue, forKey: "lastMicrophoneChoice") }
    }
    /// 録画でクリックした場所に輪を出す
    static var highlightClicks: Bool {
        get { d.object(forKey: "highlightClicks") == nil ? true : d.bool(forKey: "highlightClicks") }
        set { d.set(newValue, forKey: "highlightClicks") }
    }
    /// 録画中に押したキーを画面に出す
    static var showKeystrokes: Bool {
        get { d.bool(forKey: "showKeystrokes") }
        set { d.set(newValue, forKey: "showKeystrokes") }
    }
    /// キー表示で、⌘ などを使わないふつうのキーも出す（切ってあれば、打った文章は出ない）
    static var keystrokesAll: Bool {
        get { d.bool(forKey: "keystrokesAll") }
        set { d.set(newValue, forKey: "keystrokesAll") }
    }
    /// 録画にカメラの映像を重ねる
    static var showCamera: Bool {
        get { d.bool(forKey: "showCamera") }
        set { d.set(newValue, forKey: "showCamera") }
    }
    /// 録画にカーソルを写す
    static var showCursor: Bool {
        get { d.object(forKey: "showCursor") == nil ? true : d.bool(forKey: "showCursor") }
        set { d.set(newValue, forKey: "showCursor") }
    }
    /// 録画の形式。"mp4" か "gif"
    static var recordFormat: String {
        get { d.string(forKey: "recordFormat") == "gif" ? "gif" : "mp4" }
        set { d.set(newValue, forKey: "recordFormat") }
    }

    /// 範囲の撮影で、自前の幕（画面を止める・拡大鏡・十字線）を使う。切ると macOS 標準の選び方になる
    static var ownAreaCapture: Bool {
        get { d.object(forKey: "ownAreaCapture") == nil ? true : d.bool(forKey: "ownAreaCapture") }
        set { d.set(newValue, forKey: "ownAreaCapture") }
    }
    static var showMagnifier: Bool {
        get { d.object(forKey: "showMagnifier") == nil ? true : d.bool(forKey: "showMagnifier") }
        set { d.set(newValue, forKey: "showMagnifier") }
    }
    static var showCrosshair: Bool {
        get { d.object(forKey: "showCrosshair") == nil ? true : d.bool(forKey: "showCrosshair") }
        set { d.set(newValue, forKey: "showCrosshair") }
    }
    /// セルフタイマーの秒数
    static var timerSeconds: Int {
        get { let v = d.integer(forKey: "timerSeconds"); return v > 0 ? v : 5 }
        set { d.set(newValue, forKey: "timerSeconds") }
    }
    /// ウィンドウを撮るときに影を付ける
    static var windowShadow: Bool {
        get { d.object(forKey: "windowShadow") == nil ? true : d.bool(forKey: "windowShadow") }
        set { d.set(newValue, forKey: "windowShadow") }
    }
    /// 編集で、はみ出したものに合わせて余白を自動で広げる
    static var editorAutoExpand: Bool {
        get { d.object(forKey: "editorAutoExpand") == nil ? true : d.bool(forKey: "editorAutoExpand") }
        set { d.set(newValue, forKey: "editorAutoExpand") }
    }

    /// 最後に範囲を決めて撮った場所（全画面を通した座標）。「同じ範囲をもう一度撮る」で使う
    static var lastAreaRect: NSRect? {
        get {
            guard let v = d.array(forKey: "lastAreaRect") as? [Double], v.count == 4 else { return nil }
            return NSRect(x: v[0], y: v[1], width: v[2], height: v[3])
        }
        set { if let r = newValue { d.set([r.minX, r.minY, r.width, r.height].map(Double.init), forKey: "lastAreaRect") } }
    }
    /// 保存先へ保存するときの画像の形式。"png" か "jpg"
    static var saveFormat: String {
        get { d.string(forKey: "saveFormat") == "jpg" ? "jpg" : "png" }
        set { d.set(newValue, forKey: "saveFormat") }
    }
    /// JPEG の画質（パーセント）
    static var jpegQuality: Int {
        get { let v = d.integer(forKey: "jpegQuality"); return v > 0 ? v : 90 }
        set { d.set(newValue, forKey: "jpegQuality") }
    }
    /// 保存するとき、画面の2倍の細かさの画像を等倍に縮める
    static var saveAt1x: Bool {
        get { d.bool(forKey: "saveAt1x") }
        set { d.set(newValue, forKey: "saveAt1x") }
    }
    /// 保存するファイルの名前の頭に付ける言葉
    static var shotPrefix: String {
        get { let v = d.string(forKey: "shotPrefix") ?? ""; return v.isEmpty ? "スクショ" : v }
        set { d.set(newValue, forKey: "shotPrefix") }
    }
    static var recPrefix: String {
        get { let v = d.string(forKey: "recPrefix") ?? ""; return v.isEmpty ? "録画" : v }
        set { d.set(newValue, forKey: "recPrefix") }
    }
    /// 録画の1秒あたりのコマ数
    static var recordFPS: Int {
        get { d.integer(forKey: "recordFPS") == 30 ? 30 : 60 }
        set { d.set(newValue, forKey: "recordFPS") }
    }
    private static func int(_ key: String, _ fallback: Int, in range: ClosedRange<Int>) -> Int {
        d.object(forKey: key) == nil ? fallback : min(range.upperBound, max(range.lowerBound, d.integer(forKey: key)))
    }
    private static func choice(_ key: String, _ options: [String]) -> String {
        let v = d.string(forKey: key) ?? ""
        return options.contains(v) ? v : options[0]
    }
    /// 録画を、画面の2倍の細かさのままにせず等倍に縮める（ファイルが軽くなる）
    static var recordScale1x: Bool {
        get { d.bool(forKey: "recordScale1x") }
        set { d.set(newValue, forKey: "recordScale1x") }
    }
    /// 録画を始める前に数える秒数。0 なら数えない
    static var recordCountdown: Int {
        get { int("recordCountdown", 0, in: 0...10) }
        set { d.set(newValue, forKey: "recordCountdown") }
    }
    /// 録画中、録る範囲の外を暗くする（録画には写らない）
    static var recordDim: Bool {
        get { d.bool(forKey: "recordDim") }
        set { d.set(newValue, forKey: "recordDim") }
    }
    /// 録画中、おやすみモードにする（macOS の「ショートカット」に用意した2つを呼ぶ）
    static var recordDND: Bool {
        get { d.bool(forKey: "recordDND") }
        set { d.set(newValue, forKey: "recordDND") }
    }
    /// クリックの輪の色。"yellow" "red" "blue" "green" "white"
    static var clickColor: String {
        get { choice("clickColor", ["yellow", "red", "blue", "green", "white"]) }
        set { d.set(newValue, forKey: "clickColor") }
    }
    /// 輪・キー表示・カメラの大きさ。0=小 1=中 2=大
    static var clickSize: Int {
        get { int("clickSize", 1, in: 0...2) }
        set { d.set(newValue, forKey: "clickSize") }
    }
    static var keySize: Int {
        get { int("keySize", 1, in: 0...2) }
        set { d.set(newValue, forKey: "keySize") }
    }
    /// キー表示を出す場所。"bottom" か "top"
    static var keyPosition: String {
        get { choice("keyPosition", ["bottom", "top"]) }
        set { d.set(newValue, forKey: "keyPosition") }
    }
    static var cameraSize: Int {
        get { int("cameraSize", 1, in: 0...2) }
        set { d.set(newValue, forKey: "cameraSize") }
    }
    /// カメラの形。"circle" か "rounded"
    static var cameraShape: String {
        get { choice("cameraShape", ["circle", "rounded"]) }
        set { d.set(newValue, forKey: "cameraShape") }
    }
    /// カメラを最初に出す隅。"bl" "br" "tl" "tr"
    static var cameraCorner: String {
        get { choice("cameraCorner", ["bl", "br", "tl", "tr"]) }
        set { d.set(newValue, forKey: "cameraCorner") }
    }
    /// カメラを鏡のように左右反転する
    static var cameraMirror: Bool {
        get { d.object(forKey: "cameraMirror") == nil ? true : d.bool(forKey: "cameraMirror") }
        set { d.set(newValue, forKey: "cameraMirror") }
    }
    /// メニューバーの印を出す
    static var showMenuBarIcon: Bool {
        get { d.object(forKey: "showMenuBarIcon") == nil ? true : d.bool(forKey: "showMenuBarIcon") }
        set { d.set(newValue, forKey: "showMenuBarIcon") }
    }
    /// ウィンドウを撮ったときに、後ろへ付ける背景。"" は付けない・"wallpaper" は壁紙・それ以外は保存した背景の組み合わせの名前
    static var windowBackdrop: String {
        get { d.string(forKey: "windowBackdrop") ?? "" }
        set { d.set(newValue, forKey: "windowBackdrop") }
    }
    /// デスクトップのアイコンを隠したままにする
    static var hideDesktopIcons: Bool {
        get { d.bool(forKey: "hideDesktopIcons") }
        set { d.set(newValue, forKey: "hideDesktopIcons") }
    }

    // 撮ったあとにすること
    /// 撮ったら左下（か右下）に小窓を出す
    static var showPopup: Bool {
        get { d.object(forKey: "showPopup") == nil ? true : d.bool(forKey: "showPopup") }
        set { d.set(newValue, forKey: "showPopup") }
    }
    /// 撮ったらすぐ編集画面を開く（画像だけ）
    static var openEditorAfterCapture: Bool {
        get { d.bool(forKey: "openEditorAfterCapture") }
        set { d.set(newValue, forKey: "openEditorAfterCapture") }
    }
    /// 小窓を出す側。"left" か "right"
    static var popupSide: String {
        get { d.string(forKey: "popupSide") == "right" ? "right" : "left" }
        set { d.set(newValue, forKey: "popupSide") }
    }
    /// 小窓を自動で閉じるまでの秒数。0 なら閉じない
    static var popupAutoClose: Int {
        get { max(0, d.integer(forKey: "popupAutoClose")) }
        set { d.set(newValue, forKey: "popupAutoClose") }
    }
    /// 小窓からほかのアプリへドラッグで渡したら、小窓を閉じる
    static var popupCloseAfterDrag: Bool {
        get { d.object(forKey: "popupCloseAfterDrag") == nil ? true : d.bool(forKey: "popupCloseAfterDrag") }
        set { d.set(newValue, forKey: "popupCloseAfterDrag") }
    }
    /// 履歴を残す日数
    static var historyDays: Int {
        get { let v = d.integer(forKey: "historyDays"); return v > 0 ? v : 7 }
        set { d.set(newValue, forKey: "historyDays") }
    }
    /// スクショにカーソルを写す
    static var shotCursor: Bool {
        get { d.bool(forKey: "shotCursor") }
        set { d.set(newValue, forKey: "shotCursor") }
    }
    /// オールインワンで、前に選んだ範囲を最初から出す
    static var allInOneRemember: Bool {
        get { d.object(forKey: "allInOneRemember") == nil ? true : d.bool(forKey: "allInOneRemember") }
        set { d.set(newValue, forKey: "allInOneRemember") }
    }
    /// オールインワンで最後に選んだ範囲（全画面を通した座標）
    static var allInOneLastRect: NSRect? {
        get {
            guard let v = d.array(forKey: "allInOneLastRect") as? [Double], v.count == 4 else { return nil }
            return NSRect(x: v[0], y: v[1], width: v[2], height: v[3])
        }
        set {
            if let r = newValue { d.set([r.minX, r.minY, r.width, r.height].map(Double.init), forKey: "allInOneLastRect") }
            else { d.removeObject(forKey: "allInOneLastRect") }
        }
    }

    /// 撮った画像の一時置き場。小窓を閉じても、決めた日数（既定は7日）は残る。
    static var historyDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kiritori/history")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// ショートカット。`defaults write local.kiritori hk.area.key -int 21` のように変えられる。
    static func hotKey(_ name: String, defaultKey: Int) -> (key: UInt32, mods: UInt32) {
        let key = d.object(forKey: "hk.\(name).key") == nil ? defaultKey : d.integer(forKey: "hk.\(name).key")
        let mods = d.object(forKey: "hk.\(name).mods") == nil ? (cmdKey | shiftKey) : d.integer(forKey: "hk.\(name).mods")
        return (UInt32(max(0, key)), UInt32(max(0, mods)))
    }
    static func setHotKey(_ name: String, key: UInt32, mods: UInt32) {
        d.set(Int(key), forKey: "hk.\(name).key")
        d.set(Int(mods), forKey: "hk.\(name).mods")
    }
    static func resetHotKey(_ name: String) {
        d.removeObject(forKey: "hk.\(name).key")
        d.removeObject(forKey: "hk.\(name).mods")
    }
}

func timestampName() -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd HH.mm.ss"
    return f.string(from: Date())
}

// MARK: - グローバルショートカット（Carbon）

var hotKeyActions: [UInt32: () -> Void] = [:]
var hotKeyRefs: [EventHotKeyRef] = []

func installHotKeyHandler() {
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
        var hk = EventHotKeyID()
        GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                          nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
        let id = hk.id
        DispatchQueue.main.async { hotKeyActions[id]?() }
        return noErr
    }, 1, &spec, nil, nil)
}

@discardableResult
func registerHotKey(id: UInt32, key: UInt32, mods: UInt32, action: @escaping () -> Void) -> Bool {
    var ref: EventHotKeyRef?
    let hkID = EventHotKeyID(signature: OSType(0x4B52_5452), id: id) // 'KRTR'
    let status = RegisterEventHotKey(key, mods, hkID, GetApplicationEventTarget(), 0, &ref)
    if status == noErr, let ref {
        hotKeyRefs.append(ref)
        hotKeyActions[id] = action
        return true
    }
    log("ショートカット登録失敗 id=\(id) key=\(key) mods=\(mods) status=\(status)")
    return false
}

func modifierFlags(fromCarbon mods: UInt32) -> NSEvent.ModifierFlags {
    var flags: NSEvent.ModifierFlags = []
    if mods & UInt32(cmdKey) != 0 { flags.insert(.command) }
    if mods & UInt32(shiftKey) != 0 { flags.insert(.shift) }
    if mods & UInt32(optionKey) != 0 { flags.insert(.option) }
    if mods & UInt32(controlKey) != 0 { flags.insert(.control) }
    return flags
}

/// ショートカットを「使わない」にしたときにキーの番号として入れておく値
let hotKeyDisabled: UInt32 = 0xFFFF

/// ショートカットに使えるキーと、その表示名
let keyNames: [Int: String] = [
    kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4", kVK_ANSI_5: "5",
    kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9", kVK_ANSI_0: "0",
    kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G",
    kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L", kVK_ANSI_M: "M", kVK_ANSI_N: "N",
    kVK_ANSI_O: "O", kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T", kVK_ANSI_U: "U",
    kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X", kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
    kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
    kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    kVK_Space: "space",
]

/// メニューに出すキー（1文字のものだけ）
func keyCharacter(forKeyCode code: UInt32) -> String {
    guard let name = keyNames[Int(code)], name.count == 1 else { return "" }
    return name.lowercased()
}

/// 「⌃⌘4」のような表示
func shortcutText(key: UInt32, mods: UInt32) -> String {
    guard key != hotKeyDisabled, let name = keyNames[Int(key)] else { return "なし" }
    var text = ""
    if mods & UInt32(controlKey) != 0 { text += "⌃" }
    if mods & UInt32(optionKey) != 0 { text += "⌥" }
    if mods & UInt32(shiftKey) != 0 { text += "⇧" }
    if mods & UInt32(cmdKey) != 0 { text += "⌘" }
    return text + name
}

/// ショートカットの一覧。設定画面で変えたら登録し直す。
struct HotKeySpec {
    let id: UInt32
    let name: String
    let title: String
    let defaultKey: Int
    let action: () -> Void
}

enum HotKeys {
    static var specs: [HotKeySpec] = []
    /// --no-hotkeys のときは登録しない
    static var enabled = true
    /// 登録できたかどうか（名前ごと）
    private(set) static var status: [String: Bool] = [:]

    static func unregisterAll() {
        hotKeyRefs.forEach { UnregisterEventHotKey($0) }
        hotKeyRefs = []
        hotKeyActions = [:]
    }

    @discardableResult
    static func registerAll() -> [String: Bool] {
        unregisterAll()
        status = [:]
        guard enabled else { return status }
        for spec in specs {
            let hk = Prefs.hotKey(spec.name, defaultKey: spec.defaultKey)
            guard hk.key != hotKeyDisabled else { continue }
            status[spec.name] = registerHotKey(id: spec.id, key: hk.key, mods: hk.mods, action: spec.action)
        }
        return status
    }
}

// MARK: - 撮影

enum CaptureMode: String {
    case area, full, window
}

func screenUnderMouse() -> NSScreen {
    let p = NSEvent.mouseLocation
    return NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
}

/// screencapture の -D に渡す番号（1がメインディスプレイ）。
func displayIndex(for screen: NSScreen) -> Int {
    guard let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return 1 }
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetActiveDisplayList(count, &ids, &count)
    if let i = ids.firstIndex(of: num.uint32Value) { return i + 1 }
    return 1
}

final class CaptureController {
    static let shared = CaptureController()
    private var busy = false

    func capture(_ mode: CaptureMode) {
        // 範囲選びの幕が出ている間にもう一度ショートカットを押したら、幕を閉じる（幕が残ってしまったときの逃げ道）
        if let selector = shotSelector {
            selector.close()
            shotSelector = nil
            busy = false
            return
        }
        guard !busy, ensurePermission() else { return }
        if mode == .area, Prefs.ownAreaCapture {   // 画面を止めて、拡大鏡つきの幕で選ぶ
            captureAreaWithOverlay()
            return
        }
        busy = true
        let source = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let out = Prefs.historyDir.appendingPathComponent("shot \(timestampName()).png")
        var args: [String] = []
        if !Prefs.playSound { args.append("-x") }
        if Prefs.shotCursor { args.append("-C") }
        switch mode {
        case .area: args += ["-i"]
        case .window: args += Prefs.windowShadow ? ["-i", "-W"] : ["-i", "-W", "-o"]   // -o＝影なし
        case .full: args += ["-D", String(displayIndex(for: screenUnderMouse()))]
        }
        args.append(out.path)

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = args
        task.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                self?.busy = false
                let size = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0
                log("撮影 mode=\(mode.rawValue) exit=\(proc.terminationStatus) size=\(size)")
                guard size > 0 else { return } // Escで取り消したときはファイルができない
                self?.didCapture(out, source: source, window: mode == .window)
            }
        }
        do {
            try task.run()
        } catch {
            busy = false
            log("screencapture を起動できない: \(error)")
        }
    }

    // MARK: 自前の幕で撮る

    private var shotSelector: ShotSelector?
    /// 撮った場所（全画面を通した座標）。ピン留めで同じ場所へ重ねるのに使う
    private var captureRects: [String: NSRect] = [:]
    func captureRect(for file: URL) -> NSRect? { captureRects[file.lastPathComponent] }
    private let countdown = CountdownHUD()
    private var scrollSession: AnyObject?

    private func playShutter() {
        guard Prefs.playSound else { return }
        let path = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif"
        (NSSound(contentsOfFile: path, byReference: true) ?? NSSound(named: "Tink"))?.play()
    }

    /// 切り出した画像を履歴に書いて、小窓に出す。scale は1ポイントあたりのピクセル数。
    func saveCaptured(_ image: CGImage, scale: CGFloat, source: String?, kind: String, rect: NSRect? = nil) {
        let out = Prefs.historyDir.appendingPathComponent("shot \(timestampName()).png")
        if let rect { captureRects[out.lastPathComponent] = rect; Prefs.lastAreaRect = rect }
        guard let data = pngData(image, dpi: 72 * scale), (try? data.write(to: out)) != nil else {
            log("撮影 mode=\(kind) 書き出しに失敗")
            NSSound.beep()
            return
        }
        log("撮影 mode=\(kind) \(image.width)x\(image.height) size=\(data.count)")
        playShutter()
        didCapture(out, source: source)
    }

    /// 範囲を選んで撮る（画面を止めて、拡大鏡と十字線で選ぶ）。
    func captureAreaWithOverlay() {
        busy = true
        let source = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        // 画面を止めるのに 0.2 秒ほどかかるので、その間は先に仮の幕（暗くする＋十字の線）を出しておく
        // （カーソルも写す設定のときは、十字のカーソルが写ってしまうので出さない）
        let pressed = Date()
        let pending: PendingCrosshair? = Prefs.shotCursor ? nil : PendingCrosshair()
        pending?.show()
        let pendingMs = Int(Date().timeIntervalSince(pressed) * 1000)
        captureAllScreens(hide: pending?.panels ?? []) { [weak self] shots in
            defer {
                pending?.close()
                log("範囲選び: 仮の幕 \(pending == nil ? "なし" : "\(pendingMs)ms")／本物の幕 \(Int(Date().timeIntervalSince(pressed) * 1000))ms")
            }
            guard let self else { return }
            guard !shots.isEmpty else {
                self.busy = false
                log("画面を止められなかった")
                NSSound.beep()
                return
            }
            let selector = ShotSelector(frozen: shots, hint: "ドラッグで撮る範囲を選ぶ　／　esc か右クリックでやめる", onDone: { [weak self] rect, screen, cropped in
                self?.shotSelector = nil
                self?.busy = false
                guard let cropped else { return }
                self?.saveCaptured(cropped, scale: screen.backingScaleFactor, source: source, kind: "area", rect: rect)
            }, onCancel: { [weak self] in
                self?.shotSelector = nil
                self?.busy = false
            })
            self.shotSelector = selector
            selector.show()
        }
    }

    /// セルフタイマー：範囲を決めて、数秒待ってから撮る（メニューを開いた状態などを撮るため）。
    func captureWithTimer() {
        guard !busy, ensurePermission() else { return }
        busy = true
        let source = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let seconds = Prefs.timerSeconds
        let hint = "ドラッグで範囲を選ぶ（クリックだけならその画面全体）。\(seconds)秒後に撮ります　／　esc か右クリックでやめる"
        let selector = ShotSelector(frozen: [], hint: hint, onDone: { [weak self] rect, screen, _ in
            guard let self else { return }
            self.shotSelector = nil
            let area = rect ?? screen.frame
            self.countdown.start(seconds: seconds, center: NSPoint(x: area.midX, y: area.midY)) { [weak self] in
                self?.runScreencapture(rect: rect, screen: screen, source: source, kind: "timer")
            }
        }, onCancel: { [weak self] in
            self?.shotSelector = nil
            self?.busy = false
        })
        shotSelector = selector
        selector.show()
    }

    /// 動作確認用：出ている範囲選びの幕で、ドラッグしたことにする
    func testDragSelection(from a: NSPoint, to b: NSPoint) { shotSelector?.testDrag(from: a, to: b) }

    /// 動作確認用：範囲選びを飛ばして、数字を数えてから撮る所だけを通す
    func testTimerCapture(rect: NSRect, screen: NSScreen, seconds: Int) {
        busy = true
        countdown.start(seconds: seconds, center: NSPoint(x: rect.midX, y: rect.midY)) { [weak self] in
            self?.runScreencapture(rect: rect, screen: screen, source: nil, kind: "timer")
        }
    }

    /// 決まった範囲（nil なら画面全体）を、いまの画面のまま撮る。
    private func runScreencapture(rect: NSRect?, screen: NSScreen, source: String?, kind: String) {
        let out = Prefs.historyDir.appendingPathComponent("shot \(timestampName()).png")
        if let rect { captureRects[out.lastPathComponent] = rect; Prefs.lastAreaRect = rect }
        var args: [String] = Prefs.playSound ? [] : ["-x"]
        if Prefs.shotCursor { args.append("-C") }
        if let rect {
            let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
            args += ["-R", "\(Int(rect.minX)),\(Int(primaryHeight - rect.maxY)),\(Int(rect.width)),\(Int(rect.height))"]
        } else {
            args += ["-D", String(displayIndex(for: screen))]
        }
        args.append(out.path)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = args
        task.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                self?.busy = false
                let size = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0
                log("撮影 mode=\(kind) exit=\(proc.terminationStatus) size=\(size)")
                guard size > 0 else { return }
                self?.didCapture(out, source: source)
            }
        }
        do { try task.run() } catch { busy = false; log("screencapture を起動できない: \(error)") }
    }

    /// 文字を読み取る：範囲を選ぶと、その中の文字（と QR コード）を読み取ってクリップボードへ入れる。画像は残さない。
    func captureText() {
        if let selector = shotSelector {
            selector.close()
            shotSelector = nil
            busy = false
            return
        }
        guard !busy, ensurePermission() else { return }
        busy = true
        captureAllScreens { [weak self] shots in
            guard let self else { return }
            guard !shots.isEmpty else { self.busy = false; NSSound.beep(); return }
            let selector = ShotSelector(frozen: shots, hint: "文字を読み取る範囲をドラッグで選ぶ　／　esc か右クリックでやめる", onDone: { [weak self] _, _, cropped in
                self?.shotSelector = nil
                self?.busy = false
                guard let cropped else { return }
                TextReader.read(cropped) { text, codes in TextReader.copyResult(text: text, codes: codes) }
            }, onCancel: { [weak self] in
                self?.shotSelector = nil
                self?.busy = false
            })
            self.shotSelector = selector
            selector.show()
        }
    }

    /// スクロール撮影：範囲を決めて、下へスクロールしていく間ずっと撮り、1枚の縦長の画像にする。
    func captureScrolling() {
        guard !busy, ensurePermission() else { return }
        guard #available(macOS 14.0, *) else {
            log("スクロール撮影は macOS 14 以上")
            NSSound.beep()
            return
        }
        busy = true
        let source = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let selector = ShotSelector(frozen: [], hint: "スクロールして撮る範囲をドラッグで選ぶ　／　esc か右クリックでやめる", onDone: { [weak self] rect, screen, _ in
            guard let self else { return }
            self.shotSelector = nil
            guard let rect, rect.width >= 80, rect.height >= 80 else { self.busy = false; return }
            self.startScroll(rect: rect, screen: screen, source: source)
        }, onCancel: { [weak self] in
            self?.shotSelector = nil
            self?.busy = false
        })
        shotSelector = selector
        selector.show()
    }

    /// 画面収録の許可があれば true。なければ案内を出して false。
    func ensurePermission() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        log("画面収録の許可がない")
        CGRequestScreenCaptureAccess()
        showPermissionAlert()
        return false
    }

    func didCapture(_ file: URL, source: String? = nil, window: Bool = false) {
        HistoryStore.record(file: file, source: source)
        // 設定してあれば、決めた背景を付ける。ウィンドウを撮ったときは、ウィンドウ用の背景を先に見る
        if !(window && BackgroundStore.applyWindowBackdrop(to: file)) { BackgroundStore.applyAuto(to: file) }
        if Prefs.autoCopy { copyImageToPasteboard(file) }
        if Prefs.autoSave { _ = saveToFolder(file) }
        if Prefs.showPopup { PopupController.shared.show(file: file, on: screenUnderMouse()) }
        if Prefs.openEditorAfterCapture, !isMotion(file), !EditorController.headless {
            if Prefs.showPopup, let popup = PopupController.shared.latest, popup.fileURL == file {
                popup.openEditor()   // 編集を終えたら小窓へ戻る
            } else {
                EditorController.open(file: file) { _ in }
            }
        }
    }

    // MARK: 同じ範囲をもう一度・画像を開く

    /// 最後に範囲を決めて撮った場所を、選び直さずにもう一度撮る。
    func capturePrevious() {
        guard !busy, ensurePermission() else { return }
        guard let rect = Prefs.lastAreaRect,
              let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: rect.midX, y: rect.midY)) }) else {
            log("同じ範囲をもう一度撮る: まだ範囲を決めて撮っていない")
            ToastHUD.show("まだ範囲を決めて撮っていません", detail: "一度「範囲を選んで撮る」かオールインワンで撮ると使えます")
            return
        }
        busy = true
        runScreencapture(rect: rect, screen: screen, source: NSWorkspace.shared.frontmostApplication?.bundleIdentifier, kind: "previous")
    }

    /// 外から持ってきた画像を履歴に入れる（編集は履歴の中の写しに対して行う）。
    @discardableResult
    func importImage(_ image: CGImage, dpi: CGFloat) -> URL? {
        let out = Prefs.historyDir.appendingPathComponent("shot \(timestampName()).png")
        guard let data = pngData(image, dpi: dpi), (try? data.write(to: out)) != nil else { NSSound.beep(); return nil }
        HistoryStore.record(file: out, source: nil)
        return out
    }

    /// クリップボードの画像を編集画面で開く。
    func openFromClipboard() {
        guard let item = imagesFrom(pasteboard: .general).first else {
            ToastHUD.show("クリップボードに画像がありません", detail: nil)
            return
        }
        openInEditor(item.image, dpi: item.dpi)
    }

    func openInEditor(_ image: CGImage, dpi: CGFloat) {
        guard let file = importImage(image, dpi: dpi) else { return }
        EditorController.open(file: file) { saved in
            if !saved { PopupController.shared.show(file: file, on: screenUnderMouse()) }
        }
    }

    // MARK: オールインワン

    private var allInOneSelector: RegionSelector?
    var isAllInOneOpen: Bool { allInOneSelector != nil }

    /// 範囲を1回決めて、撮る・スクロール・タイマー・文字・録画のどれにするかを帯で選ぶ。
    func allInOne() {
        if let open = allInOneSelector {   // もう一度押したら閉じる
            open.close()
            allInOneSelector = nil
            return
        }
        guard !busy, !RecordController.shared.isRecording, ensurePermission() else { return }
        let source = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let selector = RegionSelector(allInOne: true, onDone: { [weak self] rect, screen, gif in
            self?.allInOneSelector = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                RecordController.shared.startAfterCountdown(rect: rect, screen: screen, gif: gif, source: source)
            }
        }, onAction: { [weak self] action, rect, screen in
            self?.allInOneSelector = nil
            // 薄暗い幕が消えてから撮る
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self?.perform(action, rect: rect, screen: screen, source: source) }
        }, onCancel: { [weak self] in
            self?.allInOneSelector = nil
        })
        allInOneSelector = selector
        selector.show()
    }

    /// 動作確認用
    var testAllInOneSelector: RegionSelector? { allInOneSelector }

    /// オールインワンで選んだ操作を実行する。rect が nil ならその画面全体。
    func perform(_ action: SelectorAction, rect: NSRect?, screen: NSScreen, source: String?) {
        guard !busy else { return }
        log("オールインワン: \(action) 範囲=\(rect.map { "\(Int($0.width))x\(Int($0.height))" } ?? "画面全体")")
        switch action {
        case .shot:
            busy = true
            runScreencapture(rect: rect, screen: screen, source: source, kind: "allinone")
        case .timer:
            busy = true
            let area = rect ?? screen.frame
            countdown.start(seconds: Prefs.timerSeconds, center: NSPoint(x: area.midX, y: area.midY)) { [weak self] in
                self?.runScreencapture(rect: rect, screen: screen, source: source, kind: "timer")
            }
        case .scroll:
            guard #available(macOS 14.0, *) else { NSSound.beep(); return }
            busy = true
            startScroll(rect: rect ?? screen.frame, screen: screen, source: source)
        case .ocr:
            busy = true
            grab(rect: rect ?? screen.frame) { [weak self] image in
                self?.busy = false
                guard let image else { NSSound.beep(); return }
                TextReader.read(image) { text, codes in TextReader.copyResult(text: text, codes: codes) }
            }
        }
    }

    /// 決まった範囲を撮って、ファイルに残さず画像だけ返す。
    private func grab(rect: NSRect, completion: @escaping (CGImage?) -> Void) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("kiritori-grab-\(UUID().uuidString).png")
        let primaryHeight = NSScreen.screens.first?.frame.height ?? rect.maxY
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-x", "-R", "\(Int(rect.minX)),\(Int(primaryHeight - rect.maxY)),\(Int(rect.width)),\(Int(rect.height))", file.path]
        task.terminationHandler = { _ in
            DispatchQueue.main.async {
                // ファイルを消す前に、中身をメモリへ読み切る
                let image = loadImage(at: file).flatMap { resampled($0.image, width: $0.image.width, height: $0.image.height) }
                try? FileManager.default.removeItem(at: file)
                completion(image)
            }
        }
        do { try task.run() } catch { completion(nil) }
    }

    @available(macOS 14.0, *)
    private func startScroll(rect: NSRect, screen: NSScreen, source: String?) {
        let session = ScrollCaptureSession(rect: rect, screen: screen)
        session.onFinish = { [weak self] image in
            self?.scrollSession = nil
            self?.busy = false
            if let image { self?.saveCaptured(image, scale: screen.backingScaleFactor, source: source, kind: "scroll") }
        }
        scrollSession = session
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { session.start() }   // 幕が消えてから撮り始める
    }

    private func showPermissionAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "画面収録の許可が必要です"
        alert.informativeText = "システム設定の「プライバシーとセキュリティ」→「画面収録とシステムオーディオ録音」で Kiritori をオンにしてください。一覧に Kiritori が無いときは、一覧の下の「＋」から Kiritori を足します。オンにしたあと Kiritori を一度終了して起動し直すと撮れるようになります。"
        alert.addButton(withTitle: "設定を開く")
        alert.addButton(withTitle: "あとで")
        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}

// MARK: - コピーと保存

/// 動作確認のときだけ別のペーストボードに差し替える（本物のクリップボードを上書きしないため）。
var pasteboardForCopy = NSPasteboard.general

func copyPNGDataToPasteboard(_ data: Data) {
    let pb = pasteboardForCopy
    pb.clearContents()
    let item = NSPasteboardItem()
    item.setData(data, forType: .png)
    if let tiff = NSImage(data: data)?.tiffRepresentation {
        item.setData(tiff, forType: .tiff)
    }
    pb.writeObjects([item])
}

func copyImageToPasteboard(_ file: URL) {
    if isMotion(file) {
        // 動画と GIF はファイルとしてクリップボードへ（貼り付け先に添付される。GIF は動きを保つため）
        pasteboardForCopy.clearContents()
        pasteboardForCopy.writeObjects([file as NSURL])
        log("コピー（\(isGIF(file) ? "GIF" : "動画")ファイル） \(file.lastPathComponent)")
        return
    }
    guard let data = try? Data(contentsOf: file) else { return }
    copyPNGDataToPasteboard(data)
    log("コピー \(file.lastPathComponent)")
}

@discardableResult
/// 画像を PNG か JPEG のデータにする。JPEG は透明を持てないので白地に重ねる。
func encodeImage(_ image: CGImage, dpi: CGFloat, jpegQuality: Int?) -> Data? {
    guard let quality = jpegQuality else { return pngData(image, dpi: dpi) }
    guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    guard let flat = ctx.makeImage() else { return nil }
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
    let props: [CFString: Any] = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi,
                                  kCGImageDestinationLossyCompressionQuality: Double(quality) / 100]
    CGImageDestinationAddImage(dest, flat, props as CFDictionary)
    return CGImageDestinationFinalize(dest) ? data as Data : nil
}

/// 履歴の中のファイルを、保存先フォルダへ保存する。画像は設定した形式・細かさに直す。
func saveToFolder(_ file: URL) -> URL? {
    let dir = Prefs.saveDir
    var ext = file.pathExtension.isEmpty ? "png" : file.pathExtension
    var name = file.deletingPathExtension().lastPathComponent
    if name.hasPrefix("shot ") { name = Prefs.shotPrefix + " " + name.dropFirst(5) }
    else if name.hasPrefix("rec ") { name = Prefs.recPrefix + " " + name.dropFirst(4) }
    // 画像は、形式か細かさを変える設定のときだけ作り直す（そうでなければそのまま写す）
    var converted: Data?
    if !isMotion(file), Prefs.saveFormat == "jpg" || Prefs.saveAt1x, let loaded = loadImage(at: file) {
        var image = loaded.image, dpi = loaded.dpi
        if Prefs.saveAt1x, dpi > 73 {
            let k = 72 / dpi
            if let small = resampled(image, width: max(1, Int((CGFloat(image.width) * k).rounded())),
                                     height: max(1, Int((CGFloat(image.height) * k).rounded()))) {
                image = small
                dpi = 72
            }
        }
        converted = encodeImage(image, dpi: dpi, jpegQuality: Prefs.saveFormat == "jpg" ? Prefs.jpegQuality : nil)
        if converted != nil, Prefs.saveFormat == "jpg" { ext = "jpg" }
    }
    var dest = dir.appendingPathComponent("\(name).\(ext)")
    var n = 2
    while FileManager.default.fileExists(atPath: dest.path) {
        dest = dir.appendingPathComponent("\(name) (\(n)).\(ext)")
        n += 1
    }
    do {
        if let converted { try converted.write(to: dest) } else { try FileManager.default.copyItem(at: file, to: dest) }
        log("保存 \(dest.path)")
        return dest
    } catch {
        log("保存失敗 \(error)")
        NSSound.beep()
        return nil
    }
}

// MARK: - デスクトップのアイコンを隠す

/// いま画面に出ている壁紙を、画面ごとに取ってくる。
/// 壁紙のファイルは動かされていたり動く壁紙だったりして読めないことがあるので、壁紙の窓そのものを撮る。
func captureWallpapers(completion: @escaping ([(screen: NSScreen, image: CGImage)]) -> Void) {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
    var jobs: [(NSScreen, Int, URL)] = []
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kiritori-wallpaper-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for w in list {
        guard (w[kCGWindowOwnerName as String] as? String) == "Dock",
              (w[kCGWindowName as String] as? String)?.hasPrefix("Wallpaper") == true,
              let id = w[kCGWindowNumber as String] as? Int, let b = w[kCGWindowBounds as String] as? [String: Any],
              let x = b["X"] as? CGFloat, let y = b["Y"] as? CGFloat, let width = b["Width"] as? CGFloat, let height = b["Height"] as? CGFloat,
              // 窓の位置（左上が原点）から、どの画面の壁紙かを決める
              let screen = NSScreen.screens.first(where: {
                  abs($0.frame.minX - x) < 2 && abs(primaryHeight - $0.frame.maxY - y) < 2 && abs($0.frame.width - width) < 2 && abs($0.frame.height - height) < 2
              }), !jobs.contains(where: { $0.0 == screen }) else { continue }
        jobs.append((screen, id, dir.appendingPathComponent("\(id).png")))
    }
    let group = DispatchGroup()
    for (_, id, file) in jobs {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-o", "-l\(id)", file.path]
        group.enter()
        p.terminationHandler = { _ in group.leave() }
        do { try p.run() } catch { group.leave() }
    }
    group.notify(queue: .main) {
        var result: [(screen: NSScreen, image: CGImage)] = []
        for (screen, _, file) in jobs {
            // ファイルを消す前にメモリへ読み切る
            if let lazy = loadImage(at: file)?.image, let image = resampled(lazy, width: lazy.width, height: lazy.height) { result.append((screen, image)) }
        }
        try? FileManager.default.removeItem(at: dir)
        completion(result)
    }
}

/// アイコンのすぐ上に、壁紙と同じ絵の窓を敷いて隠す（Finder の設定は変えない）。
enum DesktopCover {
    private static var windows: [NSWindow] = []
    private static var observer: Any?
    static var isOn: Bool { !windows.isEmpty }

    private static func clear() {
        windows.forEach { $0.orderOut(nil) }
        windows = []
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    /// 隠す・戻す。壁紙が取れない画面があったら隠さずに false を返す。
    static func set(_ on: Bool, completion: ((Bool) -> Void)? = nil) {
        clear()
        Prefs.hideDesktopIcons = on
        guard on else { completion?(true); return }
        captureWallpapers { shots in
            guard !shots.isEmpty, shots.count == NSScreen.screens.count else {
                log("アイコンを隠せない: 壁紙が取れない \(shots.count)/\(NSScreen.screens.count)")
                Prefs.hideDesktopIcons = false
                completion?(false)
                return
            }
            clear()
            for (screen, image) in shots {
                let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
                window.setFrame(screen.frame, display: false)
                window.isReleasedWhenClosed = false
                window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
                window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
                window.ignoresMouseEvents = true
                window.hasShadow = false
                let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
                view.wantsLayer = true
                view.layer?.contents = image
                view.layer?.contentsGravity = .resize
                window.contentView = view
                windows.append(window)
            }
            windows.forEach { $0.orderFrontRegardless() }
            // 画面のつなぎ方が変わったら敷き直す
            observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
                if isOn { set(true) }
            }
            log("デスクトップのアイコンを隠した 画面=\(windows.count)")
            completion?(true)
        }
    }
}

func cleanHistory() {
    let fm = FileManager.default
    let limit = Date().addingTimeInterval(-Double(Prefs.historyDays) * 24 * 3600)
    guard let files = try? fm.contentsOfDirectory(at: Prefs.historyDir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
    for f in files where !f.hasDirectoryPath {
        if let date = try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, date < limit {
            try? fm.removeItem(at: f)
        }
    }
    EditProject.cleanOrphans()   // 消えた画像の「編集の控え」も片付ける
}

// MARK: - 撮った直後の小窓

final class ThumbView: NSView, NSDraggingSource {
    private(set) var image: NSImage
    let fileURL: URL
    var onDragDone: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    /// 動画のときの長さ（「0:12」）。入っていれば左下に印を出す
    var videoBadge: String?
    private var downPoint: NSPoint?

    init(frame: NSRect, image: NSImage, fileURL: URL) {
        self.image = image
        self.fileURL = fileURL
        super.init(frame: frame)
        toolTip = "ドラッグで他のアプリへ。ダブルクリックで編集します"
    }

    func reload() {
        // NSImage(contentsOf:) は同じURLを使い回すことがあるので、データから読み直す
        if isVideo(fileURL) {   // 動画は最初のコマと長さを取り直す
            if let poster = videoPoster(fileURL) { image = poster }
            videoBadge = clockText(videoInfo(fileURL)?.seconds ?? 0)
            needsDisplay = true
        } else if let data = try? Data(contentsOf: fileURL), let fresh = NSImage(data: data) {
            image = fresh
            needsDisplay = true
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    private var imageRect: NSRect {
        let s = image.size
        guard s.width > 0, s.height > 0 else { return bounds }
        let scale = min(bounds.width / s.width, bounds.height / s.height, 1.0)
        let w = s.width * scale, h = s.height * scale
        return NSRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = imageRect
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).addClip()
        image.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.withAlphaComponent(0.25).setStroke()
        let border = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        border.lineWidth = 1
        border.stroke()
        if let videoBadge { drawVideoBadge(videoBadge, in: r) }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            downPoint = nil
            onDoubleClick?()
            return
        }
        downPoint = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downPoint else { return }
        let now = convert(event.locationInWindow, from: nil)
        guard hypot(now.x - start.x, now.y - start.y) > 4 else { return }
        downPoint = nil
        let item = NSDraggingItem(pasteboardWriter: fileURL as NSURL)
        item.setDraggingFrame(imageRect, contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if operation != [] { onDragDone?() }
    }
}

final class ShotPopup: NSPanel {
    let fileURL: URL
    let targetScreen: NSScreen
    private var thumb: ThumbView!

    static let width: CGFloat = 300
    static let thumbHeight: CGFloat = 150
    static let height: CGFloat = thumbHeight + 8 + 8 + 28 + 8

    init(fileURL: URL, screen: NSScreen) {
        self.fileURL = fileURL
        self.targetScreen = screen
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.height),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        level = .floating
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        appearance = NSAppearance(named: .vibrantDark)

        let root = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.height))
        root.material = .hudWindow
        root.state = .active
        root.blendingMode = .behindWindow
        root.wantsLayer = true
        root.layer?.cornerRadius = 12
        root.layer?.masksToBounds = true
        contentView = root

        let video = isVideo(fileURL)
        let image = (video ? videoPoster(fileURL) : NSImage(contentsOf: fileURL)) ?? NSImage()
        let thumb = ThumbView(frame: NSRect(x: 8, y: 44, width: Self.width - 16, height: Self.thumbHeight),
                              image: image, fileURL: fileURL)
        let motion = isMotion(fileURL)
        if motion {
            thumb.videoBadge = video ? clockText(videoInfo(fileURL)?.seconds ?? 0) : "GIF"
            thumb.toolTip = video ? "ドラッグで他のアプリへ。ダブルクリックで編集画面を開きます" : "ドラッグで他のアプリへ。ダブルクリックで再生します"
        }
        thumb.onDragDone = { [weak self] in if Prefs.popupCloseAfterDrag { self?.dismiss() } }
        thumb.onDoubleClick = { [weak self] in self?.openEditor() }
        root.addSubview(thumb)
        self.thumb = thumb

        var titles: [(String, Selector)] = [("コピー", #selector(copyTapped)), ("保存", #selector(saveTapped)), (motion && !video ? "再生" : "編集", #selector(editTapped))]
        if !motion { titles.append(("ピン", #selector(pinTapped))) }   // 画像だけ（動画は留められない）
        let closeWidth: CGFloat = 28
        let buttonWidth = (Self.width - 16 - closeWidth - 4 * CGFloat(titles.count)) / CGFloat(titles.count)
        var x: CGFloat = 8
        for (title, action) in titles {
            let b = NSButton(title: title, target: self, action: action)
            b.bezelStyle = .rounded
            b.controlSize = .regular
            b.frame = NSRect(x: x, y: 8, width: buttonWidth, height: 28)
            root.addSubview(b)
            x += buttonWidth + 4
        }
        let close = NSButton(title: "×", target: self, action: #selector(closeTapped))
        close.bezelStyle = .rounded
        close.frame = NSRect(x: x, y: 8, width: closeWidth, height: 28)
        close.toolTip = "閉じる（画像は\(Prefs.historyDays)日間、履歴に残ります）"
        root.addSubview(close)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    @objc func copyTapped() {
        copyImageToPasteboard(fileURL)
        dismiss()   // コピーしたら小窓は片付ける。画像は「最近のスクショを開く」に残る
    }

    @objc func saveTapped() {
        if saveToFolder(fileURL) != nil { dismiss() }
    }

    @objc func editTapped() { openEditor() }

    /// 画面に留める（撮った場所が分かっていれば、その場所へ重ねる）。小窓は片付ける
    @objc func pinTapped() {
        if PinController.shared.pin(file: fileURL, at: CaptureController.shared.captureRect(for: fileURL)) != nil { dismiss() }
    }

    @objc func closeTapped() { dismiss() }

    func openEditor() {
        if isVideo(fileURL) {   // 動画は動画エディタで開く（前後を切る・音を消す・縮めるなど）
            VideoEditorController.open(file: fileURL) { [weak self] in self?.thumb.reload() }
            return
        }
        if isMotion(fileURL) {   // GIF は編集せず、標準のアプリで開く
            NSWorkspace.shared.open(fileURL)
            return
        }
        EditorController.open(file: fileURL) { [weak self] saved in
            if saved {
                self?.dismiss()      // 保存まで済んだら小窓は片付ける
            } else {
                self?.thumb.reload() // 「完了」なら編集後の画像でドラッグ・コピーできるようにする
            }
        }
    }

    func dismiss() {
        PopupController.shared.remove(self)
    }
}

final class PopupController {
    static let shared = PopupController()
    private var popups: [ShotPopup] = []

    func show(file: URL, on screen: NSScreen) {
        if let existing = popups.first(where: { $0.fileURL == file }) {
            existing.orderFrontRegardless()
            return
        }
        let p = ShotPopup(fileURL: file, screen: screen)
        popups.append(p)
        if popups.count > 5 {
            let old = popups.removeFirst()
            old.orderOut(nil)
            closedFiles.append(old.fileURL)
        }
        relayout()
        p.orderFrontRegardless()
        scheduleAutoClose(p)
    }

    /// 設定した秒数がたったら小窓を閉じる。カーソルが乗っている間は待つ。
    private func scheduleAutoClose(_ popup: ShotPopup, after seconds: Double? = nil) {
        let wait = seconds ?? Double(Prefs.popupAutoClose)
        guard wait > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self, weak popup] in
            guard let self, let popup, self.popups.contains(where: { $0 === popup }) else { return }
            if NSMouseInRect(NSEvent.mouseLocation, popup.frame, false) || EditorController.openEditors.contains(where: { $0.fileURL == popup.fileURL }) {
                self.scheduleAutoClose(popup, after: 2)
            } else {
                self.remove(popup)
            }
        }
    }

    /// 設定で出す側を変えたときに並べ直す
    func applySettings() { relayout() }

    /// 最後に閉じた小窓の中身（「直前に閉じたものを戻す」用）
    private var closedFiles: [URL] = []

    /// 最後に閉じた小窓をもう一度出す。押すたびに、ひとつ前に閉じたものへさかのぼる。
    func restoreLast() {
        while let file = closedFiles.popLast() {
            guard FileManager.default.fileExists(atPath: file.path), !popups.contains(where: { $0.fileURL == file }) else { continue }
            show(file: file, on: screenUnderMouse())
            log("閉じた小窓を戻した \(file.lastPathComponent)")
            return
        }
        ToastHUD.show("戻せるものがありません", detail: "前に撮ったものは「履歴を見る」にあります")
    }

    func remove(_ popup: ShotPopup) {
        guard popups.contains(where: { $0 === popup }) else { return }
        popups.removeAll { $0 === popup }
        closedFiles.removeAll { $0 == popup.fileURL }
        closedFiles.append(popup.fileURL)
        if closedFiles.count > 20 { closedFiles.removeFirst() }
        // すっと消してから片付ける
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            popup.animator().alphaValue = 0
        }, completionHandler: {
            popup.orderOut(nil)
        })
        relayout()
    }

    func remove(file: URL) {
        popups.filter { $0.fileURL == file }.forEach { remove($0) }
    }

    var latest: ShotPopup? { popups.last }
    var count: Int { popups.count }

    private func relayout() {
        var nextY: [ObjectIdentifier: CGFloat] = [:]
        for p in popups {
            let key = ObjectIdentifier(p.targetScreen)
            let vf = p.targetScreen.visibleFrame
            let y = nextY[key] ?? (vf.minY + 16)
            let x = Prefs.popupSide == "right" ? vf.maxX - ShotPopup.width - 16 : vf.minX + 16
            p.setFrameOrigin(NSPoint(x: x, y: y))
            nextY[key] = y + ShotPopup.height + 10
        }
    }
}

// MARK: - メニューバー

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem?
    /// ショートカットを出しているメニュー項目（名前ごと）。設定で変えたら表示も変える
    var hotKeyItems: [String: NSMenuItem] = [:]
    var desktopIconsItem: NSMenuItem!
    var closePinsItem: NSMenuItem!
    var unlockPinsItem: NSMenuItem!
    var statusMenu: NSMenu?

    func buildMainMenu() {
        let main = NSMenu()

        let fileItem = NSMenuItem()
        let file = NSMenu(title: "ファイル")
        file.addItem(withTitle: "保存", action: Selector(("saveDocument:")), keyEquivalent: "s")
        file.addItem(withTitle: "閉じる", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = file
        main.addItem(fileItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "編集")
        edit.addItem(withTitle: "取り消す", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "やり直す", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "カット", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "コピー", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "ペースト", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "すべてを選択", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        NSApp.mainMenu = main
    }

    /// 識別名を local.kiritori から付け直したので、前の設定（保存先・ショートカットなど）を一度だけ引き継ぐ。
    func migrateOldDefaults() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "migratedFromLocalKiritori") else { return }
        if let old = d.persistentDomain(forName: "local.kiritori") {
            for (key, value) in old where d.object(forKey: key) == nil && !key.hasPrefix("NS") {
                d.set(value, forKey: key)
            }
            log("前の設定を引き継いだ \(old.keys.sorted())")
        }
        d.set(true, forKey: "migratedFromLocalKiritori")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 範囲選びをすぐ出せるように、画面の一覧を先に取っておく
        if #available(macOS 14.0, *) {
            DisplayCache.shared.warm()
            NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
                DisplayCache.shared.warm()
            }
        }
        migrateOldDefaults()
        cleanHistory()
        buildMainMenu()
        buildMenu()
        installHotKeyHandler()

        HotKeys.specs = [
            HotKeySpec(id: 7, name: "allinone", title: "オールインワン", defaultKey: kVK_ANSI_1) { CaptureController.shared.allInOne() },
            HotKeySpec(id: 2, name: "area", title: "範囲を選んで撮る", defaultKey: kVK_ANSI_4) { CaptureController.shared.capture(.area) },
            HotKeySpec(id: 1, name: "full", title: "画面全体を撮る", defaultKey: kVK_ANSI_3) { CaptureController.shared.capture(.full) },
            HotKeySpec(id: 3, name: "window", title: "ウィンドウを撮る", defaultKey: kVK_ANSI_5) { CaptureController.shared.capture(.window) },
            HotKeySpec(id: 8, name: "previous", title: "同じ範囲をもう一度撮る", defaultKey: Int(hotKeyDisabled)) { CaptureController.shared.capturePrevious() },
            HotKeySpec(id: 6, name: "ocr", title: "文字を読み取る", defaultKey: kVK_ANSI_2) { CaptureController.shared.captureText() },
            HotKeySpec(id: 5, name: "record", title: "画面を録画する", defaultKey: kVK_ANSI_7) { RecordController.shared.toggle() },
            HotKeySpec(id: 9, name: "pause", title: "録画を一時停止・再開する", defaultKey: Int(hotKeyDisabled)) { RecordController.shared.togglePause() },
            HotKeySpec(id: 10, name: "restore", title: "直前に閉じたものを戻す", defaultKey: Int(hotKeyDisabled)) { PopupController.shared.restoreLast() },
            HotKeySpec(id: 4, name: "history", title: "履歴を見る", defaultKey: kVK_ANSI_6) { HistoryController.shared.toggle() },
        ]
        // --no-hotkeys : 同じショートカットを使う別アプリがいるMacで試すとき用。メニューからだけ撮る
        HotKeys.enabled = !CommandLine.arguments.contains("--no-hotkeys")
        let ok = HotKeys.registerAll()
        let summary = HotKeys.specs.map { "\($0.name)=\(ok[$0.name] ?? false)" }.joined(separator: " ")
        log("起動 v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") ショートカット \(summary) 画面収録の許可=\(CGPreflightScreenCaptureAccess())")

        if !CommandLine.arguments.contains(where: { $0.hasPrefix("--test-") }) {
            if Prefs.hideDesktopIcons { DesktopCover.set(true) }
            BackgroundPainter.loadWallpaper(nil)   // 背景ツールの「壁紙」用に、先に取っておく
        }

        // 動作確認用の起動引数
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--test-popup"), i + 1 < args.count {
            let src = URL(fileURLWithPath: args[i + 1])
            let dst = Prefs.historyDir.appendingPathComponent("shot \(timestampName()).png")
            try? FileManager.default.copyItem(at: src, to: dst)
            CaptureController.shared.didCapture(dst)
            // --test-actions copy,save : ボタンと同じ処理を順に呼んで結果をログに残す
            if let j = args.firstIndex(of: "--test-actions"), j + 1 < args.count {
                pasteboardForCopy = NSPasteboard(name: NSPasteboard.Name("local.kiritori.test"))
                for action in args[j + 1].split(separator: ",") {
                    guard let popup = PopupController.shared.latest else { log("テスト: 小窓がない"); break }
                    switch action {
                    case "copy":
                        popup.copyTapped()
                        let types = pasteboardForCopy.types?.map(\.rawValue) ?? []
                        let bytes = pasteboardForCopy.data(forType: .png)?.count ?? 0
                        log("テスト: copy types=\(types) pngBytes=\(bytes) 後の小窓の数=\(PopupController.shared.count)")
                    case "save":
                        popup.saveTapped()
                        log("テスト: save 後の小窓の数=\(PopupController.shared.count)")
                    case "close":
                        popup.closeTapped()
                        log("テスト: close 後の小窓の数=\(PopupController.shared.count)")
                    default: break
                    }
                }
            }
        }
        // --settings : 設定画面を開く（確認用） / --video <動画> : 写しを作って動画エディタで開く（確認用）
        if args.contains("--settings") { SettingsController.shared.show() }
        if let i = args.firstIndex(of: "--video"), i + 1 < args.count {
            let src = URL(fileURLWithPath: args[i + 1])
            let dst = Prefs.historyDir.appendingPathComponent("rec \(timestampName()).mp4")
            if (try? FileManager.default.copyItem(at: src, to: dst)) != nil { _ = VideoEditorController.open(file: dst) }
        }
        // --edit <画像> : 撮影なしで編集画面を開く。完了すると小窓に出る（画面収録の許可がなくても編集を試せる）
        if let i = args.firstIndex(of: "--edit"), i + 1 < args.count {
            let src = URL(fileURLWithPath: args[i + 1])
            let dst = Prefs.historyDir.appendingPathComponent("shot \(timestampName()).png")
            do {
                try FileManager.default.copyItem(at: src, to: dst)
                let opened = EditorController.open(file: dst) { saved in
                    if !saved { PopupController.shared.show(file: dst, on: screenUnderMouse()) }
                }
                // --test-background-show <出力フォルダ> : 背景の小窓を実際に開いて、編集の窓と小窓だけを撮って終わる
                if let opened, let j = args.firstIndex(of: "--test-background-show"), j + 1 < args.count {
                    let out = URL(fileURLWithPath: args[j + 1])
                    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
                    let savedLast = BackgroundStore.last
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        let panel = opened.showBackgroundPanel()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                            for (name, window) in [("editor", opened.window), ("panel", panel.view.window)] {
                                guard let window else { continue }
                                let task = Process()
                                task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                                task.arguments = ["-x", "-o", "-l\(window.windowNumber)", out.appendingPathComponent("bgshow-\(name).png").path]
                                try? task.run()
                                task.waitUntilExit()
                            }
                            BackgroundStore.last = savedLast
                            EditProject.discard(for: dst)
                            try? FileManager.default.removeItem(at: dst)
                            exit(0)
                        }
                    }
                }
            } catch {
                log("--edit: 画像を用意できない \(error)")
            }
        }
        // --test-editor <画像> [--test-annotate <出力png>] [--test-mouse] [--test-snapshot <出力png>]
        // 編集画面を開き、全種類の注釈を足して書き出す。結果はログに残す。
        if let i = args.firstIndex(of: "--test-editor"), i + 1 < args.count {
            EditorController.headless = true
            let src = URL(fileURLWithPath: args[i + 1])
            let dst = Prefs.historyDir.appendingPathComponent("shot \(timestampName()) edit.png")
            try? FileManager.default.copyItem(at: src, to: dst)
            let editor = EditorController.open(file: dst) { saved in log("テスト: 編集終了 saved=\(saved)") }
            if let editor, let j = args.firstIndex(of: "--test-annotate"), j + 1 < args.count {
                let c = editor.canvas
                let w = c.renderer.width, h = c.renderer.height, k = c.renderer.dpiScale
                let pal = EditorController.palette
                func make(_ tool: Tool, _ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat, _ color: NSColor) -> Annotation {
                    Annotation(tool: tool, p0: CGPoint(x: w * x0, y: h * y0), p1: CGPoint(x: w * x1, y: h * y1),
                               color: color, weight: 0.25, scale: k)
                }
                // マウス操作のテストは何も描いていない画像でやる
                let showcase = !args.contains("--test-mouse")
                // ぼかし3種
                for (n, style) in (showcase ? Array(BlurStyle.allCases.enumerated()) : []) {
                    var b = make(.blur, 0.03 + CGFloat(n) * 0.15, 0.62, 0.16 + CGFloat(n) * 0.15, 0.92, pal[6]); b.blurStyle = style; c.add(b)
                }
                // 矢印4種（まっすぐ）と、曲げたもの4種
                for (n, style) in (showcase ? Array(ArrowStyle.allCases.enumerated()) : []) {
                    var a = make(.arrow, 0.52, 0.90 - CGFloat(n) * 0.09, 0.72, 0.86 - CGFloat(n) * 0.09, pal[0]); a.arrowStyle = style; c.add(a)
                    var b = make(.arrow, 0.76, 0.90 - CGFloat(n) * 0.09, 0.96, 0.86 - CGFloat(n) * 0.09, pal[4]); b.arrowStyle = style
                    b.ctrl = CGPoint(x: w * 0.86, y: h * (0.97 - CGFloat(n) * 0.09)); c.add(b)
                }
                if showcase {
                    var thick = make(.arrow, 0.52, 0.40, 0.72, 0.50, pal[1]); thick.weight = 0.8; thick.arrowStyle = .tapered; c.add(thick)
                    c.add(make(.rect, 0.05, 0.30, 0.25, 0.52, pal[0]))
                    c.add(make(.ellipse, 0.28, 0.30, 0.46, 0.52, pal[4]))
                    var ln = make(.line, 0.05, 0.25, 0.46, 0.25, pal[2]); ln.ctrl = CGPoint(x: w * 0.25, y: h * 0.18); c.add(ln)
                    var t1 = make(.text, 0.05, 0.10, 0.05, 0.10, pal[0]); t1.text = "縁取りの文字 Check 123"; c.add(t1)
                    var t2 = make(.text, 0.40, 0.10, 0.40, 0.10, pal[4]); t2.text = "背景つきの文字"; t2.textStyle = .boxed; c.add(t2)
                    var t3 = make(.text, 0.66, 0.10, 0.66, 0.10, pal[2]); t3.text = "黄色の背景"; t3.textStyle = .boxed; c.add(t3)
                    for n in 1...3 { var cn = make(.counter, 0.78 + CGFloat(n) * 0.05, 0.45, 0, 0, pal[n == 2 ? 3 : 0]); cn.p1 = cn.p0; cn.number = n; c.add(cn) }
                } else {
                    c.add(make(.line, 0.02, 0.04, 0.10, 0.04, pal[2]))   // 取り消しの確認用に1つだけ
                }
                if let image = c.renderer.renderImage(c.annotations), let data = pngData(image, dpi: editor.dpi) {
                    try? data.write(to: URL(fileURLWithPath: args[j + 1]))
                    log("テスト: 注釈を書き出し 個数=\(c.annotations.count) bytes=\(data.count) dpi=\(editor.dpi)")
                }
                let total = c.annotations.count
                c.undo(nil)
                let afterUndo = c.annotations.count
                c.redo(nil)
                log("テスト: 取り消し \(total)→\(afterUndo) やり直し→\(c.annotations.count)")
                // 確認用に履歴へ置いた画像は、終わるときに片付ける
                NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
                    EditProject.discard(for: dst)
                    try? FileManager.default.removeItem(at: dst)
                }

                // --test-mouse : マウス操作を合成して、描く・つまみで変える・曲げる・動かす・消す・文字を通す
                if args.contains("--test-mouse") {
                    editor.window.layoutIfNeeded()
                    c.display()
                    func send(_ type: NSEvent.EventType, _ pt: NSPoint, clicks: Int = 1) {
                        let inWindow = c.convert(pt, to: nil)
                        guard let e = NSEvent.mouseEvent(with: type, location: inWindow, modifierFlags: [], timestamp: 0,
                                                         windowNumber: editor.window.windowNumber, context: nil,
                                                         eventNumber: 0, clickCount: clicks, pressure: 1) else { return }
                        switch type {
                        case .leftMouseDown: c.mouseDown(with: e)
                        case .leftMouseDragged: c.mouseDragged(with: e)
                        default: c.mouseUp(with: e)
                        }
                    }
                    func dragView(_ from: NSPoint, _ to: NSPoint) {
                        send(.leftMouseDown, from); send(.leftMouseDragged, to); send(.leftMouseUp, to)
                    }
                    func fmt(_ p: CGPoint) -> String { "(\(Int(p.x)),\(Int(p.y)))" }
                    // 何も描いていない画像の中央付近を使う
                    let origin = c.toView(CGPoint(x: w * 0.25, y: h * 0.50))
                    func at(_ dx: CGFloat, _ dy: CGFloat) -> NSPoint { NSPoint(x: origin.x + dx, y: origin.y + dy) }

                    c.setTool(.arrow)
                    let n0 = c.annotations.count
                    dragView(at(0, 0), at(90, 0))
                    log("テスト: 矢印を描いた 個数 \(n0)→\(c.annotations.count) 描いた直後に選択中=\(c.selected == c.annotations.count - 1)")
                    let arrowIndex = c.annotations.count - 1
                    let p1Before = c.annotations[arrowIndex].p1
                    dragView(c.toView(p1Before), at(60, 60))
                    log("テスト: 終点のつまみで向きを変えた p1 \(fmt(p1Before))→\(fmt(c.annotations[arrowIndex].p1)) 個数=\(c.annotations.count)")
                    let mid = c.annotations[arrowIndex].curvePoint(0.5)
                    dragView(c.toView(mid), NSPoint(x: c.toView(mid).x + 25, y: c.toView(mid).y - 25))
                    log("テスト: 真ん中のつまみで曲げた 曲がり=\(c.annotations[arrowIndex].ctrl != nil)")
                    c.setArrowStyle(.tapered)
                    log("テスト: 選んだまま種類を変えた 種類=\(c.annotations[arrowIndex].arrowStyle.label)")
                    c.setWeight(0.6)
                    c.setColor(EditorController.palette[3])
                    log("テスト: 選んだまま太さと色を変えた 太さ=\(c.annotations[arrowIndex].weight) 緑=\(c.annotations[arrowIndex].color == EditorController.palette[3])")

                    c.setTool(.rect)
                    dragView(at(0, -110), at(100, -50))
                    let rectIndex = c.annotations.count - 1
                    let r0 = c.annotations[rectIndex].rect
                    let corner = c.toView(CGPoint(x: r0.maxX, y: r0.maxY))
                    dragView(corner, NSPoint(x: corner.x + 40, y: corner.y + 20))
                    let r1 = c.annotations[rectIndex].rect
                    log("テスト: 四角を描いて右上のつまみで広げた \(Int(r0.width))x\(Int(r0.height))→\(Int(r1.width))x\(Int(r1.height))")
                    // 道具は四角のまま、枠線をつかんで動かす
                    let edge = c.toView(CGPoint(x: r1.minX, y: r1.midY))
                    dragView(edge, NSPoint(x: edge.x - 30, y: edge.y))
                    log("テスト: 四角の道具のまま枠をつかんで動かした 左端 \(Int(r1.minX))→\(Int(c.annotations[rectIndex].rect.minX)) 個数=\(c.annotations.count)")
                    let nBeforeDelete = c.annotations.count
                    c.deleteSelected()
                    log("テスト: 消した 個数 \(nBeforeDelete)→\(c.annotations.count)")

                    c.setTool(.counter)
                    send(.leftMouseDown, at(140, 0)); send(.leftMouseUp, at(140, 0))
                    log("テスト: 番号を置いた 番号=\(c.annotations.last!.number)")
                    c.setTool(.text)
                    send(.leftMouseDown, at(0, 60)); send(.leftMouseUp, at(0, 60))
                    let typed = c.testTypeText("マウスで置いた文字")
                    let textIndex = c.annotations.count - 1
                    log("テスト: 文字欄が出た=\(typed) 最後の注釈=\(c.annotations[textIndex].tool.label)「\(c.annotations[textIndex].text)」")
                    let textCenter = c.toView(CGPoint(x: c.annotations[textIndex].bounds.midX, y: c.annotations[textIndex].bounds.midY))
                    send(.leftMouseDown, textCenter, clicks: 2)
                    let retyped = c.testTypeText("打ち直した文字")
                    log("テスト: ダブルクリックで打ち直し=\(retyped) 「\(c.annotations.last!.text)」 個数=\(c.annotations.count)")
                    c.setTool(.blur)
                    c.setBlurStyle(.gaussian)
                    dragView(at(160, -110), at(300, -40))
                    log("テスト: ぼかしを描いた 種類=\(c.annotations.last!.blurStyle.label)")
                    // 最後に矢印を選び直して、つまみが見える状態で止める
                    c.setTool(.select)
                    let grab = c.toView(c.annotations[arrowIndex].curvePoint(0.25))
                    send(.leftMouseDown, grab); send(.leftMouseUp, grab)
                    log("テスト: 選択の道具で矢印を選び直した 選択中=\(c.selected == arrowIndex)")
                    if let image = c.renderer.renderImage(c.annotations), let data = pngData(image, dpi: editor.dpi) {
                        try? data.write(to: URL(fileURLWithPath: args[j + 1]))
                    }
                }
            }
            // --test-newtools <出力png> <UIの出力png> : 塗り四角・ペン・蛍光ペン・スポットライト・切り抜きを足して書き出し、
            // 完了→開き直しで描いたものが戻るかまで通す
            if let editor, let j = args.firstIndex(of: "--test-newtools"), j + 2 < args.count {
                let c = editor.canvas
                let w = c.renderer.width, h = c.renderer.height, k = c.renderer.dpiScale
                let pal = EditorController.palette
                func make(_ tool: Tool, _ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat, _ color: NSColor) -> Annotation {
                    Annotation(tool: tool, p0: CGPoint(x: w * x0, y: h * y0), p1: CGPoint(x: w * x1, y: h * y1),
                               color: color, weight: 0.3, scale: k)
                }
                c.add(make(.spotlight, 0.08, 0.30, 0.52, 0.80, pal[0]))
                c.add(make(.fillRect, 0.60, 0.62, 0.78, 0.78, pal[4]))
                var pen = make(.pencil, 0.12, 0.55, 0.45, 0.55, pal[0])
                pen.points = (0...60).map { i in
                    let t = CGFloat(i) / 60
                    return CGPoint(x: w * (0.12 + 0.33 * t), y: h * (0.55 + 0.06 * sin(t * 4 * .pi)))
                }
                c.add(pen)
                var marker = make(.highlighter, 0.12, 0.42, 0.45, 0.42, pal[2])
                marker.points = [CGPoint(x: w * 0.12, y: h * 0.42), CGPoint(x: w * 0.45, y: h * 0.42)]
                c.add(marker)
                c.add(make(.arrow, 0.70, 0.45, 0.50, 0.55, pal[0]))
                c.add(make(.crop, 0.04, 0.22, 0.86, 0.90, pal[0]))
                let n = c.annotations.count
                c.setTool(.crop)
                editor.window.layoutIfNeeded()
                editor.snapshot(to: URL(fileURLWithPath: args[j + 2]))
                if let image = c.renderer.renderImage(c.annotations), let data = pngData(image, dpi: editor.dpi) {
                    try? data.write(to: URL(fileURLWithPath: args[j + 1]))
                    log("テスト: 新しい道具 注釈=\(n) 元の大きさ=\(Int(w))x\(Int(h)) 書き出し=\(image.width)x\(image.height)（切り抜き後）")
                }
                editor.doneTapped()   // 完了：画像へ反映して閉じる
                let after = pixelSize(of: dst)
                log("テスト: 完了後のファイル=\(after.map { "\($0.0)x\($0.1)" } ?? "?") 控えがある=\(FileManager.default.fileExists(atPath: EditProject.jsonURL(for: dst).path))")
                if let again = EditorController.open(file: dst, onFinish: { _ in }) {
                    let c2 = again.canvas
                    log("テスト: 開き直し 戻った注釈=\(c2.annotations.count)/\(n) 元の画像に戻っている=\(Int(c2.renderer.width) == Int(w) && Int(c2.renderer.height) == Int(h)) ペンの点=\(c2.annotations.first { $0.tool == .pencil }?.points.count ?? 0)")
                    // 矢印を選んで消し、もう一度完了 → 控えも減っているか
                    if let i = c2.annotations.firstIndex(where: { $0.tool == .arrow }) {
                        let mid = c2.toView(c2.annotations[i].curvePoint(0.4))
                        if let e = NSEvent.mouseEvent(with: .leftMouseDown, location: c2.convert(mid, to: nil), modifierFlags: [], timestamp: 0,
                                                      windowNumber: again.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                            c2.mouseDown(with: e)
                        }
                        c2.deleteSelected()
                    }
                    again.doneTapped()
                    let reloaded = EditProject.load(for: dst)?.annotations.count ?? -1
                    log("テスト: 矢印を消して完了 控えの注釈=\(reloaded)（\(n - 1) なら正しい）")
                }
                // 確認用に作った画像と控えを片付ける
                EditProject.discard(for: dst)
                try? FileManager.default.removeItem(at: dst)
                NSApp.terminate(nil)
            }
            // --test-transform <出力フォルダ> : 文字スタイル7種・画像の追加と余白・回転と反転・サイズ変更・自作の色・開き直しを通す
            // --test-extras <フォルダ> : 絵文字・枠線・曲がった矢印・強いぼかし・文字を隠す・道具の設定の保存 を通す
            if let editor, let j = args.firstIndex(of: "--test-extras"), j + 1 < args.count {
                let out = URL(fileURLWithPath: args[j + 1])
                try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
                let c = editor.canvas
                let w = c.renderer.width, h = c.renderer.height, k = c.renderer.dpiScale
                let savedPresets = UserDefaults.standard.array(forKey: "editorPresets")
                let saved = (ToolMemory.color, ToolMemory.weight, ToolMemory.arrowStyle, ToolMemory.blurStyle, ToolMemory.textStyle)
                func write(_ name: String) {
                    if let image = c.renderer.renderImage(c.annotations), let data = pngData(image, dpi: editor.dpi) {
                        try? data.write(to: out.appendingPathComponent(name))
                    }
                }
                func finish() {
                    UserDefaults.standard.set(savedPresets, forKey: "editorPresets")
                    (ToolMemory.color, ToolMemory.weight, ToolMemory.arrowStyle, ToolMemory.blurStyle, ToolMemory.textStyle) = saved
                    EditProject.discard(for: dst)
                    try? FileManager.default.removeItem(at: dst)
                    NSApp.terminate(nil)
                }
                editor.hideText(onlySensitive: true) { count in
                    log("テスト: 当てはまる文字を隠す \(count)か所 注釈=\(c.annotations.count)")
                    write("extras-sensitive.png")
                    c.undo(nil)
                    log("テスト: 取り消すと全部戻る 注釈=\(c.annotations.count)")
                    editor.hideText(onlySensitive: false) { all in
                        log("テスト: 文字をすべて隠す \(all)か所")
                        write("extras-alltext.png")
                        c.undo(nil)
                        var arrow = Annotation(tool: .arrow, p0: CGPoint(x: w * 0.1, y: h * 0.2), p1: CGPoint(x: w * 0.5, y: h * 0.2),
                                               color: EditorController.palette[0], weight: 0.3, scale: k)
                        arrow.arrowStyle = .curved
                        c.add(arrow)
                        var blur = Annotation(tool: .blur, p0: CGPoint(x: w * 0.55, y: h * 0.55), p1: CGPoint(x: w * 0.95, y: h * 0.9),
                                              color: .black, weight: 0.4, scale: k)
                        blur.blurStyle = .secure
                        c.add(blur)
                        editor.addFrame()
                        editor.addEmoji("🔥")
                        log("テスト: 曲がった矢印・強いぼかし・枠線・絵文字 注釈=\(c.annotations.count) 絵文字=\(c.annotations.last?.text ?? "") 曲がりの山=\(arrow.curvePoint(0.5).y - arrow.p0.y)")
                        write("extras-tools.png")
                        c.setTool(.rect)
                        c.setColor(EditorController.palette[4])
                        c.setWeight(0.8)
                        editor.savePreset(named: "試験用の設定")
                        c.setTool(.arrow)
                        c.setColor(EditorController.palette[0])
                        c.setWeight(0.1)
                        let n = ToolPresets.all.firstIndex { $0.name == "試験用の設定" } ?? -1
                        let applied = editor.applyPreset(at: n)
                        log("テスト: 道具の設定 保存した数=\(ToolPresets.all.count) 呼び出せた=\(applied) 道具=\(c.tool.label) 青=\(sameColor(c.color, EditorController.palette[4])) 太さ=\(c.weight)")
                        ToolPresets.remove(at: n)
                        log("テスト: 道具の設定 消したあとの数=\(ToolPresets.all.count)")
                        finish()
                    }
                }
            }
            if let editor, let j = args.firstIndex(of: "--test-transform"), j + 1 < args.count {
                let out = URL(fileURLWithPath: args[j + 1])
                try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
                let c = editor.canvas
                let r = c.renderer
                let w = r.width, h = r.height, k = r.dpiScale
                let pal = EditorController.palette
                func rgba(_ image: CGImage) -> [UInt8] {
                    var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
                    let ctx = CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                    return data
                }
                /// 左下が原点の座標で1点の色を読む
                func pixel(_ image: CGImage, _ p: CGPoint) -> [Int] {
                    let d = rgba(image)
                    let x = min(image.width - 1, max(0, Int(p.x))), y = min(image.height - 1, max(0, image.height - 1 - Int(p.y)))
                    let i = (y * image.width + x) * 4
                    return [Int(d[i]), Int(d[i + 1]), Int(d[i + 2]), Int(d[i + 3])]
                }
                func maxDiff(_ a: CGImage, _ b: CGImage) -> Int {
                    guard a.width == b.width, a.height == b.height else { return -1 }
                    let x = rgba(a), y = rgba(b)
                    var m = 0
                    for i in 0..<x.count { m = max(m, abs(Int(x[i]) - Int(y[i]))) }
                    return m
                }
                func render() -> CGImage { r.renderImage(c.annotations)! }
                func save(_ name: String) {
                    if let data = pngData(render(), dpi: editor.dpi) { try? data.write(to: out.appendingPathComponent(name)) }
                }
                func send(_ type: NSEvent.EventType, _ imagePoint: CGPoint) {
                    let inWindow = c.convert(c.toView(imagePoint), to: nil)
                    guard let e = NSEvent.mouseEvent(with: type, location: inWindow, modifierFlags: [], timestamp: 0,
                                                     windowNumber: editor.window.windowNumber, context: nil,
                                                     eventNumber: 0, clickCount: 1, pressure: 1) else { return }
                    switch type {
                    case .leftMouseDown: c.mouseDown(with: e)
                    case .leftMouseDragged: c.mouseDragged(with: e)
                    default: c.mouseUp(with: e)
                    }
                }
                func drag(from a: CGPoint, by d: CGPoint) {
                    send(.leftMouseDown, a)
                    for step in 1...6 { send(.leftMouseDragged, a + d * (CGFloat(step) / 6)) }
                    send(.leftMouseUp, a + d)
                }
                editor.window.layoutIfNeeded()
                c.display()

                // ① 文字スタイル7種
                for (n, style) in TextStyle.ordered.enumerated() {
                    var t = Annotation(tool: .text, p0: CGPoint(x: w * 0.05, y: h * (0.90 - CGFloat(n) * 0.085)), p1: .zero,
                                       color: pal[n % 6], weight: 0.22, scale: k)
                    t.p1 = t.p0
                    t.textStyle = style
                    t.text = "\(style.label) Text 123"
                    c.add(t)
                }
                c.setTool(.text)
                editor.snapshot(to: out.appendingPathComponent("ui-text.png"))
                save("1-textstyles.png")
                log("テスト: 文字スタイル \(TextStyle.ordered.count)種 台紙=\(Int(r.width))x\(Int(r.height))（元と同じなら広がっていない）")

                // ② 目印（赤い四角）と矢印を足しておく。あとで回したときに場所が合うかを見る
                var mark = Annotation(tool: .fillRect, p0: CGPoint(x: w * 0.70, y: h * 0.10), p1: CGPoint(x: w * 0.85, y: h * 0.20),
                                      color: pal[0], weight: 0.25, scale: k)
                mark.normalizeBox()
                c.add(mark)
                c.add(Annotation(tool: .arrow, p0: CGPoint(x: w * 0.55, y: h * 0.45), p1: CGPoint(x: w * 0.80, y: h * 0.30),
                                 color: pal[4], weight: 0.25, scale: k))
                var cn = Annotation(tool: .counter, p0: CGPoint(x: w * 0.62, y: h * 0.15), p1: .zero, color: pal[3], weight: 0.5, scale: k)
                cn.p1 = cn.p0
                cn.number = 7
                c.add(cn)
                let markCenter = CGPoint(x: w * 0.775, y: h * 0.15)
                let probe = CGPoint(x: w * 0.93, y: h * 0.62)   // 何も描いていない所（元の画像の色を見る）
                let before = render()
                log("テスト: 目印の色=\(pixel(before, markCenter))（赤 255,59,48 付近なら正しい） 元の画像の色=\(pixel(before, probe))")

                // ③ 回転と反転：1回ごとに、目印と元の画像の点が計算どおりの場所へ行くか
                var size = CGSize(width: r.width, height: r.height)
                var m = markCenter, q = probe
                for op in [CanvasOp.rotateLeft, .flipHorizontal, .rotateRight, .flipVertical] {
                    c.transform(op)
                    m = op.map(m, in: size); q = op.map(q, in: size)
                    size = CGSize(width: r.width, height: r.height)
                    let img = render()
                    log("テスト: \(op.label) 台紙=\(Int(r.width))x\(Int(r.height)) 目印=\(pixel(img, m)) 元の画像=\(pixel(img, q))")
                    if op == .rotateLeft { save("2-rotated-left.png") }
                }
                for _ in 0..<4 { c.undo(nil) }
                log("テスト: 4回取り消し 最初との差=\(maxDiff(before, render()))（0 なら元どおり）")
                for _ in 0..<4 { c.transform(.rotateLeft) }
                log("テスト: 左に4回転 最初との差=\(maxDiff(before, render()))（0 なら元どおり） 台紙=\(Int(r.width))x\(Int(r.height))")
                for _ in 0..<4 { c.undo(nil) }

                // ④ 画像を足す → 右へ出す → 余白が広がる → 左へ出す → 全体がずれる
                if let extra = loadImage(at: src) {
                    c.addImage(extra.image, dpi: extra.dpi, center: nil)
                    let a = c.annotations[0]
                    log("テスト: 画像を足した 道具=\(c.tool) 置いた範囲=\(a.rect) 元の画像=\(r.baseRect) 順番の先頭が画像=\(a.tool == .image)")
                    log("テスト: 足した直後の台紙=\(Int(r.width))x\(Int(r.height))（大きい画像は右どなりに並ぶ）")
                    editor.snapshot(to: out.appendingPathComponent("ui-added.png"))
                    // 四隅のつまみで半分に縮める（右下をつかんで真ん中へ。左上が止まる）
                    send(.leftMouseDown, CGPoint(x: a.rect.maxX, y: a.rect.minY))
                    send(.leftMouseDragged, CGPoint(x: a.rect.midX, y: a.rect.midY))
                    send(.leftMouseUp, CGPoint(x: a.rect.midX, y: a.rect.midY))
                    let small = c.annotations[0].rect
                    log("テスト: つまみで縮めた \(Int(small.width))x\(Int(small.height)) 比率=\(String(format: "%.4f", small.width / small.height))（元 \(String(format: "%.4f", a.rect.width / a.rect.height))） 台紙=\(Int(r.width))x\(Int(r.height))")
                    // 元の画像の中へ入れる → 余白がなくなる
                    drag(from: CGPoint(x: small.midX, y: small.midY), by: CGPoint(x: -w * 0.70, y: -h * 0.3))
                    log("テスト: 中へ入れた 台紙=\(Int(r.width))x\(Int(r.height))（元の 1200x760 に戻れば正しい）")
                    c.undo(nil)
                    // 右の外へさらに出す
                    drag(from: CGPoint(x: small.midX, y: small.midY), by: CGPoint(x: w * 0.20, y: 0))
                    log("テスト: 右へ出した 台紙=\(Int(r.width))x\(Int(r.height)) 元の画像の位置=\(r.baseOrigin) 画像=\(c.annotations[0].rect)")
                    // 足した画像の上にモザイクをかける（足した画像の中身がモザイクになるか）
                    let target = c.annotations[0].rect
                    var mosaic = Annotation(tool: .blur, p0: CGPoint(x: target.minX + target.width * 0.05, y: target.minY + target.height * 0.55),
                                            p1: CGPoint(x: target.minX + target.width * 0.75, y: target.minY + target.height * 0.95),
                                            color: pal[6], weight: 0.3, scale: k)
                    mosaic.normalizeBox()
                    let plain = pixel(render(), CGPoint(x: target.minX + target.width * 0.5, y: target.minY + target.height * 0.02))
                    c.add(mosaic)
                    let inMosaic = rgba(render())
                    var nonWhite = 0
                    let img = render()
                    for yy in stride(from: Int(mosaic.rect.minY) + 4, to: Int(mosaic.rect.maxY) - 4, by: 6) {
                        for xx in stride(from: Int(mosaic.rect.minX) + 4, to: Int(mosaic.rect.maxX) - 4, by: 6) {
                            let i = ((img.height - 1 - yy) * img.width + xx) * 4
                            if inMosaic[i + 3] > 0 && inMosaic[i] < 250 { nonWhite += 1 }
                        }
                    }
                    log("テスト: 足した画像の上のモザイク 色のついた点=\(nonWhite)（0 より多ければ、足した画像の文字がモザイクになっている） 余白の色=\(plain)")
                    c.setTool(.select)
                    editor.snapshot(to: out.appendingPathComponent("ui-combined.png"))
                    save("3-combined.png")
                    c.undo(nil)
                    // 画像の上に矢印を描けるか（矢印の道具のときは画像をつかまない）
                    c.setTool(.arrow)
                    let n0 = c.annotations.count
                    let on = c.annotations[0].rect
                    drag(from: CGPoint(x: on.minX + on.width * 0.3, y: on.midY), by: CGPoint(x: on.width * 0.4, y: on.height * 0.2))
                    log("テスト: 画像の上に矢印 \(n0)→\(c.annotations.count)個 画像は動いていない=\(c.annotations[0].rect == on)")
                    // 余白を広げない設定：外へ出しても台紙はそのまま
                    c.setTool(.select)
                    c.autoExpand = false
                    let locked = CGSize(width: r.width, height: r.height)
                    drag(from: CGPoint(x: c.annotations[0].rect.midX, y: c.annotations[0].rect.midY), by: CGPoint(x: 0, y: h * 0.8))
                    log("テスト: 余白を広げない設定で上へ出した 台紙=\(Int(r.width))x\(Int(r.height))（\(Int(locked.width))x\(Int(locked.height)) のままなら正しい）")
                    c.undo(nil)
                    c.autoExpand = true
                    // 左の外へ出す → 元の画像の位置が右へずれる
                    c.setTool(.select)
                    let now = c.annotations[0].rect
                    drag(from: CGPoint(x: now.midX, y: now.midY), by: CGPoint(x: -(now.midX + now.width), y: h * 0.1))
                    log("テスト: 左の外へ出した 台紙=\(Int(r.width))x\(Int(r.height)) 元の画像の位置=\(r.baseOrigin) 画像=\(c.annotations[0].rect)")
                    save("4-combined-left.png")
                    c.undo(nil)
                    log("テスト: 取り消し 台紙=\(Int(r.width))x\(Int(r.height)) 元の画像の位置=\(r.baseOrigin)")
                }

                // ⑤ サイズ変更：幅を半分と打つ → 比率を保って高さも半分
                let full = CGSize(width: r.width, height: r.height)
                let panel = editor.showResizePanel()
                panel.testType(width: String(Int(full.width / 2)))
                log("テスト: サイズ変更の小窓 幅に \(Int(full.width / 2)) → 変更後の予定=\(Int(panel.target.width))x\(Int(panel.target.height))")
                panel.applyTapped()
                log("テスト: サイズ変更 \(Int(full.width))x\(Int(full.height)) → \(Int(r.width))x\(Int(r.height)) 元の画像=\(r.base.width)x\(r.base.height)")
                save("5-resized.png")
                c.undo(nil)
                log("テスト: 取り消し → \(Int(r.width))x\(Int(r.height))")

                panel.view.appearance = NSAppearance(named: .darkAqua)
                panel.view.frame = NSRect(origin: .zero, size: panel.view.fittingSize)
                if let rep = panel.view.bitmapImageRepForCachingDisplay(in: panel.view.bounds) {
                    panel.view.layoutSubtreeIfNeeded()
                    panel.view.cacheDisplay(in: panel.view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("ui-resize.png"))
                }
                // 貼り付け・ドラッグで受け取る中身の読み取り（本物のクリップボードは触らない）
                let testBoard = NSPasteboard(name: NSPasteboard.Name("local.kiritori.test"))
                testBoard.clearContents()
                testBoard.writeObjects([src as NSURL])
                let fromFile = imagesFrom(pasteboard: testBoard)
                testBoard.clearContents()
                if let data = pngData(r.base, dpi: 144) { testBoard.setData(data, forType: .png) }
                let fromData = imagesFrom(pasteboard: testBoard)
                testBoard.clearContents()
                testBoard.setString("文字だけ", forType: .string)
                log("テスト: 受け取り ファイル=\(fromFile.count)枚（\(fromFile.first.map { "\($0.image.width)x\($0.image.height) \(Int($0.dpi))dpi" } ?? "-")） 画像データ=\(fromData.count)枚（\(fromData.first.map { "\(Int($0.dpi))dpi" } ?? "-")） 文字だけ=\(imagesFrom(pasteboard: testBoard).count)枚")
                testBoard.clearContents()

                // ⑥ 自分で作った色
                let saved = CustomColors.all
                editor.useCustomColor(NSColor(srgbRed: 0.10, green: 0.72, blue: 0.62, alpha: 1))
                editor.useCustomColor(NSColor(srgbRed: 0.12, green: 0.70, blue: 0.66, alpha: 1))   // 選び直し：同じ枠を上書き
                log("テスト: 自作の色 控え=\(CustomColors.all.count)個（選び直しで増えていなければ \(min(CustomColors.limit, saved.count + 1))） いまの色が一致=\(sameColor(c.color, CustomColors.all[0]))")
                editor.useCustomColor(pal[4])
                log("テスト: 最初からある色を選んだ 控え=\(CustomColors.all.count)個（増えない）")
                c.setTool(.rect)
                editor.useCustomColor(NSColor(srgbRed: 0.12, green: 0.70, blue: 0.66, alpha: 1))
                editor.snapshot(to: out.appendingPathComponent("ui-color.png"))
                CustomColors.all = saved

                // ⑦ 左に回してから完了 → 開き直しで同じ絵に戻るか
                c.transform(.rotateLeft)
                let final = render()
                let count = c.annotations.count
                let canvasSize = "\(Int(r.width))x\(Int(r.height))"
                save("6-final.png")
                editor.doneTapped()
                if let again = EditorController.open(file: dst, onFinish: { _ in }) {
                    let c2 = again.canvas
                    let img = c2.renderer.renderImage(c2.annotations)!
                    log("テスト: 開き直し 注釈=\(c2.annotations.count)/\(count) 画像つき=\(c2.annotations.filter { $0.image != nil }.count) 台紙=\(Int(c2.renderer.width))x\(Int(c2.renderer.height))（\(canvasSize)） 完了前との差=\(maxDiff(final, img))（0 なら同じ）")
                    again.window.close()
                }
                let leftovers = ((try? FileManager.default.contentsOfDirectory(atPath: EditProject.dir.path)) ?? [])
                    .filter { $0.hasPrefix(dst.deletingPathExtension().lastPathComponent) }
                log("テスト: 控えのファイル=\(leftovers.sorted())")
                EditProject.discard(for: dst)
                try? FileManager.default.removeItem(at: dst)
                NSApp.terminate(nil)
            }
            // --test-background <出力フォルダ> : 背景ツールの大きさ・位置・比率・種類・開き直し・自動で付けるを通す
            if let editor, let j = args.firstIndex(of: "--test-background"), j + 1 < args.count {
                let out = URL(fileURLWithPath: args[j + 1])
                try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
                let c = editor.canvas, r = c.renderer
                let w = Int(r.width), h = Int(r.height), k = r.dpiScale
                func pixel(_ image: CGImage, _ x: Int, _ yFromBottom: Int) -> [Int] {
                    var d = [UInt8](repeating: 0, count: 4)
                    let ctx = CGContext(data: &d, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                    ctx.draw(image, in: CGRect(x: -x, y: -yFromBottom, width: image.width, height: image.height))
                    return d.map(Int.init)
                }
                func save(_ image: CGImage, _ name: String) {
                    if let data = pngData(image, dpi: editor.dpi) { try? data.write(to: out.appendingPathComponent(name)) }
                }
                let savedLast = BackdropStyle.self == BackdropStyle.self ? BackgroundStore.last : BackdropStyle()
                let savedPresets = BackgroundStore.presets, savedAuto = BackgroundStore.autoPreset
                editor.window.layoutIfNeeded()
                let plain = r.renderFinal(c.annotations)!
                log("テスト: 背景なし \(plain.width)x\(plain.height)（元 \(w)x\(h)）")

                let panel = editor.showBackgroundPanel()
                var s = c.background
                s.kind = .gradient; s.gradient = 2; s.padding = 0.3; s.inset = 0; s.corners = 0.5; s.shadow = 0.6; s.alignment = 4; s.ratio = 0
                c.background = s
                panel.sync()
                let pad = Int((0.3 * 200 * k).rounded())
                var img = r.renderFinal(c.annotations)!
                log("テスト: 背景あり \(img.width)x\(img.height)（\(w + pad * 2)x\(h + pad * 2) なら正しい） 左下の角=\(pixel(img, 2, 2)) 真ん中=\(pixel(img, img.width / 2, img.height / 2)) 元の真ん中=\(pixel(plain, w / 2, h / 2)) スクショの角（丸めた外）=\(pixel(img, pad + 1, pad + 1))")
                save(img, "bg-1-gradient.png")
                c.display()
                editor.snapshot(to: out.appendingPathComponent("bg-ui.png"))

                s.alignment = 7; s.ratio = 16.0 / 9
                c.background = s
                img = r.renderFinal(c.annotations)!
                log("テスト: 下寄せ・16:9 \(img.width)x\(img.height) 比率=\(String(format: "%.3f", Double(img.width) / Double(img.height)))（1.778） いちばん下の真ん中=\(pixel(img, img.width / 2, 1))（スクショの色なら下に付いている） いちばん上の真ん中=\(pixel(img, img.width / 2, img.height - 2))")
                save(img, "bg-2-bottom-169.png")

                s.alignment = 4; s.ratio = 0; s.inset = 0.5; s.kind = .color; s.color = NSColor(srgbRed: 0.1, green: 0.2, blue: 0.4, alpha: 1)
                c.background = s
                img = r.renderFinal(c.annotations)!
                let ins = Int((0.5 * 80 * k).rounded())
                log("テスト: 単色・内側の余白 \(img.width)x\(img.height)（\(w + (pad + ins) * 2)x\(h + (pad + ins) * 2)） 角=\(pixel(img, 2, 2))（26,51,102 付近） 内側の余白=\(pixel(img, pad + ins / 2, img.height / 2))")
                save(img, "bg-3-color-inset.png")

                s.inset = 0; s.kind = .blur
                c.background = s
                save(r.renderFinal(c.annotations)!, "bg-4-blur.png")
                s.kind = .wallpaper
                c.background = s
                log("テスト: 壁紙が取れている=\(BackgroundPainter.wallpaper != nil)")
                save(r.renderFinal(c.annotations)!, "bg-5-wallpaper.png")

                // 矢印を1本描いて完了 → 開き直しで背景も描いたものも戻るか
                s.kind = .gradient; s.gradient = 0
                c.background = s
                c.add(Annotation(tool: .arrow, p0: CGPoint(x: r.width * 0.3, y: r.height * 0.3), p1: CGPoint(x: r.width * 0.6, y: r.height * 0.5),
                                 color: EditorController.palette[0], weight: 0.3, scale: k))
                let final = r.renderFinal(c.annotations)!
                panel.savePreset(named: "試験用の背景")
                editor.doneTapped()
                let written = pixelSize(of: dst)
                if let again = EditorController.open(file: dst, onFinish: { _ in }) {
                    let c2 = again.canvas
                    let img2 = c2.renderer.renderFinal(c2.annotations)!
                    var same = img2.width == final.width && img2.height == final.height
                    if same { same = pixel(img2, 3, 3) == pixel(final, 3, 3) && pixel(img2, final.width / 2, final.height / 2) == pixel(final, final.width / 2, final.height / 2) }
                    log("テスト: 完了後のファイル=\(written.map { "\($0.0)x\($0.1)" } ?? "?") 開き直し 背景が戻った=\(c2.background.enabled) 元の画像=\(Int(c2.renderer.width))x\(Int(c2.renderer.height)) 注釈=\(c2.annotations.count) 同じ絵=\(same)")
                    // 背景を外して完了 → 元の大きさに戻るか
                    var off = c2.background
                    off.enabled = false
                    c2.background = off
                    again.doneTapped()
                    log("テスト: 背景を外して完了 ファイル=\(pixelSize(of: dst).map { "\($0.0)x\($0.1)" } ?? "?")（\(w)x\(h) なら元の大きさ）")
                }
                // 撮ったら自動で付ける
                let auto = Prefs.historyDir.appendingPathComponent("shot \(timestampName()) auto.png")
                try? FileManager.default.copyItem(at: src, to: auto)
                BackgroundStore.autoPreset = "試験用の背景"
                BackgroundStore.applyAuto(to: auto)
                let loaded = EditProject.load(for: auto)
                log("テスト: 自動で付ける 保存した組み合わせ=\(BackgroundStore.presets.map(\.name)) ファイル=\(pixelSize(of: auto).map { "\($0.0)x\($0.1)" } ?? "?") 控えの背景=\(loaded?.background?.enabled ?? false) 控えの元の画像=\(loaded.map { "\($0.base.width)x\($0.base.height)" } ?? "なし")")
                EditProject.discard(for: auto)
                try? FileManager.default.removeItem(at: auto)
                BackgroundStore.presets = savedPresets
                BackgroundStore.autoPreset = savedAuto
                BackgroundStore.last = savedLast
                EditProject.discard(for: dst)
                try? FileManager.default.removeItem(at: dst)
                NSApp.terminate(nil)
            }
            if let editor, let j = args.firstIndex(of: "--test-snapshot"), j + 1 < args.count {
                let url = URL(fileURLWithPath: args[j + 1])
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    editor.snapshot(to: url)
                    let f = editor.window.frame
                    log("テスト: 画面を書き出し ウィンドウ=\(Int(f.width))x\(Int(f.height))")
                    NSApp.terminate(nil)
                }
            }
        }
        // --test-record <秒> : 決まった範囲を指定の秒数だけ録画して、変換・小窓・履歴まで通す
        if let i = args.firstIndex(of: "--test-record"), i + 1 < args.count, let secs = Double(args[i + 1]) {
            KeystrokeOverlay.testWithoutMonitor = args.contains("--test-keys")
            pasteboardForCopy = NSPasteboard(name: NSPasteboard.Name("local.kiritori.test"))
            let screen = NSScreen.main ?? NSScreen.screens[0]
            let rect = NSRect(x: screen.frame.minX + 120, y: screen.frame.minY + 200, width: 480, height: 300)
            RecordController.shared.onFinish = { file in
                if let file, isGIF(file) {
                    let frames = CGImageSourceCreateWithURL(file as CFURL, nil).map { CGImageSourceGetCount($0) } ?? 0
                    let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
                    log("テスト: 録画(GIF) \(file.lastPathComponent) コマ=\(frames) bytes=\(size) 大きさ=\(pixelSize(of: file).map { "\($0.0)x\($0.1)" } ?? "?") 小窓の数=\(PopupController.shared.count) 履歴にある=\(HistoryStore.items().contains { $0.url == file })")
                    if let j = args.firstIndex(of: "--test-keep"), j + 1 < args.count {
                        try? FileManager.default.copyItem(at: file, to: URL(fileURLWithPath: args[j + 1]))
                    }
                    NSApp.terminate(nil)
                    return
                }
                guard let file, let info = videoInfo(file) else { log("テスト: 録画 失敗"); NSApp.terminate(nil); return }
                let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
                let audio = AVURLAsset(url: file).tracks(withMediaType: .audio).count
                log("テスト: 録画 音のトラック=\(audio)本")
                log("テスト: 録画 \(file.lastPathComponent) 長さ=\(String(format: "%.1f", info.seconds))秒 映像=\(info.width)x\(info.height) bytes=\(size) 小窓の数=\(PopupController.shared.count)")
                PopupController.shared.latest?.copyTapped()
                let urls = pasteboardForCopy.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
                log("テスト: 録画をコピー ファイルとして入った=\(urls.first?.lastPathComponent ?? "なし") 後の小窓の数=\(PopupController.shared.count)")
                let inHistory = HistoryStore.items().contains { $0.url == file }
                log("テスト: 録画が履歴にある=\(inHistory)")
                if let j = args.firstIndex(of: "--test-keep"), j + 1 < args.count {
                    try? FileManager.default.copyItem(at: file, to: URL(fileURLWithPath: args[j + 1]))
                }
                NSApp.terminate(nil)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                RecordController.shared.start(rect: rect, screen: screen)
                if args.contains("--test-keys") {   // 録画の途中で、キーを押したことにして表示を出す
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { RecordController.shared.testKey("⌘ ⇧ 4") }
                }
                if args.contains("--test-click") {   // 範囲の真ん中を、録画の途中で3回クリックしたことにする
                    for k in 0..<3 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2 + Double(k) * 0.6) {
                            RecordController.shared.testPing(at: NSPoint(x: rect.midX, y: rect.midY))
                        }
                    }
                }
                if args.contains("--test-pause") {   // 3分の1の所で一時停止、3分の2の所で再開する
                    DispatchQueue.main.asyncAfter(deadline: .now() + secs / 3) {
                        RecordController.shared.togglePause()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { log("テスト: 一時停止中=\(RecordController.shared.isPaused) 録画中=\(RecordController.shared.isRecording)") }
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + secs * 2 / 3) { RecordController.shared.togglePause() }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + secs) { RecordController.shared.stop() }
            }
            let probe = NSPoint(x: screen.frame.midX, y: screen.frame.midY)
            log("テスト: 画面の真ん中の下のウィンドウ=\(windowFrame(under: probe).map { "\(Int($0.width))x\(Int($0.height))" } ?? "なし") マイクの数=\(audioInputDevices().count)")
        }
        // --test-mix <動画> : 音が2本ある動画を1本に混ぜる処理だけを通す（動画は上書きされる）
        if let i = args.firstIndex(of: "--test-mix"), i + 1 < args.count {
            let url = URL(fileURLWithPath: args[i + 1])
            let before = AVURLAsset(url: url).tracks(withMediaType: .audio).count
            mixAudioTracksIfNeeded(url) { out in
                let asset = AVURLAsset(url: out)
                log("テスト: 音を混ぜる 音のトラック \(before)本→\(asset.tracks(withMediaType: .audio).count)本 映像=\(asset.tracks(withMediaType: .video).count)本 長さ=\(String(format: "%.2f", CMTimeGetSeconds(asset.duration)))秒")
                NSApp.terminate(nil)
            }
        }
        // --test-selector <出力png> : 範囲選びの幕を画面に出さずに組み、マウス操作を再現して書き出す
        //   --test-hover を付けると、ウィンドウにカーソルを乗せたときの見た目を書き出す
        if let i = args.firstIndex(of: "--test-selector"), i + 1 < args.count {
            let size = NSSize(width: 1280, height: 720)
            let host = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
            let view = SelectionView(frame: NSRect(origin: .zero, size: size))
            host.contentView = view
            func send(_ type: NSEvent.EventType, _ p: NSPoint, clicks: Int = 1) {
                guard let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: 0, windowNumber: host.windowNumber,
                                                 context: nil, eventNumber: 0, clickCount: clicks, pressure: 1) else { return }
                switch type {
                case .leftMouseDown: view.mouseDown(with: e)
                case .leftMouseDragged: view.mouseDragged(with: e)
                default: view.mouseUp(with: e)
                }
            }
            func drag(_ a: NSPoint, _ b: NSPoint) { send(.leftMouseDown, a); send(.leftMouseDragged, b); send(.leftMouseUp, b) }
            func text(_ r: NSRect?) -> String { r.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "なし" }
            var result = "呼ばれていない"
            view.onDone = { rect, gif in result = (rect.map { "範囲 " + text($0) } ?? "画面全体") + (gif ? "・GIF" : "・動画") }
            if args.contains("--test-hover") {
                view.testHover(NSRect(x: 260, y: 140, width: 720, height: 460))
            } else {
                drag(NSPoint(x: 300, y: 200), NSPoint(x: 900, y: 520))
                log("テスト: 範囲選び ドラッグで選ぶ → \(text(view.selection))")
                drag(NSPoint(x: 900, y: 520), NSPoint(x: 1000, y: 600))
                log("テスト: 範囲選び 右上のつまみで広げる → \(text(view.selection))")
                drag(NSPoint(x: 300, y: 400), NSPoint(x: 250, y: 400))
                log("テスト: 範囲選び 左の辺のつまみで広げる → \(text(view.selection))")
                drag(NSPoint(x: 600, y: 400), NSPoint(x: 660, y: 350))
                log("テスト: 範囲選び 中をつかんで動かす → \(text(view.selection))")
                view.startTapped()
                log("テスト: 範囲選び 録画開始 → \(result)")
                view.fullTapped()
                log("テスト: 範囲選び 画面全体のボタン → \(text(view.selection))")
                view.startGIFTapped()
                log("テスト: 範囲選び 画面全体で GIF 録画開始 → \(result)")
                let before = (Prefs.recordSystemAudio, Prefs.highlightClicks, Prefs.showCursor)
                view.audioTapped(); view.clicksTapped(); view.cursorTapped()
                log("テスト: 範囲選び 帯の切り替え PCの音 \(before.0)→\(Prefs.recordSystemAudio) クリック \(before.1)→\(Prefs.highlightClicks) カーソル \(before.2)→\(Prefs.showCursor)")
                view.audioTapped(); view.clicksTapped(); view.cursorTapped()   // 元に戻す
                drag(NSPoint(x: 320, y: 180), NSPoint(x: 960, y: 560))
                view.testSetSize(width: 800, height: 450)
                log("テスト: 範囲選び 数字で 800×450 → \(text(view.selection))（左上は動かない）")
                view.testSetSize(width: 5000, height: 10)
                log("テスト: 範囲選び 数字で 5000×10（はみ出し・小さすぎ）→ \(text(view.selection))")
                view.syncSettings()
                view.setMicLevel(0.6)   // 見た目の確認用（マイクが入っていれば緑が6割まで伸びる）
                drag(NSPoint(x: 320, y: 180), NSPoint(x: 960, y: 560))   // 書き出し用にもう一度選ぶ
            }
            // 録画中のメニューバーの印（音量の棒つき）も書き出す
            if let tiff = recordingIndicatorImage(micLevel: 0.6).tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 1] + ".indicator.png"))
            }
            for (text, code, flags) in [("⌘⇧4", UInt16(21), NSEvent.ModifierFlags([.command, .shift])), ("a だけ", UInt16(0), NSEvent.ModifierFlags([])),
                                        ("⌃⌘→", UInt16(124), NSEvent.ModifierFlags([.control, .command]))] {
                if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                                            characters: code == 21 ? "4" : "a", charactersIgnoringModifiers: code == 21 ? "4" : "a",
                                            isARepeat: false, keyCode: code) {
                    log("テスト: キー表示 \(text) → ⌘などだけ=\(KeystrokeOverlay.describe(e, all: false) ?? "出さない") ／ 全部=\(KeystrokeOverlay.describe(e, all: true) ?? "出さない")")
                }
            }
            view.layoutSubtreeIfNeeded()
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 1]))
            }
            log("テスト: 範囲選びの幕を書き出し 選択=\(text(view.selection))")
            if !args.contains("--test-record") && !args.contains("--test-history") { NSApp.terminate(nil) }
        }
        // --test-ocr <画像> : 画像の文字を読み取って、結果を記録する（クリップボードは試験用のものを使う）
        if let i = args.firstIndex(of: "--test-ocr"), i + 1 < args.count {
            pasteboardForCopy = NSPasteboard(name: NSPasteboard.Name("local.kiritori.test"))
            let started = Date()
            TextReader.read(file: URL(fileURLWithPath: args[i + 1])) { text, codes in
                let lines = text.split(separator: "\n")
                log("テスト: 文字認識 \(String(format: "%.2f", Date().timeIntervalSince(started)))秒 行数=\(lines.count) 文字数=\(text.count) QR=\(codes) 1行目=「\(lines.first.map(String.init) ?? "")」")
                TextReader.copyResult(text: text, codes: codes)
                log("テスト: 文字認識 クリップボードに入った文字数=\(pasteboardForCopy.string(forType: .string)?.count ?? 0)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { NSApp.terminate(nil) }
            }
        }
        // --test-pin <画像> <出力png> : 画像をピン留めして、大きさ・濃さ・移動・ロック・閉じるを通し、見た目を書き出す
        if let i = args.firstIndex(of: "--test-pin"), i + 2 < args.count {
            let file = URL(fileURLWithPath: args[i + 1])
            if let pin = PinController.shared.pin(file: file, at: NSRect(x: 300, y: 400, width: 10, height: 10)) {
                let f0 = pin.frame
                log("テスト: ピン留め 等倍の大きさ=\(Int(pin.naturalSize.width))x\(Int(pin.naturalSize.height)) 窓=\(Int(f0.width))x\(Int(f0.height)) 左上=(\(Int(f0.minX)),\(Int(f0.maxY)))（300,410 なら撮った場所の左上に合っている）")
                pin.setZoom(0.5)
                log("テスト: ピン留め 大きさ50% → \(Int(pin.frame.width))x\(Int(pin.frame.height)) 真ん中のずれ=\(Int(abs(pin.frame.midX - f0.midX) + abs(pin.frame.midY - f0.midY)))")
                pin.setOpacity(0.5)
                pin.setLocked(true)
                log("テスト: ピン留め 濃さ=\(pin.alphaValue) ロック=\(pin.isLocked) クリックを通す=\(pin.ignoresMouseEvents) ロック中の数=\(PinController.shared.hasLocked)")
                PinController.shared.unlockAll()
                pin.setZoom(1)
                pin.setOpacity(1)
                if let view = pin.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    (view as? PinView)?.hovering = true
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 2]))
                }
                PinController.shared.close(pin)
                log("テスト: ピン留め 閉じたあとの数=\(PinController.shared.pins.count)")
            } else {
                log("テスト: ピン留め 失敗")
            }
            NSApp.terminate(nil)
        }
        // --test-stitch <出力png> : スクロール撮影のつなぎ合わせだけを、作り物の縦長の画像で試す
        if let i = args.firstIndex(of: "--test-stitch"), i + 1 < args.count {
            let w = 900, tall = 5200, h = 700
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: tall, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                       isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: w, height: tall).fill()
            var seed: UInt64 = 42
            func rnd() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat((seed >> 33) % 1000) / 1000 }
            var y = CGFloat(tall) - 40
            var n = 1
            while y > 20 {   // 文章の行と、ところどころ色の帯。途中に何も無い広い余白も入れる
                if n % 23 != 0 {
                    let text = "\(n) 行目 " + String(repeating: "あいうえお ", count: Int(2 + rnd() * 9))
                    NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 16 + rnd() * 10),
                                                                  .foregroundColor: NSColor(white: rnd() * 0.4, alpha: 1)]).draw(at: NSPoint(x: 30 + rnd() * 60, y: y))
                    if n % 7 == 0 { NSColor(hue: rnd(), saturation: 0.5, brightness: 0.9, alpha: 1).setFill(); NSRect(x: 500 + rnd() * 100, y: y - 6, width: 240, height: 30).fill() }
                    y -= 34 + rnd() * 16
                } else {
                    y -= 260
                }
                n += 1
            }
            NSGraphicsContext.restoreGraphicsState()
            let full = rep.cgImage!
            let stitcher = ScrollStitcher()
            var offsets = [0, 60, 190, 420, 421, 421, 700, 1100, 1500, 1830, 2300, 2900, 3340, 3900, 4400, 4500]
            offsets = offsets.filter { $0 + h <= tall }
            var failed = 0
            for o in offsets {
                let frame = full.cropping(to: CGRect(x: 0, y: o, width: w, height: h))!
                if !stitcher.add(frame) { failed += 1 }
            }
            let expected = (offsets.last ?? 0) + h
            var same = false
            if let out = stitcher.result() {
                if let data = pngData(out, dpi: 144) { try? data.write(to: URL(fileURLWithPath: args[i + 1])) }
                // 元の画像の同じ範囲と、ピクセルが同じかを比べる
                if out.height == expected, let want = full.cropping(to: CGRect(x: 0, y: 0, width: w, height: expected)) {
                    func bytes(_ image: CGImage) -> [UInt8] {
                        var buf = [UInt8](repeating: 0, count: image.width * image.height * 4)
                        buf.withUnsafeMutableBytes { b in
                            CGContext(data: b.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
                                .draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                        }
                        return buf
                    }
                    same = bytes(out) == bytes(want)
                }
            }
            log("テスト: つなぎ合わせ コマ=\(offsets.count) つなげなかった=\(failed) 高さ=\(stitcher.totalHeight)（\(expected) なら正しい） 元の画像と同じ=\(same)")
            NSApp.terminate(nil)
        }
        // --test-shot-overlay <画像> <出力png> : 範囲選びの幕（拡大鏡・十字線）を、止めた画面の代わりの画像で描いて書き出す
        if let i = args.firstIndex(of: "--test-shot-overlay"), i + 2 < args.count,
           let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[i + 1]) as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            let size = NSSize(width: CGFloat(image.width) / 2, height: CGFloat(image.height) / 2)
            let view = ShotSelectionView(frame: NSRect(origin: .zero, size: size), frozen: image)
            let dragging = args.contains("--test-dragging")
            view.testSet(mouse: NSPoint(x: size.width * 0.31, y: size.height * 0.932), start: dragging ? NSPoint(x: size.width * 0.7, y: size.height * 0.4) : nil)
            let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: image.width, pixelsHigh: image.height, bitsPerSample: 8, samplesPerPixel: 4,
                                       hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            out.size = size
            if let overlay = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: overlay)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
                NSImage(cgImage: image, size: size).draw(in: NSRect(origin: .zero, size: size))
                overlay.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
                NSGraphicsContext.restoreGraphicsState()
                try? out.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 2]))
            }
            log("テスト: 範囲選びの幕（スクショ） 選択=\(view.selection.map { "\(Int($0.width))x\(Int($0.height))" } ?? "なし")")
            NSApp.terminate(nil)
        }
        // --test-area-drag : 範囲の撮影を本物の幕で始め、ドラッグしたことにして、切り出し・保存・小窓まで通す
        if args.contains("--test-area-drag") {
            pasteboardForCopy = NSPasteboard(name: NSPasteboard.Name("local.kiritori.test"))
            CaptureController.shared.capture(.area)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                CaptureController.shared.testDragSelection(from: NSPoint(x: 200, y: 300), to: NSPoint(x: 620, y: 560))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    let newest = HistoryStore.items().first
                    var colors = Set<UInt32>()
                    if let url = newest?.url, let rep = NSBitmapImageRep(data: (try? Data(contentsOf: url)) ?? Data()) {
                        for y in stride(from: 0, to: rep.pixelsHigh, by: 9) { for x in stride(from: 0, to: rep.pixelsWide, by: 9) {
                            if let c = rep.colorAt(x: x, y: y) { colors.insert(UInt32(c.redComponent * 255) << 16 | UInt32(c.greenComponent * 255) << 8 | UInt32(c.blueComponent * 255)) }
                        } }
                    }
                    log("テスト: 範囲の撮影（幕でドラッグ 420x260）→ \(newest.map { "\($0.url.lastPathComponent) \(pixelSize(of: $0.url).map { "\($0.0)x\($0.1)" } ?? "?")" } ?? "なし") 色の種類=\(colors.count) 小窓の数=\(PopupController.shared.count)")
                    if let newest, Date().timeIntervalSince(newest.date) < 10 { try? FileManager.default.removeItem(at: newest.url) }
                    NSApp.terminate(nil)
                }
            }
        }
        // --test-timer : 範囲選びを飛ばして、1秒数えてから決まった範囲を撮る
        if args.contains("--test-timer") {
            let screen = NSScreen.main ?? NSScreen.screens[0]
            let rect = NSRect(x: screen.frame.minX + 120, y: screen.frame.minY + 200, width: 480, height: 300)
            CaptureController.shared.testTimerCapture(rect: rect, screen: screen, seconds: 1)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                let newest = HistoryStore.items().first
                log("テスト: セルフタイマー 撮れた=\(newest.map { "\($0.url.lastPathComponent) \(pixelSize(of: $0.url).map { "\($0.0)x\($0.1)" } ?? "?")" } ?? "なし") 小窓の数=\(PopupController.shared.count)")
                if let newest, Date().timeIntervalSince(newest.date) < 10 { try? FileManager.default.removeItem(at: newest.url) }
                NSApp.terminate(nil)
            }
        }
        // --test-scroll <秒> : 範囲選びを飛ばして、決まった範囲を指定の秒数だけ撮り続けて完了する（スクロールはしない）
        if let i = args.firstIndex(of: "--test-scroll"), i + 1 < args.count, let secs = Double(args[i + 1]) {
            if #available(macOS 14.0, *) {
                let screen = NSScreen.main ?? NSScreen.screens[0]
                let rect = NSRect(x: screen.frame.minX + 120, y: screen.frame.minY + 200, width: 480, height: 300)
                let session = ScrollCaptureSession(rect: rect, screen: screen)
                session.onFinish = { image in
                    log("テスト: スクロール撮影 止まった画面で\(secs)秒 → \(image.map { "\($0.width)x\($0.height)" } ?? "失敗")（960x600 なら、動いていないと正しく判断できている）")
                    NSApp.terminate(nil)
                }
                session.start()
                DispatchQueue.main.asyncAfter(deadline: .now() + secs) { session.doneTapped() }
            }
        }
        // --test-pending-shot : 仮の幕を出したまま画面を止めて、幕が絵に写るかを明るさの平均で比べる
        if args.contains("--test-pending-shot") {
            func mean(_ shots: [(screen: NSScreen, image: CGImage)]) -> String {
                shots.map { shot -> String in
                    let rep = NSBitmapImageRep(cgImage: shot.image)
                    var sum = 0.0, n = 0.0
                    for y in stride(from: 0, to: rep.pixelsHigh, by: 16) { for x in stride(from: 0, to: rep.pixelsWide, by: 16) {
                        if let c = rep.colorAt(x: x, y: y) { sum += Double(c.redComponent + c.greenComponent + c.blueComponent) / 3; n += 1 }
                    } }
                    return String(format: "%.4f", sum / max(n, 1))
                }.joined(separator: " / ")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                captureAllScreens { before in
                    log("テスト: 幕なしの明るさ \(mean(before))")
                    let pending = PendingCrosshair()
                    pending.show()
                    do {
                        captureAllScreens(hide: ProcessInfo.processInfo.environment["KT_NOHIDE"] == nil ? pending.panels : []) { after in
                            log("テスト: 幕ありの明るさ \(mean(after))")
                            pending.close()
                            NSApp.terminate(nil)
                        }
                    }
                }
            }
        }
        // --test-pending : 仮の幕でカーソルが十字になるか、止めた絵に幕が写らないかを確かめる
        if args.contains("--test-pending") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                func describe(_ c: NSCursor?) -> String { c.map { "大きさ \(Int($0.image.size.width))x\(Int($0.image.size.height)) 中心 \(Int($0.hotSpot.x)),\(Int($0.hotSpot.y))" } ?? "なし" }
                log("テスト: 出す前のカーソル \(describe(NSCursor.currentSystem))／十字の見本 \(describe(NSCursor.crosshair))")
                let pending = PendingCrosshair()
                let started = Date()
                pending.show()
                log("テスト: 仮の幕を出すまで \(Int(Date().timeIntervalSince(started) * 1000))ms")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    log("テスト: 0.15秒後のカーソル \(describe(NSCursor.currentSystem))")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        log("テスト: 0.75秒後のカーソル \(describe(NSCursor.currentSystem))")
                        pending.close()
                        NSApp.terminate(nil)
                    }
                }
            }
        }
        // --test-freeze : 全部の画面を止めた画像にできるかだけを確かめる（幕は出さない）
        if args.contains("--test-freeze") {
          // 起動してすぐは画面の一覧がまだ無いので、少し待ってから測る（ふだんの使い方に合わせる）
          DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            let started = Date()
            captureAllScreens { shots in
                let text = shots.map { "\($0.image.width)x\($0.image.height)（画面 \(Int($0.screen.frame.width))x\(Int($0.screen.frame.height))・倍率 \($0.screen.backingScaleFactor)）" }.joined(separator: " / ")
                // 止めた絵が「中身のある絵」かを確かめる（真ん中あたりを切り出して、色の種類を数える）
                for shot in shots {
                    let part = shot.image.cropping(to: CGRect(x: shot.image.width / 4, y: shot.image.height / 4, width: 400, height: 300))
                    var colors = Set<UInt32>()
                    if let part, let rep = Optional(NSBitmapImageRep(cgImage: part)) {
                        for y in stride(from: 0, to: rep.pixelsHigh, by: 7) { for x in stride(from: 0, to: rep.pixelsWide, by: 7) {
                            if let c = rep.colorAt(x: x, y: y) { colors.insert(UInt32(c.redComponent * 255) << 16 | UInt32(c.greenComponent * 255) << 8 | UInt32(c.blueComponent * 255)) }
                        } }
                    }
                    log("テスト: 止めた絵 \(shot.image.width)x\(shot.image.height) 切り出した所の色の種類=\(colors.count)")
                }
                log("テスト: 画面を止める 枚数=\(shots.count) \(String(format: "%.2f", Date().timeIntervalSince(started)))秒 \(text)")
                NSApp.terminate(nil)
            }
          }
        }
        // --test-history <出力png> : 履歴の画面を画面に出さずに組み、選ぶ・キー・削除・小窓に戻すを通して書き出す
        if let i = args.firstIndex(of: "--test-history"), i + 1 < args.count {
            HistoryController.headless = true
            pasteboardForCopy = NSPasteboard(name: NSPasteboard.Name("local.kiritori.test"))
            let out = URL(fileURLWithPath: args[i + 1])
            let h = HistoryController.shared
            // 消す確認用に、いちばん新しい画像の写しを「未来の日付」で1枚足す（先頭に来る）
            let dummy = Prefs.historyDir.appendingPathComponent("shot 2099-01-01 00.00.00.png")
            if let newest = HistoryStore.items().first { try? FileManager.default.copyItem(at: newest.url, to: dummy) }
            h.show()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                let n0 = h.count
                log("テスト: 履歴 枚数=\(n0) 選択=\(h.selected)")
                h.deleteSelected()
                log("テスト: 履歴 先頭を削除 枚数 \(n0)→\(h.count) ファイルが消えた=\(!FileManager.default.fileExists(atPath: dummy.path))")
                h.testClick(2)
                log("テスト: 履歴 3枚目を押した 選択=\(h.selected)")
                _ = h.testKey(kVK_LeftArrow)
                log("テスト: 履歴 ←キー 選択=\(h.selected)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    h.snapshot(to: out)
                    _ = h.testKey(kVK_ANSI_C, command: true)
                    let bytes = pasteboardForCopy.data(forType: .png)?.count ?? 0
                    log("テスト: 履歴 ⌘C pngBytes=\(bytes) 閉じた=\(!h.isOpen)")
                    h.show()
                    h.select(1)
                    _ = h.testKey(kVK_Return)
                    log("テスト: 履歴 return で小窓に戻す 小窓の数=\(PopupController.shared.count) 閉じた=\(!h.isOpen)")
                    _ = h.testKey(kVK_Escape)
                    NSApp.terminate(nil)
                }
            }
        }
        // --test-settings <出力フォルダ> : 設定画面を画面に出さずに組み、各タブを画像にして、ショートカットの変更を通す
        if let i = args.firstIndex(of: "--test-settings"), i + 1 < args.count {
            let out = URL(fileURLWithPath: args[i + 1])
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            SettingsController.headless = true
            let c = SettingsController.shared
            c.show()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                for n in c.tabs.tabViewItems.indices { c.snapshot(tab: n, to: out.appendingPathComponent("settings-\(n).png")) }
                log("テスト: 設定 タブ=\(c.tabs.tabViewItems.map(\.label))")
                guard let area = c.shortcutFields.first(where: { $0.spec.name == "area" }),
                      let full = c.shortcutFields.first(where: { $0.spec.name == "full" }) else { NSApp.terminate(nil); return }
                let before = area.title
                area.start()
                let noMods = area.apply(keyCode: UInt32(kVK_ANSI_9), flags: [])
                let badKey = area.apply(keyCode: UInt32(kVK_Tab), flags: [.command])
                let fullKey = Prefs.hotKey("full", defaultKey: kVK_ANSI_3)
                let clash = area.apply(keyCode: fullKey.key, flags: modifierFlags(fromCarbon: fullKey.mods))
                log("テスト: 設定 断る例 修飾キーなし=\(noMods ?? "通った") 使えないキー=\(badKey ?? "通った") かぶり=\(clash ?? "通った") まだ打ち込み中=\(area.isRecording)")
                _ = area.apply(keyCode: UInt32(kVK_ANSI_9), flags: [.control, .option])
                log("テスト: 設定 変えた \(before)→\(area.title) 打ち込み終了=\(!area.isRecording) 保存された値=\(Prefs.hotKey("area", defaultKey: kVK_ANSI_4))")
                c.snapshot(tab: 1, to: out.appendingPathComponent("settings-shortcut-changed.png"))
                full.start()
                _ = full.apply(keyCode: UInt32(kVK_Delete), flags: [])
                log("テスト: 設定 delete で「なし」=\(full.title)")
                full.start()
                _ = full.apply(keyCode: UInt32(kVK_Escape), flags: [])
                log("テスト: 設定 esc でやめる 変わらない=\(full.title)")
                Prefs.resetHotKey("area"); Prefs.resetHotKey("full")
                c.refresh()
                log("テスト: 設定 最初に戻した area=\(area.title) full=\(full.title)")
                // 切り替えが設定に届くか
                let was = Prefs.popupSide
                Prefs.popupSide = "right"
                c.snapshot(tab: 2, to: out.appendingPathComponent("settings-popup-right.png"))
                Prefs.popupSide = was
                NSApp.terminate(nil)
            }
        }
        // --test-settings-show <出力フォルダ> : 設定画面を実際に開き、その窓だけをタブごとに撮って閉じる
        if let i = args.firstIndex(of: "--test-settings-show"), i + 1 < args.count {
            let out = URL(fileURLWithPath: args[i + 1])
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let c = SettingsController.shared
            c.show()
            var n = 0
            func next() {
                guard let window = c.window, c.tabs.tabViewItems.indices.contains(n) else { NSApp.terminate(nil); return }
                c.tabs.selectedTabViewItemIndex = n
                c.refresh()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    let task = Process()
                    task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    task.arguments = ["-x", "-o", "-l\(window.windowNumber)", out.appendingPathComponent("window-\(n).png").path]
                    try? task.run()
                    task.waitUntilExit()
                    n += 1
                    next()
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { next() }
        }
        // --test-video <動画> <出力フォルダ> [--test-video-show] : 動画エディタで、切り出し・コマの画像・GIF・別名保存・完了・元に戻す・音を消して縮めるを通す
        if let i = args.firstIndex(of: "--test-video"), i + 2 < args.count {
            let src = URL(fileURLWithPath: args[i + 1]), out = URL(fileURLWithPath: args[i + 2])
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let show = args.contains("--test-video-show")
            VideoEditorController.headless = !show
            let file = Prefs.historyDir.appendingPathComponent("rec \(timestampName()) test.mp4")
            try? FileManager.default.copyItem(at: src, to: file)
            func describe(_ url: URL) -> String {
                let asset = AVURLAsset(url: url)
                let info = videoInfo(url)
                return "\(String(format: "%.2f", info?.seconds ?? -1))秒 \(info?.width ?? 0)x\(info?.height ?? 0) 音=\(asset.tracks(withMediaType: .audio).count)本 \(((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0) / 1024)KB"
            }
            func cleanup() {
                try? FileManager.default.removeItem(at: VideoExporter.originalURL(for: file))
                try? FileManager.default.removeItem(at: file)
                NSApp.terminate(nil)
            }
            guard let editor = VideoEditorController.open(file: file) else { log("テスト: 動画エディタが開かない"); cleanup(); return }
            log("テスト: 動画 開いた \(describe(file))")
            if show {
                editor.setTrim(start: 1.2, end: 4.4)
                editor.seek(2.5)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    let task = Process()
                    task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    task.arguments = ["-x", "-o", "-l\(editor.window.windowNumber)", out.appendingPathComponent("video-editor.png").path]
                    try? task.run()
                    task.waitUntilExit()
                    try? FileManager.default.removeItem(at: file)
                    exit(0)
                }
                return
            }
            editor.setTrim(start: 1.5, end: 4.0)
            editor.seek(2.0)
            log("テスト: 動画 1.5〜4.0秒を残す 変更あり=\(editor.hasChanges) 見込み=\(Int(editor.estimatedBytes / 1024))KB")
            if let frame = editor.grabFrame(), let data = pngData(frame, dpi: 72) {
                try? data.write(to: out.appendingPathComponent("video-frame.png"))
                log("テスト: 動画 いまのコマ \(frame.width)x\(frame.height)")
            }
            editor.saveAs { saved in
                log("テスト: 動画 別の動画として保存 \(saved.map { describe($0) } ?? "失敗")")
                if let saved { try? FileManager.default.removeItem(at: saved) }
                editor.makeGIFFile { gif in
                    log("テスト: 動画 GIFにする \(gif.flatMap { pixelSize(of: $0) }.map { "\($0.0)x\($0.1)" } ?? "失敗") \(gif.map { ((try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int) ?? 0) / 1024 } ?? 0)KB")
                    if let gif { try? FileManager.default.removeItem(at: gif) }
                    editor.finish { ok in
                        log("テスト: 動画 完了=\(ok) \(describe(file)) 控えがある=\(FileManager.default.fileExists(atPath: VideoExporter.originalURL(for: file).path))")
                        guard let again = VideoEditorController.open(file: file) else { cleanup(); return }
                        again.revertTapped()
                        log("テスト: 動画 元に戻す \(describe(file)) 控えが消えた=\(!FileManager.default.fileExists(atPath: VideoExporter.originalURL(for: file).path))")
                        again.setMute(true)
                        again.setMaxHeight(480)
                        again.finish { ok2 in
                            log("テスト: 動画 音を消して480pに 完了=\(ok2) \(describe(file))")
                            cleanup()
                        }
                    }
                }
            }
        }
        // --test-video2 <動画> <フォルダ> : 分ける・消す・切り抜き・ズームを通して、書き出した動画のコマを画像にする
        if let i = args.firstIndex(of: "--test-video2"), i + 2 < args.count {
            let src = URL(fileURLWithPath: args[i + 1]), out = URL(fileURLWithPath: args[i + 2])
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            VideoEditorController.headless = true
            let file = Prefs.historyDir.appendingPathComponent("rec \(timestampName()) test2.mp4")
            try? FileManager.default.copyItem(at: src, to: file)
            func describe(_ url: URL) -> String {
                let info = videoInfo(url)
                return "\(String(format: "%.2f", info?.seconds ?? -1))秒 \(info?.width ?? 0)x\(info?.height ?? 0) 音=\(AVURLAsset(url: url).tracks(withMediaType: .audio).count)本 \(((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0) / 1024)KB"
            }
            func frame(_ url: URL, at t: Double, _ name: String) {
                let g = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                g.requestedTimeToleranceBefore = .zero
                g.requestedTimeToleranceAfter = .zero
                if let cg = try? g.copyCGImage(at: CMTime(seconds: t, preferredTimescale: 600), actualTime: nil), let data = pngData(cg, dpi: 72) {
                    try? data.write(to: out.appendingPathComponent(name))
                }
            }
            guard let editor = VideoEditorController.open(file: file) else { log("テスト: 動画エディタが開かない"); try? FileManager.default.removeItem(at: file); NSApp.terminate(nil); return }
            log("テスト: 動画2 開いた \(describe(file))")
            frame(file, at: 0.2, "v2-source-0.2.png")
            frame(file, at: 1.4, "v2-source-1.4.png")
            let s1 = editor.split(at: 2.0), s2 = editor.split(at: 4.0)
            let removed = editor.toggleRemoved(piece: 1)
            log("テスト: 動画2 分けた=\(s1),\(s2) 区切り=\(editor.edit.pieces().count) 真ん中を消した=\(removed) 残す長さ=\(String(format: "%.2f", editor.edit.keptLength))")
            editor.saveAs { cut in
                log("テスト: 動画2 分けて消しただけ \(cut.map { describe($0) } ?? "失敗")")
                if let cut { frame(cut, at: 2.2, "v2-cut-2.2.png"); try? FileManager.default.removeItem(at: cut) }
                frame(file, at: 4.2, "v2-source-4.2.png")
                editor.setCrop(CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5))   // 右上の4分の1
                editor.saveAs { cropped in
                    log("テスト: 動画2 右上を切り抜き \(cropped.map { describe($0) } ?? "失敗") 見込み=\(Int(editor.estimatedBytes / 1024))KB")
                    if let cropped { frame(cropped, at: 0.2, "v2-crop-0.2.png"); try? FileManager.default.removeItem(at: cropped) }
                    editor.setCrop(nil)
                    let added = editor.addZoom(at: 0.6, scale: 2)
                    log("テスト: 動画2 ズームを足した=\(added) 数=\(editor.edit.zooms.count) 範囲=\(editor.edit.zooms.first.map { "\($0.start)〜\($0.end)" } ?? "") 途中の倍率=\(editor.edit.zoomTransform(at: 0.6 + 0.175).s) 真ん中の倍率=\(editor.edit.zoomTransform(at: 1.4).s)")
                    editor.undo()
                    let afterUndo = editor.edit.zooms.count
                    _ = editor.addZoom(at: 0.6, scale: 2)
                    editor.saveAs { zoomed in
                        log("テスト: 動画2 取り消しでズーム=\(afterUndo) ズームつき \(zoomed.map { describe($0) } ?? "失敗")")
                        if let zoomed {
                            frame(zoomed, at: 0.2, "v2-zoom-0.2.png")
                            frame(zoomed, at: 1.4, "v2-zoom-1.4.png")
                            try? FileManager.default.removeItem(at: zoomed)
                        }
                        try? FileManager.default.removeItem(at: file)
                        NSApp.terminate(nil)
                    }
                }
            }
        }
        // --test-misc <画像> : 保存の形式と名前・同じ範囲をもう一度撮る・画像の取り込み・道具の設定を覚える・アイコンを隠す を通す
        if let i = args.firstIndex(of: "--test-misc"), i + 1 < args.count {
            EditorController.headless = true
            let src = URL(fileURLWithPath: args[i + 1])
            let d = UserDefaults.standard
            let keys = ["saveFormat", "jpegQuality", "saveAt1x", "shotPrefix", "lastAreaRect", "editorColor", "editorWeight", "hideDesktopIcons"]
            let saved = keys.map { d.object(forKey: $0) }
            func restore() { for (k, v) in zip(keys, saved) { if let v { d.set(v, forKey: k) } else { d.removeObject(forKey: k) } } }
            func kb(_ url: URL) -> Int { ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0) / 1024 }
            // ① 保存の形式と名前（画面の2倍の細かさの画像として用意する）
            let shot = Prefs.historyDir.appendingPathComponent("shot \(timestampName()) misc.png")
            if let loaded = loadImage(at: src), let data = pngData(loaded.image, dpi: 144) { try? data.write(to: shot) }
            let plain = saveToFolder(shot)
            Prefs.saveFormat = "jpg"; Prefs.jpegQuality = 70; Prefs.saveAt1x = true; Prefs.shotPrefix = "資料"
            let changed = saveToFolder(shot)
            log("テスト: 保存 そのまま=\(plain?.lastPathComponent ?? "失敗") \(plain.flatMap { pixelSize(of: $0) }.map { "\($0.0)x\($0.1)" } ?? "") \(plain.map(kb) ?? 0)KB")
            log("テスト: 保存 JPEG・等倍・名前を変えた=\(changed?.lastPathComponent ?? "失敗") \(changed.flatMap { pixelSize(of: $0) }.map { "\($0.0)x\($0.1)" } ?? "") \(changed.map(kb) ?? 0)KB")
            for f in [plain, changed].compactMap({ $0 }) { try? FileManager.default.removeItem(at: f) }
            try? FileManager.default.removeItem(at: shot)
            // ② 画像の取り込み（クリップボードやファイルから編集画面へ）
            if let loaded = loadImage(at: src) {
                let before = EditorController.openEditors.count
                CaptureController.shared.openInEditor(loaded.image, dpi: loaded.dpi)
                let opened = EditorController.openEditors.last
                log("テスト: 取り込み 編集画面 \(before)→\(EditorController.openEditors.count) 履歴に入った=\(opened.map { FileManager.default.fileExists(atPath: $0.fileURL.path) } ?? false)")
                // ③ 道具の設定を覚える
                if let opened {
                    opened.canvas.setColor(EditorController.palette[4])
                    opened.canvas.setWeight(0.6)
                    log("テスト: 道具を覚える 色=青になった=\(sameColor(ToolMemory.color, EditorController.palette[4])) 太さ=\(ToolMemory.weight)")
                    let file = opened.fileURL
                    opened.window.close()
                    try? FileManager.default.removeItem(at: file)
                }
            }
            // ④ アイコンを隠す（壁紙を取ってきて敷く → すぐ戻す）
            DesktopCover.set(true) { covered in
                log("テスト: アイコンを隠す 成功=\(covered) 敷いている=\(DesktopCover.isOn) 背景ツール用の壁紙=\(BackgroundPainter.wallpaper.map { "\($0.width)x\($0.height)" } ?? "なし")")
                DesktopCover.set(false)
                log("テスト: アイコンを戻す 敷いている=\(DesktopCover.isOn)")
            }
            BackgroundPainter.loadWallpaper(nil)
            // ⑤ 同じ範囲をもう一度撮る
            let before = Set((try? FileManager.default.contentsOfDirectory(atPath: Prefs.historyDir.path)) ?? [])
            Prefs.lastAreaRect = NSRect(x: 200, y: 300, width: 400, height: 300)
            CaptureController.shared.capturePrevious()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                let made = Set((try? FileManager.default.contentsOfDirectory(atPath: Prefs.historyDir.path)) ?? []).subtracting(before).filter { $0.hasSuffix(".png") }
                log("テスト: 同じ範囲をもう一度 増えた画像=\(made.count)枚 大きさ=\(made.first.flatMap { pixelSize(of: Prefs.historyDir.appendingPathComponent($0)) }.map { "\($0.0)x\($0.1)" } ?? "?")（800x600 なら正しい）")
                for name in made { try? FileManager.default.removeItem(at: Prefs.historyDir.appendingPathComponent(name)) }   // 画面が写っているので見ずに消す
                restore()
                NSApp.terminate(nil)
            }
        }
        // --test-allinone <出力フォルダ> : オールインワンの幕を出し、範囲を決めて帯を画像にし、録画用の帯への切り替え・撮る・範囲を覚えるを通す
        if let i = args.firstIndex(of: "--test-allinone"), i + 1 < args.count {
            let out = URL(fileURLWithPath: args[i + 1])
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            pasteboardForCopy = NSPasteboard(name: NSPasteboard.Name("local.kiritori.test"))
            let savedRect = Prefs.allInOneLastRect
            Prefs.allInOneLastRect = nil
            func shoot(_ view: NSView, _ name: String) {
                view.layoutSubtreeIfNeeded()
                guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent(name))
            }
            let before = Set((try? FileManager.default.contentsOfDirectory(atPath: Prefs.historyDir.path)) ?? [])
            CaptureController.shared.allInOne()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard let selector = CaptureController.shared.testAllInOneSelector, let view = selector.testViews.first else {
                    log("テスト: オールインワン 幕が出ていない"); NSApp.terminate(nil); return
                }
                log("テスト: オールインワン 幕=\(selector.testViews.count)枚 最初の範囲=\(view.selection.map { "\($0)" } ?? "なし")")
                shoot(view, "aio-0-empty.png")
                view.testDrag(from: NSPoint(x: 200, y: 300), to: NSPoint(x: 760, y: 660))
                shoot(view, "aio-1-selected.png")
                view.recordModeTapped()
                log("テスト: オールインワン 「録画」を押した 帯=\(selector.mode)")
                shoot(view, "aio-2-record.png")
                // 録画はせずに閉じて、開き直す（まだ何も実行していないので範囲は覚えていない）
                CaptureController.shared.allInOne()
                log("テスト: オールインワン もう一度呼ぶと閉じる=\(!CaptureController.shared.isAllInOneOpen)")
                CaptureController.shared.allInOne()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    guard let again = CaptureController.shared.testAllInOneSelector?.testViews.first else { NSApp.terminate(nil); return }
                    again.testDrag(from: NSPoint(x: 200, y: 300), to: NSPoint(x: 760, y: 660))
                    again.shotTapped()   // 撮る
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                        let after = Set((try? FileManager.default.contentsOfDirectory(atPath: Prefs.historyDir.path)) ?? [])
                        let made = after.subtracting(before).filter { $0.hasSuffix(".png") }
                        let size = made.first.flatMap { pixelSize(of: Prefs.historyDir.appendingPathComponent($0)) }
                        log("テスト: オールインワン 撮る 増えた画像=\(made.count)枚 大きさ=\(size.map { "\($0.0)x\($0.1)" } ?? "?") 小窓=\(PopupController.shared.count) 覚えた範囲=\(Prefs.allInOneLastRect.map { "\($0)" } ?? "なし")")
                        // 撮った画像には画面が写っているので、中身は見ずにすぐ消す
                        for name in made { try? FileManager.default.removeItem(at: Prefs.historyDir.appendingPathComponent(name)) }
                        CaptureController.shared.allInOne()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            let views = CaptureController.shared.testAllInOneSelector?.testViews ?? []
                            log("テスト: オールインワン 開き直し 最初から出ている範囲=\(views.compactMap { $0.selection }.map { "\($0)" })")
                            if let v = views.first(where: { $0.selection != nil }) { shoot(v, "aio-3-remembered.png") }
                            CaptureController.shared.allInOne()
                            Prefs.allInOneLastRect = savedRect
                            NSApp.terminate(nil)
                        }
                    }
                }
            }
        }
        if let i = args.firstIndex(of: "--capture"), i + 1 < args.count, let mode = CaptureMode(rawValue: args[i + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { CaptureController.shared.capture(mode) }
        }
    }

    func buildMenu() {
        // 確認用の起動（--test-…）ではメニューバーの印を作らない。
        // Claude Code などから直接起動すると、macOS 26 が印を「起動した側のアプリのもの」として覚えてしまい、
        // そちらがメニューバーへの表示を許可されていないと Kiritori の印まで隠されるため。
        let isTestRun = CommandLine.arguments.contains { $0.hasPrefix("--test-") }
        if !isTestRun {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            if let button = statusItem?.button {
                let img = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Kiritori")
                img?.isTemplate = true
                button.image = img
            }
        }
        let menu = NSMenu()
        menu.delegate = self

        func add(_ title: String, _ action: Selector, hotKey name: String? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            if let name { hotKeyItems[name] = item }
            menu.addItem(item)
        }
        add("オールインワン", #selector(allInOneTapped), hotKey: "allinone")
        menu.addItem(.separator())
        add("範囲を選んで撮る", #selector(captureArea), hotKey: "area")
        add("同じ範囲をもう一度撮る", #selector(capturePreviousTapped), hotKey: "previous")
        add("画面全体を撮る", #selector(captureFull), hotKey: "full")
        add("ウィンドウを撮る", #selector(captureWindow), hotKey: "window")
        add("スクロールして撮る", #selector(captureScroll))
        add("セルフタイマーで撮る", #selector(captureTimer))
        add("文字を読み取る", #selector(captureTextTapped), hotKey: "ocr")
        add("画面を録画する", #selector(toggleRecording), hotKey: "record")
        menu.addItem(.separator())
        add("履歴を見る", #selector(showHistory), hotKey: "history")
        add("直前に閉じたものを戻す", #selector(restoreLastTapped), hotKey: "restore")
        closePinsItem = NSMenuItem(title: "ピン留めをすべて閉じる", action: #selector(closeAllPins), keyEquivalent: "")
        unlockPinsItem = NSMenuItem(title: "ピン留めのロックを外す", action: #selector(unlockPins), keyEquivalent: "")
        for item in [closePinsItem!, unlockPinsItem!] {
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let openItem = NSMenuItem(title: "画像を開く", action: nil, keyEquivalent: "")
        let open = NSMenu(title: "画像を開く")
        for (title, action) in [("ファイルを編集画面で開く…", #selector(openFileTapped)),
                                ("クリップボードの画像を編集画面で開く", #selector(openClipboardTapped)),
                                ("画像を選んでピン留め…", #selector(pinFileTapped))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            open.addItem(item)
        }
        openItem.submenu = open
        menu.addItem(openItem)
        desktopIconsItem = NSMenuItem(title: "デスクトップのアイコンを隠す", action: #selector(toggleDesktopIcons), keyEquivalent: "")
        desktopIconsItem.target = self
        menu.addItem(desktopIconsItem)
        menu.addItem(.separator())
        add("保存先を開く", #selector(openSaveDir))
        let settings = NSMenuItem(title: "設定…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        add("Kiritori を終了", #selector(quit))

        statusMenu = menu
        statusItem?.menu = menu
        statusItem?.isVisible = Prefs.showMenuBarIcon
        refreshMenuShortcuts()
        refreshMenuState()
    }

    func menuWillOpen(_ menu: NSMenu) { refreshMenuState() }

    func refreshMenuState() {
        // ピン留めの項目は、留めてあるときだけ出す
        closePinsItem.isHidden = PinController.shared.pins.isEmpty
        unlockPinsItem.isHidden = !PinController.shared.hasLocked
        desktopIconsItem.state = DesktopCover.isOn ? .on : .off
    }

    @objc func capturePreviousTapped() { CaptureController.shared.capturePrevious() }
    @objc func restoreLastTapped() { PopupController.shared.restoreLast() }
    @objc func openClipboardTapped() { CaptureController.shared.openFromClipboard() }

    private func chooseImage(_ message: String) -> URL? {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = message
        return panel.runModal() == .OK ? panel.url : nil
    }

    @objc func openFileTapped() {
        guard let url = chooseImage("編集する画像を選んでください（元のファイルは変わりません）"), let loaded = loadImage(at: url) else { return }
        CaptureController.shared.openInEditor(loaded.image, dpi: loaded.dpi)
    }

    @objc func pinFileTapped() {
        guard let url = chooseImage("画面に留める画像を選んでください") else { return }
        _ = PinController.shared.pin(file: url)
    }

    @objc func toggleDesktopIcons() {
        DesktopCover.set(!DesktopCover.isOn) { ok in
            if !ok { ToastHUD.show("アイコンを隠せませんでした", detail: "壁紙を取ってこられませんでした") }
        }
    }

    /// メニューの右に出すショートカットを、いまの設定に合わせる
    func refreshMenuShortcuts() {
        for spec in HotKeys.specs {
            guard let item = hotKeyItems[spec.name] else { continue }
            let hk = Prefs.hotKey(spec.name, defaultKey: spec.defaultKey)
            item.keyEquivalent = hk.key == hotKeyDisabled ? "" : keyCharacter(forKeyCode: hk.key)
            item.keyEquivalentModifierMask = modifierFlags(fromCarbon: hk.mods)
        }
    }

    @objc func allInOneTapped() { CaptureController.shared.allInOne() }
    @objc func openSettings() { SettingsController.shared.show() }

    @objc func captureArea() { CaptureController.shared.capture(.area) }
    @objc func captureFull() { CaptureController.shared.capture(.full) }
    @objc func captureWindow() { CaptureController.shared.capture(.window) }
    @objc func captureScroll() { CaptureController.shared.captureScrolling() }
    @objc func captureTimer() { CaptureController.shared.captureWithTimer() }
    @objc func captureTextTapped() { CaptureController.shared.captureText() }
    @objc func closeAllPins() { PinController.shared.closeAll() }
    @objc func unlockPins() { PinController.shared.unlockAll() }
    @objc func toggleOwnAreaCapture() { Prefs.ownAreaCapture.toggle() }
    @objc func toggleMagnifier() { Prefs.showMagnifier.toggle() }
    @objc func toggleCrosshair() { Prefs.showCrosshair.toggle() }
    @objc func toggleWindowShadow() { Prefs.windowShadow.toggle() }
    @objc func chooseTimerSeconds(_ sender: NSMenuItem) { Prefs.timerSeconds = sender.tag }

    @objc func toggleAutoCopy() { Prefs.autoCopy.toggle() }
    @objc func toggleAutoSave() { Prefs.autoSave.toggle() }
    @objc func toggleSound() { Prefs.playSound.toggle() }
    @objc func toggleSystemAudio() { Prefs.recordSystemAudio.toggle() }
    @objc func toggleHighlightClicks() { Prefs.highlightClicks.toggle() }
    @objc func toggleShowCursor() { Prefs.showCursor.toggle() }
    @objc func toggleKeystrokesAll() { Prefs.keystrokesAll.toggle() }
    @objc func toggleShowKeystrokes() {
        if !Prefs.showKeystrokes, !KeystrokeOverlay.hasPermission {
            CGRequestListenEventAccess()   // macOS に「入力監視」の許可を求める
            log("キー表示: 入力監視の許可がない")
            return
        }
        Prefs.showKeystrokes.toggle()
    }
    @objc func toggleShowCamera() {
        if Prefs.showCamera { Prefs.showCamera = false; return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: Prefs.showCamera = true
        case .notDetermined: AVCaptureDevice.requestAccess(for: .video) { ok in DispatchQueue.main.async { if ok { Prefs.showCamera = true } } }
        default: NSSound.beep(); log("カメラの許可がない")
        }
    }
    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            log("ログイン項目の切り替え失敗: \(error)")
            NSSound.beep()
        }
    }

    @objc func chooseSaveDir() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = Prefs.saveDir
        panel.prompt = "ここに保存する"
        if panel.runModal() == .OK, let url = panel.url {
            Prefs.saveDir = url
            log("保存先変更 \(url.path)")
        }
    }

    @objc func openSaveDir() { NSWorkspace.shared.open(Prefs.saveDir) }
    @objc func showHistory() { HistoryController.shared.show() }
    @objc func toggleRecording() { RecordController.shared.toggle() }

    @objc func togglePauseTapped() { RecordController.shared.togglePause() }

    /// 録画中だけ出す、一時停止・再開のボタン
    private var pauseItem: NSStatusItem?

    /// 録画中はメニューバーの印を「■ 0:12」に変え、押すと止まるようにする。elapsed が nil なら元に戻す。
    /// 一時停止ができる録り方のときは、その左に一時停止・再開のボタンも出す。
    func setRecording(elapsed: TimeInterval?, micLevel: CGFloat? = nil, paused: Bool = false, canPause: Bool = false) {
        if elapsed != nil, canPause, statusItem != nil {   // 確認用の起動（印を作らない）では出さない
            if pauseItem == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
                item.button?.target = self
                item.button?.action = #selector(togglePauseTapped)
                pauseItem = item
            }
            pauseItem?.button?.image = tintedSymbol(paused ? "play.circle.fill" : "pause.circle.fill", pointSize: 15,
                                                    color: paused ? .systemGreen : .labelColor)
            pauseItem?.button?.toolTip = paused ? "押すと録画を再開します" : "押すと録画を一時停止します"
        } else if let item = pauseItem {
            NSStatusBar.system.removeStatusItem(item)
            pauseItem = nil
        }
        guard let item = statusItem, let button = item.button else { return }
        if let elapsed {
            item.isVisible = true   // 印を隠す設定でも、録画中は止めるために出す
            item.menu = nil
            button.target = self
            button.action = #selector(toggleRecording)
            item.length = NSStatusItem.variableLength
            button.image = recordingIndicatorImage(micLevel: micLevel, paused: paused)   // マイクが入っていれば、音量の小さな棒が付く
            button.imagePosition = .imageLeading
            button.attributedTitle = NSAttributedString(string: " " + clockText(elapsed) + (paused ? " 停止中" : ""), attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium),
            ])
            button.toolTip = "押すと録画を止めます"
        } else {
            let img = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Kiritori")
            img?.isTemplate = true
            button.image = img
            button.title = ""
            button.imagePosition = .imageOnly
            button.toolTip = nil
            button.action = nil
            item.length = NSStatusItem.squareLength
            item.menu = statusMenu
            item.isVisible = Prefs.showMenuBarIcon
        }
    }

    /// メニューバーの印を出す・隠す。隠しているときは、Kiritori をもう一度開くと設定画面が出る。
    func applyMenuBarIcon() {
        guard !RecordController.shared.isRecording else { return }
        statusItem?.isVisible = Prefs.showMenuBarIcon
    }

    /// 印を隠しているときは、Kiritori をもう一度開くと設定画面を出す（印が無いと設定へ行けなくなるため）
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !Prefs.showMenuBarIcon { SettingsController.shared.show() }
        return false
    }

    @objc func quit() { NSApp.terminate(nil) }
}

// MARK: - 起動

if let bundleID = Bundle.main.bundleIdentifier,
   NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).count > 1 {
    log("すでに起動しているので終了")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(CommandLine.arguments.contains("--dock") ? .regular : .accessory)   // --dock は確認用（Dock に出して外から操作できるようにする）
app.run()
