import AVFoundation
import CoreAudio
import Foundation
import os.log

private let recordingLog = OSLog(subsystem: "com.zachlatta.freeflow", category: "Recording")

struct AudioDevice: Identifiable {
    let id: AudioDeviceID
    let uid: String
    let name: String

    static func availableInputDevices() -> [AudioDevice] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            &dataSize
        )
        guard status == noErr, dataSize > 0 else { return [] }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            &dataSize,
            &deviceIDs
        )
        guard status == noErr else { return [] }

        var devices: [AudioDevice] = []
        for deviceID in deviceIDs {
            // Check if device has input streams
            var inputStreamAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(deviceID, &inputStreamAddress, 0, nil, &streamSize) == noErr,
                  streamSize > 0 else { continue }

            let bufferListRaw = UnsafeMutableRawPointer.allocate(
                byteCount: Int(streamSize),
                alignment: MemoryLayout<AudioBufferList>.alignment
            )
            defer { bufferListRaw.deallocate() }
            let bufferListPointer = bufferListRaw.bindMemory(to: AudioBufferList.self, capacity: 1)
            guard AudioObjectGetPropertyData(deviceID, &inputStreamAddress, 0, nil, &streamSize, bufferListPointer) == noErr else { continue }

            let bufferList = UnsafeMutableAudioBufferListPointer(bufferListPointer)
            let inputChannels = bufferList.reduce(0) { $0 + Int($1.mNumberChannels) }
            guard inputChannels > 0 else { continue }

            // Get device UID
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var uidSize = UInt32(MemoryLayout<CFString?>.size)
            let uidRaw = UnsafeMutableRawPointer.allocate(
                byteCount: Int(uidSize),
                alignment: MemoryLayout<CFString?>.alignment
            )
            defer { uidRaw.deallocate() }
            guard AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, uidRaw) == noErr else { continue }
            guard let uidRef = uidRaw.load(as: CFString?.self) else { continue }
            let uid = uidRef as String
            guard !uid.isEmpty else { continue }

            // Get device name
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var nameSize = UInt32(MemoryLayout<CFString?>.size)
            let nameRaw = UnsafeMutableRawPointer.allocate(
                byteCount: Int(nameSize),
                alignment: MemoryLayout<CFString?>.alignment
            )
            defer { nameRaw.deallocate() }
            guard AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, nameRaw) == noErr else { continue }
            guard let nameRef = nameRaw.load(as: CFString?.self) else { continue }
            let name = nameRef as String
            guard !name.isEmpty else { continue }

            devices.append(AudioDevice(id: deviceID, uid: uid, name: name))
        }
        return devices
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        // Look up through the enumerated devices to avoid CFString pointer issues
        return availableInputDevices().first(where: { $0.uid == uid })?.id
    }
}

enum AudioRecorderError: LocalizedError {
    case invalidInputFormat(String)
    case missingInputDevice

    var errorDescription: String? {
        switch self {
        case .invalidInputFormat(let details):
            return "Invalid input format: \(details)"
        case .missingInputDevice:
            return "No audio input device available."
        }
    }
}

class AudioRecorder: NSObject, ObservableObject {
    private var audioEngine: AVAudioEngine?
    private var tempFileURL: URL?
    private let writeCoordinator = AudioWriteCoordinator()
    private let inFlightTapCallbacks = DispatchGroup()
    private let didEncounterRecordingFailure = OSAllocatedUnfairLock(initialState: false)
    private var recordingStartTime: CFAbsoluteTime = 0
    private var firstBufferLogged = false
    private let _bufferCount = OSAllocatedUnfairLock(initialState: 0)
    private var currentDeviceUID: String?
    private var storedInputFormat: AVAudioFormat?

    @Published var isRecording = false
    /// Thread-safe flag read from the audio tap callback.
    private let _recording = OSAllocatedUnfairLock(initialState: false)
    @Published var audioLevel: Float = 0.0
    private var smoothedLevel: Float = 0.0

    /// Called on the audio thread when the first non-silent buffer arrives.
    var onRecordingReady: (() -> Void)?
    private var readyFired = false

