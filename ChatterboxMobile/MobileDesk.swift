import SwiftUI

// The Desk on the phone: what needs you, incoming work to place, what is working. plans/front-desk.md

/// The home's first tab. What needs you (approve or deny in place, open, or swipe left to
/// silence), requests waiting to be placed (start where the Desk proposes, or choose another
/// place), and one quiet line of what's working. The Desk never does work itself: starting a
/// request opens a session in its Studio or project, through the same path as a tapped
/// notification. Wide (an iPad, an open iPhone Duo), the cards go in two columns.
struct MobileDeskView: View {
    @Environment(MobileStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @State private var ask = ""
    @State private var adding = false
    @FocusState private var asking: Bool
    /// Waiting items and requests acted on here, hidden until the Desk stops listing them.
    @State private var settled = Set<UUID>()
    /// Waiting things being silenced (silenceKey), hidden until the Mac answers.
    @State private var silencing = Set<String>()
    /// The Desk's width: two columns of cards when one would be wider than a card should be.
    @State private var width: CGFloat = 0
    @State private var busy = Set<UUID>()
    /// Places picked with Change Place, per request; Start There uses them.
    @State private var chosen: [UUID: Companion.DeskPlace] = [:]
    @State private var choosing: Companion.DeskRequest?
    /// Why the Desk couldn't be read, shown until it can.
    @State private var loadProblem: String?
    /// An action that didn't go through.
    @State private var actionProblem: String?
    @State private var showingAutomations = false
    /// A run's session picked in Automations: opened once the sheet has closed.
    @State private var automationPick: UUID?

    /// What the Desk's tab counts, as of its last answer: what needs you and requests
    /// waiting to be placed.
    static func waiting(_ desk: Companion.Desk) -> Int { desk.needsYou.count + desk.incoming.count }

    /// Wider than this, a card would be too wide alone: two columns.
    static let twoColumnWidth: CGFloat = 560
    static func columns(for width: CGFloat) -> Int { width - 32 > twoColumnWidth ? 2 : 1 }

    /// What silencing hides: the item, or for a reply (its id is the session's) the question it asks.
    static func silenceKey(_ item: Companion.DeskWaiting) -> String {
        "\(item.chatID.uuidString)|\(item.id.uuidString)|\(item.kind == "reply" ? item.text : "")"
    }

    private var desk: Companion.Desk? { store.latestDesk }
    private var needsYou: [Companion.DeskWaiting] {
        (desk?.needsYou ?? []).filter { !settled.contains($0.id) && !silencing.contains(Self.silenceKey($0)) }
    }
    private var incoming: [Companion.DeskRequest] { (desk?.incoming ?? []).filter { !settled.contains($0.id) } }
    private var working: [Companion.DeskWorking] { desk?.working ?? [] }

    private var columns: Int { Self.columns(for: width) }

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
                // One readable column; two side by side on an iPad or an open iPhone Duo.
                .frame(maxWidth: columns > 1 ? 1240 : 760, alignment: .leading)
                .frame(maxWidth: .infinity)
                .animation(.easeOut(duration: 0.2), value: needsYou.map(\.id) + incoming.map(\.id))
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .background(Color(uiColor: .systemGroupedBackground))
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Desk")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                // Every project's routines, to change or run (MobileAutomations.swift).
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingAutomations = true } label: { Image(systemName: "clock.arrow.circlepath") }
                        .accessibilityLabel("Automations")
                        .accessibilityIdentifier("desk-automations")
                }
                ToolbarItem(placement: .topBarTrailing) { FeedbackButton() }
            }
            .refreshable { await refresh() }
        }
        .sheet(isPresented: $showingAutomations, onDismiss: {
            if let id = automationPick { automationPick = nil; open(id) }
        }) { MobileAutomationsView { automationPick = $0 }.environment(store) }
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
                DeskWaitingCard(item: item, busy: busy.contains(item.id), fill: columns > 1,
                                open: { open(item.chatID) },
                                decide: { decide($0, item) },
                                silence: { silence(item) })
            }
        }
    }

    private var incomingSection: some View {
        section("Incoming", id: "incoming") {
            ForEach(incoming) { request in
                DeskRequestCard(request: request, place: place(for: request), changed: chosen[request.id] != nil,
                                busy: busy.contains(request.id), fill: columns > 1,
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
                        .accessibilityLabel("\(item.title)\(item.subtitle.map { ", " + $0 } ?? ""), working\(item.place.flatMap { $0 != item.title ? ", in \($0)" : nil } ?? "")")
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
            if columns > 1 {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: columns),
                          alignment: .leading, spacing: 10) { content() }
            } else {
                VStack(alignment: .leading, spacing: 10) { content() }
            }
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

    /// Silence: off the Desk on every device, without answering it; it stays waiting in its
    /// session, and something new from it shows again.
    private func silence(_ item: Companion.DeskWaiting) {
        let key = Self.silenceKey(item)
        guard silencing.insert(key).inserted else { return }
        Task {
            defer { silencing.remove(key) }
            do {
                _ = try await store.silenceDesk(item)
            } catch let error as MobileError where error.status == 404 {
                actionProblem = "Silencing needs the newest Chatterbox on the Mac. Update it there to use it."
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

/// A session waiting on you: what it asks; approve or deny in place, open it, or swipe it left
/// (or long-press it) to silence it.
private struct DeskWaitingCard: View {
    let item: Companion.DeskWaiting
    let busy: Bool
    /// In two columns: as tall as its row.
    var fill = false
    let open: () -> Void
    let decide: (String) -> Void
    let silence: () -> Void

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
        SwipeToSilence(id: item.id.uuidString, silence: silence) { taps in card(taps) }
    }

    /// The card; its buttons go through `taps`, so letting go of a swipe doesn't press them.
    private func card(_ taps: DeskSwipeTaps) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: taps(open)) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Label(kind.title, systemImage: kind.icon)
                            .font(.caption.weight(.semibold)).foregroundStyle(.yellow)
                        Spacer(minLength: 8)
                        if let place = item.place, place != item.title { DeskPlaceTag(name: place) }
                    }
                    Text(item.title).font(.headline).lineLimit(2).multilineTextAlignment(.leading)
                    // A project's session: its own title under the project's name.
                    if let subtitle = item.subtitle {
                        Text(subtitle).font(.subheadline.weight(.medium)).lineLimit(2).multilineTextAlignment(.leading)
                            .accessibilityIdentifier("desk-subtitle-\(item.id.uuidString)")
                    }
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
            .accessibilityAction(named: "Silence", silence)
            .accessibilityIdentifier("desk-waiting-\(item.id.uuidString)")
            HStack(spacing: 8) {
                if busy {
                    ProgressView().controlSize(.small)
                    Text("Sending…").font(.footnote).foregroundStyle(.secondary)
                } else if decides {
                    Button("Approve", action: taps { decide("approved") })
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("desk-approve-\(item.id.uuidString)")
                    Button("Deny", role: .destructive, action: taps { decide("denied") })
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("desk-deny-\(item.id.uuidString)")
                } else {
                    Button("Open", action: taps(open))
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("desk-open-\(item.id.uuidString)")
                }
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: fill ? .infinity : nil, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(uiColor: .secondarySystemGroupedBackground)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.yellow.opacity(0.5), lineWidth: 1.5))
        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contextMenu {
            Button("Open", systemImage: "arrow.up.forward.square", action: open)
            Button("Silence", systemImage: "bell.slash", action: silence)
        }
    }
}

