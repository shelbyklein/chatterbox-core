import AppKit
import SwiftUI

// About this thread: one readable column down the right of a chat (it replaced the column of
// icon buttons). Places you go are buttons along its top (Files, Terminal, Images); below,
// sections in a fixed order, each a line until you open it, the empty ones left out: Status,
// Where, Task & work, Outputs, Notes, Tools, Runs here. Docked on wide windows, toggled from
// the toolbar (⌥⌘0) and remembered; a slide-over when the window is narrow.

/// What the sidebar asks its chat to do: the chat owns the sheets, the terminal and the transcript.
struct ThreadSidebarActions {
    var showLibrary: () -> Void = {}
    var toggleTerminal: () -> Void = {}
    var openImage: (URL) -> Void = { _ in }
    var jumpToPin: (UUID) -> Void = { _ in }
    var openAutomations: () -> Void = {}
    var close: () -> Void = {}
}

/// The sidebar's sections, in order.
enum ThreadSidebarSection: String, CaseIterable, Identifiable {
    case status, place, work, outputs, notes, tools, runs
    var id: String { rawValue }
    var title: String {
        switch self {
        case .status: "Status"
        case .place: "Where"
        case .work: "Task & work"
        case .outputs: "Outputs"
        case .notes: "Notes"
        case .tools: "Tools"
        case .runs: "Runs here"
        }
    }
    var icon: String {
        switch self {
        case .status: "waveform.path.ecg"
        case .place: "mappin.and.ellipse"
        case .work: "checklist"
        case .outputs: "photo.on.rectangle.angled"
        case .notes: "note.text"
        case .tools: "puzzlepiece.extension"
        case .runs: "clock.arrow.circlepath"
        }
    }
    /// Open until you close them: what's happening, what it's doing, what it made.
    static let openByDefault = "status,work,outputs"
}

struct ThreadSidebar: View {
    let session: ChatSession
    let bridge: ChatToolbarBridge
    /// "Opus 5.5 · Medium": the chip under the message box says the same.
    var modelSummary: String
    var actions = ThreadSidebarActions()
    /// A slide-over (narrow window) has a close button instead of the toolbar's toggle.
    var overlay = false
    static let width: CGFloat = 288

    @Environment(AppModel.self) private var model
    @AppStorage("threadSidebarSections") private var openSections = ThreadSidebarSection.openByDefault
    @State private var outputs: [ThreadOutput] = []
    @State private var automations: [ProjectAutomation] = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(visibleSections) { section in
                        ThreadSidebarFold(section: section, open: isOpen(section), toggle: { toggle(section) }) {
                            summary(section)
                        } detail: {
                            detail(section)
                        } always: {
                            always(section)
                        }
                        .background(ColumnProbe(role: "threadSidebar:\(section.rawValue)"))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .scrollIndicators(.automatic)
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(ColumnProbe(role: "threadSidebar"))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("About this thread")
        // The transcript loaded so far: the Library loads the rest when you open it.
        .task(id: "\(session.id)|\(session.isRunning ? -1 : session.items.count)") {
            outputs = ThreadOutputs.collect(session)
        }
        .task(id: session.record.projectFolder) {
            guard let folder = session.record.projectFolder else { automations = []; return }
            automations = await Task.detached(priority: .utility) { ProjectAutomations.load() }.value
                .filter { $0.projectFolder == folder }
        }
    }

    // MARK: - Header: places you go