    func startRecording(deviceUID: String? = nil) throws {
        let t0 = CFAbsoluteTimeGetCurrent()
        recordingStartTime = t0
        firstBufferLogged = false
        readyFired = false
        didEncounterRecordingFailure.withLock { $0 = false }
        _bufferCount.withLock { $0 = 0 }

        os_log(.info, log: recordingLog, "startRecording() entered")

        guard AVCaptureDevice.default(for: .audio) != nil else {
            throw AudioRecorderError.missingInputDevice
        }
        os_log(.info, log: recordingLog, "AVCaptureDevice check: %.3fms", (CFAbsoluteTimeGetCurrent() - t0) * 1000)

        let engineNeedsRebuild = audioEngine == nil || currentDeviceUID != deviceUID || !(audioEngine?.isRunning ?? false)

        if engineNeedsRebuild {
            if audioEngine != nil {
                audioEngine?.inputNode.removeTap(onBus: 0)
                audioEngine?.stop()
                audioEngine = nil
            }

            let engine = AVAudioEngine()
            os_log(.info, log: recordingLog, "AVAudioEngine created: %.3fms", (CFAbsoluteTimeGetCurrent() - t0) * 1000)

            // Set specific input device if requested
            if let uid = deviceUID, !uid.isEmpty, uid != "default",
               let deviceID = AudioDevice.deviceID(forUID: uid) {
                os_log(.info, log: recordingLog, "device lookup resolved to %d: %.3fms", deviceID, (CFAbsoluteTimeGetCurrent() - t0) * 1000)
                guard let inputUnit = engine.inputNode.audioUnit else {
                    throw AudioRecorderError.invalidInputFormat("Audio unit not available on input node")
                }
                var id = deviceID
                AudioUnitSetProperty(
                    inputUnit,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global,
                    0,
                    &id,
                    UInt32(MemoryLayout<AudioDeviceID>.size)
                )
            }

            let inputNode = engine.inputNode
            os_log(.info, log: recordingLog, "inputNode accessed: %.3fms", (CFAbsoluteTimeGetCurrent() - t0) * 1000)
            let hardwareInputFormat = inputNode.outputFormat(forBus: 0)
            os_log(.info, log: recordingLog, "inputFormat retrieved (rate=%.0f, ch=%d): %.3fms", hardwareInputFormat.sampleRate, hardwareInputFormat.channelCount, (CFAbsoluteTimeGetCurrent() - t0) * 1000)
            guard hardwareInputFormat.sampleRate > 0 else {
                throw AudioRecorderError.invalidInputFormat("Invalid sample rate: \(hardwareInputFormat.sampleRate)")
            }
            guard hardwareInputFormat.channelCount > 0 else {
                throw AudioRecorderError.invalidInputFormat("No input channels available")
            }
            guard let recordingFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: hardwareInputFormat.sampleRate,
                channels: hardwareInputFormat.channelCount,
                interleaved: false
            ) else {
                throw AudioRecorderError.invalidInputFormat("Could not create Float32 recording format")
            }

            storedInputFormat = recordingFormat

            // Install tap — checks isRecording and audioFile dynamically
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: recordingFormat) { [weak self] buffer, _ in
                guard let self else { return }

                self.inFlightTapCallbacks.enter()
                defer { self.inFlightTapCallbacks.leave() }

                guard self._recording.withLock({ $0 }) else { return }

                let currentBufferCount = self._bufferCount.withLock { count -> Int in
                    count += 1
                    return count
                }

                // Check if this buffer has real audio
                var rms: Float = 0
                let frames = Int(buffer.frameLength)
                if frames > 0, let channelData = buffer.floatChannelData {
                    let samples = channelData[0]
                    var sum: Float = 0
                    for i in 0..<frames { sum += samples[i] * samples[i] }
                    rms = sqrtf(sum / Float(frames))
                }

                if currentBufferCount <= 40 {
                    let elapsed = (CFAbsoluteTimeGetCurrent() - self.recordingStartTime) * 1000
                    os_log(.info, log: recordingLog, "buffer #%d at %.3fms, frames=%d, rms=%.6f", currentBufferCount, elapsed, buffer.frameLength, rms)
                }

                // Fire ready callback on first non-silent buffer
                if !self.readyFired && rms > 0 {
                    self.readyFired = true
                    let elapsed = (CFAbsoluteTimeGetCurrent() - self.recordingStartTime) * 1000
                    os_log(.info, log: recordingLog, "FIRST non-silent buffer at %.3fms — recording ready", elapsed)
                    let onRecordingReady = self.onRecordingReady
                    DispatchQueue.main.async {
                        onRecordingReady?()
                    }
                }

                do {
                    let payload = try AudioWritePayload(copying: buffer)
                    guard self.writeCoordinator.enqueueWrite(payload) else {
                        self.didEncounterRecordingFailure.withLock { $0 = true }
                        os_log(.error, log: recordingLog, "audio buffer rejected after write shutdown or failure")
                        return
                    }
                } catch {
                    self.didEncounterRecordingFailure.withLock { $0 = true }
                    os_log(.error, log: recordingLog, "failed to copy audio buffer for writing: %{public}@", String(describing: error))
                    return
                }
                self.computeAudioLevel(from: buffer)
            }
            os_log(.info, log: recordingLog, "tap installed: %.3fms", (CFAbsoluteTimeGetCurrent() - t0) * 1000)

            engine.prepare()
            os_log(.info, log: recordingLog, "engine prepared: %.3fms", (CFAbsoluteTimeGetCurrent() - t0) * 1000)

