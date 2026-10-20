import Foundation
import Observation
import Darwin

/// Uses the same detached, idle-safe restart job as agents and the command line.
@MainActor @Observable final class BackgroundServiceRestart {
    static let shared = BackgroundServiceRestart()
    enum Phase { case idle, queued, waiting, restarting, completed, failed }
    private(set) var phase = Phase.idle
    private(set) var message = ""
    private(set) var launching = false
    var pending: Bool { launching || phase == .queued || phase == .waiting || phase == .restarting }
    let reportURL: URL
    private let lockURL: URL
    private let scriptURL: URL?
    private let isolated: Bool
    private let launch: (URL) async throws -> Void
    private var queuedAt: Date?
    private var launchProblem: String?

    init(scriptURL: URL? = Bundle.main.url(forResource: "restart-service", withExtension: "sh"),
         diagnostics: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Chatterbox/Diagnostics"),
         isolated: Bool = ProcessInfo.processInfo.environment["CHATTERBOX_DATA_DIR"] != nil,
         launch: @escaping (URL) async throws -> Void = BackgroundServiceRestart.runScript) {
        self.scriptURL = scriptURL; self.isolated = isolated; self.launch = launch
        reportURL = diagnostics.appendingPathComponent("service-restart.txt")
        lockURL = diagnostics.appendingPathComponent("service-restart.pid")
    }

    func restart() async {
        guard !pending else { return }
        launchProblem = nil
        guard !isolated else { fail("Isolated builds cannot restart the installed background service."); return }
        guard let scriptURL, FileManager.default.fileExists(atPath: scriptURL.path) else {
            fail("The restart helper is missing. Reinstall Chatterbox and try again."); return
        }
        launching = true; phase = .queued; message = "Queuing restart…"; queuedAt = Date()
        defer { launching = false }
        do { try await launch(scriptURL); refresh() }
        catch { fail("Couldn’t queue the restart: \(error.localizedDescription)") }
    }

    func refresh() {
        guard launchProblem == nil else { return }
        let line = Self.lastLine(reportURL)
        let reportDate = (try? reportURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let queuedAt, reportDate == nil || reportDate! < queuedAt {
            if Date().timeIntervalSince(queuedAt) < 8 {
                phase = .queued; message = "Restart queued. Waiting for the restart job…"; return
            }
            fail("The restart job didn’t start. Try again or check the restart report."); return
        }
        queuedAt = nil
        let rawPID = (try? String(contentsOf: lockURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        let alive = rawPID.flatMap(Int32.init).map { $0 > 1 && kill($0, 0) == 0 } ?? false
        if alive {
            if line.contains("restarting chatterboxd") {
                phase = .restarting; message = "Restarting the background service. Reconnecting…"
            } else if line.contains("waiting for every chat") {
                phase = .waiting; message = "Waiting for active replies to finish."
            } else {
                phase = .queued; message = "Restart queued…"
            }
        } else if line.contains("health ok") {
            phase = .completed; message = "Background service restarted successfully." + Self.dateSuffix(line)
        } else if !line.isEmpty {
            phase = .failed
            message = line.contains("gave up") ? "Restart timed out waiting for replies. Try again when they finish."
                : line.contains("health failed") ? "The service restarted, but its health check failed. Check the restart report."
                : "The previous restart did not finish. You can try again or check the restart report."
        } else { phase = .idle; message = "" }
    }

    private func fail(_ problem: String) { launchProblem = problem; phase = .failed; message = problem; queuedAt = nil }
    private static func dateSuffix(_ line: String) -> String {
        let raw = String(line.prefix(19))
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        guard let date = formatter.date(from: raw) else { return "" }
        return " " + date.formatted(date: .abbreviated, time: .shortened)
    }
    private static func lastLine(_ file: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return "" }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return "" }
        try? handle.seek(toOffset: end > 8192 ? end - 8192 : 0)
        let data = (try? handle.readToEnd()) ?? Data()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").last.map(String.init) ?? ""
    }

    nonisolated static func runScript(_ script: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [script.path] // No --now, --host, --codex, or app lifecycle flags.
            let output = Pipe(); process.standardOutput = output; process.standardError = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let detail = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                throw NSError(domain: "Chatterbox.ServiceRestart", code: Int(process.terminationStatus),
                              userInfo: [NSLocalizedDescriptionKey: detail.isEmpty ? "Restart helper exited with status \(process.terminationStatus)." : detail])
            }
        }.value
    }
}
