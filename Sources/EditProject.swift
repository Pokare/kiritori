// 編集のやり直し用の控え。
// 「完了」「保存」のとき、編集前の画像と注釈の一覧を履歴フォルダの edits/ に残しておき、
// 同じ画像をもう一度編集画面で開いたら、描いたものを動かせる状態で戻す。

import AppKit
import ImageIO

/// 手描きの線（ペン・蛍光ペン）をなめらかにつなぐ。
func smoothPath(_ pts: [CGPoint]) -> CGPath {
    let path = CGMutablePath()
    guard let first = pts.first else { return path }
    path.move(to: first)
    guard pts.count >= 3 else {
        pts.dropFirst().forEach { path.addLine(to: $0) }
        if pts.count == 1 { path.addLine(to: first) }
        return path
    }
    for i in 1..<(pts.count - 1) {
        let mid = CGPoint(x: (pts[i].x + pts[i + 1].x) / 2, y: (pts[i].y + pts[i + 1].y) / 2)
        path.addQuadCurve(to: mid, control: pts[i])
    }
    path.addLine(to: pts[pts.count - 1])
    return path
}

extension Annotation {
    func toDictionary() -> [String: Any] {
        let c = color.usingColorSpace(.sRGB) ?? NSColor.red
        var d: [String: Any] = [
            "tool": String(describing: tool),
            "p0": [p0.x, p0.y], "p1": [p1.x, p1.y],
            "color": [c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent],
            "weight": weight, "scale": scale,
            "arrowStyle": arrowStyle.rawValue, "blurStyle": blurStyle.rawValue, "textStyle": textStyle.rawValue,
            "text": text, "number": number,
        ]
        if turns != 0 { d["turns"] = turns }
        if let ctrl { d["ctrl"] = [ctrl.x, ctrl.y] }
        if !points.isEmpty { d["points"] = points.flatMap { [$0.x, $0.y] } }
        return d
    }

    init?(dictionary d: [String: Any]) {
        func point(_ key: String) -> CGPoint? {
            guard let a = d[key] as? [Double], a.count == 2 else { return nil }
            return CGPoint(x: a[0], y: a[1])
        }
        guard let name = d["tool"] as? String, let tool = Tool.allCases.first(where: { String(describing: $0) == name }),
              let p0 = point("p0"), let p1 = point("p1"),
              let rgba = d["color"] as? [Double], rgba.count == 4,
              let weight = d["weight"] as? Double, let scale = d["scale"] as? Double else { return nil }
        self.init(tool: tool, p0: p0, p1: p1,
                  color: NSColor(srgbRed: rgba[0], green: rgba[1], blue: rgba[2], alpha: rgba[3]),
                  weight: CGFloat(weight), scale: CGFloat(scale))
        ctrl = point("ctrl")
        arrowStyle = ArrowStyle(rawValue: d["arrowStyle"] as? Int ?? 0) ?? .filled
        blurStyle = BlurStyle(rawValue: d["blurStyle"] as? Int ?? 0) ?? .mosaic
        textStyle = TextStyle(rawValue: d["textStyle"] as? Int ?? 0) ?? .outline
        text = d["text"] as? String ?? ""
        number = d["number"] as? Int ?? 0
        turns = d["turns"] as? Int ?? 0
        if let flat = d["points"] as? [Double] {
            points = stride(from: 0, to: flat.count - 1, by: 2).map { CGPoint(x: flat[$0], y: flat[$0 + 1]) }
        }
    }
}

enum EditProject {
    static var dir: URL {
        let d = Prefs.historyDir.appendingPathComponent("edits")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    static func baseURL(for file: URL) -> URL { dir.appendingPathComponent(file.deletingPathExtension().lastPathComponent + ".base.png") }
    static func jsonURL(for file: URL) -> URL { dir.appendingPathComponent(file.deletingPathExtension().lastPathComponent + ".json") }
    /// 足した画像の控え（1枚ごとに1ファイル）
    static func imageURL(for file: URL, index: Int) -> URL {
        dir.appendingPathComponent(file.deletingPathExtension().lastPathComponent + ".img\(index).png")
    }
    private static func imageFiles(for file: URL) -> [URL] {
        let prefix = file.deletingPathExtension().lastPathComponent + ".img"
        return ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "png" }
    }

