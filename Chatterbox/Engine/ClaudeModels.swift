import Foundation
import Observation

/// One model Claude Code offers, as its startup handshake reports it.
struct ClaudeCodeModel: Identifiable, Hashable {
    var id: String { value }
    /// What goes to `--model`: an alias such as "opus" or a full model id.
    var value: String
    /// The model the alias currently points to, e.g. "claude-opus-5-5".
    var resolvedModel: String
    var displayName: String
    var detail: String
    /// Effort levels the model accepts, weakest first. Empty means no effort control.
    var efforts: [String]

    /// Its full name, "Opus 5.5": Claude Code's description starts with it ("Opus 5.5 · Best
    /// for everyday, complex tasks · …"); else the display name ("Opus").
    var fullName: String { Self.split(displayName, detail).name }
    /// The description without that name: "Best for everyday, complex tasks · $4/$20 per Mtok".
    var summary: String { Self.split(displayName, detail).rest }

    private static func split(_ name: String, _ detail: String) -> (name: String, rest: String) {
        let parts = detail.components(separatedBy: " \u{00B7} ")
        guard let first = parts.first, first.count > name.count, first.lowercased().hasPrefix(name.lowercased()) else { return (name, detail) }
        return (first, parts.dropFirst().joined(separator: " \u{00B7} "))
    }

    static func unknown(_ value: String) -> ClaudeCodeModel {
        ClaudeCodeModel(value: value, resolvedModel: value, displayName: value, detail: "",
                        efforts: ["low", "medium", "high", "xhigh", "max"])
    }
}

/// The Claude models and account from the user's Claude Code install. Loaded at first use and
/// again once an hour old, so a model Claude Code adds (an update, a new release) appears
/// without restarting the app or the background service.
@MainActor
@Observable
final class ClaudeModels {
    static let shared = ClaudeModels()

    private(set) var models: [ClaudeCodeModel] = []
    /// Slash commands and skills available everywhere (a chat adds its project's own).
    private(set) var commands: [SlashCommand] = []
    private(set) var accountEmail: String?
    private(set) var plan: String?
    /// Set when Claude Code is missing or couldn't start.
    private(set) var statusMessage: String?
    @ObservationIgnored private var loading = false
    @ObservationIgnored private var loadedAt = Date.distantPast

    /// The model for a `--model` value, matching aliases and full ids alike. A full id
    /// ("claude-opus-5-5") names its own model (Opus 5.5) before "Default", which may point
    /// to the same one today.
    func info(_ value: String) -> ClaudeCodeModel {
        models.first { $0.value == value }
            ?? models.first { $0.resolvedModel == value && $0.value != "default" }
            ?? models.first { $0.resolvedModel == value }
            ?? .unknown(value)
    }

    /// Models out before Claude Code's picker lists them, each placed just above the one it
    /// follows: the full id works with `--model` already (Fable 5.2, 2026-11-09). An entry
    /// steps aside once Claude Code lists that model itself.
    static let newerThanClaudeCode: [(follows: String, id: String, oldName: String, newName: String)] = [
        ("claude-fable-5-1", "claude-fable-5-2", "Fable 5.1", "Fable 5.2"),
    ]

    /// Claude Code's models, with `newerThanClaudeCode` added above the model each follows
    /// (keeping its 1M-context suffix, efforts and description, renamed).
    static func addingNewer(_ models: [ClaudeCodeModel]) -> [ClaudeCodeModel] {
        var result = models
        for newer in newerThanClaudeCode {
            let listed = result.contains { $0.value.hasPrefix(newer.id) || $0.resolvedModel.hasPrefix(newer.id) }
            guard !listed, let index = result.firstIndex(where: { $0.value.hasPrefix(newer.follows) || $0.resolvedModel.hasPrefix(newer.follows) }) else { continue }
            let old = result[index]
            var added = old
            added.value = old.value.replacingOccurrences(of: newer.follows, with: newer.id)
            added.resolvedModel = old.resolvedModel.replacingOccurrences(of: newer.follows, with: newer.id)
            added.detail = old.detail.replacingOccurrences(of: newer.oldName, with: newer.newName)
            result.insert(added, at: index)
        }
        return result
    }

    /// Whether two `--model` values currently mean the same model ("opus" and "claude-opus-5-5").
    func sameModel(_ a: String, _ b: String) -> Bool {
        a == b || info(a).resolvedModel == info(b).resolvedModel
    }

    func refresh(force: Bool = false) async {
        guard !loading, force || models.isEmpty || Date().timeIntervalSince(loadedAt) > 3600 else { return }
        loading = true
        defer { loading = false }
        do {
            let info = try await ClaudeCodeInfo.probe()
            models = Self.addingNewer(info.models)
            loadedAt = Date()
            commands = info.commands
            accountEmail = info.accountEmail
            plan = info.plan
            // A token sign-in (CLAUDE_CODE_OAUTH_TOKEN) reports no account, so ask Claude Code directly.
            let signedIn = info.accountEmail != nil ? true : await ClaudeCodeInfo.isLoggedIn()
            statusMessage = signedIn ? nil : "Claude Code isn't signed in. Run `claude` in Terminal and log in."
        } catch is CancellationError {
            // A refresh cut short (a newer one, or the app quitting) says nothing about Claude Code.
        } catch {
            statusMessage = error.localizedDescription
        }
    }
}
