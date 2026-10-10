import AppKit
import AVFoundation
import CoreText
import Foundation

/// Writes the pink-noise calibration sequence as a multichannel WAV and/or a QuickTime movie
/// with on-screen channel names and a multichannel PCM track.
final class PinkNoiseWriter {
    let spec: PinkNoiseSpec
    let video: PatternSpec   // frame rate, resolution and codec for the movie

    init(spec: PinkNoiseSpec, video: PatternSpec) {
        self.spec = spec
        self.video = video
    }

    private var channelLayoutData: Data {
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = spec.layout.layoutTag
        return Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
    }

    // MARK: - WAV

    func writeWAV(to url: URL, progress: @escaping (Double) -> Void, isCancelled: @escaping () -> Bool) throws {
        try? FileManager.default.removeItem(at: url)
        let channels = spec.layout.channelCount
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: spec.sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 24,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVChannelLayoutKey: channelLayoutData,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let format = file.processingFormat
        var generator = PinkNoiseGenerator(spec: spec)
        let total = Int(spec.durationSeconds * spec.sampleRate)
        let chunk = 48000
        var cursor = 0
        while cursor < total {
            if isCancelled() { throw PatternWriter.WriterError.cancelled }
            let count = min(chunk, total - cursor)
            let interleaved = generator.samples(from: cursor, count: count)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
                  let data = buffer.floatChannelData else {
                throw PatternWriter.WriterError.setup("audio buffer")
            }
            buffer.frameLength = AVAudioFrameCount(count)
            if format.isInterleaved {
                for i in 0..<(count * channels) { data[0][i] = interleaved[i] }
            } else {
                for c in 0..<channels {
                    for n in 0..<count { data[c][n] = interleaved[n * channels + c] }
                }
            }
            try file.write(from: buffer)
            cursor += count
            progress(Double(cursor) / Double(total))
        }
    }

    // MARK: - Movie

    func writeMovie(to url: URL, progress: @escaping (Double) -> Void, isCancelled: @escaping () -> Bool) throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let width = video.resolution.width, height = video.resolution.height
        let channels = spec.layout.channelCount

