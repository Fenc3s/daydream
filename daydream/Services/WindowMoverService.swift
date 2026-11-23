import AppKit
import ApplicationServices
import CoreFoundation
import CoreGraphics
import Darwin
import Foundation

enum WindowMoveMode: String, Equatable, Sendable {
    case standard
    case borderlessFullScreen
    case nativeFullScreen
}

struct WindowMoveResult: Equatable, Sendable {
    let applicationName: String
    let sourceScreenName: String
    let targetScreenName: String
    let mode: WindowMoveMode

    init(
        applicationName: String,
        sourceScreenName: String,
        targetScreenName: String,
        mode: WindowMoveMode = .standard
    ) {
        self.applicationName = applicationName
        self.sourceScreenName = sourceScreenName
        self.targetScreenName = targetScreenName
        self.mode = mode
    }
}

enum WindowMoverError: LocalizedError, Equatable, Sendable {
    case moveAlreadyInProgress
    case accessibilityPermissionMissing
    case noFrontmostApplication
    case noFocusedWindow(String)
    case onlyOneScreen
    case unreadableWindowFrame
    case windowPositionNotSettable
    case fullScreenExitBlockedByModalSheet(String)
    case fullScreenExitUnsupported(String)
    case fullScreenExitTimedOut(String)
    case targetScreenPlacementFailed(String)
    case fullScreenReentryTimedOut(String)
    case moveFailed(AXError)

    var errorDescription: String? {
        switch self {
        case .moveAlreadyInProgress:
            "A window move is already in progress."
        case .accessibilityPermissionMissing:
            "Accessibility permission is required to move windows between monitors."
        case .noFrontmostApplication:
            "Could not determine the frontmost application."
        case .noFocusedWindow(let applicationName):
            "\(applicationName) does not have a focused window to move."
        case .onlyOneScreen:
            "Connect another monitor before moving a window between monitors."
        case .unreadableWindowFrame:
            "Could not read the focused window's position and size."
        case .windowPositionNotSettable:
            "The focused window does not allow its position to be changed."
        case .fullScreenExitBlockedByModalSheet(let applicationName):
            "Close the open sheet in \(applicationName) before moving its full-screen window."
        case .fullScreenExitUnsupported(let applicationName):
            "\(applicationName) does not allow exiting full screen via Accessibility."
        case .fullScreenExitTimedOut(let applicationName):
            "Timed out waiting for \(applicationName) to exit full screen."
        case .targetScreenPlacementFailed(let targetScreenName):
            "Could not place the window onto \(targetScreenName) before re-entering full screen."
        case .fullScreenReentryTimedOut(let applicationName):
            "Moved \(applicationName) to the next monitor, but timed out while re-entering full screen."
        case .moveFailed(let error):
            "The focused window could not be moved (Accessibility error \(error.rawValue))."
        }
    }
}

enum AccessibilityValueResult<Value> {
    case success(Value)
    case failure(AXError)

    var value: Value? {
        switch self {
        case .success(let value):
            value
        case .failure:
            nil
        }
    }
}

struct ScreenGeometry: Equatable, Sendable {
    let name: String
    let accessibilityFrame: CGRect
    let accessibilityVisibleFrame: CGRect

    init(
        name: String,
        accessibilityFrame: CGRect,
        accessibilityVisibleFrame: CGRect
    ) {
        self.name = name
        self.accessibilityFrame = accessibilityFrame
        self.accessibilityVisibleFrame = accessibilityVisibleFrame
    }

    @MainActor
    init(screen: NSScreen, primaryScreenMaxY: CGFloat) {
        name = screen.localizedName
        accessibilityFrame = Self.accessibilityFrame(
            from: screen.frame,
            primaryScreenMaxY: primaryScreenMaxY
        )
        accessibilityVisibleFrame = Self.accessibilityFrame(
            from: screen.visibleFrame,
            primaryScreenMaxY: primaryScreenMaxY
        )
    }

    static func accessibilityFrame(from appKitFrame: CGRect, primaryScreenMaxY: CGFloat) -> CGRect {
        CGRect(
            x: appKitFrame.minX,
            y: primaryScreenMaxY - appKitFrame.maxY,
            width: appKitFrame.width,
            height: appKitFrame.height
        )
    }
}

struct WindowTargetApp: Equatable, Sendable {
    let processIdentifier: pid_t
    let bundleIdentifier: String?
    let localizedName: String
}

struct WindowElementHandle: Equatable {
    enum Storage {
        case accessibility(AXUIElement)
        case mock(id: Int)
    }

    let storage: Storage

    static func == (lhs: WindowElementHandle, rhs: WindowElementHandle) -> Bool {
        switch (lhs.storage, rhs.storage) {
        case (.accessibility(let left), .accessibility(let right)):
            return CFEqual(left, right)
        case (.mock(let left), .mock(let right)):
            return left == right
        default:
            return false
        }
    }
}

struct WindowMoverTimingConfiguration: Equatable, Sendable {
    var pollInterval: Duration = .milliseconds(25)
    var exitFullScreenTimeout: Duration = .milliseconds(2_500)
    var enterFullScreenTimeout: Duration = .milliseconds(2_500)
    var targetScreenSettleTimeout: Duration = .milliseconds(250)
    var preFullScreenEntrySettleDelay: Duration = .milliseconds(40)
    var actionRetryInterval: Duration = .milliseconds(200)
    var requiredStablePolls: Int = 3
}

@MainActor
protocol WindowMoverBackend {
    func isAccessibilityTrusted() -> Bool
    func frontmostApplication() -> WindowTargetApp?
    @discardableResult
    func activateApplication(processIdentifier: pid_t) -> Bool
    func screens() -> [ScreenGeometry]

    func focusedWindowOrElement(of processIdentifier: pid_t) -> WindowElementHandle?
    func mainWindow(of processIdentifier: pid_t) -> WindowElementHandle?
    func windows(of processIdentifier: pid_t) -> [WindowElementHandle]
    func role(of element: WindowElementHandle) -> String?
    func subrole(of element: WindowElementHandle) -> String?
    func containingWindow(of element: WindowElementHandle) -> WindowElementHandle?
    func isMinimized(_ window: WindowElementHandle) -> Bool
    func isMain(_ window: WindowElementHandle) -> Bool
    func hasAttachedModalSheet(_ window: WindowElementHandle) -> Bool
    func hasStandardWindowButtons(_ window: WindowElementHandle) -> Bool

