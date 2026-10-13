import SwiftUI

/// New Chat: where it goes, then the agent, model, effort and permissions (or a preset),
/// all chosen before it starts. The Mac works out each step's options, so what you see is
/// what the chat gets.
struct MobileNewChatSheet: View {
    struct Studio: Identifiable, Hashable { var id: UUID; var name: String }
    let studios: [Studio]
    let start: (Companion.ChatDetail) -> Void
    @State var studio: UUID?
    @Environment(MobileStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var picks = Companion.SettingsRequest()
    @State private var options: Companion.ChatOptions?
    @State private var problem: String?
    @State private var starting = false

    var body: some View {
        NavigationStack {
            Group {
                if let options {
                    ChatSettingsForm(options: options, apply: choose) {
                        if !studios.isEmpty {
                            Section("Start in") {
                                Picker("Start in", selection: $studio) {
                                    Text("Chats").tag(UUID?.none)
                                    ForEach(studios) { Text($0.name).tag(UUID?.some($0.id)) }
                                }
                                .accessibilityIdentifier("new-chat-place")
                            }
                        }
                        if let problem { Text(problem).font(.footnote).foregroundStyle(.orange) }
                    }
                    .tint(MobileConversationStyle.accent(for: options.backend))
                } else if let problem {
                    ContentUnavailableView("Can't reach the Mac", systemImage: "wifi.exclamationmark", description: Text(problem))
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("New Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") { begin() }.disabled(options == nil || starting).fontWeight(.semibold)
                        .accessibilityIdentifier("new-chat-start")
                }
            }
            .task(id: studio) { await load() }
        }
    }

    /// One change: switching agent or preset starts that part over; the rest add up.
    private func choose(_ change: Companion.SettingsRequest) {
        if let preset = change.preset {
            picks = .init(preset: preset)
        } else if let backend = change.backend, backend != options?.backend {
            picks = .init(backend: backend)
        } else {
            if let model = change.model { picks.model = model; picks.effort = nil }
            if let effort = change.effort { picks.effort = effort }
            if let mode = change.mode { picks.mode = mode }
            if let fast = change.fastMode { picks.fastMode = fast }
        }
        Task { await load() }
    }

    private func load() async {
        do { options = try await store.newChatOptions(picks, studio: studio); problem = nil }
        catch { problem = error.localizedDescription }
    }

    private func begin() {
        guard let options else { return }
        starting = true
        Task {
            do {
                // The settings as shown, so the chat starts exactly as picked.
                let settings = Companion.SettingsRequest(model: options.model, effort: options.effort, mode: options.mode, fastMode: options.fastMode)
                let detail = try await store.newChat(in: studio, backend: options.backend, preset: picks.preset, settings: settings)
                dismiss()
                start(detail)
                await store.loadChats()
            } catch {
                problem = error.localizedDescription
                starting = false
            }
        }
    }
}
