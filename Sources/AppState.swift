import Foundation
import Combine
import AppKit
import AVFoundation
import CoreAudio
import ServiceManagement
import ApplicationServices
import ScreenCaptureKit
import os.log

private let recordingLog = OSLog(subsystem: "com.zachlatta.freeflow", category: "Recording")

enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case prompts
    case runLog

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .prompts: return "Prompts"
        case .runLog: return "Run Log"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .prompts: return "text.bubble"
        case .runLog: return "clock.arrow.circlepath"
        }
    }
}

private struct PreservedPasteboardEntry {
    let type: NSPasteboard.PasteboardType
    let value: Value

    enum Value {
        case string(String)
        case propertyList(Any)
        case data(Data)
    }
}

private struct PreservedPasteboardItem {
    let entries: [PreservedPasteboardEntry]

    init(item: NSPasteboardItem) {
        self.entries = item.types.compactMap { type in
            if let string = item.string(forType: type) {
                return PreservedPasteboardEntry(type: type, value: .string(string))
            }
            if let propertyList = item.propertyList(forType: type) {
                return PreservedPasteboardEntry(type: type, value: .propertyList(propertyList))
            }
            if let data = item.data(forType: type) {
                return PreservedPasteboardEntry(type: type, value: .data(data))
            }
            return nil
        }
    }

    func makePasteboardItem() -> NSPasteboardItem {
        let item = NSPasteboardItem()
        for entry in entries {
            switch entry.value {
            case .string(let string):
                item.setString(string, forType: entry.type)
            case .propertyList(let propertyList):
                item.setPropertyList(propertyList, forType: entry.type)
            case .data(let data):
                item.setData(data, forType: entry.type)
            }
        }
        return item
    }
}

private struct PreservedPasteboardSnapshot {
    let items: [PreservedPasteboardItem]

    init(pasteboard: NSPasteboard) {
        self.items = (pasteboard.pasteboardItems ?? []).map(PreservedPasteboardItem.init)
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        _ = pasteboard.writeObjects(items.map { $0.makePasteboardItem() })
    }
}

private struct PendingClipboardRestore {
    let snapshot: PreservedPasteboardSnapshot
    let expectedChangeCount: Int
}

/// All @Published properties must be accessed on the main thread.
/// Background work captures local values before dispatch and uses MainActor.run to update state.
@MainActor
final class AppState: ObservableObject {
    private let apiKeyStorageKey = "groq_api_key"
    private let apiBaseURLStorageKey = "api_base_url"
    private let holdShortcutStorageKey = "hold_shortcut"
    private let toggleShortcutStorageKey = "toggle_shortcut"
    private let savedHoldCustomShortcutStorageKey = "saved_hold_custom_shortcut"
    private let savedToggleCustomShortcutStorageKey = "saved_toggle_custom_shortcut"
    private let customVocabularyStorageKey = "custom_vocabulary"
    private let selectedMicrophoneStorageKey = "selected_microphone_id"
    private let customSystemPromptStorageKey = "custom_system_prompt"
    private let customContextPromptStorageKey = "custom_context_prompt"
    private let customSystemPromptLastModifiedStorageKey = "custom_system_prompt_last_modified"
    private let customContextPromptLastModifiedStorageKey = "custom_context_prompt_last_modified"
    private let shortcutStartDelayStorageKey = "shortcut_start_delay"
    private let preserveClipboardStorageKey = "preserve_clipboard"
    private let forceHTTP2TranscriptionStorageKey = "force_http2_transcription"
    private let soundVolumeStorageKey = "sound_volume"
    private let enableContextGatheringStorageKey = "enable_context_gathering"
    private let postProcessingModelStorageKey = "post_processing_model"
    private let transcriptionApiKeyStorageKey = "transcription_api_key"
    private let transcriptionBaseURLStorageKey = "transcription_base_url"
    private let transcriptionModelStorageKey = "transcription_model"
    private let contextAnalysisApiKeyStorageKey = "context_analysis_api_key"
    private let contextAnalysisBaseURLStorageKey = "context_analysis_base_url"
    private let contextAnalysisModelStorageKey = "context_analysis_model"
    private let postProcessingApiKeyStorageKey = "post_processing_api_key"
    private let postProcessingBaseURLStorageKey = "post_processing_base_url"
    static let defaultPostProcessingModel = "meta-llama/llama-4-scout-17b-16e-instruct"
    static let defaultTranscriptionModel = "whisper-large-v3"
    private let transcribingIndicatorDelay: TimeInterval = 1.0
    private let clipboardRestoreDelay: TimeInterval = 0.15
    let maxPipelineHistoryCount = 20

    @Published var hasCompletedSetup: Bool {
        didSet {
            UserDefaults.standard.set(hasCompletedSetup, forKey: "hasCompletedSetup")
        }
    }

    @Published var apiKey: String {
        didSet {
            persistAPIKey(apiKey)
            contextService = AppContextService(apiKey: resolvedContextAnalysisApiKey, baseURL: resolvedContextAnalysisBaseURL, customContextPrompt: customContextPrompt, model: resolvedContextAnalysisModel)
        }
    }

    @Published var apiBaseURL: String {
        didSet {
            persistAPIBaseURL(apiBaseURL)
            contextService = AppContextService(apiKey: resolvedContextAnalysisApiKey, baseURL: resolvedContextAnalysisBaseURL, customContextPrompt: customContextPrompt, model: resolvedContextAnalysisModel)
        }
    }

    @Published var holdShortcut: ShortcutBinding {
        didSet {
            persistShortcut(holdShortcut, key: holdShortcutStorageKey)
            restartHotkeyMonitoring()
        }
    }

    @Published var toggleShortcut: ShortcutBinding {
        didSet {
            persistShortcut(toggleShortcut, key: toggleShortcutStorageKey)
            restartHotkeyMonitoring()
        }
    }

    @Published private(set) var savedHoldCustomShortcut: ShortcutBinding? {
        didSet {
            persistOptionalShortcut(savedHoldCustomShortcut, key: savedHoldCustomShortcutStorageKey)
        }
    }

    @Published private(set) var savedToggleCustomShortcut: ShortcutBinding? {
        didSet {
            persistOptionalShortcut(savedToggleCustomShortcut, key: savedToggleCustomShortcutStorageKey)
        }
    }

    @Published var customVocabulary: String {
        didSet {
            UserDefaults.standard.set(customVocabulary, forKey: customVocabularyStorageKey)
        }
    }

    @Published var customSystemPrompt: String {
        didSet {
            UserDefaults.standard.set(customSystemPrompt, forKey: customSystemPromptStorageKey)
        }
    }

    @Published var customContextPrompt: String {
        didSet {
            UserDefaults.standard.set(customContextPrompt, forKey: customContextPromptStorageKey)
            contextService = AppContextService(apiKey: resolvedContextAnalysisApiKey, baseURL: resolvedContextAnalysisBaseURL, customContextPrompt: customContextPrompt, model: resolvedContextAnalysisModel)
        }
    }

    @Published var customSystemPromptLastModified: String {
        didSet {
            UserDefaults.standard.set(customSystemPromptLastModified, forKey: customSystemPromptLastModifiedStorageKey)
        }
    }

    @Published var customContextPromptLastModified: String {
        didSet {
            UserDefaults.standard.set(customContextPromptLastModified, forKey: customContextPromptLastModifiedStorageKey)
        }
    }

    @Published var shortcutStartDelay: TimeInterval {
        didSet {
            UserDefaults.standard.set(shortcutStartDelay, forKey: shortcutStartDelayStorageKey)
        }
    }

    @Published var preserveClipboard: Bool {
        didSet {
            UserDefaults.standard.set(preserveClipboard, forKey: preserveClipboardStorageKey)
        }
    }

    @Published var forceHTTP2Transcription: Bool {
        didSet {
            UserDefaults.standard.set(forceHTTP2Transcription, forKey: forceHTTP2TranscriptionStorageKey)
        }
    }

