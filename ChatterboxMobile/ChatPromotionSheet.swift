import SwiftUI

struct ChatPromotionTarget: Identifiable {
    let chat: Companion.ChatSummary
    let kind: Companion.PromotionRequest.Kind
    var id: UUID { chat.id }
}

/// Used by the home rows/cards and the open conversation's menu.
struct ChatPromotionSheet: View {
    let target: ChatPromotionTarget
    var completed: (Companion.ChatDetail) -> Void
    @Environment(MobileStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var options: Companion.PromotionOptions?
    @State private var studioID: UUID?
    @State private var name = ""
    @State private var keepFolder = true
    @State private var folder = ""
    @State private var createFolder = false
    @State private var browsing = false
    @State private var saving = false
    @State private var error: String?

    private var isStudio: Bool { target.kind == .studio }
    private var ready: Bool {
        guard options != nil, !saving else { return false }
        return isStudio ? studioID != nil || !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            : !folder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (!createFolder || !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var body: some View {
        NavigationStack {
            Form {
                if let options {
                    if isStudio {
                        Section("Destination") {
                            Picker("Studio", selection: $studioID) {
                                Text("New Studio").tag(nil as UUID?)
                                ForEach(options.studios) { Text($0.name).tag(Optional($0.id)) }
                            }
                            .accessibilityIdentifier("promotion-studio")
                            if studioID == nil {
                                TextField("Studio name", text: $name).accessibilityIdentifier("promotion-name")
                            }
                        }
                        Section {
                            if studioID != nil {
                                Toggle("Keep current working folder", isOn: $keepFolder)
                                Text(keepFolder ? options.currentFolder : options.studios.first(where: { $0.id == studioID })?.folder ?? "")
                                    .font(.footnote.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                            } else {
                                Label("Creates a folder in Chatterbox/Studios on your Mac.", systemImage: "folder.badge.plus")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                        } header: { Text("Working folder") } footer: {
                            Text(studioID != nil && keepFolder ? "The session joins the Studio and keeps working in its current folder."
                                 : "The session will work in the Studio folder. Changing folders starts a fresh Claude session with your visible history.")
                        }
                    } else {
                        Section {
                            TextField("Folder path on Mac", text: $folder)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .accessibilityIdentifier("promotion-folder")
                            Button { browsing = true } label: { Label("Browse Mac Folders", systemImage: "folder") }
                            Toggle("Create a new subfolder", isOn: $createFolder)
                            if createFolder {
                                TextField("Folder name", text: $name).accessibilityIdentifier("promotion-name")
                            }
                        } header: { Text(createFolder ? "Parent folder on your Mac" : "Project folder on your Mac") } footer: {
                            Text("Each folder has one main project chat. Changing folders starts a fresh Claude session with your visible history.")
                        }
                    }
                    Section {
                        Text("Your conversation, draft and settings stay. Existing files stay where they are.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                } else if error == nil {
                    ProgressView("Loading destinations…")
                }
                if let error {
                    Section {
                        Text(error).foregroundStyle(.red)
                        if options == nil { Button("Try Again") { Task { await load() } } }
                    }
                }
            }
            .disabled(saving)
            .navigationTitle(isStudio ? "Move to Studio" : "Make Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button { submit() } label: {
                        if saving { ProgressView() } else { Text(isStudio ? (studioID == nil ? "Create" : "Move") : "Make Project") }
                    }
                    .disabled(!ready).accessibilityIdentifier("promotion-save")
                }
            }
            .interactiveDismissDisabled(saving)
            .sheet(isPresented: $browsing) {
                MacProjectFolderPicker(initialPath: folder.isEmpty ? options?.currentFolder : folder) { folder = $0 }
            }
            .task { name = target.chat.title; await load() }
        }
    }

    private func load() async {
        error = nil
        do { options = try await store.promotionOptions(target.chat.id) }
        catch { self.error = error.localizedDescription }
    }

    private func submit() {
        guard ready else { return }
        saving = true; error = nil
        let request = Companion.PromotionRequest(kind: target.kind, studioID: studioID,
            name: isStudio && studioID == nil ? name : nil,
            folder: isStudio ? nil : folder.trimmingCharacters(in: .whitespacesAndNewlines),
            newFolderName: !isStudio && createFolder ? name : nil, keepFolder: keepFolder)
        Task {
            do {
                let result = try await store.promote(target.chat.id, using: request)
                completed(result); dismiss()
            } catch { self.error = error.localizedDescription }
            saving = false
        }
    }
}

private struct MacProjectFolderPicker: View {
    let initialPath: String?
    var choose: (String) -> Void
    @Environment(MobileStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var listing: Companion.ProjectFolders?
    @State private var error: String?
    @State private var loading = false

    var body: some View {
        NavigationStack {
            List {
                if let listing {
                    Section {
                        Text(listing.path).font(.footnote.monospaced()).textSelection(.enabled)
                        if let parent = listing.parent {
                            Button { Task { await load(parent) } } label: { Label("Parent Folder", systemImage: "arrow.up") }
                        }
                        Button { Task { await load(nil) } } label: { Label("Mac Home Folder", systemImage: "house") }
                    }
                    Section("Folders") {
                        ForEach(listing.folders) { child in
                            Button { Task { await load(child.path) } } label: {
                                HStack { Label(child.name, systemImage: "folder"); Spacer(); Image(systemName: "chevron.right").foregroundStyle(.secondary) }
                            }
                        }
                        if listing.folders.isEmpty { Text("No subfolders").foregroundStyle(.secondary) }
                    }
                }
                if loading { ProgressView("Loading folders…") }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .disabled(loading)
            .navigationTitle("Mac Folders").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use Folder") { if let listing { choose(listing.path); dismiss() } }
                        .disabled(listing == nil || loading)
                }
            }
            .task { await load(initialPath) }
        }
    }

    private func load(_ path: String?) async {
        loading = true; error = nil
        defer { loading = false }
        do { listing = try await store.projectFolders(at: path) }
        catch { self.error = error.localizedDescription }
    }
}
