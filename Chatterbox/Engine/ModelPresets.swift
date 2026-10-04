import Foundation
import Observation

/// One-click agent + model + effort combinations, shown next to the model line.
struct ModelPreset: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var backend: Backend
    /// Claude model id, or Codex model (nil means Codex's default).
    var model: String?
    /// nil means the model's default effort.
    var effort: String?
    /// Switches to the default model and effort for its agent (Settings → Default models),
    /// whatever they are; its name follows them too. Editing it makes it a fixed preset.
    var followsDefault: Bool?
}

@MainActor
@Observable
final class ModelPresets {
    static let shared = ModelPresets()

    /// The presets as saved; `presets` fills in the ones that follow the defaults.
    private var saved: [ModelPreset]
    /// Bumped when the default models change, so following presets update on screen.
    private var defaultsChanged = 0
    private let key = "modelPresets"
    @ObservationIgnored private var defaultsObserver: Any?

    /// The quick switches as shown and applied: following ones resolved to today's defaults.
    var presets: [ModelPreset] {
        _ = defaultsChanged
        return saved.map(Self.resolved)
    }

    /// One for each agent's default model.
    static var defaults: [ModelPreset] {
        [ModelPreset(title: "", backend: .claude, followsDefault: true), ModelPreset(title: "", backend: .codex, followsDefault: true)]
    }

    /// The first presets, before they followed the defaults.
    private static let original: [(String, String, String)] = [("claude", "claude-opus-5-5", "medium"), ("codex", "gpt-6-astra", "low")]

