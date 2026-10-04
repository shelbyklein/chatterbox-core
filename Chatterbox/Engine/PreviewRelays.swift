import Foundation
import Observation

/// Local previews (SKD Studio sites and other dev servers on this Mac) that the agent
/// computer's browser may open, one port at a time, only when you turn them on.
///
/// The computer reaches the Mac's IPv4 loopback through Docker (host.docker.internal), but
/// SKD Studio listens on IPv6 loopback ([::1]) only. For each enabled port Chatterbox runs a
/// relay on 127.0.0.1:PORT → [::1]:PORT, and the computer runs a forwarder on its own
/// localhost:PORT, so pages load at the same http://localhost:PORT address WordPress expects.
/// Nothing listens on the network; ports you haven't enabled aren't reachable.
@MainActor
@Observable
final class PreviewRelays {
    static let shared = PreviewRelays()
    static let key = "computerPreviewPorts"

    struct LocalSite: Identifiable, Hashable {
        var id: Int { port }
        var port: Int
        var title: String
        var process: String
    }

    private(set) var enabled: Set<Int> = Set((AppPreferences.defaults.array(forKey: key) as? [Int]) ?? [])
    private(set) var sites: [LocalSite] = []
    private(set) var scanning = false
    @ObservationIgnored private var listeners: [Int: SocketRelay] = [:]

    func start() {
        for port in enabled { openRelay(port) }
        // A computer already running from before Chatterbox restarted needs its forwarders too.
        guard !enabled.isEmpty else { return }
        Task {
            await DotComputer.shared.refresh()
            await applyToComputer()
        }
    }

    func setEnabled(_ port: Int, _ on: Bool) {
        if on { enabled.insert(port) } else { enabled.remove(port) }
        AppPreferences.defaults.set(Array(enabled).sorted(), forKey: Self.key)
        if on { openRelay(port) } else { closeRelay(port) }
        Task {
            if on { await DotComputer.shared.forward(port: port) } else { await DotComputer.shared.unforward(port: port) }
        }
    }

    /// After the computer starts: its forwarders for every enabled port.
    func applyToComputer() async {
        for port in enabled { await DotComputer.shared.forward(port: port) }
    }

    // MARK: - The relay on the Mac

    private func openRelay(_ port: Int) {
        guard listeners[port] == nil else { return }
        // The site may already answer on IPv4 loopback itself; then Docker reaches it directly
        // and the bind fails, which is fine.
        guard let relay = SocketRelay(port: UInt16(clamping: port)) else { return }
        listeners[port] = relay
    }

    private func closeRelay(_ port: Int) {
        listeners[port]?.close()
        listeners[port] = nil
    }

    // MARK: - Finding local sites

    /// Web servers listening on this Mac's loopback, with their page titles.
    func scan() async {
        scanning = true
        defer { scanning = false }
        let lsof = await Git.run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN"])
        var found: [Int: String] = [:]
        for line in lsof.out.split(separator: "\n").dropFirst() {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 9, let address = parts.last.map(String.init),
                  address.hasPrefix("127.0.0.1:") || address.hasPrefix("[::1]:") || address.hasPrefix("localhost:"),
                  let port = Int(address.split(separator: ":").last ?? ""), port >= 1024,
                  !String(parts[0]).hasPrefix("Chatterbo"), !String(parts[0]).hasPrefix("com.docke") else { continue }
            found[port] = String(parts[0])
        }
        var result: [LocalSite] = []
        for (port, process) in found.sorted(by: { $0.key < $1.key }) {
            guard let title = await Self.title(port) else { continue }   // Not a web page.
            result.append(LocalSite(port: port, title: title, process: process))
        }
        sites = result
    }

    nonisolated private static func title(_ port: Int) async -> String? {
        guard let url = URL(string: "http://localhost:\(port)/") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (http.value(forHTTPHeaderField: "Content-Type") ?? "").contains("html") else { return nil }
        let html = String(decoding: data.prefix(200_000), as: UTF8.self)
        guard let start = html.range(of: "<title>", options: .caseInsensitive),
              let end = html.range(of: "</title>", options: .caseInsensitive, range: start.upperBound..<html.endIndex) else {
            return "localhost:\(port)"
        }
        let title = html[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "localhost:\(port)" : title.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&#8211;", with: "–")
    }
}

/// Listens on 127.0.0.1:PORT only, and pipes each connection to [::1]:PORT.
final class SocketRelay: @unchecked Sendable {
    private let listener: Int32
    private let port: UInt16
    private var closed = false

    init?(port: UInt16) {
        self.port = port
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 32) == 0 else { Darwin.close(fd); return nil }
        listener = fd
        Thread.detachNewThread { [weak self] in self?.acceptLoop() }
    }

    func close() {
        closed = true
        shutdown(listener, SHUT_RDWR)
        Darwin.close(listener)
    }

    private func acceptLoop() {
        while !closed {
            let client = accept(listener, nil, nil)
            guard client >= 0 else { if closed { return }; continue }
            var noSigPipe: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            let port = self.port
            Thread.detachNewThread {
                guard let upstream = Self.connectIPv6Loopback(port) else { Darwin.close(client); return }
                let pair = Pair(client, upstream)
                Thread.detachNewThread { Self.pipe(client, upstream); pair.finished() }
                Self.pipe(upstream, client); pair.finished()
            }
        }
    }

    private static func connectIPv6Loopback(_ port: UInt16) -> Int32? {
        let fd = socket(AF_INET6, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in6()
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = port.bigEndian
        address.sin6_addr = in6addr_loopback
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
        }
        guard connected == 0 else { Darwin.close(fd); return nil }
        return fd
    }

    /// Both sockets of one connection, closed once both directions are done.
    private final class Pair: @unchecked Sendable {
        private let a: Int32, b: Int32
        private let lock = NSLock()
        private var done = 0
        init(_ a: Int32, _ b: Int32) { self.a = a; self.b = b }
        func finished() {
            lock.lock(); done += 1; let both = done == 2; lock.unlock()
            if both { Darwin.close(a); Darwin.close(b) }
        }
    }

    /// Copies one direction until it ends, then ends the other side's writes.
    private static func pipe(_ from: Int32, _ to: Int32) {
        var buffer = [UInt8](repeating: 0, count: 65536)
        copying: while true {
            let n = read(from, &buffer, buffer.count)
            if n <= 0 { break }
            var sent = 0
            while sent < n {
                let w = buffer.withUnsafeBytes { write(to, $0.baseAddress! + sent, n - sent) }
                if w <= 0 { break copying }
                sent += w
            }
        }
        shutdown(to, SHUT_WR)
    }
}
