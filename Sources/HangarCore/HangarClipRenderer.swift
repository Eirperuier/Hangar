import AVFoundation
import CoreImage
import Foundation

/// Draws a clip from an edit: its timing and sound as AVFoundation's composition (the parts kept, each scaled to its
/// rate, its own sound muted or not, music under it), each frame through the renderer (`HangarRenderer`: shaped by
/// the geometry, adjusted, filtered, what's drawn over it). For the editor's player, and for the clip kept. Any
/// thread.
public struct HangarClipRenderer: Sendable {
    public var renderer: HangarRenderer

    public init(renderer: HangarRenderer = HangarRenderer()) {
        self.renderer = renderer
    }

    /// A clip's timing and sound as a composition to play or export: its kept part (all of it unless `trimmed`), at
    /// its speed and slow where it's slow motion; its sound unless it's muted, and its music under it.
    public struct Playable: @unchecked Sendable {
        public let composition: AVComposition
        public let audioMix: AVAudioMix?
        public let info: HangarClipInfo
        public let timing: HangarClipTiming
    }

    /// The clip `source` (as the edit's steps make it: `edit.clipSource`) with the edit's timing and sound.
    public func playable(_ edit: HangarEdit, source: URL, trimmed: Bool = true) async throws -> Playable {
        let asset = AVURLAsset(url: edit.clipSource(source, assets: renderer.assets))
        let info = try await HangarClipInfo.load(asset)
        let timing = HangarClipTiming(edit.clip, info: info, trimmed: trimmed)
        let composition = AVMutableComposition()
        guard let videoIn = try await asset.loadTracks(withMediaType: .video).first,
              let videoOut = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw CocoaError(.fileReadCorruptFile) }
        videoOut.preferredTransform = try await videoIn.load(.preferredTransform)
        let videoRange = try await videoIn.load(.timeRange)
        var sound: (track: AVAssetTrack, range: CMTimeRange, out: AVMutableCompositionTrack)?
        if !edit.clip.muted, let audioIn = try await asset.loadTracks(withMediaType: .audio).first,
           let out = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            sound = (audioIn, try await audioIn.load(.timeRange), out)
        }
        var at = CMTime.zero
        for part in timing.parts {
            let range = part.range.cmRange.intersection(videoRange)
            guard range.duration > .zero else { continue }
            try videoOut.insertTimeRange(range, of: videoIn, at: at)
            if let sound {
                let heard = range.intersection(sound.range)
                if heard.duration > .zero { try sound.out.insertTimeRange(heard, of: sound.track, at: at + (heard.start - range.start)) }
            }
            let played = CMTime(seconds: range.duration.seconds / part.rate, preferredTimescale: 6000)
            if part.rate != 1 {
                videoOut.scaleTimeRange(CMTimeRange(start: at, duration: range.duration), toDuration: played)
                sound?.out.scaleTimeRange(CMTimeRange(start: at, duration: range.duration), toDuration: played)
            }
            at = at + played
        }
        var mix: AVMutableAudioMix?
        if let soundtrack = edit.clip.soundtrack, let file = renderer.assets?.file(soundtrack.asset) {
            let music = AVURLAsset(url: file)
            if let musicIn = try await music.loadTracks(withMediaType: .audio).first,
               let out = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                let length = try await musicIn.load(.timeRange)
                // From its start, again and again until the clip ends.
                var from = CMTime.zero
                while from < at, length.duration > CMTime(value: 1, timescale: 100) {
                    let take = CMTimeMinimum(length.duration, at - from)
                    try out.insertTimeRange(CMTimeRange(start: length.start, duration: take), of: musicIn, at: from)
                    from = from + take
                }
                let parameters = AVMutableAudioMixInputParameters(track: out)
                parameters.setVolume(Float(min(max(soundtrack.volume, 0), 1)), at: .zero)
                parameters.audioTimePitchAlgorithm = .spectral
                mix = AVMutableAudioMix()
                mix?.inputParameters = [parameters]
            }
        }
        return Playable(composition: composition, audioMix: mix, info: info, timing: timing)
    }

    /// Each frame of `playable` drawn with the edit: shaped, adjusted, filtered, what's drawn over it; Auto as it
    /// reads `reading` (a frame of the clip: every frame is done alike).
    public func videoComposition(_ edit: HangarEdit, _ playable: Playable, reading: CIImage) async throws -> AVVideoComposition {
        let renderer = renderer
        let size = playable.info.size
        let shapedSize = Self.shapedSize(edit, renderer: renderer, size: size)
        let marks = renderer.marks(edit, size: size)
        let context = HangarRenderContext(source: reading)
        let composition = try await AVMutableVideoComposition.videoComposition(with: playable.composition) { request in
            let frame = request.sourceImage
            let base = frame.transformed(by: CGAffineTransform(translationX: -frame.extent.minX, y: -frame.extent.minY))
            let shaped = renderer.shape(edit, base)
            var out = renderer.apply(edit, to: shaped, context: context.resized(to: shaped, scale: 1))
            if let marks { out = marks.composited(over: out).cropped(to: shaped.extent) }
            request.finish(with: out, context: nil)
        }
        composition.renderSize = shapedSize
        let rate = min(max(playable.info.frameRate.rounded(), 24), 60)
        composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(rate))
        return composition
    }

    /// The size of a frame `size` large once the edit's geometry shapes it, in whole even pixels (as encoders take).
    static func shapedSize(_ edit: HangarEdit, renderer: HangarRenderer, size: CGSize) -> CGSize {
        let shaped = renderer.shape(edit, CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: size))).extent.size
        func even(_ v: CGFloat) -> CGFloat { max(2, (v / 2).rounded() * 2) }
        return CGSize(width: even(shaped.width), height: even(shaped.height))
    }

    /// The clip `source` with the edit, written to `url` (a QuickTime movie). Takes a while: off the main thread.
    public func export(_ edit: HangarEdit, source: URL, to url: URL) async throws {
        let playable = try await playable(edit, source: source)
        let reading = try await Self.frame(of: edit.clipSource(source, assets: renderer.assets), at: playable.timing.range.start)
        let video = try await videoComposition(edit, playable, reading: CIImage(cgImage: reading))
        guard let session = AVAssetExportSession(asset: playable.composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw CocoaError(.featureUnsupported)
        }
        session.videoComposition = video
        session.audioMix = playable.audioMix
        session.audioTimePitchAlgorithm = .spectral
        try? FileManager.default.removeItem(at: url)
        if #available(iOS 18.0, macCatalyst 18.0, *) {
            try await session.export(to: url, as: .mov)
        } else {
            session.outputURL = url
            session.outputFileType = .mov
            await session.export()
            if let error = session.error { throw error }
        }
    }

    /// A frame of a clip, upright, at `time` (its own seconds), no larger than `longest` on its longer side.
    public static func frame(of url: URL, at time: Double, longest: CGFloat? = nil) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        if let longest { generator.maximumSize = CGSize(width: longest, height: longest) }
        return try await generator.image(at: CMTime(seconds: time, preferredTimescale: 6000)).image
    }

    /// The clip `source` played backwards, written to `url` (a QuickTime movie), without its sound. Read a few frames
    /// at a time from its end, so a long clip never sits in memory.
    public static func reversed(_ source: URL, to url: URL) async throws {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw CocoaError(.fileReadCorruptFile) }
        let (size, transform, range) = try await track.load(.naturalSize, .preferredTransform, .timeRange)
        // Every frame's time and length, from the samples as stored (nothing decoded).
        var frames: [(time: CMTime, length: CMTime)] = []
        let times = try AVAssetReader(asset: asset)
        let stored = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        times.add(stored)
        times.startReading()
        while let sample = stored.copyNextSampleBuffer() {
            guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
            frames.append((sample.presentationTimeStamp, sample.duration))
        }
        guard times.status == .completed, !frames.isEmpty else { throw times.error ?? CocoaError(.fileReadCorruptFile) }
        frames.sort { $0.time < $1.time }
        let end = range.end

        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
        ])
        input.transform = transform
        input.expectsMediaDataInRealTime = false
        let format = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: format, kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)

        let piece = 12
        var last = frames.count
        while last > 0 {
            try Task.checkCancellation()
            let first = max(0, last - piece)
            let reader = try AVAssetReader(asset: asset)
            reader.timeRange = CMTimeRange(start: frames[first].time, end: frames[last - 1].time + frames[last - 1].length)
            let decoded = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: format])
            reader.add(decoded)
            reader.startReading()
            var got: [CMTime: CVPixelBuffer] = [:]
            let wanted = Set(frames[first..<last].map(\.time))
            while let sample = decoded.copyNextSampleBuffer() {
                guard let pixels = sample.imageBuffer, wanted.contains(sample.presentationTimeStamp) else { continue }
                // Copied out of the reader's own buffers, so it never runs out of them while they're held.
                got[sample.presentationTimeStamp] = try copy(pixels, from: adaptor)
            }
            for frame in frames[first..<last].reversed() {
                guard let pixels = got[frame.time] else { continue }
                while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
                let at = end - frame.time - frame.length
                guard adaptor.append(pixels, withPresentationTime: CMTimeMaximum(at, .zero)) else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
            }
            last = first
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    private static func copy(_ pixels: CVPixelBuffer, from adaptor: AVAssetWriterInputPixelBufferAdaptor) throws -> CVPixelBuffer {
        var made: CVPixelBuffer?
        guard let pool = adaptor.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made) == kCVReturnSuccess, let out = made else {
            throw CocoaError(.fileWriteUnknown)
        }
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        CVPixelBufferLockBaseAddress(out, [])
        defer {
            CVPixelBufferUnlockBaseAddress(out, [])
            CVPixelBufferUnlockBaseAddress(pixels, .readOnly)
        }
        for plane in 0..<min(CVPixelBufferGetPlaneCount(pixels), CVPixelBufferGetPlaneCount(out)) {
            guard let from = CVPixelBufferGetBaseAddressOfPlane(pixels, plane), let to = CVPixelBufferGetBaseAddressOfPlane(out, plane) else { continue }
            let rows = min(CVPixelBufferGetHeightOfPlane(pixels, plane), CVPixelBufferGetHeightOfPlane(out, plane))
            let fromStride = CVPixelBufferGetBytesPerRowOfPlane(pixels, plane), toStride = CVPixelBufferGetBytesPerRowOfPlane(out, plane)
            let width = min(fromStride, toStride)
            for row in 0..<rows {
                memcpy(to + row * toStride, from + row * fromStride, width)
            }
        }
        return out
    }
}
