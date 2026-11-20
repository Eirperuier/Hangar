#if DEBUG
import Foundation
import QuartzCore
import UIKit

/// For measuring on a device without touching it (debug builds only): with `HANGAR_SCRUB=<tool>` in the app's
/// environment, the editor sweeps that tool's ruler back and forth for four seconds once it's in, as a finger would,
/// and writes how the frames went to Documents/scrub-<tool>.json and the console. `HANGAR_SCRUB_ALL=1` first sets every
/// adjustment to a third of the way, the heaviest picture to draw.
@MainActor
final class Scrub: NSObject {
    static var asked: String? { ProcessInfo.processInfo.environment["HANGAR_SCRUB"] }
    static var all: Bool { ProcessInfo.processInfo.environment["HANGAR_SCRUB_ALL"] != nil }

    private let ruler: Ruler
    private let canvas: CanvasView
    private let name: String
    private var link: CADisplayLink?
    private var start: CFTimeInterval = 0
    private var last: CFTimeInterval = 0
    private var intervals: [Double] = []
    private var nominal = 1.0 / 60
    private var moves = 0
    private static var running: Scrub?

    init(ruler: Ruler, canvas: CanvasView, name: String) {
        self.ruler = ruler
        self.canvas = canvas
        self.name = name
    }

    func run() {
        Self.running = self
        canvas.stats = CanvasStats()
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        if start == 0 {
            start = link.timestamp
        } else {
            intervals.append(link.timestamp - last)
        }
        nominal = link.targetTimestamp - link.timestamp
        last = link.timestamp
        let t = link.timestamp - start
        guard t < 4 else { return finish() }
        // A sweep from -0.6 to 0.6 and back every 1.6 s: about a finger's pace across the ruler.
        ruler.debugMove(to: 0.6 * sin(t * 2 * .pi / 1.6))
        moves += 1
    }

    private func finish() {
        link?.invalidate()
        link = nil
        ruler.debugEnd()
        // Let the last frames land before counting.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.report() }
    }

    private func report() {
        let stats = canvas.stats
        let ms = { (s: [Double]) -> [String: Double] in
            guard !s.isEmpty else { return [:] }
            let sorted = s.sorted()
            let mean = s.reduce(0, +) / Double(s.count)
            return ["mean": (mean * 10000).rounded() / 10, "p95": (sorted[Int(Double(sorted.count - 1) * 0.95)] * 10000).rounded() / 10,
                    "max": (sorted.last! * 10000).rounded() / 10]
        }
        let late = intervals.filter { $0 > nominal * 1.5 }.count
        let seconds = intervals.reduce(0, +)
        let result: [String: Any] = [
            "tool": name,
            "allTools": Self.all,
            "screenHz": (1 / nominal).rounded(),
            "mainFrames": intervals.count,
            "mainFps": seconds > 0 ? (Double(intervals.count) / seconds * 10).rounded() / 10 : 0,
            "mainLateFrames": late,
            "mainFrameMs": ms(intervals),
            "rulerMoves": moves,
            "picturesAsked": stats.asked,
            "picturesDrawn": stats.drawn,
            "pictureFps": seconds > 0 ? (Double(stats.drawn) / seconds * 10).rounded() / 10 : 0,
            "gpuMs": ms(stats.gpu),
            "makeMs": ms(stats.make),
            "latencyMs": ms(stats.latency),
            "canvasPixels": "\(Int(canvas.bounds.width * canvas.contentScaleFactor))x\(Int(canvas.bounds.height * canvas.contentScaleFactor))",
        ]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            try? data.write(to: documents.appendingPathComponent("scrub-\(name).json"))
            print(String(decoding: data, as: UTF8.self))
        }
        Self.running = nil
    }
}

/// What the canvas did while a scrub ran: pictures asked for and drawn, the GPU's time on each, the time making each
/// (building and encoding it), and from being asked for to being drawn.
struct CanvasStats {
    var asked = 0
    var drawn = 0
    var gpu: [Double] = []
    var make: [Double] = []
    var latency: [Double] = []
}
#endif
