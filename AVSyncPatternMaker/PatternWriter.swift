import AVFoundation
import CoreVideo
import Foundation

/// Renders one pattern file with AVAssetWriter. Blocking; run it off the main thread.
final class PatternWriter {
    enum WriterError: LocalizedError {
        case setup(String)
        case failed(String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .setup(let m): return "Could not set up the writer: \(m)"
            case .failed(let m): return "Writing failed: \(m)"
            case .cancelled: return "Cancelled"
            }
        }
    }

    let spec: PatternSpec
    let outputURL: URL

    init(spec: PatternSpec, outputURL: URL) {
        self.spec = spec
        self.outputURL = outputURL
    }

    func write(progress: @escaping (Double) -> Void, isCancelled: @escaping () -> Bool) throws {
        try? FileManager.default.removeItem(at: outputURL)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: spec.fileType)
        writer.movieTimeScale = spec.frameRate.numerator

        let width = spec.resolution.width
        let height = spec.resolution.height

        // Video input
        var videoSettings: [String: Any] = [
            AVVideoCodecKey: spec.videoCodec.avCodec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
        if !spec.videoCodec.isProRes {
            let pixelsPerSecond = Double(width * height) * spec.frameRate.fps
            var compression: [String: Any] = [
                AVVideoAverageBitRateKey: Int(pixelsPerSecond * 0.12),   // ~15 Mb/s at 1080p60, plenty for black/white
                AVVideoMaxKeyFrameIntervalKey: spec.periodFrames,
                AVVideoExpectedSourceFrameRateKey: Int(spec.frameRate.fps.rounded()),
                AVVideoAllowFrameReorderingKey: false,
            ]
            if spec.videoCodec == .h264 {
                compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
            }
            videoSettings[AVVideoCompressionPropertiesKey] = compression
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        videoInput.mediaTimeScale = spec.frameRate.numerator
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])

        // Audio input
        var audioSettings: [String: Any] = [
            AVSampleRateKey: spec.sampleRate,
            AVNumberOfChannelsKey: 2,
        ]
        switch spec.audioFormat {
        case .pcm24, .pcm16:
            audioSettings[AVFormatIDKey] = kAudioFormatLinearPCM
            audioSettings[AVLinearPCMBitDepthKey] = spec.audioFormat == .pcm24 ? 24 : 16
            audioSettings[AVLinearPCMIsFloatKey] = false
            audioSettings[AVLinearPCMIsBigEndianKey] = false
            audioSettings[AVLinearPCMIsNonInterleaved] = false
        case .aac:
            audioSettings[AVFormatIDKey] = kAudioFormatMPEG4AAC
            audioSettings[AVEncoderBitRateKey] = 256_000
        }
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput.expectsMediaDataInRealTime = false

        guard writer.canAdd(videoInput) else { throw WriterError.setup("video settings rejected for \(spec.fileExtension)") }
        writer.add(videoInput)
        guard writer.canAdd(audioInput) else { throw WriterError.setup("audio settings rejected for \(spec.fileExtension)") }
        writer.add(audioInput)

        guard writer.startWriting() else {
            throw WriterError.failed(writer.error?.localizedDescription ?? "startWriting failed")
        }
        writer.startSession(atSourceTime: .zero)

        let renderer = FrameRenderer(spec: spec)
        let tone = ToneGenerator(spec: spec)
        let audioFormat = try Self.makeAudioFormatDescription(sampleRate: spec.sampleRate)

        // Frame cache: the white frame never changes; the dark frame only changes per event
        // (unless timecode is burned in, which changes every frame).
        let white = try Self.makePixelBuffer(width: width, height: height)
        renderer.render(frame: spec.firstEventFrame, into: white)
        var darkCache: (event: Int, buffer: CVPixelBuffer)?

        let totalFrames = spec.totalFrames
        let sampleRate = spec.sampleRate
        let chunkSamples = 4800
        var audioCursor = 0
        let totalSamples = Int((spec.time(ofFrame: totalFrames) * sampleRate).rounded())

        func appendAudio(upTo target: Int) throws {
            while audioCursor < target {
                let count = min(chunkSamples, target - audioCursor)
                while !audioInput.isReadyForMoreMediaData {
                    if isCancelled() { throw WriterError.cancelled }
                    usleep(2000)
                }
                let samples = tone.samples(from: audioCursor, count: count)
                let buffer = try Self.makeAudioSampleBuffer(samples: samples, frames: count, startSample: audioCursor,
                                                            sampleRate: sampleRate, format: audioFormat)
                guard audioInput.append(buffer) else {
                    throw WriterError.failed(writer.error?.localizedDescription ?? "audio append failed")
                }
                audioCursor += count
            }
        }

        for frame in 0..<totalFrames {
            if isCancelled() {
                writer.cancelWriting()
                throw WriterError.cancelled
            }
            let pixelBuffer: CVPixelBuffer
            if spec.isFlashFrame(frame) {
                pixelBuffer = white
            } else if spec.burnInTimecode {
                guard let pool = adaptor.pixelBufferPool else { throw WriterError.setup("no pixel buffer pool") }
                var pooled: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pooled)
                guard let pooled else { throw WriterError.setup("pixel buffer allocation failed") }
                renderer.render(frame: frame, into: pooled)
                pixelBuffer = pooled
            } else {
                let event = spec.eventIndex(forFrame: frame) ?? -1
                if let cached = darkCache, cached.event == event {
                    pixelBuffer = cached.buffer
                } else {
                    let buffer = try Self.makePixelBuffer(width: width, height: height)
                    renderer.render(frame: frame, into: buffer)
                    darkCache = (event, buffer)
                    pixelBuffer = buffer
                }
            }

            while !videoInput.isReadyForMoreMediaData {
                if isCancelled() { writer.cancelWriting(); throw WriterError.cancelled }
                usleep(2000)
            }
            let pts = CMTime(value: CMTimeValue(frame) * CMTimeValue(spec.frameRate.denominator),
                             timescale: spec.frameRate.numerator)
            guard adaptor.append(pixelBuffer, withPresentationTime: pts) else {
                throw WriterError.failed(writer.error?.localizedDescription ?? "video append failed")
            }

            // Keep audio roughly level with video so neither input starves.
            let audioTarget = min(totalSamples, Int((spec.time(ofFrame: frame + 1) * sampleRate).rounded()))
            try appendAudio(upTo: audioTarget)

            if frame % 24 == 0 {
                progress(Double(frame) / Double(max(1, totalFrames)))
            }
        }
        try appendAudio(upTo: totalSamples)

        videoInput.markAsFinished()
        audioInput.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        if writer.status != .completed {
            throw WriterError.failed(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")
        }
        progress(1)
    }

    // MARK: - Buffers

    private static func makePixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                         attributes as CFDictionary, &buffer)
        guard status == kCVReturnSuccess, let buffer else { throw WriterError.setup("CVPixelBufferCreate \(status)") }
        return buffer
    }

    private static func makeAudioFormatDescription(sampleRate: Double) throws -> CMAudioFormatDescription {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8,
            mFramesPerPacket: 1,
            mBytesPerFrame: 8,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0)
        var description: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
                                                    layoutSize: 0, layout: nil,
                                                    magicCookieSize: 0, magicCookie: nil,
                                                    extensions: nil, formatDescriptionOut: &description)
        guard status == noErr, let description else { throw WriterError.setup("audio format description \(status)") }
        return description
    }

    private static func makeAudioSampleBuffer(samples: [Float], frames: Int, startSample: Int,
                                              sampleRate: Double, format: CMAudioFormatDescription) throws -> CMSampleBuffer {
        let byteCount = samples.count * MemoryLayout<Float>.size
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                                                        blockLength: byteCount, blockAllocator: kCFAllocatorDefault,
                                                        customBlockSource: nil, offsetToData: 0,
                                                        dataLength: byteCount, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                        blockBufferOut: &blockBuffer)
        guard status == kCMBlockBufferNoErr, let blockBuffer else { throw WriterError.setup("block buffer \(status)") }
        status = samples.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: blockBuffer,
                                          offsetIntoDestination: 0, dataLength: byteCount)
        }
        guard status == kCMBlockBufferNoErr else { throw WriterError.setup("block buffer fill \(status)") }

        var sampleBuffer: CMSampleBuffer?
        let pts = CMTime(value: CMTimeValue(startSample), timescale: CMTimeScale(sampleRate))
        status = CMAudioSampleBufferCreateWithPacketDescriptions(allocator: kCFAllocatorDefault,
                                                                 dataBuffer: blockBuffer,
                                                                 dataReady: true,
                                                                 makeDataReadyCallback: nil,
                                                                 refcon: nil,
                                                                 formatDescription: format,
                                                                 sampleCount: frames,
                                                                 presentationTimeStamp: pts,
                                                                 packetDescriptions: nil,
                                                                 sampleBufferOut: &sampleBuffer)
        guard status == noErr, let sampleBuffer else { throw WriterError.setup("audio sample buffer \(status)") }
        return sampleBuffer
    }
}