    @Published var soundVolume: Float {
        didSet {
            UserDefaults.standard.set(soundVolume, forKey: soundVolumeStorageKey)
        }
    }

    @Published var postProcessingModel: String {
        didSet {
            let trimmed = postProcessingModel.trimmingCharacters(in: .whitespacesAndNewlines)
            UserDefaults.standard.set(trimmed.isEmpty ? Self.defaultPostProcessingModel : trimmed, forKey: postProcessingModelStorageKey)
        }
    }

    @Published var transcriptionApiKey: String {
        didSet { UserDefaults.standard.set(transcriptionApiKey, forKey: transcriptionApiKeyStorageKey) }
    }
    @Published var transcriptionBaseURL: String {
        didSet { UserDefaults.standard.set(transcriptionBaseURL, forKey: transcriptionBaseURLStorageKey) }
    }
    @Published var transcriptionModel: String {
        didSet {
            let trimmed = transcriptionModel.trimmingCharacters(in: .whitespacesAndNewlines)
            UserDefaults.standard.set(trimmed.isEmpty ? Self.defaultTranscriptionModel : trimmed, forKey: transcriptionModelStorageKey)
        }
    }

    @Published var contextAnalysisApiKey: String {
        didSet {
            UserDefaults.standard.set(contextAnalysisApiKey, forKey: contextAnalysisApiKeyStorageKey)
            contextService = AppContextService(apiKey: resolvedContextAnalysisApiKey, baseURL: resolvedContextAnalysisBaseURL, customContextPrompt: customContextPrompt, model: resolvedContextAnalysisModel)
        }
    }
    @Published var contextAnalysisBaseURL: String {
        didSet {
            UserDefaults.standard.set(contextAnalysisBaseURL, forKey: contextAnalysisBaseURLStorageKey)
            contextService = AppContextService(apiKey: resolvedContextAnalysisApiKey, baseURL: resolvedContextAnalysisBaseURL, customContextPrompt: customContextPrompt, model: resolvedContextAnalysisModel)
        }
    }
    @Published var contextAnalysisModel: String {
        didSet {
            let trimmed = contextAnalysisModel.trimmingCharacters(in: .whitespacesAndNewlines)
            UserDefaults.standard.set(trimmed.isEmpty ? Self.defaultPostProcessingModel : trimmed, forKey: contextAnalysisModelStorageKey)
            contextService = AppContextService(apiKey: resolvedContextAnalysisApiKey, baseURL: resolvedContextAnalysisBaseURL, customContextPrompt: customContextPrompt, model: resolvedContextAnalysisModel)
        }
    }

    @Published var postProcessingApiKey: String {
        didSet { UserDefaults.standard.set(postProcessingApiKey, forKey: postProcessingApiKeyStorageKey) }
    }
    @Published var postProcessingBaseURL: String {
        didSet { UserDefaults.standard.set(postProcessingBaseURL, forKey: postProcessingBaseURLStorageKey) }
    }

    var resolvedTranscriptionApiKey: String {
        transcriptionApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? apiKey : transcriptionApiKey
    }
    var resolvedTranscriptionBaseURL: String {
        transcriptionBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? apiBaseURL : transcriptionBaseURL
    }
    var resolvedTranscriptionModel: String {
        let trimmed = transcriptionModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Self.defaultTranscriptionModel : trimmed
    }
    var resolvedContextAnalysisApiKey: String {
        contextAnalysisApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? apiKey : contextAnalysisApiKey
    }
    var resolvedContextAnalysisBaseURL: String {
        contextAnalysisBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? apiBaseURL : contextAnalysisBaseURL
    }
    var resolvedContextAnalysisModel: String {
        let trimmed = contextAnalysisModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Self.defaultPostProcessingModel : trimmed
    }
    var resolvedPostProcessingApiKey: String {
        postProcessingApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? apiKey : postProcessingApiKey
    }
    var resolvedPostProcessingBaseURL: String {
        postProcessingBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? apiBaseURL : postProcessingBaseURL
    }
    var resolvedPostProcessingModel: String {
        let trimmed = postProcessingModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Self.defaultPostProcessingModel : trimmed
    }

    @Published var enableContextGathering: Bool {
        didSet {
            UserDefaults.standard.set(enableContextGathering, forKey: enableContextGatheringStorageKey)
        }
    }

    @Published var isRecording = false
    @Published var isTranscribing = false
    @Published var retryingItemIDs: Set<UUID> = []
    @Published var lastTranscript: String = ""
    @Published var errorMessage: String?
    @Published var statusText: String = "Ready"
    @Published var hasAccessibility = false
    @Published var isDebugOverlayActive = false
    @Published var selectedSettingsTab: SettingsTab? = .general
    @Published var pipelineHistory: [PipelineHistoryItem] = []
    @Published var debugStatusMessage = "Idle"
    @Published var lastRawTranscript = ""
    @Published var lastPostProcessedTranscript = ""
    @Published var lastPostProcessingPrompt = ""
    @Published var lastContextSummary = ""
    @Published var lastPostProcessingStatus = ""
    @Published var lastContextScreenshotDataURL: String? = nil
    @Published var lastContextScreenshotStatus = "No screenshot"
    @Published var hasScreenRecordingPermission = false
    @Published var launchAtLogin: Bool {
        didSet { setLaunchAtLogin(launchAtLogin) }
    }

    @Published var selectedMicrophoneID: String {
        didSet {
            UserDefaults.standard.set(selectedMicrophoneID, forKey: selectedMicrophoneStorageKey)
        }
    }
    @Published var availableMicrophones: [AudioDevice] = []

    let audioRecorder = AudioRecorder()
    let hotkeyManager = HotkeyManager()
    let overlayManager = RecordingOverlayManager()
    private var accessibilityTimer: Timer?
    private var audioLevelCancellable: AnyCancellable?
    private var debugOverlayTimer: Timer?
    private var transcribingIndicatorTask: Task<Void, Never>?
    private var contextService: AppContextService
    private var contextCaptureTask: Task<AppContext?, Never>?
    private var capturedContext: AppContext?
    private var hasShownScreenshotPermissionAlert = false
    private var audioDeviceListenerBlock: AudioObjectPropertyListenerBlock?
    private let pipelineHistoryStore = PipelineHistoryStore()
    private let shortcutSessionController = DictationShortcutSessionController()
    private var activeRecordingTriggerMode: RecordingTriggerMode?
    private var pendingShortcutStartTask: Task<Void, Never>?
    private var pendingShortcutStartMode: RecordingTriggerMode?
    private var shouldMonitorHotkeys = false
    private var isCapturingShortcut = false
    private var startupAttemptState = RecordingStartupAttemptState.idle
    private var startupTimeoutTask: Task<Void, Never>?
    private let startupPolicy = RecordingStartupPolicy()

