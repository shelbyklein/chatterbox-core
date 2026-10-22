import SwiftUI

/// The tone button in the toolbar: the current tone's name, with the three to pick from.
struct ToneMenu: View {
    let session: ChatSession
    /// Just the tone's icon, for the session's button column.
    var iconOnly = false

    var body: some View {
        let current = session.record.personality
        Menu {
            Picker("Tone", selection: Binding(get: { current }, set: session.setPersonality)) {
                ForEach(Personality.allCases) { tone in
                    Label(tone.label, systemImage: Self.icon(tone)).tag(tone)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            if iconOnly { Image(systemName: Self.icon(current)) } else { ToolbarLabel(current.label, systemImage: Self.icon(current)) }
        }
        .modifier(SideIcon.MenuStyle(enabled: iconOnly))
        .help("Tone: \(current.label). Changes apply from your next message.")
    }

    static func icon(_ tone: Personality) -> String {
        switch tone {
        case .friendly: "face.smiling"
        case .pragmatic: "wrench.and.screwdriver"
        case .neutral: "circle.dashed"
        }
    }
}


/// User notes live separately from agent transcripts and message drafts.
struct PinnedNote: Codable, Identifiable, Equatable {
    var id = UUID()
    var text: String
    var createdAt = Date()
}

@MainActor @Observable final class PinnedNotesStore {
    static let shared = PinnedNotesStore()
    private let defaults: UserDefaults
    private(set) var notes: [String: [PinnedNote]]
    private(set) var drafts: [String: String]
    init(defaults: UserDefaults = AppPreferences.defaults) {
        self.defaults = defaults
        notes = defaults.data(forKey: "macPinnedNotes").flatMap { try? JSONDecoder().decode([String: [PinnedNote]].self, from: $0) } ?? [:]
        drafts = defaults.dictionary(forKey: "macPinnedNoteDrafts") as? [String: String] ?? [:]
    }
    static func scope(for record: ConversationRecord) -> String {
        if let folder = record.worktreeOf ?? record.sidechatProjectFolder ?? record.projectFolder {
            return "project:" + AppModel.normalize(folder)
        }
        return "chat:" + record.id.uuidString
    }
    func setDraft(_ text: String, for scope: String) {
        drafts[scope] = text.isEmpty ? nil : text
        defaults.set(drafts, forKey: "macPinnedNoteDrafts")
    }
    @discardableResult func add(for scope: String) -> Bool {
        let text = (drafts[scope] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        notes[scope, default: []].insert(PinnedNote(text: text), at: 0)
        save(); setDraft("", for: scope)
        return true
    }
    func remove(_ id: UUID, for scope: String) {
        notes[scope]?.removeAll { $0.id == id }; save()
    }
    private func save() {
        if let data = try? JSONEncoder().encode(notes) { defaults.set(data, forKey: "macPinnedNotes") }
    }
}

struct ChatNotes: View {
    let scope: String
    let project: Bool
    var panelWidth: CGFloat = 280
    @State private var store = PinnedNotesStore.shared
    @Environment(\.colorScheme) private var scheme
    /// The box for a new note opens and closes as needed; the notes themselves always show.
    @AppStorage("notesComposerOpen") private var composing = true
    private var entries: [PinnedNote] { store.notes[scope] ?? [] }
    private var hasDraft: Bool { !(store.drafts[scope] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(project ? "Project notes" : "Session notes", systemImage: "note.text").font(.headline)
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { composing.toggle() }
                } label: {
                    Image(systemName: composing ? "chevron.up" : "square.and.pencil")
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(hasDraft && !composing ? Color.accentColor : Color.secondary)
                .help(composing ? "Hide the note box" : hasDraft ? "Show the note box (it has an unsaved note)" : "Write a note")
                .accessibilityLabel(composing ? "Hide the note box" : "Write a note")
            }
            if composing { composer }
            notesList
        }
        .padding(14)
        .frame(width: panelWidth, alignment: .leading)
        .background(scheme == .dark ? Color(white: 0.10) : Color(white: 0.97), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.12)))
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var composer: some View {
        TextEditor(text: Binding(get: { store.drafts[scope] ?? "" }, set: { store.setDraft($0, for: scope) }))
            .font(.body).scrollContentBackground(.hidden)
            .padding(6).frame(height: 90)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            .accessibilityLabel("Write a note")
        HStack {
            Text("Notes are saved on this Mac.").font(.caption2).foregroundStyle(.secondary)
            Spacer()
            Button("Add Note") { store.add(for: scope) }
                .disabled(!hasDraft)
        }
    }

    @ViewBuilder private var notesList: some View {
        if entries.isEmpty { Text("No notes yet").font(.caption).foregroundStyle(.secondary) }
        else {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(entries) { note in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(note.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            HStack {
                                Text(note.createdAt, format: .dateTime.month(.abbreviated).day()).font(.caption2).foregroundStyle(.secondary)
                                Spacer()
                                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(note.text, forType: .string) } label: { Image(systemName: "doc.on.doc") }.help("Copy note")
                                Button { store.remove(note.id, for: scope) } label: { Image(systemName: "trash") }.help("Delete note")
                            }.buttonStyle(.borderless)
                        }.padding(10).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                    }
                }
            }.frame(maxHeight: 300)
        }
    }
}