    func frame(of window: WindowElementHandle) -> AccessibilityValueResult<CGRect>
    func positionSettability(_ window: WindowElementHandle) -> AccessibilityValueResult<Bool>
    func isSizeSettable(_ window: WindowElementHandle) -> Bool
    func setPosition(_ origin: CGPoint, of window: WindowElementHandle) -> AXError
    func setSize(_ size: CGSize, of window: WindowElementHandle) -> AXError
    @discardableResult
    func raiseWindow(_ window: WindowElementHandle) -> AXError

    func fullScreenState(of window: WindowElementHandle) -> AccessibilityValueResult<Bool>
    func isFullScreenSettable(_ window: WindowElementHandle) -> Bool
    func setFullScreen(_ fullScreen: Bool, of window: WindowElementHandle) -> AXError
    func pressFullScreenButton(of window: WindowElementHandle, requireFullScreenSubrole: Bool) -> AXError
    func hasFullScreenCapableButton(_ window: WindowElementHandle) -> Bool

    func isEnhancedUserInterfaceEnabled(for processIdentifier: pid_t) -> Bool
    @discardableResult
    func setEnhancedUserInterface(_ enabled: Bool, for processIdentifier: pid_t) -> AXError

    func sleep(_ duration: Duration) async throws
}

@MainActor
final class AccessibilityWindowMoverBackend: WindowMoverBackend {
    private static let fullScreenAttribute = "AXFullScreen"
    private static let enhancedUserInterfaceAttribute = "AXEnhancedUserInterface"

    func isAccessibilityTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    func frontmostApplication() -> WindowTargetApp? {
        guard let application = NSWorkspace.shared.frontmostApplication else {
            return nil
        }
        let localizedName = application.localizedName ?? application.bundleIdentifier ?? "Unknown App"
        return WindowTargetApp(
            processIdentifier: application.processIdentifier,
            bundleIdentifier: application.bundleIdentifier,
            localizedName: localizedName
        )
    }

    @discardableResult
    func activateApplication(processIdentifier: pid_t) -> Bool {
        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        let axResult = setBoolAttribute(
            true,
            attribute: kAXFrontmostAttribute,
            of: applicationElement
        )
        let appKitActivated = NSRunningApplication(processIdentifier: processIdentifier)?.activate() ?? false
        return axResult == .success || appKitActivated
    }

    func screens() -> [ScreenGeometry] {
        let currentScreens = NSScreen.screens
        let primaryScreenMaxY = currentScreens.first?.frame.maxY ?? 0
        return currentScreens.map {
            ScreenGeometry(screen: $0, primaryScreenMaxY: primaryScreenMaxY)
        }
    }

    func focusedWindowOrElement(of processIdentifier: pid_t) -> WindowElementHandle? {
        let application = AXUIElementCreateApplication(processIdentifier)
        return elementAttribute(kAXFocusedWindowAttribute, of: application)
            .map { WindowElementHandle(storage: .accessibility($0)) }
    }

    func mainWindow(of processIdentifier: pid_t) -> WindowElementHandle? {
        let application = AXUIElementCreateApplication(processIdentifier)
        return elementAttribute(kAXMainWindowAttribute, of: application)
            .map { WindowElementHandle(storage: .accessibility($0)) }
    }

    func windows(of processIdentifier: pid_t) -> [WindowElementHandle] {
        let application = AXUIElementCreateApplication(processIdentifier)
        return elementsAttribute(kAXWindowsAttribute, of: application)
            .map { WindowElementHandle(storage: .accessibility($0)) }
    }

    func role(of element: WindowElementHandle) -> String? {
        guard let axElement = axElement(from: element) else { return nil }
        return stringAttribute(kAXRoleAttribute, of: axElement)
    }

    func subrole(of element: WindowElementHandle) -> String? {
        guard let axElement = axElement(from: element) else { return nil }
        return stringAttribute(kAXSubroleAttribute, of: axElement)
    }

    func containingWindow(of element: WindowElementHandle) -> WindowElementHandle? {
        guard let axElement = axElement(from: element) else { return nil }

        for attribute in [kAXWindowAttribute, kAXTopLevelUIElementAttribute] {
            if let candidate = elementAttribute(attribute, of: axElement),
               stringAttribute(kAXRoleAttribute, of: candidate) == (kAXWindowRole as String) {
                return WindowElementHandle(storage: .accessibility(candidate))
            }
        }

        var current = axElement
        for _ in 0..<4 {
            guard let parent = elementAttribute(kAXParentAttribute, of: current) else {
                break
            }
            if stringAttribute(kAXRoleAttribute, of: parent) == (kAXWindowRole as String) {
                return WindowElementHandle(storage: .accessibility(parent))
            }
            current = parent
        }

        return nil
    }

    func isMinimized(_ window: WindowElementHandle) -> Bool {
        guard let axWindow = axElement(from: window),
              case .success(let minimized) = boolAttribute(kAXMinimizedAttribute, of: axWindow) else {
            return false
        }
        return minimized
    }

    func isMain(_ window: WindowElementHandle) -> Bool {
        guard let axWindow = axElement(from: window),
              case .success(let isMain) = boolAttribute(kAXMainAttribute, of: axWindow) else {
            return false
        }
        return isMain
    }

    func hasAttachedModalSheet(_ window: WindowElementHandle) -> Bool {
        guard let axWindow = axElement(from: window) else { return false }
        let children = elementsAttribute(kAXChildrenAttribute, of: axWindow)
        return children.contains {
            stringAttribute(kAXRoleAttribute, of: $0) == (kAXSheetRole as String)
        }
    }

