import SwiftUI

/// A widget tap creates a blank ordinary chat, without sending a message or agent turn.
struct MobileWidgetNewChat: View {
    let shortcut: WidgetChatShortcut
    let created: (UUID) -> Void
    @Environment(MobileStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var starting = false
    @State private var attempted = false
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let problem {
                    MobileProblemCard(problem)
                    Button("Try Again") { Task { await begin() } }
                        .buttonStyle(.borderedProminent).accessibilityIdentifier("widget-chat-retry")
                } else {
                    ProgressView("Opening \(shortcut.title)…")
                }
            }
            .padding(24)
            .navigationTitle("\(shortcut.modelTitle) · Medium")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(starting)
                }
            }
            .interactiveDismissDisabled(starting)
            .task {
                guard !attempted else { return }
                attempted = true
                await begin()
            }
        }
    }

    @MainActor private func begin() async {
        guard !starting else { return }
        starting = true; problem = nil
        do {
            let detail = try await store.newChat(in: nil, backend: shortcut.rawValue,
                settings: .init(model: shortcut.model, effort: shortcut.effort))
            created(detail.summary.id)
            dismiss()
        } catch {
            problem = error.localizedDescription
        }
        starting = false
    }
}

/// New Chat: where it goes, then the agent, model, effort and permissions (or a preset),
/// all chosen before it starts. The Mac works out each step's options, so what you see is
/// what the chat gets.
struct MobileNewChatSheet: View {
    struct Studio: Identifiable, Hashable { var id: UUID; var name: String }
    let studios: [Studio]
    let start: (Companion.ChatDetail) -> Void
    @State var studio: UUID?
    /// New Project: the chat starts, then becomes the project of the folder chosen here.
    @State var newProject = false
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
    /// New Project's folder on the Mac: the folder itself, or the parent of a new subfolder.
    @State private var folder = ""
    @State private var createFolder = true
    @State private var folderName = ""
    @State private var browsing = false

    /// "Start in": Chats, a Studio, or a new project.
    private enum Place: Hashable { case chats, studio(UUID), newProject }
    private var place: Binding<Place> {
        Binding(get: { newProject ? .newProject : studio.map(Place.studio) ?? .chats },
                set: { pick in
                    switch pick {
                    case .chats: newProject = false; studio = nil
                    case .studio(let id): newProject = false; studio = id
                    case .newProject: newProject = true; studio = nil
                    }
                })
    }
    private var projectFolderName: String {
        let typed = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? name.trimmingCharacters(in: .whitespacesAndNewlines) : typed
    }
    private var projectReady: Bool {
        !newProject || (!folder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (!createFolder || !projectFolderName.isEmpty))
    }

    var body: some View {
        NavigationStack {
            Group {
                if let options {
                    ChatSettingsForm(options: options, apply: choose) {
                        Section("Name") {
                            TextField("Optional: named from your first message", text: $name)
                                .accessibilityIdentifier("new-chat-name")
                        }
                        // The row names itself: no header over it saying the same.
                        Section {
                            Picker("Start in", selection: place) {
                                Text("Chats").tag(Place.chats)
                                ForEach(studios) { Text($0.name).tag(Place.studio($0.id)) }
                                Text("New Project\u{2026}").tag(Place.newProject)
                            }
                            .accessibilityIdentifier("new-chat-place")
                        }
                        if newProject {
                            Section {
                                Button { browsing = true } label: {
                                    HStack {
                                        Label(folder.isEmpty ? "Choose a Mac Folder" : (folder as NSString).lastPathComponent, systemImage: "folder")
                                        Spacer()
                                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                                    }
                                }
                                .accessibilityIdentifier("new-project-browse")
                                if !folder.isEmpty {
                                    Text(folder).font(.footnote.monospaced()).foregroundStyle(.secondary)
                                        .accessibilityIdentifier("new-project-folder")
                                }
                                Toggle("Create a new subfolder", isOn: $createFolder)
                                    .accessibilityIdentifier("new-project-create-folder")
                                if createFolder {
                                    TextField(name.isEmpty ? "Folder name" : name, text: $folderName)
                                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                                        .accessibilityIdentifier("new-project-folder-name")
                                }
                            } header: {
                                Text(createFolder ? "Inside this folder on your Mac" : "Project folder on your Mac")
                            } footer: {
                                Text(createFolder ? "Makes the folder and starts the project's chat in it."
                                     : "Each folder has one main project chat.")
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
            .navigationTitle(newProject ? "New Project" : "New Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") { begin() }.disabled(options == nil || starting || !projectReady).fontWeight(.semibold)
                        .accessibilityIdentifier("new-chat-start")
                }
            }
            .task(id: studio) { await load() }
            .sheet(isPresented: $browsing) {
                MacProjectFolderPicker(initialPath: folder.isEmpty ? nil : folder) { folder = $0 }
            }
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
                var detail = try await store.newChat(in: newProject ? nil : studio, backend: options.backend, preset: picks.preset,
                                                      settings: settings, title: name, desk: putOnDesk)
                if newProject {
                    // The fresh chat becomes the folder's project chat, before its first message.
                    do {
                        detail = try await store.promote(detail.summary.id, using: .init(kind: .project,
                            folder: folder.trimmingCharacters(in: .whitespacesAndNewlines),
                            newFolderName: createFolder ? projectFolderName : nil))
                    } catch {
                        problem = "\(error.localizedDescription) The chat was started in Chats; use Make Project\u{2026} in its menu to try again."
                        starting = false
                        await store.loadChats()
                        return
                    }
                }
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
