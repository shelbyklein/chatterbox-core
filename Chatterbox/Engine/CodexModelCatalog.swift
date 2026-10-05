import Foundation

/// Codex's model list, tidied: GPT models first, then Claude models (which reach Codex through
/// the proxy) under readable names ("Opus 5.5" for claude-opus-5-5). The current ones are the
/// newest of each family; older and dated versions are for "Show all models".
enum CodexModelCatalog {
    struct Entry: Identifiable, Hashable {
        var model: CodexModelInfo
        var name: String
        var isClaude: Bool
        /// The newest of its family (shown without "Show all models").
        var isCurrent: Bool
        var id: String { model.model }
    }

    /// Chat models only, in order: GPT, then Claude. `chosen` is always included.
    static func entries(_ models: [CodexModelInfo], chosen: String? = nil) -> [Entry] {
        let usable = models.filter { model in
            model.model == chosen || (!model.hidden && !model.model.hasPrefix("gpt-image") && model.model != "codex-auto-review")
        }
        var gptNewest: [String: Double] = [:], gptGeneration = 0.0
        var claudeNewest: [String: Double] = [:]
        for model in usable {
            if let (family, version) = claude(model.model) { claudeNewest[family] = max(claudeNewest[family] ?? 0, version) }
            else if let (family, version) = gpt(model.displayName) {
                gptNewest[family] = max(gptNewest[family] ?? 0, version)
                gptGeneration = max(gptGeneration, version.rounded(.down))
            }
        }
        let all = usable.map { model -> Entry in
            if let (family, version) = claude(model.model) {
                // Claude 3 and dated releases are older generations.
                let current = version >= (claudeNewest[family] ?? 0) && version >= 4
                return Entry(model: model, name: "\(family) \(format(version))", isClaude: true, isCurrent: current)
            }
            let current = gpt(model.displayName).map { family, version in
                version >= (gptNewest[family] ?? 0) && version.rounded(.down) >= gptGeneration
            } ?? true
            return Entry(model: model, name: model.displayName, isClaude: false, isCurrent: current)
        }
        return all.filter { !$0.isClaude } + all.filter(\.isClaude).sorted { order($0.name) < order($1.name) }
    }

    /// Display name for a Codex model id: "Opus 5.5" for a Claude model, else Codex's own name.
    static func name(_ id: String, models: [CodexModelInfo]) -> String {
        if let (family, version) = claude(id) { return "\(family) \(format(version))" }
        return models.first { $0.model == id }?.displayName ?? id
    }

    /// "claude-opus-5-5" → ("Opus", 5.5); "claude-haiku-4-5-20251001" → ("Haiku", 4.5).
    static func claude(_ id: String) -> (String, Double)? {
        let parts = id.lowercased().split(separator: "-").map(String.init)
        guard parts.count >= 3, parts[0] == "claude" else { return nil }
        // Old ids put the version first: claude-3-7-sonnet-…
        let familyIndex = Int(parts[1]) == nil ? 1 : parts.firstIndex { Int($0) == nil && $0 != "claude" } ?? 1
        let family = parts[familyIndex].capitalized
        let numbers = parts.filter { Int($0) != nil && $0.count < 8 }
        guard let major = numbers.first.flatMap(Double.init) else { return nil }
        let minor = numbers.count > 1 ? (Double(numbers[1]) ?? 0) : 0
        return (family, major + minor / 10)
    }

    /// "GPT-6.1-Sol" → ("Sol", 6.1).
    private static func gpt(_ name: String) -> (String, Double)? {
        let parts = name.split(separator: "-")
        guard parts.count >= 2, let version = Double(parts[1]) else { return nil }
        return (parts.dropFirst(2).joined(separator: "-"), version)
    }

    private static func format(_ version: Double) -> String {
        version == version.rounded() ? String(Int(version)) : String(format: "%.1f", version)
    }

    private static func order(_ name: String) -> Int {
        ["Fable", "Opus", "Sonnet", "Haiku"].firstIndex { name.hasPrefix($0) } ?? 9
    }
}