    func hasStandardWindowButtons(_ window: WindowElementHandle) -> Bool {
        guard let axWindow = axElement(from: window) else { return false }
        if elementAttribute(kAXCloseButtonAttribute, of: axWindow) != nil
            || elementAttribute(kAXMinimizeButtonAttribute, of: axWindow) != nil {
            return true
        }
        return hasFullScreenCapableButton(window)
    }

    func frame(of window: WindowElementHandle) -> AccessibilityValueResult<CGRect> {
        guard let axWindow = axElement(from: window) else {
            return .failure(.invalidUIElement)
        }
        switch pointAttribute(kAXPositionAttribute, of: axWindow) {
        case .failure(let error):
            return .failure(error)
        case .success(let origin):
            switch sizeAttribute(kAXSizeAttribute, of: axWindow) {
            case .failure(let error):
                return .failure(error)
            case .success(let size):
                return .success(CGRect(origin: origin, size: size))
            }
        }
    }

    func positionSettability(_ window: WindowElementHandle) -> AccessibilityValueResult<Bool> {
        guard let axWindow = axElement(from: window) else {
            return .failure(.invalidUIElement)
        }
        return attributeSettability(kAXPositionAttribute, of: axWindow)
    }

    func isSizeSettable(_ window: WindowElementHandle) -> Bool {
        guard let axWindow = axElement(from: window),
              case .success(let settable) = attributeSettability(kAXSizeAttribute, of: axWindow) else {
            return false
        }
        return settable
    }

    func setPosition(_ origin: CGPoint, of window: WindowElementHandle) -> AXError {
        guard let axWindow = axElement(from: window) else {
            return .invalidUIElement
        }
        var mutableOrigin = origin
        guard let positionValue = AXValueCreate(.cgPoint, &mutableOrigin) else {
            return .illegalArgument
        }
        return AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, positionValue)
    }

    func setSize(_ size: CGSize, of window: WindowElementHandle) -> AXError {
        guard let axWindow = axElement(from: window) else {
            return .invalidUIElement
        }
        var mutableSize = size
        guard let sizeValue = AXValueCreate(.cgSize, &mutableSize) else {
            return .illegalArgument
        }
        return AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, sizeValue)
    }

    @discardableResult
    func raiseWindow(_ window: WindowElementHandle) -> AXError {
        guard let axWindow = axElement(from: window) else {
            return .invalidUIElement
        }
        _ = AXUIElementSetAttributeValue(axWindow, kAXMainAttribute as CFString, kCFBooleanTrue)
        _ = AXUIElementSetAttributeValue(axWindow, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        return AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
    }

    func fullScreenState(of window: WindowElementHandle) -> AccessibilityValueResult<Bool> {
        guard let axWindow = axElement(from: window) else {
            return .failure(.invalidUIElement)
        }
        return boolAttribute(Self.fullScreenAttribute, of: axWindow)
    }

    func isFullScreenSettable(_ window: WindowElementHandle) -> Bool {
        guard let axWindow = axElement(from: window),
              case .success(let settable) = attributeSettability(Self.fullScreenAttribute, of: axWindow) else {
            return false
        }
        return settable
    }

    func setFullScreen(_ fullScreen: Bool, of window: WindowElementHandle) -> AXError {
        guard let axWindow = axElement(from: window) else {
            return .invalidUIElement
        }
        return setBoolAttribute(fullScreen, attribute: Self.fullScreenAttribute, of: axWindow)
    }

    func pressFullScreenButton(of window: WindowElementHandle, requireFullScreenSubrole: Bool) -> AXError {
        guard let axWindow = axElement(from: window) else {
            return .invalidUIElement
        }
        let button = elementAttribute(kAXFullScreenButtonAttribute, of: axWindow)
            ?? elementAttribute(kAXZoomButtonAttribute, of: axWindow)
        guard let button else {
            return .noValue
        }
        if requireFullScreenSubrole,
           stringAttribute(kAXSubroleAttribute, of: button) != (kAXFullScreenButtonSubrole as String) {
            return .attributeUnsupported
        }
        return AXUIElementPerformAction(button, kAXPressAction as CFString)
    }

    func hasFullScreenCapableButton(_ window: WindowElementHandle) -> Bool {
        guard let axWindow = axElement(from: window) else { return false }
        if elementAttribute(kAXFullScreenButtonAttribute, of: axWindow) != nil {
            return true
        }
        if let zoomButton = elementAttribute(kAXZoomButtonAttribute, of: axWindow),
           stringAttribute(kAXSubroleAttribute, of: zoomButton) == (kAXFullScreenButtonSubrole as String) {
            return true
        }
        return false
    }

    func isEnhancedUserInterfaceEnabled(for processIdentifier: pid_t) -> Bool {
        let application = AXUIElementCreateApplication(processIdentifier)
        if case .success(let enabled) = boolAttribute(Self.enhancedUserInterfaceAttribute, of: application) {
            return enabled
        }
        return false
    }

    @discardableResult
    func setEnhancedUserInterface(_ enabled: Bool, for processIdentifier: pid_t) -> AXError {
        let application = AXUIElementCreateApplication(processIdentifier)
        return setBoolAttribute(enabled, attribute: Self.enhancedUserInterfaceAttribute, of: application)
    }

    func sleep(_ duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }

    private func axElement(from handle: WindowElementHandle) -> AXUIElement? {
        switch handle.storage {
        case .accessibility(let element):
            return element
        case .mock:
            return nil
        }
    }

    private func elementAttribute(_ attribute: String, of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private func elementsAttribute(_ attribute: String, of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success,
              let array = value as? [AnyObject] else {
            return []
        }
        return array.compactMap { item in
            guard CFGetTypeID(item) == AXUIElementGetTypeID() else { return nil }
            return (item as! AXUIElement)
        }
    }

    private func stringAttribute(_ attribute: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success, let stringValue = value as? String else {
            return nil
        }
        return stringValue
    }

    private func boolAttribute(_ attribute: String, of element: AXUIElement) -> AccessibilityValueResult<Bool> {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else {
            return .failure(result)
        }
        guard let value else {
            return .failure(.noValue)
        }
        if CFGetTypeID(value) == CFBooleanGetTypeID() {
            return .success(CFBooleanGetValue((value as! CFBoolean)))
        }
        if let number = value as? NSNumber {
            return .success(number.boolValue)
        }
        return .failure(.illegalArgument)
    }

    private func setBoolAttribute(
        _ boolValue: Bool,
        attribute: String,
        of element: AXUIElement
    ) -> AXError {
        let cfBool: CFBoolean = boolValue ? kCFBooleanTrue : kCFBooleanFalse
        return AXUIElementSetAttributeValue(element, attribute as CFString, cfBool)
    }

    private func attributeSettability(
        _ attribute: String,
        of element: AXUIElement
    ) -> AccessibilityValueResult<Bool> {
        var isSettable = DarwinBoolean(false)
        let result = AXUIElementIsAttributeSettable(
            element,
            attribute as CFString,
            &isSettable
        )
        guard result == .success else {
            return .failure(result)
        }
        return .success(isSettable.boolValue)
    }

    private func pointAttribute(_ attribute: String, of element: AXUIElement) -> AccessibilityValueResult<CGPoint> {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else {
            return .failure(result)
        }
        guard let value,
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return .failure(.noValue)
        }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cgPoint else {
            return .failure(.illegalArgument)
        }

        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else {
            return .failure(.cannotComplete)
        }
        return .success(point)
    }

    private func sizeAttribute(_ attribute: String, of element: AXUIElement) -> AccessibilityValueResult<CGSize> {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else {
            return .failure(result)
        }
        guard let value,
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return .failure(.noValue)
        }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cgSize else {
            return .failure(.illegalArgument)
        }

        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else {
            return .failure(.cannotComplete)
        }
        return .success(size)
    }
}