    private var header: some View {
        HStack(spacing: 4) {
            HeaderButton(title: "Files", icon: "folder", help: "Open this thread's folder in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session.workingFolder)])
            }
            .background(ColumnProbe(role: "threadSidebar:header:files"))
            HeaderButton(title: "Terminal", icon: "terminal", help: "A terminal in this thread's folder, at the bottom of the window (\u{2303}`)",
                         action: actions.toggleTerminal)
                .background(ColumnProbe(role: "threadSidebar:header:terminal"))
            HeaderButton(title: "Images", icon: "photo.on.rectangle.angled", help: "Library: the images and files this thread made or shared",
                         action: actions.showLibrary)
                .background(ColumnProbe(role: "threadSidebar:header:images"))
            Spacer(minLength: 0)
            Button(action: actions.close) {
                Image(systemName: overlay ? "xmark" : "sidebar.right").frame(width: 26, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.metadata)
            .help(overlay ? "Close" : "Hide this sidebar (\u{2325}\u{2318}0)")
            .accessibilityLabel(overlay ? "Close About this thread" : "Hide About this thread")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    // MARK: - Which sections

    private var visibleSections: [ThreadSidebarSection] {
        ThreadSidebarSection.allCases.filter { section in
            switch section {
            case .status, .place: true
            case .work: hasWork
            case .outputs: !outputs.isEmpty
            case .notes: true
            case .tools: !(ThreadTools.shared.chips(for: session) ?? []).isEmpty
            case .runs: !runs.isEmpty || !automations.isEmpty
            }
        }
    }
    private func isOpen(_ section: ThreadSidebarSection) -> Bool { openSections.split(separator: ",").contains { $0 == section.rawValue } }
    private func toggle(_ section: ThreadSidebarSection) {
        var open = Set(openSections.split(separator: ",").map(String.init))
        if open.remove(section.rawValue) == nil { open.insert(section.rawValue) }
        withAnimation(.smooth(duration: 0.18)) { openSections = open.sorted().joined(separator: ",") }
    }

    @ViewBuilder private func summary(_ section: ThreadSidebarSection) -> some View {
        switch section {
        case .status: statusSummary
        case .place: Text(placeSummary)
        case .work: Text(workSummary)
        case .outputs: Text(outputsSummary)
        case .notes: Text(notesSummary)
        case .tools: Text(toolsSummary)
        case .runs: Text(runsSummary)
        }
    }

    @ViewBuilder private func detail(_ section: ThreadSidebarSection) -> some View {
        switch section {
        case .status: statusDetail
        case .place: placeDetail
        case .work: workDetail
        case .outputs: outputsDetail
        case .notes: notesDetail
        case .tools: toolsDetail
        case .runs: runsDetail
        }
    }

    /// Shown open or closed: Outputs keeps its newest pictures in view.
    @ViewBuilder private func always(_ section: ThreadSidebarSection) -> some View {
        if section == .outputs, !isOpen(.outputs) { thumbnailStrip }
    }

    // MARK: - Status

    private var state: WorkThreadState { WorkThreadState(session) }
    private var context: ContextUsage? { session.contextUsage[session.record.backend] }

    private var statusSummary: some View {
        HStack(spacing: 4) {
            Circle().fill(state.color).frame(width: 7, height: 7)
            Text(state.label + " \u{00B7} " + modelSummary)
        }
    }

    private var statusDetail: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: state.icon).foregroundStyle(state.color)
                Text(state.label).fontWeight(.medium)
                if session.isRunning, let started = session.record.turnStartedAt {
                    Text(started, style: .timer).font(.caption.monospacedDigit()).foregroundStyle(Color.metadata)
                }
            }
            if state == .working, let step = session.lastActionSummary {
                Text(DeskStore.short(step, limit: 160)).font(.caption).foregroundStyle(Color.metadata).lineLimit(3)
            }
            SidebarRowButton(icon: session.record.backend.iconName, assetIcon: true, title: modelSummary,
                             help: "Model and effort. Click to change (\u{2318}\u{21E7}M).") {
                ChatCommands.shared.toggleModelPopover()
            }
            .background(ColumnProbe(role: "threadSidebar:model"))
            SidebarRowButton(icon: session.mode.systemImage, title: session.mode.title,
                             tint: session.mode.isUnrestricted ? .orange : nil,
                             help: "Permissions: \(session.mode.detail). Click to change (\u{2318}\u{21E7}P).") {
                ChatCommands.shared.toggleModePopover()
            }
            Menu {
                Picker("Tone", selection: Binding(get: { session.record.personality }, set: session.setPersonality)) {
                    ForEach(Personality.allCases) { tone in Label(tone.label, systemImage: ToneMenu.icon(tone)).tag(tone) }
                }
                .pickerStyle(.inline).labelsHidden()
            } label: {
                SidebarRowLabel(icon: ToneMenu.icon(session.record.personality), title: "Tone: \(session.record.personality.label)", chevron: true)
            }
            .modifier(RowMenuStyle(enabled: true))
            .help("Tone. Changes apply from your next message.")
            if let context {
                if let fraction = context.fraction {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text("Context").font(.caption)
                            Spacer()
                            Text("\(Int((fraction * 100).rounded()))%").font(.caption.monospacedDigit())
                        }
                        .foregroundStyle(Color.metadata)
                        ProgressView(value: fraction)
                            .progressViewStyle(.linear)
                            .tint(fraction >= 0.9 ? .red : fraction >= 0.75 ? .orange : .accentColor)
                            .controlSize(.small)
                    }
                    .padding(.top, 2)
                    .help("Context: \(UsageMeter.contextText(context))")
                    .background(ColumnProbe(role: "threadSidebar:context"))
                } else {
                    Text("Context: \(UsageMeter.tokens(context.used)) tokens").font(.caption).foregroundStyle(Color.metadata)
                }
            }
        }
    }

    // MARK: - Where

    private var studio: Studio? { model.studio(for: session) }
    private var git: GitStatus? { GitStatusStore.shared.status(for: session.record.projectFolder) }

    private var placeSummary: String {
        let place = studio?.name ?? (session.record.projectFolder != nil ? session.projectName : URL(fileURLWithPath: session.workingFolder).lastPathComponent)
        return [place, git?.branch, session.runMachine?.name].compactMap { $0 }.joined(separator: " \u{00B7} ")
    }

    private var placeDetail: some View {
        VStack(alignment: .leading, spacing: 6) {
            PlaceSlot(bridge: bridge, style: .row)
            SidebarRowButton(icon: "folder", title: (session.workingFolder as NSString).abbreviatingWithTildeInPath, middle: true,
                             help: "Show \(session.workingFolder) in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session.workingFolder)])
            }
            if let git, let branch = git.branch {
                let remote = git.remote(preferring: session.record.gitRemote)
                VStack(alignment: .leading, spacing: 4) {
                    let sync = [(git.ahead ?? 0) > 0 ? "\u{2191}\(git.ahead!)" : nil, (git.behind ?? 0) > 0 ? "\u{2193}\(git.behind!)" : nil].compactMap { $0 }
                    SidebarRowLabel(icon: "arrow.triangle.branch", title: branch, trailing: sync.isEmpty ? nil : sync.joined(separator: " "))
                    if let drift = git.mainDriftText { Text(drift).font(.caption).foregroundStyle(Color.metadata).padding(.leading, 24) }
                    if let repo = remote?.repo {
                        RepoDetails(bridge: bridge, repo: repo).padding(.leading, 24)
                    }
                }
            }
            SidebarRowLabel(icon: "desktopcomputer", title: session.runMachine?.name ?? "This Mac")
        }
    }

    // MARK: - Task & work

    private var desk: DeskModel { .shared }
    private var task: Companion.DeskTask? { desk.task(of: session.id) }
    private var front: ChatSession? { session.record.workOf.flatMap { id in model.sessions.first { $0.id == id } } }
    private var workThreads: [ChatSession] { session.isWorkThread ? [] : model.workThreads(of: session) }
    /// Starting things from here: work threads, sidequests, sidechats, errands, presets.
    private var canStart: Bool { !session.isSidequest && session.record.archivedAt == nil }
    private var hasWork: Bool { canStart || task != nil || front != nil || !workThreads.isEmpty }

    private var workSummary: String {
        var parts: [String] = []
        if task != nil { parts.append("Task \u{00B7} " + Self.column(for: state)) }
        if let front { parts.append("Work for \(front.title)") }
        if !workThreads.isEmpty {
            let working = workThreads.filter { WorkThreadState($0) == .working }.count
            parts.append("\(workThreads.count) work thread\(workThreads.count == 1 ? "" : "s")" + (working > 0 ? ", \(working) working" : ""))
        }
        return parts.isEmpty ? "Start work, a sidequest or a sidechat" : parts.joined(separator: " \u{00B7} ")
    }

    /// The Desk column a task's thread puts it in.
    static func column(for state: WorkThreadState) -> String {
        switch state {
        case .working: "Working"
        case .needsYou: "Needs you"
        case .ready: "Ready to mark complete"
        case .done: "Done"
        }
    }

    private var workDetail: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let task {
                VStack(alignment: .leading, spacing: 2) {
                    SidebarRowButton(icon: "checklist", title: DeskStore.short(task.text, limit: 90), lines: 2,
                                     help: "This thread's task on the Desk. Click to open the Desk.") { model.showDesk() }
                    Text("On the Desk \u{00B7} " + Self.column(for: state)).font(.caption).foregroundStyle(Color.metadata).padding(.leading, 24)
                }
            }
            if let front {
                SidebarRowButton(icon: "arrow.uturn.backward", title: "Works for \(front.title)",
                                 help: "The front thread this work thread reports back to. Click to open it.") { model.selectedID = front.id }
                    .accessibilityIdentifier("workFront")
            }
            if !workThreads.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(workThreads) { thread in WorkThreadRow(thread: thread) }
                }
                .background(ColumnProbe(role: "threadSidebar:workThreads"))
            }
            if canStart { StartActions(session: session) }
        }
    }

    // MARK: - Outputs

    private var images: [ThreadOutput] { outputs.filter { $0.kind == .image } }

    private var outputsSummary: String {
        let counts: [(Int, String)] = [(images.count, "image"), (outputs.filter { $0.kind == .file }.count, "file"),
                                       (outputs.filter { $0.kind == .link }.count, "link"), (outputs.filter { $0.kind == .draft }.count, "draft")]
        return counts.filter { $0.0 > 0 }.map { "\($0.0) \($0.1)\($0.0 == 1 ? "" : "s")" }.joined(separator: " \u{00B7} ")
    }

    private var thumbnailStrip: some View {
        HStack(spacing: 6) {
            ForEach(images.prefix(4)) { output in thumbnail(output, size: 56) }
            if images.isEmpty, let first = outputs.first { OutputRow(output: first, open: open) }
            Spacer(minLength: 0)
        }
        .padding(.leading, 22)
    }

    private var outputsDetail: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !images.isEmpty {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                    ForEach(images.prefix(8)) { output in thumbnail(output, size: 58) }
                }
            }
            ForEach(outputs.filter { $0.kind != .image }.prefix(10)) { output in OutputRow(output: output, open: open) }
            Button("Open Library", action: actions.showLibrary)
                .buttonStyle(.link).font(.caption)
                .help("Every image and file this thread made or shared")
        }
    }

    private func thumbnail(_ output: ThreadOutput, size: CGFloat) -> some View {
        Button { open(output) } label: {
            GalleryThumbnail(url: output.url!)
                .frame(width: size, height: size)
                .background(Color.primary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.1)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(output.title)
        .accessibilityLabel("Image \(output.title)")
    }

    @Environment(\.openURL) private var openURL
    private func open(_ output: ThreadOutput) {
        switch output.kind {
        case .image: if let url = output.url { actions.openImage(url) }
        // As a file link in the transcript opens: a document viewer, a page preview, or its app.
        case .file: if let url = output.url { openURL(url) }
        case .link: if let url = output.url { openURL(url) }
        case .draft:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(output.text ?? "", forType: .string)
        }
    }

    // MARK: - Notes

    private var noteScope: String { PinnedNotesStore.scope(for: session.record) }
    private var notes: [PinnedNote] { PinnedNotesStore.shared.notes[noteScope] ?? [] }
    private var pins: [PinnedMessage] { PinnedMessagesStore.shared.pins(for: session.id) }
    private var brief: String { session.record.brief ?? "" }

    private var notesSummary: String {
        if let line = brief.split(whereSeparator: \.isNewline).first { return "Brief: " + line }
        let parts = [notes.isEmpty ? nil : "\(notes.count) note\(notes.count == 1 ? "" : "s")",
                     pins.isEmpty ? nil : "\(pins.count) pinned"].compactMap { $0 }
        return parts.isEmpty ? "Add a brief or a note" : parts.joined(separator: " \u{00B7} ")
    }

    private var notesDetail: some View {
        VStack(alignment: .leading, spacing: 10) {
            BriefRow(session: session)
            ChatNotes(scope: noteScope, project: session.record.projectFolder != nil, panelWidth: Self.width - 32)
                .id(noteScope)
            ChatPins(chat: session.id, agentName: session.record.backend == .codex ? "Codex" : "Claude",
                     panelWidth: Self.width - 32, jump: actions.jumpToPin)
        }
    }

    // MARK: - Tools

    private var chips: [Companion.ToolChip] { ThreadTools.shared.chips(for: session) ?? [] }
    private var toolsSummary: String {
        let on = chips.filter(\.isOn).count, off = chips.count - on
        return "\(on) on" + (off > 0 ? " \u{00B7} \(off) off" : "")
    }
    private var toolsDetail: some View {
        ToolsButton(session: session, label: AnyView(
            FlowLayout(spacing: 4) {
                ForEach(chips) { chip in ToolChipView(chip: chip) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        ))
        .help("Tools: MCP servers, connectors and skills for this thread. Click for details and to change them.")
    }

    // MARK: - Runs here

    /// Sidechats and sidequests started from this thread, still open.
    private var runs: [ChatSession] {
        model.activeSessions.filter { ($0.record.sidechatOf == session.id || $0.record.sidequestOf == session.id) && !$0.isWorkThread }
            .sorted { $0.lastActivity > $1.lastActivity }
    }
    private var runsSummary: String {
        [runs.isEmpty ? nil : "\(runs.count) sidechat\(runs.count == 1 ? "" : "s")",
         automations.isEmpty ? nil : "\(automations.count) automation\(automations.count == 1 ? "" : "s")"]
            .compactMap { $0 }.joined(separator: " \u{00B7} ")
    }
    private var runsDetail: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(runs) { run in
                let state = WorkThreadState(run)
                SidebarRowButton(icon: run.isSidequest ? "point.topleft.down.to.point.bottomright.curvepath" : "bubble.left.and.bubble.right",
                                 title: run.title, trailing: state.label, trailingTint: state.color,
                                 help: "\(run.title): \(state.label). Click to peek at it beside this thread.") { model.peek(run.id, from: session.id) }
            }
            ForEach(automations) { automation in
                SidebarRowButton(icon: "clock.arrow.circlepath", title: automation.title,
                                 trailing: automation.enabled ? ProjectAutomations.scheduleText(automation) : "Off",
                                 help: "An automation of this project. Click to see and change automations.", action: actions.openAutomations)
            }
        }
    }
}

