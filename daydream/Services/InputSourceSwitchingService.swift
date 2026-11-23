import AppKit
import ApplicationServices
import Carbon
import CoreFoundation
import CoreGraphics
import Foundation

enum InputSourceSwitchingStatus: Equatable, Sendable {
    case disabled
    case active(defaultEnglishName: String, activeRuleCount: Int)
    case warning(String)

    var displayText: String {
        switch self {
        case .disabled:
            return "Disabled"
        case .active(let defaultEnglishName, let activeRuleCount):
            let ruleLabel = activeRuleCount == 1 ? "1 app rule" : "\(activeRuleCount) app rules"
            return "Active · Default: \(defaultEnglishName) · \(ruleLabel)"
        case .warning(let message):
            return message.hasPrefix("Warning:") ? message : "Warning: \(message)"
        }
    }
}

struct RunningAppSnapshot: Equatable, Sendable {
    var bundleIdentifier: String?
    var localizedName: String
    var activationPolicy: NSApplication.ActivationPolicy
    var processIdentifier: pid_t

    init(
        bundleIdentifier: String?,
        localizedName: String,
        activationPolicy: NSApplication.ActivationPolicy = .regular,
        processIdentifier: pid_t = 0
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.localizedName = localizedName
        self.activationPolicy = activationPolicy
        self.processIdentifier = processIdentifier
    }
}

enum SpotlightActivityState: Equatable, Sendable {
    case inactive
    case activeFocusedElement
    case activeFallbackWindow
}

@MainActor
protocol InputSourceBackend {
    func selectableKeyboardInputSources() -> [KeyboardInputSource]
    func currentKeyboardInputSourceID() -> String?
    func currentASCIICapableLayoutInputSourceID() -> String?
    @discardableResult
    func selectInputSource(id: String) -> OSStatus
    func frontmostApplication() -> RunningAppSnapshot?
    func isAccessibilityTrusted() -> Bool
    func spotlightActivityState(wasSpotlightActive: Bool) -> SpotlightActivityState
    func isSpotlightActive(wasSpotlightActive: Bool) -> Bool
}

extension InputSourceBackend {
    func isAccessibilityTrusted() -> Bool {
        false
    }

    func spotlightActivityState(wasSpotlightActive: Bool) -> SpotlightActivityState {
        .inactive
    }

    func isSpotlightActive(wasSpotlightActive: Bool) -> Bool {
        spotlightActivityState(wasSpotlightActive: wasSpotlightActive) != .inactive
    }
}

@MainActor
final class CarbonInputSourceBackend: InputSourceBackend {
    nonisolated static func tisString(_ value: CFString) -> String {
        value as String
    }

    private nonisolated static func cfString(_ value: CFString) -> CFString {
        value
    }

    private nonisolated static func cfBoolean(_ value: CFBoolean) -> CFBoolean {
        value
    }

    private nonisolated static var allowedSourceTypes: Set<String> {
        [
            tisString(kTISTypeKeyboardLayout),
            tisString(kTISTypeKeyboardInputMode),
            tisString(kTISTypeKeyboardInputMethodWithoutModes),
        ]
    }

    func selectableKeyboardInputSources() -> [KeyboardInputSource] {
        let sources = enabledSelectableTISInputSources()
        let allowedTypes = Self.allowedSourceTypes
        var seenIDs: Set<String> = []
        var result: [KeyboardInputSource] = []

        for source in sources {
            guard let rawID = Self.stringProperty(source, kTISPropertyInputSourceID),
                  let id = AppSettings.normalizedOptionalIdentifier(rawID),
                  let sourceType = Self.stringProperty(source, kTISPropertyInputSourceType),
                  allowedTypes.contains(sourceType),
                  seenIDs.insert(id).inserted else {
                continue
            }

            let rawName = Self.stringProperty(source, kTISPropertyLocalizedName)
            let localizedName = AppSettings.normalizedOptionalIdentifier(rawName) ?? id
            let isASCIICapable = Self.boolProperty(source, kTISPropertyInputSourceIsASCIICapable)
            let languages = Self.stringArrayProperty(source, kTISPropertyInputSourceLanguages)

            result.append(
                KeyboardInputSource(
                    id: id,
                    localizedName: localizedName,
                    sourceType: sourceType,
                    isASCIICapable: isASCIICapable,
                    languages: languages
                )
            )
        }

        return result
    }

