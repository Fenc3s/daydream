import AppKit
import ApplicationServices
import CoreFoundation
import CoreGraphics
import Foundation

enum ICloudPasswordsAutomationStatus: Equatable, Sendable {
    case disabled
    case accessibilityRequired
    case waitingForBrowser
    case watching
    case verifying
    case succeeded
    case failed(String)

    var displayText: String {
        switch self {
        case .disabled:
            "Disabled"
        case .accessibilityRequired:
            "Accessibility permission required"
        case .waitingForBrowser:
            "Waiting for Dia, Chrome, or Chrome Canary to launch"
        case .watching:
            "Ready for iCloud Passwords in Dia, Chrome, or Chrome Canary"
        case .verifying:
            "Entering verification code"
        case .succeeded:
            "Last iCloud Passwords verification succeeded"
        case .failed(let message):
            "Failed: \(message)"
        }
    }
}

final class ICloudPasswordsAutomationService: @unchecked Sendable {
    private static let diaBundleIdentifier = "company.thebrowser.dia"
    private static let chromeBundleIdentifier = "com.google.Chrome"
    private static let chromeCanaryBundleIdentifier = "com.google.Chrome.canary"
    private static let passwordsHelperBundleIdentifier = "com.apple.PasswordManagerBrowserExtensionHelper"
    private static let supportedBrowserBundleIdentifiers = [
        diaBundleIdentifier,
        chromeBundleIdentifier,
        chromeCanaryBundleIdentifier,
    ]
    private static let promptMarkers = [
        "Enable Password AutoFill",
        "verification code",
        "启用密码自动填充",
        "验证码",
        "啟用密碼自動填寫",
        "驗證碼",
    ]
    private static let successMarkers = [
        "Your passwords are synced with iCloud Keychain",
        "Open Passwords App",
        "您的密码已与 iCloud 钥匙串同步",
        "打开密码 App",
        "您的密碼已與 iCloud 鑰匙圈同步",
        "打開密碼 App",
    ]
    private static let digitKeyCodes: [Character: CGKeyCode] = [
        "0": 29, "1": 18, "2": 19, "3": 20, "4": 21,
        "5": 23, "6": 22, "7": 26, "8": 28, "9": 25,
    ]

    var onStatusChange: ((ICloudPasswordsAutomationStatus) -> Void)?

    private let logger: AppLogger
    private let queue = DispatchQueue(label: "Homer.daydream.icloud-passwords-automation")
    private var workspaceObserverTokens: [NSObjectProtocol] = []
    private var browserAccessibilityObservers: [pid_t: AXObserver] = [:]
    private var burstTimer: DispatchSourceTimer?
    private var burstEndDate = Date.distantPast
    private var verificationTargetProcessIdentifier: pid_t?
    private var lastActiveBrowserProcessIdentifier: pid_t?
    private var isStarted = false
    private var currentStatus = ICloudPasswordsAutomationStatus.disabled

    init(logger: AppLogger) {
        self.logger = logger
    }

    deinit {
        burstTimer?.cancel()
    }

    func start() {
        queue.async { [weak self] in
            guard let self, !isStarted else { return }
            isStarted = true
            installWorkspaceObservers()
            if let frontmostApplication = NSWorkspace.shared.frontmostApplication,
               Self.isSupportedBrowser(frontmostApplication) {
                lastActiveBrowserProcessIdentifier = frontmostApplication.processIdentifier
            }
            for browser in Self.runningSupportedBrowsers() {
                installBrowserAccessibilityObserver(for: browser)
            }
            updateIdleStatus()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            isStarted = false
            cancelBurstScan()
            lastActiveBrowserProcessIdentifier = nil
            removeAllBrowserAccessibilityObservers()
            removeWorkspaceObservers()
            updateStatus(.disabled)
        }
    }

