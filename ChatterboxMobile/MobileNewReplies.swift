import Observation
import SwiftUI
import UIKit

/// Which chats' replies you've seen on this phone: a chat's finished replies count as new until
/// you open it here. Starts caught up, so the first launch doesn't list old replies.
@MainActor
@Observable
final class MobileSeenReplies {
    static let shared = MobileSeenReplies()
    private let key = "mobileSeenReplies"
    private let baselineKey = "mobileSeenRepliesSince"
    private var seen: [String: Date]
    private let baseline: Date

    private init() {
        let defaults = UserDefaults.standard
        if let saved = defaults.object(forKey: baselineKey) as? Date { baseline = saved }
        else { baseline = Date(); defaults.set(baseline, forKey: baselineKey) }
        seen = (defaults.dictionary(forKey: key) as? [String: Date]) ?? [:]
    }

    func isNew(_ completion: Companion.TurnCompletion) -> Bool {
        completion.endedAt > max(baseline, seen[completion.chatID.uuidString] ?? .distantPast)
    }

    func markSeen(_ chat: UUID) {
        seen[chat.uuidString] = Date()
        // Keep the record small: chats seen in the last 30 days.
        let cutoff = Date().addingTimeInterval(-30 * 86400)
        seen = seen.filter { $0.value > cutoff }
        UserDefaults.standard.set(seen, forKey: key)
        MobileWidgetSync.refresh()
    }

    /// The newest unseen reply of each chat, newest first.
    func newest(in activity: [Companion.TurnCompletion], limit: Int) -> [Companion.TurnCompletion] {
        var chats = Set<UUID>()
        return activity.sorted { $0.endedAt > $1.endedAt }
            .filter { isNew($0) && chats.insert($0.chatID).inserted }
            .prefix(limit).map { $0 }
    }
}

/// Phone-local Activity visibility, separate from read state and the saved conversation.
@MainActor
@Observable
final class MobileActivityDismissals {
    static let shared = MobileActivityDismissals()
    private let defaults: UserDefaults
    private let key = "mobileActivityDismissals"
    private struct Record: Codable {
        var through: Date?
        var running: String?
        var savedAt: Date
    }
    private var records: [String: Record]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        records = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([String: Record].self, from: $0) } ?? [:]
    }

    func hides(_ reply: Companion.TurnCompletion) -> Bool {
        reply.endedAt <= (records[reply.chatID.uuidString]?.through ?? .distantPast)
    }

    func hides(_ chat: Companion.ChatSummary, activity: [Companion.TurnCompletion]) -> Bool {
        records[chat.id.uuidString]?.running == runningKey(chat, activity: activity)
    }

    func dismiss(_ chat: Companion.ChatSummary, reply: Companion.TurnCompletion?, activity: [Companion.TurnCompletion]) {
        let id = chat.id.uuidString
        var record = records[id] ?? Record(savedAt: Date())
        if let reply { record.through = max(record.through ?? .distantPast, reply.endedAt) }
        else { record.running = runningKey(chat, activity: activity) }
        record.savedAt = Date()
        records[id] = record
        save()
    }

    /// Older Macs omit turnStartedAt: observing an idle chat clears the running dismissal.
    func reconcile(_ chats: [Companion.ChatSummary]) {
        let running = Set(chats.filter(\.isRunning).map { $0.id.uuidString })
        var changed = false
        for id in Array(records.keys) where !running.contains(id) && records[id]?.running != nil {
            records[id]?.running = nil
            changed = true
        }
        if changed { save() }
    }

    private func runningKey(_ chat: Companion.ChatSummary, activity: [Companion.TurnCompletion]) -> String {
        if let start = chat.turnStartedAt { return "turn:\(start.timeIntervalSince1970)" }
        let last = activity.filter { $0.chatID == chat.id }.max { $0.endedAt < $1.endedAt }
        return "after:\(last?.id.uuidString ?? "first")"
    }

    private func save() {
        let cutoff = Date().addingTimeInterval(-30 * 86400)
        records = records.filter { $0.value.savedAt > cutoff }
        if let data = try? JSONEncoder().encode(records) { defaults.set(data, forKey: key) }
    }
}