// MARK: - Pieces

/// One section: a heading line with its summary; open, the detail below it.
private struct ThreadSidebarFold<Summary: View, Detail: View, Always: View>: View {
    let section: ThreadSidebarSection
    let open: Bool
    let toggle: () -> Void
    @ViewBuilder let summary: Summary
    @ViewBuilder let detail: Detail
    @ViewBuilder let always: Always
    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: toggle) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.metadata)
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .frame(width: 10)
                    Text(section.title).font(.subheadline.weight(.semibold)).fixedSize()
                    summary
                        .font(.caption)
                        .foregroundStyle(Color.metadata)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .opacity(open ? 0 : 1)
                }
                .padding(.vertical, 5)
                .padding(.horizontal, 6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hovered ? 0.05 : 0)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
            .help(open ? "Hide \(section.title)" : "Show \(section.title)")
            .accessibilityLabel(section.title)
            .accessibilityValue(open ? "Expanded" : "Collapsed")
            always
            if open {
                detail
                    .font(.callout)
                    .padding(.leading, 6)
                    .padding(.trailing, 2)
                    .padding(.bottom, 6)
                    .transition(.opacity)
            }
        }
    }
}

/// A labeled icon along the sidebar's top.
private struct HeaderButton: View {
    let title: String
    let icon: String
    let help: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon).font(.system(size: 14)).frame(height: 18)
                Text(title).font(.caption2)
            }
            .frame(width: 58, height: 40)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(hovered ? 0.08 : 0.04)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
        .accessibilityLabel(title)
    }
}

