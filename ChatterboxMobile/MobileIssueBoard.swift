import PhotosUI
import SwiftUI

// A project's issue board on the phone (plans/project-issues.md, I3): from a project chat's About
// (Issues). Issues grouped by game (General last), open work first; a game filter and Show Done;
// New Issue and an issue's page edit them, attach photos, and Start, Open or Unlink its thread.

private enum IssueWords {
    static let statuses: [(id: String, title: String)] = [("open", "Open"), ("inProgress", "In progress"), ("review", "Review"), ("done", "Done")]
    static func status(_ id: String) -> String { statuses.first { $0.id == id }?.title ?? id }
    static func type(_ id: String) -> String { ["bug": "Bug", "feature": "Feature", "polish": "Polish"][id] ?? id }
    static func priority(_ id: String) -> String { ["low": "Low", "normal": "Normal", "high": "High"][id] ?? id }
    static func typeIcon(_ id: String) -> String { ["bug": "ladybug", "feature": "sparkles", "polish": "wand.and.stars"][id] ?? "circle" }
    static func typeColor(_ id: String) -> Color { ["bug": .red, "feature": .blue, "polish": .purple][id] ?? .secondary }
    static func statusColor(_ id: String) -> Color { ["inProgress": .blue, "review": .green, "done": .secondary][id] ?? .orange }
}