/// Whether a card's button may act: not while it's swiped, nor as the swipe lets go (a
/// button under the finger would otherwise take the release as a tap).
final class DeskSwipeTaps {
    fileprivate var swiping = false
    fileprivate var open = false
    fileprivate var endedAt = Date.distantPast
    var allowed: Bool { !swiping && !open && Date().timeIntervalSince(endedAt) > 0.35 }
    /// The action, when a tap is a tap.
    func callAsFunction(_ action: @escaping () -> Void) -> () -> Void {
        { [weak self] in if self?.allowed ?? true { action() } }
    }
}

/// Swipe a card left to show Silence, or all the way to silence it, as a list row's swipe
/// actions do (the Desk is a scroll view of cards, not a list). A tap on an open card closes it.
private struct SwipeToSilence<Content: View>: View {
    let id: String
    let silence: () -> Void
    @ViewBuilder let content: (DeskSwipeTaps) -> Content
    @State private var taps = DeskSwipeTaps()
    /// How far the card is moved left (negative), and where it rests (0 or open).
    @State private var offset: CGFloat = 0
    @State private var resting: CGFloat = 0
    /// Decided once per drag: sideways swipes the card, up and down scrolls.
    @State private var sideways: Bool?
    @State private var width: CGFloat = 0
    /// Past the point where letting go silences it.
    @State private var armed = false
    /// How far an open card moves, and the space between it and Silence.
    private let reveal: CGFloat = 96
    private let gap: CGFloat = 8
    private var commit: CGFloat { max(reveal + 70, width * 0.5) }

