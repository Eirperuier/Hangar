import AVFoundation
import CoreImage
import XCTest
@testable import HangarCore

final class ClipTests: XCTestCase {
    // MARK: Values

    func testEditKeptBeforeClipsOpensWithNone() throws {
        let old = #"{"adjustments":{"exposure":0.5},"switchedOff":[],"filterAmount":1,"steps":[{"tool":"x","takes":["a"]}]}"#
        let edit = try JSONDecoder().decode(HangarEdit.self, from: Data(old.utf8))
        XCTAssertEqual(edit.clip, HangarClipEdit())
        XCTAssertFalse(edit.steps[0].clip)
    }

    func testClipEditRoundTrips() throws {
        var edit = HangarEdit()
        edit.clip = HangarClipEdit(trim: HangarTimeRange(1, 3), muted: true, speed: 2,
                                   slowMotion: HangarSlowMotion(range: HangarTimeRange(1.5, 2), rate: 0.25),
                                   soundtrack: HangarSoundtrack(asset: "m.m4a", volume: 0.5, name: "Epic"))
        edit.steps = [HangarStep(tool: "upscale", takes: ["c.mov"], replaces: true, clip: true)]
        let back = try JSONDecoder().decode(HangarEdit.self, from: JSONEncoder().encode(edit))
        XCTAssertEqual(back, edit)
        XCTAssertFalse(back.isOriginal)
    }

    func testOnlyAClipsOwnValuesChangeIt() {
        var edit = HangarEdit()
        XCTAssertTrue(edit.isOriginal)
        edit.clip.muted = true
        XCTAssertFalse(edit.isOriginal)
        edit.clip.muted = false
        edit.clip.trim = HangarTimeRange(0, 1)
        XCTAssertFalse(edit.isOriginal)
    }

    // MARK: Timing

    private let plain = HangarClipInfo(duration: 12, frameRate: 30, size: CGSize(width: 1920, height: 1080), hasSound: true)
    private let slow = HangarClipInfo(duration: 6, frameRate: 240, size: CGSize(width: 1920, height: 1080), hasSound: false)

    func testTrimAndSpeed() {
        let timing = HangarClipTiming(HangarClipEdit(trim: HangarTimeRange(2, 8), speed: 2), info: plain)
        XCTAssertEqual(timing.duration, 3, accuracy: 1e-9)
        XCTAssertEqual(timing.played(at: 5), 1.5, accuracy: 1e-9)
        XCTAssertEqual(timing.time(at: 1.5), 5, accuracy: 1e-9)
        // Held within what's played.
        XCTAssertEqual(timing.played(at: 0), 0, accuracy: 1e-9)
        XCTAssertEqual(timing.time(at: 99), 8, accuracy: 1e-9)
        let whole = HangarClipTiming(HangarClipEdit(trim: HangarTimeRange(2, 8)), info: plain, trimmed: false)
        XCTAssertEqual(whole.duration, 12, accuracy: 1e-9)
    }

    func testSlowMotionPlaysItsMiddleAtThirtyFrames() {
        // Its first slow part: 1 to 5 seconds, at 30 of 240 frames a second (1/8).
        let timing = HangarClipTiming(HangarClipEdit(), info: slow)
        XCTAssertEqual(timing.parts.map(\.rate), [1, 0.125, 1])
        XCTAssertEqual(timing.duration, 1 + 4 * 8 + 1, accuracy: 1e-9)
        XCTAssertEqual(timing.played(at: 3), 1 + 2 * 8, accuracy: 1e-9)
        XCTAssertEqual(timing.time(at: 17), 3, accuracy: 1e-9)
        // An empty slow part plays it as shot; a clip that isn't slow motion ignores one.
        XCTAssertEqual(HangarClipTiming(HangarClipEdit(slowMotion: HangarSlowMotion(range: HangarTimeRange(2, 2), rate: 0.125)), info: slow).duration, 6, accuracy: 1e-9)
        XCTAssertEqual(HangarClipTiming(HangarClipEdit(slowMotion: HangarSlowMotion(range: HangarTimeRange(2, 4), rate: 0.5)), info: plain).duration, 12, accuracy: 1e-9)
        // Trimmed into it.
        let trimmed = HangarClipTiming(HangarClipEdit(trim: HangarTimeRange(3, 5.5)), info: slow)
        XCTAssertEqual(trimmed.duration, 2 * 8 + 0.5, accuracy: 1e-9)
    }

