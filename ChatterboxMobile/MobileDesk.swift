import SwiftUI

// The Desk on the phone: what needs you, incoming work to place, what is working. plans/front-desk.md

/// The home's first tab. What needs you (approve or deny in place, or open), requests waiting
/// to be placed (start where the Desk proposes, or choose another place), and one quiet line
/// of what's working. The Desk never does work itself: starting a request opens a session in
/// its Studio or project, through the same path as a tapped notification.
struct MobileDeskView: View {
    @Environment(MobileStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @State private var ask = ""
    @State private var adding = false
    @FocusState private var asking: Bool
    /// Waiting items and requests acted on here, hidden until the Desk stops listing them.
    @State private var settled = Set<UUID>()
    @State private var busy = Set<UUID>()
    /// Places picked with Change Place, per request; Start There uses them.
    @State private var chosen: [UUID: Companion.DeskPlace] = [:]
    @State private var choosing: Companion.DeskRequest?
    /// Why the Desk couldn't be read, shown until it can.
    @State private var loadProblem: String?
    /// An action that didn't go through.
    @State private var actionProblem: String?

    /// What the Desk's tab counts, as of its last answer: what needs you and requests
    /// waiting to be placed.
    static func waiting(_ desk: Companion.Desk) -> Int { desk.needsYou.count + desk.incoming.count }

    private var desk: Companion.Desk? { store.latestDesk }
    private var needsYou: [Companion.DeskWaiting] { (desk?.needsYou ?? []).filter { !settled.contains($0.id) } }
    private var incoming: [Companion.DeskRequest] { (desk?.incoming ?? []).filter { !settled.contains($0.id) } }
    private var working: [Companion.DeskWorking] { desk?.working ?? [] }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    summaryLine
                    if let problem = store.problem ?? loadProblem { MobileProblemCard(problem) }
                    // Nothing to ask of a Mac without the Desk, or one not reached yet.
                    if desk != nil || (loadProblem == nil && store.problem == nil) { askBox }
                    if desk == nil, loadProblem == nil, store.problem == nil { loading }
                    if !needsYou.isEmpty { needsYouSection }
                    if !incoming.isEmpty { incomingSection }
                    if desk != nil, needsYou.isEmpty, incoming.isEmpty { calm }
                    if !working.isEmpty { workingLine }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
                // A readable column on a big iPad; an iPad mini or open iPhone Duo fills.
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
                .animation(.easeOut(duration: 0.2), value: needsYou.map(\.id) + incoming.map(\.id))
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Desk")
            .navigationBarTitleDisplayMode(.large)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { FeedbackButton() } }
            .refreshable { await refresh() }
        }
        .sheet(item: $choosing) { request in
            MobileDeskPlacePicker(current: place(for: request)) { chosen[request.id] = $0 }
                .environment(store)
        }
        .alert("Couldn't update the Desk", isPresented: Binding(get: { actionProblem != nil }, set: { if !$0 { actionProblem = nil } })) {
            Button("OK", role: .cancel) { actionProblem = nil }
        } message: { Text(actionProblem ?? "") }
        // On screen: kept current, like the chat list.
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    // MARK: Sections

    /// "2 need you · 1 incoming · 3 working", under the title.
    private var summaryLine: some View {
        Text(summary)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("desk-summary")
    }

    private var summary: String {
        guard desk != nil else { return "Checking with \(store.connection?.macName ?? "your Mac")…" }
        var parts: [String] = []
        if !needsYou.isEmpty { parts.append("\(needsYou.count) need\(needsYou.count == 1 ? "s" : "") you") }
        if !incoming.isEmpty { parts.append("\(incoming.count) incoming") }
        if !working.isEmpty { parts.append("\(working.count) working") }
        return parts.isEmpty ? "All clear" : parts.joined(separator: " · ")
    }

    private var loading: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Reading the Desk…").font(.footnote).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var trimmedAsk: String { ask.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Type what needs doing; the Desk proposes where it goes before anything starts.
    private var askBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField("What needs doing?", text: $ask, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($asking)
                    .padding(.vertical, 6)
                    .accessibilityIdentifier("desk-ask")
                Button(action: add) {
                    Group {
                        if adding { ProgressView().controlSize(.small) }
                        else { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    }
                    .frame(width: 32, height: 32)
                }
                .disabled(trimmedAsk.isEmpty || adding)
                .accessibilityLabel("Add to Desk")
                .accessibilityIdentifier("desk-ask-send")
            }
            .padding(.leading, 14).padding(.trailing, 6).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(uiColor: .secondarySystemGroupedBackground)))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(asking ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.06), lineWidth: asking ? 1.5 : 1))
            Text("The Desk suggests a place before anything starts.")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 6)
        }
    }

    private var needsYouSection: some View {
        section("Needs you", id: "needs-you") {
            ForEach(needsYou) { item in
                DeskWaitingCard(item: item, busy: busy.contains(item.id),
                                open: { open(item.chatID) },
                                decide: { decide($0, item) })
            }
        }
    }

    private var incomingSection: some View {
        section("Incoming", id: "incoming") {
            ForEach(incoming) { request in
                DeskRequestCard(request: request, place: place(for: request), changed: chosen[request.id] != nil,
                                busy: busy.contains(request.id),
                                start: { start(request) },
                                change: { choosing = request },
                                ignore: { ignore(request) })
            }
        }
    }

    /// A healthy Desk takes no space.
    private var calm: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle").font(.title3).foregroundStyle(.green)
            Text("Nothing else needs you.").font(.body).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("desk-calm")
    }

    /// One quiet line: what's working, each title opens its session.
    private var workingLine: some View {
        HStack(spacing: 8) {
            Label("\(working.count) working", systemImage: "circle.dotted")
                .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon).fixedSize()
                .accessibilityIdentifier("desk-working")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(working) { item in
                        Button { open(item.id) } label: {
                            Text(item.title).font(.footnote).lineLimit(1)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(Capsule().fill(Color(uiColor: .secondarySystemGroupedBackground)))
                                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.06)))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(item.title), working\(item.place.map { ", in \($0)" } ?? "")")
                        .accessibilityIdentifier("desk-working-\(item.id.uuidString)")
                    }
                }
            }
        }
    }

    private func section<Content: View>(_ title: String, id: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.footnote.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                .padding(.horizontal, 4)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("desk-section-\(id)")
            content()
        }
    }

    // MARK: Actions

    private func refresh() async {
        async let chats: Void = store.loadChats()
        do {
            let fresh = try await store.desk()
            loadProblem = nil
            // What the Desk no longer lists needn't stay hidden.
            settled = settled.filter { id in fresh.needsYou.contains { $0.id == id } || fresh.incoming.contains { $0.id == id } }
        } catch is CancellationError {
        } catch {
            if !Task.isCancelled { loadProblem = Self.describe(error) }
        }
        await chats
    }

    /// Opens a session in its own tab, as a tapped notification does: on iPhone over that
    /// tab's list, on iPad beside it.
    private func open(_ chat: UUID) {
        Task {
            // The tab is chosen from the chat list; a new session may not be in it yet.
            if store.chatList?.groups.contains(where: { $0.chats.contains { $0.id == chat } }) != true { await store.loadChats() }
            MobilePushNotifications.shared.pendingChat = chat
        }
    }

    private func add() {
        let text = trimmedAsk
        guard !text.isEmpty, !adding else { return }
        adding = true
        Task {
            defer { adding = false }
            do {
                _ = try await store.addToDesk(text)
                ask = ""
                asking = false
            } catch { actionProblem = Self.describe(error) }
        }
    }

    /// Approve or deny in place, with the same call the session's own card makes.
    private func decide(_ decision: String, _ item: Companion.DeskWaiting) {
        guard busy.insert(item.id).inserted else { return }
        Task {
            defer { busy.remove(item.id) }
            do {
                _ = try await store.decide(decision, item: item.id, in: item.chatID)
                settled.insert(item.id)
                _ = try? await store.desk()
            } catch { actionProblem = Self.describe(error) }
        }
    }

    private func start(_ request: Companion.DeskRequest) {
        guard place(for: request) != nil else { choosing = request; return }
        guard busy.insert(request.id).inserted else { return }
        let place = chosen[request.id]
        Task {
            defer { busy.remove(request.id) }
            do {
                let started = try await store.startDesk(request.id, place: place)
                settled.insert(request.id)
                chosen[request.id] = nil
                open(started.summary.id)
                _ = try? await store.desk()
            } catch { actionProblem = Self.describe(error) }
        }
    }

    private func ignore(_ request: Companion.DeskRequest) {
        guard busy.insert(request.id).inserted else { return }
        Task {
            defer { busy.remove(request.id) }
            do {
                _ = try await store.ignoreDesk(request.id)
                settled.insert(request.id)
                chosen[request.id] = nil
            } catch { actionProblem = Self.describe(error) }
        }
    }

    private func place(for request: Companion.DeskRequest) -> Companion.DeskPlace? {
        chosen[request.id] ?? request.proposed
    }

    static func describe(_ error: Error) -> String {
        if let error = error as? MobileError, error.status == 404 {
            return "The Desk isn't on this Mac yet. Update Chatterbox on the Mac to use it."
        }
        return error.localizedDescription
    }
}

