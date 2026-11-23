// 動画エディタ: 録画の前後を切り落とす・音を消す・音量を変える・大きさを縮める・GIF にする・いまのコマを画像にする。
// 小窓か履歴で録画の「編集」を押すと開く。

import AppKit
import AVFoundation
import AVKit
import Carbon.HIToolbox

// MARK: - 編集の中身

/// ある時間だけ、映像の一部を大きく見せる。cx・cy は大きく見せたい場所の中心（0〜1・左上が原点）。
struct VideoZoom: Equatable {
    var start: Double
    var end: Double
    var cx: Double = 0.5
    var cy: Double = 0.5
    var scale: Double = 2

    /// 大きく映る範囲（0〜1・左上が原点）
    var box: CGRect {
        let w = 1 / scale
        let x = max(0, min(1 - w, cx - w / 2)), y = max(0, min(1 - w, cy - w / 2))
        return CGRect(x: x, y: y, width: w, height: w)
    }
}

struct VideoEdit: Equatable {
    var start: Double = 0
    var end: Double = 0
    var mute = false
    /// 音量。1 がそのまま
    var volume: Double = 1
    /// 高さの上限（ピクセル）。0 は元のまま
    var maxHeight = 0
    /// 分けた位置（秒）
    var splits: [Double] = []
    /// 消した部分。分けた区切りのうち、真ん中がここに入るものを消す
    var removed: [ClosedRange<Double>] = []
    /// 切り抜く範囲（0〜1・左上が原点）。nil は切り抜かない
    var crop: CGRect? = nil
    var zooms: [VideoZoom] = []

    static let heights: [(String, Int)] = [("元のまま", 0), ("1080p", 1080), ("720p", 720), ("480p", 480)]
    static let zoomScales: [(String, Double)] = [("1.5倍", 1.5), ("2倍", 2), ("3倍", 3), ("4倍", 4)]
    /// ズームが寄る・戻るのにかける秒数
    static let ramp = 0.35

    struct Piece: Equatable {
        var start: Double
        var end: Double
        var removed: Bool
    }

    /// 残す範囲を、分けた位置で区切ったもの
    func pieces() -> [Piece] {
        let inner = splits.filter { $0 > start + 0.05 && $0 < end - 0.05 }.sorted()
        let cuts = [start] + inner + [end]
        return zip(cuts, cuts.dropFirst()).map { a, b in
            Piece(start: a, end: b, removed: removed.contains { $0.contains((a + b) / 2) })
        }
    }

    /// 書き出す範囲（消した部分を除いて、隣り合うものはつなぐ）
    func kept() -> [(start: Double, end: Double)] {
        var out: [(start: Double, end: Double)] = []
        for p in pieces() where !p.removed {
            if let last = out.last, abs(last.end - p.start) < 0.0005 { out[out.count - 1].end = p.end } else { out.append((p.start, p.end)) }
        }
        return out
    }

    var keptLength: Double { kept().reduce(0) { $0 + ($1.end - $1.start) } }

    /// 時刻 t の映し方。元の映像の点 p（0〜1・左上が原点）が s·p + o に映る。ズームの外では s=1・o=0。
    func zoomTransform(at t: Double) -> (s: Double, ox: Double, oy: Double) {
        guard let z = zooms.first(where: { t >= $0.start && t <= $0.end }) else { return (1, 0, 0) }
        let ramp = min(Self.ramp, (z.end - z.start) / 2)
        let f = ramp <= 0 ? 1 : max(0, min(1, min(t - z.start, z.end - t) / ramp))
        let box = z.box
        return (1 + (z.scale - 1) * f, -box.minX * z.scale * f, -box.minY * z.scale * f)
    }
}

enum VideoExporter {
    /// 編集を反映した動画を out へ書き出す。
    static func export(_ file: URL, edit: VideoEdit, to out: URL, completion: @escaping (Bool) -> Void) {
        let asset = AVURLAsset(url: file)
        guard let video = asset.tracks(withMediaType: .video).first else { completion(false); return }
        let kept = edit.kept()
        guard !kept.isEmpty else { completion(false); return }
        func time(_ t: Double) -> CMTime { CMTime(seconds: t, preferredTimescale: 600) }
        let composition = AVMutableComposition()
        guard let v = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { completion(false); return }
        /// 元の時刻 → 書き出す動画の時刻（残す範囲ごと）
        var offsets: [(start: Double, end: Double, at: Double)] = []
        var cursor = 0.0
        for k in kept {
            guard (try? v.insertTimeRange(CMTimeRange(start: time(k.start), end: time(k.end)), of: video, at: time(cursor))) != nil else { completion(false); return }
            offsets.append((k.start, k.end, cursor))
            cursor += k.end - k.start
        }
        var mixParams: [AVMutableAudioMixInputParameters] = []
        if !edit.mute {
            for track in asset.tracks(withMediaType: .audio) {
                guard let a = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
                for o in offsets { try? a.insertTimeRange(CMTimeRange(start: time(o.start), end: time(o.end)), of: track, at: time(o.at)) }
                let params = AVMutableAudioMixInputParameters(track: a)
                params.setVolume(Float(edit.volume), at: .zero)
                mixParams.append(params)
            }
        }
        let shown = CGRect(origin: .zero, size: video.naturalSize).applying(video.preferredTransform)
        let size = CGSize(width: abs(shown.width), height: abs(shown.height))
        var preset = AVAssetExportPresetHighestQuality
        var videoComposition: AVMutableVideoComposition?
        if edit.crop != nil || !edit.zooms.isEmpty {
            // 切り抜きとズームは、コマごとの映し方（拡大・ずらし）で作る
            let crop = edit.crop ?? CGRect(x: 0, y: 0, width: 1, height: 1)
            let cropPx = CGRect(x: crop.minX * size.width, y: crop.minY * size.height, width: crop.width * size.width, height: crop.height * size.height)
            let k: CGFloat = edit.maxHeight > 0 && cropPx.height > CGFloat(edit.maxHeight) ? CGFloat(edit.maxHeight) / cropPx.height : 1
            func even(_ x: CGFloat) -> CGFloat { max(2, (x / 2).rounded() * 2) }
            let render = CGSize(width: even(cropPx.width * k), height: even(cropPx.height * k))
            // 回してある動画は、まず表示の向きに直す（左上を原点に寄せる）
            let base = video.preferredTransform.concatenating(CGAffineTransform(translationX: -shown.minX, y: -shown.minY))
            func transform(at t: Double) -> CGAffineTransform {
                let z = edit.zoomTransform(at: t)
                let zoom = CGAffineTransform(a: CGFloat(z.s), b: 0, c: 0, d: CGFloat(z.s), tx: CGFloat(z.ox) * size.width, ty: CGFloat(z.oy) * size.height)
                return base.concatenating(zoom)
                    .concatenating(CGAffineTransform(translationX: -cropPx.minX, y: -cropPx.minY))
                    .concatenating(CGAffineTransform(scaleX: render.width / cropPx.width, y: render.height / cropPx.height))
            }
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: v)
            layer.setTransform(transform(at: kept[0].start), at: .zero)
            for o in offsets {
                // ズームの始まり・寄り終わり・戻り始め・終わりで区切って、その間をなめらかにつなぐ
                var marks: Set<Double> = [o.start, o.end]
                for z in edit.zooms {
                    let ramp = min(VideoEdit.ramp, (z.end - z.start) / 2)
                    for m in [z.start, z.start + ramp, z.end - ramp, z.end] where m > o.start && m < o.end { marks.insert(m) }
                }
                let sorted = marks.sorted()
                for (m0, m1) in zip(sorted, sorted.dropFirst()) where m1 - m0 > 0.0005 {
                    layer.setTransformRamp(fromStart: transform(at: m0), toEnd: transform(at: m1),
                                           timeRange: CMTimeRange(start: time(o.at + m0 - o.start), end: time(o.at + m1 - o.start)))
                }
            }
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: .zero, duration: composition.duration)
            instruction.layerInstructions = [layer]
            let vc = AVMutableVideoComposition()
            vc.instructions = [instruction]
            vc.renderSize = render
            let fps = video.nominalFrameRate
            vc.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps >= 1 ? min(60, fps.rounded()) : 60))
            videoComposition = vc
        } else {
            v.preferredTransform = video.preferredTransform
            let shrink = edit.maxHeight > 0 && Int(size.height) > edit.maxHeight
            switch shrink ? edit.maxHeight : 0 {
            case 1080: preset = AVAssetExportPreset1920x1080
            case 720: preset = AVAssetExportPreset1280x720
            case 480: preset = AVAssetExportPreset640x480
            default: break
            }
        }
        guard let session = AVAssetExportSession(asset: composition, presetName: preset) else { completion(false); return }
        try? FileManager.default.removeItem(at: out)
        session.outputURL = out
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        session.videoComposition = videoComposition
        if !mixParams.isEmpty, abs(edit.volume - 1) > 0.01 {
            let mix = AVMutableAudioMix()
            mix.inputParameters = mixParams
            session.audioMix = mix
        }
        session.exportAsynchronously {
            DispatchQueue.main.async {
                if session.status != .completed { log("動画の書き出し失敗 \(String(describing: session.error))") }
                completion(session.status == .completed)
            }
        }
    }

    /// 編集前の動画の控え（「元に戻す」用）
    static func originalURL(for file: URL) -> URL {
        EditProject.dir.appendingPathComponent(file.deletingPathExtension().lastPathComponent + ".orig." + file.pathExtension)
    }
}