    private static func fileSize(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? -1
    }

    /// 上書きする前に、編集前の画像を一度だけ控える。
    static func keepBase(of file: URL) {
        let base = baseURL(for: file)
        guard !FileManager.default.fileExists(atPath: base.path) else { return }
        try? FileManager.default.copyItem(at: file, to: base)
    }

    /// file へ書き戻したあとに呼ぶ。注釈の一覧と台紙の広さ、書き戻した画像の大きさ（別の所で変えられていないかの目印）を残す。
    static func save(for file: URL, annotations: [Annotation], renderer: Renderer, dpi: CGFloat) {
        for old in imageFiles(for: file) { try? FileManager.default.removeItem(at: old) }
        var list: [[String: Any]] = []
        var imageCount = 0
        for a in annotations {
            var d = a.toDictionary()
            if a.tool == .image {
                // 画像の中身は別のファイルに書き、名前だけ一覧に残す
                guard let image = a.image, let data = pngData(image, dpi: dpi) else { continue }
                let url = imageURL(for: file, index: imageCount)
                guard (try? data.write(to: url, options: .atomic)) != nil else { continue }
                d["imageFile"] = url.lastPathComponent
                imageCount += 1
            }
            list.append(d)
        }
        var payload: [String: Any] = [
            "version": 2,
            "renderedBytes": fileSize(file),
            "baseOrigin": [renderer.baseOrigin.x, renderer.baseOrigin.y],
            "canvas": [renderer.width, renderer.height],
            "annotations": list,
        ]
        if renderer.background.enabled { payload["background"] = renderer.background.toDictionary() }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? data.write(to: jsonURL(for: file), options: .atomic)
    }

    /// 控えがあって、画像が控えたときのままなら、編集前の画像と注釈を返す。
    static func load(for file: URL) -> (base: CGImage, dpi: CGFloat, annotations: [Annotation], baseOrigin: CGPoint, size: CGSize, background: BackdropStyle?)? {
        guard let data = try? Data(contentsOf: jsonURL(for: file)),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (payload["renderedBytes"] as? Int) == fileSize(file),
              let list = payload["annotations"] as? [[String: Any]],
              let base = loadImage(at: baseURL(for: file)) else { return nil }
        let annotations: [Annotation] = list.compactMap { d in
            guard var a = Annotation(dictionary: d) else { return nil }
            if a.tool == .image {
                guard let name = d["imageFile"] as? String, let loaded = loadImage(at: dir.appendingPathComponent(name)) else { return nil }
                a.image = loaded.image
            }
            return a
        }
        var origin = CGPoint.zero
        var size = CGSize(width: base.image.width, height: base.image.height)
        if let o = payload["baseOrigin"] as? [Double], o.count == 2, let c = payload["canvas"] as? [Double], c.count == 2 {
            origin = CGPoint(x: o[0], y: o[1])
            size = CGSize(width: c[0], height: c[1])
        }
        let background = (payload["background"] as? [String: Any]).map { BackdropStyle(dictionary: $0) }
        return (base.image, base.dpi, annotations, origin, size, background)
    }

    static func discard(for file: URL) {
        try? FileManager.default.removeItem(at: baseURL(for: file))
        try? FileManager.default.removeItem(at: jsonURL(for: file))
        for old in imageFiles(for: file) { try? FileManager.default.removeItem(at: old) }
    }

    /// もう無い画像の控えを片付ける。
    static func cleanOrphans() {
        let fm = FileManager.default
        let names = Set(((try? fm.contentsOfDirectory(atPath: Prefs.historyDir.path)) ?? [])
            .map { ($0 as NSString).deletingPathExtension })
        for item in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
            var stem = item.deletingPathExtension().lastPathComponent      // "shot ….base" か "shot …"
            if stem.hasSuffix(".base") { stem = String(stem.dropLast(5)) }
            if stem.hasSuffix(".orig") { stem = String(stem.dropLast(5)) }   // 動画の「元に戻す」用の控え
            if let r = stem.range(of: #"\.img\d+$"#, options: .regularExpression) { stem.removeSubrange(r) }
            if !names.contains(stem) { try? fm.removeItem(at: item) }
        }
    }
}