/// A row's icon and text.
struct SidebarRowLabel: View {
    let icon: String
    var assetIcon = false
    let title: String
    var lines = 1
    var middle = false
    var trailing: String? = nil
    var trailingTint: Color? = nil
    var tint: Color? = nil
    var chevron = false

    var body: some View {
        HStack(alignment: lines > 1 ? .top : .center, spacing: 8) {
            // Menus draw their labels in the system font; every row the same size.
            Group {
                if assetIcon { Image(icon).resizable().scaledToFit().frame(width: 13, height: 13) } else { Image(systemName: icon) }
            }
            .foregroundStyle(tint ?? Color.metadata)
            .frame(width: 16)
            Text(title).lineLimit(lines).truncationMode(middle ? .middle : .tail)
                .foregroundStyle(tint ?? Color.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let trailing {
                Text(trailing).font(.caption).foregroundStyle(trailingTint ?? Color.metadata).lineLimit(1).fixedSize()
            }
            if chevron { Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(Color.metadata) }
        }
        .font(.callout)
        .padding(.vertical, chevron ? 3 : 0).padding(.horizontal, chevron ? 4 : 0)
        .contentShape(Rectangle())
    }
}

/// A row that does something when clicked, highlighted on hover.
struct SidebarRowButton: View {
    let icon: String
    var assetIcon = false
    let title: String
    var lines = 1
    var middle = false
    var trailing: String? = nil
    var trailingTint: Color? = nil
    var tint: Color? = nil
    let help: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            SidebarRowLabel(icon: icon, assetIcon: assetIcon, title: title, lines: lines, middle: middle,
                            trailing: trailing, trailingTint: trailingTint, tint: tint)
                .padding(.vertical, 3).padding(.horizontal, 4)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(hovered ? 0.07 : 0)))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
    }
}

