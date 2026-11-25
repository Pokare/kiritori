// 新しい版の確認と入れ替え。
// GitHub の Releases（Pokare/kiritori）のいちばん新しい版を見に行き、いまより新しければメニューと通知で知らせる。
// 「更新する」を押すと zip を取ってきて、いまのアプリと入れ替えて開き直す。
// 送るのは「いちばん新しい版を教えて」という問い合わせだけ（撮ったものや設定は送らない）。

import AppKit

final class Updater: NSObject {
    static let shared = Updater()
    static let repo = "Pokare/kiritori"
    static var pageURL: URL { URL(string: "https://github.com/\(repo)/releases/latest")! }

    /// メニューに足す項目。新しい版があるときだけ「v◯ に更新する」が出る。
    let updateItem = NSMenuItem(title: "", action: #selector(installTapped), keyEquivalent: "")
    let checkItem = NSMenuItem(title: "更新を確認する", action: #selector(checkTapped), keyEquivalent: "")

    private(set) var latest: (version: String, zip: URL)?
    private var checking = false
    private var installing = false
    private var timer: Timer?

    var current: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    override init() {
        super.init()
        updateItem.target = self
        updateItem.isHidden = true
        checkItem.target = self
    }

    /// "0.18.10" と "0.18.9" のように、数字の並びとして比べる。
    static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] { s.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 } }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    /// 起動して少ししたら1回、そのあとは6時間ごとに見に行く。
    func start() {
        timer?.invalidate()
        timer = nil
        guard Prefs.autoUpdateCheck else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.check(manual: false) }
        let t = Timer(timeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in self?.check(manual: false) }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    @objc private func checkTapped() { check(manual: true) }
    @objc private func installTapped() { install() }

