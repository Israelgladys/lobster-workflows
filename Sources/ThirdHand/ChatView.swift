import AppKit
import SwiftUI

/// Monochrome palette: black surfaces, hairline borders, white text, one accent.
enum Theme {
    static let background = Color.black
    static let sidebar = Color(white: 0.043)
    static let surface = Color(white: 0.075)
    static let raised = Color(white: 0.11)
    static let border = Color(white: 0.16)
    static let text = Color(white: 0.96)
    static let secondary = Color(white: 0.55)
    static let tertiary = Color(white: 0.36)
    static let accent = Color(red: 0.55, green: 0.64, blue: 1.0)
    static let success = Color(red: 0.36, green: 0.84, blue: 0.55)
    static let failure = Color(red: 1.0, green: 0.42, blue: 0.42)
}

struct MainView: View {
    @ObservedObject var chat: ChatController
    @ObservedObject var store: ThreadStore
    @ObservedObject var setup: AppDelegate

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(chat: chat, store: store, setup: setup)
                .frame(width: 250)
            Rectangle().fill(Theme.border).frame(width: 1)
            VStack(spacing: 0) {
                if !setup.isReady { SetupBanner(setup: setup) }
                if let id = store.selection, let thread = store.thread(id) {
                    ThreadView(chat: chat, thread: thread)
                } else {
                    EmptyState(chat: chat)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background)
        }
        .foregroundStyle(Theme.text)
        .background(Theme.background)
        .ignoresSafeArea()
        .frame(minWidth: 760, minHeight: 480)
        .preferredColorScheme(.dark)
    }
}

private struct SetupBanner: View {
    @ObservedObject var setup: AppDelegate

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(Color.yellow).frame(width: 7, height: 7)
            Text("Finish setup to let Third Hand control apps").font(.system(size: 13))
            Spacer()
            Button("Open Setup") { setup.showSetup() }.buttonStyle(PillButtonStyle())
        }
        .padding(.horizontal, 20).padding(.top, 40).padding(.bottom, 12)
        .background(Theme.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }
}

private struct EmptyState: View {
    @ObservedObject var chat: ChatController

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "hand.raised.fill").font(.system(size: 34, weight: .light)).foregroundStyle(Theme.secondary)
            Text("Tag an app. Tell it what to do.").font(.system(size: 20, weight: .semibold))
            Text("“@Spotify play something chill” · “@Notes start a grocery list”\nPress Control–Space in any app to start a thread with it.")
                .font(.system(size: 13)).multilineTextAlignment(.center).foregroundStyle(Theme.secondary).lineSpacing(3)
            Button("New thread") { chat.newThread() }.buttonStyle(PillButtonStyle(prominent: true)).keyboardShortcut("n")
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    @ObservedObject var chat: ChatController
    @ObservedObject var store: ThreadStore
    @ObservedObject var setup: AppDelegate

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Third Hand").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.secondary)
                Spacer()
                Button { chat.newThread() } label: {
                    Image(systemName: "square.and.pencil").font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(IconButtonStyle()).help("New thread (⌘N)")
            }
            .padding(.leading, 16).padding(.trailing, 10)
            .padding(.top, 40).padding(.bottom, 12)

            Text("THREADS").font(.system(size: 10, weight: .semibold)).tracking(0.8).foregroundStyle(Theme.tertiary)
                .padding(.horizontal, 16).padding(.bottom, 6)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(store.sorted) { thread in
                        ThreadRow(thread: thread, selected: store.selection == thread.id, catalog: chat.catalog)
                            .onTapGesture { store.selection = thread.id }
                            .contextMenu { Button("Delete Thread", role: .destructive) { store.delete(thread.id) } }
                    }
                }
                .padding(.horizontal, 8)
            }

            Spacer(minLength: 0)
            Button { setup.showSetup() } label: {
                HStack(spacing: 8) {
                    Circle().fill(setup.isReady ? Theme.success : Color.yellow).frame(width: 7, height: 7)
                    Text(setup.codexAccount ?? "Setup").font(.system(size: 12)).lineLimit(1)
                    Spacer()
                    Image(systemName: "gearshape").font(.system(size: 12))
                }
                .foregroundStyle(Theme.secondary)
                .padding(.horizontal, 16).padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
        }
        .background(Theme.sidebar)
    }
}

