import Foundation
import Observation

/// Changes made on this Mac that the background service hasn't confirmed yet
/// (plans/mac-outbox.md): a session's tags, name, place and other metadata, its settings,
/// Brief, archive and Remote Control, a new or deleted session, and Studios, pins and settings.
///
/// Each change is sent at once, as a request whose reply confirms it, and kept until then:
/// a lost, timed-out or refused send is retried with backoff and again on reconnect, and the
/// pending changes are saved next to mac-navigation.json, so a relaunch sends them too. Meanwhile
/// the session shows its own copy (`project`): the service's updates don't put the old values
/// back. Only the fields that changed are sent, so a stale copy of the rest can't overwrite what
/// changed on the service (the phone, an agent) in the meantime.
@MainActor @Observable final class RuntimeOutbox {
    static let shared = RuntimeOutbox()

    /// How long a send waits for its reply, how long a change waits before it shows as pending,
    /// and how often pending changes are looked at. Tests shorten them.
    @ObservationIgnored var requestTimeout: Duration = .seconds(15)
    @ObservationIgnored var slowAfter: TimeInterval = 10
    @ObservationIgnored var tick: Duration = .milliseconds(500)
    /// Where pending changes are kept across a relaunch (AppModel sets it).
    @ObservationIgnored var file: URL?
    /// The session's record on this Mac, for a service without partial metadata.
    @ObservationIgnored var localRecord: (UUID) -> ConversationRecord? = { _ in nil }
    /// A session's change was given up, or its confirmation never came: show the service's copy.
    @ObservationIgnored var onSettled: (UUID) -> Void = { _ in }

    struct Entry: Codable {
        var op: String
        var key: String
        var value: JSON
        /// Record fields (wire names) this change shows on the Mac until it's on the service.
        var overlay: [String: JSON]?
        var version: Int
        var since: Date
        var failures = 0
        var lastError: String?
        /// Applied on the service at this chat revision; shown until an update that new arrives.
        var ackedAt: Int? = nil
        var ackedDate: Date? = nil
        /// The version being sent now.
        var inFlight: Int? = nil
        var nextAttempt: Date? = nil
        /// A send may have reached the service without its reply coming back (or this is from
        /// before a relaunch): an update showing the change also confirms it.
        var uncertain = false
        enum CodingKeys: String, CodingKey { case op, key, value, overlay, version, since, failures, lastError }
    }

    enum Status: Equatable {
        case saving
        case retrying(String)
    }
    /// Sessions (by id) and "global" with a change pending longer than `slowAfter`.
    private(set) var slow: [String: Status] = [:]
    func status(_ chat: UUID) -> Status? { slow[chat.uuidString] }

    /// Sends in this order, so a new session exists before its changes and a delete comes last.
    static let order = ["create", "metadata", "settings", "setBrief", "remoteControl", "archive", "delete", "studios", "pins", "preferences"]
    /// Ops whose changes go together in one request, a field each.
    private static let merged: Set<String> = ["metadata", "settings", "preferences"]
    /// Fields an update without the transcript leaves out: those can't confirm a change.
    private static let notInSummaries: Set<String> = ["brief"]
    /// Service errors that won't change on a retry.
    private static let permanent: Set<String> = ["chat_not_found", "permission_denied", "unsupported_operation", "invalid_record",
                                                 "Malformed request", "Conversation not found", "unsupported_version"]

    @ObservationIgnored private var scopes: [String: [String: Entry]] = [:]
    @ObservationIgnored private var nextVersion = 1
    @ObservationIgnored private var flushing: Set<String> = []
    @ObservationIgnored private var pump: Task<Void, Never>?
    @ObservationIgnored private var saveScheduled = false

    private static func scope(_ chat: UUID?) -> String { chat?.uuidString ?? "global" }

    // MARK: Changes

    /// Records changes (`values`, by field, or by op for single-value ops) and sends them now.
    func enqueue(_ chat: UUID?, op: String, values: [String: JSON], overlays: [String: [String: JSON]] = [:]) {
        guard !values.isEmpty else { return }
        let scope = Self.scope(chat)
        var entries = scopes[scope] ?? [:]
        for (key, value) in values {
            let id = op + "/" + key
            let old = entries[id]
            let since = old.flatMap { $0.ackedAt == nil ? $0.since : nil } ?? Date()
            var entry = Entry(op: op, key: key, value: value, overlay: overlays[key], version: nextVersion, since: since)
            nextVersion += 1
            entry.failures = old?.ackedAt == nil ? old?.failures ?? 0 : 0
            entry.lastError = old?.lastError
            entry.inFlight = old?.inFlight
            entry.uncertain = old?.uncertain ?? false
            entries[id] = entry
        }
        scopes[scope] = entries
        saveSoon(); startPump()
        // A session the service may not have yet: its changes go after it, in order.
        if op != "create", let create = entries["create/create"], create.ackedAt == nil, create.inFlight == nil {
            flush(scope); return
        }
        if let send = prepare(scope, op: op) { Task { await deliver(send) } }
    }

