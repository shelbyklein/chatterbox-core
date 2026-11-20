import Observation
import SwiftUI

// About this thread, on the phone (the Mac's thread sidebar): tapping a session's title drops it
// down from under the title, half the screen, dragged to full; on a wide layout (an iPad, an open
// iPhone Duo) it's a column on the right beside the conversation instead, opened from the About
// button on the session list's bar like a tab; a work thread or sidechat peeks in it too. The
// same sections as the Mac's, as compact rows, each hidden when it has nothing: Status, Where,
// Task & work, Outputs, Notes, Tools, Runs here. Actions that open a sheet of the session's
// (settings, the Brief, a sidequest, a work thread) go back to it as `MobileAboutAction`s.

/// What the About panel asks its session to do.
enum MobileAboutAction: Equatable {
    case settings, brief, sidequest, startWork, linkTask, makeTask, terminal
    case unlinkTask(UUID)
    case change(Companion.SettingsRequest)
    /// Scroll the transcript to a message (a file or draft it holds).
    case reveal(UUID)
    case open(Companion.ChatSummary)
    /// The session's own actions, from About's Actions menu (wide, where the chat has no ⋯).
    case refresh, stopReply, restart, togglePin, rename, moveToStudio, makeProject, fork, archive, unarchive

    static func == (a: Self, b: Self) -> Bool { String(describing: a) == String(describing: b) }
}

/// On a wide layout: whether the About column shows (on the right, beside the conversation),
/// what it peeks at, and what it last asked the open session to do.
@MainActor @Observable
final class MobileAboutColumn {
    static let openKey = "mobileAboutColumnOpen"
    /// Remembered: About stays open across sessions and launches, like a selected tab.
    var isOpen = UserDefaults.standard.bool(forKey: MobileAboutColumn.openKey) {
        didSet {
            UserDefaults.standard.set(isOpen, forKey: Self.openKey)
            if !isOpen { peek = nil }
            // Upright, one side panel at a time (Shelby, 2026-11-20): About in, the list out.
            if isOpen, listShelf, listShown { listShown = false }
        }
    }
    /// A work thread or sidechat of the open session, shown live in the column in About's place
    /// (the Mac's peek, PeekPanel.swift) until Back.
    var peek: Companion.ChatSummary?
    /// Wide and upright (an open Duo in portrait): the session list is a shelf that slides in
    /// over the conversation, which has the whole width. `listShown`: it's out now.
    var listShelf = false
    var listShown = false {
        // …and the list in, About out.
        didSet { if listShown, listShelf, isOpen { isOpen = false } }
    }
    /// The newest request, numbered so the same action twice still arrives.
    private(set) var request: (number: Int, action: MobileAboutAction)?
    func send(_ action: MobileAboutAction) { request = ((request?.number ?? 0) + 1, action) }
}

/// A front thread's running work threads, as a small pill under its title.
struct MobileWorkingPill: View {
    let count: Int
    var body: some View {
        if count > 0 {
            HStack(spacing: 3) {
                ProgressView().controlSize(.mini)
                Text("\(count) working")
            }
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill(Color.blue.opacity(0.18)))
            .foregroundStyle(.primary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(count) work threads working")
            .accessibilityIdentifier("workingPill")
        }
    }
}

/// What a session made or shared, newest first, from its recent transcript.
enum MobileAboutOutputs {
    enum Kind: Equatable { case image(Companion.File), pdf(Companion.File), file(Companion.File), link(URL), draft(String) }
    struct Output: Identifiable, Equatable {
        var id: String
        var kind: Kind
        /// The message it's in.
        var item: UUID
        var title: String
    }

