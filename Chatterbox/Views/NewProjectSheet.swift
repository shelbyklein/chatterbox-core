import SwiftUI

/// Makes a new project folder, optionally a git repository, and opens its chat.
struct NewProjectSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var location = NSHomeDirectory()
    @AppStorage("newProjectGitInit") private var gitInit = true
    @State private var error: String?
    @State private var creating = false

    private var folder: String { (location as NSString).appendingPathComponent(AppModel.folderName(for: name)) }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var exists: Bool { !trimmedName.isEmpty && FileManager.default.fileExists(atPath: folder) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Project").font(.title3.weight(.semibold))

            Form {
                TextField("Name", text: $name, prompt: Text("my-new-project"))
                LabeledContent("Location") {
                    HStack {
                        Text((location as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Choose\u{2026}") {
                            if let path = FolderPicker.choose(startingAt: location, message: "Choose where the new project folder goes") {
                                location = path
                            }
                        }
                    }
                }
                Toggle("Start a git repository", isOn: $gitInit)
            }
            .formStyle(.columns)

            Group {
                if exists {
                    Label("\((folder as NSString).abbreviatingWithTildeInPath) already exists. Use Open Project to open it.",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                } else if let error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                } else if !trimmedName.isEmpty {
                    Text("Creates \((folder as NSString).abbreviatingWithTildeInPath)").foregroundStyle(.secondary)
                } else {
                    Text(" ")
                }
            }
            .font(.caption)
            .lineLimit(2)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty || exists || creating)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { location = model.newProjectLocation }
    }

    private func create() {
        creating = true
        Task {
            do {
                try await model.createProject(named: trimmedName, in: location, gitInit: gitInit)
                dismiss()
            } catch {
                self.error = error.localizedDescription
                creating = false
            }
        }
    }
}