/// One work thread: its state and name, and while it works, its latest status line.
struct WorkThreadRow: View {
    let thread: ChatSession
    @Environment(AppModel.self) private var model
    @State private var hovered = false

    var body: some View {
        let state = WorkThreadState(thread)
        let status = state == .working ? thread.lastActionSummary.map { DeskStore.short($0, limit: 160) } : nil
        // A peek beside the front thread (PeekPanel.swift), as the transcript's links do.
        Button { model.peek(thread.id, from: thread.record.workOf ?? thread.id) } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: state.icon).foregroundStyle(state.color).frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    HStack {
                        Text(thread.title).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(state.label).font(.caption).foregroundStyle(state == .needsYou ? Color.attention : Color.metadata).fixedSize()
                    }
                    if let status { Text(status).font(.caption).foregroundStyle(Color.metadata).lineLimit(2) }
                }
            }
            .padding(.vertical, 3).padding(.horizontal, 4)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(hovered ? 0.07 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("\(thread.title): \(state.label)\(status.map { " (\($0))" } ?? ""). Click to peek at it beside this thread.")
        .accessibilityLabel("\(thread.title), \(state.label)\(status.map { ", \($0)" } ?? "")")
        .accessibilityIdentifier("workChip:\(thread.id)")
    }
}

