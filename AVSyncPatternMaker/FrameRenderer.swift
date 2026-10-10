import AppKit
import CoreGraphics
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
