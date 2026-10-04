import AppKit
import ApplicationServices

/// Gives background control a window when the app has none on screen: a minimized window, or the
/// windows of a hidden app, are moved onto an invisible display where the app treats them as visible.
/// `restore` puts everything back as it was: minimized or hidden again, at the original positions.
/// Windows move only while out of sight (minimized or hidden), so the user never sees them travel.
@MainActor
final class WindowParking {
    private struct Parked {
        let window: AXUIElement
        let id: CGWindowID
        let position: CGPoint
    }

    private let application: NSRunningApplication
    private let appElement: AXUIElement
    private var display: VirtualDisplay?
    private var parked: [Parked] = []
    private var unminimized: AXUIElement?
    private var unhid = false

    init(target: AppTarget) {
        application = target.application
        appElement = target.appElement
    }

    nonisolated static func windows(of app: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success else { return [] }
        return (value as? [AXUIElement]) ?? []
    }

    nonisolated static func bool(_ element: AXUIElement, _ attribute: String) -> Bool {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success && (value as? Bool) == true
    }

    private static func position(of window: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        var point = CGPoint.zero
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetValue(value as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    @discardableResult
    private static func move(_ window: AXUIElement, to point: CGPoint) -> Bool {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else { return false }
        return AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value) == .success
    }

    private static func onScreenFrame(_ id: CGWindowID) -> CGRect? {
        let windows = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]] ?? []
        guard let info = windows.first, (info[kCGWindowIsOnscreen as String] as? Bool) == true,
              let bounds = info[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: bounds)
    }

    /// Polls without honouring cancellation, so a stopped task still restores the user's windows.
    private func wait(timeout: TimeInterval, until condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            await withCheckedContinuation { continuation in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { continuation.resume() }
            }
        }
        return condition()
    }

    /// Parks the window background control will use. Throws when the app has no window to park.
    func park(appName: String) async throws {
        let windows = Self.windows(of: appElement)
        let hidden = application.isHidden
        // A hidden app shows all its open windows when unhidden, so all of them move; otherwise one
        // minimized window is brought back.
        let open = hidden ? windows.filter { !Self.bool($0, kAXMinimizedAttribute) } : []
        let minimized = open.isEmpty ? windows.first { Self.bool($0, kAXMinimizedAttribute) } : nil
        let moving = open.isEmpty ? minimized.map { [$0] } ?? [] : open
        guard !moving.isEmpty else {
            throw ControllerError.invalid("\(appName) has no window Third Hand can reach. Its windows may be on another desktop.")
        }
        guard let display = VirtualDisplay() else {
            throw ControllerError.invalid("\(appName)'s window is minimized or hidden, and this Mac couldn't create a display to use it in the background.")
        }
        self.display = display
        guard await wait(timeout: 3, until: { !display.bounds.isEmpty }) else {
            self.display = nil
            throw ControllerError.invalid("The background display didn't become ready.")
        }
        let origin = display.bounds.origin
        for (index, window) in moving.enumerated() {
            guard let id = SkyLight.windowID(of: window), let position = Self.position(of: window) else { continue }
            Self.move(window, to: CGPoint(x: origin.x + 40 + CGFloat(index * 30), y: origin.y + 40 + CGFloat(index * 30)))
            parked.append(Parked(window: window, id: id, position: position))
        }
        guard let first = parked.first else {
            self.display = nil
            throw ControllerError.invalid("\(appName)'s window couldn't be moved for background control.")
        }
        if hidden {
            application.unhide()
            unhid = true
        }
        if let minimized {
            AXUIElementSetAttributeValue(minimized, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            unminimized = minimized
        }
        let bounds = display.bounds
        let landed = await wait(timeout: 3) { Self.onScreenFrame(first.id).map { bounds.intersects($0) } ?? false }
        Log.info("Parked windows=\(parked.count) hidden=\(hidden) landed=\(landed)")
        if !landed { throw ControllerError.invalid("\(appName)'s window didn't open for background control.") }
    }

    /// Minimizes or hides again, then moves the windows back while they're out of sight.
    func restore() async {
        guard !parked.isEmpty else { display = nil; return }
        if let window = unminimized {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
            _ = await wait(timeout: 2) { Self.bool(window, kAXMinimizedAttribute) }
        }
        if unhid {
            application.hide()
            _ = await wait(timeout: 2) { self.application.isHidden }
        }
        for entry in parked { Self.move(entry.window, to: entry.position) }
        Log.info("Restored parked windows=\(parked.count)")
        parked = []
        unminimized = nil
        unhid = false
        display = nil
    }
}
