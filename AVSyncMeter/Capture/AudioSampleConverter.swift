import AVFoundation
import Foundation

/// Converts a capture-session audio sample buffer to mono Float samples plus its start time.
enum AudioSampleConverter {
    struct Chunk {
        let samples: [Float]
        let sampleRate: Double
        /// Capture-clock time of the first sample (seconds).
        let startTime: Double
    }

    static func monoFloat(from sampleBuffer: CMSampleBuffer) -> Chunk? {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(format) else { return nil }
        let asbd = asbdPointer.pointee
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0, let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }

        let length = CMBlockBufferGetDataLength(block)
        var bytes = [UInt8](repeating: 0, count: length)
        let status = bytes.withUnsafeMutableBytes { raw -> OSStatus in
            guard let dst = raw.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: dst)
        }
        guard status == kCMBlockBufferNoErr else { return nil }

        let channels = Int(max(1, asbd.mChannelsPerFrame))
        let interleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
        let stride = interleaved ? channels : 1   // non-interleaved: channel 0 is the first plane
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let bytesPerSample = Int(asbd.mBitsPerChannel) / 8
        guard bytesPerSample > 0, frames * stride * bytesPerSample <= length else { return nil }

        var out = [Float](repeating: 0, count: frames)
        let ok: Bool = bytes.withUnsafeBytes { raw in
            switch (isFloat, bytesPerSample) {
            case (true, 4):
                for i in 0..<frames {
                    out[i] = raw.loadUnaligned(fromByteOffset: i * stride * 4, as: Float.self)
                }
            case (false, 2):
                for i in 0..<frames {
                    out[i] = Float(raw.loadUnaligned(fromByteOffset: i * stride * 2, as: Int16.self)) / 32768
                }
            case (false, 4):
                for i in 0..<frames {
                    out[i] = Float(raw.loadUnaligned(fromByteOffset: i * stride * 4, as: Int32.self)) / 2147483648
                }
            default:
                return false
            }
            return true
        }
        guard ok else { return nil }

        let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        return Chunk(samples: out, sampleRate: asbd.mSampleRate, startTime: pts)
    }
}