/// A saved prompt the ⚡️ list sends to a chat in one click.
struct QuickPrompt: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var prompt: String
}

/// The prompt presets, kept in this Mac's preferences; /dev-sync to start with.
@MainActor
@Observable
final class QuickPrompts {
    static let shared = QuickPrompts()
    private let key = "macQuickPrompts"
    var prompts: [QuickPrompt] { didSet { save() } }
    private init() {
        if let data = AppPreferences.defaults.data(forKey: key), let saved = try? JSONDecoder().decode([QuickPrompt].self, from: data) {
            prompts = saved
        } else {
            prompts = [QuickPrompt(title: "Sync branches to main", prompt: "/dev-sync")]
        }
    }
    private func save() {
        if let data = try? JSONEncoder().encode(prompts) { AppPreferences.defaults.set(data, forKey: key) }
    }
}

/// Beside the notes: a list of prompt presets. Pick one to send it to this chat, exactly as
/// if typed; edit the list in place. Disabled while a reply runs.
struct ChatQuickActions: View {
    let session: ChatSession
    @Environment(\.colorScheme) private var scheme
    @State private var open = false
    var body: some View {
        Button { open.toggle() } label: { Image(systemName: "bolt").frame(width: 36, height: 32).contentShape(Rectangle()) }
            .buttonStyle(.plain)
            .disabled(session.isRunning)
            .background(scheme == .dark ? Color(white: 0.10) : Color(white: 0.97), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.12)))
            .help(session.isRunning ? "Prompt presets are available once the reply finishes" : "Prompt presets")
            .accessibilityLabel("Prompt presets")
            .popover(isPresented: $open, arrowEdge: .bottom) {
                QuickPromptList { prompt in open = false; session.send(prompt.prompt) }
            }
    }
}

