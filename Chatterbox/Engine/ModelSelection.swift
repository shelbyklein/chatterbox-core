import Foundation

/// A model to switch to: the agent and its model ("opus", "gpt-6.1-sol"). A Codex model of
/// nil is Codex's own default.
struct ModelChoice: Codable, Hashable {
    var backend: Backend
    var model: String?
}

/// What a kind of session last ran on, so the next one of that kind starts there.
struct LastModel: Codable, Equatable {
    var backend: Backend
    var model: String?
    var effort: String?
}

/// Sessions start on what their own kind last used.
enum SessionKind: String, CaseIterable {
    case chats, studios, projects

    @MainActor static func of(_ session: ChatSession) -> SessionKind {
        if session.record.studioID != nil { return .studios }
        return ToolScopes.projectFolder(of: session) != nil ? .projects : .chats
    }
}

/// Switching a session's model (keeping the closest effort) and remembering what each kind
/// of session last used, so the next one starts there. Saved as JSON text, so the background
/// service, which starts sessions for the phone too, gets it.
@MainActor
final class ModelSelection {
    static let shared = ModelSelection()
    static func lastKey(_ kind: SessionKind) -> String { "lastModel." + kind.rawValue }
    /// Effort levels from least to most, for keeping the closest one across a switch.
    static let effortOrder = ["minimal", "low", "medium", "high", "xhigh", "max"]

    // MARK: - Names and efforts

    /// "Opus 5.5", "GPT-6.1-Sol", "Codex default".
    static func name(_ choice: ModelChoice) -> String {
        switch choice.backend {
        case .claude:
            let info = ClaudeModels.shared.info(choice.model ?? "default")
            if info.value == "default",
               let meant = ClaudeModels.shared.models.first(where: { $0.resolvedModel == info.resolvedModel && $0.value != "default" }) {
                return "Default (\(meant.displayName))"
            }
            return info.displayName
        case .codex:
            let models = CodexAppServer.shared.models
            return choice.model.map { CodexModelCatalog.name($0, models: models) } ?? "Codex default"
        }
    }

    /// The effort levels a model takes, least first ("" isn't one: it's the model's default).
    static func efforts(_ choice: ModelChoice) -> [String] {
        switch choice.backend {
        case .claude:
            return ClaudeModels.shared.info(choice.model ?? "default").efforts
        case .codex:
            let models = CodexAppServer.shared.models
            let model = models.first { $0.model == choice.model } ?? models.first(where: \.isDefault)
            return model?.efforts ?? ["low", "medium", "high"]
        }
    }

    /// The level `effort` comes closest to among `efforts` ("" stays the default).
    static func closest(_ effort: String, in efforts: [String]) -> String {
        guard !effort.isEmpty, !efforts.isEmpty else { return "" }
        if efforts.contains(effort) { return effort }
        guard let rank = effortOrder.firstIndex(of: effort) else { return "" }
        return efforts.min { a, b in
            abs((effortOrder.firstIndex(of: a) ?? rank) - rank) < abs((effortOrder.firstIndex(of: b) ?? rank) - rank)
        } ?? ""
    }

    // MARK: - A session's model

    static func current(_ session: ChatSession) -> ModelChoice {
        session.record.backend == .claude
            ? ModelChoice(backend: .claude, model: session.record.model)
            : ModelChoice(backend: .codex, model: session.record.codex?.model)
    }

    static func effort(_ session: ChatSession) -> String {
        session.record.backend == .claude ? session.record.effort : session.record.codex?.effort ?? ""
    }

    /// Switches the session to `choice`, keeping the closest effort, and remembers it for
    /// the next session of its kind. Nothing reaches the agent until the next message.
    func choose(_ choice: ModelChoice, for session: ChatSession) {
        let effort = Self.closest(Self.effort(session), in: Self.efforts(choice))
        Self.apply(choice, effort: effort, to: session)
        remember(LastModel(backend: choice.backend, model: choice.model, effort: effort.isEmpty ? nil : effort), for: session)
    }

    /// Sets the session's effort ("" is the model's default) and remembers it.
    func setEffort(_ effort: String, for session: ChatSession) {
        switch session.record.backend {
        case .claude: session.setEffort(effort)
        case .codex: session.setCodexEffort(effort.isEmpty ? nil : effort)
        }
        let choice = Self.current(session)
        remember(LastModel(backend: choice.backend, model: choice.model, effort: effort.isEmpty ? nil : effort), for: session)
    }

    static func apply(_ choice: ModelChoice, effort: String, to session: ChatSession) {
        if session.record.backend != choice.backend { session.setBackend(choice.backend) }
        switch choice.backend {
        case .claude:
            session.setModel(choice.model ?? "default")
            session.setEffort(effort)
        case .codex:
            session.setCodexModel(choice.model)
            session.setCodexEffort(effort.isEmpty ? nil : effort)
        }
    }

    // MARK: - Last used

    func remember(_ last: LastModel, for session: ChatSession) {
        guard !session.isDot, let data = try? JSONEncoder().encode(last), let text = String(data: data, encoding: .utf8) else { return }
        AppPreferences.defaults.set(text, forKey: Self.lastKey(SessionKind.of(session)))
    }

    static func lastUsed(_ kind: SessionKind) -> LastModel? {
        guard let text = AppPreferences.defaults.string(forKey: lastKey(kind)) else { return nil }
        return try? JSONDecoder().decode(LastModel.self, from: Data(text.utf8))
    }

    /// A new session starts on what its kind last used. One started on a named agent
    /// ("New Codex Session") keeps that agent, so it takes the last model only if it matches.
    static func startLikeLast(_ session: ChatSession, kind: SessionKind, requested backend: Backend? = nil) {
        guard let last = lastUsed(kind), backend == nil || backend == last.backend else { return }
        let choice = ModelChoice(backend: last.backend, model: last.model)
        apply(choice, effort: closest(last.effort ?? "", in: efforts(choice)), to: session)
    }
}
