import AppKit
import ApplicationServices

struct AppTarget {
    let pid: pid_t
    let name: String
    let bundleIdentifier: String?
    let application: NSRunningApplication
    let appElement: AXUIElement
    let windowElement: AXUIElement?
    let windowFrame: NSRect?
    let icon: NSImage?

    var isTerminal: Bool {
        ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable", "net.kovidgoyal.kitty", "org.alacritty"].contains(bundleIdentifier ?? "")
    }

    static let ignoredBundles: Set<String> = [
        Bundle.main.bundleIdentifier ?? "",
        "com.apple.SecurityAgent",
        "com.apple.loginwindow",
        "com.apple.UserNotificationCenter",
    ]

    static func captureCurrentApp() -> AppTarget? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            Log.info("captureCurrentApp: no frontmost app")
            return nil
        }
        Log.info("captureCurrentApp: \(frontApp.localizedName ?? "?") pid=\(frontApp.processIdentifier) bundle=\(frontApp.bundleIdentifier ?? "nil")")
        return make(from: frontApp)
    }

    /// A target for any running app except Third Hand itself and system security UI.
    static func make(from app: NSRunningApplication) -> AppTarget? {
        guard let bundleId = app.bundleIdentifier, !ignoredBundles.contains(bundleId), !app.isTerminated else {
            Log.info("AppTarget: filtered out (self or system: \(app.bundleIdentifier ?? "nil"))")
            return nil
        }
        let pid = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)
        let windowElement = focusedWindow(of: appElement)
        let frame = windowElement.flatMap { windowFrame(of: $0) }

        return AppTarget(
            pid: pid,
            name: app.localizedName ?? "Unknown",
            bundleIdentifier: bundleId,
            application: app,
            appElement: appElement,
            windowElement: windowElement,
            windowFrame: frame,
            icon: app.icon
        )
    }

    private static func focusedWindow(of app: AXUIElement) -> AXUIElement? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value)
        guard result == .success else { return nil }
        return (value as! AXUIElement)
    }

    private static func windowFrame(of window: AXUIElement) -> NSRect? {
        var posValue: AnyObject?
        var sizeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posValue) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success
        else { return nil }

        var position = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posValue as! AXValue, .cgPoint, &position)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)

        guard let primaryScreen = NSScreen.screens.first else { return nil }
        let screenHeight = primaryScreen.frame.height
        let appKitY = screenHeight - position.y - size.height

        return NSRect(x: position.x, y: appKitY, width: size.width, height: size.height)
    }
}