@MainActor
final class WindowMoverService {
    private struct ResolvedWindow {
        let window: WindowElementHandle
        let focusedElementWasSheet: Bool
    }

    private let logger: AppLogger?
    private let backend: any WindowMoverBackend
    private let timing: WindowMoverTimingConfiguration
    private(set) var isMoveInProgress = false

    init(
        logger: AppLogger? = nil,
        backend: (any WindowMoverBackend)? = nil,
        timing: WindowMoverTimingConfiguration = .init()
    ) {
        self.logger = logger
        self.backend = backend ?? AccessibilityWindowMoverBackend()
        self.timing = timing
    }

    func moveFocusedWindowToNextScreen() async throws -> WindowMoveResult {
        guard !isMoveInProgress else {
            throw WindowMoverError.moveAlreadyInProgress
        }
        isMoveInProgress = true
        defer { isMoveInProgress = false }

        guard backend.isAccessibilityTrusted() else {
            throw WindowMoverError.accessibilityPermissionMissing
        }

        guard let application = backend.frontmostApplication() else {
            throw WindowMoverError.noFrontmostApplication
        }

        var screens = Self.orderedScreens(from: backend.screens())
        guard screens.count > 1 else {
            throw WindowMoverError.onlyOneScreen
        }

        let applicationName = application.localizedName
        guard let resolved = resolveTargetWindow(for: application.processIdentifier) else {
            throw WindowMoverError.noFocusedWindow(applicationName)
        }

        guard case .success(let initialFrame) = backend.frame(of: resolved.window),
              initialFrame.width > 0,
              initialFrame.height > 0 else {
            throw WindowMoverError.unreadableWindowFrame
        }

        let sourceIndex = Self.screenIndex(containing: initialFrame, in: screens)
        var targetIndex = screens.index(after: sourceIndex) == screens.endIndex
            ? screens.startIndex
            : screens.index(after: sourceIndex)
        var source = screens[sourceIndex]
        var target = screens[targetIndex]

        let mode = try classifyMoveMode(
            window: resolved.window,
            initialFrame: initialFrame,
            source: source
        )

        let hadEnhancedUI = backend.isEnhancedUserInterfaceEnabled(for: application.processIdentifier)
        var attemptedDisableEnhancedUI = false
        defer {
            if attemptedDisableEnhancedUI {
                backend.setEnhancedUserInterface(true, for: application.processIdentifier)
            }
        }

        let preExistingSiblingWindows = backend.windows(of: application.processIdentifier).filter {
            $0 != resolved.window
        }

        var activeWindow = resolved.window
        var workingFrame = initialFrame

        if mode == .nativeFullScreen {
            let exited = try await exitNativeFullScreenAndAwaitDesktop(
                resolved: resolved,
                initialFrame: initialFrame,
                excludedSiblingWindows: preExistingSiblingWindows,
                application: application,
                applicationName: applicationName
            )
            activeWindow = exited.window
            workingFrame = exited.restoredFrame

            let refreshedScreens = Self.orderedScreens(from: backend.screens())
            guard refreshedScreens.count > 1 else {
                throw WindowMoverError.onlyOneScreen
            }
            let previousSource = source
            let previousTarget = target
            screens = refreshedScreens
            if let matchedTargetIndex = screens.firstIndex(where: {
                $0.accessibilityFrame.approximatelyEquals(previousTarget.accessibilityFrame, tolerance: 2)
            }) ?? screens.firstIndex(where: { $0.name == previousTarget.name }) {
                targetIndex = matchedTargetIndex
            } else {
                targetIndex = min(targetIndex, screens.count - 1)
            }
            target = screens[targetIndex]
            if let matchedSource = screens.first(where: {
                $0.accessibilityFrame.approximatelyEquals(previousSource.accessibilityFrame, tolerance: 2)
            }) ?? screens.first(where: { $0.name == previousSource.name }) {
                source = matchedSource
            }
        }

        if hadEnhancedUI {
            attemptedDisableEnhancedUI = true
            _ = backend.setEnhancedUserInterface(
                false,
                for: application.processIdentifier
            )
        }

        try relocateDesktopWindow(
            activeWindow,
            workingFrame: workingFrame,
            source: source,
            target: target,
            screens: screens,
            mode: mode
        )

        if mode == .nativeFullScreen {
            try await reenterNativeFullScreenOnTarget(
                window: activeWindow,
                excludedSiblingWindows: preExistingSiblingWindows,
                application: application,
                applicationName: applicationName,
                target: target,
                targetIndex: targetIndex,
                screens: screens
            )
        }

        return WindowMoveResult(
            applicationName: applicationName,
            sourceScreenName: source.name,
            targetScreenName: target.name,
            mode: mode
        )
    }

