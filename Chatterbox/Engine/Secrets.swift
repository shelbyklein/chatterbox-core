import CryptoKit
import Foundation
import Observation
import Security

/// API keys, tokens, and account passwords for agents to use without seeing them.
///
/// Values live in the login Keychain (this device only); the names, notes, and scopes in
/// Application Support. A chat in scope gets each secret as an environment variable for the
/// commands its agent runs, and is told only the variable's name and what it's for. Any value
/// that turns up in a transcript is masked before it's shown or saved.
struct SecretEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    /// What you call it ("Stripe test key").
    var name: String
    /// The environment variable ("STRIPE_TEST_KEY").
    var variable: String
    /// What it's for, told to agents ("Stripe test mode, for the PlayCase store").
    var note: String = ""
    /// For an account: the user name (not secret; agents get it as <VARIABLE>_USER).
    var username: String = ""
    /// Empty: every chat. Otherwise, only chats in these project folders.
    var projects: [String] = []
    var created = Date()

    var isAccount: Bool { !username.isEmpty }

    /// Letters, digits, and underscores, starting with a letter.
    static func variableName(from text: String) -> String {
        let cleaned = text.uppercased()
            .replacingOccurrences(of: "[^A-Z0-9]+", with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return cleaned.first?.isLetter == true ? cleaned : (cleaned.isEmpty ? "" : "SECRET_" + cleaned)
    }

    static func isValidVariable(_ text: String) -> Bool {
        text.range(of: "^[A-Z][A-Z0-9_]*$", options: .regularExpression) != nil
    }
}

@MainActor
@Observable
final class SecretVault {
    static let shared = SecretVault()
    private static let service = "com.shelbyklein.Chatterbox.secrets"

    private(set) var entries: [SecretEntry] = []
    /// Values, read from Keychain once; never shown in the app.
    @ObservationIgnored private var values: [UUID: String] = [:]
    /// Bumped on every change, so chats can tell their environment needs refreshing.
    private(set) var revision = 0

    private var file: URL {
        let base: URL
        if let dir = ProcessInfo.processInfo.environment["CHATTERBOX_DATA_DIR"], !dir.isEmpty {
            base = URL(fileURLWithPath: dir)
        } else {
            base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Chatterbox")
        }
        return base.appendingPathComponent("Secrets.json")
    }

    private var isTest: Bool { ProcessInfo.processInfo.environment["CHATTERBOX_DATA_DIR"] != nil }

    init() {
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([SecretEntry].self, from: data) {
            entries = saved
        }
        for entry in entries { values[entry.id] = Self.read(entry.id, test: isTest) }
    }

    func hasValue(_ entry: SecretEntry) -> Bool { !(values[entry.id] ?? "").isEmpty }

    /// Adds or updates an entry. A nil value keeps the one already stored.
    func save(_ entry: SecretEntry, value: String?) throws {
        if let value, !value.isEmpty {
            try Self.write(value, for: entry.id, test: isTest)
            values[entry.id] = value
        }
        if let index = entries.firstIndex(where: { $0.id == entry.id }) { entries[index] = entry } else { entries.append(entry) }
        persist()
    }

    func remove(_ entry: SecretEntry) {
        Self.delete(entry.id, test: isTest)
        values[entry.id] = nil
        entries.removeAll { $0.id == entry.id }
        persist()
    }

    private func persist() {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(entries) { try? data.write(to: file, options: .atomic) }
        revision += 1
    }

    // MARK: - For chats

    func entries(for session: ChatSession) -> [SecretEntry] {
        let folder = (session.record.sidechatProjectFolder ?? session.convertedProjectScope ?? session.record.worktreeOf ?? session.record.projectFolder).map(RuntimePaths.normalize)
        return entries.filter { entry in
            hasValue(entry) && (entry.projects.isEmpty || folder.map { f in entry.projects.contains { RuntimePaths.normalize($0) == f } } == true)
        }
    }

    /// The variables for a chat's commands.
    func environment(for session: ChatSession) -> [String: String] {
        var env: [String: String] = [:]
        for entry in entries(for: session) {
            env[entry.variable] = values[entry.id]
            if entry.isAccount { env[entry.variable + "_USER"] = entry.username }
        }
        return env
    }

