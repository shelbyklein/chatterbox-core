import Foundation
import CoreFoundation
import Observation

struct ProxyQuotaWindow: Identifiable {
    var id: String { title }
    var title: String
    var remaining: Double?
    var reset: Date?
}
struct ProxyQuotaAccount: Identifiable {
    var id: String
    var provider: String
    var name: String
    var disabled: Bool
    var windows: [ProxyQuotaWindow] = []
    var problem: String?
    var checked: Date?
    var status: String {
        if disabled { return "Disabled" }
        if problem != nil { return "Unavailable" }
        if windows.contains(where: { $0.remaining == 0 }) { return "Limited" }
        return windows.contains(where: { $0.remaining != nil }) ? "Available" : "Unknown"
    }
}

/// Read-only management requests. Provider tokens stay inside EasyCLIProxy.
@MainActor @Observable final class ProxyQuotaStore {
    static let shared = ProxyQuotaStore()
    var accounts: [ProxyQuotaAccount] = []
    var refreshing = false
    var problem: String?
    var lastRefresh: Date?

    struct Connection {
        let base: URL
        let key: String
    }
    static func connection() throws -> Connection {
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/com.cpa.gui/config.toml")
        guard let text = try? String(contentsOf: path, encoding: .utf8) else { throw Failure("EasyCLIProxy configuration wasn't found. Open EasyCLIProxyAPI first.") }
        func value(_ name: String) -> String? {
            guard let line = text.split(separator: "\n").first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix(name + " =") }), let eq = line.firstIndex(of: "=") else { return nil }
            let raw = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if raw.hasPrefix("\"") { return (try? JSONSerialization.jsonObject(with: Data(raw.utf8), options: .fragmentsAllowed)) as? String }
            return raw
        }
        guard let key = value("management-secret-key"), !key.isEmpty else { throw Failure("EasyCLIProxy's management key is unavailable. Configure it in EasyCLIProxyAPI.") }
        let port = Int(value("port") ?? "8317") ?? 8317
        guard (1...65535).contains(port), let base = URL(string: "http://127.0.0.1:\(port)/v0/management/") else { throw Failure("Invalid local proxy port.") }
        return Connection(base: base, key: key)
    }
    struct Failure: LocalizedError { let message: String; init(_ message: String) { self.message = message }; var errorDescription: String? { message } }
    private func request(_ path: String, connection: Connection, body: [String: Any]? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: connection.base.appendingPathComponent(path))
        request.timeoutInterval = 20
        request.setValue("Bearer " + connection.key, forHTTPHeaderField: "Authorization")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw Failure(code == 401 || code == 403 ? "Management access was refused. Check EasyCLIProxyAPI's settings." : "Local quota request failed (HTTP \(code)).")
        }
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure("Unexpected quota response.") }
        return value
    }
    func refreshIfNeeded() async {
        if lastRefresh == nil || Date().timeIntervalSince(lastRefresh!) > 60 { await refresh() }
    }
    func refresh() async {
        guard !refreshing else { return }
        refreshing = true; problem = nil
        defer { refreshing = false }
        do {
            let connection = try Self.connection()
            let response = try await request("auth-files", connection: connection)
            guard let files = response["files"] as? [[String: Any]] else { throw Failure("The proxy returned an unsupported account list.") }
            let supported = files.filter { ["claude", "codex"].contains($0["provider"] as? String ?? "") }
            accounts = supported.enumerated().map { i, file in
                ProxyQuotaAccount(id: file["auth_index"] as? String ?? "missing-\(i)", provider: file["provider"] as? String ?? "", name: file["email"] as? String ?? file["label"] as? String ?? "Account \(i + 1)", disabled: file["disabled"] as? Bool ?? false)
            }
            for index in accounts.indices {
                if Task.isCancelled { return }
                do {
                    guard !accounts[index].id.hasPrefix("missing-") else { throw Failure("This account has no quota lookup identifier.") }
                    let claude = accounts[index].provider == "claude"
                    var header = ["Authorization": "Bearer $TOKEN$", "Content-Type": "application/json"]
                    if claude { header["anthropic-beta"] = "oauth-2025-04-20" }
                    else { header["User-Agent"] = "codex-tui/0.160.0" }
                    let value = try await request("api-call", connection: connection, body: ["authIndex": accounts[index].id, "method": "GET", "url": claude ? "https://api.anthropic.com/api/oauth/usage" : "https://chatgpt.com/backend-api/wham/usage", "header": header])
                    let code = value["status_code"] as? Int ?? 0
                    guard (200..<300).contains(code) else { throw Failure("Provider quota check failed (HTTP \(code)).") }
                    let payload: [String: Any]
                    if let raw = value["body"] as? String, let data = raw.data(using: .utf8), let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] { payload = decoded }
                    else if let decoded = value["body"] as? [String: Any] { payload = decoded }
                    else { throw Failure("The provider returned an unsupported quota response.") }
                    accounts[index].windows = Self.windows(payload, provider: accounts[index].provider)
                    accounts[index].checked = Date()
                } catch {
                    accounts[index].problem = (error as? Failure)?.message ?? "Quota lookup couldn't connect. Try Refresh."
                }
            }
            lastRefresh = Date()
        } catch {
            // Never display raw response bodies or configuration values.
            problem = (error as? Failure)?.message ?? "Couldn't reach EasyCLIProxyAPI. Make sure it is running, then refresh."
        }
    }
    static func windows(_ payload: [String: Any], provider: String, now: Date = Date()) -> [ProxyQuotaWindow] {
        func remaining(_ raw: Any?) -> Double? {
            guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
            return max(0, min(100, 100 - n.doubleValue))
        }
        func date(_ raw: Any?) -> Date? {
            if let n = raw as? NSNumber { return Date(timeIntervalSince1970: n.doubleValue) }
            guard let s = raw as? String else { return nil }
            let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
        }
        if provider == "claude" {
            let labels = [("five_hour", "5-hour window"), ("seven_day", "7-day window"), ("seven_day_opus", "7-day Opus"), ("seven_day_sonnet", "7-day Sonnet"), ("iguana_necktie", "7-day Fable")]
            var rows = labels.compactMap { key, title -> ProxyQuotaWindow? in
                guard let raw = payload[key] as? [String: Any] else { return nil }
                return ProxyQuotaWindow(title: title, remaining: remaining(raw["utilization"]), reset: date(raw["resets_at"]))
            }
            for limit in payload["limits"] as? [[String: Any]] ?? [] {
                guard limit["kind"] as? String == "weekly_scoped", let scope = limit["scope"] as? [String: Any], let model = scope["model"] as? [String: Any], let name = model["display_name"] as? String, let percent = remaining(limit["percent"]) else { continue }
                let title = "7-day \(name)"
                if name.lowercased().contains("fable") { rows.removeAll { $0.title == "7-day Fable" } }
                if !rows.contains(where: { $0.title == title }) { rows.append(ProxyQuotaWindow(title: title, remaining: percent, reset: date(limit["resets_at"] ?? limit["reset_at"]))) }
            }
            return rows
        }
        var rows: [ProxyQuotaWindow] = []
        func add(_ limit: Any?, prefix: String) {
            guard let limit = limit as? [String: Any] else { return }
            for key in ["primary_window", "secondary_window"] {
                guard let raw = limit[key] as? [String: Any] else { continue }
                let duration = raw["limit_window_seconds"] as? Int
                let label = duration == 604800 ? "Weekly limit" : duration == 18000 ? "5-hour window" : duration.map { "\($0 / 3600)-hour window" } ?? (key == "primary_window" ? "Primary window" : "Secondary window")
                let reset = date(raw["reset_at"]) ?? (raw["reset_after_seconds"] as? NSNumber).map { now.addingTimeInterval($0.doubleValue) }
                rows.append(ProxyQuotaWindow(title: prefix + label, remaining: remaining(raw["used_percent"]), reset: reset))
            }
        }
        add(payload["rate_limit"], prefix: "")
        add(payload["code_review_rate_limit"], prefix: "Code review · ")
        for extra in payload["additional_rate_limits"] as? [[String: Any]] ?? [] { add(extra["rate_limit"], prefix: (extra["limit_name"] as? String ?? extra["metered_feature"] as? String ?? "Additional") + " · ") }
        return rows
    }
}
