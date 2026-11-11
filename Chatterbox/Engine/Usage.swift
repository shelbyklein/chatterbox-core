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

/// Durable usage metadata. Telemetry errors never interrupt an agent turn.
enum TokenLedgerReporter {
    static func record(eventID: String, app: String, session: String, task: String?, provider: String,
                       model: String?, input: Int?, output: Int?, cached: Int?, written: Int?, reasoning: Int? = nil,
                       includesCache: Bool, cumulative: Bool = false) {
        guard input != nil || output != nil else { return }
        let env = ProcessInfo.processInfo.environment
        let root = env["TOKENLEDGER_EVENTS_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/TokenLedger/events")
        var event: [String: Any] = ["version": 1, "event_id": eventID, "app": app,
            "machine": ProcessInfo.processInfo.hostName, "session_id": session, "provider": provider,
            "timestamp": ISO8601DateFormatter().string(from: Date()), "source": "native",
            "input_includes_cache": includesCache, "counter_kind": cumulative ? "cumulative" : "request"]
        event["task_id"] = task; event["model"] = model
        event["input_tokens"] = input; event["output_tokens"] = output
        event["cached_input_tokens"] = cached; event["cache_write_tokens"] = written; event["reasoning_tokens"] = reasoning
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            // One file per process avoids cross-process append races; importer deduplicates replayed IDs.
            let file = root.appendingPathComponent("\(app)-\(ProcessInfo.processInfo.processIdentifier).jsonl")
            if !FileManager.default.fileExists(atPath: file.path) {
                guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { return }
            }
            let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
            try handle.seekToEnd()
            var data = try JSONSerialization.data(withJSONObject: event); data.append(10)
            try handle.write(contentsOf: data)
        } catch { /* Collection must never affect chat execution. */ }
    }
}
