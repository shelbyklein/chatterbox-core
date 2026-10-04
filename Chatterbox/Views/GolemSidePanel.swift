#if GOLEM_APP
import SwiftUI
import AppKit

/// The column beside Golem's chat: Golem himself and how he's doing, then what he's been up
/// to (Activity), the decisions made along the way (Decisions), and what runs on its own
/// (Scheduled).
struct GolemSidePanel: View {
    let session: ChatSession
    @Environment(AppModel.self) private var model
    @AppStorage("golemPanelTab") private var tab = Tab.activity
    /// Off only for still renders (proof screenshots), which can't draw a scroll view.
    var scrolls = true
    var showsAvatar = true
    private let journal = GolemJournal.shared

    enum Tab: String, CaseIterable, Identifiable {
        case activity, decisions, scheduled
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var icon: String {
            switch self {
            case .activity: "list.bullet"
            case .decisions: "checkmark.shield"
            case .scheduled: "clock"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            tabs.padding(.horizontal, 14).padding(.bottom, 10)
            Divider()
            if scrolls {
                ScrollView { content }
            } else {
                content
                Spacer(minLength: 0)
            }
        }
        .task {while !Task.isCancelled{journal.refresh();if RuntimeClient.usesDaemon{await GolemServiceClient.shared.refresh()};try? await Task.sleep(for:.seconds(3))}}
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch tab {
            case .activity: activity
            case .decisions: decisions
            case .scheduled: scheduled
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Header

    private var mood: GolemAvatar.Mood { GolemAvatar.mood(of: session) }

    private var header: some View {
        VStack(spacing: 6) {
            Group {
                if !showsAvatar { Color.clear }
                else if GolemAvatar.shared.hasAnimations { GolemAnimated(mood: mood) } else { GolemHead(size: 40) }
            }
            .frame(width: 120, height: 120)
            Text(session.title).font(.title3.weight(.semibold))
            HStack(spacing: 5) {
                Circle().fill(statusColor).frame(width: 7, height: 7)
                Text(status).font(.callout).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
        .padding(.top, 18).padding(.bottom, 14)
        .frame(maxWidth: .infinity)
    }

    private var status: String {
        switch mood {
        case .waiting: "Waiting on you"
        case .thinking: "Working on a reply"
        case .news: "Has news for you"
        case .idle: "Ready"
        }
    }

    private var statusColor: Color {
        switch mood {
        case .waiting: .yellow
        case .thinking: .orange
        case .news: Color.highlight
        case .idle: .green
        }
    }

    private var tabs: some View {
        HStack(spacing: 4) {
            ForEach(Tab.allCases) { item in
                Button { tab = item } label: {
                    Image(systemName: item.icon)
                        .font(.system(size: 14, weight: .medium))
                        .frame(maxWidth: .infinity, minHeight: 28)
                        .background(RoundedRectangle(cornerRadius: 8).fill(tab == item ? Color.primary.opacity(0.12) : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(tab == item ? .primary : .secondary)
                .help(item.title)
                .accessibilityLabel(item.title)
                .accessibilityAddTraits(tab == item ? .isSelected : [])
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }

    // MARK: - Activity

    /// Question cards and approvals waiting in other chats, with Golem's suggestion if he made one.
    private var waiting: [(chat: ChatSession, item: DisplayItem)] {
        model.sessions.filter { !$0.isDot }.flatMap { chat in
            chat.items.filter { ($0.kind == .questions || $0.kind == .approval) && $0.approvalState == .pending }.map { (chat, $0) }
        }
    }

    @ViewBuilder
    private var activity: some View {
        let waiting = self.waiting
        if !waiting.isEmpty {
            section("Needs you") {
                ForEach(waiting, id: \.item.id) { entry in
                    Button { openChat(entry.chat.id) } label: {
                        row(icon: entry.item.kind == .approval ? "hand.raised" : "questionmark.bubble", tint: .yellow,
                            title: name(of: entry.chat),
                            detail: entry.item.kind == .approval ? "Waiting for your approval"
                                : entry.item.suggested != nil ? "\(session.title) suggested an answer \u{2014} one tap to send"
                                : (entry.item.questions ?? []).map(\.question).joined(separator: " / "),
                            date: nil)
                    }
                    .buttonStyle(.plain)
                    .help("Open \(name(of: entry.chat))")
                }
            }
        }
        section("Recent") {
            if journal.activity.isEmpty {
                empty("No activity yet", detail: "Check-ins, briefings, emails and suggested answers show up here.")
            }
            ForEach(journal.activity.prefix(100)) { entry($0, icon: icon(for: $0)) }
        }
    }

    private func icon(for entry: GolemJournal.Entry) -> String {
        if entry.title.hasPrefix("Email") { return "envelope" }
        if entry.title.hasPrefix("Suggested") { return "text.bubble" }
        if entry.title.localizedCaseInsensitiveContains("waiting") { return "bell" }
        if entry.title.localizedCaseInsensitiveContains("finished") { return "checkmark.circle" }
        return "sparkles"
    }

    // MARK: - Decisions

    @ViewBuilder
    private var decisions: some View {
        if journal.decisions.isEmpty {
            empty("No decisions yet", detail: "When you send or change an answer \(session.title) suggested, or he logs a decision, it's kept here.")
        }
        ForEach(journal.decisions.prefix(150)) { entry($0, icon: "checkmark.shield") }
    }

    // MARK: - Scheduled

    @ViewBuilder
    private var scheduled: some View {
        let service=GolemServiceClient.shared
        section("Runs on its own") {
            schedule(icon: "envelope", title: "Email watch", on: AppPreferences.defaults.object(forKey:"dotEmailWatch") as? Bool ?? true,
                     detail: service.sweeping ? "Reading your mail now\u{2026}"
                        : "Every 15 minutes, 9 to 5; every 30 otherwise."
                        + (service.emailThrough.map { " Read through \($0.formatted(.relative(presentation: .named)))." } ?? ""),
                     problem: service.problem)
            schedule(icon: "sun.max", title: "Check-ins", on: AppPreferences.defaults.object(forKey:"dotCheckIns") as? Bool ?? true,
                     detail: "Weekdays at " + service.checkInTimes.map(Self.clock).joined(separator: " and ")
                        + (nextCheckIn.map { ". Next \($0.formatted(.relative(presentation: .named)))." } ?? "."), problem: nil)
        }
        section("When things happen") {
            schedule(icon: "bell", title: "Chats waiting on you", on: AppPreferences.defaults.object(forKey:"dotWatchWaiting") as? Bool ?? true,
                     detail: "Briefs you when another chat asks a question or needs approval, and suggests an answer when he can.", problem: nil)
            schedule(icon: "checkmark.circle", title: "Finished work", on: AppPreferences.defaults.object(forKey:"dotSummarizeFinished") as? Bool ?? true,
                     detail: "Summarizes real work when a chat finishes.", problem: nil)
        }
        Text("Change these in Settings \u{2192} \(session.title).").font(.caption).foregroundStyle(.secondary)
    }

    private var nextCheckIn: Date? {
        let calendar = Calendar.current
        let now = Date()
        for day in 0..<8 {
            guard let date = calendar.date(byAdding: .day, value: day, to: calendar.startOfDay(for: now)),
                  !calendar.isDateInWeekend(date) else { continue }
            for minutes in GolemServiceClient.shared.checkInTimes.sorted() {
                if let time = calendar.date(byAdding: .minute, value: minutes, to: date), time > now { return time }
            }
        }
        return nil
    }

    private static func clock(_ minutes: Int) -> String {
        var parts = DateComponents()
        parts.hour = minutes / 60
        parts.minute = minutes % 60
        return Calendar.current.date(from: parts)?.formatted(date: .omitted, time: .shortened) ?? "\(minutes / 60):\(minutes % 60)"
    }

    private func schedule(icon: String, title: String, on: Bool, detail: String, problem: String?) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).frame(width: 18).foregroundStyle(on ? Color.highlight : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(title).font(.callout.weight(.medium))
                    Spacer()
                    Text(on ? "On" : "Off").font(.caption.weight(.semibold)).foregroundStyle(on ? .green : .secondary)
                }
                Text(on ? detail : "Off.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let problem, on {
                    Label(problem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Pieces

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    private func openChat(_ id:UUID) {
        if !NSWorkspace.shared.open(URL(string:"chatterbox://chat/\(id)")!) {
            let alert=NSAlert();alert.messageText="Chatterbox is unavailable"
            alert.informativeText="Install Chatterbox to open this conversation.";alert.runModal()
        }
    }

    private func entry(_ entry: GolemJournal.Entry, icon: String) -> some View {
        Group {
            if let id = entry.chat, model.sessions.contains(where: { $0.id == id }) {
                Button {
                    if model.dot?.id==id{model.openDot()}
                    else{openChat(id)}
                } label: {
                    row(icon: icon, tint: Color.highlight, title: entry.title, detail: entry.detail, chat: entry.chatName, date: entry.date)
                }
                .buttonStyle(.plain)
                .help("Open \(entry.chatName ?? "the chat")")
            } else {
                row(icon: icon, tint: Color.highlight, title: entry.title, detail: entry.detail, chat: entry.chatName, date: entry.date)
            }
        }
    }

    private func row(icon: String, tint: Color, title: String, detail: String?, chat: String? = nil, date: Date?) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).frame(width: 18).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.callout.weight(.medium)).lineLimit(2)
                    Spacer(minLength: 6)
                    if let date {
                        Text(Date().timeIntervalSince(date) < 60 ? "now" : date.formatted(.relative(presentation: .numeric, unitsStyle: .narrow)))
                            .font(.caption2).foregroundStyle(.tertiary).fixedSize()
                    }
                }
                if let chat { Text(chat).font(.caption.weight(.medium)).foregroundStyle(.secondary).lineLimit(1) }
                if let detail, !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func empty(_ title: String, detail: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: tab.icon).font(.title2).foregroundStyle(.secondary)
            Text(title).font(.callout.weight(.medium))
            Text(detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private func name(of chat: ChatSession) -> String {
        chat.record.projectFolder != nil ? chat.projectName : chat.title
    }
}

#endif
