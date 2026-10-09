import SwiftUI

// The Studios page: a column of Studios on the left (Pinned first, Activity at the bottom),
// and on the right either the pinned sessions as large previews or one Studio's inspector.
// Selecting a card or row only changes what this page shows; opening it selects the session.

/// Where a Studio session stands, in the order that matters most.
enum StudioSessionStatus: String {
    case needsYou = "Needs you", working = "Working", review = "Ready to review", idle = "Idle"

    var color: Color {
        switch self {
        case .needsYou: .orange
        case .working: .blue
        case .review: .green
        case .idle: .secondary
        }
    }
}

/// What a Studio session's card says about it, all from the chat itself: its state, the start of
/// its latest reply, and when its newest image arrived.
@MainActor
struct StudioSessionSummary {
    let status: StudioSessionStatus
    let note: String
    let lastActivity: Date
    let imageDate: Date?

    init(_ session: ChatSession, unread: Bool? = nil) {
        let unread = unread ?? Attention.shared.unread.contains(session.id)
        if session.isWaitingOnYou { status = .needsYou }
        else if session.isRunning || session.hasBackgroundWork { status = .working }
        else if unread { status = .review }
        else { status = .idle }
        note = Self.note(session, limit: 120)
        lastActivity = session.lastActivity
        imageDate = Self.imageDate(session)
    }

    /// The first sentence of the latest finished reply.
    static func note(_ session: ChatSession, limit: Int) -> String {
        guard let text = session.items.last(where: { $0.kind == .assistant && $0.phase == .final && !$0.text.isEmpty })?.text
        else { return "No replies yet" }
        return ChatSession.firstSentence(of: text, limit: limit) ?? "Open to view the conversation"
    }

    /// When the row holding the newest image was added.
    static func imageDate(_ session: ChatSession) -> Date? {
        guard let url = session.latestThumbnailURL() else { return nil }
        let row = session.items.last { item in
            item.attachments?.contains { $0.url == url } == true || item.text.contains(url.path) || item.text.contains(url.lastPathComponent)
        }
        return row?.timestamp
    }
}

/// Which Studio entry is chosen in the left column.
enum StudioSelection: Hashable {
    case pinned, studio(UUID)

    init(_ raw: String) { self = UUID(uuidString: raw).map(StudioSelection.studio) ?? .pinned }
    var raw: String {
        switch self {
        case .pinned: "pinned"
        case .studio(let id): id.uuidString
        }
    }
}

