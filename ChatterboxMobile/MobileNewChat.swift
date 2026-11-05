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
    /// Its name; empty: named from the first message.
    @State private var name = ""
    /// Put on the Desk: a task for it there, named from the first message.
    @State private var putOnDesk = false

    var body: some View {
        NavigationStack {
            Group {
                if let options {
                    ChatSettingsForm(options: options, apply: choose) {
                        Section("Name") {
                            TextField("Optional: named from your first message", text: $name)
                                .accessibilityIdentifier("new-chat-name")
                        }
                        if !studios.isEmpty {
                            // The row names itself: no header over it saying the same.
                            Section {
                                Picker("Start in", selection: $studio) {
                                    Text("Chats").tag(UUID?.none)
                                    ForEach(studios) { Text($0.name).tag(UUID?.some($0.id)) }
                                }
                                .accessibilityIdentifier("new-chat-place")
                            }
                        }
                        Section {
                            Toggle("Put on the Desk", isOn: $putOnDesk)
                                .accessibilityIdentifier("new-chat-desk")
                        } footer: {
                            Text("A task for it on the Desk, named from your first message.")
                        }
                        if let problem { Text(problem).font(.footnote).foregroundStyle(.orange) }
                    }
                    // As in Chat Settings: the app's blue, whichever agent is picked.
                    .tint(.blue)
                } else if let problem {
                    MobileProblemCard(problem).padding(.horizontal, 24).frame(maxWidth: 420, maxHeight: .infinity)
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
        .tint(.blue)
    }

    private func choose(_ change: Companion.SettingsRequest) {
        picks.add(change, backend: options?.backend)
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
                let settings = Companion.SettingsRequest(model: options.model, effort: options.effort, mode: options.mode, fastMode: options.fastMode,
                                                         openModel: options.openModel)
                let detail = try await store.newChat(in: studio, backend: options.backend, preset: picks.preset, settings: settings, title: name,
                                                      desk: putOnDesk)
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