    var body: some View {
        content(taps)
            .overlay {
                if resting < 0 { Color.clear.contentShape(Rectangle()).onTapGesture(perform: close) }
            }
            .offset(x: offset)
            .background(alignment: .trailing) { if offset < 0 { button } }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .simultaneousGesture(drag)
            .sensoryFeedback(.impact(weight: .medium), trigger: armed) { _, now in now }
    }

    private var button: some View {
        Button(action: silenceNow) {
            VStack(spacing: 4) {
                Image(systemName: "bell.slash.fill").font(.title3)
                Text("Silence").font(.caption.weight(.semibold))
            }
            .foregroundStyle(.white)
            .frame(width: reveal - gap)
            .frame(width: max(reveal, -offset) - gap, alignment: armed ? .leading : .center)
            .frame(maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.indigo))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("desk-silence-\(id)")
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 14)
            .onChanged { value in
                if sideways == nil { sideways = abs(value.translation.width) > abs(value.translation.height) * 1.2 }
                guard sideways == true else { return }
                taps.swiping = true
                let x = min(0, resting + value.translation.width)
                offset = x
                armed = -x > commit
            }
            .onEnded { value in
                defer { sideways = nil }
                guard sideways == true else { return }
                taps.swiping = false
                taps.endedAt = Date()
                let x = resting + value.translation.width
                if -x > commit {
                    silenceNow()
                } else if -x > reveal / 2 || -(resting + value.predictedEndTranslation.width) > reveal {
                    withAnimation(.spring(duration: 0.25)) { offset = -reveal; resting = -reveal }
                    taps.open = true
                    armed = false
                } else {
                    close()
                }
            }
    }

    private func close() {
        withAnimation(.spring(duration: 0.25)) { offset = 0; resting = 0 }
        taps.open = false
        armed = false
    }

    /// Slides off, then goes; back in place if it's still here (it didn't go through).
    private func silenceNow() {
        withAnimation(.easeOut(duration: 0.2)) { offset = -(width + 40) }
        resting = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            silence()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { close() }
        }
    }
}

/// Work waiting to be placed: where the Desk proposes it goes, and why.
private struct DeskRequestCard: View {
    let request: Companion.DeskRequest
    let place: Companion.DeskPlace?
    /// Picked here with Change Place, instead of the Desk's proposal.
    let changed: Bool
    let busy: Bool
    /// In two columns: as tall as its row.
    var fill = false
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
        .frame(maxWidth: .infinity, maxHeight: fill ? .infinity : nil, alignment: .topLeading)
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
