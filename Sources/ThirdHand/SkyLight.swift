import AppKit
import ApplicationServices
import Darwin

/// Runtime bridge to the private WindowServer (SkyLight) calls that deliver
/// input to a background window without moving the pointer or raising it.
/// The recipe follows the MIT-licensed Cua Driver and yabai. Every symbol is
/// resolved lazily; when one is missing, callers fail closed.
enum SkyLight {
    private typealias PostToPid = @convention(c) (pid_t, UnsafeMutableRawPointer) -> Void
    private typealias SetIntField = @convention(c) (UnsafeMutableRawPointer, UInt32, Int64) -> Void
    private typealias SetWindowLocation = @convention(c) (UnsafeMutableRawPointer, Double, Double) -> Void
    private typealias PostEventRecord = @convention(c) (UnsafeRawPointer, UnsafeRawPointer) -> Int32
    private typealias GetFrontProcess = @convention(c) (UnsafeMutableRawPointer) -> Int32
    private typealias GetProcessForPID = @convention(c) (pid_t, UnsafeMutableRawPointer) -> Int32
    private typealias MainConnection = @convention(c) () -> UInt32
    private typealias GetWindowOwner = @convention(c) (UInt32, UInt32, UnsafeMutablePointer<UInt32>) -> Int32
    private typealias GetConnectionPSN = @convention(c) (UInt32, UnsafeMutableRawPointer) -> Int32
    private typealias SetAuthMessage = @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer) -> Void
    private typealias AuthFactory = @convention(c) (AnyClass, Selector, UnsafeMutableRawPointer, Int32, UInt32) -> UnsafeMutableRawPointer?
    private typealias AXGetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    typealias AXObserverAddRemote = @convention(c) (AXObserver, AXUIElement, CFString, UnsafeMutableRawPointer?) -> AXError

    private static let handles: [UnsafeMutableRawPointer] = [
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
        "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices",
    ].compactMap { (path: String) in dlopen(path, RTLD_LAZY | RTLD_GLOBAL) }

    private static func symbol<T>(_ name: String, as _: T.Type) -> T? {
        for handle in handles { if let pointer = dlsym(handle, name) { return unsafeBitCast(pointer, to: T.self) } }
        guard let pointer = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    private static let postToPid = symbol("SLEventPostToPid", as: PostToPid.self)
    private static let setIntField = symbol("SLEventSetIntegerValueField", as: SetIntField.self)
    private static let setWindowLocation = symbol("CGEventSetWindowLocation", as: SetWindowLocation.self)
    private static let postEventRecord = symbol("SLPSPostEventRecordTo", as: PostEventRecord.self)
    private static let getFrontProcess = symbol("_SLPSGetFrontProcess", as: GetFrontProcess.self)
    private static let getProcessForPID = symbol("GetProcessForPID", as: GetProcessForPID.self)
    private static let mainConnection = symbol("CGSMainConnectionID", as: MainConnection.self)
    private static let getWindowOwner = symbol("SLSGetWindowOwner", as: GetWindowOwner.self)
    private static let getConnectionPSN = symbol("SLSGetConnectionPSN", as: GetConnectionPSN.self)
    private static let setAuthMessage = symbol("SLEventSetAuthenticationMessage", as: SetAuthMessage.self)
    private static let msgSend = symbol("objc_msgSend", as: AuthFactory.self)
    private static let axGetWindow = symbol("_AXUIElementGetWindow", as: AXGetWindow.self)
    static let axObserverAddRemote = symbol("_AXObserverAddNotificationAndCheckRemote", as: AXObserverAddRemote.self)

    static var missingSymbols: [String] {
        [("SLEventPostToPid", postToPid != nil), ("SLEventSetIntegerValueField", setIntField != nil),
         ("CGEventSetWindowLocation", setWindowLocation != nil), ("SLPSPostEventRecordTo", postEventRecord != nil),
         ("_SLPSGetFrontProcess", getFrontProcess != nil), ("GetProcessForPID", getProcessForPID != nil)]
            .filter { !$0.1 }.map(\.0)
    }
    static var isAvailable: Bool { missingSymbols.isEmpty }

    static func windowID(of window: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        guard let axGetWindow, axGetWindow(window, &id) == .success, id != 0 else { return nil }
        return id
    }

    private static func pointer(_ event: CGEvent) -> UnsafeMutableRawPointer {
        Unmanaged.passUnretained(event).toOpaque()
    }

    static func setField(_ event: CGEvent, _ field: UInt32, _ value: Int64) {
        if let setIntField { setIntField(pointer(event), field, value) }
        else if let known = CGEventField(rawValue: field) { event.setIntegerValueField(known, value: value) }
    }

    static func setLocation(_ event: CGEvent, _ point: CGPoint) {
        setWindowLocation?(pointer(event), point.x, point.y)
    }

    /// Posts to one process. Keyboard events carry an authentication message,
    /// which Chromium-family apps require before accepting background keys.
    static func post(_ event: CGEvent, to pid: pid_t, authenticate: Bool = false) {
        guard let postToPid else { return event.postToPid(pid) }
        if authenticate { attachAuthentication(event, pid: pid) }
        postToPid(pid, pointer(event))
    }

    private static func attachAuthentication(_ event: CGEvent, pid: pid_t) {
        guard let setAuthMessage, let msgSend, let cls = NSClassFromString("SLSEventAuthenticationMessage") else { return }
        let selector = NSSelectorFromString("messageWithEventRecord:pid:version:")
        guard class_getClassMethod(cls, selector) != nil else { return }
        // __CGEvent is {CFRuntimeBase, uint32_t, SLSEventRecord *}.
        let base = pointer(event)
        for offset in [24, 32, 16] {
            guard let record = base.load(fromByteOffset: offset, as: UnsafeMutableRawPointer?.self) else { continue }
            if let message = msgSend(cls, selector, record, pid, 0) { setAuthMessage(base, message) }
            return
        }
    }

    // MARK: Focus without raise

    typealias PSN = [UInt8]

    static func frontProcess() -> PSN? {
        guard let getFrontProcess else { return nil }
        var psn = PSN(repeating: 0, count: 8)
        return psn.withUnsafeMutableBytes { getFrontProcess($0.baseAddress!) } == 0 ? psn : nil
    }

    static func process(owning window: CGWindowID, pid: pid_t) -> PSN? {
        var psn = PSN(repeating: 0, count: 8)
        if let mainConnection, let getWindowOwner, let getConnectionPSN {
            var owner: UInt32 = 0
            if getWindowOwner(mainConnection(), window, &owner) == 0, owner != 0,
               psn.withUnsafeMutableBytes({ getConnectionPSN(owner, $0.baseAddress!) }) == 0 { return psn }
        }
        guard let getProcessForPID else { return nil }
        return psn.withUnsafeMutableBytes { getProcessForPID(pid, $0.baseAddress!) } == 0 ? psn : nil
    }

    private static func focusRecord(_ window: CGWindowID, focused: Bool) -> [UInt8] {
        var record = [UInt8](repeating: 0, count: 0xF8)
        record[0x04] = 0xF8
        record[0x08] = 0x0D
        withUnsafeBytes(of: window.littleEndian) { record.replaceSubrange(0x3C..<0x40, with: $0) }
        record[0x8A] = focused ? 0x01 : 0x02
        return record
    }

    @discardableResult
    private static func send(_ record: [UInt8], to psn: PSN) -> Bool {
        guard let postEventRecord else { return false }
        return psn.withUnsafeBytes { p in record.withUnsafeBytes { r in postEventRecord(p.baseAddress!, r.baseAddress!) } } == 0
    }

    /// The user's app and key window, captured before borrowing key focus.
    struct Borrowed {
        let userPSN: PSN
        let userPID: pid_t?
        let userWindow: CGWindowID?
        let targetPSN: PSN
        let targetWindow: CGWindowID
    }

    /// Makes `window` key inside its app while the user's app stays frontmost
    /// and nothing is raised. Pair every call with `restore`.
    static func borrowFocus(pid: pid_t, window: CGWindowID) -> Borrowed? {
        guard let user = frontProcess(), let target = process(owning: window, pid: pid) else { return nil }
        let userApp = NSWorkspace.shared.frontmostApplication
        let userWindow = userApp.flatMap { keyWindow(of: $0.processIdentifier) }
        if user != target { send(focusRecord(window, focused: false), to: user) }
        guard send(focusRecord(window, focused: true), to: target) else { return nil }
        return Borrowed(userPSN: user, userPID: userApp?.processIdentifier, userWindow: userWindow,
                        targetPSN: target, targetWindow: window)
    }

    /// Returns key focus to the user's window. Without this the user's app
    /// stays frontmost but silently stops receiving their keystrokes.
    static func restore(_ borrowed: Borrowed) {
        guard borrowed.userPSN != borrowed.targetPSN else { return }
        send(focusRecord(borrowed.targetWindow, focused: false), to: borrowed.targetPSN)
        if let window = borrowed.userWindow { send(focusRecord(window, focused: true), to: borrowed.userPSN) }
    }

    static func keyWindow(of pid: pid_t) -> CGWindowID? {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
           let value, CFGetTypeID(value) == AXUIElementGetTypeID(), let id = windowID(of: value as! AXUIElement) { return id }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.first { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
            .flatMap { $0[kCGWindowNumber as String] as? CGWindowID }
    }
}
