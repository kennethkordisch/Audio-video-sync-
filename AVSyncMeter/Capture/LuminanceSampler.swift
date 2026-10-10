import CoreVideo
import Foundation

/// Cheap luminance statistics from a bi-planar YCbCr pixel buffer: the mean of the Y plane
/// and a coarse grid of cell means. Only every `step`-th pixel/row is read, which keeps a
/// 1080p frame at 240 fps well under 1 ms of work.
enum LuminanceSampler {
    static let cols = 48
    static let rows = 27

    struct Result {
        let mean: Double
        let cells: [Float]
    }

    static func sample(_ pixelBuffer: CVPixelBuffer, step: Int = 8) -> Result? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard CVPixelBufferGetPlaneCount(pixelBuffer) >= 1,
              let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return nil }
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        guard width > 0, height > 0 else { return nil }

        let pixels = base.assumingMemoryBound(to: UInt8.self)
        var sums = [Float](repeating: 0, count: cols * rows)
        var counts = [Int32](repeating: 0, count: cols * rows)
        var total: UInt64 = 0
        var n = 0

        var y = step / 2
        while y < height {
            let row = pixels + y * bytesPerRow
            let cellRow = (y * rows / height) * cols
            var x = step / 2
            while x < width {
                let v = row[x]
                total += UInt64(v)
                n += 1
                let idx = cellRow + x * cols / width
                sums[idx] += Float(v)
                counts[idx] += 1
                x += step
            }
            y += step
        }
        for i in 0..<sums.count where counts[i] > 0 {
            sums[i] /= Float(counts[i])
        }
        return Result(mean: Double(total) / Double(max(n, 1)), cells: sums)
    }
}
