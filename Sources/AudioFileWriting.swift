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
        let bytesPerFrame = Int(formatDescription.mBytesPerFrame)
        let byteCount = Int(frameLength) * bytesPerFrame

        let sampleBytes: Data
        if let channelData = buffer.floatChannelData {
            let firstChannel = channelData[0]
            sampleBytes = Data(bytes: firstChannel, count: byteCount)
        } else {
            sampleBytes = Data()
        }

        self.init(
            formatDescription: formatDescription,
            channelCount: channelCount,
            frameLength: frameLength,
            sampleBytes: sampleBytes
        )
    }
}

final class AudioWriteCoordinator {
    private let stateLock = NSLock()
    private let writeQueue = DispatchQueue(label: "AudioWriteCoordinator.writeQueue")
    private let pendingWrites = DispatchGroup()

    private var writer: AudioFileWriter?
    private var isAcceptingWrites = false
    private var pendingWriteCount = 0

    func start(writer: AudioFileWriter) {
        stateLock.lock()
        self.writer = writer
        isAcceptingWrites = true
        pendingWriteCount = 0
        stateLock.unlock()
    }

    func enqueueWrite(_ payload: AudioWritePayload) -> Bool {
        let activeWriter: AudioFileWriter?

        stateLock.lock()
        guard isAcceptingWrites, let writer else {
            stateLock.unlock()
            return false
        }

        pendingWriteCount += 1
        activeWriter = writer
        pendingWrites.enter()
        stateLock.unlock()

        writeQueue.async { [weak self] in
            defer {
                self?.stateLock.lock()
                if let self {
                    self.pendingWriteCount -= 1
                    self.stateLock.unlock()
                } else {
                    self?.stateLock.unlock()
                }
                self?.pendingWrites.leave()
            }

            try? activeWriter?.write(payload)
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
}
