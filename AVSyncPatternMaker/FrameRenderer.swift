import AppKit
import CoreGraphics
import CoreText
import CoreVideo
import Foundation

/// Draws pattern frames into BGRA pixel buffers.
final class FrameRenderer {
    private let spec: PatternSpec
    private let captionFont: CTFont
    private let smallFont: CTFont
    private let dimGrey = CGColor(gray: 0.25, alpha: 1)
    private let dimmerGrey = CGColor(gray: 0.19, alpha: 1)

    init(spec: PatternSpec) {
        self.spec = spec
        captionFont = CTFontCreateWithName("HelveticaNeue-Medium" as CFString, CGFloat(spec.resolution.height) / 18, nil)
        smallFont = CTFontCreateWithName("Menlo" as CFString, CGFloat(spec.resolution.height) / 36, nil)
    }

    func render(frame: Int, into pixelBuffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let info = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)
        guard let context = CGContext(data: base, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: info.rawValue) else { return }

        if spec.isSlateFrame(frame) {
            drawSlate(frame: frame, in: context, width: width, height: height)
            return
        }
        if spec.isFlashFrame(frame) {
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            return
        }

        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        if spec.showCaption {
            let eventNumber = spec.eventIndex(forFrame: frame).map { $0 + 1 } ?? 0
            let title = "AV SYNC TEST \(spec.frameRate.label)   \(eventNumber)"
            draw(title, font: captionFont, color: dimGrey, centerY: CGFloat(height) / 2, in: context, width: width)
            let detail = String(format: "flash %d fr + %.0f Hz beep every %d frames", spec.flashFrames, spec.toneFrequency, spec.periodFrames)
            draw(detail, font: smallFont, color: dimmerGrey, centerY: CGFloat(height) / 2 - CGFloat(height) / 12, in: context, width: width)
        }
        if spec.burnInTimecode {
            let tc = "\(spec.timecode(forFrame: frame))  f\(frame)"
            draw(tc, font: smallFont, color: dimGrey, centerY: CGFloat(height) / 10, in: context, width: width)
        }
    }

    /// 75% colour bars, a PLUGE row (black, +2%, +4%, 75% and 100% white), and a bar that moves
    /// one step per frame for judder/cadence checks. Shown before the pattern starts.
    private func drawSlate(frame: Int, in context: CGContext, width: Int, height: Int) {
        let w = CGFloat(width), h = CGFloat(height)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))

        // Colour bars: top 60% (CG origin is bottom-left, so y from 0.4h to h).
        let bars: [(CGFloat, CGFloat, CGFloat)] = [(0.75, 0.75, 0.75), (0.75, 0.75, 0), (0, 0.75, 0.75), (0, 0.75, 0),
                                                   (0.75, 0, 0.75), (0.75, 0, 0), (0, 0, 0.75)]
        let barWidth = w / CGFloat(bars.count)
        for (i, c) in bars.enumerated() {
            context.setFillColor(CGColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1))
            context.fill(CGRect(x: CGFloat(i) * barWidth, y: 0.4 * h, width: barWidth + 1, height: 0.6 * h))
        }

        // PLUGE row: 25% to 40% height. Near-black steps in the middle, greys at the sides.
        let pluge: [CGFloat] = [1.0, 0.75, 0.0, 0.02, 0.04, 0.0, 0.75, 1.0]
        let plugeWidth = w / CGFloat(pluge.count)
        for (i, level) in pluge.enumerated() {
            context.setFillColor(CGColor(gray: level, alpha: 1))
            context.fill(CGRect(x: CGFloat(i) * plugeWidth, y: 0.25 * h, width: plugeWidth + 1, height: 0.15 * h))
        }

        // Motion bar: crosses the frame once every 2 s, one step per frame.
        let period = max(1, Int((2 * spec.frameRate.fps).rounded()))
        let x = CGFloat(frame % period) / CGFloat(period) * w
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: x, y: 0.08 * h, width: max(2, w * 0.015), height: 0.12 * h))

        let remaining = spec.slateFrames - frame
        let seconds = Double(remaining) / spec.frameRate.fps
        let text = String(format: "AV SYNC TEST %@ fps   slate   pattern starts in %.0f s at %@",
                          spec.frameRate.label, seconds.rounded(.up), spec.timecode(forFrame: spec.firstEventFrame))
        draw(text, font: smallFont, color: CGColor(gray: 0.6, alpha: 1), centerY: 0.03 * h, in: context, width: width)
    }

    private func draw(_ text: String, font: CTFont, color: CGColor, centerY: CGFloat, in context: CGContext, width: Int) {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let bounds = CTLineGetBoundsWithOptions(line, [])
        context.textPosition = CGPoint(x: (CGFloat(width) - bounds.width) / 2, y: centerY - bounds.height / 2)
        CTLineDraw(line, context)
    }
}
