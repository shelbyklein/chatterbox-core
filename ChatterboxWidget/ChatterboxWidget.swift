import SwiftUI
import WidgetKit
import AppIntents

/// The Chatterbox widget: chats waiting on you, new replies and chats working now, from the
/// snapshot the app saves (see WidgetSnapshot). Each row opens its chat.
@main
struct ChatterboxWidgets: WidgetBundle {
    var body: some Widget {
        ChatterboxWidget()
        ChatterboxUsageWidget()
        ChatterboxNewChatWidget()
    }
}

struct NewChatEntry: TimelineEntry {
    var date: Date
    var provider: WidgetChatShortcut
}

struct NewChatProvider: TimelineProvider {
    func placeholder(in context: Context) -> NewChatEntry { .init(date: .now, provider: .codex) }
    func getSnapshot(in context: Context, completion: @escaping (NewChatEntry) -> Void) {
        completion(.init(date: .now, provider: WidgetChatShortcut.selected()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<NewChatEntry>) -> Void) {
        completion(Timeline(entries: [.init(date: .now, provider: WidgetChatShortcut.selected())], policy: .never))
    }
}

struct ChatterboxNewChatWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetChatShortcut.widgetKind, provider: NewChatProvider()) { entry in
            ChatterboxNewChatWidgetView(selection: entry.provider)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("New Chat")
        .description("Choose Claude or Codex, then tap New chat to start typing.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct ChatterboxNewChatWidgetView: View {
    let selection: WidgetChatShortcut
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var colorScheme

    private func accent(_ shortcut: WidgetChatShortcut) -> Color {
        if colorScheme == .dark { return shortcut == .codex ? .blue : .orange }
        return shortcut == .codex ? Color(red: 0, green: 0.26, blue: 0.6) : Color(red: 0.53, green: 0.22, blue: 0.02)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Link(destination: WidgetChatShortcut.fieldLink) {
                HStack(spacing: 10) {
                    if family != .systemSmall {
                        Image(systemName: "square.and.pencil").foregroundStyle(accent(selection))
                    }
                    Text("New chat…").foregroundStyle(.primary).lineLimit(1).minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                }
                .font(.subheadline)
                .padding(.horizontal, family == .systemSmall ? 10 : 16)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(.quaternary, in: Capsule())
                .contentShape(Capsule())
            }
            .accessibilityLabel("New chat with \(selection.title), \(selection.modelTitle), Medium effort")
            .accessibilityIdentifier("widget-new-chat-field")

            HStack(spacing: 8) {
                ForEach([WidgetChatShortcut.claude, .codex]) { provider in
                    Button(intent: SelectWidgetProviderIntent(provider: provider)) {
                        Text(provider.title)
                            .font(family == .systemSmall ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
                            .lineLimit(1).minimumScaleFactor(0.8)
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(selection == provider ? accent(provider).opacity(0.18) : Color.clear, in: Capsule())
                            .overlay(Capsule().strokeBorder(selection == provider ? accent(provider) : Color.primary.opacity(0.5), lineWidth: selection == provider ? 1.5 : 1))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Select \(provider.title)")
                    .accessibilityValue(selection == provider ? "Selected" : "Not selected")
                    .accessibilityAddTraits(selection == provider ? .isSelected : [])
                    .accessibilityIdentifier("widget-provider-\(provider.rawValue)")
                }
            }
            Text(family == .systemSmall ? selection.modelTitle : "\(selection.modelTitle) · Medium")
                .font(.caption2).foregroundStyle(.primary).lineLimit(1)
                .accessibilityLabel("\(selection.modelTitle) · Medium")
                .accessibilityIdentifier("widget-selected-model")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        // Small widgets have one default URL; intent buttons take precedence over it.
        .widgetURL(family == .systemSmall ? WidgetChatShortcut.fieldLink : nil)
    }
}

/// Separate from activity so account quotas can use the whole Home Screen widget.
struct ChatterboxUsageWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ChatterboxUsage", provider: SnapshotProvider()) { entry in
            ChatterboxUsageWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Usage")
        .description("Claude and Codex usage for every connected account. Choose Large for all limit windows.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct ChatterboxUsageWidgetView: View {
    let entry: SnapshotEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.dynamicTypeSize) private var typeSize
    private var usage: WidgetSnapshot.Usage? { entry.snapshot.usage }

    var body: some View {
        VStack(alignment: .leading, spacing: family == .systemLarge ? 8 : 4) {
            HStack {
                Text("Usage").font(family == .systemSmall ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
                Spacer(minLength: 4)
                Text(family == .systemMedium ? "Highest limit · % used" : "% used").font(.caption2).foregroundStyle(.secondary)
            }
            if family == .systemSmall {
                Text("Highest reported limit").font(.caption2).foregroundStyle(.secondary)
                providerSummary("Claude", provider: "claude")
                providerSummary("Codex", provider: "codex")
            } else {
                if family == .systemLarge {
                    Text("Account limits").font(.caption2).foregroundStyle(.secondary)
                }
                if family == .systemMedium {
                    // The usual pool fits as one compact row per account. ViewThatFits can
                    // reject this column's ideal size even when its proposed size fits.
                    let rows = max(accounts("claude").count + (direct("claude").isEmpty ? 0 : 1),
                                   accounts("codex").count + (direct("codex").isEmpty ? 0 : 1))
                    if rows <= 4, typeSize <= .large {
                        columns(detailed: false)
                    } else {
                        overflowSummary
                    }
                } else {
                  ViewThatFits(in: .vertical) {
                    if family == .systemLarge {
                        columns(detailed: true).fixedSize(horizontal: false, vertical: true)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        columns(detailed: false)
                        if family == .systemLarge {
                            Text("Summary · open Usage for every limit").font(.caption2).foregroundStyle(.secondary)
                                .accessibilityIdentifier("usage-overflow")
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    overflowSummary
                  }
                }
            }
            Spacer(minLength: 0)
            freshness
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(URL(string: "\(Flavor.current.urlScheme)://usage")!)
    }

    private var overflowSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            providerSummary("Claude", provider: "claude")
            providerSummary("Codex", provider: "codex")
            Text("More accounts and limits in Usage").font(.caption2).foregroundStyle(.secondary)
                .accessibilityIdentifier("usage-overflow")
        }
    }

    private func accounts(_ provider: String) -> [WidgetSnapshot.Usage.Account] {
        usage?.proxyAccounts?.filter { $0.provider == provider } ?? []
    }

    private func direct(_ provider: String) -> [WidgetSnapshot.Usage.Window] {
        provider == "claude" ? usage?.claude ?? [] : usage?.codex ?? []
    }

    private func columns(detailed: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            providerColumn("Claude", provider: "claude", detailed: detailed)
            providerColumn("Codex", provider: "codex", detailed: detailed)
        }
    }

    private func providerColumn(_ name: String, provider: String, detailed: Bool) -> some View {
        let list = accounts(provider)
        let reported = direct(provider)
        return VStack(alignment: .leading, spacing: detailed ? 8 : 4) {
            Text(list.isEmpty ? name : "\(name) · \(list.count)").font(.caption.weight(.semibold))
            ForEach(Array(list.enumerated()), id: \.offset) { index, account in
                accountView(account, detailed: detailed)
                    .accessibilityIdentifier("usage-account-\(provider)-\(index)")
            }
            if !reported.isEmpty {
                Group {
                    if detailed {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Chat reported").font(.caption2).foregroundStyle(.secondary)
                            ForEach(Array(reported.enumerated()), id: \.offset) { _, window in windowRow(window) }
                        }
                    } else {
                        compactAccountView(.init(provider: provider, name: "Chat reported", status: "Available", windows: reported))
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("usage-direct-\(provider)")
            } else if list.isEmpty {
                Text(usage?.proxyRefreshing == true ? "Checking quotas…" : "Not reported")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func accountView(_ account: WidgetSnapshot.Usage.Account, detailed: Bool) -> some View {
        let tightest = account.status == "Disabled" ? nil : account.tightest(at: entry.date)
        return VStack(alignment: .leading, spacing: 0) {
            if !detailed {
                compactAccountView(account)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(account.name).font(.caption2.weight(.medium)).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                        if account.status != "Available" {
                            Text(account.status).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    if !account.windows.isEmpty {
                        ForEach(Array(account.windows.enumerated()), id: \.offset) { _, window in windowRow(window) }
                    } else {
                        Text(account.status == "Unavailable" || account.problem != nil ? "Quota unavailable"
                             : account.status == "Disabled" ? "Disabled" : "No limits reported")
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accountLabel(account, detailed: detailed, tightest: tightest))
    }

    private func compactAccountView(_ account: WidgetSnapshot.Usage.Account) -> some View {
        let tightest = account.status == "Disabled" ? nil : account.tightest(at: entry.date)
        return HStack(spacing: 4) {
            Text(account.name).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
            if let tightest {
                Text(tightest.compactLabel).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: 40)
                Text(percent(tightest)).monospacedDigit().fixedSize(horizontal: true, vertical: false)
                bar(tightest).frame(width: 28)
            } else {
                Text(account.status == "Available" ? "Unknown" : account.status).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .font(.caption2)
        .accessibilityElement(children: .combine)
    }

    private func accountLabel(_ account: WidgetSnapshot.Usage.Account, detailed: Bool, tightest: WidgetSnapshot.Usage.Window?) -> String {
        let windows = detailed ? account.windows : tightest.map { [$0] } ?? []
        return ([account.name, account.status] + windows.map { $0.text(at: entry.date) + " used" }).joined(separator: ", ")
    }

    private func windowRow(_ window: WidgetSnapshot.Usage.Window) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .top, spacing: 4) {
                Text(window.compactLabel).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 0)
                Text(percent(window)).font(.caption2.monospacedDigit()).fixedSize(horizontal: true, vertical: false)
            }
            bar(window)
        }
    }

    private func percent(_ window: WidgetSnapshot.Usage.Window?) -> String {
        window?.usedFraction(at: entry.date).map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
    }

    @ViewBuilder private func bar(_ window: WidgetSnapshot.Usage.Window) -> some View {
        if let used = window.usedFraction(at: entry.date) {
            ProgressView(value: used, total: 1).progressViewStyle(.linear)
                .tint(used >= 0.9 ? .red : used >= 0.75 ? .orange : .accentColor)
                .frame(maxWidth: .infinity).frame(height: 3).accessibilityHidden(true)
        }
    }

    private func providerSummary(_ name: String, provider: String) -> some View {
        let list = accounts(provider)
        let windows = list.filter { $0.status != "Disabled" }.flatMap(\.windows) + direct(provider)
        let highest = windows.filter { $0.usedFraction(at: entry.date) != nil }
            .max { ($0.usedFraction(at: entry.date) ?? 0) < ($1.usedFraction(at: entry.date) ?? 0) }
        let reported = list.filter { $0.tightest(at: entry.date) != nil }.count
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(name).font(.caption.weight(.medium))
                Spacer(minLength: 4)
                Text(percent(highest)).font(.caption.monospacedDigit())
            }
            if let highest { bar(highest) }
            Text(list.isEmpty ? (highest == nil ? "Not reported" : "Chat reported") : "\(reported) of \(list.count) accounts reported")
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("usage-summary-\(provider)")
    }

    private var freshness: some View {
        VStack(alignment: .leading, spacing: 1) {
            if usage?.proxyRefreshing == true {
                Text("Checking quotas…").accessibilityIdentifier("usage-checking")
            } else if usage?.proxyProblem != nil {
                Text("Quota check unavailable").foregroundStyle(.orange)
            }
            if let checked = usage?.proxyChecked {
                HStack(spacing: 3) { Text("Quota checked"); Text(checked, style: .relative) }
            } else if let synced = usage?.syncedAt {
                HStack(spacing: 3) { Text("Synced"); Text(synced, style: .relative) }
            } else {
                Text("Open Chatterbox to sync usage")
            }
        }
        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        .accessibilityElement(children: .combine).accessibilityIdentifier("usage-freshness")
    }
}

struct ChatterboxWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ChatterboxActivity", provider: SnapshotProvider()) { entry in
            ChatterboxWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Chatterbox")
        .description("What's waiting on you, new replies and work in progress.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryCircular, .accessoryRectangular])
    }
}

struct SnapshotEntry: TimelineEntry {
    var date: Date
    var snapshot: WidgetSnapshot
}

struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry { SnapshotEntry(date: .now, snapshot: .sample) }
    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(SnapshotEntry(date: .now, snapshot: context.isPreview ? .sample : WidgetSnapshot.load()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        // The app reloads the widget when its snapshot changes; this just keeps ages fresh.
        let entry = SnapshotEntry(date: .now, snapshot: WidgetSnapshot.load())
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(15 * 60))))
    }
}

/// One row: what state it's in, the chat, and when.
private struct Row: Identifiable {
    enum State { case waiting, reply, working }
    var state: State
    var item: WidgetSnapshot.Item
    var id: String { "\(state)-\(item.chatID)" }
}

struct ChatterboxWidgetView: View {
    let entry: SnapshotEntry
    @Environment(\.widgetFamily) private var family
    private var snapshot: WidgetSnapshot { entry.snapshot }

    private var rows: [Row] { attention + workingRows }
    /// Waiting on you and new replies: what needs you, first.
    private var attention: [Row] {
        snapshot.waiting.map { Row(state: .waiting, item: $0) } + snapshot.newReplies.map { Row(state: .reply, item: $0) }
    }
    /// Chats working now. Only the app writes the snapshot, so after half an hour without it
    /// they may well have finished: left out rather than shown as working.
    private var workingRows: [Row] {
        guard entry.date.timeIntervalSince(snapshot.updatedAt) < 1800 else { return [] }
        return snapshot.working.map { Row(state: .working, item: $0) }
    }
    private var needsYou: Int { snapshot.waiting.count + snapshot.newReplies.count }
    private var stale: Bool { entry.date.timeIntervalSince(snapshot.updatedAt) > 3600 && snapshot.updatedAt != .distantPast }

    var body: some View {
        switch family {
        case .accessoryCircular: circular
        case .accessoryRectangular: rectangular
        case .systemSmall: small
        case .systemLarge: list(limit: 6)
        default: list(limit: 2, compactWorking: true)
        }
    }

    // MARK: Lock Screen

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                Image(systemName: snapshot.waiting.isEmpty ? "bubble.left.and.text.bubble.right" : "questionmark.bubble")
                    .font(.caption)
                Text("\(needsYou)").font(.title3.weight(.semibold)).monospacedDigit()
            }
        }
        .widgetURL(rows.first?.item.link)
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(summaryLine).font(.headline).lineLimit(1)
            if let first = rows.first {
                Text(first.item.title).lineLimit(1)
                Text(first.item.date, style: .relative).font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("All caught up").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(rows.first?.item.link)
    }