struct ChatHomeView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var filter: HomeThreadFilter = .all
    /// Asks for a name and makes a Studio (ContentView owns that sheet).
    var newStudio: () -> Void = {}
    /// A thread's context menu, the same as the sidebar's.
    let menu: (ChatSession) -> AnyView

    @AppStorage("macStudioSelection") private var savedSelection = "pinned"
    /// Each Studio's inspected session, as "studio=session" pairs.
    @AppStorage("macStudioInspected") private var savedInspected = ""

    /// A Studio that no longer exists falls back to Pinned.
    private var selection: StudioSelection {
        let saved = StudioSelection(savedSelection)
        if case .studio(let id) = saved, !model.activeStudios.contains(where: { $0.id == id }) { return .pinned }
        return saved
    }
    private var selectedStudio: Studio? {
        if case .studio(let id) = selection { return model.activeStudios.first { $0.id == id } }
        return nil
    }

    var body: some View {
        HStack(spacing: 0) {
            StudioColumn(selection: selection, newStudio: newStudio) { savedSelection = $0.raw }
                .frame(width: 230)
            Divider()
            VStack(spacing: 0) {
                header.padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 16)
                Divider()
                if let studio = selectedStudio {
                    StudioInspector(studio: studio, sessions: sessions(in: studio), inspected: inspectedBinding(studio), menu: menu)
                } else {
                    PinnedSheet(groups: pinnedGroups, filtering: isFiltering, menu: menu) { session in
                        guard let id = session.record.studioID else { return }
                        setInspected(session.id, in: id)
                        withAnimation(.smooth(duration: 0.2)) { savedSelection = StudioSelection.studio(id).raw }
                    }
                }
            }
        }
        // The window's theme (Settings → Appearance), else the system's window color.
        .background(Theme.currentBackground ?? Color(nsColor: .windowBackgroundColor))
        .accessibilityLabel(selectedStudio.map { "Studio \($0.name)" } ?? "Pinned Studio sessions")
    }

    private var isFiltering: Bool { !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || filter != .all }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(selectedStudio?.name ?? "Studios").font(.largeTitle.weight(.bold)).lineLimit(1)
                if selectedStudio == nil {
                    Text("Pinned").font(.title3).foregroundStyle(.secondary)
                }
                Spacer()
                if let studio = selectedStudio {
                    Button("Instructions", systemImage: "doc.text") { model.editingStudioInstructions = studio.id }
                        .help("Edit \(studio.name)'s instructions")
                    Button("New Chat", systemImage: "plus") {
                        model.newChat(in: studio)
                        model.showingHome = false
                    }
                    .help("New chat in \(studio.name)")
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { searchField; filterPicker.frame(width: 300) }
                VStack(alignment: .leading, spacing: 10) { searchField; filterPicker }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(selectedStudio.map { "Search \($0.name)" } ?? "Search pinned sessions", text: $search).textFieldStyle(.plain)
        }.padding(9).background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
    }
    private var filterPicker: some View {
        Picker("Threads", selection: $filter) {
            ForEach(HomeThreadFilter.allCases) { Text($0.rawValue).tag($0) }
        }.pickerStyle(.segmented).labelsHidden().accessibilityLabel("Filter threads")
        #if DEBUG
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { MacHomeDebug.filter = $0 }
        #endif
    }

    /// A Studio's chats with their Sidechats, newest first, through the search and filter.
    private func sessions(in studio: Studio) -> [ChatSession] {
        model.chats(in: studio).sorted { $0.lastActivity > $1.lastActivity }
            .flatMap { [$0] + model.sidechats(of: $0) }
            .filter { HomeThreads.matches($0, model, search: search, filter: filter) }
    }

    /// Pinned Studio sessions under their Studios, in Studio order, then pin order.
    private var pinnedGroups: [HomeThreadGroup] {
        let pinned = model.pinnedThreads.filter { $0.record.studioID != nil && HomeThreads.matches($0, model, search: search, filter: filter) }
        return model.activeStudios.compactMap { studio in
            let threads = pinned.filter { $0.record.studioID == studio.id }
            return threads.isEmpty ? nil : HomeThreadGroup(id: studio.id.uuidString, title: studio.name, threads: threads)
        }
    }

    private var inspectedMap: [String: String] {
        Dictionary(savedInspected.split(separator: ",").compactMap { pair -> (String, String)? in
            let parts = pair.split(separator: "=")
            return parts.count == 2 ? (String(parts[0]), String(parts[1])) : nil
        }, uniquingKeysWith: { _, last in last })
    }
    private func setInspected(_ session: UUID, in studio: UUID) {
        var map = inspectedMap
        map[studio.uuidString] = session.uuidString
        savedInspected = map.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ",")
    }
    private func inspectedBinding(_ studio: Studio) -> Binding<UUID?> {
        Binding(get: { inspectedMap[studio.id.uuidString].flatMap(UUID.init) },
                set: { if let id = $0 { setInspected(id, in: studio.id) } })
    }
}

// MARK: - Left column