private struct ThreadRow: View {
    let thread: ChatThread
    let selected: Bool
    let catalog: AppCatalog
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let app = thread.lastApp {
                    Image(nsImage: catalog.icon(for: app.bundleID)).resizable()
                } else {
                    Image(systemName: "bubble.left").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
            }
            .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(thread.title).font(.system(size: 13, weight: selected ? .semibold : .regular)).lineLimit(1)
                if let last = thread.messages.last(where: { $0.role == .task }) {
                    Text(last.status ?? last.text).font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if thread.messages.contains(where: { $0.state == .running }) {
                ProgressView().controlSize(.mini)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Theme.raised : hovering ? Theme.surface : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

// MARK: - Conversation

private struct ThreadView: View {
    @ObservedObject var chat: ChatController
    let thread: ChatThread

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if let app = thread.lastApp {
                    Image(nsImage: chat.catalog.icon(for: app.bundleID)).resizable().frame(width: 16, height: 16)
                }
                Text(thread.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 24).padding(.top, 14).padding(.bottom, 12)
            .frame(height: 52, alignment: .bottom)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        ForEach(thread.messages) { message in
                            MessageRow(message: message, catalog: chat.catalog) {
                                chat.stop(messageID: message.id, in: thread.id)
                            }
                            .id(message.id)
                        }
                    }
                    .padding(.horizontal, 24).padding(.vertical, 20)
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .scrollContentBackground(.hidden)
                .onChange(of: thread.messages.last) { _, last in
                    if let last { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
                .onAppear { if let last = thread.messages.last { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
            Composer(chat: chat, threadID: thread.id, lastApp: thread.lastApp)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
        }
    }
}

private struct MessageRow: View {
    let message: ChatMessage
    let catalog: AppCatalog
    let onStop: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            avatar
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(message.date, style: .time).font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                    if let seconds = message.seconds, message.state == .done {
                        Text(String(format: "· %.0fs", seconds)).font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                    }
                }
                if message.role == .user {
                    Text(Self.highlighted(message.text)).font(.system(size: 14)).lineSpacing(2).textSelection(.enabled)
                } else {
                    taskBody
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var title: String {
        message.role == .user ? "You" : message.app?.name ?? "Third Hand"
    }

    @ViewBuilder private var avatar: some View {
        Group {
            if message.role == .user {
                Circle().fill(Theme.raised).overlay(Image(systemName: "person.fill").font(.system(size: 12)).foregroundStyle(Theme.secondary))
            } else if let app = message.app {
                Image(nsImage: catalog.icon(for: app.bundleID)).resizable()
            } else {
                Circle().fill(Theme.raised).overlay(Image(systemName: "hand.raised.fill").font(.system(size: 11)).foregroundStyle(Theme.secondary))
            }
        }
        .frame(width: 28, height: 28)
    }

    @ViewBuilder private var taskBody: some View {
        switch message.state {
        case .queued, .running:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(message.status ?? "Working…").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                Button("Stop", action: onStop).buttonStyle(PillButtonStyle())
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.border))
        case .done:
            result(icon: "checkmark", color: Theme.success, text: message.text)
        case .failed:
            result(icon: "xmark", color: Theme.failure, text: message.text)
        case .stopped:
            result(icon: "stop.fill", color: Theme.tertiary, text: message.text)
        case nil:
            Text(message.text).font(.system(size: 14))
        }
    }

    private func result(icon: String, color: Color, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon).font(.system(size: 10, weight: .bold)).foregroundStyle(color)
            Text(text).font(.system(size: 14)).lineSpacing(2).textSelection(.enabled)
                .foregroundStyle(message.state == .stopped ? Theme.secondary : Theme.text)
        }
    }