    /// One field's change: its value, and what it shows as on the record meanwhile.
    func enqueue(_ chat: UUID?, op: String, key: String? = nil, value: JSON, overlay: [String: JSON]? = nil) {
        let key = key ?? op
        enqueue(chat, op: op, values: [key: value], overlays: overlay.map { [key: $0] } ?? [:])
    }

    /// Deletes a session: whatever else it had pending no longer matters.
    func delete(_ chat: UUID) {
        scopes[chat.uuidString] = scopes[chat.uuidString]?.filter { $0.value.op == "create" && $0.value.inFlight != nil }
        enqueue(chat, op: "delete", value: .bool(true))
    }

    /// The value pending (or applied, awaiting its update) for a field.
    func value(_ chat: UUID?, op: String, key: String) -> JSON? { scopes[Self.scope(chat)]?[op + "/" + key]?.value }
    /// Whether `op` has a change the service hasn't confirmed.
    func has(_ chat: UUID?, op: String) -> Bool {
        scopes[Self.scope(chat)]?.values.contains { $0.op == op && $0.ackedAt == nil } ?? false
    }
    func isPending(_ chat: UUID?, op: String, key: String) -> Bool {
        guard let entry = scopes[Self.scope(chat)]?[op + "/" + key] else { return false }
        return entry.ackedAt == nil
    }
    func creating(_ chat: UUID) -> Bool { has(chat, op: "create") }
    func deleting(_ chat: UUID) -> Bool { scopes[chat.uuidString]?["delete/delete"] != nil }
    /// Record fields shown from changes other than `op`'s (a setting's model, say).
    func overlayKeys(_ chat: UUID, excluding op: String) -> Set<String> {
        Set((scopes[chat.uuidString] ?? [:]).values.filter { $0.op != op }.flatMap { $0.overlay?.keys.map { $0 } ?? [] })
    }
    var isEmpty: Bool { scopes.isEmpty }

    // MARK: Updates from the service

    /// A service update for a session: changes it shows (or that its revision covers) are done;
    /// the rest stay on `record`, so the update doesn't undo them.
    func project(_ record: inout ConversationRecord, revision: Int, summary: Bool) {
        let scope = record.id.uuidString
        guard var entries = scopes[scope], !entries.isEmpty else { return }
        var incoming: [String: JSON]?
        var done = false
        for (id, entry) in entries {
            if let acked = entry.ackedAt {
                if revision >= acked { entries[id] = nil; done = true }
                continue
            }
            guard entry.uncertain, entry.inFlight == nil, let overlay = entry.overlay,
                  !(summary && overlay.keys.contains(where: Self.notInSummaries.contains)) else { continue }
            if incoming == nil { incoming = record.wireFields() }
            if Self.matches(overlay, incoming!) {
                Diagnostics.note("Saved a change to \u{201C}\(record.title)\u{201D} (\(entry.op) \(entry.key)); the service had it")
                entries[id] = nil; done = true
            }
        }
        if done { scopes[scope] = entries.isEmpty ? nil : entries; saveSoon() }
        let shown = entries.values.sorted { $0.version < $1.version }.compactMap(\.overlay)
        let fields = shown.reduce(into: [String: JSON]()) { all, overlay in all.merge(overlay) { $1 } }
        if !fields.isEmpty, let merged = record.merging(fields) { record = merged }
        updateSlow()
    }

    /// Global settings the service sent: pending ones keep this Mac's value.
    func pendingPreferences() -> Set<String> {
        Set((scopes["global"] ?? [:]).values.filter { $0.op == "preferences" }.map(\.key))
    }

    private static func matches(_ overlay: [String: JSON], _ incoming: [String: JSON]) -> Bool {
        overlay.allSatisfy { key, value in
            let have = incoming[key] ?? .null
            // An archive's date is the service's own; archived or not is what matters.
            if key == "archivedAt" { return (value == .null) == (have == .null) }
            return have == value
        }
    }