// MARK: - 映像を出す所（切り抜きの枠・ズームの枠を上に重ねる）

final class VideoCanvasView: NSView {
    let playerLayer = AVPlayerLayer()
    private let clipLayer = CALayer()
    /// 映像の縦横（ピクセル）
    var pixelSize = CGSize(width: 16, height: 9) { didSet { needsLayout = true } }
    private let marks = Marks(frame: .zero)
    /// 映像が出ている場所（この view の座標）
    private(set) var videoRect = NSRect.zero
    /// いまの映し方（再生中のズームの見え方）
    var zoom: (s: Double, ox: Double, oy: Double) = (1, 0, 0) { didSet { applyZoom() } }

    /// 切り抜く範囲（0〜1・左上が原点）
    var crop: CGRect? { didSet { marks.needsDisplay = true } }
    /// 切り抜きの枠を動かせる状態か
    var cropEditing = false { didSet { marks.needsDisplay = true; window?.invalidateCursorRects(for: self) } }
    /// 選んでいるズームで大きく映る範囲（0〜1・左上が原点）。nil なら枠を出さない
    var zoomBox: CGRect? { didSet { marks.needsDisplay = true } }
    /// began は、ドラッグの最初の1回だけ true
    var onCropChange: ((CGRect, Bool) -> Void)?
    var onZoomMove: ((CGPoint, Bool) -> Void)?
    var onClick: (() -> Void)?

    private enum Drag { case none, handle(Int), move(CGPoint, CGRect), draw(CGPoint), zoom }
    private var drag: Drag = .none
    private var dragBegan = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        clipLayer.masksToBounds = true
        playerLayer.videoGravity = .resize
        clipLayer.addSublayer(playerLayer)
        layer?.addSublayer(clipLayer)
        // 枠は映像の層より上に描きたいので、別の view に任せる
        marks.canvas = self
        marks.frame = bounds
        marks.autoresizingMask = [.width, .height]
        marks.wantsLayer = true
        addSubview(marks)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let k = min(bounds.width / max(1, pixelSize.width), bounds.height / max(1, pixelSize.height))
        let size = CGSize(width: pixelSize.width * k, height: pixelSize.height * k)
        videoRect = NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clipLayer.frame = videoRect
        playerLayer.setAffineTransform(.identity)
        playerLayer.frame = clipLayer.bounds
        CATransaction.commit()
        applyZoom()
        marks.needsDisplay = true
    }

    private func applyZoom() {
        let w = videoRect.width, h = videoRect.height
        let s = CGFloat(zoom.s)
        // 層は真ん中を軸に拡大するので、左上が原点の式に合わせてずらす（層の座標は上向きが正）
        let tx = CGFloat(zoom.ox) * w + (s - 1) * w / 2
        let ty = -(CGFloat(zoom.oy) * h + (s - 1) * h / 2)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.setAffineTransform(CGAffineTransform(a: s, b: 0, c: 0, d: s, tx: tx, ty: ty))
        CATransaction.commit()
    }

    // 0〜1（左上が原点）と、この view の座標の行き来
    private func toView(_ r: CGRect) -> NSRect {
        NSRect(x: videoRect.minX + r.minX * videoRect.width, y: videoRect.maxY - r.maxY * videoRect.height,
               width: r.width * videoRect.width, height: r.height * videoRect.height)
    }
    private func toUnit(_ p: NSPoint) -> CGPoint {
        CGPoint(x: max(0, min(1, (p.x - videoRect.minX) / max(1, videoRect.width))),
                y: max(0, min(1, (videoRect.maxY - p.y) / max(1, videoRect.height))))
    }

    final class Marks: NSView {
        weak var canvas: VideoCanvasView?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func draw(_ dirtyRect: NSRect) { canvas?.drawMarks() }
    }

    fileprivate func drawMarks() {
        if let crop = crop ?? (cropEditing ? CGRect(x: 0, y: 0, width: 1, height: 1) : nil) {
            let r = toView(crop)
            let dimPath = NSBezierPath(rect: videoRect)
            dimPath.append(NSBezierPath(rect: r))
            dimPath.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(cropEditing ? 0.6 : 0.78).setFill()
            dimPath.fill()
            let border = NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5))
            border.lineWidth = cropEditing ? 2 : 1
            (cropEditing ? NSColor.white : NSColor.white.withAlphaComponent(0.5)).setStroke()
            border.stroke()
            if cropEditing {
                for p in handlePoints(r) {
                    let dot = NSBezierPath(ovalIn: NSRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10))
                    NSColor.white.setFill()
                    dot.fill()
                    NSColor.black.withAlphaComponent(0.5).setStroke()
                    dot.stroke()
                }
            }
        }
        if let zoomBox, !cropEditing {
            let r = toView(zoomBox)
            let path = NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4)
            path.lineWidth = 2.5
            NSColor.systemPurple.setStroke()
            path.stroke()
            NSColor.systemPurple.withAlphaComponent(0.12).setFill()
            path.fill()
            let label = NSAttributedString(string: "この中が大きく映ります", attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white,
            ])
            let size = label.size()
            if r.width > size.width + 16, r.height > size.height + 14 {
                let tag = NSRect(x: r.minX + 6, y: r.maxY - size.height - 10, width: size.width + 10, height: size.height + 4)
                NSColor.systemPurple.setFill()
                NSBezierPath(roundedRect: tag, xRadius: 4, yRadius: 4).fill()
                label.draw(at: NSPoint(x: tag.minX + 5, y: tag.minY + 2))
            }
        }
    }

    /// 四隅と辺のつまみ（左下から反時計回り）
    private func handlePoints(_ r: NSRect) -> [NSPoint] {
        [NSPoint(x: r.minX, y: r.minY), NSPoint(x: r.midX, y: r.minY), NSPoint(x: r.maxX, y: r.minY), NSPoint(x: r.maxX, y: r.midY),
         NSPoint(x: r.maxX, y: r.maxY), NSPoint(x: r.midX, y: r.maxY), NSPoint(x: r.minX, y: r.maxY), NSPoint(x: r.minX, y: r.midY)]
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        dragBegan = false
        if cropEditing {
            let current = crop ?? CGRect(x: 0, y: 0, width: 1, height: 1)
            let r = toView(current)
            if let i = handlePoints(r).firstIndex(where: { hypot($0.x - p.x, $0.y - p.y) <= 13 }) {
                drag = .handle(i)
            } else if r.contains(p), current.width < 0.999 || current.height < 0.999 {
                drag = .move(toUnit(p), current)
            } else {
                drag = .draw(toUnit(p))
            }
        } else if zoomBox != nil, videoRect.contains(p) {
            drag = .zoom
            mouseDragged(with: event)
        } else {
            drag = .none
            onClick?()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let u = toUnit(convert(event.locationInWindow, from: nil))
        let minSide = 0.06
        func send(_ r: CGRect) {
            onCropChange?(r, !dragBegan)
            dragBegan = true
        }
        switch drag {
        case .handle(let i):
            var r = crop ?? CGRect(x: 0, y: 0, width: 1, height: 1)
            var x0 = Double(r.minX), x1 = Double(r.maxX), y0 = Double(r.minY), y1 = Double(r.maxY)   // y は下向きが正
            // 左下から反時計回り：0 左下・1 下・2 右下・3 右・4 右上・5 上・6 左上・7 左
            if [0, 6, 7].contains(i) { x0 = min(Double(u.x), x1 - minSide) }
            if [2, 3, 4].contains(i) { x1 = max(Double(u.x), x0 + minSide) }
            if [0, 1, 2].contains(i) { y1 = max(Double(u.y), y0 + minSide) }
            if [4, 5, 6].contains(i) { y0 = min(Double(u.y), y1 - minSide) }
            r = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
            send(r)
        case .move(let from, let original):
            let x = max(0, min(1 - original.width, original.minX + u.x - from.x))
            let y = max(0, min(1 - original.height, original.minY + u.y - from.y))
            send(CGRect(x: x, y: y, width: original.width, height: original.height))
        case .draw(let from):
            let r = CGRect(x: min(from.x, u.x), y: min(from.y, u.y), width: abs(u.x - from.x), height: abs(u.y - from.y))
            if r.width >= minSide, r.height >= minSide { send(r) }
        case .zoom:
            onZoomMove?(u, !dragBegan)
            dragBegan = true
        case .none:
            break
        }
    }

    override func mouseUp(with event: NSEvent) { drag = .none }

    override func resetCursorRects() {
        if cropEditing { addCursorRect(bounds, cursor: .crosshair) }
    }
}