struct MobileIssueBoardView: View {
    @Environment(MobileStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    /// Any session in the project.
    let chat: UUID
    @State private var board: Companion.IssueBoard?
    @State private var problem: String?
    @State private var game = "all"
    @State private var showDone = false
    @State private var adding = false

    var body: some View {
        NavigationStack {
            Group {
                if let board {
                    List {
                        let groups = groups(board)
                        if groups.isEmpty {
                            ContentUnavailableView("No issues yet", systemImage: "checklist",
                                                   description: Text("Tap + to file one. Agents in this project file them too."))
                        }
                        ForEach(groups, id: \.id) { group in
                            Section {
                                ForEach(group.issues) { issue in
                                    NavigationLink {
                                        MobileIssueEditor(chat: chat, games: board.games, issue: issue) { await load() }
                                    } label: { IssueRow(issue: issue) }
                                    .accessibilityIdentifier("issue-\(issue.number)")
                                }
                            } header: {
                                Label("\(group.title) · \(group.issues.count)", systemImage: group.id == "general" ? "tray" : "gamecontroller")
                            }
                        }
                    }
                    .refreshable { await load() }
                } else if let problem {
                    ContentUnavailableView("Couldn't load the board", systemImage: "exclamationmark.triangle", description: Text(problem))
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(board.map { "\($0.projectName) Issues" } ?? "Issues")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItemGroup(placement: .primaryAction) {
                    Menu {
                        if let games = board?.games, !games.isEmpty {
                            Picker("Game", selection: $game) {
                                Text("All games").tag("all")
                                Text("General").tag("general")
                                ForEach(games) { Text($0.title).tag($0.id) }
                            }
                        }
                        Toggle("Show Done", isOn: $showDone)
                    } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
                    .accessibilityLabel("Filter")
                    .accessibilityIdentifier("issue-filter")
                    Button { adding = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("New Issue")
                        .accessibilityIdentifier("issue-new")
                }
            }
            .sheet(isPresented: $adding) {
                NavigationStack {
                    MobileIssueEditor(chat: chat, games: board?.games ?? [], issue: nil, preset: game == "all" || game == "general" ? nil : game) { await load() }
                }
                .environment(store)
            }
            .task { await load() }
            .onReceive(NotificationCenter.default.publisher(for: .closeIssueBoard)) { _ in dismiss() }
        }
    }

    private func load() async {
        do { board = try await store.issueBoard(chat: chat); problem = nil }
        catch { problem = error.localizedDescription }
    }

    private struct IssueGroup { var id: String; var title: String; var issues: [Companion.ProjectIssue] }

    private func groups(_ board: Companion.IssueBoard) -> [IssueGroup] {
        let shown = board.issues.filter { showDone || $0.status != "done" }
        var result: [IssueGroup] = board.games.compactMap { g in
            let issues = shown.filter { $0.game == g.id }
            return issues.isEmpty ? nil : IssueGroup(id: g.id, title: g.title, issues: issues)
        }
        let general = shown.filter { issue in issue.game == nil || !board.games.contains { $0.id == issue.game } }
        if !general.isEmpty { result.append(IssueGroup(id: "general", title: "General", issues: general)) }
        return game == "all" ? result : result.filter { $0.id == game }
    }
}

private struct IssueRow: View {
    let issue: Companion.ProjectIssue
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: IssueWords.typeIcon(issue.type)).foregroundStyle(IssueWords.typeColor(issue.type)).frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(issue.title).font(.body).lineLimit(2)
                HStack(spacing: 6) {
                    Text("#\(issue.number)").monospacedDigit()
                    Text(IssueWords.status(issue.status)).foregroundStyle(IssueWords.statusColor(issue.status))
                    if issue.priority == "high" { Text("High").foregroundStyle(.orange).fontWeight(.semibold) }
                    if !issue.attachments.isEmpty { Label("\(issue.attachments.count)", systemImage: "paperclip").labelStyle(.titleAndIcon) }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if issue.needsYou == true { Circle().fill(Color.attention).frame(width: 9, height: 9).padding(.top, 6) }
        }
        .accessibilityElement(children: .combine)
    }
}

/// New Issue, or an issue's page.
struct MobileIssueEditor: View {
    @Environment(MobileStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let chat: UUID
    let games: [Companion.IssueGame]
    let issue: Companion.ProjectIssue?
    var preset: String? = nil
    let changed: () async -> Void

    @State private var title = ""
    @State private var notes = ""
    @State private var game = "general"
    @State private var type = "bug"
    @State private var priority = "normal"
    @State private var status = "open"
    @State private var picks: [PhotosPickerItem] = []
    @State private var photos: [Data] = []
    @State private var images: [String: UIImage] = [:]
    @State private var busy = false
    @State private var problem: String?
    @State private var confirmingDelete = false
    @State private var viewing: UIImage?

    var body: some View {
        Form {
            Section {
                TextField("Title", text: $title, axis: .vertical).font(.headline).accessibilityIdentifier("issue-title")
                if !games.isEmpty {
                    Picker("Game", selection: $game) {
                        Text("General").tag("general")
                        ForEach(games) { Text($0.title).tag($0.id) }
                    }
                }
                Picker("Type", selection: $type) { ForEach(["bug", "feature", "polish"], id: \.self) { Text(IssueWords.type($0)).tag($0) } }
                Picker("Priority", selection: $priority) { ForEach(["low", "normal", "high"], id: \.self) { Text(IssueWords.priority($0)).tag($0) } }
                if let issue, issue.chatID == nil {
                    Picker("Status", selection: $status) { ForEach(IssueWords.statuses, id: \.id) { Text($0.title).tag($0.id) } }
                }
            }
            Section("Notes") {
                TextField("What's wrong, or wanted", text: $notes, axis: .vertical).lineLimit(4...12)
            }
            Section("Attachments") {
                let kept = issue?.attachments ?? []
                if !kept.isEmpty || !photos.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(kept, id: \.path) { file in
                                Button { viewing = images[file.path] } label: {
                                    thumb(images[file.path], label: file.name)
                                }
                                .buttonStyle(.plain)
                                .task { if file.mediaType.hasPrefix("image/"), images[file.path] == nil { images[file.path] = try? await store.issueImage(file) } }
                            }
                            ForEach(photos.indices, id: \.self) { index in thumb(UIImage(data: photos[index]), label: "New photo").opacity(0.8) }
                        }
                    }
                }
                PhotosPicker(selection: $picks, maxSelectionCount: 6, matching: .images) { Label("Add Photos", systemImage: "photo.badge.plus") }
                    .onChange(of: picks) { _, items in Task { await loadPicks(items) } }
            }
            if let issue { threadSection(issue) }
            if let problem { Section { Text(problem).foregroundStyle(.orange) } }
            if issue != nil {
                Section { Button("Delete Issue", role: .destructive) { confirmingDelete = true } }
            }
        }
        .navigationTitle(issue.map { "Issue #\($0.number)" } ?? "New Issue")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if issue == nil { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            ToolbarItem(placement: .confirmationAction) {
                Button(issue == nil ? "File" : "Save") { Task { await save() } }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
                    .accessibilityIdentifier("issue-save")
            }
        }
        .confirmationDialog("Delete this issue?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { if await act(["action": "delete"]) { dismiss() } } }
        } message: { Text("Its attachments go too. Its thread, if any, carries on.") }
        .fullScreenCover(item: Binding(get: { viewing.map(IdentifiedImage.init) }, set: { viewing = $0?.image })) { shown in
            ImageViewer(image: shown.image, name: "Attachment")
        }
        .onAppear(perform: fill)
    }

    private struct IdentifiedImage: Identifiable { let image: UIImage; var id: ObjectIdentifier { ObjectIdentifier(image) } }

    private func thumb(_ image: UIImage?, label: String) -> some View {
        VStack(spacing: 4) {
            Group {
                if let image { Image(uiImage: image).resizable().scaledToFill() } else { Image(systemName: "doc").font(.title2) }
            }
            .frame(width: 84, height: 60).clipShape(RoundedRectangle(cornerRadius: 6))
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            Text(label).font(.caption2).lineLimit(1).frame(width: 84)
        }
    }

    @ViewBuilder private func threadSection(_ issue: Companion.ProjectIssue) -> some View {
        Section("Thread") {
            if let thread = issue.chatID {
                LabeledContent(issue.chatTitle ?? "Its thread", value: IssueWords.status(issue.status))
                Button { MobilePushNotifications.shared.pendingChat = thread; dismissAll() } label: {
                    Label("Open Thread", systemImage: "arrow.up.forward.square")
                }
                Button("Unlink") { Task { await act(["action": "unlink"]) } }
            } else {
                Button { Task { await start(issue) } } label: { Label("Start Thread", systemImage: "play.fill") }
                    .disabled(busy)
                    .accessibilityIdentifier("issue-start")
                Text("A work thread in this project on the Mac, given the issue and its attachments.").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    /// Opening a thread leaves the board: the chat list then opens it.
    private func dismissAll() { dismiss(); NotificationCenter.default.post(name: .closeIssueBoard, object: nil) }

    private func fill() {
        if let issue {
            title = issue.title; notes = issue.notes ?? ""; game = issue.game ?? "general"
            type = issue.type; priority = issue.priority; status = issue.status
        } else {
            game = preset ?? "general"
        }
    }

    private func loadPicks(_ items: [PhotosPickerItem]) async {
        var loaded: [Data] = []
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else { continue }
            // Screenshots stay sharp; large photos come down to a sensible size.
            loaded.append(image.jpegData(compressionQuality: 0.85) ?? data)
        }
        photos = loaded
    }

    private var uploads: [[String: String]] {
        photos.enumerated().map { ["name": "Photo \($0.offset + 1).jpg", "data": $0.element.base64EncodedString()] }
    }

    @discardableResult
    private func act(_ fields: [String: Any]) async -> Bool {
        busy = true
        defer { busy = false }
        var body = fields
        body["chatID"] = chat.uuidString
        if let issue { body["id"] = issue.id.uuidString }
        do { try await store.issueAction(body); problem = nil; await changed(); return true }
        catch { problem = error.localizedDescription; return false }
    }

    private func save() async {
        var fields: [String: Any] = ["title": title, "notes": notes, "type": type, "priority": priority]
        if let issue {
            fields["action"] = "update"
            fields["game"] = game == "general" ? "" : game
            if issue.chatID == nil { fields["status"] = status }
            guard await act(fields) else { return }
            if !photos.isEmpty, !(await act(["action": "attach", "uploads": uploads])) { return }
        } else {
            fields["action"] = "add"
            if game != "general" { fields["game"] = game }
            if !uploads.isEmpty { fields["uploads"] = uploads }
            guard await act(fields) else { return }
        }
        dismiss()
    }

    private func start(_ issue: Companion.ProjectIssue) async {
        busy = true
        defer { busy = false }
        do {
            let data = try await store.issueAction(["action": "start", "chatID": chat.uuidString, "id": issue.id.uuidString])
            let detail = try Companion.decoder.decode(Companion.ChatDetail.self, from: data)
            await changed()
            MobilePushNotifications.shared.pendingChat = detail.summary.id
            dismissAll()
        } catch { problem = error.localizedDescription }
    }
}

extension Notification.Name {
    /// Opening a thread from an issue closes the board sheet, so the chat can open.
    static let closeIssueBoard = Notification.Name("closeIssueBoard")
}
