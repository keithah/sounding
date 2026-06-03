import Foundation

#if canImport(AVFoundation)
    import AVFoundation

    struct AVFoundationPCMBufferFactory: Sendable {
        func makePCMBuffer(from frame: SharedPCMFrame) throws -> AVAudioPCMBuffer {
            let format = frame.format
            guard format.payloadKind == .linearPCM else {
                throw AppPlayerAdapterError.unsupportedPCMFormat(
                    "Unsupported PCM format for frame \(frame.sequence): decoded payload is \(format.payloadKind.rawValue)."
                )
            }
            guard frame.startSeconds.isFinite, frame.endSeconds.isFinite,
                frame.startSeconds >= 0, frame.endSeconds >= frame.startSeconds
            else {
                throw AppPlayerAdapterError.unsupportedPCMFormat(
                    "Unsupported PCM format for frame \(frame.sequence): timestamp bounds are malformed."
                )
            }
            guard let sampleRate = format.sampleRate, sampleRate.isFinite, sampleRate > 0 else {
                throw AppPlayerAdapterError.unsupportedPCMFormat(
                    "Unsupported PCM format for frame \(frame.sequence): missing sample rate.")
            }
            guard let channelCount = format.channelCount, channelCount > 0,
                channelCount <= Int(UInt32.max)
            else {
                throw AppPlayerAdapterError.unsupportedPCMFormat(
                    "Unsupported PCM format for frame \(frame.sequence): missing channel count.")
            }
            guard format.bitDepth == 16, !format.isFloat, format.isInterleaved, !format.isBigEndian
            else {
                throw AppPlayerAdapterError.unsupportedPCMFormat(
                    "Unsupported PCM format for frame \(frame.sequence): only little-endian interleaved 16-bit PCM is schedulable."
                )
            }
            guard frame.byteCount > 0, frame.byteCount <= frame.audio.count else {
                throw AppPlayerAdapterError.unsupportedPCMFormat(
                    "Unsupported PCM format for frame \(frame.sequence): PCM payload is empty or truncated."
                )
            }

            let bytesPerFrame = channelCount * MemoryLayout<Int16>.size
            guard frame.byteCount % bytesPerFrame == 0 else {
                throw AppPlayerAdapterError.unsupportedPCMFormat(
                    "Unsupported PCM format for frame \(frame.sequence): PCM payload byte count is not aligned to frames."
                )
            }
            let frameCount = frame.byteCount / bytesPerFrame
            guard frameCount > 0, frameCount <= Int(UInt32.max) else {
                throw AppPlayerAdapterError.unsupportedPCMFormat(
                    "Unsupported PCM format for frame \(frame.sequence): PCM payload frame count is invalid."
                )
            }
            guard
                let audioFormat = AVAudioFormat(
                    commonFormat: .pcmFormatInt16,
                    sampleRate: sampleRate,
                    channels: AVAudioChannelCount(channelCount),
                    interleaved: true
                ),
                let buffer = AVAudioPCMBuffer(
                    pcmFormat: audioFormat,
                    frameCapacity: AVAudioFrameCount(frameCount)
                )
            else {
                throw AppPlayerAdapterError.unsupportedPCMFormat(
                    "Unsupported PCM format for frame \(frame.sequence): AVFoundation could not create a PCM buffer."
                )
            }

            buffer.frameLength = AVAudioFrameCount(frameCount)
            let mutableBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            guard let audioBuffer = mutableBuffers.first,
                let destination = audioBuffer.mData
            else {
                throw AppPlayerAdapterError.schedulingFailed(
                    "Player scheduling failed: AVFoundation did not expose PCM buffer storage.")
            }
            guard audioBuffer.mDataByteSize >= frame.byteCount else {
                throw AppPlayerAdapterError.schedulingFailed(
                    "Player scheduling failed: AVFoundation PCM buffer storage is too small.")
            }
            frame.audio.withUnsafeBytes { rawBytes in
                if let source = rawBytes.baseAddress {
                    destination.copyMemory(from: source, byteCount: frame.byteCount)
                }
            }
            mutableBuffers[0].mDataByteSize = UInt32(frame.byteCount)
            return buffer
        }

        func convert(
            _ sourceBuffer: AVAudioPCMBuffer,
            to playbackFormat: AVAudioFormat
        ) throws -> AVAudioPCMBuffer {
            guard sourceBuffer.format != playbackFormat else { return sourceBuffer }
            guard let converter = AVAudioConverter(from: sourceBuffer.format, to: playbackFormat) else {
                throw AppPlayerAdapterError.unsupportedPCMFormat(
                    "Unsupported PCM format: AVFoundation could not create playback format converter."
                )
            }

            let sourceFrameCount = Double(sourceBuffer.frameLength)
            let sourceRate = sourceBuffer.format.sampleRate
            let playbackRate = playbackFormat.sampleRate
            let capacity = max(
                1,
                AVAudioFrameCount(ceil(sourceFrameCount * playbackRate / sourceRate)) + 512
            )
            guard let convertedBuffer = AVAudioPCMBuffer(
                pcmFormat: playbackFormat,
                frameCapacity: capacity
            ) else {
                throw AppPlayerAdapterError.unsupportedPCMFormat(
                    "Unsupported PCM format: AVFoundation could not allocate playback format buffer."
                )
            }

            var didProvideInput = false
            var conversionError: NSError?
            let status = converter.convert(to: convertedBuffer, error: &conversionError) { _, outStatus in
                if didProvideInput {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                didProvideInput = true
                outStatus.pointee = .haveData
                return sourceBuffer
            }
            if let conversionError {
                throw AppPlayerAdapterError.unsupportedPCMFormat(
                    "Unsupported PCM format: playback conversion failed: \(conversionError)."
                )
            }
            guard status != .error, convertedBuffer.frameLength > 0 else {
                throw AppPlayerAdapterError.unsupportedPCMFormat(
                    "Unsupported PCM format: playback conversion produced no renderable audio."
                )
            }
            return convertedBuffer
        }
    }
#endif
