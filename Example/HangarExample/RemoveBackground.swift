import CoreImage
import Hangar
import Vision

/// An app's own action, made the way any is: Remove Background, by Vision on the device. Only where the subject is
/// is worked out (at 2048 pixels at most); the step it makes is the background made clear, so the subject keeps the
/// picture's own pixels.
extension HangarAction {
    static let removeBackground = HangarAction(title: "Remove Background", symbol: "person.and.background.dotted", job: HangarJob(
        tool: "removeBackground", name: "Removing Background", longestSide: 2048
    ) { picture in
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: picture)
        try handler.perform([request])
        guard let found = request.results?.first, !found.allInstances.isEmpty else { throw NoSubject() }
        let subject = CIImage(cvPixelBuffer: try found.generateScaledMaskForImage(forInstances: found.allInstances, from: handler))
        // The step's picture is clear, laid where the subject isn't.
        let background = subject.applyingFilter("CIColorInvert")
        let context = CIContext()
        guard let mask = context.createCGImage(background, from: background.extent, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray()),
              let clear = context.createCGImage(CIImage(color: .clear).cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1)),
                                                from: CGRect(x: 0, y: 0, width: 1, height: 1))
        else { throw NoSubject() }
        return HangarMade(clear, mask: mask)
    })
}

private struct NoSubject: LocalizedError {
    var errorDescription: String? { "No subject was found to keep." }
}

#if DEBUG
/// For the UI tests on a simulator, where Vision can't run (`-testSteps 1`): two steps made the way any is, one
/// kept by a mask (the middle of the picture inverted), one making it larger (half as wide again, the picture in the
/// middle of a grey ground).
extension HangarAction {
    static let testInvert = HangarAction(title: "Test Step", symbol: "circle.lefthalf.filled", job: HangarJob(
        tool: "testInvert", name: "Testing", region: CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6)
    ) { picture in
        try await Task.sleep(for: .seconds(1.5))
        let image = CIImage(cgImage: picture)
        let e = image.extent
        let middle = CIVector(x: e.midX, y: e.midY)
        let mask = CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": middle, "inputRadius0": min(e.width, e.height) * 0.2, "inputRadius1": min(e.width, e.height) * 0.3,
            "inputColor0": CIColor.white, "inputColor1": CIColor.black,
        ])!.outputImage!.cropped(to: e)
        let context = CIContext()
        guard let inverted = context.createCGImage(image.applyingFilter("CIColorInvert"), from: e),
              let kept = context.createCGImage(mask, from: e, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
        else { throw NoSubject() }
        return HangarMade(inverted, mask: kept)
    })

    static let testExpand = HangarAction(title: "Test Expand", symbol: "arrow.left.and.right", job: HangarJob(
        tool: "testExpand", name: "Testing"
    ) { picture in
        try await Task.sleep(for: .seconds(1.5))
        let image = CIImage(cgImage: picture)
        let w = image.extent.width, h = image.extent.height
        let ground = CIImage(color: CIColor(red: 0.45, green: 0.47, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: w * 1.5, height: h))
        let out = image.transformed(by: CGAffineTransform(translationX: w * 0.25, y: 0)).composited(over: ground)
        guard let made = CIContext().createCGImage(out, from: out.extent) else { throw NoSubject() }
        return HangarMade(made, frame: CGRect(x: -0.25, y: 0, width: 1.5, height: 1))
    })
}
#endif
