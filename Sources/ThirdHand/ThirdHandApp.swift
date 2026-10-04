import SwiftUI

@main
struct ThirdHandApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // The chat window is managed by AppDelegate so the Dock icon and Control–Space can always reopen it.
        Settings { EmptyView() }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { appDelegate.showSetup() }
                    .keyboardShortcut(",")
            }
            CommandGroup(replacing: .newItem) {
                Button("New Thread") {
                    appDelegate.chat.newThread()
                    appDelegate.showMain()
                }
                .keyboardShortcut("n")
            }
            CommandMenu("Debug") {
                Button("Run Benchmark") {
                    appDelegate.showMain()
                    Task { await appDelegate.benchmark.run() }
                }
                .keyboardShortcut("b", modifiers: [.command, .option])
                Button("Edit Benchmark Tasks…") {
                    if let url = Benchmark.specURL {
                        _ = try? appDelegate.benchmark.loadSpec()
                        NSWorkspace.shared.open(url)
                    }
                }
                Button("Show Benchmark Results") {
                    NSWorkspace.shared.activateFileViewerSelecting([Benchmark.resultsURL])
                }
            }
            CommandGroup(after: .windowList) {
                Button("Third Hand") { appDelegate.showMain() }
                    .keyboardShortcut("0")
            }
        }
    }
}