    func currentKeyboardInputSourceID() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return nil
        }
        return AppSettings.normalizedOptionalIdentifier(
            Self.stringProperty(source, kTISPropertyInputSourceID)
        )
    }

    func currentASCIICapableLayoutInputSourceID() -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue() else {
            return nil
        }
        return AppSettings.normalizedOptionalIdentifier(
            Self.stringProperty(source, kTISPropertyInputSourceID)
        )
    }

    @discardableResult
    func selectInputSource(id: String) -> OSStatus {
        guard let normalizedID = AppSettings.normalizedOptionalIdentifier(id) else {
            return OSStatus(paramErr)
        }
        let allowedTypes = Self.allowedSourceTypes
        for source in enabledSelectableTISInputSources() {
            guard let sourceID = AppSettings.normalizedOptionalIdentifier(
                Self.stringProperty(source, kTISPropertyInputSourceID)
            ),
            sourceID == normalizedID else {
                continue
            }
            if let sourceType = Self.stringProperty(source, kTISPropertyInputSourceType),
               !allowedTypes.contains(sourceType) {
                continue
            }
            return TISSelectInputSource(source)
        }
        return OSStatus(paramErr)
    }

    func frontmostApplication() -> RunningAppSnapshot? {
        guard let application = NSWorkspace.shared.frontmostApplication else {
            return nil
        }
        return RunningAppSnapshot(
            bundleIdentifier: application.bundleIdentifier,
            localizedName: application.localizedName ?? "",
            activationPolicy: application.activationPolicy,
            processIdentifier: application.processIdentifier
        )
    }

    func isAccessibilityTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    func spotlightActivityState(wasSpotlightActive: Bool) -> SpotlightActivityState {
        guard AXIsProcessTrusted() else {
            return .inactive
        }

        let spotlightApps = NSWorkspace.shared.runningApplications.filter { app in
            !app.isTerminated && AppSettings.spotlightHostBundleIdentifiers.contains(app.bundleIdentifier ?? "")
        }
        guard !spotlightApps.isEmpty else {
            return .inactive
        }

        let spotlightPIDs = Set(spotlightApps.map(\.processIdentifier))

        // Signal A (Primary — system-wide keyboard focus):
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
           let focusedRef,
           CFGetTypeID(focusedRef) == AXUIElementGetTypeID() {
            let focusedElement = focusedRef as! AXUIElement
            var focusedPID: pid_t = 0
            if AXUIElementGetPid(focusedElement, &focusedPID) == .success, focusedPID > 0 {
                return spotlightPIDs.contains(focusedPID) ? .activeFocusedElement : .inactive
            }
        }

        // Signal B (Fallback when focused UI element is temporarily nil, e.g. arrowing Spotlight result rows):
        if let frontmostID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           AppSettings.spotlightHostBundleIdentifiers.contains(frontmostID) {
            return .activeFocusedElement
        }

        for app in spotlightApps where !app.isHidden {
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            if Self.boolAXAttribute(appElement, kAXHiddenAttribute as CFString) == true {
                continue
            }
            var appFocusedElement: CFTypeRef?
            let hasAppFocusedElement = AXUIElementCopyAttributeValue(
                appElement,
                kAXFocusedUIElementAttribute as CFString,
                &appFocusedElement
            ) == .success && appFocusedElement != nil
            guard wasSpotlightActive || hasAppFocusedElement else {
                continue
            }
            if Self.hasVisibleSpotlightWindow(appElement) {
                return .activeFallbackWindow
            }
        }

        return .inactive
    }

    fileprivate nonisolated static func allCandidateWindows(of appElement: AXUIElement) -> [AXUIElement] {
        var result: [AXUIElement] = []
        func appendUnique(_ candidate: AXUIElement?) {
            guard let candidate else { return }
            if !result.contains(where: { CFEqual($0, candidate) }) {
                result.append(candidate)
            }
        }
        appendUnique(axElementAttribute(appElement, kAXFocusedWindowAttribute as CFString))
        appendUnique(axElementAttribute(appElement, kAXMainWindowAttribute as CFString))
        for window in axElementsAttribute(appElement, kAXWindowsAttribute as CFString) {
            appendUnique(window)
        }
        return result
    }

    private nonisolated static func hasVisibleSpotlightWindow(_ appElement: AXUIElement) -> Bool {
        for window in allCandidateWindows(of: appElement) {
            if boolAXAttribute(window, kAXMinimizedAttribute as CFString) == true {
                continue
            }
            if boolAXAttribute(window, kAXHiddenAttribute as CFString) == true {
                continue
            }
            guard let size = sizeAXAttribute(window, kAXSizeAttribute as CFString),
                  size.width >= 200,
                  size.height >= 36 else {
                continue
            }
            return true
        }
        return false
    }

    private nonisolated static func boolAXAttribute(_ element: AXUIElement, _ attribute: CFString) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value else {
            return nil
        }
        if CFGetTypeID(value) == CFBooleanGetTypeID() {
            return CFBooleanGetValue((value as! CFBoolean))
        }
        return value as? Bool
    }

    private nonisolated static func sizeAXAttribute(_ element: AXUIElement, _ attribute: CFString) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cgSize else {
            return nil
        }
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else {
            return nil
        }
        return size
    }

    private nonisolated static func axElementAttribute(_ element: AXUIElement, _ attribute: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private nonisolated static func axElementsAttribute(_ element: AXUIElement, _ attribute: CFString) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == CFArrayGetTypeID() else {
            return []
        }
        let cfArray = value as! CFArray
        return withExtendedLifetime(cfArray) {
            let count = CFArrayGetCount(cfArray)
            guard count > 0 else { return [] }
            var elements: [AXUIElement] = []
            elements.reserveCapacity(count)
            for index in 0..<count {
                guard let pointer = CFArrayGetValueAtIndex(cfArray, index) else { continue }
                let candidate = Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
                if CFGetTypeID(candidate) == AXUIElementGetTypeID() {
                    elements.append(candidate as! AXUIElement)
                }
            }
            return elements
        }
    }

    private func enabledSelectableTISInputSources() -> [TISInputSource] {
        let filter: [String: Any] = [
            Self.tisString(kTISPropertyInputSourceCategory): Self.cfString(kTISCategoryKeyboardInputSource),
            Self.tisString(kTISPropertyInputSourceIsSelectCapable): Self.cfBoolean(kCFBooleanTrue),
            Self.tisString(kTISPropertyInputSourceIsEnabled): Self.cfBoolean(kCFBooleanTrue),
        ]
        guard let cfArray = TISCreateInputSourceList(filter as CFDictionary, false)?.takeRetainedValue() else {
            return []
        }
        return withExtendedLifetime(cfArray) {
            let count = CFArrayGetCount(cfArray)
            guard count > 0 else { return [] }
            var sources: [TISInputSource] = []
            sources.reserveCapacity(count)
            for index in 0..<count {
                guard let pointer = CFArrayGetValueAtIndex(cfArray, index) else { continue }
                sources.append(Unmanaged<TISInputSource>.fromOpaque(pointer).takeUnretainedValue())
            }
            return sources
        }
    }

    private static func propertyObject(_ source: TISInputSource, _ key: CFString) -> AnyObject? {
        guard let pointer = TISGetInputSourceProperty(source, key) else {
            return nil
        }
        return Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
    }

    private static func stringProperty(_ source: TISInputSource, _ key: CFString) -> String? {
        propertyObject(source, key) as? String
    }

    private static func boolProperty(_ source: TISInputSource, _ key: CFString) -> Bool {
        guard let object = propertyObject(source, key) else {
            return false
        }
        if CFGetTypeID(object) == CFBooleanGetTypeID() {
            return CFBooleanGetValue((object as! CFBoolean))
        }
        return (object as? Bool) ?? false
    }

    private static func stringArrayProperty(_ source: TISInputSource, _ key: CFString) -> [String] {
        (propertyObject(source, key) as? [String]) ?? []
    }
}

private final class AXObserverCallbackContext: @unchecked Sendable {
    private let lock = NSLock()
    private weak var _service: InputSourceSwitchingService?
    let pid: pid_t
    let isSpotlightHost: Bool
    private var isInvalidated = false

    var service: InputSourceSwitchingService? {
        get {
            lock.lock()
            defer { lock.unlock() }
            guard !isInvalidated else { return nil }
            return _service
        }
        set {
            lock.lock()
            _service = newValue
            if newValue == nil {
                isInvalidated = true
            }
            lock.unlock()
        }
    }