    /// Connected again: everything pending goes now, in order.
    func reconnected() {
        for scope in scopes.keys {
            for id in scopes[scope]!.keys { scopes[scope]![id]!.nextAttempt = nil }
            flush(scope)
        }
    }

    // MARK: Sending

    private struct Send { var scope: String; var op: String; var operation: String; var body: JSON; var versions: [String: Int] }

    /// The request for `op`'s pending changes in `scope`, marked as being sent.
    private func prepare(_ scope: String, op: String) -> Send? {
        guard var entries = scopes[scope] else { return nil }
        let group = entries.filter { $0.value.op == op && $0.value.ackedAt == nil && $0.value.inFlight != $0.value.version }
        guard !group.isEmpty else { return nil }
        let chat = UUID(uuidString: scope)
        var body: [String: JSON] = chat.map { ["chatID": .string($0.uuidString)] } ?? [:]
        let values = group.values.reduce(into: [String: JSON]()) { $0[$1.key] = $1.value }
        switch op {
        case "create": body = ["record": values["create"] ?? .null]
        case "delete": break
        case "metadata":
            if RuntimeClient.shared.supportsMetadataFields { body["fields"] = .object(values) }
            else {
                // An older service takes the whole record: this Mac's, with these changes.
                guard let chat, let local = localRecord(chat), var record = local.merging(values) else { return nil }
                record.items = []
                body = ["record": (try? .value(record)) ?? .null]
            }
        case "settings", "preferences": body.merge(values) { $1 }
        case "setBrief": body["brief"] = values["setBrief"]
        case "archive": body["archived"] = values["archive"]
        case "remoteControl": body["enabled"] = values["remoteControl"]
        case "studios", "pins": body[op] = values[op]
        default: body.merge(values) { $1 }
        }
        var versions: [String: Int] = [:]
        for (id, entry) in group { versions[id] = entry.version; entries[id]!.inFlight = entry.version }
        scopes[scope] = entries
        return Send(scope: scope, op: op, operation: op, body: .object(body), versions: versions)
    }

    /// Sends it; whether it was applied (or can't ever be, and was given up).
    @discardableResult private func deliver(_ send: Send) async -> Bool {
        do {
            let reply = try await RuntimeClient.shared.request(send.operation, body: send.body, timeout: requestTimeout)
            settle(send, revision: reply["revision"]?.int)
            return true
        } catch {
            let message = error.localizedDescription
            if send.op == "create", message.contains("already exists") { settle(send, revision: nil); return true }
            if send.op == "delete", message == "chat_not_found" || message == "Conversation not found" { settle(send, revision: nil); return true }
            let waitsForCreate = message == "chat_not_found" && has(UUID(uuidString: send.scope), op: "create")
            if Self.permanent.contains(message), !waitsForCreate { giveUp(send, message); return true }
            failed(send, message)
            return false
        }
    }

    private func settle(_ send: Send, revision: Int?) {
        guard var entries = scopes[send.scope] else { return }
        for (id, version) in send.versions {
            guard var entry = entries[id] else { continue }
            if entry.version == version {
                if entry.failures > 0 { Diagnostics.note("Saved a change (\(entry.op) \(entry.key)) after \(entry.failures) failed tries") }
                if let revision, entry.overlay != nil, UUID(uuidString: send.scope) != nil {
                    entry.ackedAt = revision; entry.ackedDate = Date(); entry.inFlight = nil; entry.failures = 0; entry.lastError = nil
                    entries[id] = entry
                } else { entries[id] = nil }
            } else if entry.inFlight == version { entries[id]!.inFlight = nil }
        }
        scopes[send.scope] = entries.isEmpty ? nil : entries
        saveSoon(); updateSlow()
        // Changes that waited for this session to exist.
        if send.op == "create", entries.contains(where: { $0.value.ackedAt == nil }) { flush(send.scope) }
    }

    private func failed(_ send: Send, _ message: String) {
        guard var entries = scopes[send.scope] else { return }
        let sent = !message.contains("nothing was sent")
        for (id, version) in send.versions {
            guard var entry = entries[id], entry.inFlight == version else { continue }
            entry.inFlight = nil
            if entry.version == version {
                if entry.failures == 0 { Diagnostics.note("A change (\(entry.op) \(entry.key)) wasn't confirmed; retrying: \(message)") }
                entry.failures += 1; entry.lastError = message
                entry.uncertain = entry.uncertain || sent
                entry.nextAttempt = Date().addingTimeInterval(Self.backoff(entry.failures))
            }
            entries[id] = entry
        }
        scopes[send.scope] = entries
        saveSoon(); updateSlow()
    }

