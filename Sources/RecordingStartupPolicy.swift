import Foundation

struct RecordingStartupPolicy {
    let timeoutSeconds: TimeInterval = 4

    enum OverlapDecision: Equatable {
        case ignoreNewTrigger
        case startNewAttempt
    }

    func overlapDecision(isStartupInProgress: Bool) -> OverlapDecision {
        isStartupInProgress ? .ignoreNewTrigger : .startNewAttempt
    }
}

enum RecordingStartupFailureReason: Equatable {
    case microphonePermissionDenied
    case permissionBlocked(details: String)
    case timeout
    case general(String)
}

struct RecordingStartupAttemptState: Equatable {
    let currentAttemptID: String?
    let isStarting: Bool
    let isRecording: Bool
    let shouldDismissOverlay: Bool
    let statusText: String?
    let errorMessage: String?

    static let idle = RecordingStartupAttemptState(
        currentAttemptID: nil,
        isStarting: false,
        isRecording: false,
        shouldDismissOverlay: false,
        statusText: nil,
        errorMessage: nil
    )

    enum StartRequestDecision: Equatable {
        case ignore
        case allow
    }

    func startingNewAttempt(id: String) -> RecordingStartupAttemptState {
        RecordingStartupAttemptState(
            currentAttemptID: id,
            isStarting: true,
            isRecording: false,
            shouldDismissOverlay: false,
            statusText: nil,
            errorMessage: nil
        )
    }

    func startRequestDecision(for id: String) -> StartRequestDecision {
        isStarting ? .ignore : .allow
    }

    func shouldAcceptCompletion(for id: String) -> Bool {
        currentAttemptID == id
    }

    func cancelledAttempt(id: String) -> RecordingStartupAttemptState {
        guard currentAttemptID == id else { return self }
        return RecordingStartupAttemptState(
            currentAttemptID: nil,
            isStarting: false,
            isRecording: false,
            shouldDismissOverlay: true,
            statusText: nil,
            errorMessage: nil
        )
    }

    func timedOutAttempt(id: String) -> RecordingStartupAttemptState {
        guard currentAttemptID == id else { return self }
        return RecordingStartupAttemptState(
            currentAttemptID: nil,
            isStarting: false,
            isRecording: false,
            shouldDismissOverlay: true,
            statusText: "Error",
            errorMessage: "Recording start timed out. Please try again."
        )
    }

    func failedAttempt(id: String, reason: RecordingStartupFailureReason) -> RecordingStartupAttemptState {
        guard currentAttemptID == id else { return self }
        let message: String
        switch reason {
        case .microphonePermissionDenied:
            message = "Microphone access is required to start recording."
        case .permissionBlocked:
            message = "Recording permission is required to start recording."
        case .timeout:
            message = "Recording start timed out. Please try again."
        case .general(let detail):
            message = detail
        }
        return RecordingStartupAttemptState(
            currentAttemptID: nil,
            isStarting: false,
            isRecording: false,
            shouldDismissOverlay: true,
            statusText: "Error",
            errorMessage: message
        )
    }

    func completedAttempt(id: String) -> RecordingStartupAttemptState {
        guard currentAttemptID == id else { return self }
        return RecordingStartupAttemptState(
            currentAttemptID: id,
            isStarting: false,
            isRecording: true,
            shouldDismissOverlay: false,
            statusText: nil,
            errorMessage: nil
        )
    }
}

struct RecordingStartupResetState: Equatable {
    let isRecording: Bool
    let activeTriggerMode: String?
    let shouldDismissOverlay: Bool
    let statusText: String?

    static func timeoutReset() -> RecordingStartupResetState {
        RecordingStartupResetState(
            isRecording: false,
            activeTriggerMode: nil,
            shouldDismissOverlay: true,
            statusText: "Error"
        )
    }

    static func failedStartupReset() -> RecordingStartupResetState {
        RecordingStartupResetState(
            isRecording: false,
            activeTriggerMode: nil,
            shouldDismissOverlay: true,
            statusText: "Error"
        )
    }
}

struct AudioRecorderStartupContract: Equatable {
    let engineStarted: Bool
    let tapInstalled: Bool
    let writerReady: Bool

    var isReady: Bool {
        engineStarted && tapInstalled && writerReady
    }
}

struct AudioRecorderStartupResetState: Equatable {
    let isRecording: Bool
    let hasActiveEngine: Bool
    let hasInstalledTap: Bool
    let hasWriter: Bool

    static func failedStartupReset() -> AudioRecorderStartupResetState {
        AudioRecorderStartupResetState(
            isRecording: false,
            hasActiveEngine: false,
            hasInstalledTap: false,
            hasWriter: false
        )
    }
}
