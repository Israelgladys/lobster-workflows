import AppKit
import ApplicationServices

/// Input addressed to one window of one process. The user's pointer, front
/// app and key window are left alone; key focus is borrowed only for the few
/// milliseconds an event batch takes and then handed back.
enum BackgroundInput {
    enum Failure: Error, LocalizedError {
        case unavailable(String)
        case noFocus
        case invalid(String)
        var errorDescription: String? {
            switch self {
            case .unavailable(let missing): "Background input is unavailable on this macOS (missing \(missing))."
            case .noFocus: "The target window could not take background key focus."
            case .invalid(let reason): reason
            }
        }
    }

    static func ensureAvailable() throws {
        let missing = SkyLight.missingSymbols
        if !missing.isEmpty { throw Failure.unavailable(missing.joined(separator: ", ")) }
    }

    private static func withBorrowedFocus<T>(pid: pid_t, window: CGWindowID, _ body: () throws -> T) throws -> T {
        try ensureAvailable()
        guard let borrowed = SkyLight.borrowFocus(pid: pid, window: window) else { throw Failure.noFocus }
        defer { SkyLight.restore(borrowed) }
        usleep(40_000)
        return try body()
    }

    /// A click at a screen point inside `window`. The event stream matches the
    /// one Chromium accepts from a trusted source: a stamped move, an
    /// off-screen primer click for its user-activation gate, then the target.
    static func click(pid: pid_t, window: CGWindowID, at point: CGPoint, count: Int = 1, right: Bool = false) throws {
        try withBorrowedFocus(pid: pid, window: window) {
            let source = CGEventSource(stateID: .hidSystemState)
            let group = Int64(DispatchTime.now().uptimeNanoseconds & 0x7fff_ffff)
            let button: CGMouseButton = right ? .right : .left
            let down: CGEventType = right ? .rightMouseDown : .leftMouseDown
            let up: CGEventType = right ? .rightMouseUp : .leftMouseUp
            func emit(_ type: CGEventType, _ location: CGPoint, phase: Int64, clicks: Int64, delay: useconds_t) throws {
                guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: location, mouseButton: button) else {
                    throw Failure.invalid("Cannot create mouse event")
                }
                SkyLight.setField(event, 0, phase)
                SkyLight.setField(event, 1, clicks)
                SkyLight.setField(event, 3, right ? 1 : 0)
                SkyLight.setField(event, 7, 3)
                SkyLight.setField(event, 40, Int64(pid))
                for field: UInt32 in [51, 91, 92] { SkyLight.setField(event, field, Int64(window)) }
                SkyLight.setField(event, 58, group)
                SkyLight.setLocation(event, location)
                SkyLight.post(event, to: pid)
                if delay > 0 { usleep(delay) }
            }
            let offscreen = CGPoint(x: -1, y: -1)
            try emit(.mouseMoved, point, phase: 2, clicks: 0, delay: 15_000)
            if !right {
                try emit(.leftMouseDown, offscreen, phase: 1, clicks: 1, delay: 1_000)
                try emit(.leftMouseUp, offscreen, phase: 2, clicks: 1, delay: 100_000)
            }
            for n in 1...max(1, min(count, 3)) {
                try emit(down, point, phase: 3, clicks: Int64(n), delay: 1_000)
                try emit(up, point, phase: 3, clicks: Int64(n), delay: n < count ? 80_000 : 30_000)
            }
        }
    }

    static func scroll(pid: pid_t, window: CGWindowID, at point: CGPoint, lines: Int32) throws {
        try ensureAvailable()
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0) else {
            throw Failure.invalid("Cannot create scroll event")
        }
        event.location = point
        for field: UInt32 in [51, 91, 92] { SkyLight.setField(event, field, Int64(window)) }
        SkyLight.setLocation(event, point)
        SkyLight.post(event, to: pid)
    }

    private static func flags(_ modifiers: [String]) -> CGEventFlags {
        modifiers.reduce(CGEventFlags()) { flags, name in
            flags.union(["command": .maskCommand, "shift": .maskShift, "option": .maskAlternate, "control": .maskControl][name] ?? [])
        }
    }

    private static func postKey(_ code: CGKeyCode, flags: CGEventFlags, unicode: [UInt16]? = nil, pid: pid_t) throws {
        let source = CGEventSource(stateID: .hidSystemState)
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: isDown) else {
                throw Failure.invalid("Cannot create key event")
            }
            event.flags = flags
            if let unicode {
                unicode.withUnsafeBufferPointer { event.keyboardSetUnicodeString(stringLength: unicode.count, unicodeString: $0.baseAddress) }
            }
            SkyLight.post(event, to: pid, authenticate: true)
            usleep(8_000)
        }
    }

    static func press(pid: pid_t, window: CGWindowID, key: String, modifiers: [String] = []) throws {
        guard let code = InputController.keyCodes[key.lowercased()] else { throw Failure.invalid("Unsupported key") }
        try withBorrowedFocus(pid: pid, window: window) {
            try postKey(code, flags: flags(modifiers), pid: pid)
            usleep(30_000)
        }
    }

    /// Types in short bursts so key focus returns to the user's window between them.
    static func type(pid: pid_t, window: CGWindowID, text: String, check: () throws -> Void = {}) async throws {
        let characters = Array(text)
        for start in stride(from: 0, to: characters.count, by: 16) {
            try Task.checkCancellation()
            try check()
            try withBorrowedFocus(pid: pid, window: window) {
                for character in characters[start..<min(start + 16, characters.count)] {
                    try postKey(0, flags: [], unicode: Array(String(character).utf16), pid: pid)
                }
                usleep(20_000)
            }
            await Task.yield()
        }
    }

    /// Selects all text in a field without ⌘A, which AppKit only honours in the front app.
    @discardableResult
    static func selectAll(in field: AXUIElement) -> Bool {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(field, kAXValueAttribute as CFString, &value)
        var range = CFRange(location: 0, length: ((value as? String) ?? "").utf16.count)
        guard let selection = AXValueCreate(.cfRange, &range) else { return false }
        return AXUIElementSetAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, selection) == .success
    }

    /// Runs a ⌘ shortcut through the app's menu, since key equivalents only reach the
    /// front app. Returns false when no enabled menu item has that shortcut.
    static func menuShortcut(app: AXUIElement, key: String, modifiers: [String]) -> Bool {
        var bar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &bar) == .success, let bar,
              CFGetTypeID(bar) == AXUIElementGetTypeID() else { return false }
        // AXMenuItemCmdModifiers: shift 1, option 2, control 4; command is implied.
        let wanted = (modifiers.contains("shift") ? 1 : 0) | (modifiers.contains("option") ? 2 : 0) | (modifiers.contains("control") ? 4 : 0)
        func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
        }
        func find(_ element: AXUIElement, depth: Int) -> AXUIElement? {
            if (attribute(element, "AXMenuItemCmdChar") as? String)?.lowercased() == key.lowercased(),
               (attribute(element, "AXMenuItemCmdModifiers") as? Int) == wanted,
               (attribute(element, kAXEnabledAttribute) as? Bool) == true { return element }
            guard depth < 4 else { return nil }
            for child in (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
                if let hit = find(child, depth: depth + 1) { return hit }
            }
            return nil
        }
        guard let item = find(bar as! AXUIElement, depth: 0) else { return false }
        return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
    }

    /// Some apps activate themselves once their first window appears, even when launched
    /// without activation. Hands the front back to the user's app if that happens.
    static func keepBehind(_ app: NSRunningApplication, restoring previous: NSRunningApplication?, for seconds: Double = 3) async {
        guard let previous, previous.processIdentifier != app.processIdentifier else { return }
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, !Task.isCancelled {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier {
                Log.info("Launched app took the front; restoring the user's app")
                previous.activate()
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }
}