/// Starting something from this thread: each opens the form its column button used to.
private struct StartActions: View {
    let session: ChatSession
    @Environment(AppModel.self) private var model
    @State private var startingWork = false
    @State private var sidequest = false
    @State private var sidequestTask = ""
    @State private var errand = false
    @State private var errandTask = ""
    @State private var errandFiles: [URL] = []
    @State private var errandAgent: Backend = .claude
    @State private var presets = false
    private var other: Backend { session.record.backend == .claude ? .codex : .claude }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)], alignment: .leading, spacing: 4) {
                if !session.isWorkThread, session.record.automationID == nil {
                    action("Work Thread", "arrow.triangle.branch", "Start a work thread: a fresh thread in this folder for one piece of work, from a brief; its result comes back here") { startingWork = true }
                        .popover(isPresented: $startingWork, arrowEdge: .leading) { WorkThreadForm(front: session) { startingWork = false } }
                }
                action("Sidequest", "point.topleft.down.to.point.bottomright.curvepath", "Sidequest: send a task to \(other.label), and its answer comes back here") { sidequest = true }
                    .popover(isPresented: $sidequest, arrowEdge: .leading) {
                        SidequestForm(agent: other.label, from: session.record.backend.label, task: $sidequestTask) {
                            model.newSidequest(of: session, task: sidequestTask)
                            sidequestTask = ""; sidequest = false
                        }
                    }
                action("Sidechat", "bubble.left.and.bubble.right", "New Sidechat: a separate thread with a context handoff from this session, in the same folder") {
                    model.newSidechat(of: session)
                }
                action("On \(RemoteMachine.pc.name)", "desktopcomputer", "Do on \(RemoteMachine.pc.name): send a task to the PC, and its answer and files come back here") {
                    errandAgent = session.record.backend; errand = true
                }
                .popover(isPresented: $errand, arrowEdge: .leading) {
                    PCErrandForm(task: $errandTask, files: $errandFiles, agent: $errandAgent) {
                        model.newPCErrand(of: session, task: errandTask, files: errandFiles.map(\.path), backend: errandAgent)
                        errandTask = ""; errandFiles = []; errand = false
                    }
                }
                action("Presets", "bolt", session.isRunning ? "Prompt presets are available once the reply finishes" : "Prompt presets: send a saved prompt to this thread") { presets = true }
                    .disabled(session.isRunning)
                    .popover(isPresented: $presets, arrowEdge: .leading) {
                        QuickPromptList { prompt in presets = false; session.send(prompt.prompt) }
                    }
                if DeskModel.shared.hasTasks, session.record.sidequestOf == nil, session.record.automationID == nil {
                    Menu { ThreadTaskMenu(session: session) } label: {
                        Label(DeskModel.shared.task(of: session.id) == nil ? "Task" : "Task", systemImage: "checklist")
                    }
                    .menuStyle(.borderlessButton)
                    .controlSize(.small)
                    .fixedSize()
                    .help("Make this a task on the Desk, link it to one, or unlink it")
                }
            }
        }
        .padding(.top, 2)
        .background(ColumnProbe(role: "threadSidebar:start"))
    }

    private func action(_ title: String, _ icon: String, _ help: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Label(title, systemImage: icon).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(help)
        .accessibilityLabel(title == "Work Thread" ? "Start a Work Thread" : title)
    }
}

