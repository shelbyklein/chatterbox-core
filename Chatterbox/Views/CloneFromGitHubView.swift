import AppKit
import SwiftUI

/// Starts a project from a GitHub repo: pick one of yours (via `gh`) or paste a URL, and it's
/// cloned into a folder and bound to a new chat. A repo that already has a chat, or is already
/// cloned where it would go, opens that instead of cloning again.
struct CloneFromGitHubView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @AppStorage("cloneParentFolder") private var parentFolder = ""
    @State private var repos: [GitHubRepo] = []
    @State private var loadError: String?
    @State private var loading = true
    @State private var query = ""
    @State private var selection: String?
    @State private var cloning = false
    @State private var cloneError: String?

    /// A pasted URL or owner/name wins over the list selection.
    private var chosenRepo: String? { Git.parseRepo(query) ?? selection }

    private var parent: String {
        parentFolder.isEmpty
            ? (AppPreferences.defaults.string(forKey: "codexFolder") ?? NSHomeDirectory())
            : parentFolder
    }

    private var destination: String? {
        chosenRepo.map { (parent as NSString).appendingPathComponent(String($0.split(separator: "/").last ?? "")) }
    }

    private var filtered: [GitHubRepo] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty, Git.parseRepo(query) == nil else { return repos }
        return repos.filter { $0.nameWithOwner.lowercased().contains(q) || $0.description.lowercased().contains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Project from GitHub").font(.title3.weight(.semibold))

            TextField("Search your repos, or paste owner/name or a URL", text: $query)
                .textFieldStyle(.roundedBorder)

            Group {
                if loading {
                    ProgressView("Loading your repos\u{2026}").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let loadError, repos.isEmpty {
                    Text(loadError).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(filtered, selection: $selection) { repo in
                        HStack(spacing: 8) {
                            Image(systemName: repo.isPrivate ? "lock" : "book.closed").foregroundStyle(.secondary).frame(width: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(repo.nameWithOwner)
                                if !repo.description.isEmpty {
                                    Text(repo.description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer()
                            if model.session(forRepo: repo.nameWithOwner) != nil {
                                Text("Has a chat").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .tag(repo.nameWithOwner)
                    }
                }
            }
            .frame(height: 300)

            HStack {
                Text("Clone into").foregroundStyle(.secondary)
                Button((parent as NSString).abbreviatingWithTildeInPath) {
                    if let path = FolderPicker.choose(startingAt: parent, message: "Choose where to clone the repo") { parentFolder = path }
                }
                .buttonStyle(.link)
                if let destination {
                    Text("\u{2192} \((destination as NSString).lastPathComponent)").foregroundStyle(.secondary)
                }
            }
            .font(.callout)

            if let cloneError {
                Label(cloneError, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(actionTitle) { Task { await open() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosenRepo == nil || cloning)
            }
        }
        .padding(20)
        .frame(width: 560)
        .task { await load() }
    }

    private var actionTitle: String {
        if cloning { return "Cloning\u{2026}" }
        if let repo = chosenRepo, model.session(forRepo: repo) != nil { return "Open Chat" }
        return "Clone and Open"
    }

    private func load() async {
        do { repos = try await GitHubCLI.listRepos() } catch { loadError = error.localizedDescription }
        loading = false
    }

    private func open() async {
        guard let repo = chosenRepo, let destination else { return }
        cloneError = nil
        // The repo already has a chat: go there.
        if let existing = model.session(forRepo: repo) {
            model.selectedID = existing.id
            dismiss()
            return
        }
        let fm = FileManager.default
        if fm.fileExists(atPath: destination) {
            // Already cloned here: bind it instead of cloning again.
            let status = await Git.status(of: destination)
            guard status?.remotes.contains(where: { $0.repo?.lowercased() == repo.lowercased() }) == true else {
                cloneError = "\((destination as NSString).abbreviatingWithTildeInPath) already exists and isn't a clone of \(repo). Choose another folder."
                return
            }
        } else {
            cloning = true
            defer { cloning = false }
            do { try await GitHubCLI.clone(repo, into: destination) } catch {
                cloneError = error.localizedDescription
                return
            }
        }
        model.openProject(destination)
        if let session = model.selected {
            await GitStatusStore.shared.refresh(destination)
            session.updateGitHubRepo(from: GitStatusStore.shared.status(for: destination))
        }
        dismiss()
    }
}
