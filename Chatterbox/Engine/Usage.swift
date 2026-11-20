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
struct UsageWindow: Equatable, Identifiable, Codable {
    var id: String
    var label: String
    /// 0 to 1.
    var utilization: Double
    var resetsAt: Date?
    /// How fast it's being used lately, and when it would run out at that pace.
    var burn: UsageBurn?
}

/// The pace a limit is used at, from its recent readings.
struct UsageBurn: Equatable, Codable {
    /// Share of the limit per hour (0.12 = 12% an hour).
    var perHour: Double
    /// When it would be all used at this pace; nil while it isn't going up.
    var runsOutAt: Date?
    /// Runs out before the window resets.
    var beforeReset: Bool

    /// From readings (oldest first) over the last hour or so: the slope between the first
    /// and the last, once they're at least five minutes apart.
    static func from(_ readings: [(at: Date, used: Double)], now: Date, resetsAt: Date?) -> UsageBurn? {
        let recent = readings.filter { now.timeIntervalSince($0.at) <= 75 * 60 }
        guard let first = recent.first, let last = recent.last else { return nil }
        let span = last.at.timeIntervalSince(first.at)
        guard span >= 5 * 60 else { return nil }
        let perHour = max(0, (last.used - first.used) / span * 3600)
        let runsOut = perHour > 0.0001 ? last.at.addingTimeInterval((1 - last.used) / perHour * 3600) : nil
        return UsageBurn(perHour: perHour, runsOutAt: runsOut,
                         beforeReset: runsOut.map { run in resetsAt.map { run < $0 } ?? true } ?? false)
    }
}

/// A limit has fallen to 50%, 20% or 5% left: once each per window (per reset).
struct UsageWarning: Equatable {
    var backend: Backend
    var window: UsageWindow
    /// The share left that was crossed: 0.5, 0.2 or 0.05.
    var left: Double

    var title: String { "\(backend.label): \(Int((left * 100).rounded()))% of your \(window.label) limit left" }
    var body: String {
        var parts: [String] = []
        if let burn = window.burn, burn.perHour > 0.0001 {
            parts.append("Using about \(Int((burn.perHour * 100).rounded()))% an hour.")
            if let run = burn.runsOutAt {
                parts.append("At this pace it runs out \(UsageWarning.time(run))" + (burn.beforeReset ? ", before it resets." : "."))
            }
        }
        if let reset = window.resetsAt { parts.append("Resets \(UsageWarning.time(reset)).") }
        return parts.joined(separator: " ")
    }

    static func time(_ date: Date) -> String {
        Calendar.current.isDateInToday(date) ? "at " + date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.weekday(.wide).hour().minute())
    }
}

/// Usage limits belong to the signed-in account, not one chat, so every chat on an agent
/// shows the same latest numbers.
@MainActor
@Observable
final class UsageLimits {
    static let shared = UsageLimits()

    private(set) var claude: [UsageWindow] = []
    private(set) var codex: [UsageWindow] = []

    /// Called when a limit falls to 50%, 20% or 5% left (the service posts it to the Mac and
    /// the phone). Once per level per window, kept across restarts.
    @ObservationIgnored var onWarning: (UsageWarning) -> Void = { _ in }
    /// Readings per backend and window, for the burn rate: the last two hours or so.
    @ObservationIgnored private var readings: [String: [(at: Date, used: Double)]] = [:]
    @ObservationIgnored var now: () -> Date = Date.init
    static let warningLevels: [Double] = [0.5, 0.2, 0.05]
    private static let warnedKey = "usageWarnedLevels"

    func windows(for backend: Backend) -> [UsageWindow] { backend == .claude ? claude : codex }

    /// The Mac app with the background service: the service's numbers, as they are (the
    /// service keeps the readings and warns; the app only shows them).
    func show(claude: [UsageWindow], codex: [UsageWindow]) {
        if claude != self.claude { self.claude = claude }
        if codex != self.codex { self.codex = codex }
    }

    /// Claude Code's `rate_limit_event`: `rate_limit_info.unifiedWindows` maps a window name
    /// (`five_hour`, `seven_day`, …) to a 0–1 `utilization` and a `resetsAt` in Unix seconds.
    func updateClaude(_ info: JSON?) {
        guard let windows = info?["unifiedWindows"]?.object, !windows.isEmpty else { return }
        let order = ["five_hour", "seven_day"]
        let fresh = windows.compactMap { key, value -> UsageWindow? in
            guard let used = value["utilization"]?.double else { return nil }
            return UsageWindow(id: key, label: Self.claudeLabel(key), utilization: used,
                               resetsAt: value["resetsAt"]?.double.map { Date(timeIntervalSince1970: $0) })
        }
        .sorted { (order.firstIndex(of: $0.id) ?? 99, $0.id) < (order.firstIndex(of: $1.id) ?? 99, $1.id) }
        claude = fresh.map { track(.claude, $0) }
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
        codex = merged.sorted { $0.id < $1.id }.map { track(.codex, $0) }
    }

    /// Keeps the reading for the burn rate, adds the burn rate, and warns on a level crossed.
    private func track(_ backend: Backend, _ window: UsageWindow) -> UsageWindow {
        let key = backend.rawValue + "." + window.id
        let time = now()
        var list = readings[key] ?? []
        // A drop means the window reset: start over.
        if let last = list.last, window.utilization < last.used - 0.02 { list = [] }
        if list.last?.used != window.utilization || list.last.map({ time.timeIntervalSince($0.at) >= 60 }) ?? true {
            list.append((time, window.utilization))
        }
        list.removeAll { time.timeIntervalSince($0.at) > 2 * 3600 }
        readings[key] = list
        var result = window
        result.burn = UsageBurn.from(list, now: time, resetsAt: window.resetsAt)
        warnIfCrossed(backend, result, key: key)
        return result
    }

    private func warnIfCrossed(_ backend: Backend, _ window: UsageWindow, key: String) {
        let left = 1 - window.utilization
        // The lowest level reached; one warning, not one per level skipped past.
        guard let level = Self.warningLevels.last(where: { left <= $0 + 0.000_1 }) else { return }
        // Per window period: a new resetsAt starts the levels over.
        let period = window.resetsAt.map { String(Int($0.timeIntervalSince1970 / 60)) } ?? "none"
        let defaults = AppPreferences.defaults
        var warned = defaults.dictionary(forKey: Self.warnedKey) as? [String: String] ?? [:]
        let previous = warned[key].flatMap { entry -> (period: String, level: Double)? in
            let parts = entry.split(separator: "|")
            guard parts.count == 2, let level = Double(parts[1]) else { return nil }
            return (String(parts[0]), level)
        }
        if let previous, previous.period == period, previous.level <= level + 0.000_1 { return }
        warned[key] = "\(period)|\(level)"
        defaults.set(warned, forKey: Self.warnedKey)
        onWarning(UsageWarning(backend: backend, window: window, left: level))
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