private struct StudioColumn: View {
    @Environment(AppModel.self) private var model
    let selection: StudioSelection
    let newStudio: () -> Void
    let select: (StudioSelection) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    Text("STUDIOS").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 10).padding(.bottom, 6)
                    entry(.pinned, title: "Pinned", count: model.pinnedThreads.filter { $0.record.studioID != nil }.count, icon: "pin")
                    ForEach(model.activeStudios) { studio in
                        entry(.studio(studio.id), title: studio.name, count: model.chats(in: studio).count, icon: "paintpalette")
                    }
                    Button { newStudio() } label: {
                        Label("New Studio", systemImage: "plus").font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 7)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).padding(.top, 6)
                }
                .padding(.horizontal, 12).padding(.top, 24)
            }
            // The same Working and New replies as the chat sidebar's.
            SidebarActivityStrip(showsEmptyState: true).padding(.horizontal, 12).padding(.vertical, 10)
                #if DEBUG
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { MacHomeDebug.activity = $0 }
                #endif
        }
        .background(Color.primary.opacity(0.03))
        #if DEBUG
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { MacHomeDebug.column = $0 }
        #endif
    }

    private func entry(_ value: StudioSelection, title: String, count: Int, icon: String) -> some View {
        let selected = selection == value
        return Button { withAnimation(.smooth(duration: 0.2)) { select(value) } } label: {
            HStack(spacing: 8) {
                Image(systemName: selected && value == .pinned ? "pin.fill" : icon).frame(width: 18).foregroundStyle(.secondary)
                Text(title).lineLimit(1)
                Spacer(minLength: 4)
                Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(selected ? Color.primary.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        #if DEBUG
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { MacHomeDebug.entries[value.raw] = $0 }
        #endif
    }
}

// MARK: - Pinned

private struct PinnedSheet: View {
    @Environment(AppModel.self) private var model
    let groups: [HomeThreadGroup]
    let filtering: Bool
    let menu: (ChatSession) -> AnyView
    let inspect: (ChatSession) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(group.title).font(.title2.weight(.semibold))
                            Text(counts(group.threads)).font(.subheadline).foregroundStyle(.secondary)
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 210, maximum: 320), spacing: 18, alignment: .top)], alignment: .leading, spacing: 22) {
                            ForEach(group.threads) { session in
                                StudioPreviewCard(session: session, inspect: { inspect(session) }, open: { model.selectedID = session.id })
                                    .contextMenu { menu(session) }
                            }
                        }
                    }
                    #if DEBUG
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { MacHomeDebug.pinnedGroups[group.id] = $0 }
                    #endif
                }
                if groups.isEmpty {
                    ContentUnavailableView(filtering ? "No matching pinned sessions" : "No pinned Studio sessions", systemImage: "pin",
                                           description: Text(filtering ? "Try another search or choose All."
                                                             : "Right-click a session in any Studio and choose Pin to Top to see it here."))
                        .frame(maxWidth: .infinity).padding(.vertical, 80)
                }
            }
            .padding(28).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func counts(_ threads: [ChatSession]) -> String {
        let statuses = threads.map { StudioSessionSummary($0).status }
        var parts = ["\(threads.count) pinned"]
        let needs = statuses.filter { $0 == .needsYou }.count
        let working = statuses.filter { $0 == .working }.count
        if needs > 0 { parts.append("\(needs) needs you") }
        if working > 0 { parts.append("\(working) working") }
        return parts.joined(separator: " · ")
    }
}

/// A pinned session: Project-card provider/activity header, then its image, title and note.
private struct StudioPreviewCard: View {
    let session: ChatSession
    let inspect: () -> Void
    let open: () -> Void
    @State private var hovered = false