    func testAClipStepsTiming() {
        var edit = HangarEdit()
        edit.clip.trim = HangarTimeRange(1, 3)
        edit.clip.slowMotion = HangarSlowMotion(range: HangarTimeRange(1.5, 2), rate: 0.25)
        var kept = edit
        kept.add(HangarStep(tool: "upscale", takes: ["a"], replaces: true, clip: true), timing: .kept)
        XCTAssertEqual(kept.clip.trim, HangarTimeRange(1, 3))
        var reversed = edit
        reversed.add(HangarStep(tool: "reverse", takes: ["a"], replaces: true, clip: true), timing: .reversed(duration: 10))
        XCTAssertEqual(reversed.clip.trim, HangarTimeRange(7, 9))
        XCTAssertEqual(reversed.clip.slowMotion?.range, HangarTimeRange(8, 8.5))
        var longer = edit
        longer.add(HangarStep(tool: "continue", takes: ["a"], replaces: true, clip: true), timing: .new)
        XCTAssertNil(longer.clip.trim)
        XCTAssertNil(longer.clip.slowMotion)
        XCTAssertEqual(longer.steps.count, 1)
    }

    func testTransformsTurnFramesUpright() {
        // An iPhone held upright stores its frames on their side, turned a quarter right to show.
        XCTAssertEqual(CGImagePropertyOrientation(CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)), .right)
        XCTAssertEqual(CGImagePropertyOrientation(CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 1920)), .left)
        XCTAssertEqual(CGImagePropertyOrientation(CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 1920, ty: 1080)), .down)
        XCTAssertEqual(CGImagePropertyOrientation(.identity), .up)
    }

    // MARK: Files

    func testInfoReadsTheTransform() async throws {
        let url = try await Self.clip(frames: 30, size: CGSize(width: 64, height: 32), turned: true)
        let info = try await HangarClipInfo.load(url)
        XCTAssertEqual(info.size, CGSize(width: 32, height: 64))
        XCTAssertEqual(info.orientation, .right)
        XCTAssertEqual(info.duration, 1, accuracy: 0.01)
        XCTAssertEqual(info.frameRate, 30, accuracy: 0.5)
        XCTAssertTrue(info.hasSound)
    }

    func testExportKeepsTheTrimAtItsSpeed() async throws {
        let url = try await Self.clip(frames: 60, size: CGSize(width: 64, height: 48))
        var edit = HangarEdit()
        edit.clip = HangarClipEdit(trim: HangarTimeRange(0.5, 1.5), speed: 2)
        let out = Self.temporary("mov")
        try await HangarClipRenderer().export(edit, source: url, to: out)
        let info = try await HangarClipInfo.load(out)
        XCTAssertEqual(info.duration, 0.5, accuracy: 0.05)
        XCTAssertTrue(info.hasSound)
        // Its first frame is the clip's at 0.5 s (frame 15 of 60): its colour says which.
        let first = try await HangarClipRenderer.frame(of: out, at: 0)
        XCTAssertEqual(Self.frameNumber(first, of: 60), 15, accuracy: 2)
    }

    func testMutedExportHasNoSound() async throws {
        let url = try await Self.clip(frames: 30, size: CGSize(width: 64, height: 48))
        var edit = HangarEdit()
        edit.clip.muted = true
        let out = Self.temporary("mov")
        try await HangarClipRenderer().export(edit, source: url, to: out)
        let info = try await HangarClipInfo.load(out)
        XCTAssertFalse(info.hasSound)
    }

    func testExportShapesATurnedClip() async throws {
        // Stored 64×32 on its side: upright 32×64. Cropped to its top quarter (32×16), then turned a quarter: 16×32.
        let url = try await Self.clip(frames: 30, size: CGSize(width: 64, height: 32), turned: true)
        var edit = HangarEdit()
        edit.geometry.crop = CGRect(x: 0, y: 0, width: 1, height: 0.25)
        edit.geometry.turns = 1
        let out = Self.temporary("mov")
        try await HangarClipRenderer().export(edit, source: url, to: out)
        let info = try await HangarClipInfo.load(out)
        XCTAssertEqual(info.size, CGSize(width: 16, height: 32), "\(info)")
    }

    func testExportPlaysTheSlowPartSlowly() async throws {
        // 1 s at 120 frames a second: 1/6 to 5/6 played at 30 frames a second (a quarter speed).
        let url = try await Self.clip(frames: 120, fps: 120, size: CGSize(width: 64, height: 48), sound: false)
        let out = Self.temporary("mov")
        try await HangarClipRenderer().export(HangarEdit(), source: url, to: out)
        let info = try await HangarClipInfo.load(out)
        XCTAssertEqual(info.duration, 1.0 / 6 + 4.0 / 6 * 4 + 1.0 / 6, accuracy: 0.05)
    }

    func testReversedPlaysBackwards() async throws {
        let url = try await Self.clip(frames: 30, size: CGSize(width: 64, height: 48), turned: true)
        let out = Self.temporary("mov")
        try await HangarClipRenderer.reversed(url, to: out)
        let info = try await HangarClipInfo.load(out)
        XCTAssertEqual(info.duration, 1, accuracy: 0.05)
        XCTAssertEqual(info.size, CGSize(width: 48, height: 64))
        XCTAssertFalse(info.hasSound)
        let first = try await HangarClipRenderer.frame(of: out, at: 0)
        let last = try await HangarClipRenderer.frame(of: out, at: 0.97)
        XCTAssertEqual(Self.frameNumber(first, of: 30, turned: true), 29, accuracy: 2)
        XCTAssertEqual(Self.frameNumber(last, of: 30, turned: true), 0, accuracy: 2)
    }

    // MARK: Making clips

    static func temporary(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
    }

    /// A clip whose frame n is grey (n / frames) at its top left and white elsewhere; with a second of silence's sound,
    /// stored turned a quarter (as an iPhone held upright stores it) if `turned`.
    static func clip(frames: Int, fps: Int = 30, size: CGSize, turned: Bool = false, sound: Bool = true) async throws -> URL {
        let url = temporary("mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
        ])
        if turned { video.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: size.height, ty: 0) }
        video.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height),
        ])
        writer.add(video)
        var audio: AVAssetWriterInput?
        if sound {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1,
            ])
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audio = input
        }
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        // The sound first: a writer interleaves its inputs, and would wait for sound behind all the frames.
        if let audio {
            let rate = 44100.0, count = Int(rate * Double(frames) / Double(fps))
            var format: CMAudioFormatDescription?
            var description = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
                                                          mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
                                                          mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1,
                                                          mBitsPerChannel: 16, mReserved: 0)
            CMAudioFormatDescriptionCreate(allocator: nil, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                           magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
            var block: CMBlockBuffer?
            CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: count * 2, blockAllocator: nil,
                                               customBlockSource: nil, offsetToData: 0, dataLength: count * 2, flags: 0, blockBufferOut: &block)
            CMBlockBufferFillDataBytes(with: 0, blockBuffer: block!, offsetIntoDestination: 0, dataLength: count * 2)
            var sample: CMSampleBuffer?
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block!, formatDescription: format!,
                                                                 sampleCount: count, presentationTimeStamp: .zero,
                                                                 packetDescriptions: nil, sampleBufferOut: &sample)
            try await Self.ready(audio)
            audio.append(sample!)
            audio.markAsFinished()
        }
        for n in 0..<frames {
            try await Self.ready(video)
            var made: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &made)
            let pixels = made!
            CVPixelBufferLockBaseAddress(pixels, [])
            let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(pixels)
            let grey = UInt8(Double(n) / Double(frames) * 255)
            for y in 0..<Int(size.height) {
                for x in 0..<Int(size.width) {
                    let corner = x < Int(size.width) / 2 && y < Int(size.height) / 2
                    let v: UInt8 = corner ? grey : 255
                    let p = base + y * stride + x * 4
                    p[0] = v; p[1] = v; p[2] = v; p[3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            XCTAssertTrue(adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(n), timescale: CMTimeScale(fps))))
        }
        video.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, "\(String(describing: writer.error))")
        return url
    }

    /// Waits for a writer's input to take more, failing rather than hanging.
    static func ready(_ input: AVAssetWriterInput) async throws {
        let until = Date().addingTimeInterval(10)
        while !input.isReadyForMoreMediaData {
            guard Date() < until else { throw CocoaError(.fileWriteUnknown) }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    /// Which frame a picture of `clip`'s is, from the grey of the corner it was drawn in: its top left as stored, the
    /// top right upright once it's turned a quarter right.
    static func frameNumber(_ picture: CGImage, of frames: Int, turned: Bool = false) -> Double {
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // A point well inside the corner's quarter, a tenth of the way in each way.
        let w = CGFloat(picture.width), h = CGFloat(picture.height)
        context.draw(picture, in: CGRect(x: -w * (turned ? 0.9 : 0.1), y: -h * 0.9 + 1, width: w, height: h))
        let grey = Double(context.data!.assumingMemoryBound(to: UInt8.self)[0])
        return grey / 255 * Double(frames)
    }
}
