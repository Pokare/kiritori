// ショートカットの重なりを見つけて知らせる。
// ① macOS 標準のスクリーンショットと同じキー：設定を読めば分かるので、起動時と設定画面で知らせる。
// ② ほかのアプリと同じキー：相手の設定は読めない。範囲選びの幕が出ているのにクリックがよそへ行ったら「重なっていそう」と知らせる。

import AppKit
import Carbon.HIToolbox

enum ShortcutConflicts {
    private static let shift: UInt = 1 << 17, control: UInt = 1 << 18, option: UInt = 1 << 19, command: UInt = 1 << 20

    /// macOS 標準のスクリーンショット。設定に書かれていないときは、この初期値が生きている。
    private static let standard: [(id: String, key: Int, mods: UInt, title: String)] = [
        ("28", kVK_ANSI_3, command | shift, "画面全体を撮る"),
        ("29", kVK_ANSI_3, control | command | shift, "画面全体をクリップボードへ"),
        ("30", kVK_ANSI_4, command | shift, "範囲を撮る"),
        ("31", kVK_ANSI_4, control | command | shift, "範囲をクリップボードへ"),
        ("184", kVK_ANSI_5, command | shift, "スクリーンショットの操作パネル"),
    ]

    private static func carbon(_ flags: UInt) -> UInt32 {
        var mods: UInt32 = 0
        if flags & command != 0 { mods |= UInt32(cmdKey) }
        if flags & shift != 0 { mods |= UInt32(shiftKey) }
        if flags & option != 0 { mods |= UInt32(optionKey) }
        if flags & control != 0 { mods |= UInt32(controlKey) }
        return mods
    }

    /// 確認用：ここに入れた値を「生きている標準のキー」として扱う
    static var testOverride: [(key: UInt32, mods: UInt32, title: String)]?

    /// いま生きている macOS 標準のスクリーンショットのキー
    static func systemShortcuts() -> [(key: UInt32, mods: UInt32, title: String)] {
        if let testOverride { return testOverride }
        let all = UserDefaults(suiteName: "com.apple.symbolichotkeys")?.dictionary(forKey: "AppleSymbolicHotKeys") ?? [:]
        var result: [(key: UInt32, mods: UInt32, title: String)] = []
        for item in standard {
            var key = item.key, mods = item.mods, enabled = true
            if let entry = all[item.id] as? [String: Any] {
                if let on = entry["enabled"] as? Bool { enabled = on } else if let on = entry["enabled"] as? Int { enabled = on != 0 }
                if let params = (entry["value"] as? [String: Any])?["parameters"] as? [Any], params.count >= 3,
                   let k = (params[1] as? NSNumber)?.intValue, let m = (params[2] as? NSNumber)?.uintValue {
                    key = k; mods = m
                }
            }
            if enabled { result.append((UInt32(key), carbon(mods), item.title)) }
        }
        return result
    }

    /// Kiritori のショートカットのうち、macOS 標準と同じキーになっているもの
    static func withSystem() -> [(name: String, title: String, keys: String, system: String)] {
        let system = systemShortcuts()
        var hits: [(name: String, title: String, keys: String, system: String)] = []
        for spec in HotKeys.specs {
            let hk = Prefs.hotKey(spec.name, defaultKey: spec.defaultKey)
            guard hk.key != hotKeyDisabled, let same = system.first(where: { $0.key == hk.key && $0.mods == hk.mods }) else { continue }
            hits.append((spec.name, spec.title, shortcutText(key: hk.key, mods: hk.mods), same.title))
        }
        return hits
    }

    /// 設定画面に出す一文（重なりが無ければ nil）
    static func settingsNote() -> String? {
        let hits = withSystem()
        guard !hits.isEmpty else { return nil }
        return "⚠︎ " + hits.map { "「\($0.title)」(\($0.keys))" }.joined(separator: "・") + " は macOS 標準のスクリーンショットと同じキーです。両方が動きます"
    }

    private static func ignored(_ key: String) -> Bool { (UserDefaults.standard.stringArray(forKey: "conflictIgnored") ?? []).contains(key) }
    private static func ignore(_ key: String) {
        var list = UserDefaults.standard.stringArray(forKey: "conflictIgnored") ?? []
        if !list.contains(key) { list.append(key) }
        UserDefaults.standard.set(list, forKey: "conflictIgnored")
    }

    /// 確認用の起動では窓を出さない
    static var quiet = false

    /// 起動したときに、macOS 標準との重なりを知らせる
    static func checkAtLaunch() {
        let hits = withSystem()
        guard !hits.isEmpty else { return }
        let mark = "system:" + hits.map { "\($0.name)=\($0.keys)" }.joined(separator: ",")
        log("ショートカットが macOS 標準と重なっている: " + hits.map { "\($0.title) \($0.keys)＝標準の「\($0.system)」" }.joined(separator: " / "))
        guard !quiet, !ignored(mark) else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "ショートカットが macOS 標準のスクリーンショットと重なっています"
        alert.informativeText = hits.map { "・\($0.title)（\($0.keys)）" }.joined(separator: "\n")
            + "\n\nこのままだと、押したときに macOS 標準と Kiritori の両方が動きます。どちらかを変えてください。\n\n標準のほうを切るには、システム設定 →「キーボード」→「キーボードショートカット…」→「スクリーンショット」でチェックを外します。"
        alert.addButton(withTitle: "システム設定を開く")
        alert.addButton(withTitle: "Kiritori のキーを変える")
        alert.addButton(withTitle: "あとで")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "この重なりは今後知らせない"
        let answer = alert.runModal()
        if alert.suppressionButton?.state == .on { ignore(mark) }
        if answer == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
        } else if answer == .alertSecondButtonReturn {
            SettingsController.shared.showShortcuts()
        }
    }

    private static var toldOtherApp = false

    /// 範囲選びの幕が出ているのに、クリックがほかのアプリへ行った。同じキーにほかのアプリも反応していそう。
    static func suspectOtherApp(_ name: String) {
        guard let spec = HotKeys.specs.first(where: { $0.name == name }) else { return }
        let hk = Prefs.hotKey(spec.name, defaultKey: spec.defaultKey)
        let keys = shortcutText(key: hk.key, mods: hk.mods)
        let mark = "other:\(name)=\(keys)"
        log("ほかのアプリと重なっていそう: \(spec.title) \(keys)（幕が出ている間に、クリックがほかのアプリへ行った）")
        // 1回の起動で1度だけ知らせる
        guard !quiet, !toldOtherApp, !ignored(mark) else { return }
        toldOtherApp = true
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "同じキーに、ほかのアプリも反応しているようです"
        alert.informativeText = "「\(spec.title)」（\(keys)）を押したとき、Kiritori より先にほかのアプリが画面のクリックを受け取っていました。範囲を2回選ぶことになるのはこのためです。\n\nKiritori か、そのアプリのどちらかのキーを変えると、1回で撮れるようになります。マウスのボタンにキーを割り当てている場合は、そちらも同じキーに変えてください。"
        alert.addButton(withTitle: "Kiritori のキーを変える")
        alert.addButton(withTitle: "閉じる")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "このキーについては今後知らせない"
        let answer = alert.runModal()
        if alert.suppressionButton?.state == .on { ignore(mark) }
        if answer == .alertFirstButtonReturn { SettingsController.shared.showShortcuts() }
    }
}