    // MARK: Home Screen

    private var small: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            Spacer(minLength: 0)
            if let first = rows.first {
                Text(label(first.state)).font(.caption2.weight(.semibold)).foregroundStyle(color(first))
                Text(first.item.title).font(.subheadline.weight(.semibold)).lineLimit(2)
            } else {
                caughtUp
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(rows.first?.item.link)
    }

    /// What needs you first, then what's working: in its own rows when there's room, or one
    /// line naming them (`compactWorking`), so working chats never fall off the end.
    private func list(limit: Int, compactWorking: Bool = false) -> some View {
        let working = workingRows
        let workingSpace = working.isEmpty ? 0 : compactWorking ? 1 : min(working.count, max(2, limit - attention.count))
        let shown = Array(attention.prefix(limit - workingSpace))
        let hidden = attention.count - shown.count + (compactWorking ? 0 : working.count - min(working.count, workingSpace))
        return VStack(alignment: .leading, spacing: 6) {
            header
            if attention.isEmpty && working.isEmpty {
                Spacer(minLength: 0)
                caughtUp
                Spacer(minLength: 0)
            } else {
                ForEach(shown) { row in
                    Link(destination: row.item.link) { rowView(row) }
                }
                if !working.isEmpty {
                    if compactWorking {
                        workingLine(working)
                    } else {
                        ForEach(working.prefix(workingSpace)) { row in
                            Link(destination: row.item.link) { rowView(row) }
                        }
                    }
                }
                if hidden > 0 {
                    Text("\(hidden) more in Chatterbox").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// "Working: Galley, Coach Archie" in one row; opens the first.
    private func workingLine(_ working: [Row]) -> some View {
        Link(destination: working[0].item.link) {
            HStack(spacing: 8) {
                Image(systemName: symbol(.working)).font(.caption.weight(.semibold))
                    .foregroundStyle(color(working[0])).frame(width: 16)
                (Text("Working ").font(.subheadline.weight(.semibold))
                 + Text(working.map(\.item.title).joined(separator: ", ")).font(.subheadline).foregroundStyle(.secondary))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
        }
    }

    private func rowView(_ row: Row) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol(row.state)).font(.caption.weight(.semibold))
                .foregroundStyle(color(row)).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.item.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                if let detail = row.item.detail, !detail.isEmpty, family == .systemLarge {
                    Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Text(row.item.date, style: .relative).font(.caption2).foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing).frame(maxWidth: 64, alignment: .trailing)
        }
    }

    private var header: some View {
        HStack(spacing: 4) {
            Text(summaryLine).font(.caption.weight(.semibold)).lineLimit(1)
            Spacer(minLength: 0)
            if stale {
                Text(snapshot.updatedAt, style: .relative).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.secondary)
    }

    private var caughtUp: some View {
        Label("All caught up", systemImage: "checkmark.circle").font(.subheadline).foregroundStyle(.secondary)
    }

    private var summaryLine: String {
        var parts: [String] = []
        if !snapshot.waiting.isEmpty { parts.append("\(snapshot.waiting.count) waiting") }
        if !snapshot.newReplies.isEmpty { parts.append("\(snapshot.newReplies.count) new") }
        if !workingRows.isEmpty { parts.append("\(workingRows.count) working") }
        return parts.isEmpty ? "Chatterbox" : parts.joined(separator: " · ")
    }

    private func label(_ state: Row.State) -> String {
        switch state { case .waiting: "Waiting on you"; case .reply: "New reply"; case .working: "Working" }
    }
    private func symbol(_ state: Row.State) -> String {
        switch state { case .waiting: "questionmark.bubble.fill"; case .reply: "circle.fill"; case .working: "ellipsis" }
    }
    private func color(_ row: Row) -> Color {
        switch row.state {
        case .waiting: .orange
        case .reply: .blue
        case .working: row.item.backend == "codex" ? Color(red: 0.06, green: 0.64, blue: 0.5) : Color(red: 0.85, green: 0.47, blue: 0.34)
        }
    }
}

extension WidgetSnapshot {
    /// Shown in the widget gallery and while it first loads.
    static let sample = WidgetSnapshot(
        updatedAt: .now, macName: "Mac",
        waiting: [.init(chatID: UUID(), title: "SDHQ", detail: "Which plugin should I update first?", backend: "claude", date: .now.addingTimeInterval(-300))],
        newReplies: [.init(chatID: UUID(), title: "Spoolside", detail: "Both changes are live.", backend: "claude", date: .now.addingTimeInterval(-900)),
                     .init(chatID: UUID(), title: "Event Logos", detail: "Here are four ribbon concepts.", backend: "codex", date: .now.addingTimeInterval(-2400))],
        working: [.init(chatID: UUID(), title: "Vispix", detail: nil, backend: "codex", date: .now.addingTimeInterval(-120))],
        usage: .init(syncedAt: .now,
                     claude: [.init(label: "5-hour", fraction: 0.42, resetsAt: nil), .init(label: "7-day", fraction: 0.81, resetsAt: nil)],
                     codex: [.init(label: "5-hour", fraction: 0.12, resetsAt: nil)],
                     proxyAccounts: [
                        .init(provider: "claude", name: "Claude Personal", status: "Limited", windows: [
                            .init(label: "5-hour window", fraction: 1, resetsAt: nil), .init(label: "7-day window", fraction: 0.6, resetsAt: nil)]),
                        .init(provider: "claude", name: "Claude Work", status: "Available", windows: [
                            .init(label: "5-hour window", fraction: 0.3, resetsAt: nil), .init(label: "7-day window", fraction: 0.2, resetsAt: nil),
                            .init(label: "7-day Sonnet", fraction: 0.1, resetsAt: nil)]),
                        .init(provider: "codex", name: "Codex One", status: "Unavailable", windows: [], problem: "Quota lookup unavailable"),
                        .init(provider: "codex", name: "Codex Two", status: "Unavailable", windows: [], problem: "Quota lookup unavailable"),
                        .init(provider: "codex", name: "Codex Three", status: "Available", windows: [.init(label: "5-hour window", fraction: 0.35, resetsAt: nil)])
                     ], proxyChecked: .now, proxyRefreshing: false))
}
