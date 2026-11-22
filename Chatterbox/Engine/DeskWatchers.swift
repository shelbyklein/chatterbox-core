import Foundation

/// Where each watcher left off, and what it last saw of each task, so a change is reported
/// once. `Desk/checkpoints.json`; only advanced after a complete, successful check.
struct DeskCheckpoints: Codable, Equatable {
    struct TaskSnapshot: Codable, Equatable {
        var name: String
        var status: String
        var priority: String?
        var due: String?
        var descriptionHash: Int
    }
    /// ClickUp: tasks updated after this (milliseconds since 1970, ClickUp's unit).
    var clickupUpdatedAfter: Int64?
    var clickupTasks: [String: TaskSnapshot] = [:]
    /// Apple Mail: messages received after this ROWID in Mail's index.
    var mailAfterRow: Int64?
    /// When each watcher last finished a check, and its problem if the last one failed.
    var lastChecked: [String: Date] = [:]
    var problems: [String: String] = [:]

    static var file: URL { RuntimePaths.data.appendingPathComponent("Desk/checkpoints.json") }
    static func load(_ file: URL = Self.file) -> DeskCheckpoints {
        (try? Data(contentsOf: file)).flatMap { try? Companion.decoder.decode(DeskCheckpoints.self, from: $0) } ?? DeskCheckpoints()
    }
    func save(_ file: URL = Self.file) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Companion.encoder.encode(self).write(to: file, options: .atomic)
    }
}

/// ClickUp, every few minutes, through its API with the `CLICKUP_API` secret (no AI): tasks
/// assigned to Shelby in the USA Archery workspace updated since the checkpoint, and new
/// comments on them from anyone else. Each real change becomes an inbox event.
@MainActor
final class ClickUpWatcher {
    static let shared = ClickUpWatcher()
    static let workspace = "9014281602"
    static let me = 57216908
    static var interval: TimeInterval = 180