// MARK: - Places

enum MobileDeskPlaces {
    static func icon(_ place: Companion.DeskPlace?) -> String {
        switch place?.kind {
        case "studio": "paintpalette"
        case "project": "folder"
        case "loose": "bubble.left"
        case nil: "questionmark.circle"
        default: "tray"
        }
    }

    /// The same place, whether or not each copy carries its detail line.
    static func same(_ a: Companion.DeskPlace?, _ b: Companion.DeskPlace) -> Bool {
        guard let a else { return false }
        return a.kind == b.kind && a.id == b.id && (a.id != nil || a.name == b.name)
    }
}

/// A Studio or project's name, small, with its kind's symbol.
private struct DeskPlaceTag: View {
    let name: String
    var body: some View {
        Text(name)
            .font(.caption.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
    }
}

/// A session waiting on you: what it asks; approve or deny in place, or open it.
private struct DeskWaitingCard: View {
    let item: Companion.DeskWaiting
    let busy: Bool
    let open: () -> Void
    let decide: (String) -> Void

    private var decides: Bool { item.kind == "approval" || item.kind == "plan" }
    private var kind: (title: String, icon: String) {
        switch item.kind {
        case "approval": ("Permission needed", "hand.raised.fill")
        case "plan": ("Plan ready", "list.bullet.clipboard")
        case "questions": ("Questions", "questionmark.bubble")
        case "reply": ("Waiting on your reply", "text.bubble")
        default: ("Needs you", "exclamationmark.circle")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: open) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Label(kind.title, systemImage: kind.icon)
                            .font(.caption.weight(.semibold)).foregroundStyle(.yellow)
                        Spacer(minLength: 8)
                        if let place = item.place, place != item.title { DeskPlaceTag(name: place) }
                    }
                    Text(item.title).font(.headline).lineLimit(2).multilineTextAlignment(.leading)
                    Text(item.text).font(.subheadline).foregroundStyle(.secondary)
                        .lineLimit(4).multilineTextAlignment(.leading)
                    if let questions = item.questions, questions.count > 1 {
                        Text("\(questions.count) questions").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the session")
            .accessibilityIdentifier("desk-waiting-\(item.id.uuidString)")
            HStack(spacing: 8) {
                if busy {
                    ProgressView().controlSize(.small)
                    Text("Sending…").font(.footnote).foregroundStyle(.secondary)
                } else if decides {
                    Button("Approve") { decide("approved") }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("desk-approve-\(item.id.uuidString)")
                    Button("Deny", role: .destructive) { decide("denied") }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("desk-deny-\(item.id.uuidString)")
                } else {
                    Button("Open", action: open)
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("desk-open-\(item.id.uuidString)")
                }
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(uiColor: .secondarySystemGroupedBackground)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.yellow.opacity(0.5), lineWidth: 1.5))
    }
}

