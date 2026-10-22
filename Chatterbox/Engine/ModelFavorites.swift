import Foundation
import Observation

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

/// The models you pick most, numbered in the model popover (press 1–9), and the effort a
/// switch keeps. Favorites replaced presets: they're models only; effort is the slider.
/// Saved as JSON text so the background service (which answers the phone) gets them too.
@MainActor
@Observable
final class ModelFavorites {
    static let shared = ModelFavorites()
    static let key = "modelFavorites"
    static func lastKey(_ kind: SessionKind) -> String { "lastModel." + kind.rawValue }
    /// Effort levels from least to most, for keeping the closest one across a switch.
    static let effortOrder = ["minimal", "low", "medium", "high", "xhigh", "max"]

    private(set) var favorites: [ModelChoice]
    @ObservationIgnored private var observer: Any?

    init() {
        if let saved = Self.load() {
            favorites = saved
        } else {
            // First run: the presets you had become your favorites, in order.
            favorites = Self.fromPresets()
            #if !CHATTERBOX_HEADLESS
            save()
            #endif
        }
        #if CHATTERBOX_HEADLESS
        // The service: take favorites edited in the app as they arrive.
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if let fresh = Self.load(), fresh != self?.favorites { self?.favorites = fresh }
            }
        }
        #endif
    }

    private static func load() -> [ModelChoice]? {
        guard let text = AppPreferences.defaults.string(forKey: key) else { return nil }
        return try? JSONDecoder().decode([ModelChoice].self, from: Data(text.utf8))
    }

    static func fromPresets() -> [ModelChoice] {
        var choices: [ModelChoice] = []
        for preset in ModelPresets.shared.presets {
            let choice = ModelChoice(backend: preset.backend, model: preset.backend == .claude ? (preset.model ?? "default") : preset.model)
            if !choices.contains(choice) { choices.append(choice) }
        }
        return choices
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(favorites), let text = String(data: data, encoding: .utf8) else { return }
        AppPreferences.defaults.set(text, forKey: Self.key)
    }

    // MARK: - Favorites

    func isFavorite(_ choice: ModelChoice) -> Bool { favorites.contains(choice) }

    func toggle(_ choice: ModelChoice) {
        if let index = favorites.firstIndex(of: choice) { favorites.remove(at: index) } else { favorites.append(choice) }
        save()
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        var moved = favorites
        let items = source.sorted().map { moved[$0] }
        for index in source.sorted(by: >) { moved.remove(at: index) }
        let target = destination - source.filter { $0 < destination }.count
        moved.insert(contentsOf: items, at: max(0, min(target, moved.count)))
        favorites = moved
        save()
    }

    func set(_ list: [ModelChoice]) {
        favorites = list
        save()
    }

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
