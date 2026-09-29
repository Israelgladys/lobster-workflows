import SwiftUI

@main
struct ThirdHandApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // The chat window is managed by AppDelegate so the Dock icon and Control–Space can always reopen it.
        Settings {
            SetupView(delegate: appDelegate)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Thread") {
                    appDelegate.chat.newThread()
                    appDelegate.showMain()
                }
                .keyboardShortcut("n")
            }
            CommandGroup(after: .windowList) {
                Button("Third Hand") { appDelegate.showMain() }
                    .keyboardShortcut("0")
            }
        }
    }
}