    init(service: InputSourceSwitchingService, pid: pid_t, isSpotlightHost: Bool) {
        self._service = service
        self.pid = pid
        self.isSpotlightHost = isSpotlightHost
    }

    func invalidate() {
        lock.lock()
        isInvalidated = true
        _service = nil
        lock.unlock()
    }

    func currentServiceIfValid() -> InputSourceSwitchingService? {
        lock.lock()
        defer { lock.unlock() }
        guard !isInvalidated else { return nil }
        return _service
    }
}

private final class AXObserverRegistration: @unchecked Sendable {
    let pid: pid_t
    let observer: AXObserver
    private let lock = NSLock()
    private let callbackContext: AXObserverCallbackContext
    private var isInvalidated = false

    init(pid: pid_t, observer: AXObserver, callbackContext: AXObserverCallbackContext) {
        self.pid = pid
        self.observer = observer
        self.callbackContext = callbackContext
    }

    var contextPointer: UnsafeMutableRawPointer {
        Unmanaged.passUnretained(callbackContext).toOpaque()
    }

    func invalidate() {
        lock.lock()
        guard !isInvalidated else {
            lock.unlock()
            return
        }
        isInvalidated = true
        lock.unlock()

        callbackContext.service = nil
        callbackContext.invalidate()
        let mainRunLoop = CFRunLoopGetMain()
        CFRunLoopRemoveSource(
            mainRunLoop,
            AXObserverGetRunLoopSource(observer),
            .commonModes
        )
        if !Thread.isMainThread {
            let retainedObserver = observer
            let retainedContext = callbackContext
            CFRunLoopPerformBlock(mainRunLoop, CFRunLoopMode.commonModes.rawValue) {
                withExtendedLifetime((retainedObserver, retainedContext)) {}
            }
            CFRunLoopWakeUp(mainRunLoop)
        }
    }

    deinit {
        invalidate()
    }
}

private final class ObserverRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var workspaceObservers: [NSObjectProtocol] = []
    private var distributedObserver: NSObjectProtocol?
    private var spotlightObservers: [pid_t: AXObserverRegistration] = [:]
    private var temporaryUnderlyingObserver: AXObserverRegistration?

    var hasWorkspaceObservers: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !workspaceObservers.isEmpty
    }

    func setWorkspaceObservers(_ observers: [NSObjectProtocol]) {
        lock.lock()
        let previous = workspaceObservers
        workspaceObservers = observers
        lock.unlock()

        let center = NSWorkspace.shared.notificationCenter
        previous.forEach(center.removeObserver)
    }

    var hasDistributedObserver: Bool {
        lock.lock()
        defer { lock.unlock() }
        return distributedObserver != nil
    }

    func setDistributedObserver(_ observer: NSObjectProtocol) {
        lock.lock()
        let previous = distributedObserver
        distributedObserver = observer
        lock.unlock()

        if let previous {
            DistributedNotificationCenter.default().removeObserver(previous)
        }
    }

    var hasSpotlightObservers: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !spotlightObservers.isEmpty
    }

    func hasSpotlightObserver(for pid: pid_t) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return spotlightObservers[pid] != nil
    }

    func spotlightObserverPIDs() -> Set<pid_t> {
        lock.lock()
        defer { lock.unlock() }
        return Set(spotlightObservers.keys)
    }

    func setSpotlightObserver(_ registration: AXObserverRegistration, for pid: pid_t) {
        lock.lock()
        let previous = spotlightObservers.updateValue(registration, forKey: pid)
        lock.unlock()

        previous?.invalidate()
    }

    func removeSpotlightObserver(for pid: pid_t) {
        lock.lock()
        let removed = spotlightObservers.removeValue(forKey: pid)
        lock.unlock()

        removed?.invalidate()
    }

    func temporaryUnderlyingObserverPID() -> pid_t? {
        lock.lock()
        defer { lock.unlock() }
        return temporaryUnderlyingObserver?.pid
    }

    func setTemporaryUnderlyingObserver(_ registration: AXObserverRegistration) {
        lock.lock()
        let previous = temporaryUnderlyingObserver
        temporaryUnderlyingObserver = registration
        lock.unlock()

        previous?.invalidate()
    }

    func removeTemporaryUnderlyingObserver() {
        lock.lock()
        let removed = temporaryUnderlyingObserver
        temporaryUnderlyingObserver = nil
        lock.unlock()

        removed?.invalidate()
    }

    func removeAll() {
        lock.lock()
        let workspaceTokens = workspaceObservers
        workspaceObservers.removeAll()
        let distributedToken = distributedObserver
        distributedObserver = nil
        let spotlightRegistrations = Array(spotlightObservers.values)
        spotlightObservers.removeAll()
        let temporaryRegistration = temporaryUnderlyingObserver
        temporaryUnderlyingObserver = nil
        lock.unlock()

        temporaryRegistration?.invalidate()
        spotlightRegistrations.forEach { $0.invalidate() }

        let center = NSWorkspace.shared.notificationCenter
        workspaceTokens.forEach(center.removeObserver)
        if let distributedToken {
            DistributedNotificationCenter.default().removeObserver(distributedToken)
        }
    }
}

private func registerSpotlightWindowNotifications(
    observer: AXObserver,
    windowElement: AXUIElement,
    context: UnsafeMutableRawPointer
) {
    _ = AXObserverAddNotification(
        observer,
        windowElement,
        kAXUIElementDestroyedNotification as CFString,
        context
    )
    _ = AXObserverAddNotification(
        observer,
        windowElement,
        kAXWindowMiniaturizedNotification as CFString,
        context
    )
}

private func spotlightAXObserverCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ context: UnsafeMutableRawPointer?
) {
    guard let context else { return }
    let callbackContext = Unmanaged<AXObserverCallbackContext>
        .fromOpaque(context)
        .takeUnretainedValue()
    guard let service = callbackContext.currentServiceIfValid() else { return }

    if callbackContext.isSpotlightHost,
       (notification as String) == (kAXWindowCreatedNotification as String) {
        registerSpotlightWindowNotifications(
            observer: observer,
            windowElement: element,
            context: context
        )
    }

    Task { @MainActor [weak service] in
        service?.handleSpotlightActivityEvent()
    }
}

@MainActor
final class InputSourceSwitchingService {
    nonisolated static let preferredEnglishFallbackIDs = [
        "com.apple.keylayout.ABC",
        "com.apple.keylayout.US",
        "com.apple.keylayout.USInternational-PC",
        "com.apple.keylayout.British",
    ]