    var body: some View {
        let summary = StudioSessionSummary(session)
        Button { StudioClicks.handle(inspect: inspect, open: open) } label: { VStack(alignment: .leading, spacing: 8) {
            HStack {
                SessionProviderIcon(session: session)
                Spacer(minLength: 6)
                SessionActivityIndicator(session: session)
            }
            StudioPreviewImage(session: session, cornerRadius: 12)
                .aspectRatio(4 / 3, contentMode: .fit)
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(summary.status == .needsYou ? Color.orange : Color.primary.opacity(hovered ? 0.3 : 0.1), lineWidth: summary.status == .needsYou ? 2 : 1)
                }
            HStack(alignment: .firstTextBaseline) {
                Text(session.title).font(.headline).lineLimit(1)
                Spacer(minLength: 6)
                Text(ShortAge.string(since: summary.lastActivity)).font(.caption).foregroundStyle(.secondary)
            }
            StudioAttentionLabel(status: summary.status)
            Text(summary.note).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
        }
        .contentShape(Rectangle()) }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("\(session.title) — \(summary.status.rawValue). Click to inspect, double-click to open.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(session.title)
        .accessibilityValue("\(summary.status.rawValue), \(summary.note)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Inspect", inspect)
        .accessibilityAction(named: "Open chat", open)
        #if DEBUG
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { MacHomeDebug.cards[session.id] = $0 }
        #endif
    }
}

// MARK: - Inspector

private struct StudioInspector: View {
    @Environment(AppModel.self) private var model
    let studio: Studio
    let sessions: [ChatSession]
    @Binding var inspected: UUID?
    let menu: (ChatSession) -> AnyView

    /// The saved session if it's still listed, else the newest.
    private var current: ChatSession? { sessions.first { $0.id == inspected } ?? sessions.first }

    var body: some View {
        if sessions.isEmpty {
            ContentUnavailableView {
                Label("No sessions to show", systemImage: "paintpalette")
            } description: {
                Text(model.chats(in: studio).isEmpty ? "Start a chat in \(studio.name) to see it here." : "Try another search or choose All.")
            } actions: {
                Button("New Chat in \(studio.name)") { model.newChat(in: studio); model.showingHome = false }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HStack(alignment: .top, spacing: 0) {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(sessions) { session in
                            InspectorRow(session: session, selected: session.id == current?.id) {
                                withAnimation(.smooth(duration: 0.15)) { inspected = session.id }
                            } open: { model.selectedID = session.id }
                            .contextMenu { menu(session) }
                        }
                    }.padding(16)
                }
                .frame(width: 320)
                Divider()
                if let current { InspectorDetail(session: current) }
            }
            #if DEBUG
            .onChange(of: current?.id, initial: true) { MacHomeDebug.inspected = current?.id }
            .onChange(of: sessions.map(\.id), initial: true) { MacHomeDebug.listed = sessions.map(\.id) }
            #endif
        }
    }
}

private struct InspectorRow: View {
    let session: ChatSession
    let selected: Bool
    let inspect: () -> Void
    let open: () -> Void
    @State private var hovered = false