/// The repository's name, with its branch details and issues behind a click.
private struct RepoDetails: View {
    let bridge: ChatToolbarBridge
    let repo: String
    @State private var open = false

    var body: some View {
        HStack(spacing: 8) {
            Button { open.toggle() } label: {
                Text(repo).font(.caption).lineLimit(1).truncationMode(.middle)
            }
            .buttonStyle(.link)
            .help("\(repo): branch, remote and issues")
            .popover(isPresented: $open, arrowEdge: .leading) { RepoSlot(bridge: bridge).padding(14) }
            if let panel = bridge.issuesPanel {
                Button("Issues") { panel.show() }.buttonStyle(.link).font(.caption)
                    .help("This repository's issues, in a panel on the right (\u{2318}\u{21E7}I)")
            }
        }
    }
}

/// The Brief: its first lines, and the editor behind Edit.
private struct BriefRow: View {
    let session: ChatSession
    @State private var editing = false
    private var brief: String { session.record.brief ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("Brief", systemImage: brief.isEmpty ? "doc.text" : "doc.text.fill").font(.callout.weight(.medium))
                Spacer()
                Button(brief.isEmpty ? "Add" : "Edit") { editing = true }
                    .buttonStyle(.link).font(.caption)
                    .popover(isPresented: $editing, arrowEdge: .leading) { BriefEditor(session: session) { editing = false } }
            }
            if brief.isEmpty {
                Text("What this thread is for, the tools to use, the key files. Both agents get it.")
                    .font(.caption).foregroundStyle(Color.metadata).fixedSize(horizontal: false, vertical: true)
            } else {
                Text(brief).font(.caption).lineLimit(4).foregroundStyle(.primary)
                    .help(brief).textSelection(.enabled)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(brief.isEmpty ? "Brief, not set" : "Brief: \(brief)")
    }
}

private struct ToolChipView: View {
    let chip: Companion.ToolChip
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: chip.kind == "server" ? "server.rack" : chip.kind == "skill" ? "wand.and.stars" : "link")
                .font(.system(size: 8))
            Text(chip.name).lineLimit(1)
        }
        .font(.caption)
        .foregroundStyle(chip.isOn ? Color.primary : Color.metadata)
        .strikethrough(!chip.isOn, color: Color.metadata)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Capsule().fill(chip.isOn ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.05)))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(chip.isOn ? 0.08 : 0.12)))
        .accessibilityLabel("\(chip.name), \(chip.isOn ? "on" : "off")")
    }
}