/// Working sessions first, then three unread replies. Swipes affect this Activity list only
/// unless the person explicitly chooses Archive or confirms Delete.
struct MobileNewReplies: View {
    let activity: [Companion.TurnCompletion]
    var chats: [Companion.ChatSummary] = []
    let summary: (UUID) -> Companion.ChatSummary?
    let open: (Companion.ChatSummary) -> Void
    let rename: (Companion.ChatSummary) -> Void
    var headingInset: CGFloat = 4
    @Environment(MobileStore.self) private var store
    @AppStorage("mobileActivityExpanded") private var expanded = true
    @State private var pending: ManagementAction?
    @State private var problem: String?
    @State private var busy = Set<UUID>()

    private struct ManagementAction: Identifiable {
        let chat: Companion.ChatSummary
        let deleting: Bool
        var id: UUID { chat.id }
    }

    private var replies: [Companion.TurnCompletion] {
        MobileSeenReplies.shared.newest(in: activity.filter {
            summary($0.chatID) != nil && !MobileActivityDismissals.shared.hides($0)
        }, limit: 3)
    }
    private var working: [Companion.ChatSummary] {
        chats.filter { $0.isRunning && $0.isDot != true && !MobileActivityDismissals.shared.hides($0, activity: activity) }
    }

    var body: some View {
        let replies = replies
        let working = working
        let entries = working.map { MobileActivityEntry(chat: $0, reply: nil) }
            + replies.compactMap { reply in summary(reply.chatID).map { MobileActivityEntry(chat: $0, reply: reply) } }
        Group {
            if !entries.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Button { withAnimation(.easeOut(duration: 0.2)) { expanded.toggle() } } label: {
                        HStack(spacing: 6) {
                            Text("ACTIVITY")
                            Image(systemName: "chevron.right").font(.caption2.weight(.bold))
                                .rotationEffect(.degrees(expanded ? 90 : 0))
                            Spacer()
                            if !working.isEmpty { Text("\(working.count) working") }
                            if !replies.isEmpty { Text("\(replies.count) new").foregroundStyle(.blue) }
                        }
                        .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                        .textCase(nil).padding(.horizontal, headingInset).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Activity, \(replies.count) new replies, \(working.count) working")
                    .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                    if expanded {
                        TimelineView(.periodic(from: .now, by: 60)) { context in
                            MobileActivityRows(entries: entries, busy: busy, now: context.date, open: open, rename: rename, dismiss: dismiss,
                                               archive: { manage($0, deleting: false) }, delete: { manage($0, deleting: true) })
                                .fixedSize(horizontal: false, vertical: true)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
            }
        }
        .onChange(of: chats, initial: true) { _, chats in MobileActivityDismissals.shared.reconcile(chats) }
        .alert(pending?.deleting == true ? "Delete this chat?" : "Archive this working chat?",
               isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), presenting: pending) { action in
            Button(action.deleting ? "Delete Chat" : "Archive and Stop Reply", role: .destructive) { perform(action) }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: { action in
            Text(action.deleting
                 ? "Deletes \"\(action.chat.title)\" and its conversation history from Chatterbox and stops any reply. Project and Studio files stay in their folders."
                 : "Archives \"\(action.chat.title)\" and stops its current reply. You can restore the chat from Archive on your Mac.")
        }
        .alert("Couldn't update chat", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) { problem = nil }
        } message: { Text(problem ?? "") }
    }

    private func dismiss(_ entry: MobileActivityEntry) {
        MobileActivityDismissals.shared.dismiss(entry.chat, reply: entry.reply, activity: activity)
    }

    private func manage(_ chat: Companion.ChatSummary, deleting: Bool) {
        let action = ManagementAction(chat: chat, deleting: deleting)
        if deleting || chat.isRunning { pending = action }
        else { perform(action) }
    }

    private func perform(_ action: ManagementAction) {
        guard busy.insert(action.chat.id).inserted else { return }
        Task { @MainActor in
            defer { busy.remove(action.chat.id) }
            do {
                if action.deleting { try await store.deleteChat(action.chat.id) }
                else { _ = try await store.setArchived(true, chat: action.chat.id) }
                await store.loadChats()
            } catch { problem = error.localizedDescription }
        }
    }
}

private struct MobileActivityEntry: Identifiable, Equatable {
    let chat: Companion.ChatSummary
    let reply: Companion.TurnCompletion?
    var id: String { reply.map { "reply:\($0.id)" } ?? "working:\(chat.id)" }
    var backend: String { reply?.backend ?? chat.backend }
}

/// A non-scrolling native table keeps swipe gestures consistent inside both SwiftUI List
/// and Studio's gallery ScrollView, without stealing vertical scrolling or Back gestures.
private struct MobileActivityRows: UIViewRepresentable {
    let entries: [MobileActivityEntry]
    let busy: Set<UUID>
    let now: Date
    let open: (Companion.ChatSummary) -> Void
    let rename: (Companion.ChatSummary) -> Void
    let dismiss: (MobileActivityEntry) -> Void
    let archive: (Companion.ChatSummary) -> Void
    let delete: (Companion.ChatSummary) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> ActivityTable {
        let table = ActivityTable(frame: .zero, style: .plain)
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.isScrollEnabled = false
        table.backgroundColor = .secondarySystemGroupedBackground
        table.separatorInset = UIEdgeInsets(top: 0, left: 40, bottom: 0, right: 0)
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 64
        table.register(MobileActivityCell.self, forCellReuseIdentifier: "activity")
        return table
    }
    func updateUIView(_ table: ActivityTable, context: Context) {
        let previous = context.coordinator.parent
        context.coordinator.parent = self
        if previous.entries.map(\.id) != entries.map(\.id) || table.numberOfRows(inSection: 0) != entries.count {
            table.reloadData()
        } else if previous.entries != entries || previous.busy != busy || previous.now != now {
            for path in table.indexPathsForVisibleRows ?? [] {
                if let cell = table.cellForRow(at: path) { context.coordinator.configure(cell, at: path) }
            }
        }
        table.invalidateIntrinsicContentSize()
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ActivityTable, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        uiView.frame.size.width = width
        uiView.layoutIfNeeded()
        return CGSize(width: width, height: uiView.contentSize.height)
    }