// MARK: - 下の帯（コマの並び・切り出す範囲・分けた区切り・ズーム・再生位置）

final class TimelineView: NSView {
    var duration: Double = 1
    var start: Double = 0 { didSet { needsDisplay = true } }
    var end: Double = 1 { didSet { needsDisplay = true } }
    var playhead: Double = 0 { didSet { needsDisplay = true } }
    var thumbs: [NSImage] = [] { didSet { needsDisplay = true } }
    var pieces: [VideoEdit.Piece] = [] { didSet { needsDisplay = true } }
    var zooms: [VideoZoom] = [] { didSet { needsDisplay = true } }
    var selectedPiece: Int? { didSet { needsDisplay = true } }
    var selectedZoom: Int? { didSet { needsDisplay = true } }
    var onSeek: ((Double) -> Void)?
    var onTrim: ((Double, Double) -> Void)?
    /// 帯の中を押したとき（区切りの番号。分けていなければ nil）
    var onSelectPiece: ((Int?) -> Void)?
    var onSelectZoom: ((Int?) -> Void)?
    /// ズームの帯を動かした（番号・始まり・終わり・ドラッグの最初か）
    var onZoomChange: ((Int, Double, Double, Bool) -> Void)?
    /// 切り出す範囲の最短（秒）
    static let minLength = 0.3
    static let zoomLane: CGFloat = 18

    private enum Drag { case none, start, end, seek, zoomStart(Int), zoomEnd(Int), zoomMove(Int, Double, Double, Double) }
    private var drag: Drag = .none
    private var dragBegan = false
    private let inset: CGFloat = 12

    private var strip: NSRect { NSRect(x: inset, y: 6 + Self.zoomLane, width: bounds.width - inset * 2, height: bounds.height - 12 - Self.zoomLane) }
    private var lane: NSRect { NSRect(x: inset, y: 4, width: bounds.width - inset * 2, height: Self.zoomLane - 4) }
    private func x(_ t: Double) -> CGFloat { strip.minX + CGFloat(t / max(0.001, duration)) * strip.width }
    private func time(_ x: CGFloat) -> Double { Double(max(0, min(1, (x - strip.minX) / strip.width))) * duration }
    private func zoomRect(_ z: VideoZoom) -> NSRect { NSRect(x: x(z.start), y: lane.minY, width: max(6, x(z.end) - x(z.start)), height: lane.height) }

