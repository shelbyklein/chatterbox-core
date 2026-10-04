#if DEBUG
import Foundation

/// Opt-in, read-only verification in the actual app/ATS process. Never pairs or sends a token.
enum CompanionTransportProbe {
    static func runIfRequested() async {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["CHATTERBOX_TRANSPORT_PROBE"], allowed(host) else { return }
        var hosts = [host]
        if let lan = environment["CHATTERBOX_TRANSPORT_PROBE_LAN"], allowed(lan), lan != host { hosts.append(lan) }
        // This public IP must stay blocked by ATS; no credentials are used by any probe.
        hosts.append("1.1.1.1")
        var results: [[String: Any]] = []
        for host in hosts {
            let url = URL(string: "http://\(host):\(Companion.port)/v1/chats")!
            var request = URLRequest(url: url)
            request.timeoutInterval = 6
            request.cachePolicy = .reloadIgnoringLocalCacheData
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                results.append(["host": host, "status": (response as? HTTPURLResponse)?.statusCode ?? 0])
            } catch {
                let error = error as NSError
                results.append(["host": host, "errorDomain": error.domain, "errorCode": error.code])
            }
        }
        let output = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("companion-transport-probe.json")
        if let data = try? JSONSerialization.data(withJSONObject: [
            "results": results,
            "ats": Bundle.main.object(forInfoDictionaryKey: "NSAppTransportSecurity") as? [String: Any] ?? [:],
            "bundleID": Bundle.main.bundleIdentifier ?? "",
            "testedAt": ISO8601DateFormatter().string(from: Date())
        ], options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: output, options: .atomic)
        }
    }

    private static func allowed(_ host: String) -> Bool {
        let parts = host.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 10 || parts[0] == 127
            || (parts[0] == 172 && (16...31).contains(parts[1]))
            || (parts[0] == 192 && parts[1] == 168)
            || (parts[0] == 100 && (64...127).contains(parts[1]))
    }
}
#endif