private struct OutputRow: View {
    let output: ThreadOutput
    let open: (ThreadOutput) -> Void
    @State private var copied = false

    var body: some View {
        SidebarRowButton(icon: icon, title: output.title, trailing: copied ? "Copied" : output.kind == .draft ? "Copy" : nil,
                         help: help) {
            open(output)
            if output.kind == .draft {
                copied = true
                Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
            }
        }
    }
    private var icon: String {
        switch output.kind {
        case .image: "photo"
        case .file: output.url?.pathExtension.lowercased() == "pdf" ? "doc.richtext" : "doc"
        case .link: "link"
        case .draft: "envelope"
        }
    }
    private var help: String {
        switch output.kind {
        case .image, .file: output.url?.path ?? output.title
        case .link: "Open \(output.url?.absoluteString ?? "")"
        case .draft: "Copy this draft: " + (output.text ?? "")
        }
    }
}

// MARK: - Outputs

/// Something a thread made or shared: an image or file, a published link, or a draft.
struct ThreadOutput: Identifiable, Hashable {
    enum Kind { case image, file, link, draft }
    var id: String
    var kind: Kind
    var title: String
    var url: URL?
    var text: String? = nil
}

enum ThreadOutputs {
    /// Newest first, from the transcript loaded so far (its last few hundred messages).
    @MainActor static func collect(_ session: ChatSession, scanning: Int = 400, limit: Int = 40) -> [ThreadOutput] {
        let fm = FileManager.default
        let folder = session.workingFolder
        var seen = Set<String>()
        var found: [ThreadOutput] = []
        func addFile(_ url: URL) {
            var directory: ObjCBool = false
            guard seen.insert(url.path).inserted, fm.fileExists(atPath: url.path, isDirectory: &directory), !directory.boolValue else { return }
            let image = MediaKind.isStillImage(url.path) || url.pathExtension.lowercased() == "gif"
            found.append(.init(id: url.path, kind: image ? .image : .file, title: url.lastPathComponent, url: url))
        }
        for item in session.items.suffix(scanning).reversed() {
            guard found.count < limit else { break }
            item.attachments?.forEach { addFile($0.url) }
            guard item.kind == .assistant, item.phase == .final else { continue }
            for link in links(in: item.text) where seen.insert(link.absoluteString).inserted {
                found.append(.init(id: link.absoluteString, kind: .link, title: link.host.map { $0 + link.path } ?? link.absoluteString, url: link))
            }
            for draft in drafts(in: item.text) where seen.insert("draft:" + draft).inserted {
                let first = draft.split(whereSeparator: \.isNewline).first.map(String.init) ?? draft
                found.append(.init(id: "draft:\(item.id):\(found.count)", kind: .draft, title: first.replacingOccurrences(of: "Subject: ", with: ""), url: nil, text: draft))
            }
            ChatSession.referencedImages(in: item.text, folder: folder).forEach(addFile)
            PathLinks.referencedFiles(in: item.text, folder: folder).forEach { addFile(URL(fileURLWithPath: $0)) }
        }
        return Array(found.prefix(limit))
    }

    /// Published snippet links.
    static func links(in text: String) -> [URL] {
        guard text.contains("snippets.shelbyklein.com") else { return [] }
        let pattern = #"https://snippets\.shelbyklein\.com/[^\s)\]>"'`]*"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            Range(match.range, in: text).flatMap { URL(string: String(text[$0]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:"))) }
        }
    }

    /// The text of each ```draft or ```email block.
    static func drafts(in text: String) -> [String] {
        guard text.contains("```") else { return [] }
        var drafts: [String] = []
        var current: [Substring]?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if current != nil {
                if trimmed == "```" { drafts.append(current!.joined(separator: "\n")); current = nil } else { current!.append(line) }
            } else if trimmed.hasPrefix("```"), DraftCard.languages.contains(String(trimmed.dropFirst(3)).lowercased()) {
                current = []
            }
        }
        return drafts.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}
