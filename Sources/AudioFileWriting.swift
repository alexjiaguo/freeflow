import AVFoundation
import Foundation

protocol AudioFileWriter {
    func write(_ payload: AudioWritePayload) throws
}

struct AudioWritePayload {
    let formatDescription: AudioStreamBasicDescription
    let channelCount: AVAudioChannelCount
    let frameLength: AVAudioFrameCount
    let sampleBytes: Data

    init(formatDescription: AudioStreamBasicDescription,
         channelCount: AVAudioChannelCount,
         frameLength: AVAudioFrameCount,
         sampleBytes: Data) {
        self.formatDescription = formatDescription
        self.channelCount = channelCount
        self.frameLength = frameLength
        self.sampleBytes = sampleBytes
    }

    init(copying buffer: AVAudioPCMBuffer) throws {
        let formatDescription = buffer.format.streamDescription.pointee
        let channelCount = buffer.format.channelCount
        let frameLength = buffer.frameLength

        guard let channelData = buffer.floatChannelData else {
            throw AudioWritePayloadError.unsupportedBufferLayout
        }

        let bytesPerChannel = Int(frameLength) * MemoryLayout<Float>.size
        let totalByteCount = Int(frameLength) * Int(channelCount) * MemoryLayout<Float>.size
        var sampleBytes = Data(capacity: totalByteCount)

        for channelIndex in 0..<Int(channelCount) {
            let channelBytes = UnsafeRawBufferPointer(
                start: channelData[channelIndex],
                count: bytesPerChannel
            )
            sampleBytes.append(contentsOf: channelBytes)
        }

        self.init(
            formatDescription: formatDescription,
            channelCount: channelCount,
            frameLength: frameLength,
            sampleBytes: sampleBytes
        )
    }

    var expectedSampleByteCount: Int {
        Int(frameLength) * Int(channelCount) * MemoryLayout<Float>.size
    }
}

final class AVAudioFileWriterAdapter: AudioFileWriter {
    private let file: AVAudioFile

    init(file: AVAudioFile) {
        self.file = file
    }

    func write(_ payload: AudioWritePayload) throws {
        guard payload.sampleBytes.count == payload.expectedSampleByteCount else {
            throw AudioWritePayloadError.invalidSampleByteCount(
                expected: payload.expectedSampleByteCount,
                actual: payload.sampleBytes.count
            )
        }

        var streamDescription = payload.formatDescription
        guard let format = AVAudioFormat(streamDescription: &streamDescription) else {
            throw AudioWritePayloadError.invalidFormatDescription
        }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: payload.frameLength) else {
            throw AudioWritePayloadError.bufferAllocationFailed
        }

        guard let channelData = buffer.floatChannelData else {
            throw AudioWritePayloadError.unsupportedBufferLayout
        }

        buffer.frameLength = payload.frameLength

        let bytesPerChannel = Int(payload.frameLength) * MemoryLayout<Float>.size
        payload.sampleBytes.withUnsafeBytes { sourceBytes in
            for channelIndex in 0..<Int(payload.channelCount) {
                let byteOffset = channelIndex * bytesPerChannel
                let source = UnsafeRawBufferPointer(
                    rebasing: sourceBytes[byteOffset..<(byteOffset + bytesPerChannel)]
                )
                let destination = UnsafeMutableRawBufferPointer(
                    start: channelData[channelIndex],
                    count: bytesPerChannel
                )
                destination.copyMemory(from: source)
            }
        }

        try file.write(from: buffer)
    }
}

final class AudioWriteCoordinator {
    private let stateLock = NSLock()
    private let writeQueue = DispatchQueue(label: "AudioWriteCoordinator.writeQueue")
    private let pendingWrites = DispatchGroup()

    private var writer: AudioFileWriter?
    private var isAcceptingWrites = false
    private var firstFailure: Error?
    private var hasLoggedFailure = false

    func start(writer: AudioFileWriter) {
        stateLock.lock()
        self.writer = writer
        isAcceptingWrites = true
        firstFailure = nil
        hasLoggedFailure = false
        stateLock.unlock()
    }

    func enqueueWrite(_ payload: AudioWritePayload) -> Bool {
        let activeWriter: AudioFileWriter

        stateLock.lock()
        guard isAcceptingWrites, firstFailure == nil, let writer else {
            stateLock.unlock()
            return false
        }

        activeWriter = writer
        pendingWrites.enter()
        stateLock.unlock()

        writeQueue.async { [weak self] in
            defer {
                self?.completePendingWrite()
            }

            do {
                try activeWriter.write(payload)
            } catch {
                self?.latchFailure(error)
            }
        }

        return true
    }

    func finish() throws {
        stateLock.lock()
        isAcceptingWrites = false
        writer = nil
        stateLock.unlock()

        pendingWrites.wait()

        stateLock.lock()
        let failure = firstFailure
        stateLock.unlock()

        if let failure {
            throw failure
        }
    }

    private func completePendingWrite() {
        pendingWrites.leave()
    }

    private func latchFailure(_ error: Error) {
        let shouldLogFailure: Bool

        stateLock.lock()
        if firstFailure == nil {
            firstFailure = error
            isAcceptingWrites = false
        }
        shouldLogFailure = !hasLoggedFailure
        hasLoggedFailure = true
        stateLock.unlock()

        guard shouldLogFailure else {
            return
        }

        fputs("Audio write failed: \(error)\n", stderr)
    }
}

private enum AudioWritePayloadError: Error {
    case invalidSampleByteCount(expected: Int, actual: Int)
    case invalidFormatDescription
    case bufferAllocationFailed
    case unsupportedBufferLayout
}
