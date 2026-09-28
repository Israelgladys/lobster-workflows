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

    static func captureCurrentApp() -> AppTarget? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            Log.info("captureCurrentApp: no frontmost app")
            return nil
        }
        let pid = frontApp.processIdentifier
        Log.info("captureCurrentApp: \(frontApp.localizedName ?? "?") pid=\(pid) bundle=\(frontApp.bundleIdentifier ?? "nil")")
        let ignoredBundles: Set<String> = [
            Bundle.main.bundleIdentifier ?? "",
            "com.apple.SecurityAgent",
            "com.apple.loginwindow",
            "com.apple.UserNotificationCenter",
        ]
        guard let bundleId = frontApp.bundleIdentifier,
              !ignoredBundles.contains(bundleId) else {
            Log.info("captureCurrentApp: filtered out (self or system: \(frontApp.bundleIdentifier ?? "nil"))")
            return nil
        }

        let appElement = AXUIElementCreateApplication(pid)
        let windowElement = focusedWindow(of: appElement)
        let frame = windowElement.flatMap { windowFrame(of: $0) }

        return AppTarget(
            pid: pid,
            name: frontApp.localizedName ?? "Unknown",
            bundleIdentifier: bundleId,
            application: frontApp,
            appElement: appElement,
            windowElement: windowElement,
            windowFrame: frame,
            icon: frontApp.icon
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