    /// Shows the first @mention in the accent color.
    static func highlighted(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)
        if let range = text.range(of: #"@[^\s@]+"#, options: .regularExpression),
           let attributedRange = Range(range, in: attributed) {
            attributed[attributedRange].foregroundColor = Theme.accent
            attributed[attributedRange].font = .system(size: 14, weight: .semibold)
        }
        return attributed
    }
}

// MARK: - Composer

private struct Composer: View {
    @ObservedObject var chat: ChatController
    let threadID: UUID
    let lastApp: ChatApp?
    @FocusState private var focused: Bool
    @State private var highlighted = 0

    private var draft: Binding<String> {
        Binding(get: { chat.drafts[threadID] ?? "" }, set: { chat.drafts[threadID] = $0 })
    }

    private var suggestions: [AppEntry] {
        MentionParser.partial(in: draft.wrappedValue).map { chat.catalog.suggestions(for: $0) } ?? []
    }

    private var canSend: Bool { !draft.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, entry in
                        Button { complete(with: entry) } label: {
                            HStack(spacing: 10) {
                                Image(nsImage: chat.catalog.icon(for: entry.bundleID)).resizable().frame(width: 18, height: 18)
                                Text(entry.name).font(.system(size: 13))
                                Spacer()
                                if !chat.catalog.isRunning(entry.bundleID) {
                                    Text("opens").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                                }
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 6).fill(index == highlighted ? Theme.raised : .clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField("", text: draft, prompt: Text(placeholder).foregroundStyle(Theme.tertiary), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .lineLimit(1...6)
                    .focused($focused)
                    .onSubmit(submit)
                    .onKeyPress(.upArrow) { move(-1) }
                    .onKeyPress(.downArrow) { move(1) }
                    .onKeyPress(.tab) {
                        guard let entry = suggestions[safe: highlighted] else { return .ignored }
                        complete(with: entry)
                        return .handled
                    }
                    .padding(.vertical, 3)
                Button(action: submit) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(canSend ? Color.black : Theme.tertiary)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(canSend ? Theme.text : Theme.raised))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
            }
            .padding(.leading, 14).padding(.trailing, 8).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 14).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(focused ? Theme.tertiary : Theme.border))
        }
        .padding(.horizontal, 24).padding(.bottom, 20).padding(.top, 4)
        .onAppear { focusAtEnd() }
        .onChange(of: chat.focusRequest) { _, _ in focusAtEnd() }
        .onChange(of: draft.wrappedValue) { _, _ in highlighted = 0 }
    }

    /// Focusing a text field selects its contents on macOS; put the caret after a prefilled "@App " instead.
    private func focusAtEnd() {
        focused = true
        DispatchQueue.main.async {
            guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return }
            editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        }
    }

    private var placeholder: String {
        lastApp.map { "Message \($0.name), or @mention another app" } ?? "@mention an app and say what to do"
    }

    private func move(_ delta: Int) -> KeyPress.Result {
        guard !suggestions.isEmpty else { return .ignored }
        highlighted = (highlighted + delta + suggestions.count) % suggestions.count
        return .handled
    }

    private func submit() {
        if let entry = suggestions[safe: highlighted] { complete(with: entry); return }
        chat.send(in: threadID)
        focused = true
    }

    private func complete(with entry: AppEntry) {
        var text = draft.wrappedValue
        if let at = text.lastIndex(of: "@") { text = String(text[..<at]) }
        draft.wrappedValue = text + "@\(entry.name) "
        focused = true
    }
}

// MARK: - Controls

private struct PillButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(prominent ? Color.black : Theme.text)
            .padding(.horizontal, prominent ? 16 : 10).padding(.vertical, prominent ? 7 : 4)
            .background(Capsule().fill(prominent ? Theme.text : Theme.raised))
            .overlay(Capsule().stroke(prominent ? .clear : Theme.border))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

private struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Theme.secondary)
            .frame(width: 26, height: 26)
            .background(RoundedRectangle(cornerRadius: 6).fill(configuration.isPressed ? Theme.raised : .clear))
            .contentShape(Rectangle())
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