    var body: some View {
        let summary = StudioSessionSummary(session)
        Button { StudioClicks.handle(inspect: inspect, open: open) } label: { HStack(alignment: .top, spacing: 12) {
            StudioPreviewImage(session: session, cornerRadius: 8, small: true).frame(width: 58, height: 58)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    SessionProviderIcon(session: session)
                    Spacer(minLength: 6)
                    SessionActivityIndicator(session: session)
                }
                Text(session.title).font(.body.weight(.semibold)).lineLimit(1)
                StudioAttentionLabel(status: summary.status)
                Text(summary.note).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Text(ShortAge.string(since: summary.lastActivity)).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(selected ? Color.primary.opacity(0.12) : hovered ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            if summary.status == .needsYou { RoundedRectangle(cornerRadius: 10).strokeBorder(Color.orange.opacity(0.7)) }
        }
        .contentShape(Rectangle()) }
        .buttonStyle(.plain)
        .padding(.leading, session.record.sidechatOf != nil ? 20 : 0)
        .onHover { hovered = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(session.title)
        .accessibilityValue("\(summary.status.rawValue), \(summary.note)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: "Inspect", inspect)
        .accessibilityAction(named: "Open chat", open)
        #if DEBUG
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { MacHomeDebug.cards[session.id] = $0 }
        #endif
    }
}

private struct InspectorDetail: View {
    @Environment(AppModel.self) private var model
    let session: ChatSession
    private let appearance = ReaderStyleSettings()

    var body: some View {
        let summary = StudioSessionSummary(session)
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                SessionProviderIcon(session: session, size: 19)
                    .alignmentGuide(.firstTextBaseline, computeValue: SidebarRow.centerOnTextLine)
                Text(session.title).font(.title2.weight(.semibold)).lineLimit(2)
                Spacer(minLength: 12)
                SessionActivityIndicator(session: session)
                    .alignmentGuide(.firstTextBaseline, computeValue: SidebarRow.centerOnTextLine)
            }
            // Without an image, a short placeholder rather than an empty stage.
            let hasImage = ThreadThumbnails.shared.images[session.id] != nil || ThreadThumbnails.shared.largeImages[session.id] != nil
            StudioPreviewImage(session: session, cornerRadius: 12, fit: true)
                .frame(maxWidth: .infinity, maxHeight: hasImage ? .infinity : 200)
                .overlay(alignment: .topTrailing) {
                    if let date = summary.imageDate {
                        Text("Image from \(ShortAge.string(since: date)) ago").font(.caption)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                            .foregroundStyle(.white).padding(10)
                    }
                }
                #if DEBUG
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { MacHomeDebug.preview = $0 }
                #endif
            if !hasImage { Spacer(minLength: 0) }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                StudioAttentionLabel(status: summary.status)
                Text(StudioSessionSummary.note(session, limit: 320)).font(.body).lineLimit(4).textSelection(.enabled)
                HStack {
                    Text("Last active \(summary.lastActivity.formatted(.relative(presentation: .named))) · \(session.record.provider.label)")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Chat") { model.selectedID = session.id }
                        .keyboardShortcut(.defaultAction)
                        #if DEBUG
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { MacHomeDebug.openChat = $0 }
                        #endif
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Shared pieces

/// One click inspects a card or row; the second click of a double-click opens its chat.
@MainActor enum StudioClicks {
    static func handle(inspect: () -> Void, open: () -> Void) {
        if (NSApp.currentEvent?.clickCount ?? 1) >= 2 { open() } else { inspect() }
    }
}

/// A session's newest image on a dark panel, large when there's room; its agent's icon otherwise.
private struct StudioPreviewImage: View {
    let session: ChatSession
    var cornerRadius: CGFloat
    var small = false
    /// Show the whole image rather than filling the frame.
    var fit = false
    private let appearance = ReaderStyleSettings()
    private var thumbnails: ThreadThumbnails { .shared }

    var body: some View {
        let image = small ? thumbnails.images[session.id] : (thumbnails.largeImages[session.id] ?? thumbnails.images[session.id])
        // The panel takes the offered size; the image fills or fits inside it, never past it.
        Color.primary.opacity(0.07).overlay {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high)
                    .aspectRatio(contentMode: fit ? .fit : .fill)
                    .padding(fit ? 12 : 0)
                    .accessibilityLabel("Latest image in \(session.title)")
            } else {
                VStack(spacing: 10) {
                    SessionProviderIcon(session: session, size: small ? 24 : 40)
                    if fit { Text("No image yet").font(.callout).foregroundStyle(.secondary) }
                }
            }
        }
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: ThreadThumbnails.key(session)) {
            if small { thumbnails.refresh(session) } else { thumbnails.refreshLarge(session) }
        }
        #if DEBUG
        .onChange(of: thumbnails.largeImages[session.id]?.size, initial: true) {
            if fit, let size = thumbnails.largeImages[session.id]?.size { MacHomeDebug.previewPixels = size }
        }
        #endif
    }
}

/// Only states requiring action need text; activity itself lives in the top-right indicator.
private struct StudioAttentionLabel: View {
    let status: StudioSessionStatus
    var body: some View {
        if status == .needsYou || status == .review {
            Text(status == .review ? "New reply" : status.rawValue)
                .font(.caption.weight(.medium))
                .foregroundStyle(status == .needsYou ? Color.orange : .blue)
        }
    }
}
