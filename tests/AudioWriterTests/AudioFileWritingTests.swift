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

    func test_finish_rejectsWritesAfterShutdownBegins() {
        let writer = BlockingAudioFileWriter()
        let coordinator = AudioWriteCoordinator()
        coordinator.start(writer: writer)

        XCTAssertTrue(coordinator.enqueueWrite(AudioWritePayload(copying: makeBuffer(samples: [0.1, 0.2]))))
        writer.waitUntilWriteStarts()

        let finishReturned = expectation(description: "finish returned")
        DispatchQueue.global(qos: .userInitiated).async {
            coordinator.finish()
            finishReturned.fulfill()
        }

        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertFalse(coordinator.enqueueWrite(AudioWritePayload(copying: makeBuffer(samples: [0.3, 0.4]))))

        writer.releaseWrite()

        wait(for: [finishReturned], timeout: 1.0)
        XCTAssertEqual(writer.completedWriteCount, 1)
    }

    func test_finishWithNoPendingWritesReturnsImmediately() {
        let coordinator = AudioWriteCoordinator()
        coordinator.start(writer: RecordingAudioFileWriter())

        let start = Date()
        coordinator.finish()

        XCTAssertLessThan(Date().timeIntervalSince(start), 0.1)
    }

    func test_finishIsIdempotent() {
        let coordinator = AudioWriteCoordinator()
        coordinator.start(writer: RecordingAudioFileWriter())

        coordinator.finish()

        let secondFinishStartedAt = Date()
        coordinator.finish()

        XCTAssertLessThan(Date().timeIntervalSince(secondFinishStartedAt), 0.1)
        XCTAssertFalse(coordinator.enqueueWrite(AudioWritePayload(copying: makeBuffer(samples: [0.1]))))
    }

    func test_writeFailureLatchesAndRejectsLaterWrites() throws {
        if ProcessInfo.processInfo.environment["AUDIO_WRITER_FAILURE_CHILD"] == "1" {
            let writer = FailingAudioFileWriter()
            let coordinator = AudioWriteCoordinator()
            coordinator.start(writer: writer)

            XCTAssertTrue(coordinator.enqueueWrite(AudioWritePayload(copying: makeBuffer(samples: [0.1, 0.2]))))
            writer.waitUntilWriteStarts()
            Thread.sleep(forTimeInterval: 0.1)
            XCTAssertFalse(coordinator.enqueueWrite(AudioWritePayload(copying: makeBuffer(samples: [0.3, 0.4]))))
            coordinator.finish()
            return
        }

        let process = Process()
        let fileManager = FileManager.default
        let outputURL = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("log")
        fileManager.createFile(atPath: outputURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        defer {
            try? outputHandle.close()
            try? fileManager.removeItem(at: outputURL)
        }

        process.executableURL = URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer/usr/bin/xctest")
        process.arguments = [
            "-XCTest",
            "AudioWriterTests.AudioFileWritingTests/test_writeFailureLatchesAndRejectsLaterWrites",
            Bundle(for: Self.self).bundlePath,
        ]
        process.currentDirectoryURL = URL(fileURLWithPath: "/Volumes/Download/ai-projects/temp/freeflow/.claude/worktrees/audio-writer")

        var environment = ProcessInfo.processInfo.environment
        environment["AUDIO_WRITER_FAILURE_CHILD"] = "1"
        process.environment = environment
        process.standardOutput = outputHandle
        process.standardError = outputHandle

        try process.run()
        process.waitUntilExit()

        let combinedOutput = try String(contentsOf: outputURL, encoding: .utf8)
        XCTAssertEqual(
            process.terminationStatus,
            0,
            "Expected the child scenario to pass once failure latching is implemented. Child output:\n\(combinedOutput)"
        )
    }

    func test_startAfterFinishResetsCoordinatorState() {
        let firstWriter = RecordingAudioFileWriter()
        let secondWriter = RecordingAudioFileWriter()
        let coordinator = AudioWriteCoordinator()

        coordinator.start(writer: firstWriter)
        XCTAssertTrue(coordinator.enqueueWrite(AudioWritePayload(copying: makeBuffer(samples: [0.1, 0.2]))))
        coordinator.finish()

        coordinator.start(writer: secondWriter)
        XCTAssertTrue(coordinator.enqueueWrite(AudioWritePayload(copying: makeBuffer(samples: [0.3, 0.4]))))
        coordinator.finish()

        XCTAssertEqual(firstWriter.writeCount, 1)
        XCTAssertEqual(secondWriter.writeCount, 1)
    }

    func test_enqueueWriteRacingWithFinishIsEitherAcceptedOrRejectedNeverLost() {
        let writer = RecordingAudioFileWriter()
        let coordinator = AudioWriteCoordinator()
        coordinator.start(writer: writer)

        let workQueue = DispatchQueue(label: "AudioFileWritingTests.race", attributes: .concurrent)
        let attemptGroup = DispatchGroup()
        let acceptedCount = LockedValue(0)
        let attemptCount = 100

        for index in 0..<attemptCount {
            attemptGroup.enter()
            workQueue.async {
                let accepted = coordinator.enqueueWrite(AudioWritePayload(copying: makeBuffer(samples: [Float(index)])))
                if accepted {
                    acceptedCount.withValue { current in current + 1 }
                }
                attemptGroup.leave()
            }
        }

        workQueue.async {
            coordinator.finish()
        }

        XCTAssertEqual(attemptGroup.wait(timeout: .now() + 2.0), .success)

        coordinator.finish()

        XCTAssertEqual(writer.writeCount, acceptedCount.value)
        XCTAssertLessThanOrEqual(writer.writeCount, attemptCount)
    }
}

private final class BlockingAudioFileWriter: AudioFileWriter {
    private let writeStarted = DispatchSemaphore(value: 0)
    private let allowWriteToFinish = DispatchSemaphore(value: 0)
    private let completedWrites = LockedValue(0)

    var completedWriteCount: Int {
        completedWrites.value
    }

    func write(_ payload: AudioWritePayload) throws {
        writeStarted.signal()
        allowWriteToFinish.wait()
        completedWrites.setValue(completedWriteCount + 1)
    }

    func waitUntilWriteStarts() {
        _ = writeStarted.wait(timeout: .now() + 1.0)
    }

    func releaseWrite() {
        allowWriteToFinish.signal()
    }
}

private final class RecordingAudioFileWriter: AudioFileWriter {
    private let writes = LockedValue<[AudioWritePayload]>([])

    var writeCount: Int {
        writes.value.count
    }

    func write(_ payload: AudioWritePayload) throws {
        writes.withValue { current in
            current + [payload]
        }
    }
}

private enum StubWriteError: Error {
    case failed
}

private final class FailingAudioFileWriter: AudioFileWriter {
    private let writeStarted = DispatchSemaphore(value: 0)

    func write(_ payload: AudioWritePayload) throws {
        writeStarted.signal()
        throw StubWriteError.failed
    }

    func waitUntilWriteStarts() {
        _ = writeStarted.wait(timeout: .now() + 1.0)
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

    func withValue(_ transform: (Value) -> Value) {
        lock.lock()
        storage = transform(storage)
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