    /// いちばん新しい版を調べる。completion は確認用（main で返す）。
    func check(manual: Bool, completion: ((String?) -> Void)? = nil) {
        guard !checking, !installing else { return }
        checking = true
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Kiritori", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            var found: (version: String, zip: URL)?
            var failure: String?
            if let data, (response as? HTTPURLResponse)?.statusCode == 200,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tag = json["tag_name"] as? String {
                let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                let assets = json["assets"] as? [[String: Any]] ?? []
                let zip = assets.compactMap { asset -> URL? in
                    guard let name = asset["name"] as? String, name.hasSuffix(".zip"),
                          let text = asset["browser_download_url"] as? String, let url = URL(string: text),
                          // 取りに行く先は、このアプリの置き場所だけに限る
                          url.scheme == "https", url.host == "github.com", url.path.hasPrefix("/\(Self.repo)/releases/download/") else { return nil }
                    return url
                }.first
                if let zip { found = (version, zip) } else { failure = "版 \(version) に zip が載っていない" }
            } else {
                failure = error?.localizedDescription ?? "返事が読めない（\((response as? HTTPURLResponse)?.statusCode ?? 0)）"
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.checking = false
                if let failure {
                    log("更新の確認に失敗: \(failure)")
                    if manual { self.say("更新を確認できませんでした", "インターネットにつながっているかを見て、もう一度試してください。") }
                    completion?(nil)
                    return
                }
                guard let found else { completion?(nil); return }
                let newer = Self.isNewer(found.version, than: self.current)
                log("更新の確認: いま v\(self.current)／いちばん新しい版 v\(found.version)\(newer ? "（新しい版あり）" : "")")
                if newer {
                    self.latest = found
                    self.updateItem.title = "v\(found.version) に更新する"
                    self.updateItem.isHidden = false
                    (NSApp.delegate as? AppDelegate)?.applyUpdateBadge()
                    // 自動の確認では、同じ版を何度も知らせない。録画中は邪魔になるので次の確認まで待つ
                    if manual || (Prefs.updateNotified != found.version && !RecordController.shared.isRecording && completion == nil) {
                        Prefs.updateNotified = found.version
                        self.offer(found.version)
                    }
                } else {
                    self.latest = nil
                    self.updateItem.isHidden = true
                    (NSApp.delegate as? AppDelegate)?.applyUpdateBadge()
                    if manual { self.say("いまの版がいちばん新しい版です", "Kiritori \(self.current)") }
                }
                completion?(found.version)
            }
        }.resume()
    }

    private func say(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func offer(_ version: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Kiritori の新しい版があります"
        alert.informativeText = "いまの版は \(current)、新しい版は \(version) です。更新すると Kiritori が一度閉じて、新しい版で開き直します。あとで更新するときは、メニューの「v\(version) に更新する」を選びます。"
        alert.addButton(withTitle: "更新する")
        alert.addButton(withTitle: "あとで")
        if alert.runModal() == .alertFirstButtonReturn { install() }
    }

    // MARK: 入れ替え

    private func fail(_ reason: String) {
        installing = false
        if let latest { updateItem.title = "v\(latest.version) に更新する" }
        updateItem.isEnabled = true
        log("更新に失敗: \(reason)")
        guard !Self.quiet else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "更新できませんでした"
        alert.informativeText = "\(reason)\n配布ページから zip を取って、手で入れ替えることもできます。"
        alert.addButton(withTitle: "配布ページを開く")
        alert.addButton(withTitle: "閉じる")
        if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(Self.pageURL) }
    }

    /// 確認用の起動では、失敗しても窓を出さない
    static var quiet = false

    func install() {
        guard let latest, !installing else { return }
        guard !RecordController.shared.isRecording else {
            say("録画中は更新できません", "録画を止めてから、もう一度メニューの「v\(latest.version) に更新する」を選んでください。")
            return
        }
        let dest = Bundle.main.bundleURL
        guard dest.pathExtension == "app", FileManager.default.isWritableFile(atPath: dest.deletingLastPathComponent().path) else {
            fail("Kiritori の置き場所（\(dest.deletingLastPathComponent().path)）に書き込めません。")
            return
        }
        installing = true
        updateItem.title = "更新しています…"
        updateItem.isEnabled = false
        log("更新を始める v\(current) → v\(latest.version) \(latest.zip.absoluteString)")
        var request = URLRequest(url: latest.zip)
        request.setValue("Kiritori", forHTTPHeaderField: "User-Agent")
        URLSession.shared.downloadTask(with: request) { [weak self] file, response, error in
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("kiritori-update-\(UUID().uuidString)")
            var problem: String?
            var fresh: URL?
            if let file, (response as? HTTPURLResponse)?.statusCode == 200 {
                do {
                    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                    let zip = work.appendingPathComponent("update.zip")
                    try FileManager.default.moveItem(at: file, to: zip)
                    let unpacked = work.appendingPathComponent("unpacked")
                    guard Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path]) == 0 else { throw NSError(domain: "zip を開けませんでした。", code: 0) }
                    let app = unpacked.appendingPathComponent("Kiritori.app")
                    // 取ってきたものが、同じアプリの、知らされた版で、壊れていないことを確かめる
                    guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
                          info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else { throw NSError(domain: "取ってきたものが Kiritori ではありませんでした。", code: 0) }
                    guard info["CFBundleShortVersionString"] as? String == latest.version else { throw NSError(domain: "取ってきたものの版が違いました。", code: 0) }
                    guard Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]) == 0 else { throw NSError(domain: "取ってきたものが壊れていました。", code: 0) }
                    fresh = app
                } catch {
                    problem = (error as NSError).domain.hasSuffix("。") ? (error as NSError).domain : error.localizedDescription
                }
            } else {
                problem = "zip を取ってこられませんでした（\(error?.localizedDescription ?? "返事 \((response as? HTTPURLResponse)?.statusCode ?? 0)")）。"
            }
            DispatchQueue.main.async {
                guard let self else { return }
                guard let fresh else {
                    try? FileManager.default.removeItem(at: work)
                    self.fail(problem ?? "理由が分かりませんでした。")
                    return
                }
                self.swap(dest: dest, fresh: fresh, work: work)
            }
        }.resume()
    }

    /// いまのアプリが閉じるのを待って入れ替え、開き直す（入れ替えは別の小さな手順に任せる。自分自身は書き換えられないため）。
    /// 入れ替えに失敗したら、前のアプリを元の場所へ戻す。
    private func swap(dest: URL, fresh: URL, work: URL) {
        let script = """
        pid="$1"; dest="$2"; fresh="$3"; work="$4"
        i=0
        while kill -0 "$pid" 2>/dev/null && [ $i -lt 100 ]; do sleep 0.1; i=$((i+1)); done
        if mv "$dest" "$work/old.app"; then
          if mv "$fresh" "$dest"; then /bin/rm -rf "$work"; else mv "$work/old.app" "$dest"; fi
        fi
        /usr/bin/open "$dest"
        """
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", script, "sh", String(ProcessInfo.processInfo.processIdentifier), dest.path, fresh.path, work.path]
        do { try task.run() } catch {
            try? FileManager.default.removeItem(at: work)
            fail("入れ替えを始められませんでした。")
            return
        }
        log("入れ替えのため終了する")
        NSApp.terminate(nil)
    }

    private static func run(_ path: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}