    static func orderedScreens(from screens: [ScreenGeometry]) -> [ScreenGeometry] {
        screens.sorted {
            if $0.accessibilityFrame.minX == $1.accessibilityFrame.minX {
                return $0.accessibilityFrame.minY < $1.accessibilityFrame.minY
            }
            return $0.accessibilityFrame.minX < $1.accessibilityFrame.minX
        }
    }

    static func screenIndex(containing windowFrame: CGRect, in screens: [ScreenGeometry]) -> Int {
        let intersectionAreas = screens.map {
            windowFrame.intersection($0.accessibilityFrame).area
        }
        if let index = intersectionAreas.indices.max(by: { intersectionAreas[$0] < intersectionAreas[$1] }),
           intersectionAreas[index] > 0 {
            return index
        }

        let windowCenter = CGPoint(x: windowFrame.midX, y: windowFrame.midY)
        return screens.indices.min(by: {
            screens[$0].accessibilityFrame.center.squaredDistance(to: windowCenter)
                < screens[$1].accessibilityFrame.center.squaredDistance(to: windowCenter)
        }) ?? screens.startIndex
    }

    static func mappedOrigin(
        _ origin: CGPoint,
        sourceWindowSize: CGSize,
        targetWindowSize: CGSize,
        from sourceFrame: CGRect,
        to targetFrame: CGRect
    ) -> CGPoint {
        let x: CGFloat
        if targetWindowSize.width > targetFrame.width {
            x = targetFrame.midX - (targetWindowSize.width / 2)
        } else {
            let sourceTravelX = max(0, sourceFrame.width - sourceWindowSize.width)
            let relativeX = sourceTravelX > 0 ? (origin.x - sourceFrame.minX) / sourceTravelX : 0
            let targetTravelX = max(0, targetFrame.width - targetWindowSize.width)
            x = targetFrame.minX + min(max(relativeX, 0), 1) * targetTravelX
        }

        let y: CGFloat
        if targetWindowSize.height > targetFrame.height {
            y = targetFrame.midY - (targetWindowSize.height / 2)
        } else {
            let sourceTravelY = max(0, sourceFrame.height - sourceWindowSize.height)
            let relativeY = sourceTravelY > 0 ? (origin.y - sourceFrame.minY) / sourceTravelY : 0
            let targetTravelY = max(0, targetFrame.height - targetWindowSize.height)
            y = targetFrame.minY + min(max(relativeY, 0), 1) * targetTravelY
        }

        return CGPoint(x: x, y: y)
    }

    private func resolveTargetWindow(
        for processIdentifier: pid_t,
        excluding excludedWindows: [WindowElementHandle] = []
    ) -> ResolvedWindow? {
        let isAllowed: (WindowElementHandle) -> Bool = { candidate in
            !excludedWindows.contains(candidate) && !self.backend.isMinimized(candidate)
        }

        if let focusedElement = backend.focusedWindowOrElement(of: processIdentifier),
           let unwrapped = unwrapToWindow(focusedElement),
           isAllowed(unwrapped.window) {
            let wasSheet = unwrapped.originalRole == (kAXSheetRole as String)
            let subrole = backend.subrole(of: unwrapped.window)
            let isFloatingAuxiliary = subrole == (kAXFloatingWindowSubrole as String)
                || subrole == (kAXSystemFloatingWindowSubrole as String)
            let isNativeFullScreen = backend.fullScreenState(of: unwrapped.window).value == true
            let isPositionLocked = backend.positionSettability(unwrapped.window).value == false

            if !isNativeFullScreen,
               (isFloatingAuxiliary || isPositionLocked),
               let mainElement = backend.mainWindow(of: processIdentifier),
               let mainUnwrapped = unwrapToWindow(mainElement),
               mainUnwrapped.window != unwrapped.window,
               isAllowed(mainUnwrapped.window),
               (backend.fullScreenState(of: mainUnwrapped.window).value == true
                || backend.positionSettability(mainUnwrapped.window).value == true
                || backend.hasFullScreenCapableButton(mainUnwrapped.window)) {
                return ResolvedWindow(
                    window: mainUnwrapped.window,
                    focusedElementWasSheet: mainUnwrapped.originalRole == (kAXSheetRole as String)
                )
            }

            return ResolvedWindow(window: unwrapped.window, focusedElementWasSheet: wasSheet)
        }

        if let mainElement = backend.mainWindow(of: processIdentifier),
           let mainUnwrapped = unwrapToWindow(mainElement),
           isAllowed(mainUnwrapped.window) {
            return ResolvedWindow(
                window: mainUnwrapped.window,
                focusedElementWasSheet: mainUnwrapped.originalRole == (kAXSheetRole as String)
            )
        }

        let candidates = backend.windows(of: processIdentifier).filter {
            backend.role(of: $0) == (kAXWindowRole as String) && isAllowed($0)
        }
        guard !candidates.isEmpty else {
            return nil
        }

        if let fullScreenWindow = candidates.first(where: {
            backend.fullScreenState(of: $0).value == true
        }) {
            return ResolvedWindow(window: fullScreenWindow, focusedElementWasSheet: false)
        }

        if let mainCandidate = candidates.first(where: { backend.isMain($0) }) {
            return ResolvedWindow(window: mainCandidate, focusedElementWasSheet: false)
        }

        if let standardWindow = candidates.first(where: {
            backend.subrole(of: $0) == (kAXStandardWindowSubrole as String)
        }) {
            return ResolvedWindow(window: standardWindow, focusedElementWasSheet: false)
        }

        return ResolvedWindow(window: candidates[0], focusedElementWasSheet: false)
    }

