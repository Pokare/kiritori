// 音つきの画面録画（macOS 15 以上）。
// ScreenCaptureKit で画面・パソコンの音・マイクを取り、mp4 に直接書き出す。
// 14 以前では Recorder.swift の screencapture 方式（パソコンの音なし）に落ちる。

import AppKit
import AVFoundation
import ScreenCaptureKit

@available(macOS 15.0, *)
final class StreamRecorder: NSObject, SCStreamDelegate, SCRecordingOutputDelegate {
    private var stream: SCStream?
    private var finished = false
    let url: URL
    /// 録画が終わった（ファイルが閉じられた）ら main で呼ばれる
    var onFinished: ((Error?) -> Void)?

    init(url: URL) {
        self.url = url
    }

    /// rect は AppKit の座標（左下が原点・全画面を通した座標）。nil ならその画面全体。
    /// microphoneID: nil＝マイクなし／MicrophoneChoice.system＝macOS で選んである入力／それ以外＝そのマイク
    /// includeWindowIDs: 自分の窓のうち、例外で写すもの（クリックの輪）
    func start(rect: NSRect?, screen: NSScreen, systemAudio: Bool, microphoneID: String?, showsCursor: Bool,
               includeWindowIDs: [CGWindowID], scale1x: Bool = false, completion: @escaping (Error?) -> Void) {
        Task {
            do {
                var content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                // 出したばかりの窓（クリックの輪など）がまだ一覧に載っていないことがあるので、少し待って取り直す
                for _ in 0..<3 where content.windows.filter({ includeWindowIDs.contains($0.windowID) }).count != includeWindowIDs.count {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                }
                let screenID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
                guard let display = content.displays.first(where: { $0.displayID == screenID }) ?? content.displays.first else {
                    throw NSError(domain: "Kiritori", code: 1, userInfo: [NSLocalizedDescriptionKey: "録画する画面が見つからない"])
                }
                // 自分の窓（赤い枠・小窓）は写さない
                let mine = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
                let extra = content.windows.filter { includeWindowIDs.contains($0.windowID) }
                if extra.count != includeWindowIDs.count { log("クリックの輪の窓が見つからない（輪は録画に写らない）") }
                let filter = SCContentFilter(display: display, excludingApplications: mine, exceptingWindows: extra)

                let config = SCStreamConfiguration()
                let scale = scale1x ? 1 : screen.backingScaleFactor
                var pointSize = screen.frame.size
                if let rect {
                    // sourceRect は、その画面の左上を原点にした座標
                    config.sourceRect = CGRect(x: rect.minX - screen.frame.minX, y: screen.frame.maxY - rect.maxY,
                                               width: rect.width, height: rect.height)
                    pointSize = rect.size
                }
                // H.264 で扱える大きさに収める（横 3840 まで）。縦横とも偶数にそろえる
                var w = pointSize.width * scale, h = pointSize.height * scale
                if w > 3840 { h = h * 3840 / w; w = 3840 }
                if h > 3840 { w = w * 3840 / h; h = 3840 }
                config.width = max(2, Int(w / 2) * 2)
                config.height = max(2, Int(h / 2) * 2)
                config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(Prefs.recordFPS))
                config.showsCursor = showsCursor
                config.queueDepth = 6
                config.capturesAudio = systemAudio
                config.excludesCurrentProcessAudio = true
                config.sampleRate = 48000
                config.channelCount = 2
                config.captureMicrophone = microphoneID != nil
                if let microphoneID, microphoneID != MicrophoneChoice.system {
                    config.microphoneCaptureDeviceID = microphoneID
                }

                let stream = SCStream(filter: filter, configuration: config, delegate: self)
                let recording = SCRecordingOutputConfiguration()
                recording.outputURL = url
                recording.outputFileType = .mp4
                recording.videoCodecType = .h264
                try stream.addRecordingOutput(SCRecordingOutput(configuration: recording, delegate: self))
                try await stream.startCapture()
                self.stream = stream
                await MainActor.run { completion(nil) }
            } catch {
                await MainActor.run { completion(error) }
            }
        }
    }

    func stop() {
        guard let stream else { finish(nil); return }
        Task {
            do { try await stream.stopCapture() } catch { self.finish(error) }
            // ファイルを閉じ終えた知らせ（下の recordingOutputDidFinishRecording）が来なかったときの保険
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            self.finish(nil)
        }
    }

    private func finish(_ error: Error?) {
        DispatchQueue.main.async {
            guard !self.finished else { return }
            self.finished = true
            self.stream = nil
            self.onFinished?(error)
        }
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) { finish(nil) }
    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) { finish(error) }
    func stream(_ stream: SCStream, didStopWithError error: Error) { finish(error) }
}