            self.audioEngine = engine
            self.currentDeviceUID = deviceUID
        }

        guard let inputFormat = storedInputFormat else {
            throw AudioRecorderError.invalidInputFormat("No stored input format")
        }

        // Create a temp file to write audio to
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent(UUID().uuidString + ".wav")
        self.tempFileURL = fileURL

        // Try the input format first to avoid conversion issues, then fall back to 16-bit PCM.
        let newAudioFile: AVAudioFile
        do {
            newAudioFile = try AVAudioFile(forWriting: fileURL, settings: inputFormat.settings)
        } catch {
            let fallbackSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: inputFormat.sampleRate,
                AVNumberOfChannelsKey: inputFormat.channelCount,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: inputFormat.isInterleaved ? 0 : 1,
            ]
            newAudioFile = try AVAudioFile(
                forWriting: fileURL,
                settings: fallbackSettings,
                commonFormat: .pcmFormatFloat32,
                interleaved: inputFormat.isInterleaved
            )
        }
        os_log(.info, log: recordingLog, "audio file created: %.3fms", (CFAbsoluteTimeGetCurrent() - t0) * 1000)

        writeCoordinator.start(writer: AVAudioFileWriterAdapter(file: newAudioFile))
        _recording.withLock { $0 = true }

        // Start engine if not already running after writer setup so initial buffers are captured.
        do {
            if let engine = audioEngine, !engine.isRunning {
                try engine.start()
                os_log(.info, log: recordingLog, "engine started: %.3fms", (CFAbsoluteTimeGetCurrent() - t0) * 1000)
            }
        } catch {
            _recording.withLock { $0 = false }
            try? writeCoordinator.finish()
            tempFileURL = nil
            throw error
        }

        self.isRecording = true

        os_log(.info, log: recordingLog, "startRecording() complete: %.3fms total", (CFAbsoluteTimeGetCurrent() - t0) * 1000)
    }

    func stopRecording() -> URL? {
        let finalBufferCount = _bufferCount.withLock { $0 }
        let elapsed = (CFAbsoluteTimeGetCurrent() - recordingStartTime) * 1000
        os_log(.info, log: recordingLog, "stopRecording() called: %.3fms after start, %d buffers received", elapsed, finalBufferCount)

        _recording.withLock { $0 = false }
        audioEngine?.inputNode.removeTap(onBus: 0)
        let waitResult = inFlightTapCallbacks.wait(timeout: .now() + 2.0)
        if waitResult == .timedOut {
            os_log(.error, log: recordingLog, "inFlightTapCallbacks.wait() timed out after 2s — proceeding with stop")
        }
        audioEngine?.stop()
        do {
            try writeCoordinator.finish()
        } catch {
            didEncounterRecordingFailure.withLock { $0 = true }
            os_log(.error, log: recordingLog, "audio write failed during stop: %{public}@", String(describing: error))
        }
        isRecording = false
        if didEncounterRecordingFailure.withLock({ $0 }) {
            smoothedLevel = 0.0
            DispatchQueue.main.async { self.audioLevel = 0.0 }
            return nil
        }
        smoothedLevel = 0.0
        DispatchQueue.main.async { self.audioLevel = 0.0 }

        os_log(.info, log: recordingLog, "engine stopped (mic indicator off)")

        return tempFileURL
    }

    private func computeAudioLevel(from buffer: AVAudioPCMBuffer) {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }

        let rms: Float
        if let channelData = buffer.floatChannelData {
            rms = rootMeanSquare(from: channelData[0], frameCount: frames)
        } else if let channelData = buffer.int16ChannelData {
            rms = rootMeanSquare(from: channelData[0], frameCount: frames)
        } else {
            return
        }

        let scaled = min(rms * 10.0, 1.0)

        if scaled > smoothedLevel {
            smoothedLevel = smoothedLevel * 0.3 + scaled * 0.7
        } else {
            smoothedLevel = smoothedLevel * 0.6 + scaled * 0.4
        }

        DispatchQueue.main.async {
            self.audioLevel = self.smoothedLevel
        }
    }

    private func rootMeanSquare(from samples: UnsafePointer<Float>, frameCount: Int) -> Float {
        var sumOfSquares: Float = 0.0
        for index in 0..<frameCount {
            let sample = samples[index]
            sumOfSquares += sample * sample
        }
        return sqrtf(sumOfSquares / Float(frameCount))
    }

    private func rootMeanSquare(from samples: UnsafePointer<Int16>, frameCount: Int) -> Float {
        var sumOfSquares: Float = 0.0
        for index in 0..<frameCount {
            let sample = Float(samples[index]) / Float(Int16.max)
            sumOfSquares += sample * sample
        }
        return sqrtf(sumOfSquares / Float(frameCount))
    }

    func cleanup() {
        if let url = tempFileURL {
            try? FileManager.default.removeItem(at: url)
            tempFileURL = nil
        }
    }
}