    init() {
        let hasCompletedSetup = UserDefaults.standard.bool(forKey: "hasCompletedSetup")
        let apiKey = Self.loadStoredAPIKey(account: apiKeyStorageKey)
        let apiBaseURL = Self.loadStoredAPIBaseURL(account: "api_base_url")
        let shortcuts = Self.loadShortcutConfiguration(
            holdKey: holdShortcutStorageKey,
            toggleKey: toggleShortcutStorageKey
        )
        let savedHoldCustomShortcut = Self.loadShortcut(forKey: savedHoldCustomShortcutStorageKey)
            ?? (shortcuts.hold.isCustom ? shortcuts.hold : nil)
        let savedToggleCustomShortcut = Self.loadShortcut(forKey: savedToggleCustomShortcutStorageKey)
            ?? (shortcuts.toggle.isCustom ? shortcuts.toggle : nil)
        let customVocabulary = UserDefaults.standard.string(forKey: customVocabularyStorageKey) ?? ""
        let customSystemPrompt = UserDefaults.standard.string(forKey: customSystemPromptStorageKey) ?? ""
        let customContextPrompt = UserDefaults.standard.string(forKey: customContextPromptStorageKey) ?? ""
        let customSystemPromptLastModified = UserDefaults.standard.string(forKey: customSystemPromptLastModifiedStorageKey) ?? ""
        let customContextPromptLastModified = UserDefaults.standard.string(forKey: customContextPromptLastModifiedStorageKey) ?? ""
        let shortcutStartDelay = max(0, UserDefaults.standard.double(forKey: shortcutStartDelayStorageKey))
        let preserveClipboard = UserDefaults.standard.object(forKey: preserveClipboardStorageKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: preserveClipboardStorageKey)
        let forceHTTP2Transcription = UserDefaults.standard.bool(forKey: forceHTTP2TranscriptionStorageKey)
        let soundVolume: Float = UserDefaults.standard.object(forKey: soundVolumeStorageKey) != nil
            ? UserDefaults.standard.float(forKey: soundVolumeStorageKey) : 1.0
        let storedModel = UserDefaults.standard.string(forKey: postProcessingModelStorageKey)
        let postProcessingModel: String = {
            guard let m = storedModel, !m.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return Self.defaultPostProcessingModel
            }
            return m
        }()
        let enableContextGathering = UserDefaults.standard.object(forKey: enableContextGatheringStorageKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: enableContextGatheringStorageKey)
        let transcriptionApiKey = UserDefaults.standard.string(forKey: transcriptionApiKeyStorageKey) ?? ""
        let transcriptionBaseURL = UserDefaults.standard.string(forKey: transcriptionBaseURLStorageKey) ?? ""
        let transcriptionModel = UserDefaults.standard.string(forKey: transcriptionModelStorageKey) ?? ""
        let contextAnalysisApiKey = UserDefaults.standard.string(forKey: contextAnalysisApiKeyStorageKey) ?? ""
        let contextAnalysisBaseURL = UserDefaults.standard.string(forKey: contextAnalysisBaseURLStorageKey) ?? ""
        let contextAnalysisModel = UserDefaults.standard.string(forKey: contextAnalysisModelStorageKey) ?? ""
        let postProcessingApiKey = UserDefaults.standard.string(forKey: postProcessingApiKeyStorageKey) ?? ""
        let postProcessingBaseURL = UserDefaults.standard.string(forKey: postProcessingBaseURLStorageKey) ?? ""

        let resolvedCtxApiKey = contextAnalysisApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? apiKey : contextAnalysisApiKey
        let resolvedCtxBaseURL = contextAnalysisBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? apiBaseURL : contextAnalysisBaseURL
        let resolvedCtxModel = contextAnalysisModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Self.defaultPostProcessingModel : contextAnalysisModel

        let initialAccessibility = AXIsProcessTrusted()
        let initialScreenCapturePermission = CGPreflightScreenCaptureAccess()
        var removedAudioFileNames: [String] = []
        do {
            removedAudioFileNames = try pipelineHistoryStore.trim(to: maxPipelineHistoryCount)
        } catch {
            print("Failed to trim pipeline history during init: \(error)")
        }
        for audioFileName in removedAudioFileNames {
            Self.deleteAudioFile(audioFileName)
        }
        let savedHistory = pipelineHistoryStore.loadAllHistory()

        let selectedMicrophoneID = UserDefaults.standard.string(forKey: selectedMicrophoneStorageKey) ?? "default"

        self.contextService = AppContextService(apiKey: resolvedCtxApiKey, baseURL: resolvedCtxBaseURL, customContextPrompt: customContextPrompt, model: resolvedCtxModel)
        self.hasCompletedSetup = hasCompletedSetup
        self.apiKey = apiKey
        self.apiBaseURL = apiBaseURL
        self.holdShortcut = shortcuts.hold
        self.toggleShortcut = shortcuts.toggle
        self.savedHoldCustomShortcut = savedHoldCustomShortcut
        self.savedToggleCustomShortcut = savedToggleCustomShortcut
        self.customVocabulary = customVocabulary
        self.customSystemPrompt = customSystemPrompt
        self.customContextPrompt = customContextPrompt
        self.customSystemPromptLastModified = customSystemPromptLastModified
        self.customContextPromptLastModified = customContextPromptLastModified
        self.shortcutStartDelay = shortcutStartDelay
        self.preserveClipboard = preserveClipboard
        self.forceHTTP2Transcription = forceHTTP2Transcription
        self.soundVolume = soundVolume
        self.postProcessingModel = postProcessingModel
        self.transcriptionApiKey = transcriptionApiKey
        self.transcriptionBaseURL = transcriptionBaseURL
        self.transcriptionModel = transcriptionModel
        self.contextAnalysisApiKey = contextAnalysisApiKey
        self.contextAnalysisBaseURL = contextAnalysisBaseURL
        self.contextAnalysisModel = contextAnalysisModel
        self.postProcessingApiKey = postProcessingApiKey
        self.postProcessingBaseURL = postProcessingBaseURL
        self.enableContextGathering = enableContextGathering
        self.pipelineHistory = savedHistory
        self.hasAccessibility = initialAccessibility
        self.hasScreenRecordingPermission = initialScreenCapturePermission
        self.launchAtLogin = SMAppService.mainApp.status == .enabled
        self.selectedMicrophoneID = selectedMicrophoneID

        refreshAvailableMicrophones()
        installAudioDeviceListener()

        if shortcuts.didMigrateLegacyValue {
            persistShortcut(shortcuts.hold, key: holdShortcutStorageKey)
            persistShortcut(shortcuts.toggle, key: toggleShortcutStorageKey)
        }
        persistOptionalShortcut(savedHoldCustomShortcut, key: savedHoldCustomShortcutStorageKey)
        persistOptionalShortcut(savedToggleCustomShortcut, key: savedToggleCustomShortcutStorageKey)