        var videoSettings: [String: Any] = [
            AVVideoCodecKey: video.videoCodec.avCodec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
        if !video.videoCodec.isProRes {
            videoSettings[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: 4_000_000,
                AVVideoMaxKeyFrameIntervalKey: Int(video.frameRate.fps.rounded()),
                AVVideoAllowFrameReorderingKey: false,
            ]
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        videoInput.mediaTimeScale = video.frameRate.numerator
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: spec.sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 24,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVChannelLayoutKey: channelLayoutData,
        ]
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput.expectsMediaDataInRealTime = false

        guard writer.canAdd(videoInput), writer.canAdd(audioInput) else {
            throw PatternWriter.WriterError.setup("writer rejected \(channels)-channel PCM or the video settings")
        }
        writer.add(videoInput)
        writer.add(audioInput)
        writer.movieTimeScale = video.frameRate.numerator
        guard writer.startWriting() else {
            throw PatternWriter.WriterError.failed(writer.error?.localizedDescription ?? "startWriting failed")
        }
        writer.startSession(atSourceTime: .zero)

        let format = try makeAudioFormatDescription(channels: channels)
        var generator = PinkNoiseGenerator(spec: spec)
        let renderer = TextFrameRenderer(width: width, height: height)
        let fps = video.frameRate.fps
        let totalFrames = Int((spec.durationSeconds * fps).rounded())
        let totalSamples = Int(spec.durationSeconds * spec.sampleRate)
        var audioCursor = 0
        var cache: (key: String, buffer: CVPixelBuffer)?
        let segments = spec.segments

        func appendAudio(upTo target: Int) throws {
            while audioCursor < target {
                let count = min(4800, target - audioCursor)
                while !audioInput.isReadyForMoreMediaData {
                    if isCancelled() { throw PatternWriter.WriterError.cancelled }
                    usleep(2000)
                }
                let samples = generator.samples(from: audioCursor, count: count)
                let buffer = try makeAudioSampleBuffer(samples: samples, frames: count, channels: channels,
                                                       startSample: audioCursor, format: format)
                guard audioInput.append(buffer) else {
                    throw PatternWriter.WriterError.failed(writer.error?.localizedDescription ?? "audio append failed")
                }
                audioCursor += count
            }
        }

        for frame in 0..<totalFrames {
            if isCancelled() { writer.cancelWriting(); throw PatternWriter.WriterError.cancelled }
            let time = Double(frame) * Double(video.frameRate.denominator) / Double(video.frameRate.numerator)
            let segment = spec.segment(at: time)
            let index = segment.flatMap { seg in segments.firstIndex { $0.start == seg.start } }
            let key = segment?.title ?? "gap"
            let pixelBuffer: CVPixelBuffer
            if let cache, cache.key == key {
                pixelBuffer = cache.buffer
            } else {
                let buffer = try TextFrameRenderer.makePixelBuffer(width: width, height: height)
                var lines: [TextFrameRenderer.Line] = []
                if let segment {
                    lines.append(.init(text: segment.title, scale: 1 / 7, gray: 0.85))
                    lines.append(.init(text: String(format: "pink noise  %.0f dBFS RMS  %@  %d / %d",
                                                    spec.levelDBFS, spec.layout.rawValue, (index ?? 0) + 1, segments.count),
                                       scale: 1 / 28, gray: 0.5))
                } else {
                    lines.append(.init(text: time < spec.leadInSeconds ? "SPEAKER LEVEL CHECK  \(spec.layout.rawValue)" : "…",
                                       scale: 1 / 14, gray: 0.45))
                    lines.append(.init(text: "channels: " + spec.layout.channels.joined(separator: "  "), scale: 1 / 28, gray: 0.35))
                }
                renderer.render(lines: lines, into: buffer)
                cache = (key, buffer)
                pixelBuffer = buffer
            }
            while !videoInput.isReadyForMoreMediaData {
                if isCancelled() { writer.cancelWriting(); throw PatternWriter.WriterError.cancelled }
                usleep(2000)
            }
            let pts = CMTime(value: CMTimeValue(frame) * CMTimeValue(video.frameRate.denominator), timescale: video.frameRate.numerator)
            guard adaptor.append(pixelBuffer, withPresentationTime: pts) else {
                throw PatternWriter.WriterError.failed(writer.error?.localizedDescription ?? "video append failed")
            }
            let audioTarget = min(totalSamples, Int((Double(frame + 1) / fps) * spec.sampleRate))
            try appendAudio(upTo: audioTarget)
            if frame % 24 == 0 { progress(Double(frame) / Double(max(1, totalFrames))) }
        }
        try appendAudio(upTo: totalSamples)

        videoInput.markAsFinished()
        audioInput.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else {
            throw PatternWriter.WriterError.failed(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")
        }
        progress(1)
    }

    private func makeAudioFormatDescription(channels: Int) throws -> CMAudioFormatDescription {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: spec.sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * channels),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(4 * channels),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0)
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = spec.layout.layoutTag
        var description: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
                                                    layoutSize: MemoryLayout<AudioChannelLayout>.size, layout: &layout,
                                                    magicCookieSize: 0, magicCookie: nil,
                                                    extensions: nil, formatDescriptionOut: &description)
        guard status == noErr, let description else { throw PatternWriter.WriterError.setup("audio format description \(status)") }
        return description
    }

    private func makeAudioSampleBuffer(samples: [Float], frames: Int, channels: Int, startSample: Int,
                                       format: CMAudioFormatDescription) throws -> CMSampleBuffer {
        let byteCount = samples.count * MemoryLayout<Float>.size
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                                                        blockLength: byteCount, blockAllocator: kCFAllocatorDefault,
                                                        customBlockSource: nil, offsetToData: 0,
                                                        dataLength: byteCount, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                        blockBufferOut: &blockBuffer)
        guard status == kCMBlockBufferNoErr, let blockBuffer else { throw PatternWriter.WriterError.setup("block buffer \(status)") }
        status = samples.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: byteCount)
        }
        guard status == kCMBlockBufferNoErr else { throw PatternWriter.WriterError.setup("block buffer fill \(status)") }
        var sampleBuffer: CMSampleBuffer?
        let pts = CMTime(value: CMTimeValue(startSample), timescale: CMTimeScale(spec.sampleRate))
        status = CMAudioSampleBufferCreateWithPacketDescriptions(allocator: kCFAllocatorDefault, dataBuffer: blockBuffer,
                                                                 dataReady: true, makeDataReadyCallback: nil, refcon: nil,
                                                                 formatDescription: format, sampleCount: frames,
                                                                 presentationTimeStamp: pts, packetDescriptions: nil,
                                                                 sampleBufferOut: &sampleBuffer)
        guard status == noErr, let sampleBuffer else { throw PatternWriter.WriterError.setup("audio sample buffer \(status)") }
        return sampleBuffer
    }
}

/// Centred lines of text on black, for the pink-noise movie.
final class TextFrameRenderer {
    struct Line {
        let text: String
        /// Font size as a fraction of frame height.
        let scale: CGFloat
        let gray: CGFloat
    }

    let width: Int
    let height: Int

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    static func makePixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer)
        guard status == kCVReturnSuccess, let buffer else { throw PatternWriter.WriterError.setup("CVPixelBufferCreate \(status)") }
        return buffer
    }

    func render(lines: [Line], into pixelBuffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let info = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)
        guard let context = CGContext(data: base, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info.rawValue) else { return }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let h = CGFloat(height)
        var y = h * 0.5 + CGFloat(lines.count - 1) * h * 0.06
        for line in lines {
            let font = CTFontCreateWithName("HelveticaNeue-Medium" as CFString, h * line.scale, nil)
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: line.gray, alpha: 1),
            ]
            let ctLine = CTLineCreateWithAttributedString(NSAttributedString(string: line.text, attributes: attributes))
            let bounds = CTLineGetBoundsWithOptions(ctLine, [])
            context.textPosition = CGPoint(x: (CGFloat(width) - bounds.width) / 2, y: y - bounds.height / 2)
            CTLineDraw(ctLine, context)
            y -= h * line.scale + h * 0.05
        }
    }
}