    final class ActivityTable: UITableView {
        override var contentSize: CGSize { didSet { if oldValue != contentSize { invalidateIntrinsicContentSize() } } }
        override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: contentSize.height) }
    }

    final class Coordinator: NSObject, UITableViewDataSource, UITableViewDelegate {
        var parent: MobileActivityRows
        init(_ parent: MobileActivityRows) { self.parent = parent }
        func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { parent.entries.count }
        func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
            let cell = tableView.dequeueReusableCell(withIdentifier: "activity", for: indexPath)
            configure(cell, at: indexPath)
            return cell
        }
        func configure(_ cell: UITableViewCell, at indexPath: IndexPath) {
            let entry = parent.entries[indexPath.row]
            let busy = parent.busy.contains(entry.chat.id)
            (cell as? MobileActivityCell)?.configure(entry, busy: busy, now: parent.now)
            cell.accessibilityCustomActions = [
                UIAccessibilityCustomAction(name: "Rename Chat") { [weak self] _ in self?.parent.rename(entry.chat); return true },
                UIAccessibilityCustomAction(name: "Dismiss from Activity") { [weak self] _ in self?.parent.dismiss(entry); return true },
                UIAccessibilityCustomAction(name: "Archive Chat") { [weak self] _ in self?.parent.archive(entry.chat); return true },
                UIAccessibilityCustomAction(name: "Delete Chat") { [weak self] _ in self?.parent.delete(entry.chat); return true }
            ]
        }
        func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
            let chat = parent.entries[indexPath.row].chat
            if !parent.busy.contains(chat.id) { parent.open(chat) }
        }
        func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
            let entry = parent.entries[indexPath.row]
            guard !parent.busy.contains(entry.chat.id) else { return nil }
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
                UIMenu(children: [
                    UIAction(title: "Rename", image: UIImage(systemName: "pencil")) { _ in self?.parent.rename(entry.chat) },
                    UIAction(title: "Dismiss from Activity", image: UIImage(systemName: "checkmark")) { _ in self?.parent.dismiss(entry) },
                    UIAction(title: "Archive", image: UIImage(systemName: "archivebox")) { _ in self?.parent.archive(entry.chat) },
                    UIAction(title: "Delete", image: UIImage(systemName: "trash"), attributes: .destructive) { _ in self?.parent.delete(entry.chat) }
                ])
            }
        }
        func tableView(_ tableView: UITableView, leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
            let entry = parent.entries[indexPath.row]
            guard !parent.busy.contains(entry.chat.id) else { return nil }
            let dismiss = UIContextualAction(style: .normal, title: "Dismiss") { [weak self] _, _, done in
                done(true)
                tableView.setEditing(false, animated: false)
                // Finish UIKit's swipe transition before SwiftUI changes the row collection.
                DispatchQueue.main.async { self?.parent.dismiss(entry) }
            }
            dismiss.backgroundColor = .systemBlue
            let archive = UIContextualAction(style: .normal, title: "Archive") { [weak self] _, _, done in
                done(true)
                tableView.setEditing(false, animated: false)
                DispatchQueue.main.async { self?.parent.archive(entry.chat) }
            }
            archive.backgroundColor = .systemOrange
            let delete = UIContextualAction(style: .normal, title: "Delete") { [weak self] _, _, done in
                done(true)
                tableView.setEditing(false, animated: false)
                DispatchQueue.main.async { self?.parent.delete(entry.chat) }
            }
            delete.backgroundColor = .systemRed
            let actions = UISwipeActionsConfiguration(actions: [dismiss, archive, delete])
            actions.performsFirstActionWithFullSwipe = true
            return actions
        }
    }
}