    override func draw(_ dirtyRect: NSRect) {
        let s = strip
        let clip = NSBezierPath(roundedRect: s, xRadius: 6, yRadius: 6)
        NSGraphicsContext.saveGraphicsState()
        clip.addClip()
        NSColor(white: 0.2, alpha: 1).setFill()
        s.fill()
        if !thumbs.isEmpty {
            let w = s.width / CGFloat(thumbs.count)
            for (i, image) in thumbs.enumerated() {
                // コマは枠いっぱいに、縦横比を保って敷く
                let cell = NSRect(x: s.minX + CGFloat(i) * w, y: s.minY, width: w + 1, height: s.height)
                let k = max(cell.width / image.size.width, cell.height / image.size.height)
                let size = NSSize(width: image.size.width * k, height: image.size.height * k)
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: cell).addClip()
                image.draw(in: NSRect(x: cell.midX - size.width / 2, y: cell.midY - size.height / 2, width: size.width, height: size.height))
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        // 切り落とす所を暗くする
        NSColor.black.withAlphaComponent(0.62).setFill()
        NSRect(x: s.minX, y: s.minY, width: x(start) - s.minX, height: s.height).fill()
        NSRect(x: x(end), y: s.minY, width: s.maxX - x(end), height: s.height).fill()
        // 消した部分は暗くして、斜めの線を入れる
        for piece in pieces where piece.removed {
            let r = NSRect(x: x(piece.start), y: s.minY, width: x(piece.end) - x(piece.start), height: s.height)
            NSColor.black.withAlphaComponent(0.7).setFill()
            r.fill()
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: r).addClip()
            NSColor.systemRed.withAlphaComponent(0.55).setStroke()
            var lx = r.minX - r.height
            while lx < r.maxX {
                let line = NSBezierPath()
                line.move(to: NSPoint(x: lx, y: r.minY))
                line.line(to: NSPoint(x: lx + r.height, y: r.maxY))
                line.lineWidth = 1.5
                line.stroke()
                lx += 9
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        NSGraphicsContext.restoreGraphicsState()

        // 残す範囲の枠と、左右のつまみ
        let keep = NSRect(x: x(start), y: s.minY, width: x(end) - x(start), height: s.height)
        let frame = NSBezierPath(roundedRect: keep.insetBy(dx: -1, dy: 0), xRadius: 5, yRadius: 5)
        frame.lineWidth = 3
        NSColor.systemYellow.setStroke()
        frame.stroke()
        // 分けた位置
        for piece in pieces.dropFirst() {
            NSColor.black.withAlphaComponent(0.7).setFill()
            NSRect(x: x(piece.start) - 2, y: s.minY, width: 4, height: s.height).fill()
            NSColor.systemYellow.setFill()
            NSRect(x: x(piece.start) - 1, y: s.minY, width: 2, height: s.height).fill()
        }
        // 選んだ区切り
        if let i = selectedPiece, pieces.indices.contains(i), pieces.count > 1 {
            let piece = pieces[i]
            let r = NSRect(x: x(piece.start), y: s.minY, width: x(piece.end) - x(piece.start), height: s.height)
            let outline = NSBezierPath(roundedRect: r.insetBy(dx: 2, dy: 2.5), xRadius: 4, yRadius: 4)
            outline.lineWidth = 2.5
            NSColor.white.setStroke()
            outline.stroke()
        }
        for edge in [keep.minX, keep.maxX] {
            let grip = NSBezierPath(roundedRect: NSRect(x: edge - 5, y: s.midY - 13, width: 10, height: 26), xRadius: 4, yRadius: 4)
            NSColor.systemYellow.setFill()
            grip.fill()
            NSColor.black.withAlphaComponent(0.45).setFill()
            NSRect(x: edge - 0.75, y: s.midY - 6, width: 1.5, height: 12).fill()
        }
        // ズーム
        for (i, z) in zooms.enumerated() {
            let r = zoomRect(z)
            let bar = NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4)
            NSColor.systemPurple.withAlphaComponent(i == selectedZoom ? 1 : 0.6).setFill()
            bar.fill()
            if i == selectedZoom {
                bar.lineWidth = 1.5
                NSColor.white.setStroke()
                bar.stroke()
            }
            let label = NSAttributedString(string: "×\(String(format: "%g", z.scale))", attributes: [
                .font: NSFont.systemFont(ofSize: 9, weight: .bold), .foregroundColor: NSColor.white,
            ])
            if r.width > label.size().width + 8 { label.draw(at: NSPoint(x: r.minX + 5, y: r.midY - label.size().height / 2)) }
        }
        // 再生位置
        let p = x(max(0, min(duration, playhead)))
        NSColor.white.setFill()
        NSRect(x: p - 1, y: bounds.minY + 1, width: 2, height: bounds.height - 2).fill()
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        dragBegan = false
        if p.y < strip.minY - 1 {
            // ズームの段
            if let i = zooms.indices.first(where: { zoomRect(zooms[$0]).insetBy(dx: -4, dy: -3).contains(p) }) {
                let r = zoomRect(zooms[i])
                onSelectZoom?(i)
                if p.x - r.minX <= 6 { drag = .zoomStart(i) }
                else if r.maxX - p.x <= 6 { drag = .zoomEnd(i) }
                else { drag = .zoomMove(i, time(p.x), zooms[i].start, zooms[i].end) }
                onSeek?(max(zooms[i].start, min(zooms[i].end, time(p.x))))
            } else {
                onSelectZoom?(nil)
                drag = .seek
                mouseDragged(with: event)
            }
            return
        }
        if abs(p.x - x(start)) <= 9 { drag = .start }
        else if abs(p.x - x(end)) <= 9 { drag = .end }
        else {
            drag = .seek
            let t = time(p.x)
            onSelectPiece?(pieces.count > 1 ? pieces.firstIndex { t >= $0.start && t <= $0.end } : nil)
        }
        mouseDragged(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        apply(time(convert(event.locationInWindow, from: nil).x))
    }

    override func mouseUp(with event: NSEvent) { drag = .none }

    private func apply(_ t: Double) {
        func change(_ i: Int, _ a: Double, _ b: Double) {
            onZoomChange?(i, a, b, !dragBegan)
            dragBegan = true
        }
        switch drag {
        case .start:
            start = max(0, min(t, end - Self.minLength))
            onTrim?(start, end)
            onSeek?(start)
        case .end:
            end = min(duration, max(t, start + Self.minLength))
            onTrim?(start, end)
            onSeek?(end)
        case .seek:
            onSeek?(t)
        case .zoomStart(let i):
            guard zooms.indices.contains(i) else { return }
            change(i, min(t, zooms[i].end - 0.4), zooms[i].end)
        case .zoomEnd(let i):
            guard zooms.indices.contains(i) else { return }
            change(i, zooms[i].start, max(t, zooms[i].start + 0.4))
        case .zoomMove(let i, let from, let a, let b):
            guard zooms.indices.contains(i) else { return }
            let d = max(-a, min(duration - b, t - from))
            if abs(d) > 0.0001 || dragBegan { change(i, a + d, b + d) }
        case .none:
            break
        }
    }
}

/// キー操作を受けるための窓。
final class VideoEditorWindow: NSWindow {
    var onKey: ((NSEvent) -> Bool)?
    var onUndo: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }
    /// 「編集」メニューの「取り消す」（⌘Z）
    @objc func undo(_ sender: Any?) { onUndo?() }
}

// MARK: - 窓

final class VideoEditorController: NSObject, NSWindowDelegate {
    static var openEditors: [VideoEditorController] = []
    /// 動作確認のときは画面に出さない
    static var headless = false

    let fileURL: URL
    let window: VideoEditorWindow
    private(set) var edit = VideoEdit()
    private(set) var duration: Double = 0
    private var pixelSize = CGSize.zero
    private var player: AVPlayer!
    let canvas = VideoCanvasView(frame: .zero)
    private let timeline = TimelineView()
    /// 帯で選んでいる区切り・ズーム
    private(set) var selectedPiece: Int?
    private(set) var selectedZoom: Int?
    private(set) var cropMode = false
    /// 取り消し用の控え
    private var undoStack: [VideoEdit] = []
    private var splitButton: PillButton!
    private var removeButton: PillButton!
    private var cropButton: PillButton!
    private var cropClearButton: PillButton!
    private var zoomButton: PillButton!
    private var zoomScalePopup: NSPopUpButton!
    private var zoomDeleteButton: PillButton!
    private var hintLabel: NSTextField!
    private var observer: Any?
    private var playButton: ToolButton!
    private var timeLabel: NSTextField!
    private var infoLabel: NSTextField!
    private var muteBox: NSButton!
    private var volumeSlider: NSSlider!
    private var heightPopup: NSPopUpButton!
    private var revertButton: PillButton!
    private var doneButton: PillButton!
    private var busyLabel: NSTextField!
    private var busy = false { didSet { busyLabel.isHidden = !busy; doneButton.isEnabled = !busy } }
    private let onFinish: (() -> Void)?

    @discardableResult
    static func open(file: URL, onFinish: (() -> Void)? = nil) -> VideoEditorController? {
        if let existing = openEditors.first(where: { $0.fileURL == file }) {
            NSApp.activate(ignoringOtherApps: true)
            existing.window.makeKeyAndOrderFront(nil)
            return existing
        }
        guard let info = videoInfo(file), info.seconds > 0 else {
            log("動画エディタ: 開けない \(file.lastPathComponent)")
            NSSound.beep()
            return nil
        }
        let controller = VideoEditorController(file: file, onFinish: onFinish)
        openEditors.append(controller)
        if !headless {
            NSApp.activate(ignoringOtherApps: true)
            controller.window.makeKeyAndOrderFront(nil)
        }
        return controller
    }

