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

    static func unknown(_ value: String) -> ClaudeCodeModel {
        ClaudeCodeModel(value: value, resolvedModel: value, displayName: value, detail: "",
                        efforts: ["low", "medium", "high", "xhigh", "max"])
    }
}

/// The Claude models and account from the user's Claude Code install, loaded once per launch.
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

    /// The model for a `--model` value, matching aliases and full ids alike. A full id
    /// ("claude-opus-5-5") names its own model (Opus 5.5) before "Default", which may point
    /// to the same one today.
    func info(_ value: String) -> ClaudeCodeModel {
        models.first { $0.value == value }
            ?? models.first { $0.resolvedModel == value && $0.value != "default" }
            ?? models.first { $0.resolvedModel == value }
            ?? .unknown(value)
    }

    /// Whether two `--model` values currently mean the same model ("opus" and "claude-opus-5-5").
    func sameModel(_ a: String, _ b: String) -> Bool {
        a == b || info(a).resolvedModel == info(b).resolvedModel
    }

    func refresh(force: Bool = false) async {
        guard !loading, force || models.isEmpty else { return }
        loading = true
        defer { loading = false }
        do {
            let info = try await ClaudeCodeInfo.probe()
            models = info.models
            commands = info.commands
            accountEmail = info.accountEmail
            plan = info.plan
            statusMessage = info.accountEmail == nil ? "Claude Code isn't signed in. Run `claude` in Terminal and log in." : nil
        } catch {
            statusMessage = error.localizedDescription
        }
    }
}
