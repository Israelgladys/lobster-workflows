import AppKit
import ApplicationServices
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    private var hotkeyManager: HotkeyManager?
    private var didStart = false
    private var mainWindow: NSWindow?
    private var setupWindow: NSWindow?
    private var permissionTimer: Timer?
    private var apiKey: String?
    private var codexCredentials: CodexCredentials?
    let chat = ChatController()
    @Published var accessibilityReady = false
    @Published var shortcutReady = false
    @Published var screenReady = false
    @Published var keyReady = false
    @Published var codexAccount: String?
    @Published var codexSigningIn = false
    var codexReady: Bool { codexAccount != nil }
    var isReady: Bool { accessibilityReady && keyReady && codexReady }

    func applicationWillFinishLaunching(_ notification: Notification) {
        Log.info("applicationWillFinishLaunching")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("applicationDidFinishLaunching — starting services")
        guard !didStart else { return }
        didStart = true

        hotkeyManager = HotkeyManager { [weak self] in
            self?.handleHotkey()
        }
        chat.credentials = { [weak self] in
            guard let self, AXIsProcessTrusted(), let apiKey = self.apiKey, let codex = self.codexCredentials else { return nil }
            return (apiKey, codex)
        }
        chat.onTaskFinished = { [weak self] in self?.showMain() }
        chat.onSetupNeeded = { [weak self] in self?.showSetup() }
        chat.catalog.refresh()
        showMain()
        refreshPermissions()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPermissions() }
        }
        // Read once, outside hotkey handling: a Keychain prompt can steal app focus.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.apiKey = KeychainHelper.getAPIKey()
            self.keyReady = self.apiKey != nil
            if let tokens = KeychainHelper.getCodexTokens() { self.useCodex(tokens) }
            if !self.isReady { self.showSetup() }
        }

        Log.info("setup done")
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMain()
        return true
    }

    func showMain() {
        if mainWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "Third Hand"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = .black
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: MainView(chat: chat, store: chat.store, setup: self))
            window.setFrameAutosaveName("ThirdHandMain")
            if !window.setFrameUsingName("ThirdHandMain") { window.center() }
            mainWindow = window
        }
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showSetup() {
        if setupWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 520),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Third Hand Setup"
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = .black
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SetupView(delegate: self))
            window.center()
            setupWindow = window
        }
        setupWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private var lastPermissionState = ""

    private func refreshPermissions() {
        accessibilityReady = AXIsProcessTrusted()
        screenReady = CGPreflightScreenCaptureAccess()
        let permissionState = "accessibility=\(accessibilityReady) screenRecording=\(screenReady)"
        if permissionState != lastPermissionState { Log.info("Permissions " + permissionState); lastPermissionState = permissionState }
        if accessibilityReady && hotkeyManager?.isRunning == false { hotkeyManager?.start() }
        if !accessibilityReady && hotkeyManager?.isRunning == true { hotkeyManager?.stop() }
        shortcutReady = hotkeyManager?.isRunning == true
    }

    func openPrivacySettings(_ section: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + section) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Hotkey

    /// Opens a new thread with the app that was in front already mentioned.
    @objc func handleHotkey() {
        Log.info("Hotkey fired")
        let front = NSWorkspace.shared.frontmostApplication
        let app = front.flatMap { app -> ChatApp? in
            guard let id = app.bundleIdentifier, !AppTarget.ignoredBundles.contains(id) else { return nil }
            return ChatApp(name: app.localizedName ?? id, bundleID: id)
        }
        Log.info("Hotkey thread app=\(app?.bundleID ?? "none")")
        chat.newThread(app: app)
        showMain()
    }

    // MARK: - Onboarding

    @objc func promptAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opts) { openPrivacySettings("Privacy_Accessibility") }
        refreshPermissions()
    }

    func promptScreenRecording() {
        if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
        if !CGPreflightScreenCaptureAccess() { openPrivacySettings("Privacy_ScreenCapture") }
        refreshPermissions()
    }

    private func useCodex(_ tokens: CodexTokens) {
        codexCredentials = CodexCredentials(tokens: tokens)
        codexAccount = tokens.email ?? "ChatGPT account"
    }

    func signInWithChatGPT() {
        guard !codexSigningIn else { return }
        codexSigningIn = true
        Task {
            defer { codexSigningIn = false }
            do {
                let tokens = try await CodexAuth.signIn()
                try KeychainHelper.saveCodexTokens(tokens)
                useCodex(tokens)
                Log.info("ChatGPT sign-in succeeded")
                if isReady { setupWindow?.close(); showMain() } else { showSetup() }
            } catch is CancellationError {
            } catch {
                Log.info("ChatGPT sign-in failed")
                let failure = NSAlert()
                failure.messageText = "Could not sign in with ChatGPT"
                failure.informativeText = error.localizedDescription
                NSApp.activate(ignoringOtherApps: true)
                failure.runModal()
            }
        }
    }

    func signOutOfChatGPT() {
        KeychainHelper.deleteCodexTokens()
        codexCredentials = nil
        codexAccount = nil
    }

    @objc func promptAPIKey() {
        let alert = NSAlert()
        alert.messageText = "Enter API Key"
        alert.informativeText = "Jev API key (TypeSafe), stored in macOS Keychain. Jev finds the control for each step: the step, observed accessibility text, and recent action results are sent to TypeSafe. Screenshots and OCR processing stay on this Mac."
        alert.alertStyle = .informational

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "apikey_..."
        if let existing = apiKey { field.stringValue = existing }
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            let k = field.stringValue.trimmingCharacters(in: .whitespaces)
            if !k.isEmpty {
                do {
                    try KeychainHelper.saveAPIKey(k)
                    apiKey = k
                    keyReady = true
                }
                catch {
                    let failure = NSAlert()
                    failure.messageText = "Could not save API key"
                    failure.informativeText = error.localizedDescription
                    failure.runModal()
                }
            }
        }
    }
}

