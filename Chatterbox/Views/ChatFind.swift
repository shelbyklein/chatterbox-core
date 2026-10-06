import AppKit
import SwiftUI

/// ⌘F in a chat: what's searched for, the messages that match (oldest first), and which one
/// is current. Matches cover the whole history, not just the rows drawn.
@MainActor
@Observable
final class ChatFind {
    var isOpen = false
    var query = "" { didSet { if query != oldValue { recompute() } } }
    private(set) var matches: [UUID] = []
    private(set) var current: Int?
    /// Bumped to ask the transcript to bring the current match into view.
    private(set) var jumpRequest = 0
    /// Bumped to put the cursor in the search field.
    private(set) var focusRequest = 0
    @ObservationIgnored weak var session: ChatSession?

    var currentID: UUID? { current.map { matches[$0] } }

    func open() {
        isOpen = true
        focusRequest += 1
        recompute()
    }

    func close() {
        isOpen = false
        current = nil
    }

    func next() { step(+1) }
    func previous() { step(-1) }

    private func step(_ direction: Int) {
        guard !matches.isEmpty else { return }
        let start = current ?? (direction > 0 ? -1 : matches.count)
        current = (start + direction + matches.count) % matches.count
        jumpRequest += 1
    }

    /// Re-searches, keeping the newest match current when the query changes.
    func recompute() {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard isOpen, !words.isEmpty, let session else { matches = []; current = nil; return }
        matches = session.items.filter { item in
            let text = Self.searchableText(item)
            return !text.isEmpty && words.allSatisfy { text.localizedStandardContains($0) }
        }.map(\.id)
        if matches.isEmpty { current = nil } else { current = matches.count - 1; jumpRequest += 1 }
    }

    private static func searchableText(_ item: DisplayItem) -> String {
        [item.text, item.detail ?? "", item.attachments?.map(\.url.lastPathComponent).joined(separator: " ") ?? ""]
            .joined(separator: " ")
    }
}

/// The find bar above a chat's messages.
struct ChatFindBar: View {
    @Bindable var find: ChatFind
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find in this chat", text: $find.query)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit {
                    if NSEvent.modifierFlags.contains(.shift) { find.previous() } else { find.next() }
                    focused = true
                }
                .onKeyPress(.escape) { find.close(); return .handled }
            if !find.query.isEmpty {
                Text(find.matches.isEmpty ? "No matches" : "\((find.current ?? 0) + 1) of \(find.matches.count)")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            Button { find.previous() } label: { Image(systemName: "chevron.up") }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(find.matches.isEmpty).help("Previous match (⇧⌘G)")
            Button { find.next() } label: { Image(systemName: "chevron.down") }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(find.matches.isEmpty).help("Next match (⌘G)")
            Button("Done") { find.close() }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .onAppear { focused = true }
        .onChange(of: find.focusRequest) { focused = true }
    }
}

/// ⌘F for the window's own chat (Command Center tiles leave it to the window).
struct FindShortcut: ViewModifier {
    let find: ChatFind
    let session: ChatSession
    let enabled: Bool

    func body(content: Content) -> some View {
        content
            .background {
                if enabled {
                    Button("Find") { find.session = session; find.open() }
                        .keyboardShortcut("f", modifiers: .command)
                        .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
                }
            }
            .onAppear { find.session = session }
    }
}
