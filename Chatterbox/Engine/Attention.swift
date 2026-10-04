import AppKit
import UserNotifications

/// Tells you when a chat needs you while you're looking elsewhere: an approval or question
/// is waiting, or a reply finished. Also keeps the Dock badge and the sidebar's unread dots.
@MainActor
@Observable
final class Attention: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Attention()

    /// Chats with a finished reply you haven't looked at yet.
    private(set) var unread: Set<UUID> = []

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var wasRunning: [UUID: Bool] = [:]
    @ObservationIgnored private var notified: Set<UUID> = []
    @ObservationIgnored private var authorized = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private static let approvalCategory = "approval"

    private var defaults: UserDefaults { .standard }
    private var notifyReplies: Bool { defaults.object(forKey: "notifyReplies") as? Bool ?? true }
    private var notifyNeeds: Bool { defaults.object(forKey: "notifyNeeds") as? Bool ?? true }
    private var playSound: Bool { defaults.object(forKey: "notifySound") as? Bool ?? true }
    private var showBadge: Bool { defaults.object(forKey: "notifyBadge") as? Bool ?? true }

    /// Sets up the notification center once; called when the app starts.
    func start(model: AppModel) {
        guard self.model == nil else { return }
        self.model = model
        // Notifications need a real app bundle; test harnesses run without one.
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        registerCategories()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            Task { @MainActor in self.authorized = granted }
        }
        // Coming back to the window clears the current chat's unread mark.
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                if let session = self.model?.selected, self.isWatching(session) { self.markSeen(session.id) }
            }
        })
        for session in model.sessions { wasRunning[session.id] = session.isRunning; notified.formUnion(pendingItems(session).map(\.id)) }
        // The first time, everything so far counts as read.
        if dotSeenItem == nil, let dot = model.dot { markDotSeen(dot) }
    }

    /// The buttons notifications offer: Allow and Deny on approvals, and the email watch's
    /// (again after Dot is renamed, since one is named for it).
    func registerCategories() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let allow = UNNotificationAction(identifier: "allow", title: "Allow")
        let deny = UNNotificationAction(identifier: "deny", title: "Deny", options: [.destructive])
        var categories:Set<UNNotificationCategory>=[UNNotificationCategory(identifier:Self.approvalCategory,actions:[allow,deny],intentIdentifiers:[])]
        #if GOLEM_APP
        categories.insert(EmailWatch.notificationCategory(name:model?.dotName ?? "Golem"))
        #endif
        UNUserNotificationCenter.current().setNotificationCategories(categories)
    }

    /// You're watching a chat when Chatterbox is frontmost and that chat is open.
    func isWatching(_ session: ChatSession) -> Bool {
        #if GOLEM_APP
        if model?.showingDot == true {
            let readingMini = model?.dotMiniWindow?.isReading == true
            if session.isDot { return readingMini }
            if readingMini { return false }
        }
        #endif
        return NSApp.isActive && model?.selectedID == session.id
    }

    func markSeen(_ id: UUID?) {
        if let id, let dot = model?.dot, dot.id == id { markDotSeen(dot) }
        guard let id, unread.remove(id) != nil else { return }
        refreshBadge()
    }

    // MARK: - Dot's unread messages

    /// The last of Dot's rows you've seen, kept across launches.
    private(set) var dotSeenItem: UUID? = AppPreferences.defaults.string(forKey: "dotSeenItem").flatMap(UUID.init(uuidString:))

    private func markDotSeen(_ dot: ChatSession) {
        guard let last = dot.items.last?.id, last != dotSeenItem else { return }
        dotSeenItem = last
        AppPreferences.defaults.set(last.uuidString, forKey: "dotSeenItem")
    }

    /// Dot's replies since you last looked, one per reply (a check-in with nothing to say
    /// leaves none). Before you've ever opened it, nothing counts as new.
    private func unreadDotReplies(_ dot: ChatSession) -> [DisplayItem] {
        guard let seen = dotSeenItem else { return [] }
        let start = dot.items.firstIndex(where: { $0.id == seen }).map { $0 + 1 } ?? dot.items.count
        var replies: [DisplayItem] = []
        var latestInTurn: DisplayItem?
        for item in dot.items[start...] {
            if item.kind == .user {
                if let latestInTurn { replies.append(latestInTurn) }
                latestInTurn = nil
            } else if item.kind == .assistant, item.phase == .final, !item.text.isEmpty {
                latestInTurn = item
            }
        }
        if let latestInTurn, !dot.isRunning { replies.append(latestInTurn) }
        return replies
    }

    func dotUnreadCount(_ dot: ChatSession) -> Int { unreadDotReplies(dot).count }

    /// The newest unread reply's text, for the sidebar.
    func dotLatestUnread(_ dot: ChatSession) -> String? { unreadDotReplies(dot).last?.text }

    /// Chats waiting on you or with news, for the Dock badge.
    var attentionCount: Int {
        let waiting = (model?.sessions ?? []).filter { !pendingItems($0).isEmpty }.map(\.id)
        return Set(waiting).union(unread).count
    }

    private func pendingItems(_ session: ChatSession) -> [DisplayItem] {
        session.items.filter { ($0.kind == .approval || $0.kind == .questions) && $0.approvalState == .pending }
    }

    /// Called on every change to a chat: notices new requests and finished turns.
    func update(_ session: ChatSession, model: AppModel) {
        #if GOLEM_APP
        if RuntimeClient.usesDaemon,!session.isDot{return}
        #endif
        if self.model == nil { start(model: model) }
        let watching = isWatching(session)
        #if GOLEM_APP
        if !RuntimeClient.usesDaemon {DotActivity.shared.noticeWaiting(in: session)}
        #endif

        for item in pendingItems(session) where !notified.contains(item.id) {
            notified.insert(item.id)
            let need = item.questions?.first?.question ?? item.text
            if !RuntimeClient.usesDaemon {MobilePush.shared.post(title: title(for: session), body: need, chat: session.id, kind: "needs")}
            if !watching, notifyNeeds { notifyNeed(item, in: session) }
        }

        let running = session.isRunning
        let finished = wasRunning[session.id] == true && !running
        wasRunning[session.id] = running
        if session.isDot, watching { markDotSeen(session) }
        if finished, session.skipFinishedAlert {
            // Dot's check-in sent its own alert, or had nothing to say.
            session.skipFinishedAlert = false
            if session.isDot, !watching, dotUnreadCount(session) > 0 { unread.insert(session.id) }
        } else if finished {
            let reply = session.items.last { $0.kind == .assistant && $0.phase == .final }?.text ?? "Reply finished."
            if !RuntimeClient.usesDaemon {MobilePush.shared.post(title: title(for: session), body: reply, chat: session.id, kind: "replies")}
            if watching {
                unread.remove(session.id)
            } else {
                unread.insert(session.id)
                if notifyReplies { notifyFinished(session) }
            }
        }
        refreshBadge()
    }

    private func refreshBadge() {
        let count = attentionCount
        NSApp.dockTile.badgeLabel = showBadge && count > 0 ? "\(count)" : nil
    }

    // MARK: - Posting

    private func title(for session: ChatSession) -> String {
        session.record.projectFolder != nil ? "\(session.projectName) \u{00B7} \(session.record.backend.label)" : session.title
    }

    private func notifyNeed(_ item: DisplayItem, in session: ChatSession) {
        let content = UNMutableNotificationContent()
        content.title = title(for: session)
        switch item.kind {
        case .questions:
            let count = item.questions?.count ?? 0
            content.subtitle = "\(session.record.backend.label) has \(count == 1 ? "a question" : "\(count) questions") for you"
            content.body = item.questions?.first?.question ?? ""
        default:
            content.subtitle = item.text
            content.body = String((item.detail ?? "").prefix(200))
            // Plan approvals need a choice of how to build, so they open the chat instead.
            if item.approvalStyle == nil { content.categoryIdentifier = Self.approvalCategory }
        }
        post(content, session: session, item: item.id)
    }

    private func notifyFinished(_ session: ChatSession) {
        let content = UNMutableNotificationContent()
        content.title = title(for: session)
        if let last = session.items.last, last.kind == .notice, last.text.hasPrefix("Claude Code reported") || last.text.contains("stopped unexpectedly") {
            content.subtitle = "Something went wrong"
            content.body = last.text
        } else {
            let reply = session.items.last { $0.kind == .assistant && $0.phase == .final }?.text ?? ""
            content.subtitle = "\(session.record.backend.label) finished"
            content.body = String(reply.replacingOccurrences(of: "\n", with: " ").prefix(180))
        }
        post(content, session: session, item: nil)
    }

    private func post(_ content: UNMutableNotificationContent, session: ChatSession, item: UUID?) {
        guard authorized, Bundle.main.bundleIdentifier != nil else { return }
        if playSound { content.sound = .default }
        content.threadIdentifier = session.id.uuidString
        content.userInfo = ["session": session.id.uuidString, "item": item?.uuidString ?? ""]
        let request = UNNotificationRequest(identifier: item?.uuidString ?? UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Responses

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // Shown as a banner even when Chatterbox is frontmost but a different chat is open.
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let sessionID = (info["session"] as? String).flatMap(UUID.init(uuidString:))
        let itemID = (info["item"] as? String).flatMap(UUID.init(uuidString:))
        let action = response.actionIdentifier
        let email = info["email"] as? String
        let typed = (response as? UNTextInputNotificationResponse)?.userText
        Task { @MainActor in
            defer { completionHandler() }
            #if GOLEM_APP
            if let email {
                EmailWatch.shared.handle(action: action, emailJSON: email, typed: typed)
                return
            }
            #endif
            guard let model = self.model, let sessionID, let session = model.sessions.first(where: { $0.id == sessionID }) else { return }
            switch action {
            case "allow", "deny":
                if let itemID { session.resolveApproval(itemID, action == "allow" ? .approved : .denied) }
            default:
                // Clicking the notification: bring the chat forward.
                if session.record.archivedAt != nil { model.unarchive(session) }
                model.selectedID = sessionID
                NSApp.activate(ignoringOtherApps: true)
                self.markSeen(sessionID)
            }
            self.refreshBadge()
        }
    }
}