struct QuickPromptList: View {
    let send: (QuickPrompt) -> Void
    @State private var store = QuickPrompts.shared
    @State var editing = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Prompt presets").font(.headline)
                Spacer()
                Button(editing ? "Done" : "Edit") { editing.toggle(); if !editing { store.prompts.removeAll { $0.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } } }
            }
            if store.prompts.isEmpty && !editing {
                Text("No presets yet. Click Edit to add one.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach($store.prompts) { $prompt in
                if editing {
                    HStack(alignment: .top, spacing: 8) {
                        VStack(spacing: 4) {
                            TextField("Name", text: $prompt.title).textFieldStyle(.roundedBorder)
                            TextField("Prompt, e.g. /dev-sync", text: $prompt.prompt, axis: .vertical)
                                .textFieldStyle(.roundedBorder).lineLimit(1...4)
                        }
                        Button { store.prompts.removeAll { $0.id == prompt.id } } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).help("Delete preset")
                    }
                } else {
                    Button { send(prompt) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(prompt.title.isEmpty ? prompt.prompt : prompt.title).font(.body.weight(.medium))
                            if !prompt.title.isEmpty {
                                Text(prompt.prompt).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Send \u{201C}\(prompt.prompt)\u{201D} to this session")
                }
            }
            if editing {
                Button("Add Preset", systemImage: "plus") { store.prompts.append(QuickPrompt(title: "", prompt: "")) }
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}

/// The activity menu's icon: a twelve-pointed star with an exclamation point, drawn as a
/// line icon like the toolbar's SF Symbols (there's no twelve-point star among them).
struct AttentionStar: View {
    var body: some View {
        ZStack {
            StarShape(points: 12, innerRatio: 0.8)
                .stroke(.primary, style: StrokeStyle(lineWidth: 1.4, lineJoin: .round))
            Text("!").font(.system(size: 10, weight: .bold, design: .rounded)).offset(y: -0.5)
        }
        .accessibilityHidden(true)
    }
}

struct StarShape: Shape {
    var points: Int
    /// The inner corners' distance from the center, as a share of the outer ones'.
    var innerRatio: CGFloat
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2, inner = outer * innerRatio
        var path = Path()
        for i in 0..<(points * 2) {
            let angle = CGFloat(i) * .pi / CGFloat(points) - .pi / 2
            let radius = i.isMultiple(of: 2) ? outer : inner
            let point = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}

struct FinishedChatsBell: View {
    @Environment(AppModel.self) private var model
    @State private var open = false
    private var chats: [ChatSession] { Attention.shared.finishedChats(in: model) }
    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 4) {
                AttentionStar().frame(width: 17, height: 17)
                if !chats.isEmpty { Text("\(chats.count)").font(.caption.weight(.semibold).monospacedDigit()) }
            }
            // It's the last item in its toolbar pill: give it room before the pill's edge.
            .padding(.leading, 4).padding(.trailing, 12)
        }
        .buttonStyle(.plain)
        .help("\(chats.count) unseen finished sessions · \(Attention.shared.workingChats(in: model).count) working")
        .accessibilityLabel("Session activity, \(chats.count) unseen")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            FinishedChatsList { open = false }.environment(model)
        }
    }
}