    private func unwrapToWindow(
        _ element: WindowElementHandle
    ) -> (window: WindowElementHandle, originalRole: String?)? {
        let elementRole = backend.role(of: element)
        if elementRole == (kAXWindowRole as String) {
            return (element, elementRole)
        }
        guard let parentWindow = backend.containingWindow(of: element),
              backend.role(of: parentWindow) == (kAXWindowRole as String) else {
            return nil
        }
        return (parentWindow, elementRole)
    }

    private func classifyMoveMode(
        window: WindowElementHandle,
        initialFrame: CGRect,
        source: ScreenGeometry
    ) throws -> WindowMoveMode {
        switch backend.fullScreenState(of: window) {
        case .success(true):
            return .nativeFullScreen
        case .failure(.attributeUnsupported):
            if backend.positionSettability(window).value == false,
               Self.spansFullScreenBand(initialFrame, on: source),
               backend.hasFullScreenCapableButton(window) {
                return .nativeFullScreen
            }
        case .success(false), .failure:
            break
        }

        guard backend.positionSettability(window).value == true else {
            throw WindowMoverError.windowPositionNotSettable
        }

        let fillsFullScreen = initialFrame.approximatelyEquals(source.accessibilityFrame, tolerance: 2)
        let coversSystemChrome = !source.accessibilityFrame.approximatelyEquals(
            source.accessibilityVisibleFrame,
            tolerance: 1
        )
        let isNonStandardWindow = backend.subrole(of: window) != (kAXStandardWindowSubrole as String)
        let lacksStandardButtons = !backend.hasStandardWindowButtons(window)

        if fillsFullScreen && (coversSystemChrome || isNonStandardWindow || lacksStandardButtons) {
            return .borderlessFullScreen
        }

        return .standard
    }

    private func exitNativeFullScreenAndAwaitDesktop(
        resolved: ResolvedWindow,
        initialFrame: CGRect,
        excludedSiblingWindows: [WindowElementHandle],
        application: WindowTargetApp,
        applicationName: String
    ) async throws -> (window: WindowElementHandle, restoredFrame: CGRect) {
        let window = resolved.window
        if resolved.focusedElementWasSheet || backend.hasAttachedModalSheet(window) {
            throw WindowMoverError.fullScreenExitBlockedByModalSheet(applicationName)
        }

        let canSetFullScreen = backend.isFullScreenSettable(window)
        let hasFullScreenButton = backend.hasFullScreenCapableButton(window)
        guard canSetFullScreen || hasFullScreenButton else {
            throw WindowMoverError.fullScreenExitUnsupported(applicationName)
        }

        var usedButtonFallback = false
        if canSetFullScreen {
            let exitResult = backend.setFullScreen(false, of: window)
            if !Self.isAcceptableTransitionTriggerResult(exitResult) {
                if backend.fullScreenState(of: window).value != false {
                    guard hasFullScreenButton,
                          Self.isAcceptableTransitionTriggerResult(
                              backend.pressFullScreenButton(of: window, requireFullScreenSubrole: false)
                          ) else {
                        throw WindowMoverError.fullScreenExitUnsupported(applicationName)
                    }
                    usedButtonFallback = true
                    await logDiagnostic(
                        "Used full-screen button fallback to exit full screen",
                        metadata: ["app": applicationName, "ax_error": "\(exitResult.rawValue)"]
                    )
                }
            }
        } else {
            guard Self.isAcceptableTransitionTriggerResult(
                backend.pressFullScreenButton(of: window, requireFullScreenSubrole: false)
            ) else {
                throw WindowMoverError.fullScreenExitUnsupported(applicationName)
            }
            usedButtonFallback = true
            await logDiagnostic(
                "Used full-screen button to exit full screen",
                metadata: ["app": applicationName]
            )
        }

        var activeWindow = window
        var elapsed = Duration.zero
        var lastCandidateFrame: CGRect?
        var stablePolls = 0
        var didRetryExit = false

        while elapsed < timing.exitFullScreenTimeout {
            try await backend.sleep(timing.pollInterval)
            elapsed += timing.pollInterval

            if backend.frontmostApplication()?.processIdentifier != application.processIdentifier {
                backend.activateApplication(processIdentifier: application.processIdentifier)
            }

            var frameResult = backend.frame(of: activeWindow)
            if case .failure(.invalidUIElement) = frameResult,
               let refreshed = resolveTargetWindow(
                   for: application.processIdentifier,
                   excluding: excludedSiblingWindows
               )?.window {
                activeWindow = refreshed
                frameResult = backend.frame(of: activeWindow)
            }

            let isStillFullScreen: Bool
            switch backend.fullScreenState(of: activeWindow) {
            case .success(let flag):
                isStillFullScreen = flag
            case .failure(.invalidUIElement):
                if let refreshed = resolveTargetWindow(
                    for: application.processIdentifier,
                    excluding: excludedSiblingWindows
                )?.window {
                    activeWindow = refreshed
                }
                continue
            case .failure(.attributeUnsupported):
                guard case .success(let settable) = backend.positionSettability(activeWindow) else {
                    continue
                }
                isStillFullScreen = !settable
            case .failure:
                lastCandidateFrame = nil
                stablePolls = 0
                continue
            }

            if !isStillFullScreen,
               backend.positionSettability(activeWindow).value == true,
               case .success(let currentFrame) = frameResult,
               currentFrame.width > 1,
               currentFrame.height > 1 {
                if let previous = lastCandidateFrame,
                   currentFrame.approximatelyEquals(previous, tolerance: 0.5) {
                    stablePolls += 1
                } else {
                    lastCandidateFrame = currentFrame
                    stablePolls = 1
                }

                let requiredPolls = currentFrame.approximatelyEquals(initialFrame, tolerance: 1.0)
                    ? (timing.requiredStablePolls + 1)
                    : timing.requiredStablePolls
                if stablePolls >= max(1, requiredPolls) {
                    return (activeWindow, currentFrame)
                }
            } else {
                lastCandidateFrame = nil
                stablePolls = 0

                if !didRetryExit,
                   elapsed >= timing.actionRetryInterval,
                   isStillFullScreen {
                    didRetryExit = true
                    if backend.hasAttachedModalSheet(activeWindow) {
                        throw WindowMoverError.fullScreenExitBlockedByModalSheet(applicationName)
                    }
                    await logDiagnostic(
                        "Retrying full-screen exit after transition stall",
                        metadata: ["app": applicationName]
                    )
                    if !usedButtonFallback, backend.isFullScreenSettable(activeWindow) {
                        let retryResult = backend.setFullScreen(false, of: activeWindow)
                        if !Self.isAcceptableTransitionTriggerResult(retryResult),
                           backend.fullScreenState(of: activeWindow).value != false,
                           backend.hasFullScreenCapableButton(activeWindow) {
                            _ = backend.pressFullScreenButton(
                                of: activeWindow,
                                requireFullScreenSubrole: false
                            )
                        }
                    } else if backend.fullScreenState(of: activeWindow).value != false,
                              backend.hasFullScreenCapableButton(activeWindow) {
                        _ = backend.pressFullScreenButton(
                            of: activeWindow,
                            requireFullScreenSubrole: false
                        )
                    }
                }
            }
        }

        throw WindowMoverError.fullScreenExitTimedOut(applicationName)
    }

