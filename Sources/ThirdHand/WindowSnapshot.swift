import AppKit
import ScreenCaptureKit
import ApplicationServices

struct WindowSnapshot {
    let windowID: CGWindowID
    let frame: CGRect // Global Quartz coordinates, top-left origin.
    let image: CGImage?

    /// All of an app's windows that accessibility reports, including minimized ones and a hidden app's.
    nonisolated static func axWindows(of app: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success else { return [] }
        return (value as? [AXUIElement]) ?? []
    }

    static func frontWindow(pid: pid_t) -> (id: CGWindowID, frame: CGRect)? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let candidates: [(id: CGWindowID, frame: CGRect)] = windows.compactMap { window in
            guard window[kCGWindowOwnerPID as String] as? Int32 == pid,
                  window[kCGWindowLayer as String] as? Int == 0,
                  let id = window[kCGWindowNumber as String] as? UInt32,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds), frame.width > 1, frame.height > 1 else { return nil }
            return (id, frame)
        }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        var focused: CFTypeRef?
        var focusedFrame: CGRect?
        if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focused) == .success,
           let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() {
            focusedFrame = InputController.frame(focused as! AXUIElement)
        }
        return selectWindow(candidates, focusedFrame: focusedFrame)
    }

    /// Keep AX traversal, click bounds, and capture tied to the same real window.
    static func selectWindow(_ candidates: [(id: CGWindowID, frame: CGRect)],
                             focusedFrame: CGRect?) -> (id: CGWindowID, frame: CGRect)? {
        guard let focusedFrame else { return candidates.first }
        return candidates.first { candidate in
            abs(candidate.frame.minX - focusedFrame.minX) < 2 &&
            abs(candidate.frame.minY - focusedFrame.minY) < 2 &&
            abs(candidate.frame.width - focusedFrame.width) < 2 &&
            abs(candidate.frame.height - focusedFrame.height) < 2
        }
    }

    static func capture(pid: pid_t) async throws -> WindowSnapshot {
        guard CGPreflightScreenCaptureAccess() else {
            throw ControllerError.invalid("Enable Screen Recording for Third Hand in System Settings, then relaunch to read screen text locally.")
        }
        guard let front = frontWindow(pid: pid) else { throw ControllerError.invalid("No visible target window") }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == front.id }) else {
            throw ControllerError.invalid("Target window is unavailable for capture")
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let scale = min(1, 1600 / max(window.frame.width, window.frame.height))
        config.width = max(1, Int(window.frame.width * scale))
        config.height = max(1, Int(window.frame.height * scale))
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return WindowSnapshot(windowID: window.windowID, frame: window.frame, image: image)
    }

    func point(x: Double, y: Double) -> CGPoint {
        CGPoint(x: frame.minX + x * (frame.width - 1), y: frame.minY + y * (frame.height - 1))
    }
}
