import XCTest
@testable import AudioWriterHarness

// MARK: - Plan 1: Recording Start Reliability

// Task 1: Bounded Startup Attempt Policy

final class RecordingStartupPolicyTests: XCTestCase {
    func test_recordingStartupPolicyUsesFourSecondTimeout() {
        let policy = RecordingStartupPolicy()
        XCTAssertEqual(policy.timeoutSeconds, 4)
    }

    func test_recordingStartupPolicyIgnoresOverlappingStartTrigger() {
        let policy = RecordingStartupPolicy()
        let decision = policy.overlapDecision(isStartupInProgress: true)
        XCTAssertEqual(decision, .ignoreNewTrigger)
    }

    func test_recordingStartupPolicyAllowsSingleFreshAttempt() {
        let policy = RecordingStartupPolicy()
        let decision = policy.overlapDecision(isStartupInProgress: false)
        XCTAssertEqual(decision, .startNewAttempt)
    }
}

// Task 2: Centralized Startup Attempt Ownership

final class RecordingStartupAttemptStateTests: XCTestCase {
    func test_recordingStartupAttemptCreatesAuthoritativeAttemptState() {
        let state = RecordingStartupAttemptState.idle
        let updated = state.startingNewAttempt(id: "attempt-1")
        XCTAssertTrue(updated.isStarting)
        XCTAssertEqual(updated.currentAttemptID, "attempt-1")
    }

    func test_recordingStartupAttemptIgnoresSecondStartWhileInProgress() {
        let state = RecordingStartupAttemptState(
            currentAttemptID: "attempt-1",
            isStarting: true,
            isRecording: false,
            shouldDismissOverlay: false,
            statusText: nil,
            errorMessage: nil
        )
        let decision = state.startRequestDecision(for: "attempt-2")
        XCTAssertEqual(decision, .ignore)
    }

    func test_recordingStartupAttemptRejectsStaleCompletion() {
        let state = RecordingStartupAttemptState(
            currentAttemptID: "attempt-2",
            isStarting: true,
            isRecording: false,
            shouldDismissOverlay: false,
            statusText: nil,
            errorMessage: nil
        )
        XCTAssertFalse(state.shouldAcceptCompletion(for: "attempt-1"))
        XCTAssertTrue(state.shouldAcceptCompletion(for: "attempt-2"))
    }

    func test_recordingStartupAttemptCancelClearsAttemptOwnership() {
        let state = RecordingStartupAttemptState(
            currentAttemptID: "attempt-1",
            isStarting: true,
            isRecording: false,
            shouldDismissOverlay: false,
            statusText: nil,
            errorMessage: nil
        )
        let cancelled = state.cancelledAttempt(id: "attempt-1")
        XCTAssertFalse(cancelled.isStarting)
        XCTAssertNil(cancelled.currentAttemptID)
        XCTAssertTrue(cancelled.shouldDismissOverlay)
    }
}

// Task 3: Timeout, Permission Failure, and Idle Reset

final class RecordingStartupTimeoutTests: XCTestCase {
    func test_recordingStartupTimeoutTransitionsAttemptToFailure() {
        let state = RecordingStartupAttemptState(
            currentAttemptID: "attempt-1",
            isStarting: true,
            isRecording: false,
            shouldDismissOverlay: false,
            statusText: nil,
            errorMessage: nil
        )
        let timedOut = state.timedOutAttempt(id: "attempt-1")
        XCTAssertFalse(timedOut.isStarting)
        XCTAssertEqual(timedOut.statusText, "Error")
        XCTAssertEqual(timedOut.errorMessage, "Recording start timed out. Please try again.")
    }

    func test_recordingStartupPermissionFailureUsesExplicitMessageForIdentifiedPermissionBlock() {
        let state = RecordingStartupAttemptState(
            currentAttemptID: "attempt-1",
            isStarting: true,
            isRecording: false,
            shouldDismissOverlay: false,
            statusText: nil,
            errorMessage: nil
        )
        let microphoneDenied = state.failedAttempt(
            id: "attempt-1",
            reason: .microphonePermissionDenied
        )
        let permissionBlocked = state.failedAttempt(
            id: "attempt-1",
            reason: .permissionBlocked(details: "audio input unavailable without permission")
        )
        XCTAssertEqual(microphoneDenied.errorMessage, "Microphone access is required to start recording.")
        XCTAssertEqual(permissionBlocked.errorMessage, "Recording permission is required to start recording.")
    }

    func test_recordingStartupTimeoutClearsOverlayAndTriggerState() {
        let cleared = RecordingStartupResetState.timeoutReset()
        XCTAssertFalse(cleared.isRecording)
        XCTAssertNil(cleared.activeTriggerMode)
        XCTAssertTrue(cleared.shouldDismissOverlay)
    }
}

