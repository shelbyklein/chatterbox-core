#if GOLEM_APP
import AppKit
import Foundation
import Observation
import UserNotifications

/// Dot's email watch: every 15 minutes from 9 to 5 (every 30 otherwise), a one-off Codex
/// run on a light model reads only the mail that arrived since the last sweep, in every
/// Gmail account Codex reaches, and picks out what needs you by the rules in Dot's memory.
/// Each email worth your attention becomes a notification (who, what, why, and a suggested
/// next step) with Draft Reply, Tell Dot…, and Open, plus a line in Dot's chat. Sweeps keep
/// no history and leave nothing behind when there's nothing to tell. It only reads mail.
@MainActor
@Observable
final class EmailWatch {
    static let shared = EmailWatch()

    static let enabledKey = "dotEmailWatch"
    static let modelKey = "dotEmailModel"
    static let defaultModel = "gpt-6-luna"
    static let category = "dotEmail"
    private static let lastAttemptKey = "dotEmailLastAttempt"
    private static let lastSweepKey = "dotEmailLastSweep"
    private static let reportedKey = "dotEmailReported"

    struct Email: Codable, Equatable {
        var account: String
        var from: String
        var subject: String
        var why: String
        var action: String
        var link: String
        var id: String
    }

    @ObservationIgnored weak var model: AppModel?
    @ObservationIgnored private var timer: Timer?
    private(set) var isSweeping = false
    /// Why the last sweep didn't work, if it didn't.
    private(set) var problem: String?
    /// When mail was last read through (the start of the last sweep that worked).
    private(set) var lastSweep: Date? = AppPreferences.defaults.object(forKey: lastSweepKey) as? Date

    var isOn: Bool { AppPreferences.defaults.object(forKey: Self.enabledKey) as? Bool ?? true }
    /// Roughly when the next sweep is due (they run on a one-minute tick).
    var nextSweep: Date {
        let last = AppPreferences.defaults.object(forKey: Self.lastAttemptKey) as? Date ?? Date()
        return max(Date(), last.addingTimeInterval(Self.interval(at: last)))
    }
    var sweepModel: String { AppPreferences.defaults.string(forKey: Self.modelKey) ?? Self.defaultModel }

    /// 15 minutes during the working day, 30 the rest of the time.
    static func interval(at date: Date) -> TimeInterval {
        (9..<17).contains(Calendar.current.component(.hour, from: date)) ? 15 * 60 : 30 * 60
    }