    private func giveUp(_ send: Send, _ message: String) {
        guard var entries = scopes[send.scope] else { return }
        for (id, version) in send.versions where entries[id]?.version == version {
            Diagnostics.note("The service refused a change (\(send.op) \(entries[id]!.key)): \(message)")
            entries[id] = nil
        }
        scopes[send.scope] = entries.isEmpty ? nil : entries
        saveSoon(); updateSlow()
        if message != "chat_not_found" { RuntimeClient.shared.report("A change wasn't saved: \(message)") }
        if let chat = UUID(uuidString: send.scope) { onSettled(chat) }
    }

    /// 1, 2, 4, 8, 16, then every 30 seconds.
    static func backoff(_ failures: Int) -> TimeInterval { min(30, pow(2, Double(max(0, failures - 1)))) }

    /// Sends a scope's pending changes in order, one request at a time; a new session first.
    private func flush(_ scope: String) {
        guard !flushing.contains(scope) else { return }
        flushing.insert(scope)
        Task {
            defer { flushing.remove(scope) }
            for op in Self.order {
                guard let send = prepare(scope, op: op) else {
                    // A new session still on its way: what follows waits for it (`settle`).
                    if op == "create", scopes[scope]?["create/create"]?.inFlight != nil { return }
                    continue
                }
                let applied = await deliver(send)
                if op == "create", !applied { return }
            }
        }
    }

    // MARK: Retrying

    private func startPump() {
        guard pump == nil else { return }
        pump = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                try? await Task.sleep(for: self.tick)
                self.service()
                if self.scopes.isEmpty { self.pump = nil; return }
            }
        }
    }

    private func service() {
        let now = Date()
        for scope in Array(scopes.keys) {
            guard var entries = scopes[scope] else { continue }
            // Applied, but no update that new came within a minute: let the service's copy show.
            let stale = entries.filter { $0.value.ackedDate.map { now.timeIntervalSince($0) > 60 } ?? false }
            if !stale.isEmpty {
                for id in stale.keys { entries[id] = nil }
                scopes[scope] = entries.isEmpty ? nil : entries
                if let chat = UUID(uuidString: scope) { onSettled(chat) }
            }
            let due = entries.values.contains { $0.ackedAt == nil && $0.inFlight != $0.version && ($0.nextAttempt ?? .distantPast) <= now }
            if due, RuntimeClient.shared.connected { flush(scope) }
        }
        updateSlow()
    }

    private func updateSlow() {
        let now = Date()
        var fresh: [String: Status] = [:]
        for (scope, entries) in scopes {
            let pending = entries.values.filter { $0.ackedAt == nil }
            guard let oldest = pending.map(\.since).min(), now.timeIntervalSince(oldest) >= slowAfter else { continue }
            let error = pending.compactMap { $0.failures > 0 ? $0.lastError : nil }.first
            fresh[scope] = error.map(Status.retrying) ?? .saving
        }
        if fresh != slow { slow = fresh }
    }

    // MARK: Keeping them across a relaunch

    private struct Saved: Codable { var schema = 1; var scopes: [String: [String: Entry]] }

    func load() {
        guard let file, let data = try? Data(contentsOf: file) else { return }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard let saved = try? decoder.decode(Saved.self, from: data), saved.schema == 1 else { return }
        let week = Date().addingTimeInterval(-7 * 86_400)
        for (scope, entries) in saved.scopes {
            var kept: [String: Entry] = [:]
            for (id, var entry) in entries where entry.since > week {
                entry.uncertain = true
                kept[id] = entry
                nextVersion = max(nextVersion, entry.version + 1)
            }
            if !kept.isEmpty { scopes[scope] = kept }
        }
        if !scopes.isEmpty {
            Diagnostics.note("\(scopes.values.map(\.count).reduce(0, +)) changes from before the relaunch weren't confirmed yet; sending them")
            startPump()
        }
    }

    private func saveSoon() {
        guard file != nil, !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.saveScheduled = false
            self.save()
        }
    }

    /// Small and rare, so written at once: a quit right after a change keeps it.
    func save() {
        guard let file else { return }
        let pending = scopes.compactMapValues { entries -> [String: Entry]? in
            let left = entries.filter { $0.value.ackedAt == nil }
            return left.isEmpty ? nil : left
        }
        if pending.isEmpty { try? FileManager.default.removeItem(at: file); return }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        do {
            try encoder.encode(Saved(scopes: pending)).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch { NSLog("Chatterbox: pending changes not saved: \(error.localizedDescription)") }
    }
}
