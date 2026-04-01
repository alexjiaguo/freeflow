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

    init(copying buffer: AVAudioPCMBuffer) {
        let formatDescription = buffer.format.streamDescription.pointee
        let channelCount = buffer.format.channelCount
        let frameLength = buffer.frameLength

        precondition(channelCount == 1, "AudioWritePayload(copying:) only supports mono buffers in Task 3")
        guard let channelData = buffer.floatChannelData else {
            preconditionFailure("AudioWritePayload(copying:) requires float channel data in Task 3")
        }

        let byteCount = Int(frameLength) * Int(formatDescription.mBytesPerFrame)
        let sampleBytes = Data(bytes: channelData[0], count: byteCount)

        self.init(
            formatDescription: formatDescription,
            channelCount: channelCount,
            frameLength: frameLength,
            sampleBytes: sampleBytes
        )
    }

    var expectedSampleByteCount: Int {
        Int(frameLength) * Int(formatDescription.mBytesPerFrame)
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
            throw AudioWritePayloadError.missingChannelData
        }

        buffer.frameLength = payload.frameLength
        payload.sampleBytes.withUnsafeBytes { sourceBytes in
            let destination = UnsafeMutableRawBufferPointer(
                start: UnsafeMutableRawPointer(channelData[0]),
                count: payload.sampleBytes.count
            )
            destination.copyMemory(from: sourceBytes)
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
    private var pendingWriteCount = 0
    private var firstFailure: Error?
    private var hasLoggedFailure = false

    func start(writer: AudioFileWriter) {
        stateLock.lock()
        self.writer = writer
        isAcceptingWrites = true
        pendingWriteCount = 0
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

        pendingWriteCount += 1
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

    func finish() {
        stateLock.lock()
        isAcceptingWrites = false
        writer = nil
        stateLock.unlock()

        pendingWrites.wait()
    }

    private func completePendingWrite() {
        stateLock.lock()
        pendingWriteCount -= 1
        stateLock.unlock()
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
    case missingChannelData
}