    /// The API's base address; tests point it at a fake server.
    var base = URL(string: "https://api.clickup.com/api/v2")!
    var token: () -> String? = { SecretVault.shared.value(forVariable: "CLICKUP_API") }
    var checkpointsFile = DeskCheckpoints.file
    var inbox: DeskInbox { DeskInbox.shared }
    private(set) var checking = false
    private var timer: Timer?
    /// After a failure the wait doubles (to 30 minutes), and resets on success.
    private var backoff: TimeInterval = 0

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { ClickUpWatcher.shared.checkIfDue() }
        }
        Task { await check() }
    }
    func stop() { timer?.invalidate(); timer = nil }

    private var lastAttempt: Date?
    func checkIfDue() {
        let wait = max(Self.interval, backoff)
        if lastAttempt.map({ Date().timeIntervalSince($0) >= wait }) ?? true { Task { await check() } }
    }

    /// One check. Returns the number of events added.
    @discardableResult
    func check(now: Date = Date()) async -> Int {
        guard !checking else { return 0 }
        checking = true
        lastAttempt = now
        defer { checking = false }
        var points = DeskCheckpoints.load(checkpointsFile)
        do {
            guard let token = token(), !token.isEmpty else { throw RuntimeFailure("No ClickUp key: add CLICKUP_API in Settings → Secrets.") }
            let first = points.clickupUpdatedAfter == nil
            let since = points.clickupUpdatedAfter ?? Int64(now.timeIntervalSince1970 * 1000)
            var tasks: [JSON] = []
            var page = 0
            while true {
                let reply = try await get("team/\(Self.workspace)/task", token: token, query: [
                    "assignees[]": "\(Self.me)", "date_updated_gt": "\(since)", "subtasks": "true",
                    "include_closed": "true", "order_by": "updated", "page": "\(page)"])
                tasks += reply["tasks"]?.array ?? []
                if reply["last_page"]?.bool != false || page >= 20 { break }
                page += 1
            }
            var added: [DeskEvent] = []
            var newest = since
            for task in tasks {
                guard let id = task["id"]?.string else { continue }
                let updated = Self.ms(task["date_updated"]) ?? since
                newest = max(newest, updated)
                let snapshot = Self.snapshot(task)
                let previous = points.clickupTasks[id]
                points.clickupTasks[id] = snapshot
                let created = Self.ms(task["date_created"]) ?? 0
                let link = task["url"]?.string
                if previous == nil, created > since {
                    added.append(DeskEvent(source: "clickup", sourceEventID: "task:\(id)", kind: "task.new",
                                           title: snapshot.name, detail: Self.describe(task), link: link))
                } else if let previous, previous != snapshot {
                    added.append(DeskEvent(source: "clickup", sourceEventID: "task:\(id):\(updated)", kind: "task.updated",
                                           title: snapshot.name, detail: Self.changes(from: previous, to: snapshot) + "\n" + Self.describe(task), link: link))
                }
                // New comments from anyone but Shelby (a comment moves the task's update time).
                guard !first else { continue }
                let comments = try await get("task/\(id)/comment", token: token)["comments"]?.array ?? []
                for comment in comments {
                    guard let cid = comment["id"]?.string, let date = Self.ms(comment["date"]), date > since,
                          comment["user"]?["id"]?.int != Self.me else { continue }
                    let who = comment["user"]?["username"]?.string ?? "Someone"
                    let text = String((comment["comment_text"]?.string ?? "").prefix(1500))
                    added.append(DeskEvent(source: "clickup", sourceEventID: "comment:\(cid)", kind: "comment.new",
                                           title: "\(who) on \u{201C}\(snapshot.name)\u{201D}", detail: text, link: link))
                }
            }
            // The first check only learns where things stand: nothing floods in.
            if first { added = [] }
            points.clickupUpdatedAfter = newest
            points.lastChecked["clickup"] = now
            points.problems["clickup"] = nil
            points.save(checkpointsFile)
            backoff = 0
            return added.filter { inbox.add($0) }.count
        } catch {
            backoff = min(1800, max(Self.interval * 2, backoff * 2))
            points.problems["clickup"] = error.localizedDescription
            points.save(checkpointsFile)
            RuntimeHooks.note("ClickUp check failed: \(error.localizedDescription)")
            return 0
        }
    }

    private func get(_ path: String, token: String, query: [String: String] = [:]) async throws -> JSON {
        var parts = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { parts.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var request = URLRequest(url: parts.url!, timeoutInterval: 30)
        request.setValue(token, forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 429 { throw RuntimeFailure("ClickUp asked to slow down (rate limit).") }
        if status == 401 { throw RuntimeFailure("ClickUp refused the key (401): update CLICKUP_API in Settings → Secrets.") }
        guard (200..<300).contains(status) else { throw RuntimeFailure("ClickUp answered \(status).") }
        return try JSON.parse(data)
    }

    static func snapshot(_ task: JSON) -> DeskCheckpoints.TaskSnapshot {
        .init(name: task["name"]?.string ?? "Untitled task", status: task["status"]?["status"]?.string ?? "",
              priority: task["priority"]?["priority"]?.string, due: task["due_date"]?.string,
              descriptionHash: stableHash(task["text_content"]?.string ?? ""))
    }

    /// The same number for the same text in every launch (Swift's hashValue changes per run).
    static func stableHash(_ text: String) -> Int {
        var hash: UInt64 = 5381
        for byte in text.utf8 { hash = (hash &* 33) ^ UInt64(byte) }
        return Int(truncatingIfNeeded: hash)
    }

    /// ClickUp sends times as strings of milliseconds (sometimes as numbers).
    static func ms(_ value: JSON?) -> Int64? { value?.string.flatMap { Int64($0) } ?? value?.int.map(Int64.init) }

    static func changes(from old: DeskCheckpoints.TaskSnapshot, to new: DeskCheckpoints.TaskSnapshot) -> String {
        var parts: [String] = []
        if old.status != new.status { parts.append("status \(old.status) → \(new.status)") }
        if old.priority != new.priority { parts.append("priority \(old.priority ?? "none") → \(new.priority ?? "none")") }
        if old.due != new.due { parts.append("due date changed") }
        if old.name != new.name { parts.append("renamed from \u{201C}\(old.name)\u{201D}") }
        if old.descriptionHash != new.descriptionHash { parts.append("description edited") }
        return "Changed: " + (parts.isEmpty ? "details" : parts.joined(separator: ", "))
    }

    static func describe(_ task: JSON) -> String {
        var lines = ["Status: \(task["status"]?["status"]?.string ?? "?")"]
        if let priority = task["priority"]?["priority"]?.string { lines.append("Priority: \(priority)") }
        if let due = ms(task["due_date"]) {
            lines.append("Due: " + Date(timeIntervalSince1970: Double(due) / 1000).formatted(date: .abbreviated, time: .omitted))
        }
        if let list = task["list"]?["name"]?.string { lines.append("List: \(list)") }
        if let id = task["id"]?.string { lines.append("ClickUp task id: \(id)") }
        let text = (task["text_content"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { lines.append("Description: " + String(text.prefix(1500))) }
        return lines.joined(separator: "\n")
    }
}