    static func collect(_ items: [Companion.Item]) -> [Output] {
        var seen = Set<String>()
        var found: [Output] = []
        func add(_ output: Output) { if seen.insert(output.id).inserted { found.append(output) } }
        for item in items.reversed() {
            for file in item.attachments {
                let pdf = file.mediaType == "application/pdf" || (file.name as NSString).pathExtension.lowercased() == "pdf"
                add(.init(id: file.id.uuidString, kind: file.isImage ? .image(file) : pdf ? .pdf(file) : .file(file), item: item.id, title: file.name))
            }
            guard item.kind == .assistant, !item.isCommentary else { continue }
            for link in links(in: item.text) { add(.init(id: link.absoluteString, kind: .link(link), item: item.id, title: link.lastPathComponent.isEmpty || link.lastPathComponent == "/" ? (link.host ?? link.absoluteString) : link.lastPathComponent)) }
            for draft in drafts(in: item.text) {
                let first = draft.split(separator: "\n").first.map(String.init) ?? draft
                add(.init(id: "draft:" + draft, kind: .draft(draft), item: item.id, title: first))
            }
        }
        return found
    }

    /// Published snippet links.
    static func links(in text: String) -> [URL] {
        guard text.contains("snippets.shelbyklein.com") else { return [] }
        let pattern = #"https://snippets\.shelbyklein\.com[^\s)\]>"'`]*"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).flatMap { URL(string: String(text[$0]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:"))) }
        }
    }

    /// The text of each ```draft or ```email block.
    static func drafts(in text: String) -> [String] {
        guard text.contains("```") else { return [] }
        var result: [String] = [], current: [Substring]?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if current != nil {
                if trimmed == "```" { result.append(current!.joined(separator: "\n")); current = nil } else { current!.append(line) }
            } else if trimmed == "```draft" || trimmed == "```email" {
                current = []
            }
        }
        return result.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

/// The panel's sections, in order (and their test identifiers: "about-section-<key>").
private enum AboutSection: String {
    case status, place, work, outputs, notes, tools, runs
}

struct MobileAboutPanel: View {
    let summary: Companion.ChatSummary
    let detail: Companion.ChatDetail?
    let chats: [Companion.ChatSummary]
    let perform: (MobileAboutAction) -> Void
    /// Wide, About carries the session's actions (Refresh, Restart, Rename…): the chat's own ⋯
    /// toolbar would only fold into a floating pill there.
    var sessionActions = false
    @Environment(MobileStore.self) private var store
    @State private var browsing: String?
    @State private var viewing: ViewedImage?
    @State private var reviewingPDF: Companion.File?
    @State private var page: PageRequest?
    @State private var showingImages = false
    /// The project's issue board (MobileIssueBoard.swift).
    @State private var showingIssues = false
    @State private var editingInstructions: StudioInstructions?
    struct StudioInstructions: Identifiable { var id: UUID; var title: String; var text: String
        init(title: String, id: UUID, text: String) { self.title = title; self.id = id; self.text = text } }
    /// The Studio the session belongs to, from the list (its instructions are there).
    private var studioGroup: Companion.ChatGroup? {
        store.chatList?.groups.first { $0.kind == .studio && $0.studioID != nil && $0.chats.contains { $0.id == summary.id } }
    }

    private struct ViewedImage: Identifiable { let id = UUID(); var image: UIImage; var name: String }
    private var outputs: [MobileAboutOutputs.Output] { MobileAboutOutputs.collect(detail?.items ?? []) }
    private var images: [Companion.File] { outputs.compactMap { if case .image(let file) = $0.kind { file } else { nil } } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Shelby's order (2026-11-20): notes, what it made, actions, tools, where it works;
            // then its status and runs.
            header
            notes
            outputsSection
            work
            tools
            place
            status
            runs
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("aboutPanel")
        .fullScreenCover(item: $viewing) { shown in
            ImageViewer(image: shown.image, name: shown.name, onComment: { store.composer(for: summary.id).add($0) })
        }
        .fullScreenCover(item: $reviewingPDF) { file in MobilePDFViewer(file: file, chat: summary.id) }
        .sheet(item: $page) { SafariView(url: $0.url).ignoresSafeArea() }
        .sheet(isPresented: $showingIssues) { MobileIssueBoardView(chat: summary.id).environment(store) }
        .sheet(item: $editingInstructions) { StudioInstructionsEditor(title: $0.title, studio: $0.id, initial: $0.text).environment(store) }
        .sheet(isPresented: $showingImages) {
            MobileAboutImages(chat: summary.id, files: images) { file, image in showingImages = false; viewing = .init(image: image, name: file.name) }
        }
    }

