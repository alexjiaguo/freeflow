import AVFoundation
import XCTest
@testable import AudioWriterHarness

final class AudioFileWritingTests: XCTestCase {
    func test_finish_waits_forAcceptedWriteToComplete() {
        let writer = BlockingAudioFileWriter()
        let coordinator = AudioWriteCoordinator()
        coordinator.start(writer: writer)

        let payload = AudioWritePayload(copying: makeBuffer(samples: [0.1, 0.2, 0.3, 0.4]))
        XCTAssertTrue(coordinator.enqueueWrite(payload))

        writer.waitUntilWriteStarts()

        let finishReturned = expectation(description: "finish returned")
        let finishState = LockedValue(false)

        DispatchQueue.global(qos: .userInitiated).async {
            coordinator.finish()
            finishState.setValue(true)
            finishReturned.fulfill()
        }

        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertFalse(finishState.value)

        writer.releaseWrite()

        wait(for: [finishReturned], timeout: 1.0)
    }

    func test_payloadCopyPreservesReconstructionInvariantsAfterSourceBufferMutation() throws {
        let buffer = makeBuffer(samples: [0.25, -0.5, 0.75, -1.0])
        let originalStreamDescription = buffer.format.streamDescription.pointee
        let originalBytes = sampleBytes(from: buffer)

        let payload = AudioWritePayload(copying: buffer)

        overwrite(buffer: buffer, with: [1.0, 1.0, 1.0, 1.0])

        XCTAssertEqual(payload.frameLength, 4)
        XCTAssertEqual(payload.channelCount, buffer.format.channelCount)
        XCTAssertEqual(payload.formatDescription.mSampleRate, originalStreamDescription.mSampleRate)
        XCTAssertEqual(payload.formatDescription.mFormatID, originalStreamDescription.mFormatID)
        XCTAssertEqual(payload.formatDescription.mBytesPerFrame, originalStreamDescription.mBytesPerFrame)
        XCTAssertEqual(payload.sampleBytes, originalBytes)
    }
}

private final class BlockingAudioFileWriter: AudioFileWriter {
    private let writeStarted = DispatchSemaphore(value: 0)
    private let allowWriteToFinish = DispatchSemaphore(value: 0)

    func write(_ payload: AudioWritePayload) throws {
        writeStarted.signal()
        allowWriteToFinish.wait()
    }

    func waitUntilWriteStarts() {
        _ = writeStarted.wait(timeout: .now() + 1.0)
    }

    func releaseWrite() {
        allowWriteToFinish.signal()
    }
}

private final class LockedValue<Value> {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func setValue(_ newValue: Value) {
        lock.lock()
        storage = newValue
        lock.unlock()
    }
}

private func makeBuffer(samples: [Float]) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
    buffer.frameLength = AVAudioFrameCount(samples.count)

    guard let channelData = buffer.floatChannelData else {
        XCTFail("Expected float channel data")
        return buffer
    }

    for (index, sample) in samples.enumerated() {
        channelData[0][index] = sample
    }

    return buffer
}

private func overwrite(buffer: AVAudioPCMBuffer, with samples: [Float]) {
    guard let channelData = buffer.floatChannelData else {
        XCTFail("Expected float channel data")
        return
    }

    for (index, sample) in samples.enumerated() {
        channelData[0][index] = sample
    }
}

private func sampleBytes(from buffer: AVAudioPCMBuffer) -> Data {
    guard let channelData = buffer.floatChannelData else {
        XCTFail("Expected float channel data")
        return Data()
    }

    let firstChannel = channelData[0]
    let byteCount = Int(buffer.frameLength) * MemoryLayout<Float>.size
    return Data(bytes: firstChannel, count: byteCount)
}