    private func relocateDesktopWindow(
        _ window: WindowElementHandle,
        workingFrame: CGRect,
        source: ScreenGeometry,
        target: ScreenGeometry,
        screens: [ScreenGeometry],
        mode: WindowMoveMode
    ) throws {
        let moveSourceBounds: CGRect
        let targetBounds: CGRect

        switch mode {
        case .borderlessFullScreen:
            moveSourceBounds = source.accessibilityFrame
            targetBounds = target.accessibilityFrame
        case .nativeFullScreen:
            let restoredIndex = Self.screenIndex(containing: workingFrame, in: screens)
            moveSourceBounds = screens[restoredIndex].accessibilityVisibleFrame
            targetBounds = target.accessibilityVisibleFrame
        case .standard:
            moveSourceBounds = source.accessibilityVisibleFrame
            targetBounds = target.accessibilityVisibleFrame
        }

        let desiredSize: CGSize
        if mode == .borderlessFullScreen {
            desiredSize = targetBounds.size
        } else {
            desiredSize = CGSize(
                width: min(workingFrame.width, targetBounds.width),
                height: min(workingFrame.height, targetBounds.height)
            )
        }

        let canSetSize = backend.isSizeSettable(window)
        var didResizeBeforeMove = false
        if canSetSize,
           workingFrame.width > desiredSize.width + 0.5
            || workingFrame.height > desiredSize.height + 0.5
            || mode == .borderlessFullScreen {
            didResizeBeforeMove = backend.setSize(desiredSize, of: window) == .success
        }

        let sizeAfterStepA = backend.frame(of: window).value?.size ?? desiredSize
        let targetOrigin = Self.mappedOrigin(
            workingFrame.origin,
            sourceWindowSize: workingFrame.size,
            targetWindowSize: sizeAfterStepA,
            from: moveSourceBounds,
            to: targetBounds
        )

        let moveResult = backend.setPosition(targetOrigin, of: window)
        guard moveResult == .success else {
            if didResizeBeforeMove {
                _ = backend.setSize(workingFrame.size, of: window)
            }
            throw WindowMoverError.moveFailed(moveResult)
        }

        if canSetSize,
           case .success(let movedFrame) = backend.frame(of: window),
           !movedFrame.size.approximatelyEquals(desiredSize, tolerance: 1.0) {
            if backend.setSize(desiredSize, of: window) == .success,
               case .success(let resizedFrame) = backend.frame(of: window) {
                let adjustedOrigin = Self.mappedOrigin(
                    workingFrame.origin,
                    sourceWindowSize: workingFrame.size,
                    targetWindowSize: resizedFrame.size,
                    from: moveSourceBounds,
                    to: targetBounds
                )
                if !resizedFrame.origin.approximatelyEquals(adjustedOrigin, tolerance: 1.0) {
                    _ = backend.setPosition(adjustedOrigin, of: window)
                }
            }
        }
    }