    nonisolated static var defaultIgnoredBundleIdentifiers: Set<String> {
        AppSettings.systemIgnoredBundleIdentifiers
    }

    private struct SwitchTarget: Sendable {
        var bundleID: String
        var localizedName: String
        var isSpotlight: Bool
    }

    private nonisolated static let spotlightAppNotifications: [String] = [
        kAXWindowCreatedNotification,
        kAXUIElementDestroyedNotification,
        kAXFocusedWindowChangedNotification,
        kAXMainWindowChangedNotification,
        kAXFocusedUIElementChangedNotification,
        kAXApplicationActivatedNotification,
        kAXApplicationDeactivatedNotification,
        kAXApplicationShownNotification,
        kAXApplicationHiddenNotification,
    ]

    private nonisolated static let underlyingAppNotifications: [String] = [
        kAXFocusedUIElementChangedNotification,
        kAXFocusedWindowChangedNotification,
        kAXApplicationActivatedNotification,
    ]

    private nonisolated static let requiredObserverNotifications: Set<String> = [
        kAXFocusedUIElementChangedNotification,
        kAXWindowCreatedNotification,
        kAXApplicationActivatedNotification,
    ]

    var onStatusChange: ((InputSourceSwitchingStatus) -> Void)?
    var onAvailableSourcesChange: (([KeyboardInputSource]) -> Void)?

    private(set) var currentStatus: InputSourceSwitchingStatus = .disabled

    private let logger: AppLogger
    private let backend: any InputSourceBackend
    private let settleDelay: Duration
    private let verificationDelay: Duration
    private let fallbackSettleDelay: Duration
    private let ignoredBundleIdentifiers: Set<String>
    private let observerRegistry = ObserverRegistry()

    private var isEnabled = false
    private var isSpotlightOverlayActive = false
    private var pendingActivatedApp: RunningAppSnapshot?
    private var preferredDefaultEnglishInputSourceID: String?
    private var rules: [AppInputSourceRule] = []
    private var rulesByBundleID: [String: AppInputSourceRule] = [:]
    private var lastActiveDefaultEnglishInputSourceID: String?
    private var lastActiveRules: [AppInputSourceRule] = []
    private var hasConfiguredActiveState = false
    private var cachedAvailableSources: [KeyboardInputSource] = []
    private var hasLoadedAvailableSources = false
    private var lastKnownAutoEnglishLayoutID: String?
    private var hasQueriedAutoEnglishLayoutID = false
    private var switchTask: Task<Void, Never>?

    init(
        logger: AppLogger,
        backend: (any InputSourceBackend)? = nil,
        settleDelay: Duration = .milliseconds(35),
        verificationDelay: Duration = .milliseconds(60),
        fallbackSettleDelay: Duration = .milliseconds(180),
        ignoredBundleIdentifiers: Set<String>? = nil
    ) {
        self.logger = logger
        self.backend = backend ?? CarbonInputSourceBackend()
        self.settleDelay = settleDelay
        self.verificationDelay = verificationDelay
        self.fallbackSettleDelay = fallbackSettleDelay
        if let ignoredBundleIdentifiers {
            self.ignoredBundleIdentifiers = Set(
                ignoredBundleIdentifiers.compactMap(AppSettings.normalizedOptionalIdentifier)
            )
        } else {
            self.ignoredBundleIdentifiers = Self.defaultIgnoredBundleIdentifiers
        }
    }

    deinit {
        switchTask?.cancel()
        observerRegistry.removeAll()
    }

    func availableInputSources(forceRefresh: Bool = false) -> [KeyboardInputSource] {
        if forceRefresh {
            hasQueriedAutoEnglishLayoutID = false
        }
        if forceRefresh || !hasLoadedAvailableSources || cachedAvailableSources.isEmpty {
            let refreshed = backend.selectableKeyboardInputSources()
            let didChange = hasLoadedAvailableSources && refreshed != cachedAvailableSources
            cachedAvailableSources = refreshed
            hasLoadedAvailableSources = true
            if let lastID = lastKnownAutoEnglishLayoutID,
               !refreshed.contains(where: { $0.id == lastID && Self.isValidEnglishASCIILayout($0) }) {
                lastKnownAutoEnglishLayoutID = nil
            }
            if forceRefresh {
                sampleCurrentAutoEnglishLayoutID(sources: refreshed)
            }
            if didChange {
                onAvailableSourcesChange?(refreshed)
            }
        }
        return cachedAvailableSources
    }

    func automaticDefaultEnglishInputSource() -> KeyboardInputSource? {
        if !hasLoadedAvailableSources {
            _ = availableInputSources()
        }
        return Self.resolveDefaultEnglishInputSource(
            preferredID: nil,
            availableSources: cachedAvailableSources,
            currentASCIILayoutID: cachedCurrentASCIILayoutID
        )
    }

    func resolvedDefaultEnglishInputSource(preferredID: String?) -> KeyboardInputSource? {
        if !hasLoadedAvailableSources {
            _ = availableInputSources()
        }
        return Self.resolveDefaultEnglishInputSource(
            preferredID: preferredID,
            availableSources: cachedAvailableSources,
            currentASCIILayoutID: cachedCurrentASCIILayoutID
        )
    }

    nonisolated private static func isEnglishLanguageCode(_ code: String) -> Bool {
        code == "en" || code.hasPrefix("en-") || code.hasPrefix("en_")
    }

    nonisolated private static func isValidEnglishASCIILayout(_ source: KeyboardInputSource) -> Bool {
        let keyboardLayoutType = CarbonInputSourceBackend.tisString(kTISTypeKeyboardLayout)
        return source.sourceType == keyboardLayoutType &&
            source.isASCIICapable &&
            (preferredEnglishFallbackIDs.contains(source.id) ||
             source.languages.contains(where: isEnglishLanguageCode))
    }

