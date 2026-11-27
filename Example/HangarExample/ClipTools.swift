import AVFoundation
import CoreImage
import Hangar
import HangarCore
import UIKit

/// The example's tools for a clip, made on the device as its picture tools are, so each can be tried end to end: an
/// app gives its video models instead (a change in words given `request.marked` and `request.boxes`, a clip continued
/// from its last frame, one upscaled). Reverse is real: Hangar's own (`HangarClipRenderer.reversed`).
extension HangarTool {
    /// A clip changed in words: the colour named laid over the painted part's box, or over all of it, every frame.
    static let localClipEdit = HangarTool.clipEdit(words: HangarWords(placeholder: "Describe the change", suggestions: [
        HangarSuggestion(title: "Make It Red", symbol: "paintpalette", words: "make it red"),
        HangarSuggestion(title: "Golden Hour", symbol: "sun.horizon", words: "golden hour light"),
    ]), price: "20 credits") { request in
        let colour = CIColor(cgColor: request.words.flatMap(named) ?? CGColor(srgbRed: 0.85, green: 0.2, blue: 0.75, alpha: 1))
        let box = request.boxes.first
        return [try await ClipWork.export(request.clip) { frame, _ in
            let e = frame.extent
            // Core Image's y goes up.
            let part = box.map { CGRect(x: e.minX + $0.minX * e.width, y: e.minY + (1 - $0.maxY) * e.height, width: $0.width * e.width, height: $0.height * e.height) } ?? e
            let tint = CIImage(color: colour.withAlpha(box == nil ? 0.45 : 0.85)).cropped(to: part)
            return tint.applyingFilter("CIColorBlendMode", parameters: [kCIInputBackgroundImageKey: frame]).cropped(to: e)
        }]
    }

    /// A clip continued: its last frame held two seconds more, the camera pushing in on it.
    static let localClipContinue = HangarTool.clipContinue(price: "30 credits") { request in
        [try await ClipWork.export(request.clip, holding: 2) { frame, past in
            guard past > 0 else { return frame }
            let e = frame.extent, zoom = 1 + 0.12 * past / 2
            return frame.transformed(by: CGAffineTransform(translationX: -e.midX, y: -e.midY).scaledBy(x: zoom, y: zoom)
                .concatenating(CGAffineTransform(translationX: e.midX, y: e.midY))).cropped(to: e)
        }]
    }

    static let localClip: [HangarTool] = [.localClipEdit, .localClipContinue]
}

extension HangarAction {
    /// Reverse, in More: the clip played backwards, on the device.
    static let reverse = HangarAction(title: "Reverse", symbol: "backward", clipJob: HangarClipJob(tool: "reverse", name: "Reversing", timing: .reversed) { request in
        let out = ClipWork.temporary()
        try await HangarClipRenderer.reversed(request.clip, to: out)
        return [out]
    })

    /// Upscale for a clip, in More: twice as large by Lanczos, as a model would make it with more detail.
    static let upscaleClip = HangarAction(title: "Upscale", symbol: "arrow.up.left.and.arrow.down.right.square", price: "40 credits",
                                          clipJob: HangarClipJob(tool: "upscale", name: "Upscaling") { request in
        [try await ClipWork.export(request.clip, scale: 2) { frame, _ in
            frame.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: 2, kCIInputAspectRatioKey: 1])
        }]
    })
}

private extension CIColor {
    func withAlpha(_ alpha: CGFloat) -> CIColor {
        CIColor(red: red, green: green, blue: blue, alpha: alpha)
    }
}

/// A clip written again with each frame changed (`frame`, given the frame and how far past the clip's end it is),
/// `scale` times its size, `holding` its last frame that many seconds more.
enum ClipWork {
    static func temporary() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
    }

    static func export(_ clip: URL, scale: CGFloat = 1, holding: Double = 0,
                       frame change: @escaping @Sendable (CIImage, Double) -> CIImage) async throws -> URL {
        let asset = AVURLAsset(url: clip)
        let composition = AVMutableComposition()
        let duration = try await asset.load(.duration)
        guard let video = try await asset.loadTracks(withMediaType: .video).first,
              let out = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let range = try await video.load(.timeRange)
        try out.insertTimeRange(range, of: video, at: .zero)
        out.preferredTransform = try await video.load(.preferredTransform)
        if let sound = try await asset.loadTracks(withMediaType: .audio).first,
           let soundOut = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try soundOut.insertTimeRange(try await sound.load(.timeRange), of: sound, at: .zero)
        }
        if holding > 0 {
            // The last frame, stretched.
            let last = CMTimeRange(start: range.end - CMTime(value: 1, timescale: 30), duration: CMTime(value: 1, timescale: 30))
            try out.insertTimeRange(last, of: video, at: range.end)
            out.scaleTimeRange(CMTimeRange(start: range.end, duration: last.duration), toDuration: CMTime(seconds: holding, preferredTimescale: 600))
        }
        let end = duration.seconds
        let videoComposition = try await AVMutableVideoComposition.videoComposition(with: composition) { request in
            request.finish(with: change(request.sourceImage, max(0, request.compositionTime.seconds - end)), context: nil)
        }
        videoComposition.renderSize = CGSize(width: (videoComposition.renderSize.width * scale / 2).rounded() * 2,
                                             height: (videoComposition.renderSize.height * scale / 2).rounded() * 2)
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw CocoaError(.featureUnsupported)
        }
        session.videoComposition = videoComposition
        let url = temporary()
        if #available(iOS 18.0, *) {
            try await session.export(to: url, as: .mov)
        } else {
            session.outputURL = url
            session.outputFileType = .mov
            await session.export()
            if let error = session.error { throw error }
        }
        return url
    }
}
