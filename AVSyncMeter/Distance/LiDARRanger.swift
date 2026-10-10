import ARKit
import Foundation

/// Measures the distance to whatever is at the centre of the camera view using the LiDAR
/// depth map (ARKit scene depth). Only available on LiDAR-equipped devices. Range is roughly
/// 0.3 to 5 m; beyond that the confidence drops and no sample is recorded.
final class LiDARRanger: NSObject, ARSessionDelegate {
    static var isSupported: Bool {
        ARWorldTrackingConfiguration.isSupported
            && ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    }

    private let session = ARSession()
    private var samples: [Double] = []

    /// Median of the accepted samples so far (meters).
    private(set) var estimate: Double?
    private(set) var sampleCount = 0

    func start() {
        samples.removeAll()
        estimate = nil
        sampleCount = 0
        let configuration = ARWorldTrackingConfiguration()
        configuration.frameSemantics.insert(.sceneDepth)
        session.delegate = self
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    }

    func stop() {
        session.pause()
        session.delegate = nil
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard let depth = frame.sceneDepth else { return }
        guard let value = Self.centreDepth(depthMap: depth.depthMap, confidenceMap: depth.confidenceMap) else { return }
        samples.append(value)
        if samples.count > 60 { samples.removeFirst(samples.count - 60) }
        sampleCount = samples.count
        estimate = Statistics.median(samples)
    }

    /// Median depth of a 9x9 patch at the image centre, using only medium/high-confidence pixels.
    private static func centreDepth(depthMap: CVPixelBuffer, confidenceMap: CVPixelBuffer?) -> Double? {
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        if let confidenceMap { CVPixelBufferLockBaseAddress(confidenceMap, .readOnly) }
        defer { if let confidenceMap { CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly) } }

        guard CVPixelBufferGetPixelFormatType(depthMap) == kCVPixelFormatType_DepthFloat32,
              let depthBase = CVPixelBufferGetBaseAddress(depthMap) else { return nil }
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        let depthStride = CVPixelBufferGetBytesPerRow(depthMap) / MemoryLayout<Float32>.size
        let depthPixels = depthBase.assumingMemoryBound(to: Float32.self)

        var confidencePixels: UnsafePointer<UInt8>?
        var confidenceStride = 0
        if let confidenceMap, let confidenceBase = CVPixelBufferGetBaseAddress(confidenceMap),
           CVPixelBufferGetWidth(confidenceMap) == width, CVPixelBufferGetHeight(confidenceMap) == height {
            confidencePixels = UnsafePointer(confidenceBase.assumingMemoryBound(to: UInt8.self))
            confidenceStride = CVPixelBufferGetBytesPerRow(confidenceMap)
        }

        let radius = 4
        let cx = width / 2, cy = height / 2
        var values: [Double] = []
        for y in max(0, cy - radius)...min(height - 1, cy + radius) {
            for x in max(0, cx - radius)...min(width - 1, cx + radius) {
                if let confidencePixels {
                    let c = Int(confidencePixels[y * confidenceStride + x])
                    guard c >= ARConfidenceLevel.medium.rawValue else { continue }
                }
                let d = Double(depthPixels[y * depthStride + x])
                if d.isFinite && d > 0.1 && d < 10 { values.append(d) }
            }
        }
        // Require most of the patch to be confident.
        guard values.count >= 40 else { return nil }
        return Statistics.median(values)
    }
}