    // MARK: - Header: places you go

    private var header: some View {
        HStack(spacing: 8) {
            if !images.isEmpty { headerButton("Images", "photo.on.rectangle", "about-images") { showingImages = true } }
            // A project's issue board (plans/project-issues.md).
            if summary.project != nil, detail?.isArchived != true {
                headerButton("Issues", "checklist", "about-issues") { showingIssues = true }
            }
            if detail?.folder != nil, detail?.isArchived != true {
                headerButton("Terminal", "terminal", "about-terminal") { perform(.terminal) }
            }
        }
    }

    private func headerButton(_ title: String, _ icon: String, _ id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.body)
                Text(title).font(.caption2)
            }
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityIdentifier(id)
    }

    // MARK: - Sections

    @ViewBuilder private var status: some View {
        card(.status, "Status") {
            let state = summary.isWaitingOnYou ? ("Needs you", "hand.raised.fill", Color.attention)
                : summary.isRunning ? ("Working", "circle.dotted", Color.blue) : ("Ready", "checkmark.circle", Color.green)
            row(icon: state.1, tint: state.2) { Text(state.0).fontWeight(.semibold) }
                .accessibilityIdentifier("about-state")
            if let options = detail?.options {
                VStack(alignment: .leading, spacing: 8) {
                    CompactModelPicker(options: options, browsing: $browsing) { perform(.change($0)) }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("about-model-row")
                Button { perform(.settings) } label: {
                    row(icon: "slider.horizontal.3") {
                        // Unrestricted access in the warning color, as Session Settings marks it.
                        Text(settingsLine(options)).lineLimit(2)
                            .foregroundStyle(options.modes.first { $0.id == options.mode }?.isUnrestricted == true ? Color.attention : Color.primary)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Session Settings: \(settingsLine(options))")
                .accessibilityIdentifier("about-settings")
            } else if let detail {
                row(icon: "cpu") { Text(detail.settings).foregroundStyle(Color.metadata) }
            }
            // Only a number the agent reported: no bar until then.
            if let fraction = detail?.contextFraction {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Context").font(.caption)
                        Spacer()
                        Text("\(Int((fraction * 100).rounded()))% used").font(.caption.monospacedDigit())
                    }
                    .foregroundStyle(Color.metadata)
                    ProgressView(value: min(1, max(0, fraction)))
                        .tint(fraction >= 0.9 ? .red : fraction >= 0.75 ? .orange : .accentColor)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Context \(Int((fraction * 100).rounded())) percent used")
                .accessibilityIdentifier("about-context")
            }
        }
    }

    private func settingsLine(_ options: Companion.ChatOptions) -> String {
        let models = options.models(for: options.backend)
        let model = models.first { $0.id == options.model }
        var parts: [String] = []
        if options.openModel == nil, let model, !model.efforts.isEmpty {
            let effort = options.effort.isEmpty ? model.defaultEffort ?? "" : options.effort
            if !effort.isEmpty { parts.append(ChatSettingsLabels.effort(effort) + " effort") }
        }
        if let mode = options.modes.first(where: { $0.id == options.mode }) { parts.append(mode.title) }
        return parts.isEmpty ? "Session Settings" : parts.joined(separator: " \u{00B7} ")
    }

    @ViewBuilder private var place: some View {
        let placeName = detail?.studio ?? summary.project
        if placeName != nil || detail?.folder != nil || detail?.branch != nil {
            card(.place, "Where") {
                if let placeName {
                    row(icon: detail?.studio != nil ? "paintpalette" : "star.square.fill") { Text(placeName) }
                }
                if let folder = detail?.folder {
                    row(icon: "folder") {
                        Text((folder as NSString).abbreviatingWithTildeInPath.replacingOccurrences(of: "/Users/", with: "~/", options: .anchored))
                            .font(.callout.monospaced()).foregroundStyle(Color.metadata).lineLimit(1).truncationMode(.middle)
                    }
                }
                if let branch = detail?.branch { row(icon: "arrow.triangle.branch") { Text(branch).font(.callout.monospaced()) } }
                row(icon: detail?.machine == nil ? "laptopcomputer" : "desktopcomputer") { Text(detail?.machine ?? "This Mac") }
                    .accessibilityIdentifier("about-machine")
            }
        }
    }

    private var carriedTask: Companion.DeskTask? {
        store.latestDesk?.linked?.first { $0.chatID == summary.id && $0.completedAt == nil }
    }
    private var taskColumn: MobileDeskColumn {
        if summary.isWaitingOnYou { return .needsYou }
        if summary.isRunning { return .working }
        return store.latestDesk?.ready?.contains { $0.id == summary.id } == true ? .ready : .working
    }
    private var canStartWork: Bool { !summary.isSidequest && summary.workOf == nil && detail?.isArchived != true }
    private var tasksKept: Bool { store.latestDesk?.linked != nil && !summary.isSidequest && detail?.isArchived != true }

    @ViewBuilder private var work: some View {
        let threads = detail?.work ?? []
        // Its task and work threads, then everything you can do with the session: the Desk,
        // starting work, and the session itself (what the ⋯ menu has).
        card(.work, "Actions") {
                if let task = carriedTask {
                    row(icon: "checklist") {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(task.text).lineLimit(2)
                            Text("On the Desk \u{00B7} \(taskColumn.title)").font(.caption).foregroundStyle(Color.metadata)
                        }
                    }
                    .accessibilityIdentifier("about-task")
                }
                if let front = summary.workOf {
                    let listed = chats.first { $0.id == front }
                    let title = listed?.title ?? detail?.workOfTitle ?? "its front thread"
                    Button {
                        perform(.open(listed ?? .init(id: front, title: title, project: nil, subtitle: nil, backend: summary.backend,
                                                      isRunning: false, isWaitingOnYou: false, updatedAt: Date())))
                    } label: {
                        row(icon: "arrow.uturn.backward") {
                            Text("Work for \u{201C}\(title)\u{201D}").lineLimit(1)
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("about-front")
                }
                ForEach(threads) { thread in
                    Button {
                        perform(.open(chats.first { $0.id == thread.id } ?? .init(id: thread.id, title: thread.title, project: nil, subtitle: nil,
                                                                                backend: thread.backend, isRunning: thread.state == "working",
                                                                                isWaitingOnYou: thread.state == "needsYou", updatedAt: thread.updatedAt,
                                                                                workOf: summary.id)))
                    } label: {
                        row(icon: thread.stateIcon, tint: thread.stateColor) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(thread.title).lineLimit(1)
                                Text(thread.state == "working" ? thread.status.map { "Working \u{00B7} \($0)" } ?? "Working" : thread.stateLabel)
                                    .font(.caption).foregroundStyle(Color.metadata).lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Work thread \(thread.title), \(thread.stateLabel)\(thread.status.map { ", \($0)" } ?? "")")
                    .accessibilityIdentifier("work-chip-\(thread.id.uuidString)")
                }
                // Two to a row, filling the width: a narrow column (an open Duo) never cuts one off.
                if tasksKept {
                    chipGroup("Desk") {
                        if let task = carriedTask {
                            actionChip("Unlink Task", "Unlink from Task", "link", "about-unlink-task") { perform(.unlinkTask(task.id)) }
                        } else {
                            // No task: its questions show in the Desk's Needs you only when on.
                            if let followed = store.latestDesk?.followed {
                                let on = followed.contains(summary.id)
                                actionChip(on ? "On Desk" : "Show on Desk", on ? "Shown on the Desk, on" : "Show on the Desk, off",
                                           on ? "checkmark.circle.fill" : "rectangle.stack", "about-show-on-desk", active: on) {
                                    Task { try? await store.followDesk(summary.id, !on) }
                                }
                            }
                            actionChip("Make Task", "Make This a Task", "checklist", "about-make-task") { perform(.makeTask) }
                            if !(store.latestDesk?.incoming ?? []).isEmpty {
                                actionChip("Link Task", "Link to a Task", "link.badge.plus", "about-link-task") { perform(.linkTask) }
                            }
                        }
                    }
                }
                if canStartWork || (!summary.isSidequest && detail?.isArchived != true) || detail?.canFork == true {
                    chipGroup("Start") {
                        if canStartWork { actionChip("Work Thread", "Start a Work Thread", "arrow.triangle.branch", "about-start-work") { perform(.startWork) } }
                        if !summary.isSidequest, detail?.isArchived != true {
                            actionChip("Sidequest", "Sidequest to \(summary.otherAgentLabel)", "point.topleft.down.to.point.bottomright.curvepath", "about-sidequest") { perform(.sidequest) }
                        }
                        if detail?.canFork == true {
                            actionChip("Fork", "Fork", "arrow.triangle.branch", "about-fork") { perform(.fork) }
                        }
                    }
                }
                chipGroup("Session") {
                    actionChip("Rename", "Rename", "pencil", "about-rename") { perform(.rename) }
                    actionChip("Refresh", "Refresh Session", "arrow.clockwise", "about-refresh") { perform(.refresh) }
                    if summary.isRunning {
                        actionChip("Stop Reply", "Stop Reply", "stop.circle", "about-stop") { perform(.stopReply) }
                    }
                    if detail != nil {
                        actionChip("Restart", "Restart Thread", "arrow.triangle.2.circlepath", "about-restart") { perform(.restart) }
                    }
                    if summary.worktreeBranch == nil, summary.sidechatOf == nil {
                        actionChip(summary.pinnedRank == nil ? "Pin" : "Unpin", summary.pinnedRank == nil ? "Pin to Top" : "Unpin",
                                   summary.pinnedRank == nil ? "pin" : "pin.slash", "about-pin") { perform(.togglePin) }
                    }
                    if summary.canPromote == true, detail?.isArchived != true, !summary.isRunning {
                        actionChip("To Studio", "Move to Studio", "paintpalette", "about-move-studio") { perform(.moveToStudio) }
                        actionChip("Make Project", "Make Project", "folder.badge.plus", "about-make-project") { perform(.makeProject) }
                    }
                    if detail?.isArchived == true {
                        actionChip("Unarchive", "Unarchive", "tray.and.arrow.up", "about-unarchive") { perform(.unarchive) }
                    } else {
                        actionChip("Archive", "Archive", "archivebox", "about-archive") { perform(.archive) }
                    }
                }
            }
    }

    /// A small heading over two-to-a-row action chips.
    private func chipGroup<Chips: View>(_ title: String, @ViewBuilder _ chips: () -> Chips) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(Color.metadata)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], alignment: .leading, spacing: 8) {
                chips()
            }
        }
        .padding(.top, 2)
    }

    /// A short label that fits half a narrow column; the full name for VoiceOver.
    private func actionChip(_ title: String, _ full: String, _ icon: String, _ id: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(.caption.weight(.medium)).lineLimit(1).minimumScaleFactor(0.8)
                .foregroundStyle(active ? Color.white : Color.primary)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 8).padding(.vertical, 8)
                .background(Capsule().fill(active ? Color.accentColor : Color(uiColor: .tertiarySystemFill)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(full)
        .accessibilityIdentifier(id)
    }

    @ViewBuilder private var outputsSection: some View {
        let all = outputs
        if !all.isEmpty {
            card(.outputs, "Outputs") {
                if !images.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(images.prefix(12)) { file in
                                MobileAboutThumbnail(chat: summary.id, file: file) { image in viewing = .init(image: image, name: file.name) }
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                }
                ForEach(all.filter { if case .image = $0.kind { false } else { true } }.prefix(8)) { output in
                    Button { openOutput(output) } label: {
                        row(icon: icon(output.kind)) {
                            Text(output.title).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 4)
                            Text(kindLabel(output.kind)).font(.caption).foregroundStyle(Color.metadata)
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        switch output.kind {
                        case .draft(let text): Button { UIPasteboard.general.string = text } label: { Label("Copy Draft", systemImage: "doc.on.doc") }
                        case .link(let url): Button { UIPasteboard.general.url = url } label: { Label("Copy Link", systemImage: "link") }
                        default: EmptyView()
                        }
                        Button { perform(.reveal(output.item)) } label: { Label("Show in Session", systemImage: "text.bubble") }
                    }
                    .accessibilityIdentifier("about-output-\(kindLabel(output.kind).lowercased())")
                }
            }
        }
    }

    private func openOutput(_ output: MobileAboutOutputs.Output) {
        switch output.kind {
        case .pdf(let file): reviewingPDF = file
        case .link(let url): page = PageRequest(url: url)
        case .image, .file, .draft: perform(.reveal(output.item))
        }
    }
    private func icon(_ kind: MobileAboutOutputs.Kind) -> String {
        switch kind {
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .file: "doc"
        case .link: "link"
        case .draft: "envelope"
        }
    }
    private func kindLabel(_ kind: MobileAboutOutputs.Kind) -> String {
        switch kind {
        case .image: "Image"
        case .pdf: "PDF"
        case .file: "File"
        case .link: "Link"
        case .draft: "Draft"
        }
    }

    @ViewBuilder private var notes: some View {
        let brief = (summary.brief ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let pins = summary.pins ?? []
        card(.notes, "Notes") {
            // Just the note (Shelby, 2026-11-20): no label, no description.
            Button { perform(.brief) } label: {
                row(icon: brief.isEmpty ? "square.and.pencil" : "note.text") {
                    Text(brief.isEmpty ? "Add a note" : brief)
                        .lineLimit(3).foregroundStyle(brief.isEmpty ? Color.metadata : Color.primary)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(brief.isEmpty ? "Note, not set" : "Note: \(brief)")
            .accessibilityIdentifier("about-brief")
            // The instructions the session follows: its Studio's, readable and editable here.
            if let studio = studioGroup, let id = studio.studioID {
                Button { editingInstructions = .init(title: studio.title, id: id, text: studio.instructions ?? "") } label: {
                    row(icon: "text.book.closed") {
                        Text("\(studio.title) instructions").lineLimit(1)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("about-studio-instructions")
            }
            if !pins.isEmpty { MobilePinPills(pins: pins) }
        }
    }

    @ViewBuilder private var tools: some View {
        if let chips = detail?.tools, !chips.isEmpty {
            card(.tools, "Tools") {
                AboutFlow(spacing: 6) {
                    ForEach(chips) { chip in
                        Text(chip.name)
                            .font(.caption.weight(.medium))
                            .strikethrough(!chip.isOn)
                            .foregroundStyle(chip.isOn ? Color.primary : Color.metadata)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Capsule().fill(chip.isOn ? Color.accentColor.opacity(0.16) : Color(uiColor: .tertiarySystemFill)))
                            .accessibilityLabel("\(chip.name), \(chip.kind == "server" ? "MCP server" : chip.kind), \(chip.isOn ? "on" : "off")")
                    }
                }
                Text("Change them on the Mac, in Settings \u{203A} Tools.").font(.caption2).foregroundStyle(Color.metadata)
            }
        }
    }

    @ViewBuilder private var runs: some View {
        let sidechats = chats.filter { $0.sidechatOf == summary.id && $0.sidequestOf == nil && $0.workOf == nil }
        let quests = MobileSidequests.of(summary.id, in: chats)
        if !sidechats.isEmpty || !quests.isEmpty {
            card(.runs, "Runs here") {
                ForEach(quests) { quest in MobileSidequestRow(quest: quest) { perform(.open(quest)) } }
                ForEach(sidechats) { chat in
                    Button { perform(.open(chat)) } label: {
                        row(icon: "bubble.left.and.bubble.right") {
                            Text(chat.title).lineLimit(1)
                            Spacer(minLength: 4)
                            if chat.isRunning { ProgressView().controlSize(.mini) }
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Pieces

    private func card<Content: View>(_ section: AboutSection, _ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(Color.metadata)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 10) { content() }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("about-section-\(section.rawValue)")
    }

    private func row<Content: View>(icon: String, tint: Color = Color.metadata, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint).frame(width: 20)
            content()
        }
        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// An image the session made, small; a tap shows it full size.
private struct MobileAboutThumbnail: View {
    let chat: UUID
    let file: Companion.File
    var size: CGFloat = 64
    let view: (UIImage) -> Void
    @Environment(MobileStore.self) private var store
    @State private var image: UIImage?

    var body: some View {
        Button {
            Task { if let full = (try? await store.image(file, in: chat, maxPixels: nil)) ?? image { view(full) } }
        } label: {
            Group {
                if let image { Image(uiImage: image).resizable().scaledToFill() }
                else { Color(uiColor: .tertiarySystemFill).overlay(ProgressView().controlSize(.small)) }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(file.name)
        .accessibilityIdentifier("about-thumbnail")
        .task(id: file.id) { image = try? await store.image(file, in: chat, maxPixels: Int(size * 3)) }
    }
}

/// The header's Images: every image in the session's recent messages, as a grid.
private struct MobileAboutImages: View {
    let chat: UUID
    let files: [Companion.File]
    let view: (Companion.File, UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 8) {
                    ForEach(files) { file in
                        MobileAboutThumbnail(chat: chat, file: file, size: 104) { view(file, $0) }
                    }
                }
                .padding(16)
            }
            .navigationTitle("Images").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

/// Chips that wrap onto as many lines as they need.
private struct AboutFlow: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: rows.last.map { $0.y + $0.height } ?? 0)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }
    private struct Row { var indices: [Int] = []; var y: CGFloat; var width: CGFloat = 0; var height: CGFloat = 0 }
    private func arrange(width: CGFloat, _ subviews: Subviews) -> [Row] {
        var rows = [Row(y: 0)]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                let last = rows[rows.count - 1]
                rows.append(Row(y: last.y + last.height + spacing))
            }
            let gap = rows[rows.count - 1].indices.isEmpty ? 0 : spacing
            rows[rows.count - 1].indices.append(index)
            rows[rows.count - 1].width += gap + size.width
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows
    }
}

/// The drop-down: the About panel under the session's title, half the screen; drag its handle
/// down for the whole screen, up (or tap outside) to close.
struct MobileAboutDropDown<Content: View>: View {
    @Binding var isPresented: Bool
    @ViewBuilder var content: () -> Content
    @GestureState private var drag: CGFloat = 0

    // A drawer from the right edge, the whole height (Shelby, 2026-11-20: it dropped from the
    // top). Tap the dimmed chat or drag its left edge to the right to close it.
    var body: some View {
        GeometryReader { geometry in
            let width = min(geometry.size.width * 0.88, 420)
            ZStack(alignment: .trailing) {
                Color.black.opacity(0.28).ignoresSafeArea()
                    .onTapGesture { close() }
                    .accessibilityLabel("Close About")
                    .accessibilityAddTraits(.isButton)
                ScrollView { content() }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(width: width)
                    .frame(maxHeight: .infinity)
                    .background(Color(uiColor: .systemGroupedBackground))
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 18))
                    // The left edge: drag it right to close (a swipe across the list scrolls it).
                    .overlay(alignment: .leading) {
                        Color.clear
                            .frame(width: 22)
                            .contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance: 8)
                                .updating($drag) { value, state, _ in state = max(0, value.translation.width) }
                                .onEnded { value in
                                    if value.predictedEndTranslation.width > width * 0.35 { close() }
                                })
                            .accessibilityElement()
                            .accessibilityLabel("Close About")
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { close() }
                            .accessibilityIdentifier("about-handle")
                    }
                    .shadow(color: .black.opacity(0.25), radius: 12, x: -4)
                    .offset(x: drag)
                    .animation(.snappy(duration: 0.2), value: drag)
                    .transition(.move(edge: .trailing))
            }
        }
    }

    private func close() { withAnimation(.snappy(duration: 0.25)) { isPresented = false } }
}
