import AppKit

struct AppEntry: Identifiable, Hashable {
    let name: String
    let bundleID: String
    let url: URL
    var id: String { bundleID }
    var chatApp: ChatApp { ChatApp(name: name, bundleID: bundleID) }
}

/// Apps that can be @mentioned: running apps first, then installed ones.
@MainActor
final class AppCatalog: ObservableObject {
    @Published private(set) var installed: [AppEntry] = []

    nonisolated static let searchDirectories = ["/Applications", "/Applications/Utilities", "/System/Applications",
                                                "/System/Applications/Utilities", NSHomeDirectory() + "/Applications"]

    func refresh() {
        Task.detached(priority: .utility) {
            let found = Self.scanInstalled()
            await MainActor.run { self.installed = found }
        }
    }

    nonisolated static func scanInstalled() -> [AppEntry] {
        var entries: [String: AppEntry] = [:]
        for directory in searchDirectories {
            let urls = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: directory),
                includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            for url in urls where url.pathExtension == "app" {
                guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier,
                      !AppTarget.ignoredBundles.contains(id), entries[id] == nil else { continue }
                let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? url.deletingPathExtension().lastPathComponent
                entries[id] = AppEntry(name: name, bundleID: id, url: url)
            }
        }
        return entries.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var running: [AppEntry] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, let id = app.bundleIdentifier, !AppTarget.ignoredBundles.contains(id),
                  let url = app.bundleURL else { return nil }
            return AppEntry(name: app.localizedName ?? url.deletingPathExtension().lastPathComponent, bundleID: id, url: url)
        }
    }

    var all: [AppEntry] {
        var seen: Set<String> = []
        return (running + installed).filter { seen.insert($0.bundleID).inserted }
    }

    func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// Running apps first, then installed; name prefix matches before substring matches.
    func suggestions(for partial: String, limit: Int = 8) -> [AppEntry] {
        let query = partial.lowercased()
        let runningIDs = Set(running.map(\.bundleID))
        func rank(_ entry: AppEntry) -> Int? {
            let name = entry.name.lowercased()
            let match = query.isEmpty || name.hasPrefix(query) ? 0 : name.contains(query) ? 1 : nil
            return match.map { $0 + (runningIDs.contains(entry.bundleID) ? 0 : 2) }
        }
        let ranked: [(entry: AppEntry, rank: Int)] = all.compactMap { entry in rank(entry).map { (entry, $0) } }
        let ordered = ranked.sorted { lhs, rhs in
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            return lhs.entry.name.localizedCaseInsensitiveCompare(rhs.entry.name) == .orderedAscending
        }
        return ordered.prefix(limit).map(\.entry)
    }

    func icon(for bundleID: String) -> NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSImage(systemSymbolName: "app", accessibilityDescription: nil) ?? NSImage()
    }

    /// Launches the app if needed (or asks a running app with no window to reopen one) and waits for a window.
    /// `hidden` launches it hidden, for background control to bring its window up out of sight.
    static func prepare(_ app: ChatApp, hidden: Bool = false, timeout: TimeInterval = 15) async throws -> NSRunningApplication {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).first { !$0.isTerminated }
        if let running, WindowSnapshot.frontWindow(pid: running.processIdentifier) != nil { return running }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) else {
            throw ControllerError.invalid("\(app.name) isn't installed.")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        // Stay in the chat while the planner reads the app; it comes forward before the first input.
        configuration.activates = false
        configuration.hides = hidden
        Log.info("Opening app bundle=\(app.bundleID) running=\(running != nil) hidden=\(hidden)")
        let launched = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            if WindowSnapshot.frontWindow(pid: launched.processIdentifier) != nil { return launched }
            if hidden, !WindowParking.windows(of: AXUIElementCreateApplication(launched.processIdentifier)).isEmpty { return launched }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw ControllerError.invalid("\(app.name) didn't open a window in time.")
    }
}