        overlayManager.onStopButtonPressed = { [weak self] in
            DispatchQueue.main.async {
                self?.handleOverlayStopButtonPressed()
            }
        }
    }

    func cleanupBeforeDeallocation() {
        removeAudioDeviceListener()
        accessibilityTimer?.invalidate()
        accessibilityTimer = nil
        debugOverlayTimer?.invalidate()
        debugOverlayTimer = nil
        transcribingIndicatorTask?.cancel()
        contextCaptureTask?.cancel()
        pendingShortcutStartTask?.cancel()
        startupTimeoutTask?.cancel()
    }

    private func removeAudioDeviceListener() {
        guard let block = audioDeviceListenerBlock else { return }
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            DispatchQueue.main,
            block
        )
        audioDeviceListenerBlock = nil
    }

    nonisolated private static func loadStoredAPIKey(account: String) -> String {
        if let storedKey = AppSettingsStorage.load(account: account), !storedKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return storedKey
        }
        return ""
    }

    private func persistAPIKey(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            AppSettingsStorage.delete(account: apiKeyStorageKey)
        } else {
            AppSettingsStorage.save(trimmed, account: apiKeyStorageKey)
        }
    }

    private nonisolated static let defaultAPIBaseURL = "https://api.groq.com/openai/v1"

    private struct StoredShortcutConfiguration {
        let hold: ShortcutBinding
        let toggle: ShortcutBinding
        let didMigrateLegacyValue: Bool
    }

    nonisolated private static func loadStoredAPIBaseURL(account: String) -> String {
        if let stored = AppSettingsStorage.load(account: account), !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return stored
        }
        return defaultAPIBaseURL
    }

    nonisolated private static func loadShortcutConfiguration(holdKey: String, toggleKey: String) -> StoredShortcutConfiguration {
        if let hold = loadShortcut(forKey: holdKey),
           let toggle = loadShortcut(forKey: toggleKey) {
            return StoredShortcutConfiguration(hold: hold, toggle: toggle, didMigrateLegacyValue: false)
        }

        let legacyPreset = ShortcutPreset(
            rawValue: UserDefaults.standard.string(forKey: "hotkey_option") ?? ShortcutPreset.fnKey.rawValue
        ) ?? .fnKey
        let hold = legacyPreset.binding
        let toggle = hold.withAddedModifiers(.command)
        return StoredShortcutConfiguration(hold: hold, toggle: toggle, didMigrateLegacyValue: true)
    }

    nonisolated private static func loadShortcut(forKey key: String) -> ShortcutBinding? {
        guard let data = UserDefaults.standard.data(forKey: key) else {
            return nil
        }
        return try? JSONDecoder().decode(ShortcutBinding.self, from: data)
    }

    private func persistAPIBaseURL(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == Self.defaultAPIBaseURL {
            AppSettingsStorage.delete(account: apiBaseURLStorageKey)
        } else {
            guard URL(string: trimmed) != nil else {
                os_log(.error, "Rejecting invalid API base URL: %{public}@", trimmed)
                return
            }
            AppSettingsStorage.save(trimmed, account: apiBaseURLStorageKey)
        }
    }

    private func persistShortcut(_ binding: ShortcutBinding, key: String) {
        guard let data = try? JSONEncoder().encode(binding) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    private func persistOptionalShortcut(_ binding: ShortcutBinding?, key: String) {
        guard let binding else {
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        persistShortcut(binding, key: key)
    }

    struct SavedAudioFile {
        let fileName: String
        let fileURL: URL
    }

    nonisolated static func audioStorageDirectory() -> URL {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return FileManager.default.temporaryDirectory
        }
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "FreeFlow"
        let audioDir = appSupport.appendingPathComponent("\(appName)/audio", isDirectory: true)
        if !FileManager.default.fileExists(atPath: audioDir.path) {
            try? FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        }
        return audioDir
    }

    nonisolated static func saveAudioFile(from tempURL: URL) -> SavedAudioFile? {
        let fileName = UUID().uuidString + ".wav"
        let destURL = audioStorageDirectory().appendingPathComponent(fileName)
        do {
            try AudioNormalization.writePreferredAudioCopy(from: tempURL, to: destURL)
            return SavedAudioFile(fileName: fileName, fileURL: destURL)
        } catch {
            return nil
        }
    }

    nonisolated private static func deleteAudioFile(_ fileName: String) {
        let fileURL = audioStorageDirectory().appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: fileURL)
    }

    func clearPipelineHistory() {
        do {
            let removedAudioFileNames = try pipelineHistoryStore.clearAll()
            for audioFileName in removedAudioFileNames {
                Self.deleteAudioFile(audioFileName)
            }
            pipelineHistory = []
        } catch {
            errorMessage = "Unable to clear run history: \(error.localizedDescription)"
        }
    }

    func deleteHistoryEntry(id: UUID) {
        guard let index = pipelineHistory.firstIndex(where: { $0.id == id }) else { return }
        do {
            if let audioFileName = try pipelineHistoryStore.delete(id: id) {
                Self.deleteAudioFile(audioFileName)
            }
            pipelineHistory.remove(at: index)
        } catch {
            errorMessage = "Unable to delete run history entry: \(error.localizedDescription)"
        }
    }

    func retryTranscription(item: PipelineHistoryItem) {
        guard let audioFileName = item.audioFileName else { return }
        guard !retryingItemIDs.contains(item.id) else { return }

        retryingItemIDs.insert(item.id)

        let audioURL = Self.audioStorageDirectory().appendingPathComponent(audioFileName)
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            retryingItemIDs.remove(item.id)
            errorMessage = "Audio file not found for retry."
            return
        }

        let restoredContext = AppContext(
            appName: nil,
            bundleIdentifier: nil,
            windowTitle: nil,
            selectedText: nil,
            currentActivity: item.contextSummary,
            contextPrompt: item.contextPrompt,
            screenshotDataURL: item.contextScreenshotDataURL,
            screenshotMimeType: item.contextScreenshotDataURL != nil ? "image/jpeg" : nil,
            screenshotError: nil
        )

        let transcriptionService = TranscriptionService(
            apiKey: resolvedTranscriptionApiKey,
            baseURL: resolvedTranscriptionBaseURL,
            forceHTTP2: forceHTTP2Transcription,
            model: resolvedTranscriptionModel
        )
        let postProcessingService = PostProcessingService(apiKey: resolvedPostProcessingApiKey, baseURL: resolvedPostProcessingBaseURL, model: resolvedPostProcessingModel)
        let capturedCustomVocabulary = customVocabulary
        let capturedCustomSystemPrompt = customSystemPrompt

        Task {
            do {
                let rawTranscript = try await transcriptionService.transcribe(fileURL: audioURL)

                let finalTranscript: String
                let processingStatus: String
                let postProcessingPrompt: String
                do {
                    let postProcessingResult = try await postProcessingService.postProcess(
                        transcript: rawTranscript,
                        context: restoredContext,
                        customVocabulary: capturedCustomVocabulary,
                        customSystemPrompt: capturedCustomSystemPrompt
                    )
                    finalTranscript = postProcessingResult.transcript
                    processingStatus = "Post-processing succeeded (retried)"
                    postProcessingPrompt = postProcessingResult.prompt
                } catch {
                    finalTranscript = rawTranscript
                    processingStatus = "Post-processing failed on retry, using raw transcript"
                    postProcessingPrompt = ""
                }

                await MainActor.run {
                    let updatedItem = PipelineHistoryItem(
                        id: item.id,
                        timestamp: item.timestamp,
                        rawTranscript: rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines),
                        postProcessedTranscript: finalTranscript.trimmingCharacters(in: .whitespacesAndNewlines),
                        postProcessingPrompt: postProcessingPrompt,
                        contextSummary: item.contextSummary,
                        contextPrompt: item.contextPrompt,
                        contextScreenshotDataURL: item.contextScreenshotDataURL,
                        contextScreenshotStatus: item.contextScreenshotStatus,
                        postProcessingStatus: processingStatus,
                        debugStatus: "Retried",
                        customVocabulary: item.customVocabulary,
                        audioFileName: item.audioFileName
                    )
                    do {
                        try pipelineHistoryStore.update(updatedItem)
                        pipelineHistory = pipelineHistoryStore.loadAllHistory()
                    } catch {
                        errorMessage = "Failed to save retry result: \(error.localizedDescription)"
                    }
                    retryingItemIDs.remove(item.id)
                }
            } catch {
                await MainActor.run {
                    let updatedItem = PipelineHistoryItem(
                        id: item.id,
                        timestamp: item.timestamp,
                        rawTranscript: item.rawTranscript,
                        postProcessedTranscript: item.postProcessedTranscript,
                        postProcessingPrompt: item.postProcessingPrompt,
                        contextSummary: item.contextSummary,
                        contextPrompt: item.contextPrompt,
                        contextScreenshotDataURL: item.contextScreenshotDataURL,
                        contextScreenshotStatus: item.contextScreenshotStatus,
                        postProcessingStatus: "Error: \(error.localizedDescription)",
                        debugStatus: "Retry failed",
                        customVocabulary: item.customVocabulary,
                        audioFileName: item.audioFileName
                    )
                    do {
                        try pipelineHistoryStore.update(updatedItem)
                        pipelineHistory = pipelineHistoryStore.loadAllHistory()
                    } catch {
                        os_log(.error, "Failed to update pipeline history on retry failure: %{public}@", "\(error)")
                    }
                    retryingItemIDs.remove(item.id)
                }
            }
        }
    }

    func startAccessibilityPolling() {
        accessibilityTimer?.invalidate()
        hasAccessibility = AXIsProcessTrusted()
        hasScreenRecordingPermission = hasScreenCapturePermission()
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.hasAccessibility = AXIsProcessTrusted()
                self?.hasScreenRecordingPermission = self?.hasScreenCapturePermission() ?? false
            }
        }
    }

    func stopAccessibilityPolling() {
        accessibilityTimer?.invalidate()
        accessibilityTimer = nil
    }

    func openAccessibilitySettings() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    func hasScreenCapturePermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    func requestScreenCapturePermission() {
        // ScreenCaptureKit triggers the "Screen & System Audio Recording"
        // permission dialog on macOS Sequoia+, correctly identifying the
        // running app (unlike the legacy CGWindowListCreateImage path).
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.hasScreenRecordingPermission = CGPreflightScreenCaptureAccess()
            }
        }

        hasScreenRecordingPermission = CGPreflightScreenCaptureAccess()
    }

    func openScreenCaptureSettings() {
        let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        if let url = settingsURL {
            NSWorkspace.shared.open(url)
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Revert the toggle on failure without re-triggering didSet
            let current = SMAppService.mainApp.status == .enabled
            if current != launchAtLogin {
                launchAtLogin = current
            }
        }
    }

    func refreshLaunchAtLoginStatus() {
        let current = SMAppService.mainApp.status == .enabled
        if current != launchAtLogin {
            launchAtLogin = current
        }
    }

    func refreshAvailableMicrophones() {
        availableMicrophones = AudioDevice.availableInputDevices()
    }

    private func installAudioDeviceListener() {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.refreshAvailableMicrophones()
            }
        }
        audioDeviceListenerBlock = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            DispatchQueue.main,
            block
        )
    }

    var usesFnShortcut: Bool {
        holdShortcut.usesFnKey || toggleShortcut.usesFnKey
    }

    var hasEnabledHoldShortcut: Bool {
        !holdShortcut.isDisabled
    }

    var hasEnabledToggleShortcut: Bool {
        !toggleShortcut.isDisabled
    }

    var shortcutStatusText: String {
        switch (hasEnabledHoldShortcut, hasEnabledToggleShortcut) {
        case (true, true):
            return "Hold \(holdShortcut.displayName) or tap \(toggleShortcut.displayName) to dictate"
        case (true, false):
            return "Hold \(holdShortcut.displayName) to dictate"
        case (false, true):
            return "Tap \(toggleShortcut.displayName) to dictate"
        case (false, false):
            return "No dictation shortcut enabled"
        }
    }

    var shortcutStartDelayMilliseconds: Int {
        Int((shortcutStartDelay * 1000).rounded())
    }

    func savedCustomShortcut(for role: ShortcutRole) -> ShortcutBinding? {
        switch role {
        case .hold:
            return savedHoldCustomShortcut
        case .toggle:
            return savedToggleCustomShortcut
        }
    }

    @discardableResult
    func setShortcut(_ binding: ShortcutBinding, for role: ShortcutRole) -> String? {
        let otherBinding = role == .hold ? toggleShortcut : holdShortcut
        if binding.isDisabled && otherBinding.isDisabled {
            return "At least one shortcut must remain enabled."
        }
        guard binding != otherBinding else {
            return "Hold and tap shortcuts must be different."
        }

        switch role {
        case .hold:
            if binding.isCustom {
                savedHoldCustomShortcut = binding
            }
            holdShortcut = binding
        case .toggle:
            if binding.isCustom {
                savedToggleCustomShortcut = binding
            }
            toggleShortcut = binding
        }

        return nil
    }

    func startHotkeyMonitoring() {
        shouldMonitorHotkeys = true
        hotkeyManager.onShortcutEvent = { [weak self] event in
            DispatchQueue.main.async {
                self?.handleShortcutEvent(event)
            }
        }
        restartHotkeyMonitoring()
    }

    func stopHotkeyMonitoring() {
        shouldMonitorHotkeys = false
        hotkeyManager.stop()
    }

    func suspendHotkeyMonitoringForShortcutCapture() {
        isCapturingShortcut = true
        restartHotkeyMonitoring()
    }

    func resumeHotkeyMonitoringAfterShortcutCapture() {
        isCapturingShortcut = false
        restartHotkeyMonitoring()
    }

    private func restartHotkeyMonitoring() {
        guard shouldMonitorHotkeys, !isCapturingShortcut else {
            hotkeyManager.stop()
            return
        }

        hotkeyManager.start(configuration: ShortcutConfiguration(hold: holdShortcut, toggle: toggleShortcut))
    }

    private func handleShortcutEvent(_ event: ShortcutEvent) {
        guard let action = shortcutSessionController.handle(event: event, isTranscribing: isTranscribing) else {
            return
        }

        switch action {
        case .start(let mode):
            os_log(.info, log: recordingLog, "Shortcut start fired for mode %{public}@", mode.rawValue)
            scheduleShortcutStart(mode: mode)
        case .stop:
            cancelPendingShortcutStart()
            guard isRecording else {
                shortcutSessionController.reset()
                activeRecordingTriggerMode = nil
                return
            }
            stopAndTranscribe()
        case .switchedToToggle:
            if isRecording {
                activeRecordingTriggerMode = .toggle
                overlayManager.setRecordingTriggerMode(.toggle, animated: true)
            } else if pendingShortcutStartMode != nil {
                pendingShortcutStartMode = .toggle
            }
        }
    }

    func toggleRecording() {
        os_log(.info, log: recordingLog, "toggleRecording() called, isRecording=%{public}d", isRecording)
        cancelPendingShortcutStart()
        if isRecording {
            stopAndTranscribe()
        } else {
            shortcutSessionController.beginManual(mode: .toggle)
            startRecording(triggerMode: .toggle)
        }
    }

    private func handleOverlayStopButtonPressed() {
        guard isRecording, activeRecordingTriggerMode == .toggle else { return }
        stopAndTranscribe()
    }

    private func scheduleShortcutStart(mode: RecordingTriggerMode) {
        cancelPendingShortcutStart(resetMode: false)
        pendingShortcutStartMode = mode
        let delay = shortcutStartDelay

        guard delay > 0 else {
            pendingShortcutStartMode = nil
            startRecording(triggerMode: mode)
            return
        }

        pendingShortcutStartTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                return
            }

            await MainActor.run { [weak self] in
                guard let self, let pendingMode = self.pendingShortcutStartMode else { return }
                self.pendingShortcutStartTask = nil
                self.pendingShortcutStartMode = nil
                self.startRecording(triggerMode: pendingMode)
            }
        }
    }

    private func cancelPendingShortcutStart(resetMode: Bool = true) {
        pendingShortcutStartTask?.cancel()
        pendingShortcutStartTask = nil
        if resetMode {
            pendingShortcutStartMode = nil
        }
    }

    private func startRecording(triggerMode: RecordingTriggerMode) {
        let t0 = CFAbsoluteTimeGetCurrent()
        os_log(.info, log: recordingLog, "startRecording() entered")
        guard !isRecording && !isTranscribing else { return }
        cancelPendingShortcutStart()
        activeRecordingTriggerMode = triggerMode
        overlayManager.setRecordingTriggerMode(triggerMode, animated: false)
        guard hasAccessibility else {
            errorMessage = "Accessibility permission required. Grant access in System Settings > Privacy & Security > Accessibility."
            statusText = "No Accessibility"
            activeRecordingTriggerMode = nil
            shortcutSessionController.reset()
            showAccessibilityAlert()
            return
        }
        os_log(.info, log: recordingLog, "accessibility check passed: %.3fms", (CFAbsoluteTimeGetCurrent() - t0) * 1000)
        guard ensureMicrophoneAccess() else { return }
        os_log(.info, log: recordingLog, "mic access check passed: %.3fms", (CFAbsoluteTimeGetCurrent() - t0) * 1000)
        beginRecording(triggerMode: triggerMode)
        os_log(.info, log: recordingLog, "startRecording() finished: %.3fms", (CFAbsoluteTimeGetCurrent() - t0) * 1000)
    }

    private func ensureMicrophoneAccess() -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        guard let self, let triggerMode = self.activeRecordingTriggerMode else { return }
                        self.beginRecording(triggerMode: triggerMode)
                    } else {
                        self?.errorMessage = "Microphone permission denied. Grant access in System Settings > Privacy & Security > Microphone."
                        self?.statusText = "No Microphone"
                        self?.activeRecordingTriggerMode = nil
                        self?.shortcutSessionController.reset()
                        self?.showMicrophonePermissionAlert()
                    }
                }
            }
            return false
        default:
            errorMessage = "Microphone permission denied. Grant access in System Settings > Privacy & Security > Microphone."
            statusText = "No Microphone"
            activeRecordingTriggerMode = nil
            shortcutSessionController.reset()
            showMicrophonePermissionAlert()
            return false
        }
    }

    private func beginRecording(triggerMode: RecordingTriggerMode) {
        os_log(.info, log: recordingLog, "beginRecording() entered")

        let decision = startupPolicy.overlapDecision(isStartupInProgress: startupAttemptState.isStarting)
        guard decision == .startNewAttempt else {
            os_log(.info, log: recordingLog, "startup already in progress — ignoring new trigger")
            return
        }

        let attemptID = UUID().uuidString
        startupAttemptState = startupAttemptState.startingNewAttempt(id: attemptID)
        os_log(.info, log: recordingLog, "startup attempt %{public}@ created", attemptID)

        errorMessage = nil
        isRecording = true
        statusText = "Starting..."
        hasShownScreenshotPermissionAlert = false

        startupTimeoutTask?.cancel()
        startupTimeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(4 * 1_000_000_000))
            } catch { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard self.startupAttemptState.shouldAcceptCompletion(for: attemptID) else { return }
                os_log(.error, log: recordingLog, "startup timeout fired for attempt %{public}@", attemptID)
                self.startupAttemptState = self.startupAttemptState.timedOutAttempt(id: attemptID)
                self.handleStartupFailure(attemptID: attemptID)
            }
        }

        var overlayShown = false
        let initTimer = DispatchSource.makeTimerSource(queue: .main)
        initTimer.schedule(deadline: .now() + 0.5)
        initTimer.setEventHandler { [weak self] in
            guard let self, !overlayShown else { return }
            overlayShown = true
            os_log(.info, log: recordingLog, "engine slow — showing initializing overlay")
            self.overlayManager.showInitializing(mode: self.activeRecordingTriggerMode ?? triggerMode)
        }
        initTimer.resume()

        let deviceUID = selectedMicrophoneID
        audioRecorder.onRecordingReady = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.startupAttemptState.shouldAcceptCompletion(for: attemptID) else {
                    os_log(.info, log: recordingLog, "stale ready callback for attempt %{public}@ — ignoring", attemptID)
                    return
                }
                self.startupTimeoutTask?.cancel()
                self.startupTimeoutTask = nil
                self.startupAttemptState = self.startupAttemptState.completedAttempt(id: attemptID)

                initTimer.cancel()
                os_log(.info, log: recordingLog, "recorder ready — transitioning to waveform (attempt %{public}@)", attemptID)
                self.statusText = "Recording..."
                if overlayShown {
                    self.overlayManager.transitionToRecording(mode: self.activeRecordingTriggerMode ?? triggerMode)
                } else {
                    self.overlayManager.showRecording(mode: self.activeRecordingTriggerMode ?? triggerMode)
                }
                overlayShown = true
                let s = NSSound(named: "Tink"); s?.volume = self.soundVolume; s?.play()
            }
        }

        let recorder = self.audioRecorder
        Task.detached(priority: .userInitiated) { [weak self] in
            let t0 = CFAbsoluteTimeGetCurrent()
            do {
                os_log(.info, log: recordingLog, "recorder startup entered")
                try recorder.startRecording(deviceUID: deviceUID)
                os_log(.info, log: recordingLog, "audioRecorder.startRecording() done: %.3fms", (CFAbsoluteTimeGetCurrent() - t0) * 1000)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.startContextCapture()
                    self.audioLevelCancellable = self.audioRecorder.$audioLevel
                        .receive(on: DispatchQueue.main)
                        .sink { [weak self] level in
                            self?.overlayManager.updateAudioLevel(level)
                        }
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    initTimer.cancel()
                    self.startupTimeoutTask?.cancel()
                    self.startupTimeoutTask = nil
                    guard self.startupAttemptState.shouldAcceptCompletion(for: attemptID) else { return }
                    let reason = self.classifyStartupFailure(error)
                    self.startupAttemptState = self.startupAttemptState.failedAttempt(id: attemptID, reason: reason)
                    self.handleStartupFailure(attemptID: attemptID, error: error)
                }
            }
        }
    }

    private func classifyStartupFailure(_ error: Error) -> RecordingStartupFailureReason {
        let lower = error.localizedDescription.lowercased()
        if lower.contains("microphone") && lower.contains("permission") {
            return .microphonePermissionDenied
        }
        if lower.contains("permission") {
            return .permissionBlocked(details: error.localizedDescription)
        }
        return .general(formattedRecordingStartError(error))
    }

    private func handleStartupFailure(attemptID: String, error: Error? = nil) {
        os_log(.error, log: recordingLog, "startup failure for attempt %{public}@: %{public}@",
               attemptID, error?.localizedDescription ?? "timeout")
        isRecording = false
        activeRecordingTriggerMode = nil
        shortcutSessionController.reset()
        errorMessage = startupAttemptState.errorMessage ?? (error.map { formattedRecordingStartError($0) })
        statusText = startupAttemptState.statusText ?? "Error"
        overlayManager.dismiss()
        audioRecorder.cleanup()
        startupAttemptState = .idle
        os_log(.info, log: recordingLog, "cleanup/reset completed — ready for retry")
    }

    private func formattedRecordingStartError(_ error: Error) -> String {
        if let recorderError = error as? AudioRecorderError {
            return "Failed to start recording: \(recorderError.localizedDescription)"
        }

        let lower = error.localizedDescription.lowercased()
        if lower.contains("operation couldn't be completed") || lower.contains("operation could not be completed") {
            return "Failed to start recording: Audio input error. Verify microphone access is granted and a working mic is selected in System Settings > Sound > Input."
        }

        let nsError = error as NSError
        if nsError.domain == NSOSStatusErrorDomain {
            return "Failed to start recording (audio subsystem error \(nsError.code)). Check microphone permissions and selected input device."
        }

        return "Failed to start recording: \(error.localizedDescription)"
    }

    func showMicrophonePermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Microphone Permission Required"
        alert.informativeText = "FreeFlow cannot record audio without Microphone access.\n\nGo to System Settings > Privacy & Security > Microphone and enable FreeFlow."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Dismiss")
        alert.icon = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
            if let url = settingsURL {
                NSWorkspace.shared.open(url)
            }
        }
    }

    func showAccessibilityAlert() {
        let alert = NSAlert()
        alert.messageText = "Accessibility Permission Required"
        alert.informativeText = "FreeFlow cannot type transcriptions without Accessibility access.\n\nGo to System Settings > Privacy & Security > Accessibility and enable FreeFlow."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Dismiss")
        alert.icon = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            openAccessibilitySettings()
        }
    }

    private func stopAndTranscribe() {
        cancelPendingShortcutStart()
        shortcutSessionController.reset()
        activeRecordingTriggerMode = nil
        audioLevelCancellable?.cancel()
        audioLevelCancellable = nil
        debugStatusMessage = "Preparing audio"
        let sessionContext = capturedContext
        let inFlightContextTask = contextCaptureTask
        capturedContext = nil
        contextCaptureTask = nil
        lastRawTranscript = ""
        lastPostProcessedTranscript = ""
        lastContextSummary = ""
        lastPostProcessingStatus = ""
        lastPostProcessingPrompt = ""
        lastContextScreenshotDataURL = nil
        lastContextScreenshotStatus = "No screenshot"

        guard let fileURL = audioRecorder.stopRecording() else {
            audioRecorder.cleanup()
            errorMessage = "No audio recorded"
            isRecording = false
            statusText = "Error"
            overlayManager.dismiss()
            return
        }
        let savedAudioFile = Self.saveAudioFile(from: fileURL)
        let transcriptionFileURL = savedAudioFile?.fileURL ?? fileURL
        isRecording = false
        isTranscribing = true
        statusText = "Transcribing..."
        debugStatusMessage = "Transcribing audio"
        errorMessage = nil
        let s = NSSound(named: "Pop"); s?.volume = soundVolume; s?.play()
        overlayManager.slideUpToNotch { }

        transcribingIndicatorTask?.cancel()
        let indicatorDelay = transcribingIndicatorDelay
        transcribingIndicatorTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(indicatorDelay * 1_000_000_000))
                let shouldShowTranscribing = self?.isTranscribing ?? false
                guard shouldShowTranscribing else { return }
                await MainActor.run { [weak self] in
                    self?.overlayManager.showTranscribing()
                }
            } catch { /* CancellationError from Task.sleep — expected */ }
        }

        let transcriptionService = TranscriptionService(
            apiKey: resolvedTranscriptionApiKey,
            baseURL: resolvedTranscriptionBaseURL,
            forceHTTP2: forceHTTP2Transcription,
            model: resolvedTranscriptionModel
        )
        let postProcessingService = PostProcessingService(apiKey: resolvedPostProcessingApiKey, baseURL: resolvedPostProcessingBaseURL, model: resolvedPostProcessingModel)

        Task {
            do {
                // Run transcription and context resolution in parallel.
                // Context may already be captured (sessionContext), still in-flight
                // (inFlightContextTask), or unavailable (fallback). Either way,
                // transcription proceeds without waiting for context.
                let contextGatheringEnabled = self.enableContextGathering

                async let transcriptResult = transcriptionService.transcribe(fileURL: transcriptionFileURL)
                async let contextResult: AppContext? = { [weak self] () async -> AppContext? in
                    guard contextGatheringEnabled else { return nil }
                    if let sessionContext {
                        return sessionContext
                    } else if let ctx = await inFlightContextTask?.value {
                        return ctx
                    } else {
                        return await self?.fallbackContextAtStop()
                    }
                }()

                let rawTranscript = try await transcriptResult
                let appContext: AppContext? = await contextResult
                await MainActor.run { [weak self] in
                    self?.debugStatusMessage = "Running post-processing"
                }
                let finalTranscript: String
                let processingStatus: String
                let postProcessingPrompt: String
                do {
                    let postProcessingResult = try await postProcessingService.postProcess(
                        transcript: rawTranscript,
                        context: appContext,
                        customVocabulary: customVocabulary,
                        customSystemPrompt: customSystemPrompt
                    )
                    finalTranscript = postProcessingResult.transcript
                    processingStatus = "Post-processing succeeded"
                    postProcessingPrompt = postProcessingResult.prompt
                } catch {
                    finalTranscript = rawTranscript
                    processingStatus = "Post-processing failed, using raw transcript"
                    postProcessingPrompt = ""
                }
                await MainActor.run {
                    self.lastContextSummary = appContext?.contextSummary ?? "Context analysis skipped"
                    self.lastContextScreenshotDataURL = appContext?.screenshotDataURL
                    self.lastContextScreenshotStatus = appContext?.screenshotError
                        ?? (appContext != nil ? "available (\(appContext?.screenshotMimeType ?? "image"))" : "Context analysis skipped")
                    let trimmedRawTranscript = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
                    let trimmedFinalTranscript = finalTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.lastPostProcessingPrompt = postProcessingPrompt
                    self.lastRawTranscript = trimmedRawTranscript
                    self.lastPostProcessedTranscript = trimmedFinalTranscript
                    self.lastPostProcessingStatus = processingStatus
                    self.recordPipelineHistoryEntry(
                        rawTranscript: trimmedRawTranscript,
                        postProcessedTranscript: trimmedFinalTranscript,
                        postProcessingPrompt: postProcessingPrompt,
                        context: appContext,
                        processingStatus: processingStatus,
                        audioFileName: savedAudioFile?.fileName
                    )
                    self.transcribingIndicatorTask?.cancel()
                    self.transcribingIndicatorTask = nil
                    self.lastTranscript = trimmedFinalTranscript
                    self.isTranscribing = false
                    self.debugStatusMessage = "Done"
                    let completionStatusText = self.preserveClipboard ? "Pasted at cursor!" : "Copied to clipboard!"

                    if trimmedFinalTranscript.isEmpty {
                        self.statusText = "Nothing to transcribe"
                        self.overlayManager.dismiss()
                    } else {
                        self.statusText = completionStatusText
                        self.overlayManager.showDone()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                            self?.overlayManager.dismiss()
                        }

                        let pendingClipboardRestore = self.writeTranscriptToPasteboard(trimmedFinalTranscript)
                        self.pasteAtCursorWhenShortcutReleased {
                            self.restoreClipboardIfNeeded(pendingClipboardRestore)
                        }
                    }

                    self.audioRecorder.cleanup()

                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                        if self?.statusText == completionStatusText || self?.statusText == "Nothing to transcribe" {
                            self?.statusText = "Ready"
                        }
                    }
                }
            } catch {
                let resolvedContext: AppContext?
                if self.enableContextGathering {
                    if let sessionContext {
                        resolvedContext = sessionContext
                    } else if let inFlightContext = await inFlightContextTask?.value {
                        resolvedContext = inFlightContext
                    } else {
                        resolvedContext = fallbackContextAtStop()
                    }
                } else {
                    resolvedContext = nil
                }
                await MainActor.run {
                    self.transcribingIndicatorTask?.cancel()
                    self.transcribingIndicatorTask = nil
                    self.errorMessage = error.localizedDescription
                    self.isTranscribing = false
                    self.statusText = "Error"
                    self.audioRecorder.cleanup()
                    self.overlayManager.dismiss()
                    self.lastPostProcessedTranscript = ""
                    self.lastRawTranscript = ""
                    self.lastContextSummary = ""
                    self.lastPostProcessingStatus = "Error: \(error.localizedDescription)"
                    self.lastPostProcessingPrompt = ""
                    self.lastContextScreenshotDataURL = resolvedContext?.screenshotDataURL
                    self.lastContextScreenshotStatus = resolvedContext?.screenshotError
                        ?? (resolvedContext != nil ? "available (\(resolvedContext?.screenshotMimeType ?? "image"))" : "Context analysis skipped")
                    self.recordPipelineHistoryEntry(
                        rawTranscript: "",
                        postProcessedTranscript: "",
                        postProcessingPrompt: "",
                        context: resolvedContext,
                        processingStatus: "Error: \(error.localizedDescription)",
                        audioFileName: savedAudioFile?.fileName
                    )
                }
            }
        }
    }

    private func recordPipelineHistoryEntry(
        rawTranscript: String,
        postProcessedTranscript: String,
        postProcessingPrompt: String,
        context: AppContext?,
        processingStatus: String,
        audioFileName: String? = nil
    ) {
        let newEntry = PipelineHistoryItem(
            timestamp: Date(),
            rawTranscript: rawTranscript,
            postProcessedTranscript: postProcessedTranscript,
            postProcessingPrompt: postProcessingPrompt,
            contextSummary: context?.contextSummary ?? "Context analysis skipped",
            contextPrompt: context?.contextPrompt,
            contextScreenshotDataURL: context?.screenshotDataURL,
            contextScreenshotStatus: context?.screenshotError
                ?? (context != nil ? "available (\(context?.screenshotMimeType ?? "image"))" : "Context analysis skipped"),
            postProcessingStatus: processingStatus,
            debugStatus: debugStatusMessage,
            customVocabulary: customVocabulary,
            audioFileName: audioFileName
        )
        do {
            let removedAudioFileNames = try pipelineHistoryStore.append(newEntry, maxCount: maxPipelineHistoryCount)
            for audioFileName in removedAudioFileNames {
                Self.deleteAudioFile(audioFileName)
            }
            pipelineHistory = pipelineHistoryStore.loadAllHistory()
        } catch {
            errorMessage = "Unable to save run history entry: \(error.localizedDescription)"
        }
    }

    private func startContextCapture() {
        let contextRunPolicy = AppStateContextRunPolicy(allowsContextAnalysis: enableContextGathering)

        contextCaptureTask?.cancel()
        capturedContext = nil

        guard contextRunPolicy.shouldCollectContext else {
            capturedContext = nil
            lastContextSummary = contextRunPolicy.disabledStatusText
            lastPostProcessingStatus = contextRunPolicy.disabledStatusText
            lastContextScreenshotDataURL = nil
            lastContextScreenshotStatus = contextRunPolicy.disabledScreenshotStatus
            lastPostProcessingPrompt = ""
            contextCaptureTask = nil
            return
        }

        lastContextSummary = "Collecting app context..."
        lastPostProcessingStatus = ""
        lastContextScreenshotDataURL = nil
        lastContextScreenshotStatus = "Collecting screenshot..."

        contextCaptureTask = Task { [weak self] in
            guard let self else { return nil }
            let context = await self.contextService.collectContext()
            await MainActor.run {
                self.capturedContext = context
                self.lastContextSummary = context.contextSummary
                self.lastContextScreenshotDataURL = context.screenshotDataURL
                self.lastContextScreenshotStatus = context.screenshotError
                    ?? "available (\(context.screenshotMimeType ?? "image"))"
                self.lastPostProcessingStatus = "App context captured"
                self.handleScreenshotCaptureIssue(context.screenshotError)
            }
            return context
        }
    }

    private func fallbackContextAtStop() -> AppContext {
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let windowTitle = focusedWindowTitle(for: frontmostApp)
        let hasWindowTextContext = frontmostApp?.localizedName != nil
        let statusMessage = FallbackContextStatusMessage.resolve(
            contextAnalysisEnabled: enableContextGathering,
            hasWindowTextContext: hasWindowTextContext
        )
        return AppContext(
            appName: frontmostApp?.localizedName,
            bundleIdentifier: frontmostApp?.bundleIdentifier,
            windowTitle: windowTitle,
            selectedText: nil,
            currentActivity: statusMessage,
            contextPrompt: nil,
            screenshotDataURL: nil,
            screenshotMimeType: nil,
            screenshotError: "No app context captured before stop"
        )
    }

    private func focusedWindowTitle(for app: NSRunningApplication?) -> String? {
        guard let app else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        return focusedWindowTitle(from: appElement)
    }

    private func focusedWindowTitle(from appElement: AXUIElement) -> String? {
        guard let focusedWindow = accessibilityElement(from: appElement, attribute: kAXFocusedWindowAttribute as CFString) else {
            return nil
        }

        guard let windowTitle = accessibilityString(from: focusedWindow, attribute: kAXTitleAttribute as CFString) else {
            return nil
        }

        return trimmedText(windowTitle)
    }

    private func accessibilityElement(from element: AXUIElement, attribute: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success,
              let rawValue = value,
              CFGetTypeID(rawValue) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeBitCast(rawValue, to: AXUIElement.self)
    }

    private func accessibilityString(from element: AXUIElement, attribute: CFString) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success, let stringValue = value as? String else { return nil }
        return stringValue
    }

    private func trimmedText(_ value: String) -> String? {
        let trimmed = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        return trimmed.isEmpty ? nil : trimmed
    }

    private func handleScreenshotCaptureIssue(_ message: String?) {
        guard let message, !message.isEmpty else {
            hasShownScreenshotPermissionAlert = false
            return
        }

        os_log(.error, "Screenshot capture issue: %{public}@", message)

        if isScreenCapturePermissionError(message) && !hasShownScreenshotPermissionAlert {
            hasShownScreenshotPermissionAlert = true

            // Permission errors are fatal — stop recording
            _ = audioRecorder.stopRecording()
            audioRecorder.cleanup()
            audioLevelCancellable?.cancel()
            audioLevelCancellable = nil
            contextCaptureTask?.cancel()
            contextCaptureTask = nil
            capturedContext = nil
            isRecording = false
            shortcutSessionController.reset()
            activeRecordingTriggerMode = nil
            statusText = "Screenshot Required"
            overlayManager.dismiss()

            let s = NSSound(named: "Basso"); s?.volume = soundVolume; s?.play()
            showScreenshotPermissionAlert(message: message)
        }
        // Non-permission errors (transient failures) — continue recording without context
    }

    private func isScreenCapturePermissionError(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return lowered.contains("permission") || lowered.contains("screen recording")
    }

    private func showScreenshotPermissionAlert(message: String) {
        let alert = NSAlert()
        alert.messageText = "Screen Recording Permission Required"
        alert.informativeText = "\(message)\n\nFreeFlow requires Screen Recording permission to capture screenshots for context-aware transcription.\n\nGo to System Settings > Privacy & Security > Screen Recording and enable FreeFlow."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Dismiss")
        alert.icon = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: nil)

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            openScreenCaptureSettings()
        }
    }

    private func showScreenshotCaptureErrorAlert(message: String) {
        let alert = NSAlert()
        alert.messageText = "Screenshot Capture Failed"
        alert.informativeText = "\(message)\n\nA screenshot is required for context-aware transcription. Recording has been stopped."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Dismiss")
        alert.icon = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: nil)
        _ = alert.runModal()
    }

    func toggleDebugOverlay() {
        if isDebugOverlayActive {
            stopDebugOverlay()
        } else {
            startDebugOverlay()
        }
    }

    private func startDebugOverlay() {
        isDebugOverlayActive = true
        overlayManager.showRecording()

        // Simulate audio levels with a timer
        var phase: Double = 0.0
        debugOverlayTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            phase += 0.15
            let base = 0.3 + 0.2 * sin(phase)
            let noise = Float.random(in: -0.15...0.15)
            let level = min(max(Float(base) + noise, 0.0), 1.0)
            MainActor.assumeIsolated {
                self.overlayManager.updateAudioLevel(level)
            }
        }
    }

    private func stopDebugOverlay() {
        debugOverlayTimer?.invalidate()
        debugOverlayTimer = nil
        isDebugOverlayActive = false
        overlayManager.dismiss()
    }

    func toggleDebugPanel() {
        selectedSettingsTab = .runLog
        NotificationCenter.default.post(name: .showSettings, object: nil)
    }

    private func pasteAtCursor() {
        let source = CGEventSource(stateID: .hidSystemState)

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cgSessionEventTap)

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cgSessionEventTap)
    }

    private func writeTranscriptToPasteboard(_ transcript: String) -> PendingClipboardRestore? {
        let pasteboard = NSPasteboard.general
        let snapshot = preserveClipboard ? PreservedPasteboardSnapshot(pasteboard: pasteboard) : nil

        pasteboard.clearContents()
        pasteboard.setString(transcript, forType: .string)

        guard let snapshot else { return nil }
        return PendingClipboardRestore(snapshot: snapshot, expectedChangeCount: pasteboard.changeCount)
    }

    private func restoreClipboardIfNeeded(_ pendingRestore: PendingClipboardRestore?) {
        guard let pendingRestore else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + clipboardRestoreDelay) { [weak self] in
            guard self != nil else { return }
            let pasteboard = NSPasteboard.general
            guard pasteboard.changeCount == pendingRestore.expectedChangeCount else { return }
            pendingRestore.snapshot.restore(to: pasteboard)
        }
    }

    private func pasteAtCursorWhenShortcutReleased(attempt: Int = 0, completion: (() -> Void)? = nil) {
        let maxAttempts = 24
        if hotkeyManager.hasPressedShortcutInputs && attempt < maxAttempts {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { [weak self] in
                self?.pasteAtCursorWhenShortcutReleased(attempt: attempt + 1, completion: completion)
            }
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            self?.pasteAtCursor()
            completion?()
        }
    }
}