    func start(model: AppModel) {
        self.model = model
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) { [weak self] in self?.tick() }
    }

    private func tick() {
        guard isOn, !isSweeping else { return }
        let now = Date()
        if let last = AppPreferences.defaults.object(forKey: Self.lastAttemptKey) as? Date,
           now.timeIntervalSince(last) < Self.interval(at: now) - 30 { return }
        Task { await sweep() }
    }

    /// A sweep right away (from Settings).
    func sweepNow() {
        guard !isSweeping else { return }
        Task { await sweep() }
    }

    // MARK: - Sweeping

    private func sweep() async {
        guard let model, let codex = CodexAppServer.locateBinary() else {
            problem = "Couldn't find the `codex` command."
            return
        }
        isSweeping = true
        defer { isSweeping = false }
        let started = Date()
        AppPreferences.defaults.set(started, forKey: Self.lastAttemptKey)
        // From the last sweep that worked; at most the past 16 hours (a night asleep), and
        // the past hour the first time.
        let since = max(lastSweep ?? started.addingTimeInterval(-3600), started.addingTimeInterval(-16 * 3600))
        let name = model.dotName
        let result = await Self.run(codex: codex, model: sweepModel, prompt: Self.prompt(name: name, since: since, now: started))
        switch result {
        case .failure(let message):
            problem = message
            NSLog("Chatterbox email watch: %@", message)
        case .success(let emails):
            problem = nil
            lastSweep = started
            AppPreferences.defaults.set(started, forKey: Self.lastSweepKey)
            var reported = AppPreferences.defaults.stringArray(forKey: Self.reportedKey) ?? []
            let fresh = emails.filter { $0.id.isEmpty || !reported.contains($0.id) }
            reported = Array((reported + fresh.map(\.id).filter { !$0.isEmpty }).suffix(500))
            AppPreferences.defaults.set(reported, forKey: Self.reportedKey)
            guard !fresh.isEmpty else { return }
            let dot = model.ensureDot()
            for email in fresh {
                dot.notice("Email for you \u{00B7} \(email.from), \u{201C}\(email.subject)\u{201D} (\(email.account)): \(email.why) Suggested: \(email.action)")
                GolemJournal.shared.add(.activity, title: "Email from \(email.from)", detail: "\u{201C}\(email.subject)\u{201D} (\(email.account)) \u{00B7} \(email.action)")
                notify(email, dot: dot)
            }
            dot.onChange?(dot)
        }
    }

    private static func prompt(name: String, since: Date, now: Date) -> String {
        let format = DateFormatter()
        format.dateFormat = "EEEE, MMMM d, yyyy 'at' h:mm a zzz"
        let iso = ISO8601DateFormatter()
        return """
        You are \(name)'s email sweep, running in the background for the user. Find the email that arrived in all of the user's Gmail accounts since \(format.string(from: since)) (\(iso.string(from: since)) UTC). Use your Gmail tools. Only read: never send, draft, archive, label, mark as read, delete, or change anything.

        To find it, search each account with exactly this query: after:\(Int(since.timeIntervalSince1970)) -in:sent -in:drafts (Gmail reads that number as the exact moment of the last sweep). Every result is new; don't filter by time yourself, since Gmail mixes time zones in its timestamps. Page through all results.

        First read the user's notes: \(AppModel.dotMemoryFolder.path)/MEMORY.md and the files it points to (especially the accounts and \(name)'s jobs). Follow them on what counts as important. Unless they say otherwise, flag mail that needs the user to do or decide something, or that they'd want to know about soon: school, appointments, bills or deadlines, clients and work requests (USA Archery and its forwards included), and personal messages from real people. Stay quiet about newsletters, promotions, receipts with nothing to do, automated notifications, and anything the user has already replied to.

        Answer with the JSON the schema asks for: "emails", most important first, at most 8. Leave it empty when nothing needs the user; that's the usual case. For each email: account (the address it arrived at), from (the sender's name), subject, why (one short sentence on why it matters to the user), action (one short suggested next step), link (a Gmail web link to the message if your tools give one, otherwise ""), and id (the message's id).
        """
    }

    nonisolated private static let schema = """
    {"type":"object","additionalProperties":false,"required":["emails"],"properties":{"emails":{"type":"array","maxItems":8,"items":{"type":"object","additionalProperties":false,"required":["account","from","subject","why","action","link","id"],"properties":{"account":{"type":"string"},"from":{"type":"string"},"subject":{"type":"string"},"why":{"type":"string"},"action":{"type":"string"},"link":{"type":"string"},"id":{"type":"string"}}}}}}
    """

    enum Outcome {
        case success([Email])
        case failure(String)
    }

    /// One `codex exec`: read-only, kept out of Codex's history, stopped after ten minutes.
    private static func run(codex: String, model: String, prompt: String) async -> Outcome {
        let folder = AppModel.dotFolder
        // Direct, not through a proxy, when Codex has a ChatGPT sign-in: Gmail comes with it.
        let direct = EasyCLIProxy.codexHasChatGPTSignIn
        return await Task.detached {
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("chatterbox-email-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: scratch) }
            let schemaFile = scratch.appendingPathComponent("schema.json")
            let answerFile = scratch.appendingPathComponent("answer.json")
            try? Data(schema.utf8).write(to: schemaFile)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: codex)
            process.arguments = (direct ? ["-c", "model_provider=openai"] : []) + ["exec", "--skip-git-repo-check", "--ephemeral", "-s", "read-only", "-m", model,

                                 "-C", folder, "--output-schema", schemaFile.path,
                                 "-o", answerFile.path, prompt]
            process.environment = BinaryLocator.environment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            let errors = Pipe()
            process.standardError = errors
            do { try process.run() } catch { return .failure("Couldn't start Codex: \(error.localizedDescription)") }
            let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 600, execute: watchdog)
            let errorText = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            watchdog.cancel()

            guard let data = try? Data(contentsOf: answerFile), !data.isEmpty else {
                NSLog("Chatterbox email watch: codex exited %d: %@", process.terminationStatus, String(errorText.suffix(1500)))
                let last = errorText.split(separator: "\n").last(where: { $0.localizedCaseInsensitiveContains("error") }) ?? ""
                return .failure(process.terminationReason == .uncaughtSignal ? "The sweep took too long and was stopped."
                                : "The sweep didn't finish. " + String(last.prefix(200)))
            }
            struct Answer: Decodable { var emails: [Email] }
            guard let answer = try? JSONDecoder().decode(Answer.self, from: data) else {
                return .failure("The sweep's answer couldn't be read.")
            }
            return .success(answer.emails)
        }.value
    }

    // MARK: - Notifications

    /// A sample notification, to try the buttons. Its buttons say it's a test to Dot.
    func sendTest() {
        guard let model else { return }
        notify(Email(account: "test", from: "Chatterbox (test)", subject: "Sample email notification",
                     why: "This is a test of the email watch; no real email is behind it.",
                     action: "Try Draft Reply, Tell \(model.dotName)\u{2026}, or Open.", link: "", id: ""),
               dot: model.ensureDot())
    }

    private func notify(_ email: Email, dot: ChatSession) {
        MobilePush.shared.post(title: email.from + " · " + email.subject,
            body: email.why + " Suggested: " + email.action, chat: dot.id, kind: "email")
        guard Bundle.main.bundleIdentifier != nil, let encoded = try? JSONEncoder().encode(email) else { return }
        let content = UNMutableNotificationContent()
        content.title = email.from
        content.subtitle = email.subject
        content.body = email.why + " Suggested: " + email.action
        content.sound = .default
        content.threadIdentifier = "email"
        content.categoryIdentifier = Self.category
        content.userInfo = ["session": dot.id.uuidString, "item": "", "email": String(decoding: encoded, as: UTF8.self)]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// The notification's buttons; the "Tell" one is named for Dot.
    static func notificationCategory(name: String) -> UNNotificationCategory {
        UNNotificationCategory(identifier: category, actions: [
            UNNotificationAction(identifier: "draftReply", title: "Draft Reply"),
            UNTextInputNotificationAction(identifier: "tellDot", title: "Tell \(name)\u{2026}", options: [],
                                          textInputButtonTitle: "Send", textInputPlaceholder: "What should \(name) do?"),
            UNNotificationAction(identifier: "openEmail", title: "Open", options: [.foreground]),
        ], intentIdentifiers: [])
    }

    /// A tap on an email notification or one of its buttons.
    func handle(action: String, emailJSON: String, typed: String?) {
        guard let model, let email = try? JSONDecoder().decode(Email.self, from: Data(emailJSON.utf8)) else { return }
        let dot = model.ensureDot()
        if email.account == "test" {
            // From Settings' sample: nothing to look up.
            dot.sendAutomatic(label: "Test notification \u{00B7} \(action == "tellDot" ? typed ?? "" : action)", text: """
            <app_note>
            The user is trying the email watch's notification buttons with a sample (no real email). They pressed \(action == "draftReply" ? "Draft Reply" : action == "tellDot" ? "Tell you, and wrote: \u{201C}\(typed ?? "")\u{201D}" : "Open"). Reply in one line confirming it reached you.
            </app_note>
            """)
            if action != "draftReply", action != "tellDot" { model.selectedID = dot.id; NSApp.activate(ignoringOtherApps: true) }
            return
        }
        let about = """
        The email: from \(email.from), subject \u{201C}\(email.subject)\u{201D}, to \(email.account)\(email.id.isEmpty ? "" : ", message id \(email.id)")\(email.link.isEmpty ? "" : ", \(email.link)"). Your sweep noted: \(email.why) Suggested: \(email.action)
        """
        switch action {
        case "draftReply":
            dot.sendAutomatic(label: "Draft a reply \u{00B7} \(email.subject)", text: """
            <app_note>
            From a notification, the user asked you to draft a reply to an email. \(about)
            Find it with your Gmail tools and read it (and its thread). Write a reply in the user's voice. Save it as a draft in that account if your tools can; never send it. Then show the draft here, briefly, so the user can review it; they'll tell you to send it or what to change.
            </app_note>
            """)
        case "tellDot":
            let text = typed?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else { return }
            dot.sendAutomatic(label: "You, about \u{201C}\(email.subject)\u{201D}: \(text)", text: """
            <app_note>
            From a notification about an email, the user wrote: \u{201C}\(text)\u{201D}
            \(about)
            Do what they asked, following your rules (ask before sending anything). Reply briefly; it reaches them as a notification.
            </app_note>
            """)
        default:
            if let url = URL(string: email.link), url.scheme?.hasPrefix("http") == true {
                NSWorkspace.shared.open(url)
            } else {
                if dot.record.archivedAt != nil { model.unarchive(dot) }
                model.selectedID = dot.id
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}

#endif
