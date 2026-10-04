import Foundation
import Observation

/// How full a conversation's context is, from the agent's own token counts.
struct ContextUsage: Equatable, Codable {
    /// Tokens the last request sent: the whole conversation so far, as the model saw it.
    var used: Int
    /// The model's context window, once the agent has reported it.
    var window: Int?

    var fraction: Double? {
        guard let window, window > 0 else { return nil }
        return min(1, Double(used) / Double(window))
    }
}

/// One usage-limit window, e.g. the 5-hour or 7-day allowance.
struct UsageWindow: Equatable, Identifiable {
    var id: String
    var label: String
    /// 0 to 1.
    var utilization: Double
    var resetsAt: Date?
}

/// Usage limits belong to the signed-in account, not one chat, so every chat on an agent
/// shows the same latest numbers.
@MainActor
@Observable
final class UsageLimits {
    static let shared = UsageLimits()

    private(set) var claude: [UsageWindow] = []
    private(set) var codex: [UsageWindow] = []

    func windows(for backend: Backend) -> [UsageWindow] { backend == .claude ? claude : codex }

    /// Claude Code's `rate_limit_event`: `rate_limit_info.unifiedWindows` maps a window name
    /// (`five_hour`, `seven_day`, …) to a 0–1 `utilization` and a `resetsAt` in Unix seconds.
    func updateClaude(_ info: JSON?) {
        guard let windows = info?["unifiedWindows"]?.object, !windows.isEmpty else { return }
        let order = ["five_hour", "seven_day"]
        claude = windows.compactMap { key, value -> UsageWindow? in
            guard let used = value["utilization"]?.double else { return nil }
            return UsageWindow(id: key, label: Self.claudeLabel(key), utilization: used,
                               resetsAt: value["resetsAt"]?.double.map { Date(timeIntervalSince1970: $0) })
        }
        .sorted { (order.firstIndex(of: $0.id) ?? 99, $0.id) < (order.firstIndex(of: $1.id) ?? 99, $1.id) }
    }

    /// Codex's rate-limit snapshot (`account/rateLimits/read` or the sparse
    /// `account/rateLimits/updated`): `primary` and `secondary` windows with `usedPercent`
    /// (0–100), `windowDurationMins`, and `resetsAt`. A missing window keeps its last value.
    func updateCodex(_ snapshot: JSON?) {
        guard let snapshot else { return }
        var merged = codex
        for key in ["primary", "secondary"] {
            guard let window = snapshot[key], let percent = window["usedPercent"]?.double else { continue }
            let minutes = window["windowDurationMins"]?.int
            let entry = UsageWindow(id: key, label: minutes.map(Self.durationLabel) ?? (key == "primary" ? "Primary" : "Secondary"),
                                    utilization: percent / 100,
                                    resetsAt: window["resetsAt"]?.double.map { Date(timeIntervalSince1970: $0) })
            if let index = merged.firstIndex(where: { $0.id == key }) { merged[index] = entry } else { merged.append(entry) }
        }
        codex = merged.sorted { $0.id < $1.id }
    }

    private static func claudeLabel(_ key: String) -> String {
        switch key {
        case "five_hour": return "5-hour"
        case "seven_day": return "7-day"
        default: return key.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private static func durationLabel(_ minutes: Int) -> String {
        if minutes % 1440 == 0 { return "\(minutes / 1440)-day" }
        if minutes % 60 == 0 { return "\(minutes / 60)-hour" }
        return "\(minutes)-minute"
    }
}

extension JSON {
    var double: Double? { if case .number(let n) = self { return n }; return nil }
}
