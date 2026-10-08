import SwiftUI
import WidgetKit

/// The Chatterbox widget: chats waiting on you, new replies and chats working now, from the
/// snapshot the app saves (see WidgetSnapshot). Each row opens its chat.
@main
struct ChatterboxWidgets: WidgetBundle {
    var body: some Widget { ChatterboxWidget() }
}

struct ChatterboxWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ChatterboxActivity", provider: SnapshotProvider()) { entry in
            ChatterboxWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Chatterbox")
        .description("What's waiting on you, new replies and chats working now.")
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

    private var rows: [Row] {
        snapshot.waiting.map { Row(state: .waiting, item: $0) }
            + snapshot.newReplies.map { Row(state: .reply, item: $0) }
            + snapshot.working.map { Row(state: .working, item: $0) }
    }
    private var needsYou: Int { snapshot.waiting.count + snapshot.newReplies.count }
    private var stale: Bool { entry.date.timeIntervalSince(snapshot.updatedAt) > 3600 && snapshot.updatedAt != .distantPast }

    var body: some View {
        switch family {
        case .accessoryCircular: circular
        case .accessoryRectangular: rectangular
        case .systemSmall: small
        case .systemLarge: list(limit: 6)
        default: list(limit: 3)
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
                Text(first.item.date, style: .relative).font(.caption2).foregroundStyle(.secondary)
            } else {
                caughtUp
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(rows.first?.item.link)
    }

    private func list(limit: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if rows.isEmpty {
                Spacer(minLength: 0)
                caughtUp
                Spacer(minLength: 0)
            } else {
                ForEach(rows.prefix(limit)) { row in
                    Link(destination: row.item.link) { rowView(row) }
                }
                if rows.count > limit {
                    Text("\(rows.count - limit) more in Chatterbox").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
        if !snapshot.working.isEmpty { parts.append("\(snapshot.working.count) working") }
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
        working: [.init(chatID: UUID(), title: "Vispix", detail: nil, backend: "codex", date: .now.addingTimeInterval(-120))])
}