    private init(file: URL, onFinish: (() -> Void)?) {
        fileURL = file
        self.onFinish = onFinish
        let screen = screenUnderMouse()
        let visible = screen.visibleFrame
        let size = CGSize(width: min(980, visible.width * 0.9), height: min(680, visible.height * 0.85))
        let origin = CGPoint(x: visible.midX - size.width / 2 - screen.frame.minX, y: visible.midY - size.height / 2 - screen.frame.minY)
        window = VideoEditorWindow(contentRect: NSRect(origin: origin, size: size),
                                   styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false, screen: screen)
        super.init()
        window.title = "Kiritori 動画の編集"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 860, height: 540)
        window.appearance = NSAppearance(named: .darkAqua)
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(white: 0.135, alpha: 1)
        window.delegate = self
        window.onKey = { [weak self] event in self?.handleKey(event) ?? false }
        window.onUndo = { [weak self] in self?.undo() }
        buildUI()
        load()
    }

    // MARK: 画面

    private func buildUI() {
        func pill(_ caption: String, width: CGFloat, tip: String, _ action: Selector) -> PillButton {
            let b = PillButton(caption: caption, primary: false, target: self, action: action)
            b.constraints.first { $0.firstAttribute == .width }?.constant = width
            b.toolTip = tip
            return b
        }
        splitButton = pill("ここで分ける", width: 104, tip: "再生位置で2つに分けます（S）。分けた部分は帯で選んで消せます", #selector(splitTapped))
        removeButton = pill("選んだ部分を消す", width: 128, tip: "帯で選んだ部分を書き出しから外します（delete）。もう一度押すと戻ります", #selector(removeTapped))
        cropButton = pill("切り抜く", width: 104, tip: "映像の一部だけを残します（C）。枠の丸をドラッグして範囲を決めます", #selector(cropTapped))
        cropClearButton = pill("切り抜きをやめる", width: 128, tip: "切り抜きを外して、映像の全体に戻します", #selector(cropClearTapped))
        zoomButton = pill("ズームを足す", width: 104, tip: "再生位置から2秒間、映像の一部を大きく見せます（Z）", #selector(zoomTapped))
        zoomDeleteButton = pill("ズームを消す", width: 104, tip: "選んだズームを消します（delete）", #selector(zoomDeleteTapped))
        zoomScalePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        zoomScalePopup.controlSize = .small
        zoomScalePopup.addItems(withTitles: VideoEdit.zoomScales.map(\.0))
        zoomScalePopup.selectItem(at: 1)
        zoomScalePopup.target = self
        zoomScalePopup.action = #selector(zoomScaleChanged)
        zoomScalePopup.toolTip = "ズームの倍率"
        hintLabel = optionLabel("")
        hintLabel.lineBreakMode = .byTruncatingTail
        hintLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        playButton = ToolButton(symbol: "play.fill", caption: "", size: NSSize(width: 38, height: 30), target: self, action: #selector(togglePlay))
        playButton.toolTip = "再生・一時停止（space）"
        timeLabel = NSTextField(labelWithString: "")
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        timeLabel.textColor = NSColor(white: 0.85, alpha: 1)
        infoLabel = optionLabel("")
        infoLabel.lineBreakMode = .byTruncatingTail
        infoLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        muteBox = NSButton(checkboxWithTitle: "音を消す", target: self, action: #selector(muteChanged))
        volumeSlider = NSSlider(value: 1, minValue: 0, maxValue: 2, target: self, action: #selector(volumeChanged))
        volumeSlider.controlSize = .small
        volumeSlider.translatesAutoresizingMaskIntoConstraints = false
        volumeSlider.widthAnchor.constraint(equalToConstant: 90).isActive = true
        volumeSlider.toolTip = "音量。真ん中がそのまま、右端が2倍"
        heightPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        heightPopup.controlSize = .small
        heightPopup.target = self
        heightPopup.action = #selector(heightChanged)
        heightPopup.toolTip = "大きさの上限。小さくするとファイルが軽くなります"

        let frameButton = PillButton(caption: "いまのコマを画像に", primary: false, target: self, action: #selector(frameTapped))
        let gifButton = PillButton(caption: "GIFにする", primary: false, target: self, action: #selector(gifTapped))
        let saveAsButton = PillButton(caption: "別の動画として保存", primary: false, target: self, action: #selector(saveAsTapped))
        revertButton = PillButton(caption: "元に戻す", primary: false, target: self, action: #selector(revertTapped))
        doneButton = PillButton(caption: "完了", primary: true, target: self, action: #selector(doneTapped))
        // 名前が長いボタンは、文字に合わせて幅を広げる
        for (button, width) in [(frameButton, 150), (gifButton, 96), (saveAsButton, 158), (revertButton, 86)] as [(PillButton, CGFloat)] {
            button.constraints.first { $0.firstAttribute == .width }?.constant = width
        }
        frameButton.toolTip = "再生位置のコマをスクショとして履歴に入れます"
        gifButton.toolTip = "残す範囲を GIF にして履歴に入れます（音なし）"
        saveAsButton.toolTip = "編集した動画を保存先フォルダへ別のファイルとして保存します。元の録画は変わりません"
        revertButton.toolTip = "前に「完了」で上書きする前の録画に戻します"
        doneButton.toolTip = "編集を録画に反映して閉じます"
        busyLabel = optionLabel("書き出しています…")
        busyLabel.textColor = .systemYellow
        busyLabel.isHidden = true

        let controls = NSStackView(views: [playButton, timeLabel, separatorView(), muteBox, optionLabel("音量"), volumeSlider,
                                           separatorView(), optionLabel("大きさ"), heightPopup, infoLabel])
        controls.orientation = .horizontal
        controls.spacing = 10
        controls.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
        let actions = NSStackView(views: [frameButton, gifButton, saveAsButton, revertButton, NSView(), busyLabel, doneButton])
        actions.orientation = .horizontal
        actions.spacing = 8
        actions.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)

        let tools = NSStackView(views: [splitButton, removeButton, separatorView(), cropButton, cropClearButton, separatorView(),
                                        zoomButton, zoomScalePopup, zoomDeleteButton, hintLabel])
        tools.orientation = .horizontal
        tools.spacing = 8
        tools.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)

        let content = NSView()
        for v in [canvas, timeline, tools, controls, actions] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        window.contentView = content
        NSLayoutConstraint.activate([
            canvas.topAnchor.constraint(equalTo: content.topAnchor, constant: 30),
            canvas.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            canvas.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            timeline.topAnchor.constraint(equalTo: canvas.bottomAnchor, constant: 10),
            timeline.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 2),
            timeline.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -2),
            timeline.heightAnchor.constraint(equalToConstant: 64 + TimelineView.zoomLane),
            tools.topAnchor.constraint(equalTo: timeline.bottomAnchor, constant: 4),
            tools.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            tools.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            tools.heightAnchor.constraint(equalToConstant: 36),
            controls.topAnchor.constraint(equalTo: tools.bottomAnchor, constant: 2),
            controls.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            controls.heightAnchor.constraint(equalToConstant: 34),
            actions.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 4),
            actions.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            actions.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            actions.heightAnchor.constraint(equalToConstant: 40),
            actions.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
        ])
        timeline.onSeek = { [weak self] t in self?.seek(t) }
        timeline.onTrim = { [weak self] a, b in self?.setTrim(start: a, end: b) }
        timeline.onSelectPiece = { [weak self] i in self?.select(piece: i) }
        timeline.onSelectZoom = { [weak self] i in self?.select(zoom: i) }
        timeline.onZoomChange = { [weak self] i, a, b, began in
            guard let self, self.edit.zooms.indices.contains(i) else { return }
            if began { self.pushUndo() }
            self.setZoomRange(i, start: a, end: b)
        }
        canvas.onClick = { [weak self] in self?.togglePlay() }
        canvas.onCropChange = { [weak self] rect, began in
            guard let self else { return }
            if began { self.pushUndo() }
            self.edit.crop = rect
            self.sync()
        }
        canvas.onZoomMove = { [weak self] center, began in
            guard let self, let i = self.selectedZoom, self.edit.zooms.indices.contains(i) else { return }
            if began { self.pushUndo() }
            self.edit.zooms[i].cx = Double(center.x)
            self.edit.zooms[i].cy = Double(center.y)
            self.sync()
        }
    }

    /// 動画を読み込んで、編集をまっさらにする（開いたときと「元に戻す」のあと）。
    private func load() {
        if let observer { player?.removeTimeObserver(observer) }
        let info = videoInfo(fileURL)
        duration = info?.seconds ?? 0
        pixelSize = CGSize(width: info?.width ?? 0, height: info?.height ?? 0)
        edit = VideoEdit(start: 0, end: duration)
        selectedPiece = nil
        selectedZoom = nil
        cropMode = false
        undoStack = []
        measured = nil
        player = AVPlayer(url: fileURL)
        canvas.playerLayer.player = player
        canvas.pixelSize = pixelSize
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            self?.tick(CMTimeGetSeconds(time))
        }
        timeline.duration = duration
        timeline.start = 0
        timeline.end = duration
        timeline.playhead = 0
        heightPopup.removeAllItems()
        // 元より大きい上限は意味がないので出さない
        let choices = VideoEdit.heights.filter { $0.1 == 0 || $0.1 < Int(pixelSize.height) }
        heightPopup.addItems(withTitles: choices.map(\.0))
        heightPopup.isEnabled = choices.count > 1
        makeThumbs()
        sync()
    }

    private func makeThumbs() {
        let url = fileURL, total = duration, count = 14
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 240, height: 240)
            var images: [NSImage] = []
            for i in 0..<count {
                let t = CMTime(seconds: total * (Double(i) + 0.5) / Double(count), preferredTimescale: 600)
                if let cg = try? generator.copyCGImage(at: t, actualTime: nil) {
                    images.append(NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)))
                }
            }
            DispatchQueue.main.async { self?.timeline.thumbs = images }
        }
    }

    private var hasBackup: Bool { FileManager.default.fileExists(atPath: VideoExporter.originalURL(for: fileURL).path) }
    var hasChanges: Bool { edit != VideoEdit(start: 0, end: duration) }

    /// 実際に書き出して量った大きさ（どの編集のときの値か、と一緒に持つ）
    private var measured: (edit: VideoEdit, bytes: Double)?
    private var measuring: VideoEdit?
    private var measureWork: DispatchWorkItem?
    /// これより長いと量るのに時間がかかるので、割合からの目安だけ出す（秒）
    private static let measureLimit = 240.0

    /// 編集の手が止まったら、裏で一度書き出して大きさを量る。割合からの計算は、動画によって2倍近くずれるため。
    private func scheduleMeasure() {
        measureWork?.cancel()
        guard hasChanges, !Self.headless, measured?.edit != edit, edit.keptLength <= Self.measureLimit else { return }
        let work = DispatchWorkItem { [weak self] in self?.measureNow() }
        measureWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
    }

    private func measureNow() {
        guard measuring == nil, !busy, hasChanges else { return }
        let target = edit
        measuring = target
        let temp = tempURL()
        VideoExporter.export(fileURL, edit: target, to: temp) { [weak self] ok in
            let bytes = Double((try? FileManager.default.attributesOfItem(atPath: temp.path)[.size] as? Int) ?? 0)
            try? FileManager.default.removeItem(at: temp)
            guard let self else { return }
            self.measuring = nil
            if ok, bytes > 0 { self.measured = (target, bytes) }
            if self.edit == target { self.updateLabels() } else { self.scheduleMeasure() }   // 量っている間に変わっていたら量り直す
        }
    }

    private func sizeText(_ bytes: Double) -> String {
        bytes >= 1_048_576 ? String(format: "%.1f MB", bytes / 1_048_576) : String(format: "%.0f KB", bytes / 1024)
    }

    /// 書き出したあとの大きさの見込み（長さと大きさの割合からの目安）。
    var estimatedBytes: Double {
        let original = Double((try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? 0)
        var estimate = original * edit.keptLength / max(0.01, duration)
        let crop = edit.crop ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        estimate *= Double(crop.width * crop.height)
        let height = pixelSize.height * crop.height
        if edit.maxHeight > 0, height > CGFloat(edit.maxHeight) {
            let k = Double(edit.maxHeight) / Double(height)
            estimate *= k * k
        }
        return estimate
    }

    private func sync() {
        muteBox.state = edit.mute ? .on : .off
        volumeSlider.doubleValue = edit.volume
        volumeSlider.isEnabled = !edit.mute
        if let i = VideoEdit.heights.first(where: { $0.1 == edit.maxHeight }).flatMap({ heightPopup.indexOfItem(withTitle: $0.0) }), i >= 0 {
            heightPopup.selectItem(at: i)
        }
        revertButton.isHidden = !hasBackup
        doneButton.caption = hasChanges ? "完了" : "閉じる"
        // 分ける・切り抜き・ズーム
        let pieces = edit.pieces()
        if let i = selectedPiece, !pieces.indices.contains(i) || pieces.count < 2 { selectedPiece = nil }
        if let i = selectedZoom, !edit.zooms.indices.contains(i) { selectedZoom = nil }
        timeline.pieces = pieces
        timeline.zooms = edit.zooms
        timeline.selectedPiece = selectedPiece
        timeline.selectedZoom = selectedZoom
        removeButton.isEnabled = selectedPiece != nil
        removeButton.caption = selectedPiece.map { pieces[$0].removed } == true ? "選んだ部分を戻す" : "選んだ部分を消す"
        cropButton.caption = cropMode ? "切り抜きを決める" : "切り抜く"
        cropClearButton.isHidden = edit.crop == nil && !cropMode
        zoomDeleteButton.isHidden = selectedZoom == nil
        if let i = selectedZoom, let k = VideoEdit.zoomScales.firstIndex(where: { $0.1 == edit.zooms[i].scale }) { zoomScalePopup.selectItem(at: k) }
        canvas.crop = edit.crop
        canvas.cropEditing = cropMode
        canvas.zoomBox = selectedZoom.map { edit.zooms[$0].box }
        if cropMode { hintLabel.stringValue = "丸をドラッグして残す範囲を決めます。決まったら「切り抜きを決める」" }
        else if selectedZoom != nil { hintLabel.stringValue = "紫の枠をドラッグして、大きく見せたい場所へ動かします" }
        else if selectedPiece != nil { hintLabel.stringValue = "delete で消す・戻す" }
        else { hintLabel.stringValue = "" }
        updatePreviewZoom()
        scheduleMeasure()
        player.isMuted = edit.mute
        player.volume = Float(min(1, edit.volume))
        updateLabels()
    }

    private func updateLabels() {
        func stamp(_ t: Double) -> String { String(format: "%d:%04.1f", Int(t) / 60, t.truncatingRemainder(dividingBy: 60)) }
        timeLabel.stringValue = "\(stamp(timeline.playhead)) / \(stamp(duration))"
        var parts = ["残す長さ \(stamp(edit.keptLength))"]
        if hasChanges {
            if let measured, measured.edit == edit { parts.append("書き出すと \(sizeText(measured.bytes))") }
            else if edit.keptLength <= Self.measureLimit, !Self.headless { parts.append("書き出すと …（量っています）") }
            else { parts.append("書き出すと \(sizeText(estimatedBytes)) 前後（目安）") }
        }
        infoLabel.stringValue = parts.joined(separator: "　")
    }

    // MARK: 再生

    private func tick(_ t: Double) {
        guard t.isFinite else { return }
        timeline.playhead = t
        if player.rate > 0 {
            let kept = edit.kept()
            if t >= (kept.last?.end ?? edit.end) - 0.02 {   // 残す範囲の終わりで止めて、頭へ戻す
                player.pause()
                seek(kept.first?.start ?? edit.start)
            } else if !kept.contains(where: { t >= $0.start - 0.02 && t < $0.end }), let next = kept.first(where: { $0.start > t }) {
                seek(next.start)   // 消した部分は飛ばす
            }
        }
        updatePreviewZoom()
        playButton.setSymbol(player.rate > 0 ? "pause.fill" : "play.fill")
        updateLabels()
    }

    func seek(_ t: Double) {
        let clamped = max(0, min(duration, t))
        timeline.playhead = clamped
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        updatePreviewZoom()
        updateLabels()
    }

    /// 再生中だけ、ズームを実際の見え方で映す。止めて枠を動かしている間は、全体を映したままにする。
    private func updatePreviewZoom() {
        let editing = cropMode || (selectedZoom != nil && (player?.rate ?? 0) == 0)
        canvas.zoom = editing ? (1, 0, 0) : edit.zoomTransform(at: timeline.playhead)
    }

    @objc func togglePlay() {
        if player.rate > 0 {
            player.pause()
        } else {
            let kept = edit.kept()
            let t = timeline.playhead
            if t >= (kept.last?.end ?? edit.end) - 0.05 || !kept.contains(where: { t >= $0.start && t < $0.end }) {
                seek(kept.first(where: { $0.start > t })?.start ?? kept.first?.start ?? edit.start)
            }
            if cropMode { setCropMode(false) }
            player.play()
        }
        updatePreviewZoom()
        playButton.setSymbol(player.rate > 0 ? "pause.fill" : "play.fill")
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let step = 1.0 / 30
        switch Int(event.keyCode) {
        case kVK_Space: togglePlay()
        case kVK_LeftArrow: player.pause(); seek(timeline.playhead - (event.modifierFlags.contains(.shift) ? 1 : step))
        case kVK_RightArrow: player.pause(); seek(timeline.playhead + (event.modifierFlags.contains(.shift) ? 1 : step))
        case kVK_ANSI_I: setTrim(start: min(timeline.playhead, edit.end - TimelineView.minLength), end: edit.end)
        case kVK_ANSI_O: setTrim(start: edit.start, end: max(timeline.playhead, edit.start + TimelineView.minLength))
        case kVK_ANSI_S: splitTapped()
        case kVK_ANSI_C: cropTapped()
        case kVK_ANSI_Z where !event.modifierFlags.contains(.command): zoomTapped()
        case kVK_Delete, kVK_ForwardDelete:
            if selectedZoom != nil { zoomDeleteTapped() } else if selectedPiece != nil { removeTapped() } else { return false }
        case kVK_Escape where cropMode: setCropMode(false)
        case kVK_Escape where selectedZoom != nil || selectedPiece != nil: select(piece: nil)
        default: return false
        }
        return true
    }

    // MARK: 編集

    func setTrim(start: Double, end: Double) {
        edit.start = max(0, min(start, duration))
        edit.end = max(edit.start, min(end, duration))
        timeline.start = edit.start
        timeline.end = edit.end
        sync()
    }

    // MARK: 分ける・切り抜き・ズーム

    private func pushUndo() {
        undoStack.append(edit)
        if undoStack.count > 60 { undoStack.removeFirst() }
    }

    /// ひとつ前の状態に戻す（⌘Z）。分ける・消す・切り抜き・ズームが対象
    func undo() {
        guard let previous = undoStack.popLast() else { NSSound.beep(); return }
        edit = previous
        timeline.start = edit.start
        timeline.end = edit.end
        sync()
    }

    func select(piece: Int?) {
        selectedPiece = piece
        selectedZoom = nil
        sync()
    }

    func select(zoom: Int?) {
        selectedZoom = zoom
        selectedPiece = nil
        if zoom != nil { player.pause(); setCropMode(false) }
        sync()
    }

    /// 再生位置で分ける。端に近すぎる・もう分けてある所では何もしない。
    @discardableResult
    func split(at t: Double) -> Bool {
        let near = 0.15
        guard t > edit.start + near, t < edit.end - near, !edit.splits.contains(where: { abs($0 - t) < near }) else { return false }
        pushUndo()
        edit.splits.append(t)
        edit.splits.sort()
        selectedPiece = edit.pieces().firstIndex { t >= $0.start && t < $0.end }
        selectedZoom = nil
        sync()
        return true
    }

    /// 区切りを消す・戻す。全部を消すことはできない。
    @discardableResult
    func toggleRemoved(piece i: Int) -> Bool {
        let pieces = edit.pieces()
        guard pieces.indices.contains(i), pieces.count > 1 else { return false }
        let p = pieces[i]
        let mid = (p.start + p.end) / 2
        if p.removed {
            pushUndo()
            edit.removed.removeAll { $0.contains(mid) }
        } else {
            guard pieces.filter({ !$0.removed }).count > 1 else { return false }
            pushUndo()
            edit.removed.append(p.start...p.end)
        }
        sync()
        return true
    }

    func setCropMode(_ on: Bool) {
        guard cropMode != on else { return }
        cropMode = on
        if on {
            player.pause()
            selectedZoom = nil
            selectedPiece = nil
        } else if let c = edit.crop, c.width > 0.995, c.height > 0.995 {
            edit.crop = nil   // 全体のままなら、切り抜きなしにする
        }
        sync()
    }

    func setCrop(_ rect: CGRect?) {
        pushUndo()
        edit.crop = rect
        sync()
    }

    /// 再生位置からズームを足す。ほかのズームと重なる所には足さない（そのズームを選ぶ）。
    @discardableResult
    func addZoom(at t: Double, scale: Double? = nil) -> Bool {
        if let i = edit.zooms.firstIndex(where: { t >= $0.start && t <= $0.end }) {
            select(zoom: i)
            return false
        }
        let limit = edit.zooms.map(\.start).filter { $0 > t }.min() ?? duration
        let end = min(t + 2, limit, duration)
        guard end - t >= 0.4 else { return false }
        pushUndo()
        let s = scale ?? VideoEdit.zoomScales[max(0, zoomScalePopup.indexOfSelectedItem)].1
        edit.zooms.append(VideoZoom(start: t, end: end, scale: s))
        edit.zooms.sort { $0.start < $1.start }
        select(zoom: edit.zooms.firstIndex { $0.start == t })
        return true
    }

    /// ズームの長さと位置を変える。隣のズームには重ねない。
    func setZoomRange(_ i: Int, start: Double, end: Double) {
        guard edit.zooms.indices.contains(i) else { return }
        let lower = i > 0 ? edit.zooms[i - 1].end : 0
        let upper = i + 1 < edit.zooms.count ? edit.zooms[i + 1].start : duration
        let a = max(lower, min(start, upper - 0.4))
        let b = min(upper, max(end, a + 0.4))
        edit.zooms[i].start = a
        edit.zooms[i].end = b
        sync()
    }

    @objc private func splitTapped() { if !split(at: timeline.playhead) { NSSound.beep() } }
    @objc private func removeTapped() {
        guard let i = selectedPiece else { return }
        if !toggleRemoved(piece: i) { NSSound.beep() }
    }
    @objc private func cropTapped() { setCropMode(!cropMode) }
    @objc private func cropClearTapped() {
        if edit.crop != nil { pushUndo() }
        edit.crop = nil
        cropMode = false
        sync()
    }
    @objc private func zoomTapped() {
        player.pause()
        if !addZoom(at: timeline.playhead), selectedZoom == nil { NSSound.beep() }
    }
    @objc private func zoomDeleteTapped() {
        guard let i = selectedZoom, edit.zooms.indices.contains(i) else { return }
        pushUndo()
        edit.zooms.remove(at: i)
        selectedZoom = nil
        sync()
    }
    @objc private func zoomScaleChanged() {
        guard let i = selectedZoom, edit.zooms.indices.contains(i) else { return }
        pushUndo()
        edit.zooms[i].scale = VideoEdit.zoomScales[max(0, zoomScalePopup.indexOfSelectedItem)].1
        sync()
    }

    func setMute(_ on: Bool) { edit.mute = on; sync() }
    func setVolume(_ v: Double) { edit.volume = max(0, min(2, v)); sync() }
    func setMaxHeight(_ h: Int) { edit.maxHeight = h; sync() }

    @objc private func muteChanged() { setMute(muteBox.state == .on) }
    @objc private func volumeChanged() {
        var v = volumeSlider.doubleValue
        if abs(v - 1) < 0.06 { v = 1 }   // 真ん中に吸い付かせる
        setVolume(v)
    }
    @objc private func heightChanged() {
        setMaxHeight(VideoEdit.heights.first { $0.0 == heightPopup.titleOfSelectedItem }?.1 ?? 0)
    }

    private func tempURL(_ ext: String = "mp4") -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("kiritori-edit-\(UUID().uuidString).\(ext)")
    }

    /// 完了: 編集を録画に反映して閉じる。最初の1回だけ、編集前の録画を控えておく。
    @objc func doneTapped() { finish(completion: nil) }

    func finish(completion: ((Bool) -> Void)?) {
        guard hasChanges else { window.close(); completion?(true); return }
        guard !busy else { return }
        busy = true
        player.pause()
        let temp = tempURL(fileURL.pathExtension == "mov" ? "mp4" : fileURL.pathExtension)
        VideoExporter.export(fileURL, edit: edit, to: temp) { [weak self] ok in
            guard let self else { return }
            self.busy = false
            guard ok else { NSSound.beep(); completion?(false); return }
            let backup = VideoExporter.originalURL(for: self.fileURL)
            if !FileManager.default.fileExists(atPath: backup.path) { try? FileManager.default.copyItem(at: self.fileURL, to: backup) }
            self.player.replaceCurrentItem(with: nil)
            do {
                _ = try FileManager.default.replaceItemAt(self.fileURL, withItemAt: temp)
                log("動画を編集 \(self.fileURL.lastPathComponent) \(String(format: "%.2f", self.edit.start))〜\(String(format: "%.2f", self.edit.end))秒 残す長さ=\(String(format: "%.2f", self.edit.keptLength)) 音なし=\(self.edit.mute) 高さの上限=\(self.edit.maxHeight) 切り抜き=\(self.edit.crop != nil) ズーム=\(self.edit.zooms.count)")
                self.window.close()
                self.onFinish?()
                completion?(true)
            } catch {
                log("動画の置き換え失敗 \(error)")
                NSSound.beep()
                completion?(false)
            }
        }
    }

    /// 編集した動画を、保存先フォルダへ別のファイルとして書き出す。
    @objc func saveAsTapped() { saveAs(completion: nil) }

    func saveAs(completion: ((URL?) -> Void)?) {
        guard !busy else { return }
        busy = true
        let out = Prefs.saveDir.appendingPathComponent("録画 \(timestampName()) 編集.mp4")
        VideoExporter.export(fileURL, edit: edit, to: out) { [weak self] ok in
            self?.busy = false
            if ok {
                let bytes = Double((try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0)
                if !Self.headless { ToastHUD.show("保存しました（\(self?.sizeText(bytes) ?? "")）", detail: out.lastPathComponent) }
            } else {
                NSSound.beep()
            }
            completion?(ok ? out : nil)
        }
    }

    /// 残す範囲を GIF にして、履歴と小窓に出す。
    @objc func gifTapped() { makeGIFFile(completion: nil) }

    func makeGIFFile(completion: ((URL?) -> Void)?) {
        guard !busy else { return }
        busy = true
        let temp = tempURL()
        var gifEdit = edit
        gifEdit.mute = true
        VideoExporter.export(fileURL, edit: gifEdit, to: temp) { [weak self] ok in
            guard ok else { self?.busy = false; NSSound.beep(); completion?(nil); return }
            makeGIF(from: temp) { gif in
                self?.busy = false
                try? FileManager.default.removeItem(at: temp)
                guard let gif else { NSSound.beep(); completion?(nil); return }
                let out = Prefs.historyDir.appendingPathComponent("rec \(timestampName()).gif")
                try? FileManager.default.moveItem(at: gif, to: out)
                HistoryStore.record(file: out, source: nil)
                if !Self.headless { PopupController.shared.show(file: out, on: screenUnderMouse()) }
                completion?(out)
            }
        }
    }

    /// 再生位置のコマを、スクショとして履歴と小窓に出す。
    @objc func frameTapped() { _ = grabFrame() }

    @discardableResult
    func grabFrame() -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: fileURL))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        guard let image = try? generator.copyCGImage(at: CMTime(seconds: timeline.playhead, preferredTimescale: 600), actualTime: nil) else {
            NSSound.beep()
            return nil
        }
        if !Self.headless { CaptureController.shared.saveCaptured(image, scale: 2, source: nil, kind: "frame") }
        return image
    }

    /// 前に「完了」で上書きする前の録画に戻す。
    @objc func revertTapped() {
        let backup = VideoExporter.originalURL(for: fileURL)
        guard FileManager.default.fileExists(atPath: backup.path) else { return }
        player.replaceCurrentItem(with: nil)
        do {
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: backup)
            log("動画を元に戻した \(fileURL.lastPathComponent)")
            load()
            onFinish?()
        } catch {
            log("動画を元に戻せない \(error)")
            NSSound.beep()
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard hasChanges, !busy, !Self.headless else { return !busy }
        let alert = NSAlert()
        alert.messageText = "編集を捨てて閉じますか"
        alert.informativeText = "「完了」を押すまで、編集は録画に反映されません。"
        alert.addButton(withTitle: "編集に戻る")
        alert.addButton(withTitle: "捨てて閉じる")
        return alert.runModal() == .alertSecondButtonReturn
    }

    func windowWillClose(_ notification: Notification) {
        measureWork?.cancel()
        if let observer { player?.removeTimeObserver(observer) }
        observer = nil
        player?.pause()
        Self.openEditors.removeAll { $0 === self }
    }
}