struct SetupView: View {
    @ObservedObject var delegate: AppDelegate

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: NSApplication.shared.applicationIconImage).resizable().frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Third Hand").font(.title2.bold())
                    Text(delegate.accessibilityReady && delegate.keyReady && delegate.codexReady ? "Ready when you are" : "Let’s get set up")
                        .foregroundStyle(.secondary)
                }
            }
            Text("Tag an app with @ in a thread, or press Control–Space in any app to start a thread with it.")
            HStack {
                Text(delegate.accessibilityReady ? "✓ Accessibility enabled" : "Accessibility access needed")
                Spacer()
                Button(delegate.accessibilityReady ? "Settings…" : "Enable…") {
                    if delegate.accessibilityReady { delegate.openPrivacySettings("Privacy_Accessibility") }
                    else { delegate.promptAccessibility() }
                }
            }
            HStack {
                Text(delegate.screenReady ? "✓ Screen Recording enabled" : "Screen Recording needed for local OCR")
                Spacer()
                Button(delegate.screenReady ? "Settings…" : "Enable…") {
                    if delegate.screenReady { delegate.openPrivacySettings("Privacy_ScreenCapture") }
                    else { delegate.promptScreenRecording() }
                }
            }
            HStack {
                Text(delegate.keyReady ? "✓ API key loaded" : "API key needs setup or Keychain approval")
                Spacer()
                Button("Set API Key…") { delegate.promptAPIKey() }
            }
            HStack {
                Text(delegate.codexAccount.map { "✓ Signed in with ChatGPT (\($0))" }
                     ?? (delegate.codexSigningIn ? "Finish signing in in your browser…" : "ChatGPT sign-in needed for planning"))
                Spacer()
                if delegate.codexReady {
                    Button("Sign Out") { delegate.signOutOfChatGPT() }
                } else {
                    Button("Sign in with ChatGPT…") { delegate.signInWithChatGPT() }.disabled(delegate.codexSigningIn)
                }
            }
            Text("Screen reading stays on-device. ChatGPT plans each step and writes any text; Jev finds the control. Your request and screen text are sent to OpenAI and TypeSafe.")
                .font(.caption).foregroundStyle(.secondary)
            Text(delegate.shortcutReady ? "✓ Control–Space is ready" : "Shortcut waiting for Accessibility access")
                .foregroundStyle(.secondary)
            Divider()
            Text("If macOS asks you to quit and reopen after enabling access, reopen this copy of Third Hand.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Show App in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
                .font(.caption)
        }
        .padding(24)
        .frame(width: 540)
    }
}
