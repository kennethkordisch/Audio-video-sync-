import CoreVideo
import Foundation
import UIKit
import Vision

/// Reads the pattern's burned-in caption ("AV SYNC TEST 23.976   17", optional timecode) from a
/// camera frame with Vision text recognition. Best effort: the caption is deliberately dim, so
/// it works on bright displays at moderate distance and simply returns nothing otherwise.
final class CaptionReader {
    struct Reading {
        let eventNumber: Int?
        let timecode: String?
    }

    private let queue = DispatchQueue(label: "AVSyncMeter.ocr", qos: .utility)
    private var busy = false

    func read(_ pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation,
              completion: @escaping @Sendable (Reading) -> Void) {
        queue.async { [self] in
            guard !busy else { return }
            busy = true
            defer { busy = false }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
            guard (try? handler.perform([request])) != nil,
                  let observations = request.results else { return }
            let strings = observations.compactMap { $0.topCandidates(1).first?.string }
            let reading = Self.parse(strings)
            if reading.eventNumber != nil || reading.timecode != nil {
                completion(reading)
            }
        }
    }

    static func parse(_ lines: [String]) -> Reading {
        var eventNumber: Int?
        var timecode: String?
        let timecodePattern = try? NSRegularExpression(pattern: #"\b\d{2}:\d{2}:\d{2}[:;]\d{2}\b"#)
        for line in lines {
            if timecode == nil, let regex = timecodePattern,
               let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
               let range = Range(match.range, in: line) {
                timecode = String(line[range])
            }
            let upper = line.uppercased()
            if upper.contains("SYNC") || upper.contains("TEST") {
                // The event counter is the last integer token on the caption line.
                let tokens = upper.split(whereSeparator: { !$0.isNumber })
                if let last = tokens.last, let value = Int(last), value < 100_000 {
                    eventNumber = value
                }
            }
        }
        return Reading(eventNumber: eventNumber, timecode: timecode)
    }

    /// Maps the phone's physical orientation to the orientation of the back camera's buffer.
    static func orientation(for device: UIDeviceOrientation) -> CGImagePropertyOrientation {
        switch device {
        case .landscapeLeft: return .up
        case .landscapeRight: return .down
        case .portraitUpsideDown: return .left
        default: return .right
        }
    }
}