    /// Changes whenever what a chat would get changes (values included, as a hash).
    func fingerprint(for session: ChatSession) -> String {
        let env = environment(for: session).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
        return env.isEmpty ? "" : SHA256.hash(data: Data(env.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// What the agent is told: names and purposes, never values.
    func note(for session: ChatSession) -> String? {
        let available = entries(for: session)
        guard !available.isEmpty else { return nil }
        let lines = available.map { entry -> String in
            var line = "- $\(entry.variable)" + (entry.isAccount ? " (password) and $\(entry.variable)_USER (user name)" : "") + ": \(entry.name)"
            if !entry.note.isEmpty { line += " — " + entry.note }
            return line
        }
        return """
        <app_note>
        The user saved these for you to use. They're environment variables in every command you run; you don't see the values:
        \(lines.joined(separator: "\n"))
        Use them only by reference, as in curl -H "Authorization: Bearer $NAME". Never print, echo, log, or write a value into a file, a commit, a message, or a reply, and don't pass one to a site or service other than the one it's for. If one is missing or wrong, ask the user to update it in Chatterbox → Settings → Secrets.
        </app_note>
        """
    }

    /// Masks any saved value in text (8 characters or longer, so short words aren't caught).
    func redact(_ text: String) -> String {
        var result = text
        for entry in entries {
            guard let value = values[entry.id], value.count >= 8, result.contains(value) else { continue }
            result = result.replacingOccurrences(of: value, with: "••••(\(entry.variable))")
        }
        return result
    }

    var hasRedactableValues: Bool { values.values.contains { $0.count >= 8 } }

    // MARK: - Keychain (a JSON file in the test data folder instead, under tests)

    private static func testFile(_ id: UUID) -> URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["CHATTERBOX_DATA_DIR"] ?? NSTemporaryDirectory())
            .appendingPathComponent("test-secret-\(id.uuidString)")
    }

    private static func read(_ id: UUID, test: Bool) -> String? {
        if test { return try? String(contentsOf: testFile(id), encoding: .utf8) }
        var value: CFTypeRef?
        let status = SecItemCopyMatching([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: id.uuidString,
                                          kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne,
                                          kSecUseAuthenticationUI: kSecUseAuthenticationUIFail] as CFDictionary, &value)
        guard status == errSecSuccess, let data = value as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func write(_ value: String, for id: UUID, test: Bool) throws {
        if test { try value.write(to: testFile(id), atomically: true, encoding: .utf8); return }
        let query = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: id.uuidString] as CFDictionary
        let data = Data(value.utf8)
        var status = SecItemUpdate(query, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: id.uuidString,
                                 kSecAttrLabel: "Chatterbox secret", kSecValueData: data,
                                 kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw NSError(domain: "Chatterbox", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Couldn't save it in Keychain (\(status))."])
        }
    }

    private static func delete(_ id: UUID, test: Bool) {
        if test { try? FileManager.default.removeItem(at: testFile(id)); return }
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: id.uuidString] as CFDictionary)
    }
}

extension ChatSession {
    /// Sent once whenever what this chat may use changes.
    func takeSecretsUpdate() -> String? {
        let vault = SecretVault.shared
        let key = vault.entries(for: self).map { "\($0.variable):\($0.note):\($0.username)" }.joined(separator: "|")
        guard key != (record.sentSecretsKey ?? "") else { return nil }
        record.sentSecretsKey = key
        return vault.note(for: self) ?? "<app_note>\nThe saved secrets you were told about earlier are no longer available.\n</app_note>"
    }

    /// Masks saved secret values in the transcript before it's shown or written to disk.
    func redactSecrets() {
        let vault = SecretVault.shared
        guard vault.hasRedactableValues else { return }
        for index in record.items.indices {
            let text = vault.redact(record.items[index].text)
            if text != record.items[index].text { record.items[index].text = text }
            if let detail = record.items[index].detail {
                let masked = vault.redact(detail)
                if masked != detail { record.items[index].detail = masked }
            }
        }
    }
}