    init() {
        if let data = AppPreferences.defaults.data(forKey: key),
           var saved = try? JSONDecoder().decode([ModelPreset].self, from: data) {
            // The two built-in presets, still as they first came, now follow the defaults.
            for index in saved.indices where saved[index].followsDefault == nil {
                let preset = saved[index]
                if Self.original.contains(where: { $0.0 == preset.backend.rawValue && $0.1 == preset.model && $0.2 == preset.effort }) {
                    saved[index].followsDefault = true
                }
            }
            self.saved = saved
        } else {
            saved = Self.defaults
        }
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.defaultsChanged += 1 }
        }
    }

    /// A following preset with today's default model, effort, and a name to match.
    static func resolved(_ preset: ModelPreset) -> ModelPreset {
        guard preset.followsDefault == true else { return preset }
        let defaults = AppPreferences.defaults
        var resolved = preset
        switch preset.backend {
        case .claude:
            resolved.model = defaults.string(forKey: "defaultModel").flatMap { $0.isEmpty ? nil : $0 } ?? "default"
            resolved.effort = defaults.string(forKey: "defaultEffort").flatMap { $0.isEmpty ? nil : $0 }
        case .codex:
            resolved.model = defaults.string(forKey: "codexDefaultModel").flatMap { $0.isEmpty ? nil : $0 }
            resolved.effort = defaults.string(forKey: "codexDefaultEffort").flatMap { $0.isEmpty ? nil : $0 }
        }
        resolved.title = followingTitle(resolved)
        return resolved
    }

    /// "Opus 5.5", "GPT-6.1-Sol · Low": the model by name (Claude's "Default" by the model it
    /// means), and the effort when one is set.
    private static func followingTitle(_ preset: ModelPreset) -> String {
        let model: String
        switch preset.backend {
        case .claude:
            let info = ClaudeModels.shared.info(preset.model ?? "default")
            model = info.value == "default"
                ? (ClaudeModels.shared.models.first { $0.resolvedModel == info.resolvedModel && $0.value != "default" }?.displayName ?? "Claude")
                : info.displayName
        case .codex:
            let models = CodexAppServer.shared.models
            model = preset.model.flatMap { id in models.first { $0.model == id }?.displayName }
                ?? models.first(where: \.isDefault)?.displayName ?? preset.model ?? "Codex"
        }
        return model + (preset.effort.map { " \u{00B7} " + RuntimePaths.effortLabel($0) } ?? "")
    }

    func apply(_ preset: ModelPreset, to session: ChatSession) {
        session.setBackend(preset.backend)
        guard session.record.backend == preset.backend else { return } // a turn is still running
        switch preset.backend {
        case .claude:
            if let model = preset.model { session.setModel(model) }
            session.setEffort(preset.effort ?? "")
        case .codex:
            session.setCodexModel(preset.model)
            session.setCodexEffort(preset.effort)
        }
    }

    func matches(_ preset: ModelPreset, session: ChatSession) -> Bool {
        guard session.record.backend == preset.backend else { return false }
        switch preset.backend {
        case .claude:
            return preset.model.map { ClaudeModels.shared.sameModel($0, session.record.model) } ?? true
                && (preset.effort ?? "") == session.record.effort
        case .codex:
            return preset.model == session.record.codex?.model && preset.effort == session.record.codex?.effort
        }
    }

    /// Saves the chat's current agent, model, and effort as a new preset.
    func saveCurrent(_ session: ChatSession, title: String) {
        let record = session.record
        let preset = record.backend == .claude
            ? ModelPreset(title: title, backend: .claude, model: record.model, effort: record.effort.isEmpty ? nil : record.effort)
            : ModelPreset(title: title, backend: .codex, model: record.codex?.model, effort: record.codex?.effort)
        guard !presets.contains(where: { $0.backend == preset.backend && $0.model == preset.model && $0.effort == preset.effort }) else { return }
        saved.append(preset)
        save()
    }

    /// A new preset, from Settings.
    func add(_ preset: ModelPreset) {
        saved.append(preset)
        save()
    }

    /// Changes what a preset switches to. A name that was made from the old model and
    /// effort follows them; a name you chose stays.
    func update(_ id: UUID, backend: Backend, model: String?, effort: String?) {
        guard let index = saved.firstIndex(where: { $0.id == id }) else { return }
        // Editing one that follows the defaults makes it a fixed preset, named as it was shown.
        if saved[index].followsDefault == true {
            saved[index] = Self.resolved(saved[index])
            saved[index].followsDefault = false
        }
        let wasAutomatic = saved[index].title == Self.automaticTitle(saved[index]) || saved[index].title == Self.followingTitle(saved[index])
        saved[index].backend = backend
        saved[index].model = model
        saved[index].effort = effort
        if wasAutomatic { saved[index].title = Self.automaticTitle(saved[index]) }
        save()
    }

    /// "Opus 5.5 · Medium", "GPT-6.1-Sol · Low": the name a preset gets from its settings.
    static func automaticTitle(_ preset: ModelPreset) -> String {
        let model: String
        switch preset.backend {
        case .claude: model = preset.model.map { ClaudeModels.shared.info($0).displayName } ?? "Claude"
        case .codex: model = preset.model.flatMap { id in CodexAppServer.shared.models.first { $0.model == id }?.displayName } ?? preset.model ?? "Codex"
        }
        return model + " \u{00B7} " + (preset.effort.map { RuntimePaths.effortLabel($0) } ?? "Default")
    }

    func remove(_ preset: ModelPreset) {
        saved.removeAll { $0.id == preset.id }
        save()
    }

    func rename(_ preset: ModelPreset, to title: String) {
        guard let index = saved.firstIndex(where: { $0.id == preset.id }), !title.isEmpty else { return }
        // A name of your own fixes a following preset where it is.
        if saved[index].followsDefault == true, title != Self.resolved(saved[index]).title {
            saved[index] = Self.resolved(saved[index])
            saved[index].followsDefault = false
        }
        saved[index].title = title
        save()
    }

    /// Moves a preset to where `target` is, for drag-to-reorder in the preset row.
    func move(_ id: UUID, to target: UUID) {
        guard id != target, let from = saved.firstIndex(where: { $0.id == id }),
              let to = saved.firstIndex(where: { $0.id == target }) else { return }
        saved.insert(saved.remove(at: from), at: to)
        save()
    }

    func resetToDefaults() {
        saved = Self.defaults
        save()
    }


    private func save() {
        if let data = try? JSONEncoder().encode(saved) { AppPreferences.defaults.set(data, forKey: key) }
    }
}