// Task 4: AudioRecorder Startup Contract

final class AudioRecorderStartupContractTests: XCTestCase {
    func test_audioRecorderStartupContractTreatsEngineStartedAsReadyWithoutWaitingForNonSilentAudio() {
        let contract = AudioRecorderStartupContract(
            engineStarted: true,
            tapInstalled: true,
            writerReady: true
        )
        XCTAssertTrue(contract.isReady)
    }

    func test_audioRecorderStartupContractNotReadyWhenEngineMissing() {
        let contract = AudioRecorderStartupContract(
            engineStarted: false,
            tapInstalled: true,
            writerReady: true
        )
        XCTAssertFalse(contract.isReady)
    }

    func test_audioRecorderStartupFailureResetClearsPartialState() {
        let reset = AudioRecorderStartupResetState.failedStartupReset()
        XCTAssertFalse(reset.isRecording)
        XCTAssertFalse(reset.hasActiveEngine)
        XCTAssertFalse(reset.hasInstalledTap)
        XCTAssertFalse(reset.hasWriter)
    }

    func test_recordingStartupAttemptSuccessAcceptsRecorderReadySignal() {
        let state = RecordingStartupAttemptState(
            currentAttemptID: "attempt-1",
            isStarting: true,
            isRecording: false,
            shouldDismissOverlay: false,
            statusText: nil,
            errorMessage: nil
        )
        let started = state.completedAttempt(id: "attempt-1")
        XCTAssertFalse(started.isStarting)
        XCTAssertTrue(started.isRecording)
        XCTAssertNil(started.errorMessage)
    }
}

// Task 5: Retry Paths

final class RecordingStartupRetryTests: XCTestCase {
    func test_recordingStartupFailureLeavesRetryableIdleState() {
        let failed = RecordingStartupResetState.failedStartupReset()
        XCTAssertFalse(failed.isRecording)
        XCTAssertNil(failed.activeTriggerMode)
        XCTAssertEqual(failed.statusText, "Error")
    }

    func test_recordingStartupRetryAfterTimeoutStartsFreshAttempt() {
        let state = RecordingStartupAttemptState.idle
            .startingNewAttempt(id: "attempt-1")
            .timedOutAttempt(id: "attempt-1")
        let retried = state.startingNewAttempt(id: "attempt-2")
        XCTAssertEqual(retried.currentAttemptID, "attempt-2")
        XCTAssertTrue(retried.isStarting)
    }

    func test_recordingStartupRetryAfterCancelStartsFreshAttempt() {
        let state = RecordingStartupAttemptState.idle
            .startingNewAttempt(id: "attempt-1")
            .cancelledAttempt(id: "attempt-1")
        let retried = state.startingNewAttempt(id: "attempt-2")
        XCTAssertEqual(retried.currentAttemptID, "attempt-2")
        XCTAssertTrue(retried.isStarting)
    }
}

// MARK: - Plan 2: No Context When Analysis Disabled

// Task 1: No-Context Post-Processing Contract

final class PostProcessingNoContextTests: XCTestCase {
    func test_postProcessingRequestOmitsContextFieldsWhenContextIsDisabled() throws {
        let requestBody = try PostProcessingService.requestBodyForTests(
            transcript: "hello world",
            context: nil,
            customVocabulary: [],
            customSystemPrompt: ""
        )
        let messages = try XCTUnwrap(requestBody["messages"] as? [[String: Any]])
        let userContent = try XCTUnwrap(messages.last?["content"] as? String)
        XCTAssertFalse(userContent.contains("CONTEXT:"))
        XCTAssertFalse(userContent.contains("SCREENSHOT"))
    }

    func test_postProcessingRequestIncludesContextFieldsWhenProvided() throws {
        let context = AppContext(
            appName: "Xcode",
            bundleIdentifier: "com.apple.dt.Xcode",
            windowTitle: "AppState.swift",
            selectedText: nil,
            currentActivity: "Editing app state",
            contextPrompt: "Context prompt",
            screenshotDataURL: nil,
            screenshotMimeType: nil,
            screenshotError: nil
        )
        let requestBody = try PostProcessingService.requestBodyForTests(
            transcript: "hello world",
            context: context,
            customVocabulary: [],
            customSystemPrompt: ""
        )
        let messages = try XCTUnwrap(requestBody["messages"] as? [[String: Any]])
        let userContent = try XCTUnwrap(messages.last?["content"] as? String)
        XCTAssertTrue(userContent.contains("CONTEXT:"))
    }
}

// Task 2: AppState Context Run Policy