    nonisolated static func resolveDefaultEnglishInputSource(
        preferredID: String?,
        availableSources: [KeyboardInputSource],
        currentASCIILayoutID: String?
    ) -> KeyboardInputSource? {
        if let normalizedPreferredID = AppSettings.normalizedOptionalIdentifier(preferredID),
           let preferredSource = availableSources.first(where: { $0.id == normalizedPreferredID }) {
            return preferredSource
        }

        let keyboardLayoutType = CarbonInputSourceBackend.tisString(kTISTypeKeyboardLayout)

        if let normalizedASCIILayoutID = AppSettings.normalizedOptionalIdentifier(currentASCIILayoutID),
           let asciiLayoutSource = availableSources.first(where: {
               $0.id == normalizedASCIILayoutID && isValidEnglishASCIILayout($0)
           }) {
            return asciiLayoutSource
        }

        for fallbackID in preferredEnglishFallbackIDs {
            if let match = availableSources.first(where: { $0.id == fallbackID }) {
                return match
            }
        }

        if let englishLayout = availableSources.first(where: { source in
            source.sourceType == keyboardLayoutType &&
            source.isASCIICapable &&
            source.languages.contains(where: { isEnglishLanguageCode($0.lowercased()) })
        }) {
            return englishLayout
        }

        if let asciiLayout = availableSources.first(where: { source in
            source.sourceType == keyboardLayoutType && source.isASCIICapable
        }) {
            return asciiLayout
        }

        return availableSources.first(where: \.isASCIICapable)
    }