    private func reenterNativeFullScreenOnTarget(
        window: WindowElementHandle,
        excludedSiblingWindows: [WindowElementHandle],
        application: WindowTargetApp,
        applicationName: String,
        target: ScreenGeometry,
        targetIndex: Int,
        screens: [ScreenGeometry]
    ) async throws {
        var activeWindow = window
        if backend.frontmostApplication()?.processIdentifier != application.processIdentifier {
            backend.activateApplication(processIdentifier: application.processIdentifier)
        }
        backend.raiseWindow(activeWindow)

        var placedOnTarget = false
        if case .success(let currentFrame) = backend.frame(of: activeWindow),
           Self.screenIndex(containing: currentFrame, in: screens) == targetIndex {
            placedOnTarget = true
        } else {
            var settleElapsed = Duration.zero
            while settleElapsed < timing.targetScreenSettleTimeout {
                try await backend.sleep(timing.pollInterval)
                settleElapsed += timing.pollInterval
                if case .success(let currentFrame) = backend.frame(of: activeWindow),
                   Self.screenIndex(containing: currentFrame, in: screens) == targetIndex {
                    placedOnTarget = true
                    break
                }
            }
        }

        guard placedOnTarget else {
            throw WindowMoverError.targetScreenPlacementFailed(target.name)
        }

        if timing.preFullScreenEntrySettleDelay > .zero {
            try await backend.sleep(timing.preFullScreenEntrySettleDelay)
        }

        let canSetFullScreen = backend.isFullScreenSettable(activeWindow)
        if canSetFullScreen {
            let enterResult = backend.setFullScreen(true, of: activeWindow)
            if !Self.isAcceptableTransitionTriggerResult(enterResult) {
                if backend.fullScreenState(of: activeWindow).value == false {
                    guard backend.hasFullScreenCapableButton(activeWindow),
                          Self.isAcceptableTransitionTriggerResult(
                              backend.pressFullScreenButton(of: activeWindow, requireFullScreenSubrole: true)
                          ) else {
                        throw WindowMoverError.fullScreenReentryTimedOut(applicationName)
                    }
                    await logDiagnostic(
                        "Used full-screen button fallback to re-enter full screen",
                        metadata: ["app": applicationName, "target_monitor": target.name]
                    )
                }
            }
        } else if backend.hasFullScreenCapableButton(activeWindow) {
            guard Self.isAcceptableTransitionTriggerResult(
                backend.pressFullScreenButton(of: activeWindow, requireFullScreenSubrole: true)
            ) else {
                throw WindowMoverError.fullScreenReentryTimedOut(applicationName)
            }
        } else {
            throw WindowMoverError.fullScreenReentryTimedOut(applicationName)
        }

        var elapsed = Duration.zero
        var nextRetryThreshold = timing.actionRetryInterval
        var retryCount = 0
        var lastEntryFrame: CGRect?
        var stableEntryPolls = 0

        while elapsed < timing.enterFullScreenTimeout {
            try await backend.sleep(timing.pollInterval)
            elapsed += timing.pollInterval

            if backend.frontmostApplication()?.processIdentifier != application.processIdentifier {
                backend.activateApplication(processIdentifier: application.processIdentifier)
            }

            var frameResult = backend.frame(of: activeWindow)
            if case .failure(.invalidUIElement) = frameResult,
               let refreshed = resolveTargetWindow(
                   for: application.processIdentifier,
                   excluding: excludedSiblingWindows
               )?.window {
                activeWindow = refreshed
                frameResult = backend.frame(of: activeWindow)
            }

            let isNowFullScreen: Bool
            switch backend.fullScreenState(of: activeWindow) {
            case .success(let flag):
                isNowFullScreen = flag
            case .failure(.invalidUIElement):
                if let refreshed = resolveTargetWindow(
                    for: application.processIdentifier,
                    excluding: excludedSiblingWindows
                )?.window {
                    activeWindow = refreshed
                }
                continue
            case .failure(.attributeUnsupported):
                guard case .success(let settable) = backend.positionSettability(activeWindow) else {
                    lastEntryFrame = nil
                    stableEntryPolls = 0
                    continue
                }
                isNowFullScreen = !settable
            case .failure:
                lastEntryFrame = nil
                stableEntryPolls = 0
                continue
            }

            if isNowFullScreen {
                guard case .success(let entryFrame) = frameResult,
                      entryFrame.width > 1,
                      entryFrame.height > 1,
                      Self.screenIndex(containing: entryFrame, in: screens) == targetIndex else {
                    lastEntryFrame = nil
                    stableEntryPolls = 0
                    continue
                }

                if let previous = lastEntryFrame,
                   entryFrame.approximatelyEquals(previous, tolerance: 0.5) {
                    stableEntryPolls += 1
                } else {
                    lastEntryFrame = entryFrame
                    stableEntryPolls = 1
                }

                let positionLocked = backend.positionSettability(activeWindow).value == false
                let requiredPolls = positionLocked ? 2 : max(2, timing.requiredStablePolls)
                if stableEntryPolls >= requiredPolls {
                    return
                }
            } else {
                lastEntryFrame = nil
                stableEntryPolls = 0

                if elapsed >= nextRetryThreshold, retryCount < 3 {
                    retryCount += 1
                    nextRetryThreshold += timing.actionRetryInterval

                    if backend.fullScreenState(of: activeWindow).value != true {
                        await logDiagnostic(
                            "Retrying full-screen re-entry on target monitor",
                            metadata: [
                                "app": applicationName,
                                "attempt": "\(retryCount)",
                                "target_monitor": target.name,
                            ]
                        )
                        backend.raiseWindow(activeWindow)
                        if backend.isFullScreenSettable(activeWindow) {
                            let retryResult = backend.setFullScreen(true, of: activeWindow)
                            if !Self.isAcceptableTransitionTriggerResult(retryResult),
                               backend.hasFullScreenCapableButton(activeWindow) {
                                _ = backend.pressFullScreenButton(
                                    of: activeWindow,
                                    requireFullScreenSubrole: true
                                )
                            }
                        } else if backend.hasFullScreenCapableButton(activeWindow) {
                            _ = backend.pressFullScreenButton(
                                of: activeWindow,
                                requireFullScreenSubrole: true
                            )
                        }
                    }
                }
            }
        }

        throw WindowMoverError.fullScreenReentryTimedOut(applicationName)
    }

    private func logDiagnostic(_ message: String, metadata: [String: String]) async {
        guard let logger else { return }
        await logger.log("window", message, metadata: metadata)
    }

    private static func spansFullScreenBand(_ frame: CGRect, on screen: ScreenGeometry) -> Bool {
        let full = screen.accessibilityFrame
        let visible = screen.accessibilityVisibleFrame
        let minExpectedHeight = min(full.height, visible.height) - 2
        return abs(frame.minX - full.minX) <= 2
            && abs(frame.width - full.width) <= 2
            && frame.minY >= full.minY - 2
            && frame.maxY <= full.maxY + 2
            && frame.height >= minExpectedHeight
    }

    private static func isAcceptableTransitionTriggerResult(_ result: AXError) -> Bool {
        result == .success || result == .cannotComplete
    }
}

private extension CGRect {
    var area: CGFloat {
        isNull || isInfinite ? 0 : width * height
    }

    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }

    func approximatelyEquals(_ other: CGRect, tolerance: CGFloat) -> Bool {
        origin.approximatelyEquals(other.origin, tolerance: tolerance)
            && size.approximatelyEquals(other.size, tolerance: tolerance)
    }
}

private extension CGSize {
    func approximatelyEquals(_ other: CGSize, tolerance: CGFloat) -> Bool {
        abs(width - other.width) <= tolerance && abs(height - other.height) <= tolerance
    }
}

private extension CGPoint {
    func squaredDistance(to other: CGPoint) -> CGFloat {
        let deltaX = x - other.x
        let deltaY = y - other.y
        return deltaX * deltaX + deltaY * deltaY
    }

    func approximatelyEquals(_ other: CGPoint, tolerance: CGFloat) -> Bool {
        abs(x - other.x) <= tolerance && abs(y - other.y) <= tolerance
    }
}