private final class MobileActivityCell: UITableViewCell {
    private let status = UIView()
    private let dot = UIView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let provider = UIImageView()
    private let name = UILabel()
    private let subtitle = UILabel()
    private let time = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .secondarySystemGroupedBackground
        isAccessibilityElement = true
        accessibilityTraits = .button
        dot.backgroundColor = .systemBlue; dot.layer.cornerRadius = 4
        status.addSubview(dot); status.addSubview(spinner)
        for view in [dot, spinner] {
            view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([view.centerXAnchor.constraint(equalTo: status.centerXAnchor), view.centerYAnchor.constraint(equalTo: status.centerYAnchor)])
        }
        NSLayoutConstraint.activate([dot.widthAnchor.constraint(equalToConstant: 8), dot.heightAnchor.constraint(equalToConstant: 8)])
        spinner.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
        provider.contentMode = .scaleAspectFit
        name.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 17, weight: .semibold))
        subtitle.font = .preferredFont(forTextStyle: .caption1); subtitle.textColor = .secondaryLabel
        time.font = .preferredFont(forTextStyle: .caption2); time.textColor = .secondaryLabel
        time.numberOfLines = 2; time.textAlignment = .right
        for label in [name, subtitle, time] { label.adjustsFontForContentSizeCategory = true }
        let text = UIStackView(arrangedSubviews: [name, subtitle]); text.axis = .vertical; text.spacing = 2
        let row = UIStackView(arrangedSubviews: [status, provider, text, time]); row.spacing = 10; row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false; contentView.addSubview(row)
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        time.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            status.widthAnchor.constraint(equalToConstant: 10), status.heightAnchor.constraint(equalToConstant: 20),
            provider.widthAnchor.constraint(equalToConstant: 16), provider.heightAnchor.constraint(equalToConstant: 16),
            time.widthAnchor.constraint(lessThanOrEqualToConstant: 80),
            row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 54)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ entry: MobileActivityEntry, busy: Bool, now: Date) {
        let chat = entry.chat
        name.text = chat.worktreeBranch ?? chat.project ?? chat.title
        subtitle.text = chat.subtitle; subtitle.isHidden = chat.subtitle?.isEmpty != false
        let accent = UIColor(MobileConversationStyle.accent(for: entry.backend))
        provider.image = UIImage(named: (Backend(rawValue: entry.backend) ?? .claude).iconName)?.withRenderingMode(.alwaysTemplate)
        provider.tintColor = accent; spinner.color = accent
        dot.isHidden = entry.reply == nil
        if entry.reply == nil { spinner.startAnimating() } else { spinner.stopAnimating() }
        if busy { time.text = "Updating…" }
        else if let reply = entry.reply {
            let formatter = RelativeDateTimeFormatter(); formatter.unitsStyle = .short
            time.text = formatter.localizedString(for: reply.endedAt, relativeTo: now)
        } else { time.text = "Working" }
        accessibilityLabel = "\(entry.reply == nil ? "Working" : "New reply"): \(chat.title)"
        accessibilityValue = [chat.subtitle, time.text].compactMap { $0 }.joined(separator: ", ")
        accessibilityHint = "Opens the chat. Swipe right for Activity actions."
        accessibilityTraits = busy ? [.button, .notEnabled] : .button
    }
}