    func configure(
        enabled: Bool,
        defaultEnglishInputSourceID: String?,
        rules: [AppInputSourceRule]
    ) {
        let wasEnabled = isEnabled
        let normalizedDefaultEnglishID = AppSettings.normalizedOptionalIdentifier(defaultEnglishInputSourceID)
        let normalizedRules = AppSettings.normalizedAppInputSourceRules(rules)
        let configurationChangedSinceLastActive = !hasConfiguredActiveState
            || normalizedDefaultEnglishID != lastActiveDefaultEnglishInputSourceID
            || normalizedRules != lastActiveRules

        preferredDefaultEnglishInputSourceID = normalizedDefaultEnglishID
        self.rules = normalizedRules
        self.rulesByBundleID = Dictionary(
            normalizedRules.map { ($0.bundleIdentifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        if cachedAvailableSources.isEmpty {
            _ = availableInputSources(forceRefresh: true)
        }

        guard enabled else {
            stop()
            return
        }

        isEnabled = true
        lastActiveDefaultEnglishInputSourceID = normalizedDefaultEnglishID
        lastActiveRules = normalizedRules
        hasConfiguredActiveState = true

        installObserversIfNeeded()
        updateStatus(computeBaselineStatus())

        if !wasEnabled || configurationChangedSinceLastActive {
            if backend.spotlightActivityState(wasSpotlightActive: isSpotlightOverlayActive) != .inactive {
                handleSpotlightActivityEvent()
            } else if let frontmostApp = backend.frontmostApplication(),
                      eligibleBundleIdentifier(for: frontmostApp) != nil {
                handleApplicationActivated(frontmostApp)
            }
        }
    }

    func stop() {
        isEnabled = false
        isSpotlightOverlayActive = false
        pendingActivatedApp = nil
        switchTask?.cancel()
        switchTask = nil
        removeObservers()
        updateStatus(.disabled)
    }

    func handleSpotlightActivityEvent() {
        guard isEnabled else {
            return
        }
        switchTask?.cancel()
        switchTask = Task<Void, Never> { @MainActor [weak self] in
            await self?.evaluateAndPerformCurrentTargetSwitch()
        }
    }

    func performSpotlightCheckForTesting() async {
        guard isEnabled else {
            return
        }
        switchTask?.cancel()
        let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            await self.evaluateAndPerformCurrentTargetSwitch()
        }
        switchTask = task
        await task.value
    }

    func handleApplicationActivated(_ app: RunningAppSnapshot) {
        guard isEnabled else {
            return
        }
        if backend.isAccessibilityTrusted() {
            installSpotlightObserversIfNeeded()
        }
        guard let bundleID = eligibleBundleIdentifier(for: app) else {
            return
        }
        pendingActivatedApp = app
        switchTask?.cancel()
        switchTask = Task<Void, Never> { @MainActor [weak self] in
            await self?.performSwitch(for: app, bundleID: bundleID)
        }
    }

    func performSwitchForTesting(_ app: RunningAppSnapshot) async {
        guard isEnabled else {
            return
        }
        if backend.isAccessibilityTrusted() {
            installSpotlightObserversIfNeeded()
        }
        guard let bundleID = eligibleBundleIdentifier(for: app) else {
            return
        }
        pendingActivatedApp = app
        switchTask?.cancel()
        let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            await self.performSwitch(for: app, bundleID: bundleID)
        }
        switchTask = task
        await task.value
    }

    // MARK: - Private Helpers

    private func installObserversIfNeeded() {
        if !observerRegistry.hasWorkspaceObservers {
            let notificationCenter = NSWorkspace.shared.notificationCenter

            let activateToken = notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let runningApp = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                    return
                }
                let snapshot = RunningAppSnapshot(
                    bundleIdentifier: runningApp.bundleIdentifier,
                    localizedName: runningApp.localizedName ?? "",
                    activationPolicy: runningApp.activationPolicy,
                    processIdentifier: runningApp.processIdentifier
                )
                Task { @MainActor [weak self] in
                    self?.handleApplicationActivated(snapshot)
                }
            }

            let launchToken = notificationCenter.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let runningApp = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                    return
                }
                let bundleID = AppSettings.normalizedOptionalIdentifier(runningApp.bundleIdentifier)
                let pid = runningApp.processIdentifier
                guard let bundleID, AppSettings.spotlightHostBundleIdentifiers.contains(bundleID) else {
                    return
                }
                Task { @MainActor [weak self] in
                    self?.handleSpotlightHostLaunched(pid: pid)
                }
            }

            let terminateToken = notificationCenter.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let runningApp = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                    return
                }
                let bundleID = AppSettings.normalizedOptionalIdentifier(runningApp.bundleIdentifier)
                let pid = runningApp.processIdentifier
                let isSpotlightHost = bundleID.map { AppSettings.spotlightHostBundleIdentifiers.contains($0) } ?? false
                Task { @MainActor [weak self] in
                    self?.handleApplicationTerminated(pid: pid, isSpotlightHost: isSpotlightHost)
                }
            }

            observerRegistry.setWorkspaceObservers([activateToken, launchToken, terminateToken])
        }

        if !observerRegistry.hasDistributedObserver {
            let notificationName = Notification.Name(
                CarbonInputSourceBackend.tisString(kTISNotifyEnabledKeyboardInputSourcesChanged)
            )
            let token = DistributedNotificationCenter.default().addObserver(
                forName: notificationName,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleEnabledInputSourcesChanged()
                }
            }
            observerRegistry.setDistributedObserver(token)
        }

        installSpotlightObserversIfNeeded()
    }

    private func removeObservers() {
        observerRegistry.removeAll()
    }

    private func installSpotlightObserversIfNeeded() {
        guard isEnabled, backend.isAccessibilityTrusted() else {
            return
        }

        let runningSpotlightApps = NSWorkspace.shared.runningApplications.filter { app in
            guard !app.isTerminated,
                  app.processIdentifier > 0,
                  let bundleID = AppSettings.normalizedOptionalIdentifier(app.bundleIdentifier) else {
                return false
            }
            return AppSettings.spotlightHostBundleIdentifiers.contains(bundleID)
        }

        let runningPIDs = Set(runningSpotlightApps.map(\.processIdentifier))
        for existingPID in observerRegistry.spotlightObserverPIDs() where !runningPIDs.contains(existingPID) {
            observerRegistry.removeSpotlightObserver(for: existingPID)
        }

        for app in runningSpotlightApps where !observerRegistry.hasSpotlightObserver(for: app.processIdentifier) {
            installSpotlightObserver(for: app.processIdentifier)
        }
    }

    private func installSpotlightObserver(for pid: pid_t) {
        guard pid > 0, backend.isAccessibilityTrusted() else {
            return
        }

        var observer: AXObserver?
        guard AXObserverCreate(pid, spotlightAXObserverCallback, &observer) == .success,
              let observer else {
            return
        }

        let callbackContext = AXObserverCallbackContext(service: self, pid: pid, isSpotlightHost: true)
        let registration = AXObserverRegistration(pid: pid, observer: observer, callbackContext: callbackContext)
        let context = registration.contextPointer
        let appElement = AXUIElementCreateApplication(pid)

        var hasRequiredNotification = false
        for notification in Self.spotlightAppNotifications {
            let error = AXObserverAddNotification(observer, appElement, notification as CFString, context)
            if error == .success,
               Self.requiredObserverNotifications.contains(notification) {
                hasRequiredNotification = true
            }
        }

        guard hasRequiredNotification else {
            registration.invalidate()
            return
        }

        for windowElement in CarbonInputSourceBackend.allCandidateWindows(of: appElement) {
            registerSpotlightWindowNotifications(
                observer: observer,
                windowElement: windowElement,
                context: context
            )
        }

        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .commonModes
        )
        observerRegistry.setSpotlightObserver(registration, for: pid)
    }

    private func updateTemporaryUnderlyingAppObserver(frontmostApp: RunningAppSnapshot?) {
        guard isEnabled,
              isSpotlightOverlayActive,
              backend.isAccessibilityTrusted(),
              let frontmostApp,
              frontmostApp.processIdentifier > 0,
              frontmostApp.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let rawBundleID = AppSettings.normalizedOptionalIdentifier(frontmostApp.bundleIdentifier),
              !AppSettings.spotlightHostBundleIdentifiers.contains(rawBundleID),
              !Self.isDaydreamBundleIdentifier(rawBundleID),
              !ignoredBundleIdentifiers.contains(rawBundleID) else {
            observerRegistry.removeTemporaryUnderlyingObserver()
            return
        }

        let pid = frontmostApp.processIdentifier
        if observerRegistry.temporaryUnderlyingObserverPID() == pid {
            return
        }

        observerRegistry.removeTemporaryUnderlyingObserver()

        var observer: AXObserver?
        guard AXObserverCreate(pid, spotlightAXObserverCallback, &observer) == .success,
              let observer else {
            return
        }

        let callbackContext = AXObserverCallbackContext(service: self, pid: pid, isSpotlightHost: false)
        let registration = AXObserverRegistration(pid: pid, observer: observer, callbackContext: callbackContext)
        let context = registration.contextPointer
        let appElement = AXUIElementCreateApplication(pid)

        var hasRequiredNotification = false
        for notification in Self.underlyingAppNotifications {
            let error = AXObserverAddNotification(observer, appElement, notification as CFString, context)
            if error == .success,
               Self.requiredObserverNotifications.contains(notification) {
                hasRequiredNotification = true
            }
        }

        guard hasRequiredNotification else {
            registration.invalidate()
            return
        }

        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .commonModes
        )
        observerRegistry.setTemporaryUnderlyingObserver(registration)
    }

    private func handleSpotlightHostLaunched(pid: pid_t) {
        guard isEnabled else {
            return
        }
        if backend.isAccessibilityTrusted() {
            installSpotlightObserver(for: pid)
        }
        handleSpotlightActivityEvent()
    }

    private func handleApplicationTerminated(pid: pid_t, isSpotlightHost: Bool) {
        guard isEnabled else {
            return
        }
        if observerRegistry.temporaryUnderlyingObserverPID() == pid {
            observerRegistry.removeTemporaryUnderlyingObserver()
        }
        if isSpotlightHost || observerRegistry.hasSpotlightObserver(for: pid) {
            observerRegistry.removeSpotlightObserver(for: pid)
            if isSpotlightOverlayActive {
                handleSpotlightActivityEvent()
            }
        }
    }

    private func handleEnabledInputSourcesChanged() {
        lastKnownAutoEnglishLayoutID = nil
        hasQueriedAutoEnglishLayoutID = false
        let refreshed = backend.selectableKeyboardInputSources()
        cachedAvailableSources = refreshed
        hasLoadedAvailableSources = true
        onAvailableSourcesChange?(refreshed)
        if isEnabled {
            updateStatus(computeBaselineStatus())
        }
    }

    private nonisolated static func isSpotlightHostApplication(_ app: RunningAppSnapshot?) -> Bool {
        guard let rawBundleID = AppSettings.normalizedOptionalIdentifier(app?.bundleIdentifier) else {
            return false
        }
        return AppSettings.spotlightHostBundleIdentifiers.contains(rawBundleID)
    }

    private nonisolated static func isDaydreamBundleIdentifier(_ bundleID: String) -> Bool {
        if bundleID == "Homer.daydream" {
            return true
        }
        if let mainBundleID = AppSettings.normalizedOptionalIdentifier(Bundle.main.bundleIdentifier),
           bundleID == mainBundleID {
            return true
        }
        return false
    }

    private func eligibleBundleIdentifier(for app: RunningAppSnapshot) -> String? {
        guard let rawBundleID = AppSettings.normalizedOptionalIdentifier(app.bundleIdentifier),
              !ignoredBundleIdentifiers.contains(rawBundleID) else {
            return nil
        }
        if AppSettings.spotlightHostBundleIdentifiers.contains(rawBundleID) {
            guard !ignoredBundleIdentifiers.contains(AppSettings.spotlightBundleIdentifier) else {
                return nil
            }
            return AppSettings.spotlightBundleIdentifier
        }
        guard app.activationPolicy == .regular || rulesByBundleID[rawBundleID]?.isEnabled == true else {
            return nil
        }
        return rawBundleID
    }

    private var activeRuleCount: Int {
        rules.filter(\.isEnabled).count
    }

    private var cachedCurrentASCIILayoutID: String? {
        if let lastID = lastKnownAutoEnglishLayoutID,
           cachedAvailableSources.contains(where: { $0.id == lastID && Self.isValidEnglishASCIILayout($0) }) {
            return lastID
        }
        lastKnownAutoEnglishLayoutID = nil
        if !hasQueriedAutoEnglishLayoutID {
            sampleCurrentAutoEnglishLayoutID(sources: cachedAvailableSources)
        }
        return lastKnownAutoEnglishLayoutID
    }

    @discardableResult
    private func sampleCurrentAutoEnglishLayoutID(sources: [KeyboardInputSource]) -> String? {
        hasQueriedAutoEnglishLayoutID = true
        if let lastID = lastKnownAutoEnglishLayoutID,
           !sources.contains(where: { $0.id == lastID && Self.isValidEnglishASCIILayout($0) }) {
            lastKnownAutoEnglishLayoutID = nil
        }
        if let currentASCIIID = AppSettings.normalizedOptionalIdentifier(
            backend.currentASCIICapableLayoutInputSourceID()
        ),
        sources.contains(where: { $0.id == currentASCIIID && Self.isValidEnglishASCIILayout($0) }) {
            lastKnownAutoEnglishLayoutID = currentASCIIID
        }
        return lastKnownAutoEnglishLayoutID
    }

    private func resolveCurrentDefaultEnglishSource(sources: [KeyboardInputSource]) -> KeyboardInputSource? {
        let currentASCIIID = sampleCurrentAutoEnglishLayoutID(sources: sources)
        return Self.resolveDefaultEnglishInputSource(
            preferredID: preferredDefaultEnglishInputSourceID,
            availableSources: sources,
            currentASCIILayoutID: currentASCIIID
        )
    }

    private func computeBaselineStatus() -> InputSourceSwitchingStatus {
        guard let englishSource = resolveCurrentDefaultEnglishSource(sources: cachedAvailableSources) else {
            return .warning("No English input source available")
        }
        return .active(defaultEnglishName: englishSource.localizedName, activeRuleCount: activeRuleCount)
    }

    private func updateStatus(_ status: InputSourceSwitchingStatus) {
        guard status != currentStatus else { return }
        currentStatus = status
        onStatusChange?(status)
    }

    private func performSwitch(for app: RunningAppSnapshot, bundleID: String) async {
        await evaluateAndPerformCurrentTargetSwitch(
            activatedApp: app,
            activatedBundleID: bundleID
        )
    }

    private func resolvePostSpotlightTarget(
        pendingApp: RunningAppSnapshot?,
        frontmostApp: RunningAppSnapshot?
    ) -> SwitchTarget? {
        if let pendingApp,
           let pendingBundleID = eligibleBundleIdentifier(for: pendingApp),
           pendingBundleID != AppSettings.spotlightBundleIdentifier,
           let frontmostApp,
           eligibleBundleIdentifier(for: frontmostApp) == pendingBundleID {
            let displayName = pendingApp.localizedName.isEmpty
                ? frontmostApp.localizedName
                : pendingApp.localizedName
            return SwitchTarget(
                bundleID: pendingBundleID,
                localizedName: displayName,
                isSpotlight: false
            )
        }
        guard let frontmostApp,
              let currentBundleID = eligibleBundleIdentifier(for: frontmostApp),
              currentBundleID != AppSettings.spotlightBundleIdentifier else {
            return nil
        }
        return SwitchTarget(
            bundleID: currentBundleID,
            localizedName: frontmostApp.localizedName,
            isSpotlight: false
        )
    }

    private func evaluateAndPerformCurrentTargetSwitch(
        activatedApp: RunningAppSnapshot? = nil,
        activatedBundleID: String? = nil
    ) async {
        do {
            try await Task.sleep(for: settleDelay)
        } catch {
            return
        }

        guard !Task.isCancelled, isEnabled else {
            return
        }

        let wasSpotlightActive = isSpotlightOverlayActive
        let spotlightDetection = backend.spotlightActivityState(wasSpotlightActive: wasSpotlightActive)

        let frontmostSnapshot = backend.frontmostApplication()
        let frontmostIsSpotlightHost = Self.isSpotlightHostApplication(frontmostSnapshot)
        let isSpotlightNowActive = spotlightDetection != .inactive || frontmostIsSpotlightHost

        if isSpotlightNowActive {
            guard !ignoredBundleIdentifiers.contains(AppSettings.spotlightBundleIdentifier) else {
                return
            }

            let matchedOnlyViaSignalB = !frontmostIsSpotlightHost
                && spotlightDetection == .activeFallbackWindow

            isSpotlightOverlayActive = true
            if matchedOnlyViaSignalB {
                if pendingActivatedApp == nil, let activatedApp {
                    pendingActivatedApp = activatedApp
                }
            } else {
                pendingActivatedApp = nil
            }
            updateTemporaryUnderlyingAppObserver(frontmostApp: frontmostSnapshot)

            let spotlightTarget = SwitchTarget(
                bundleID: AppSettings.spotlightBundleIdentifier,
                localizedName: "Spotlight",
                isSpotlight: true
            )
            await applyTargetInputSource(for: spotlightTarget)

            // One-shot animation settle re-check when Spotlight is matched only via Signal B fallback window.
            if matchedOnlyViaSignalB,
               !Task.isCancelled,
               isEnabled,
               isSpotlightOverlayActive {
                do {
                    try await Task.sleep(for: fallbackSettleDelay)
                } catch {
                    return
                }

                guard !Task.isCancelled, isEnabled, isSpotlightOverlayActive else {
                    return
                }

                let postSettleState = backend.spotlightActivityState(wasSpotlightActive: true)
                let postSettleFrontmost = backend.frontmostApplication()
                if postSettleState == .inactive && !Self.isSpotlightHostApplication(postSettleFrontmost) {
                    isSpotlightOverlayActive = false
                    let pendingApp = pendingActivatedApp
                    pendingActivatedApp = nil
                    observerRegistry.removeTemporaryUnderlyingObserver()
                    if let recoveryTarget = resolvePostSpotlightTarget(
                        pendingApp: pendingApp,
                        frontmostApp: postSettleFrontmost
                    ) {
                        await applyTargetInputSource(for: recoveryTarget)
                    }
                } else {
                    pendingActivatedApp = nil
                    updateTemporaryUnderlyingAppObserver(frontmostApp: postSettleFrontmost)
                }
            }
            return
        }

        if isSpotlightOverlayActive {
            isSpotlightOverlayActive = false
        }
        observerRegistry.removeTemporaryUnderlyingObserver()

        if let activatedApp, let activatedBundleID {
            pendingActivatedApp = nil
            if activatedBundleID == AppSettings.spotlightBundleIdentifier {
                guard let currentFrontmost = frontmostSnapshot,
                      let currentBundleID = eligibleBundleIdentifier(for: currentFrontmost),
                      currentBundleID != AppSettings.spotlightBundleIdentifier else {
                    return
                }
                let recoveryTarget = SwitchTarget(
                    bundleID: currentBundleID,
                    localizedName: currentFrontmost.localizedName,
                    isSpotlight: false
                )
                await applyTargetInputSource(for: recoveryTarget)
                return
            }

            guard let currentFrontmost = frontmostSnapshot,
                  eligibleBundleIdentifier(for: currentFrontmost) == activatedBundleID else {
                return
            }
            let displayName = activatedApp.localizedName.isEmpty
                ? currentFrontmost.localizedName
                : activatedApp.localizedName
            let appTarget = SwitchTarget(
                bundleID: activatedBundleID,
                localizedName: displayName,
                isSpotlight: false
            )
            await applyTargetInputSource(for: appTarget)
            return
        }

        if wasSpotlightActive {
            let pendingApp = pendingActivatedApp
            pendingActivatedApp = nil
            guard let recoveryTarget = resolvePostSpotlightTarget(
                pendingApp: pendingApp,
                frontmostApp: frontmostSnapshot
            ) else {
                return
            }
            await applyTargetInputSource(for: recoveryTarget)
            return
        }

        if let interruptedApp = pendingActivatedApp {
            pendingActivatedApp = nil
            guard let interruptedBundleID = eligibleBundleIdentifier(for: interruptedApp),
                  let currentFrontmost = frontmostSnapshot,
                  eligibleBundleIdentifier(for: currentFrontmost) == interruptedBundleID else {
                return
            }
            let displayName = interruptedApp.localizedName.isEmpty
                ? currentFrontmost.localizedName
                : interruptedApp.localizedName
            let appTarget = SwitchTarget(
                bundleID: interruptedBundleID,
                localizedName: displayName,
                isSpotlight: false
            )
            await applyTargetInputSource(for: appTarget)
        }
    }

    private func isTargetStillCurrent(_ target: SwitchTarget) -> Bool {
        let spotlightActive = backend.spotlightActivityState(wasSpotlightActive: isSpotlightOverlayActive) != .inactive
            || Self.isSpotlightHostApplication(backend.frontmostApplication())
        if target.isSpotlight {
            return spotlightActive
        }
        guard !spotlightActive,
              let frontmost = backend.frontmostApplication(),
              eligibleBundleIdentifier(for: frontmost) == target.bundleID else {
            return false
        }
        return true
    }

    private func applyTargetInputSource(for target: SwitchTarget) async {
        let bundleID = target.bundleID
        let targetSource: KeyboardInputSource
        let resolvedEnglishName: String?

        if let enabledRule = rulesByBundleID[bundleID], enabledRule.isEnabled {
            let matchingSource = cachedAvailableSources.first(where: { $0.id == enabledRule.inputSourceID })
                ?? availableInputSources(forceRefresh: true).first(where: { $0.id == enabledRule.inputSourceID })

            guard let matchingSource else {
                let displayName = target.localizedName.isEmpty ? enabledRule.appName : target.localizedName
                updateStatus(.warning("Input source unavailable for \(displayName)"))
                await logger.log(
                    "input_sources",
                    "Configured input source unavailable",
                    metadata: [
                        "app": displayName,
                        "bundle_id": bundleID,
                        "input_source_id": enabledRule.inputSourceID,
                    ]
                )
                return
            }

            targetSource = matchingSource
            resolvedEnglishName = resolveCurrentDefaultEnglishSource(sources: cachedAvailableSources)?.localizedName
        } else {
            let englishSource = resolveCurrentDefaultEnglishSource(sources: cachedAvailableSources)
                ?? resolveCurrentDefaultEnglishSource(sources: availableInputSources(forceRefresh: true))

            guard let englishSource else {
                updateStatus(.warning("No English input source available"))
                return
            }

            targetSource = englishSource
            resolvedEnglishName = englishSource.localizedName
        }

        let activeStatus = InputSourceSwitchingStatus.active(
            defaultEnglishName: resolvedEnglishName ?? targetSource.localizedName,
            activeRuleCount: activeRuleCount
        )

        if backend.currentKeyboardInputSourceID() == targetSource.id {
            updateStatus(activeStatus)
            return
        }

        let initialStatus = backend.selectInputSource(id: targetSource.id)
        if initialStatus == noErr, backend.currentKeyboardInputSourceID() == targetSource.id {
            updateStatus(activeStatus)
        }

        do {
            try await Task.sleep(for: verificationDelay)
        } catch {
            return
        }

        guard !Task.isCancelled,
              isEnabled,
              isTargetStillCurrent(target) else {
            return
        }

        if initialStatus != noErr || backend.currentKeyboardInputSourceID() != targetSource.id {
            let retryStatus = backend.selectInputSource(id: targetSource.id)
            let currentSourceAfterRetry = backend.currentKeyboardInputSourceID()
            await logger.log(
                "input_sources",
                "Retried input source selection after verification mismatch",
                metadata: [
                    "app": target.localizedName,
                    "bundle_id": bundleID,
                    "target_source_id": targetSource.id,
                    "initial_osstatus": "\(initialStatus)",
                    "retry_osstatus": "\(retryStatus)",
                    "current_source_id": currentSourceAfterRetry ?? "nil",
                ]
            )
            if retryStatus != noErr || currentSourceAfterRetry != targetSource.id {
                updateStatus(.warning("Failed to switch input source to \(targetSource.localizedName)"))
                return
            }
        }

        updateStatus(activeStatus)
    }
}