final class ContextRunPolicyTests: XCTestCase {
    func test_noContextPolicyForDisabledAnalysisSkipsEntireStage() {
        let policy = AppStateContextRunPolicy(allowsContextAnalysis: false)
        XCTAssertFalse(policy.shouldCollectContext)
        XCTAssertEqual(policy.disabledStatusText, "Context analysis skipped")
    }

    func test_noContextPolicyForEnabledAnalysisKeepsContextStage() {
        let policy = AppStateContextRunPolicy(allowsContextAnalysis: true)
        XCTAssertTrue(policy.shouldCollectContext)
    }

    func test_disabledRunBypassesContextCollectorsAndPostProcessesWithoutContext() {
        let result = AppStateContextRunPolicy.runtimeDecisionForTests(allowsContextAnalysis: false)
        XCTAssertFalse(result.shouldCreateContextCaptureTask)
        XCTAssertFalse(result.shouldCollectScreenshot)
        XCTAssertFalse(result.shouldCollectWindowMetadata)
        XCTAssertFalse(result.shouldCreateFallbackContext)
        XCTAssertTrue(result.shouldPostProcessWithoutContext)
        XCTAssertEqual(result.statusText, "Context analysis skipped")
    }

    func test_enabledRunKeepsNormalContextPipeline() {
        let result = AppStateContextRunPolicy.runtimeDecisionForTests(allowsContextAnalysis: true)
        XCTAssertTrue(result.shouldCreateContextCaptureTask)
        XCTAssertTrue(result.shouldAllowFallbackContext)
        XCTAssertFalse(result.shouldPostProcessWithoutContext)
    }

    func test_toggleChangeMidRunDoesNotChangeSnapshottedRunBehavior() {
        let startedDisabled = AppStateContextRunPolicy.snapshottedForRunStart(
            initialAllowsContextAnalysis: false
        )
        let afterToggle = startedDisabled.runtimeDecisionAfterSettingChangeForTests(
            newAllowsContextAnalysis: true
        )
        XCTAssertFalse(afterToggle.shouldCreateContextCaptureTask)
        XCTAssertTrue(afterToggle.shouldPostProcessWithoutContext)
    }
}

// Task 3: Stale Context Guard

final class StaleContextGuardTests: XCTestCase {
    func test_disabledRunAfterEnabledRunClearsStaleContextState() {
        let result = AppStateContextRunPolicy.clearedStateForDisabledRunForTests(
            previousSummary: "Editing app state",
            previousPrompt: "Context prompt",
            previousScreenshotStatus: "available (image/jpeg)",
            previousScreenshotDataURL: "data:image/jpeg;base64,abc",
            previousHasContextObject: true,
            previousHasInFlightContextTask: true
        )
        XCTAssertEqual(result.contextSummary, "Context analysis skipped")
        XCTAssertEqual(result.screenshotStatus, "Context analysis skipped")
        XCTAssertNil(result.screenshotDataURL)
        XCTAssertNil(result.contextPrompt)
        XCTAssertFalse(result.hasContextObject)
        XCTAssertFalse(result.hasInFlightContextTask)
    }
}

// MARK: - Plan 3: Text-Only Context Status

final class FallbackContextStatusMessageTests: XCTestCase {
    func test_fallbackContextStatusMessageUsesSkipMessageWhenAnalysisIsDisabled() {
        XCTAssertEqual(
            FallbackContextStatusMessage.resolve(
                contextAnalysisEnabled: false,
                hasWindowTextContext: true
            ),
            "Screenshot analysis skipped; using app/window text only"
        )
    }

    func test_fallbackContextStatusMessageUsesFailureMessageWhenAnalysisIsEnabled() {
        XCTAssertEqual(
            FallbackContextStatusMessage.resolve(
                contextAnalysisEnabled: true,
                hasWindowTextContext: true
            ),
            "Could not refresh app context at stop time; using text-only post-processing."
        )
    }

    func test_fallbackContextStatusMessageUsesFailureMessageWhenTextContextIsUnavailable() {
        XCTAssertEqual(
            FallbackContextStatusMessage.resolve(
                contextAnalysisEnabled: false,
                hasWindowTextContext: false
            ),
            "Could not refresh app context at stop time; using text-only post-processing."
        )
    }

    func test_appStateNormalContextPathDoesNotUseFallbackStatusMessages() {
        let normalContextSummary = FallbackContextStatusMessage.normalContextSummary(
            appName: "Xcode",
            windowTitle: "AppState.swift",
            selectedText: nil
        )
        XCTAssertEqual(normalContextSummary, "Xcode — AppState.swift")
        XCTAssertNotEqual(
            normalContextSummary,
            "Screenshot analysis skipped; using app/window text only"
        )
        XCTAssertNotEqual(
            normalContextSummary,
            "Could not refresh app context at stop time; using text-only post-processing."
        )
    }
}
