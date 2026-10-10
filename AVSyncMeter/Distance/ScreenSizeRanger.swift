import CoreGraphics
import Foundation

/// Bounding box in luminance-grid cells.
struct CellRect: Equatable {
    var minCol: Int
    var maxCol: Int
    var minRow: Int
    var maxRow: Int

    var colSpan: Int { maxCol - minCol + 1 }
    var rowSpan: Int { maxRow - minRow + 1 }

    func normalized(cols: Int, rows: Int) -> CGRect {
        CGRect(x: Double(minCol) / Double(cols),
               y: Double(minRow) / Double(rows),
               width: Double(colSpan) / Double(cols),
               height: Double(rowSpan) / Double(rows))
    }

    /// Shrinks by one cell per side when large enough, to keep the detector away from the bezel.
    var inset: CellRect {
        guard colSpan >= 4, rowSpan >= 4 else { return self }
        return CellRect(minCol: minCol + 1, maxCol: maxCol - 1, minRow: minRow + 1, maxRow: maxRow - 1)
    }
}

/// Estimates camera-to-screen distance from how large the (known-size) screen appears when it
/// flashes white, using the camera's focal length in pixels:  distance = f * D_real / d_pixels.
enum ScreenSizeRanger {
    struct Measurement {
        let rect: CellRect
        /// Sub-cell spans (partially lit edge cells count fractionally).
        let widthCells: Double
        let heightCells: Double
    }

    /// Finds the region that brightened between `dark` and `current`.
    static func brightRegion(current: [Float], dark: [Float], cols: Int, rows: Int, threshold: Float) -> Measurement? {
        guard current.count == cols * rows, dark.count == current.count, threshold > 0 else { return nil }
        var minCol = cols, maxCol = -1, minRow = rows, maxRow = -1
        var litCells = 0
        var peak: Float = 0
        for r in 0..<rows {
            for c in 0..<cols {
                let d = current[r * cols + c] - dark[r * cols + c]
                if d > peak { peak = d }
                if d > threshold {
                    litCells += 1
                    minCol = min(minCol, c); maxCol = max(maxCol, c)
                    minRow = min(minRow, r); maxRow = max(maxRow, r)
                }
            }
        }
        guard litCells >= 4, maxCol >= minCol, maxRow >= minRow else { return nil }
        let rect = CellRect(minCol: minCol, maxCol: maxCol, minRow: minRow, maxRow: maxRow)

        // Reject regions that are not roughly rectangular (e.g. light spilling on a wall).
        let fill = Double(litCells) / Double(rect.colSpan * rect.rowSpan)
        guard fill > 0.6 else { return nil }

        // Sub-cell extents: sum of per-column (per-row) coverage, where coverage is the
        // column's brightest difference relative to the overall peak.
        var widthCells = 0.0
        for c in minCol...maxCol {
            var colPeak: Float = 0
            for r in minRow...maxRow { colPeak = max(colPeak, current[r * cols + c] - dark[r * cols + c]) }
            widthCells += Double(min(1, max(0, colPeak / peak)))
        }
        var heightCells = 0.0
        for r in minRow...maxRow {
            var rowPeak: Float = 0
            for c in minCol...maxCol { rowPeak = max(rowPeak, current[r * cols + c] - dark[r * cols + c]) }
            heightCells += Double(min(1, max(0, rowPeak / peak)))
        }
        return Measurement(rect: rect, widthCells: widthCells, heightCells: heightCells)
    }

    /// False when the lit region runs off the frame (the screen is not fully in view).
    static func isFullyVisible(_ rect: CellRect, cols: Int, rows: Int) -> Bool {
        rect.minCol > 0 && rect.maxCol < cols - 1 && rect.minRow > 0 && rect.maxRow < rows - 1
    }

    static func distance(measurement m: Measurement, cols: Int, rows: Int, width: Int, height: Int,
                         focalLengthPixels: Double, screenDiagonalMeters: Double) -> Double? {
        guard focalLengthPixels > 0, screenDiagonalMeters > 0 else { return nil }
        let cellWidth = Double(width) / Double(cols)
        let cellHeight = Double(height) / Double(rows)
        let wPx = m.widthCells * cellWidth
        let hPx = m.heightCells * cellHeight
        let diagonalPx = (wPx * wPx + hPx * hPx).squareRoot()
        guard diagonalPx > 20 else { return nil }
        return focalLengthPixels * screenDiagonalMeters / diagonalPx
    }
}
