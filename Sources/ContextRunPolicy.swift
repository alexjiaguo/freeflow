import Foundation

struct AppStateContextRunPolicy: Equatable {
    let allowsContextAnalysis: Bool

    init(allowsContextAnalysis: Bool) {
        self.allowsContextAnalysis = allowsContextAnalysis
    }

    var shouldCollectContext: Bool { allowsContextAnalysis }
    var disabledStatusText: String { "Context analysis skipped" }
    var disabledScreenshotStatus: String { "Context analysis skipped" }

    struct RuntimeDecision: Equatable {
        let shouldCreateContextCaptureTask: Bool
        let shouldCollectScreenshot: Bool
        let shouldCollectWindowMetadata: Bool
        let shouldCreateFallbackContext: Bool
        let shouldAllowFallbackContext: Bool
        let shouldPostProcessWithoutContext: Bool
        let statusText: String?
    }

    static func runtimeDecisionForTests(allowsContextAnalysis: Bool) -> RuntimeDecision {
        if allowsContextAnalysis {
            return RuntimeDecision(
                shouldCreateContextCaptureTask: true,
                shouldCollectScreenshot: true,
                shouldCollectWindowMetadata: true,
                shouldCreateFallbackContext: false,
                shouldAllowFallbackContext: true,
                shouldPostProcessWithoutContext: false,
                statusText: nil
            )
        } else {
            return RuntimeDecision(
                shouldCreateContextCaptureTask: false,
                shouldCollectScreenshot: false,
                shouldCollectWindowMetadata: false,
                shouldCreateFallbackContext: false,
                shouldAllowFallbackContext: false,
                shouldPostProcessWithoutContext: true,
                statusText: "Context analysis skipped"
            )
        }
    }

    static func snapshottedForRunStart(initialAllowsContextAnalysis: Bool) -> SnapshottedRun {
        SnapshottedRun(snapshotAllowsContextAnalysis: initialAllowsContextAnalysis)
    }

    struct SnapshottedRun: Equatable {
        let snapshotAllowsContextAnalysis: Bool

        func runtimeDecisionAfterSettingChangeForTests(newAllowsContextAnalysis: Bool) -> RuntimeDecision {
            AppStateContextRunPolicy.runtimeDecisionForTests(
                allowsContextAnalysis: snapshotAllowsContextAnalysis
            )
        }
    }

    struct ClearedState: Equatable {
        let contextSummary: String
        let screenshotStatus: String
        let screenshotDataURL: String?
        let contextPrompt: String?
        let hasContextObject: Bool
        let hasInFlightContextTask: Bool
    }

    static func clearedStateForDisabledRunForTests(
        previousSummary: String,
        previousPrompt: String,
        previousScreenshotStatus: String,
        previousScreenshotDataURL: String,
        previousHasContextObject: Bool,
        previousHasInFlightContextTask: Bool
    ) -> ClearedState {
        ClearedState(
            contextSummary: "Context analysis skipped",
            screenshotStatus: "Context analysis skipped",
            screenshotDataURL: nil,
            contextPrompt: nil,
            hasContextObject: false,
            hasInFlightContextTask: false
        )
    }
}

// MARK: - Fallback Context Status Message

struct FallbackContextStatusMessage {
    static func resolve(
        contextAnalysisEnabled: Bool,
        hasWindowTextContext: Bool
    ) -> String {
        if !contextAnalysisEnabled && hasWindowTextContext {
            return "Screenshot analysis skipped; using app/window text only"
        }
        return "Could not refresh app context at stop time; using text-only post-processing."
    }

    static func normalContextSummary(
        appName: String,
        windowTitle: String?,
        selectedText: String?
    ) -> String {
        if let windowTitle {
            return "\(appName) — \(windowTitle)"
        }
        return appName
    }
}