    private func installWorkspaceObservers() {
        let notificationCenter = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
        ]
        workspaceObserverTokens = names.map { name in
            notificationCenter.addObserver(forName: name, object: nil, queue: nil) { [weak self] notification in
                guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                    return
                }
                let bundleIdentifier = application.bundleIdentifier
                guard Self.isSupportedBrowser(application)
                        || bundleIdentifier == Self.passwordsHelperBundleIdentifier else { return }
                let processIdentifier = application.processIdentifier
                self?.queue.async { [weak self] in
                    if name == NSWorkspace.didLaunchApplicationNotification {
                        guard Self.isSupportedBrowser(application) else { return }
                        self?.handleBrowserLaunch(processIdentifier: processIdentifier)
                    } else if name == NSWorkspace.didActivateApplicationNotification {
                        if bundleIdentifier == Self.passwordsHelperBundleIdentifier {
                            self?.handlePasswordsHelperActivation()
                        } else {
                            self?.handleBrowserActivation(processIdentifier: processIdentifier)
                        }
                    } else if Self.isSupportedBrowser(application) {
                        self?.handleBrowserTermination(processIdentifier: processIdentifier)
                    }
                }
            }
        }
    }

    private func removeWorkspaceObservers() {
        let notificationCenter = NSWorkspace.shared.notificationCenter
        workspaceObserverTokens.forEach(notificationCenter.removeObserver)
        workspaceObserverTokens.removeAll()
    }

    private func handleBrowserLaunch(processIdentifier: pid_t) {
        guard isStarted,
              let browser = Self.supportedBrowser(processIdentifier: processIdentifier) else {
            return
        }
        installBrowserAccessibilityObserver(for: browser)
        updateStatus(.watching)
    }

    private func handleBrowserActivation(processIdentifier: pid_t) {
        guard isStarted,
              Self.supportedBrowser(processIdentifier: processIdentifier) != nil else {
            return
        }
        lastActiveBrowserProcessIdentifier = processIdentifier
        updateStatus(.watching)
    }

    private func handleBrowserTermination(processIdentifier: pid_t) {
        guard isStarted else { return }
        if verificationTargetProcessIdentifier == processIdentifier {
            cancelBurstScan()
        }
        if lastActiveBrowserProcessIdentifier == processIdentifier {
            lastActiveBrowserProcessIdentifier = nil
        }
        removeBrowserAccessibilityObserver(processIdentifier: processIdentifier)
        updateIdleStatus()
    }

    private func handlePasswordsHelperActivation() {
        guard isStarted else { return }
        guard AXIsProcessTrusted() else {
            updateStatus(.accessibilityRequired)
            return
        }
        guard let browser = activeBrowserForVerification() else {
            updateStatus(.waitingForBrowser)
            return
        }
        let browserName = Self.browserDisplayName(browser)
        logInputEvent("Detected iCloud Passwords helper activation for \(browserName)")
        enableWebAccessibility(for: browser)
        let verificationScanIsActive = burstTimer != nil
            && verificationTargetProcessIdentifier == browser.processIdentifier
        guard verificationScanIsActive || waitForCode(timeout: 2) != nil else {
            logInputEvent("The activated Passwords helper did not contain a verification code")
            return
        }
        guard browser.activate(), waitForBrowserToBecomeFrontmost(browser, timeout: 1.5) else {
            updateStatus(.failed("Could not restore focus to \(browserName) for verification"))
            return
        }
        logInputEvent("Restored \(browserName) focus after the verification helper appeared")
        updateStatus(.watching)
        scheduleBurstScan(duration: 8, processIdentifier: browser.processIdentifier)
    }

    private func activeBrowserForVerification() -> NSRunningApplication? {
        let browsers = Self.runningSupportedBrowsers()
        if let browser = browsers.first(where: {
            pendingPINContainer(in: $0) != nil
        }) {
            return browser
        }
        if let lastActiveBrowserProcessIdentifier,
           let browser = browsers.first(where: {
               $0.processIdentifier == lastActiveBrowserProcessIdentifier
           }) {
            return browser
        }
        return browsers.count == 1 ? browsers[0] : nil
    }

    private func installBrowserAccessibilityObserver(for browser: NSRunningApplication) {
        removeBrowserAccessibilityObserver(processIdentifier: browser.processIdentifier)
        enableWebAccessibility(for: browser)

        var observer: AXObserver?
        let result = AXObserverCreate(
            browser.processIdentifier,
            { _, element, notification, context in
                guard notification as String == (kAXWindowCreatedNotification as String),
                      let context else { return }
                var processIdentifier = pid_t()
                guard AXUIElementGetPid(element, &processIdentifier) == .success else { return }
                let windowSize = ICloudPasswordsAutomationService.windowSize(of: element)
                let service = Unmanaged<ICloudPasswordsAutomationService>
                    .fromOpaque(context)
                    .takeUnretainedValue()
                service.queue.async { [weak service] in
                    service?.handleBrowserWindowCreated(
                        processIdentifier: processIdentifier,
                        windowSize: windowSize
                    )
                }
            },
            &observer
        )
        guard result == .success, let observer else {
            logInputEvent("Could not install the \(Self.browserDisplayName(browser)) window observer")
            return
        }

        let root = AXUIElementCreateApplication(browser.processIdentifier)
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard AXObserverAddNotification(
            observer,
            root,
            kAXWindowCreatedNotification as CFString,
            context
        ) == .success else {
            logInputEvent("Could not observe new \(Self.browserDisplayName(browser)) windows")
            return
        }

        browserAccessibilityObservers[browser.processIdentifier] = observer
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .commonModes
        )
        logInputEvent("Installed the \(Self.browserDisplayName(browser)) window observer")
    }

    private func enableWebAccessibility(for browser: NSRunningApplication) {
        let root = AXUIElementCreateApplication(browser.processIdentifier)
        let enhancedResult = AXUIElementSetAttributeValue(
            root,
            "AXEnhancedUserInterface" as CFString,
            kCFBooleanTrue
        )
        let manualResult = AXUIElementSetAttributeValue(
            root,
            "AXManualAccessibility" as CFString,
            kCFBooleanTrue
        )
        logInputEvent(
            "Requested \(Self.browserDisplayName(browser)) web Accessibility tree "
                + "enhanced_result=\(enhancedResult.rawValue) manual_result=\(manualResult.rawValue)"
        )
    }

    private func removeBrowserAccessibilityObserver(processIdentifier: pid_t) {
        guard let observer = browserAccessibilityObservers.removeValue(forKey: processIdentifier) else { return }
        CFRunLoopRemoveSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .commonModes
        )
    }

    private func removeAllBrowserAccessibilityObservers() {
        for processIdentifier in Array(browserAccessibilityObservers.keys) {
            removeBrowserAccessibilityObserver(processIdentifier: processIdentifier)
        }
    }

    private func handleBrowserWindowCreated(processIdentifier: pid_t, windowSize: CGSize?) {
        guard isStarted,
              let browser = Self.supportedBrowser(processIdentifier: processIdentifier) else {
            return
        }
        if let windowSize, (windowSize.width < 120 || windowSize.height < 80) {
            return
        }
        let frontmostApplication = NSWorkspace.shared.frontmostApplication
        let browserOrHelperIsActive = frontmostApplication?.processIdentifier == processIdentifier
            || frontmostApplication.map(Self.isVerificationDialogCandidate) == true
        guard browserOrHelperIsActive else {
            return
        }
        guard burstTimer == nil
                || verificationTargetProcessIdentifier == processIdentifier else {
            return
        }
        if frontmostApplication?.processIdentifier == processIdentifier {
            lastActiveBrowserProcessIdentifier = processIdentifier
        }
        logInputEvent("Detected a new \(Self.browserDisplayName(browser)) window")
        updateStatus(.watching)
        scheduleBurstScan(duration: 15, processIdentifier: processIdentifier)
    }

    private func scheduleBurstScan(duration: TimeInterval, processIdentifier: pid_t) {
        if verificationTargetProcessIdentifier != processIdentifier {
            cancelBurstScan()
            verificationTargetProcessIdentifier = processIdentifier
        }
        let requestedEndDate = Date.now.addingTimeInterval(duration)
        burstEndDate = max(burstEndDate, requestedEndDate)
        cancelBurstTimerOnly()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(500), leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            self?.burstScanTick()
        }
        burstTimer = timer
        timer.resume()
    }

    private func burstScanTick() {
        guard Date.now <= burstEndDate else {
            cancelBurstScan()
            updateStatus(.watching)
            return
        }
        guard AXIsProcessTrusted() else {
            cancelBurstScan()
            updateStatus(.accessibilityRequired)
            return
        }
        guard let processIdentifier = verificationTargetProcessIdentifier,
              let browser = Self.supportedBrowser(processIdentifier: processIdentifier) else {
            cancelBurstScan()
            updateIdleStatus()
            return
        }
        guard pendingPINContainer(in: browser) != nil else { return }

        updateStatus(.verifying)
        switch verify(in: browser) {
        case .success:
            cancelBurstScan()
            updateStatus(.succeeded)
        case .retryableFailure(let message):
            logInputEvent("Verification attempt will retry: \(message)")
            updateStatus(.watching)
        case .failure(let message):
            cancelBurstScan()
            updateStatus(.failed(message))
        }
    }

    private func cancelBurstTimerOnly() {
        burstTimer?.cancel()
        burstTimer = nil
    }

    private func cancelBurstScan() {
        cancelBurstTimerOnly()
        burstEndDate = .distantPast
        verificationTargetProcessIdentifier = nil
    }

    private func verify(in browser: NSRunningApplication) -> VerificationResult {
        let browserName = Self.browserDisplayName(browser)
        guard let code = waitForCode(timeout: 4) else {
            return .retryableFailure("The macOS verification code was not available yet")
        }
        guard enterCode(code, in: browser) else {
            return .retryableFailure("The \(browserName) PIN fields were not ready")
        }
        guard waitForBrowserToAcceptCode(in: browser, timeout: 5) else {
            return .failure("\(browserName) did not accept the verification code")
        }
        dismissCodeDialog()
        guard closeVerifiedPopup(in: browser, timeout: 2) else {
            return .failure("Verification succeeded, but the iCloud Passwords popup could not be closed")
        }
        return .success
    }

    private func waitForCode(timeout: TimeInterval) -> String? {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            if let code = codeFromAccessibility() {
                return code
            }
            usleep(150_000)
        }
        return nil
    }

    private func codeFromAccessibility() -> String? {
        for application in NSWorkspace.shared.runningApplications where Self.isVerificationDialogCandidate(application) {
            let root = AXUIElementCreateApplication(application.processIdentifier)
            let text = Self.descendants(of: root).map(Self.elementText).joined(separator: "\n")
            guard Self.hasPromptMarker(text), let code = Self.sixDigitCode(in: text) else { continue }
            return code
        }
        return nil
    }

    private func pendingPINContainer(in browser: NSRunningApplication) -> AXUIElement? {
        let root = AXUIElementCreateApplication(browser.processIdentifier)
        guard let windows = Self.attributeValue(root, kAXWindowsAttribute as CFString) as? [AXUIElement] else {
            return nil
        }
        let candidateWindows = windows.filter { window in
            guard let size = Self.windowSize(of: window) else { return true }
            return size.width >= 120 && size.height >= 80
        }.sorted { lhs, rhs in
            let lhsArea = Self.windowSize(of: lhs).map { $0.width * $0.height } ?? .greatestFiniteMagnitude
            let rhsArea = Self.windowSize(of: rhs).map { $0.width * $0.height } ?? .greatestFiniteMagnitude
            return lhsArea < rhsArea
        }
        for window in candidateWindows {
            let elements = Self.descendants(of: window, maximumDepth: 12, maximumCount: 800)
            let textFieldCount = elements.reduce(into: 0) { count, element in
                if Self.stringAttribute(element, kAXRoleAttribute as CFString) == (kAXTextFieldRole as String) {
                    count += 1
                }
            }
            guard textFieldCount >= 6 else { continue }
            let text = elements.map(Self.elementText).joined(separator: "\n")
            if Self.hasPromptMarker(text) {
                return window
            }
        }
        return nil
    }

    private func enterCode(_ code: String, in browser: NSRunningApplication) -> Bool {
        let browserName = Self.browserDisplayName(browser)
        guard browser.activate(), waitForBrowserToBecomeFrontmost(browser, timeout: 1.5) else {
            logInputEvent("Could not activate \(browserName) before entering the verification code")
            return false
        }
        guard let container = pendingPINContainer(in: browser), Self.focusFirstPINField(in: container) else {
            logInputEvent("Could not focus the first \(browserName) PIN field")
            return false
        }
        for digit in code {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == browser.processIdentifier else {
                logInputEvent("\(browserName) lost focus while entering the verification code")
                return false
            }
            Self.postDigit(digit)
            usleep(100_000)
        }
        logInputEvent("Entered the verification code using HID keyboard events")
        return true
    }

    private func waitForBrowserToAcceptCode(
        in browser: NSRunningApplication,
        timeout: TimeInterval
    ) -> Bool {
        let browserName = Self.browserDisplayName(browser)
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            if hasVerifiedState(in: browser) {
                logInputEvent("\(browserName) displayed the verified iCloud Passwords state")
                return true
            }
            usleep(100_000)
        }
        logInputEvent("\(browserName) did not display the verified iCloud Passwords state")
        return false
    }

    private func hasVerifiedState(in browser: NSRunningApplication) -> Bool {
        verifiedPopupWindow(in: browser) != nil
    }

    private func verifiedPopupWindow(in browser: NSRunningApplication) -> AXUIElement? {
        let root = AXUIElementCreateApplication(browser.processIdentifier)
        guard let windows = Self.attributeValue(root, kAXWindowsAttribute as CFString) as? [AXUIElement] else {
            return nil
        }
        return windows.first { window in
            let text = Self.descendants(of: window, maximumDepth: 12, maximumCount: 800)
                .map(Self.elementText)
                .joined(separator: "\n")
            return Self.successMarkers.contains { text.localizedCaseInsensitiveContains($0) }
        }
    }

    private func closeVerifiedPopup(in browser: NSRunningApplication, timeout: TimeInterval) -> Bool {
        guard let window = verifiedPopupWindow(in: browser) else {
            logInputEvent("The verified iCloud Passwords popup was already closed")
            return true
        }

        var usedCloseButton = false
        if let closeButton = Self.elementAttribute(window, kAXCloseButtonAttribute as CFString),
           AXUIElementPerformAction(closeButton, kAXPressAction as CFString) == .success {
            usedCloseButton = true
            logInputEvent("Pressed the verified iCloud Passwords popup close button")
        } else if browser.activate(), waitForBrowserToBecomeFrontmost(browser, timeout: 1) {
            Self.postKey(53)
            logInputEvent("Sent Escape to close the verified iCloud Passwords popup")
        } else {
            logInputEvent("Could not invoke a close action for the verified iCloud Passwords popup")
            return false
        }

        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            if verifiedPopupWindow(in: browser) == nil {
                logInputEvent(
                    usedCloseButton
                        ? "The verified iCloud Passwords popup closed after the close-button action"
                        : "The verified iCloud Passwords popup closed after Escape"
                )
                return true
            }
            usleep(100_000)
        }
        logInputEvent("The verified iCloud Passwords popup remained open after the close action")
        return false
    }

    private func waitForBrowserToBecomeFrontmost(
        _ browser: NSRunningApplication,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == browser.processIdentifier {
                return true
            }
            usleep(50_000)
        }
        return false
    }

    private func logInputEvent(_ message: String) {
        Task {
            await logger.log("icloud_passwords", message)
        }
    }

    private func dismissCodeDialog() {
        usleep(500_000)
        for application in NSWorkspace.shared.runningApplications where Self.isVerificationDialogCandidate(application) {
            let root = AXUIElementCreateApplication(application.processIdentifier)
            let elements = Self.descendants(of: root, maximumDepth: 12, maximumCount: 1_500)
            let text = elements.map(Self.elementText).joined(separator: "\n")
            guard Self.hasPromptMarker(text) else { continue }
            guard let doneButton = elements.first(where: {
                let role = Self.stringAttribute($0, kAXRoleAttribute as CFString)
                let title = Self.stringAttribute($0, kAXTitleAttribute as CFString) ?? ""
                return role == (kAXButtonRole as String) && ["Done", "完成"].contains(title)
            }) else { continue }
            AXUIElementPerformAction(doneButton, kAXPressAction as CFString)
            return
        }
    }

    private func updateIdleStatus() {
        guard AXIsProcessTrusted() else {
            updateStatus(.accessibilityRequired)
            return
        }
        updateStatus(Self.runningSupportedBrowsers().isEmpty ? .waitingForBrowser : .watching)
    }

    private func updateStatus(_ status: ICloudPasswordsAutomationStatus) {
        guard status != currentStatus else { return }
        currentStatus = status
        onStatusChange?(status)
        Task {
            await logger.log(
                "icloud_passwords",
                "Automation status changed",
                metadata: ["status": status.displayText]
            )
        }
    }

    private static func runningSupportedBrowsers() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter(isSupportedBrowser)
    }

    private static func supportedBrowser(processIdentifier: pid_t) -> NSRunningApplication? {
        runningSupportedBrowsers().first {
            $0.processIdentifier == processIdentifier
        }
    }

    private static func isSupportedBrowser(_ application: NSRunningApplication) -> Bool {
        guard !application.isTerminated,
              let bundleIdentifier = application.bundleIdentifier else {
            return false
        }
        return supportedBrowserBundleIdentifiers.contains(bundleIdentifier)
    }

    private static func browserDisplayName(_ application: NSRunningApplication) -> String {
        switch application.bundleIdentifier {
        case diaBundleIdentifier:
            return "Dia"
        case chromeBundleIdentifier:
            return "Google Chrome"
        case chromeCanaryBundleIdentifier:
            return "Google Chrome Canary"
        default:
            return application.localizedName ?? "Browser"
        }
    }

    private static func isVerificationDialogCandidate(_ application: NSRunningApplication) -> Bool {
        guard !application.isTerminated, application.processIdentifier != getpid() else { return false }
        let identity = [application.bundleIdentifier, application.localizedName]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        return identity.contains("password") || identity.contains("authentication")
    }

    fileprivate static func windowSize(of element: AXUIElement) -> CGSize? {
        guard let value = attributeValue(element, kAXSizeAttribute as CFString),
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cgSize else {
            return nil
        }
        var size = CGSize.zero
        return AXValueGetValue(axValue, .cgSize, &size) ? size : nil
    }

    private static func attributeValue(_ element: AXUIElement, _ attribute: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
        attributeValue(element, attribute) as? String
    }

    private static func elementAttribute(_ element: AXUIElement, _ attribute: CFString) -> AXUIElement? {
        guard let value = attributeValue(element, attribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private static func childElements(_ element: AXUIElement) -> [AXUIElement] {
        attributeValue(element, kAXChildrenAttribute as CFString) as? [AXUIElement] ?? []
    }

    private static func descendants(
        of root: AXUIElement,
        maximumDepth: Int = 12,
        maximumCount: Int = 2_500
    ) -> [AXUIElement] {
        var result: [AXUIElement] = []
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var cursor = 0
        while cursor < queue.count, result.count < maximumCount {
            let (element, depth) = queue[cursor]
            cursor += 1
            result.append(element)
            guard depth < maximumDepth else { continue }
            queue.append(contentsOf: childElements(element).map { ($0, depth + 1) })
        }
        return result
    }

    private static func elementText(_ element: AXUIElement) -> String {
        [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute, kAXHelpAttribute]
            .compactMap { stringAttribute(element, $0 as CFString) }
            .joined(separator: " ")
    }

    private static func hasPromptMarker(_ text: String) -> Bool {
        promptMarkers.contains { text.localizedCaseInsensitiveContains($0) }
    }

    private static func sixDigitCode(in text: String) -> String? {
        let pattern = #"(?<!\d)(\d{3})[\s\u00A0]*(\d{3})(?!\d)"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = expression.firstMatch(in: text, range: range), match.numberOfRanges == 3,
              let firstRange = Range(match.range(at: 1), in: text),
              let secondRange = Range(match.range(at: 2), in: text) else {
            return nil
        }
        return String(text[firstRange]) + String(text[secondRange])
    }

    private static func focusFirstPINField(in root: AXUIElement) -> Bool {
        let textFields = descendants(of: root).filter {
            stringAttribute($0, kAXRoleAttribute as CFString) == (kAXTextFieldRole as String)
        }
        guard textFields.count >= 6 else { return false }
        return AXUIElementSetAttributeValue(
            textFields[0],
            kAXFocusedAttribute as CFString,
            kCFBooleanTrue
        ) == .success
    }

    private static func postDigit(_ digit: Character) {
        guard let keyCode = digitKeyCodes[digit] else { return }
        postKey(keyCode)
    }

    private static func postKey(_ keyCode: CGKeyCode) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    private enum VerificationResult {
        case success
        case retryableFailure(String)
        case failure(String)
    }
}
