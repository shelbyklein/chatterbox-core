import Foundation

struct RuntimeRequest: Codable {
    var version = 1
    var id: String = UUID().uuidString
    var operation: String
    var body: JSON = [:]
}
struct RuntimeReply: Codable {
    var id: String?
    var result: JSON?
    var error: String?
    var event: RuntimeEvent?
}
extension JSON {
    static func value<T: Encodable>(_ value: T) throws -> JSON {
        let e=JSONEncoder();e.dateEncodingStrategy = .iso8601
        return try JSON.parse(e.encode(value))
    }
    func decode<T: Decodable>(_ type:T.Type) throws -> T {
        let d=JSONDecoder();d.dateDecodingStrategy = .iso8601
        return try d.decode(type,from:encoded())
    }
}

/// The chat fields the Mac sets with the service's "metadata" op (RuntimeServer.applyMetadata),
/// by their wire names. The Mac sends only the ones it changed (`fields`), so a stale copy of
/// the rest can't overwrite what changed on the service meanwhile (the phone, an agent).
extension ConversationRecord {
    static let metadataKeys: [String] = [
        "title", "activeBackend", "model", "effort", "personality", "projectNickname", "tags",
        "projectFolder", "studioID", "studioFolder", "sidechatOf", "sidechatFolder", "sidechatProjectFolder",
        "studioWorkingFolder", "convertedProjectFolder", "worktreeOf", "worktreeBranch",
        "githubRepo", "gitRemote", "claudeMode", "claudeFastMode", "remoteControl", "currentIssue", "codex",
    ]
    /// The record's fields as the wire has them, without its transcript; a missing optional is null.
    func wireFields() -> [String: JSON] {
        var copy = self; copy.items = []
        return (try? JSON.value(copy).object) ?? [:]
    }
    /// The metadata fields (`metadataKeys`), each present (null when unset).
    func metadataFields() -> [String: JSON] {
        let all = wireFields()
        return Dictionary(uniqueKeysWithValues: Self.metadataKeys.map { ($0, all[$0] ?? .null) })
    }
    /// This record with `fields` (wire values by name) in place of its own, transcript kept;
    /// nil when they don't decode.
    func merging(_ fields: [String: JSON]) -> ConversationRecord? {
        guard !fields.isEmpty else { return self }
        var object = wireFields()
        for (key, value) in fields { object[key] = value }
        guard var merged = try? JSON.object(object).decode(ConversationRecord.self) else { return nil }
        merged.items = items
        return merged
    }
}