struct FinishedChatsList: View {
    @Environment(AppModel.self) private var model
    var close: () -> Void = {}
    private let appearance = ReaderStyleSettings()
    private var chats: [ChatSession] { Attention.shared.finishedChats(in: model) }
    private var working: [ChatSession] { Attention.shared.workingChats(in: model) }
    private var recent: [ChatSession] { Attention.shared.recentChats(in: model) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Session activity").font(.headline)
            Text("Finished replies, sessions working now, and the last 12 hours").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Finished · \(chats.count)").font(.subheadline.weight(.semibold))
                    if chats.isEmpty {
                        Label("You're caught up", systemImage: "checkmark.circle")
                            .font(.caption).foregroundStyle(.secondary).padding(.vertical, 8)
                    } else {
                        ForEach(chats) { session in activityRow(session, running: false) }
                    }
                    Divider().padding(.vertical, 6)
                    Text("Working · \(working.count)").font(.subheadline.weight(.semibold))
                    if working.isEmpty {
                        Text("No sessions are working right now").font(.caption).foregroundStyle(.secondary).padding(.vertical, 8)
                    } else {
                        ForEach(working) { session in activityRow(session, running: true) }
                    }
                    Divider().padding(.vertical, 6)
                    Text("Last 12 hours · \(recent.count)").font(.subheadline.weight(.semibold))
                    if recent.isEmpty {
                        Text("Nothing else in the last 12 hours").font(.caption).foregroundStyle(.secondary).padding(.vertical, 8)
                    } else {
                        ForEach(recent) { session in recentRow(session) }
                    }
                }
            }.frame(maxHeight: 520)
        }.padding(16).frame(width: 330)
    }
    /// One line per chat: the provider, its name, and how long ago it was last active.
    private func recentRow(_ session: ChatSession) -> some View {
        Button {
            if Attention.shared.openRecentChat(session.id, in: model) { close() }
        } label: {
            HStack(spacing: 10) {
                Image(session.record.provider.iconName).resizable().scaledToFit()
                    .frame(width: 14, height: 14)
                    .foregroundStyle(appearance.style.color(for: session))
                Text(session.record.projectFolder != nil ? session.projectName : session.title)
                    .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                Text(ShortAge.string(since: session.lastActivity))
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }.padding(.horizontal, 10).padding(.vertical, 6).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(session.listSummary?.reply ?? session.items.last(where: { $0.kind == .assistant && $0.phase == .final })?.text.prefix(200).description ?? "")
    }

    private func activityRow(_ session: ChatSession, running: Bool) -> some View {
        Button {
            let opened = running ? Attention.shared.openWorkingChat(session.id, in: model)
                                 : Attention.shared.openFinishedChat(session.id, in: model)
            if opened { close() }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                if running {
                    ActivitySpinner(color: appearance.style.color(for: session))
                        .frame(width: 16, height: 16)
                } else {
                    Image(session.record.provider.iconName).resizable().scaledToFit()
                        .frame(width: 16, height: 16)
                        .foregroundStyle(appearance.style.color(for: session))
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(session.record.projectFolder != nil ? session.projectName : session.title)
                        .font(.body.weight(.semibold)).lineLimit(1)
                    if running {
                        Text("\(session.record.provider.label) is working").font(.caption).foregroundStyle(.secondary)
                        if let started = session.record.turnStartedAt {
                            Text(started, style: .timer).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    } else {
                        Text(session.listSummary?.reply ?? session.items.last(where: { $0.kind == .assistant && $0.phase == .final })?.text ?? "Reply finished")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        Text(session.record.updatedAt, style: .relative).font(.caption2).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }.padding(10).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

/// Unseen replies and currently running sessions share one compact sidebar footer.
struct SidebarActivityStrip: View {
    var showsEmptyState = false
    @Environment(AppModel.self) private var model
    @AppStorage("sidebarActivityExpanded") private var expanded = true
    private let appearance = ReaderStyleSettings()
    private var finished: [ChatSession] { Attention.shared.finishedChats(in: model) }
    private var working: [ChatSession] { Attention.shared.workingChats(in: model) }

    var body: some View {
        let replies = finished
        let running = working
        let count = replies.count + running.count
        if showsEmptyState || count > 0 {
            VStack(alignment: .leading, spacing: 3) {
                Button { withAnimation(.smooth(duration: 0.2)) { expanded.toggle() } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right").font(.caption2)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                        Text("Activity").font(.caption.weight(.semibold))
                        Spacer()
                        if !replies.isEmpty {
                            Text("\(replies.count) new").foregroundStyle(.blue)
                        }
                        if !running.isEmpty { Text("\(running.count) working") }
                    }.font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Activity, \(replies.count) new replies, \(running.count) working")
                if expanded {
                    if count == 0 {
                        Text("All caught up").font(.caption).foregroundStyle(.secondary)
                            .padding(.leading, 18).padding(.vertical, 4)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 0) {
                                if !replies.isEmpty {
                                    heading("New replies")
                                    ForEach(replies) { row($0, running: false) }
                                }
                                if !running.isEmpty {
                                    heading("Working")
                                    ForEach(running) { row($0, running: true) }
                                }
                            }
                        }.frame(height: min(160, CGFloat(count) * 24 + CGFloat((replies.isEmpty ? 0 : 1) + (running.isEmpty ? 0 : 1)) * 20))
                    }
                }
                // Below: the strip sits at the top, above the sessions.
                Divider().padding(.top, 4)
            }
        }
    }

    private func heading(_ title: String) -> some View {
        Text(title).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
            .padding(.top, 4).padding(.bottom, 2)
    }

    private func activityHelp(_ session: ChatSession, running: Bool) -> String {
        let source = session.record.sidequestOf.flatMap { id in model.sessions.first { $0.id == id } }
        let title = source.map { "\($0.record.projectFolder != nil ? $0.projectName : $0.title) · \(session.title)" } ?? session.title
        return "\(title) · \(running ? session.record.provider.label + " is working" : "New reply")"
    }

    private func row(_ session: ChatSession, running: Bool) -> some View {
        Button {
            if running { Attention.shared.openWorkingChat(session.id, in: model) }
            else { Attention.shared.openFinishedChat(session.id, in: model) }
        } label: {
            HStack(spacing: 7) {
                if running {
                    ActivitySpinner(color: appearance.style.color(for: session))
                        .frame(width: 11, height: 11)
                } else {
                    Circle().fill(.blue).frame(width: 6, height: 6).frame(width: 11, height: 11)
                }
                if session.isSidequest {
                    if let parent = session.record.sidequestOf.flatMap({ id in model.sessions.first { $0.id == id } }) {
                        Text(parent.record.projectFolder != nil ? parent.projectName : parent.title)
                            .font(.caption).lineLimit(1).layoutPriority(1)
                    }
                    Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityLabel("Sidequest")
                    Text(session.title.hasPrefix("Sidequest · ") ? String(session.title.dropFirst("Sidequest · ".count)) : session.title)
                        .font(.caption).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(session.record.projectFolder != nil ? session.projectName : session.title)
                        .font(.caption).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(.vertical, 4).padding(.horizontal, 2).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open \(running ? "working session" : "new reply") \(session.title)")
        .help(activityHelp(session, running: running))
    }
}

/// At the top of the sidebar: replies that finished while you were elsewhere, newest first,
/// until you open them. The same list as the bell's; hidden when you're caught up.
struct UnseenRepliesStrip: View {
    var showsEmptyState = false
    @Environment(AppModel.self) private var model
    @AppStorage("sidebarUnseenRepliesExpanded") private var expanded = true
    private let appearance = ReaderStyleSettings()
    private var chats: [ChatSession] { Attention.shared.finishedChats(in: model) }
    var body: some View {
        if showsEmptyState || !chats.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Button { withAnimation(.smooth(duration: 0.2)) { expanded.toggle() } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                        Text("New replies").font(.subheadline.weight(.semibold))
                        Text("\(chats.count)").font(.caption.weight(.semibold).monospacedDigit())
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Color.blue.opacity(0.85))).foregroundStyle(.white)
                        Spacer()
                    }.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("New replies, \(chats.count)")
                if expanded {
                    VStack(spacing: 2) {
                        if chats.isEmpty {
                            Text("No new replies").font(.caption).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 18)
                        }
                        ForEach(chats.prefix(6)) { row($0) }
                        if chats.count > 6 {
                            Text("\(chats.count - 6) more in Activity").font(.caption).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 26)
                        }
                    }
                }
            }
        }
    }
    private func row(_ session: ChatSession) -> some View {
        Button { Attention.shared.openFinishedChat(session.id, in: model) } label: {
            HStack(spacing: 8) {
                Circle().fill(.blue).frame(width: 6, height: 6)
                Image(session.record.provider.iconName).resizable().scaledToFit()
                    .frame(width: 12, height: 12)
                    .foregroundStyle(appearance.style.color(for: session))
                Text(session.record.projectFolder != nil ? session.projectName : session.title)
                    .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                Text(ShortAge.string(since: session.record.updatedAt))
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4).padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(session.listSummary?.reply ?? session.items.last(where: { $0.kind == .assistant && $0.phase == .final })?.text.prefix(200).description ?? "Reply finished")
    }
}
