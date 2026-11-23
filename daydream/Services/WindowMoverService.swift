import AppKit
import ApplicationServices

struct WindowMoveResult {
    let applicationName: String
    let sourceScreenName: String
    let targetScreenName: String
}

enum WindowMoverError: LocalizedError {
    case accessibilityPermissionMissing
    case noFrontmostApplication
    case noFocusedWindow(String)
    case onlyOneScreen
    case unreadableWindowFrame
    case windowPositionNotSettable
    case moveFailed(AXError)

    var errorDescription: String? {
        switch self {
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
        case .moveFailed(let error):
            "The focused window could not be moved (Accessibility error \(error.rawValue))."
        }
    }
}

@MainActor
final class WindowMoverService {
    func moveFocusedWindowToNextScreen() throws -> WindowMoveResult {
        guard AXIsProcessTrusted() else {
            throw WindowMoverError.accessibilityPermissionMissing
        }

        guard let application = NSWorkspace.shared.frontmostApplication else {
            throw WindowMoverError.noFrontmostApplication
        }

        let screens = orderedScreens()
        guard screens.count > 1 else {
            throw WindowMoverError.onlyOneScreen
        }

        let applicationName = application.localizedName ?? application.bundleIdentifier ?? "Unknown App"
        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        guard let window = focusedWindow(of: applicationElement) else {
            throw WindowMoverError.noFocusedWindow(applicationName)
        }

        guard let windowOrigin = pointAttribute(kAXPositionAttribute, of: window),
              let windowSize = sizeAttribute(kAXSizeAttribute, of: window) else {
            throw WindowMoverError.unreadableWindowFrame
        }

        var isPositionSettable = DarwinBoolean(false)
        let settableResult = AXUIElementIsAttributeSettable(
            window,
            kAXPositionAttribute as CFString,
            &isPositionSettable
        )
        guard settableResult == .success, isPositionSettable.boolValue else {
            throw WindowMoverError.windowPositionNotSettable
        }

        let windowFrame = CGRect(origin: windowOrigin, size: windowSize)
        let sourceIndex = screenIndex(containing: windowFrame, in: screens)
        let targetIndex = screens.index(after: sourceIndex) == screens.endIndex
            ? screens.startIndex
            : screens.index(after: sourceIndex)
        let source = screens[sourceIndex]
        let target = screens[targetIndex]
        var targetOrigin = mappedOrigin(
            windowOrigin,
            windowSize: windowSize,
            from: source.accessibilityVisibleFrame,
            to: target.accessibilityVisibleFrame
        )

        guard let positionValue = AXValueCreate(.cgPoint, &targetOrigin) else {
            throw WindowMoverError.unreadableWindowFrame
        }

        let moveResult = AXUIElementSetAttributeValue(
            window,
            kAXPositionAttribute as CFString,
            positionValue
        )
        guard moveResult == .success else {
            throw WindowMoverError.moveFailed(moveResult)
        }

        return WindowMoveResult(
            applicationName: applicationName,
            sourceScreenName: source.name,
            targetScreenName: target.name
        )
    }

    private func focusedWindow(of application: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            application,
            kAXFocusedWindowAttribute as CFString,
            &value
        )
        guard result == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private func pointAttribute(_ attribute: String, of element: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cgPoint else { return nil }

        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else {
            return nil
        }
        return point
    }

    private func sizeAttribute(_ attribute: String, of element: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cgSize else { return nil }

        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else {
            return nil
        }
        return size
    }

    private func orderedScreens() -> [ScreenGeometry] {
        NSScreen.screens
            .map(ScreenGeometry.init)
            .sorted {
                if $0.accessibilityFrame.minX == $1.accessibilityFrame.minX {
                    return $0.accessibilityFrame.minY < $1.accessibilityFrame.minY
                }
                return $0.accessibilityFrame.minX < $1.accessibilityFrame.minX
            }
    }

    private func screenIndex(containing windowFrame: CGRect, in screens: [ScreenGeometry]) -> Int {
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

    private func mappedOrigin(
        _ origin: CGPoint,
        windowSize: CGSize,
        from sourceFrame: CGRect,
        to targetFrame: CGRect
    ) -> CGPoint {
        let sourceTravelX = max(0, sourceFrame.width - windowSize.width)
        let sourceTravelY = max(0, sourceFrame.height - windowSize.height)
        let relativeX = sourceTravelX > 0 ? (origin.x - sourceFrame.minX) / sourceTravelX : 0
        let relativeY = sourceTravelY > 0 ? (origin.y - sourceFrame.minY) / sourceTravelY : 0
        let targetTravelX = max(0, targetFrame.width - windowSize.width)
        let targetTravelY = max(0, targetFrame.height - windowSize.height)

        return CGPoint(
            x: targetFrame.minX + min(max(relativeX, 0), 1) * targetTravelX,
            y: targetFrame.minY + min(max(relativeY, 0), 1) * targetTravelY
        )
    }
}

private struct ScreenGeometry {
    let name: String
    let accessibilityFrame: CGRect
    let accessibilityVisibleFrame: CGRect

    @MainActor
    init(screen: NSScreen) {
        name = screen.localizedName
        accessibilityFrame = Self.accessibilityFrame(from: screen.frame)
        accessibilityVisibleFrame = Self.accessibilityFrame(from: screen.visibleFrame)
    }

    @MainActor
    private static func accessibilityFrame(from appKitFrame: CGRect) -> CGRect {
        let mainScreenTop = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(
            x: appKitFrame.minX,
            y: mainScreenTop - appKitFrame.maxY,
            width: appKitFrame.width,
            height: appKitFrame.height
        )
    }
}

private extension CGRect {
    var area: CGFloat {
        isNull || isInfinite ? 0 : width * height
    }

    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}

private extension CGPoint {
    func squaredDistance(to other: CGPoint) -> CGFloat {
        let deltaX = x - other.x
        let deltaY = y - other.y
        return deltaX * deltaX + deltaY * deltaY
    }
}