/// 音のトラックが2本以上ある動画（パソコンの音＋マイク）を、1本に混ぜた動画に書き直す。
/// 映像は作り直さずそのまま写す。貼り付け先によっては1本目の音しか鳴らないため。
func mixAudioTracksIfNeeded(_ url: URL, completion: @escaping (URL) -> Void) {
    let asset = AVURLAsset(url: url)
    let audioTracks = asset.tracks(withMediaType: .audio)
    guard audioTracks.count >= 2, let videoTrack = asset.tracks(withMediaType: .video).first else {
        completion(url)
        return
    }
    let tmp = url.deletingLastPathComponent().appendingPathComponent(".mix-\(UUID().uuidString).mp4")
    func fail(_ why: String) {
        log("音を1本に混ぜられなかった（そのまま残す） \(why)")
        try? FileManager.default.removeItem(at: tmp)
        DispatchQueue.main.async { completion(url) }
    }
    guard let reader = try? AVAssetReader(asset: asset),
          let writer = try? AVAssetWriter(outputURL: tmp, fileType: .mp4) else { fail("読み書きの用意に失敗"); return }

    let videoOut = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)   // 圧縮されたまま取り出す
    let audioOut = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2,
        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ])
    guard reader.canAdd(videoOut), reader.canAdd(audioOut) else { fail("読み出しを組めない"); return }
    reader.add(videoOut)
    reader.add(audioOut)

    let videoHint = videoTrack.formatDescriptions.first.map { $0 as! CMFormatDescription }
    let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: videoHint)
    videoIn.transform = videoTrack.preferredTransform
    let audioIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 160_000,
    ])
    videoIn.expectsMediaDataInRealTime = false
    audioIn.expectsMediaDataInRealTime = false
    guard writer.canAdd(videoIn), writer.canAdd(audioIn) else { fail("書き込みを組めない"); return }
    writer.add(videoIn)
    writer.add(audioIn)
    writer.shouldOptimizeForNetworkUse = true

    guard reader.startReading(), writer.startWriting() else {
        fail("開始できない \(String(describing: reader.error ?? writer.error))")
        return
    }
    writer.startSession(atSourceTime: .zero)

    let group = DispatchGroup()
    for (input, output, label) in [(videoIn, videoOut as AVAssetReaderOutput, "video"), (audioIn, audioOut as AVAssetReaderOutput, "audio")] {
        group.enter()
        input.requestMediaDataWhenReady(on: DispatchQueue(label: "local.kiritori.mix.\(label)")) {
            while input.isReadyForMoreMediaData {
                if let sample = output.copyNextSampleBuffer() {
                    if !input.append(sample) { input.markAsFinished(); group.leave(); return }
                } else {
                    input.markAsFinished()
                    group.leave()
                    return
                }
            }
        }
    }
    group.notify(queue: .main) {
        writer.finishWriting {
            DispatchQueue.main.async {
                guard writer.status == .completed, reader.status == .completed else {
                    fail("書き出しに失敗 \(String(describing: writer.error ?? reader.error))")
                    return
                }
                do {
                    _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
                    log("音を1本に混ぜた \(url.lastPathComponent)（元は \(audioTracks.count) 本）")
                } catch {
                    fail("置き換えに失敗 \(error)")
                    return
                }
                completion(url)
            }
        }
    }
}

/// 動画を順番につないで1本にする（一時停止で区切られた録画用）。映像は作り直さずにつなぎ、だめなら作り直す。
func joinVideos(_ files: [URL], to out: URL, completion: @escaping (Bool) -> Void) {
    let fm = FileManager.default
    try? fm.removeItem(at: out)
    if files.count == 1 {
        completion((try? fm.moveItem(at: files[0], to: out)) != nil)
        return
    }
    let composition = AVMutableComposition()
    guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { completion(false); return }
    var audio: [AVMutableCompositionTrack] = []
    var cursor = CMTime.zero
    for file in files {
        let asset = AVURLAsset(url: file)
        guard let v = asset.tracks(withMediaType: .video).first else { continue }
        let range = v.timeRange
        guard (try? video.insertTimeRange(range, of: v, at: cursor)) != nil else { continue }
        video.preferredTransform = v.preferredTransform
        for (i, a) in asset.tracks(withMediaType: .audio).enumerated() {
            if audio.count <= i, let t = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) { audio.append(t) }
            guard audio.indices.contains(i) else { continue }
            let common = range.intersection(a.timeRange)
            guard common.duration > .zero else { continue }
            try? audio[i].insertTimeRange(common, of: a, at: cursor + (common.start - range.start))
        }
        cursor = cursor + range.duration
    }
    guard cursor > .zero else { completion(false); return }
    func export(_ preset: String, then fallback: (() -> Void)?) {
        guard let session = AVAssetExportSession(asset: composition, presetName: preset) else { fallback?() ?? completion(false); return }
        try? fm.removeItem(at: out)
        session.outputURL = out
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        session.exportAsynchronously {
            DispatchQueue.main.async {
                if session.status == .completed {
                    log("録画をつないだ \(files.count)本 方式=\(preset == AVAssetExportPresetPassthrough ? "そのまま" : "作り直し")")
                    completion(true)
                } else if let fallback {
                    log("そのままではつなげなかったので作り直す \(String(describing: session.error))")
                    fallback()
                } else {
                    log("録画をつなげなかった \(String(describing: session.error))")
                    completion(false)
                }
            }
        }
    }
    export(AVAssetExportPresetPassthrough) { export(AVAssetExportPresetHighestQuality, then: nil) }
}