/// Work waiting to be placed: where the Desk proposes it goes, and why.
private struct DeskRequestCard: View {
    let request: Companion.DeskRequest
    let place: Companion.DeskPlace?
    /// Picked here with Change Place, instead of the Desk's proposal.
    let changed: Bool
    let busy: Bool
    let start: () -> Void
    let change: () -> Void
    let ignore: () -> Void

    private var source: String {
        switch request.source {
        case "you": "From you"
        case "claude": "From Claude"
        default: "From \(request.source.capitalized)"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(request.text)
                .font(.body).lineLimit(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(source) · \(request.createdAt.formatted(.relative(presentation: .named)))")
                .font(.caption).foregroundStyle(.secondary)
            Button(action: change) {
                HStack(spacing: 6) {
                    Image(systemName: MobileDeskPlaces.icon(place))
                    Text(place?.name ?? "Choose a place").lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold))
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(place == nil ? Color.secondary : Color.accentColor)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Capsule().fill(place == nil ? Color.primary.opacity(0.06) : Color.accentColor.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(place.map { "Place: \($0.name)\(changed ? ", changed" : "")" } ?? "Choose a place")
            .accessibilityHint("Shows the Studios and projects it could go to")
            .accessibilityIdentifier("desk-place-\(request.id.uuidString)")
            if let note = request.note, !note.isEmpty {
                Text(note).font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if busy {
                    ProgressView().controlSize(.small)
                    Text("Working on it…").font(.footnote).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                } else {
                    // Nothing starts until it has a place.
                    Button("Start There", action: start)
                        .buttonStyle(.borderedProminent)
                        .disabled(place == nil)
                        .accessibilityIdentifier("desk-start-\(request.id.uuidString)")
                    Button(place == nil ? "Choose Place" : "Change Place", action: change)
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("desk-\(place == nil ? "choose" : "change")-\(request.id.uuidString)")
                    Spacer(minLength: 0)
                    Button("Ignore", action: ignore)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("desk-ignore-\(request.id.uuidString)")
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(uiColor: .secondarySystemGroupedBackground)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
    }
}

/// Change Place: every Studio and project, with what belongs there.
private struct MobileDeskPlacePicker: View {
    let current: Companion.DeskPlace?
    let pick: (Companion.DeskPlace) -> Void
    @Environment(MobileStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var places: [Companion.DeskPlace]?
    @State private var problem: String?
    @State private var search = ""

    private var groups: [(title: String, places: [Companion.DeskPlace])] {
        let words = search.split(whereSeparator: \.isWhitespace).map(String.init)
        let shown = (places ?? []).filter { place in
            words.allSatisfy { "\(place.name) \(place.detail ?? "")".localizedStandardContains($0) }
        }
        return [("Studios", "studio"), ("Projects", "project"), ("Other", nil)].compactMap { title, kind in
            let matching = shown.filter { place in kind.map { place.kind == $0 } ?? !["studio", "project"].contains(place.kind) }
            return matching.isEmpty ? nil : (title, matching)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if let problem {
                    Text(problem).foregroundStyle(.secondary)
                } else if places == nil {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading places…").foregroundStyle(.secondary) }
                } else if groups.isEmpty {
                    Text(search.isEmpty ? "No Studios or projects on the Mac yet." : "No places match.").foregroundStyle(.secondary)
                }
                ForEach(groups, id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.places, id: \.self) { place in row(place) }
                    }
                }
            }
            .navigationTitle("Choose a Place")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "Search places")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task {
                do { places = try await store.deskPlaces() }
                catch { problem = MobileDeskView.describe(error) }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ place: Companion.DeskPlace) -> some View {
        Button { pick(place); dismiss() } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: MobileDeskPlaces.icon(place)).foregroundStyle(.secondary).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(place.name).foregroundStyle(.primary)
                    if let detail = place.detail, !detail.isEmpty {
                        Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    }
                }
                Spacer(minLength: 0)
                if MobileDeskPlaces.same(current, place) {
                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor).accessibilityLabel("Current")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("desk-place-option-\(place.name)")
    }
}
