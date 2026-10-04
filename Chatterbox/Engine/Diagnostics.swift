import AppKit
import ScreenCaptureKit
import Darwin
import Foundation
import Observation
import os
import UserNotifications

/// Reports on why Chatterbox hung or went away, kept in Application Support/Chatterbox/
/// Diagnostics as plain text you (or an agent) can read.
///
/// - A watchdog thread checks the main thread every half second. Stuck for 3 seconds, it
///   records what the main thread is doing with macOS's `sample`, and how long the hang lasted.
/// - Each launch notes it's running; a clean quit clears that. If the last run didn't quit
///   cleanly (it crashed, froze and was force-quit), its last errors from the system log and
///   any crash report macOS wrote are gathered into a report.
/// - Recent breadcrumbs (chat opened, message sent, reply ended) go in every report.
@MainActor
@Observable
final class Diagnostics {
    static let shared = Diagnostics()
    /// Marks in Instruments (Points of Interest) for timing chat switches; see scripts/test-chat-switch-perf.sh.
    nonisolated static let signposts = OSSignposter(subsystem: "com.shelbyklein.Chatterbox", category: .pointsOfInterest)

    struct Report: Identifiable, Hashable {
        var id: URL { url }
        var url: URL
        var date: Date
        var title: String
    }

    private(set) var reports: [Report] = []

    nonisolated static var folder: URL {
        let base: URL
        if let dir = ProcessInfo.processInfo.environment["CHATTERBOX_DATA_DIR"], !dir.isEmpty {
            base = URL(fileURLWithPath: dir)
        } else {
            base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Chatterbox")
        }
        let folder = base.appendingPathComponent("Diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private var runningMarker: URL { Self.folder.appendingPathComponent("running.json") }
    /// The previous run, kept even after a clean quit, so its renderer faults can be reported.
    private var lastRunMarker: URL { Self.folder.appendingPathComponent("last-run.json") }
    @ObservationIgnored private var watchdog: Watchdog?

    // MARK: - Starting and stopping

    func start() {
        guard watchdog == nil else { return }
        checkLastRun()
        let marker = ["pid": Int(ProcessInfo.processInfo.processIdentifier), "launched": Date().timeIntervalSince1970] as [String: Any]
        if let data = try? JSONSerialization.data(withJSONObject: marker) { try? data.write(to: runningMarker) }
        watchdog = Watchdog()
        watchdog?.start()
        startOutsideWatcher()
        reload()
        #if DEBUG
        // Tests: freeze the main thread on purpose, to check a hang gets reported.
        if let seconds = ProcessInfo.processInfo.environment["CHATTERBOX_TEST_HANG"].flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                Diagnostics.note("Test: freezing the main thread for \(seconds)s")
                Thread.sleep(forTimeInterval: seconds)
            }
        }
        #endif
    }

    /// A clean quit: the next launch won't report this run as a crash, but still looks at
    /// its faults.
    func stop() {
        watchdog?.stop()
        try? FileManager.default.moveItem(at: runningMarker, to: lastRunMarker)
        try? FileManager.default.removeItem(at: runningMarker)
    }

    // MARK: - The watcher outside the app

    /// The host binary in watch mode: if the heartbeat the main thread touches goes quiet,
    /// it samples this app from outside and writes the report, even if everything in here is
    /// stuck. It exits with the app.
    private func startOutsideWatcher() {
        guard let binary = HostClient.hostBinary else { return }
        let process = Process()
        process.executableURL = binary
        process.arguments = ["--watch", String(ProcessInfo.processInfo.processIdentifier), Self.folder.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    nonisolated static var heartbeat: URL { folder.appendingPathComponent("heartbeat") }

    // MARK: - Breadcrumbs

    /// The last few things that happened, for context in a report. Safe from any thread.
    nonisolated static func note(_ event: String) { Breadcrumbs.shared.add(event) }

    // MARK: - The last run

    private func checkLastRun() {
        let fm = FileManager.default
        // An unclean exit (the marker is still there), or a clean quit (moved aside).
        let unclean = fm.fileExists(atPath: runningMarker.path)
        let markerURL = unclean ? runningMarker : lastRunMarker
        guard let data = try? Data(contentsOf: markerURL),
              let marker = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = marker["pid"] as? Int, pid != Int(ProcessInfo.processInfo.processIdentifier) else { return }
        try? fm.removeItem(at: lastRunMarker)
        let launched = Date(timeIntervalSince1970: marker["launched"] as? Double ?? 0)
        let breadcrumbs = (try? String(contentsOf: Self.folder.appendingPathComponent("breadcrumbs.txt"), encoding: .utf8)) ?? ""
        // The system log can take a while to search; the report is written when it's done.
        Task.detached(priority: .utility) {
            let faults = Self.faults(pid: pid, since: launched)
            // Renderer failures can leave a responsive main thread but a broken window.
            // Preserve them even if the user was still able to quit normally.
            // A clean quit with only routine macOS noise: nothing to report.
            if !unclean, faults.allSatisfy(Self.isRoutine) { return }
            let log = Self.systemLog(pid: pid, since: launched)
            let crash = Self.crashReports(since: launched)
            let text = """
            \(unclean
                ? "Chatterbox didn't quit cleanly (process \(pid), launched \(launched.formatted(date: .abbreviated, time: .standard))). It crashed, or froze and was quit or force-quit."
                : "Chatterbox's last run (process \(pid), launched \(launched.formatted(date: .abbreviated, time: .standard))) logged \(faults.count) fault\(faults.count == 1 ? "" : "s") before it was quit.")

            ## Faults
            \(faults.isEmpty ? "None." : faults.joined(separator: "\n"))
            \(faults.contains(where: { $0.contains("renderbox") }) ? "\nA RenderBox fault can accompany a window that stops drawing even while its main thread responds. Compare the window capture and breadcrumbs; this log alone does not identify the cause." : "")

            ## Crash reports macOS wrote
            \(crash.isEmpty ? "None." : crash.map(\.path).joined(separator: "\n"))

            ## What it was doing (breadcrumbs, newest last)
            \(breadcrumbs.isEmpty ? "None recorded." : breadcrumbs)

            ## The end of its system log
            \(log.isEmpty ? "Nothing found." : log)
            """
            await MainActor.run {
                self.save(unclean ? "unclean-exit" : "faults", title: unclean ? "Didn't quit cleanly" : "Rendering fault\(faults.count == 1 ? "" : "s") last run", text: text)
                self.notify(unclean ? "Chatterbox didn't close properly last time" : "Chatterbox's last run hit a rendering fault",
                            body: "A report is saved in Settings → Diagnostics.")
            }
        }
    }

    /// Faults macOS logs on its own that don't mean anything is wrong: Auto Layout conflicts
    /// AppKit recovers from and SwiftUI configuration notes. Listed in a report, but they
    /// never start one. (RenderBox faults still do: they can come with a stuck window.)
    nonisolated static func isRoutine(_ line: String) -> Bool {
        line.contains("com.apple.runtime-issues") || line.contains("com.apple.SwiftUI:Invalid Configuration")
            || line.hasPrefix("Will attempt to recover")
    }

    /// Fault-level lines (precondition failures and the like) the process logged.
    nonisolated private static func faults(pid: Int, since: Date) -> [String] {
        runLog(predicate: "processID == \(pid) AND messageType == fault", since: since)
    }

    nonisolated private static func runLog(predicate: String, since: Date, extra: [String] = []) -> [String] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = ["show", "--style", "compact", "--start", formatter.string(from: max(since, Date().addingTimeInterval(-6 * 3600))),
                             "--predicate", predicate] + extra
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init).filter { !$0.hasPrefix("Timestamp") }
    }

    /// The process's last errors, the 40 lines before its first fault (what led up to it),
    /// and its final lines.
    nonisolated private static func systemLog(pid: Int, since: Date) -> String {
        let errors = runLog(predicate: "processID == \(pid) AND messageType == error", since: since)
            .filter { !$0.contains("com.apple.network") && !$0.contains("WebKit") && !$0.contains("runningboard") }
        var sections: [String] = ["### Errors (last 40)"] + errors.suffix(40)
        let faults = faults(pid: pid, since: since)
        if let first = faults.first, let stamp = first.split(separator: " ").prefix(2).last {
            // Everything (info level too) in the 3 seconds before the first fault.
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
            if let time = formatter.date(from: String(first.prefix(23))) {
                let before = runLog(predicate: "processID == \(pid)", since: time.addingTimeInterval(-3), extra: ["--info", "--end", formatter.string(from: time.addingTimeInterval(0.2))])
                    .filter { !$0.contains("fgetattrlist") && !$0.contains("isViewVisible") && !$0.contains("CursorUI") && !$0.contains("IASignalAnalytics") }
                sections += ["", "### The 3 seconds before the first fault (\(stamp))"] + before.suffix(80)
            }
        }
        sections += ["", "### Its last 30 lines"] + runLog(predicate: "processID == \(pid)", since: since).suffix(30)
        return sections.joined(separator: "\n")
    }

    nonisolated private static func crashReports(since: Date) -> [URL] {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { url in
            url.lastPathComponent.hasPrefix("Chatterbox")
                && ((try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) >= since
        }
    }

    // MARK: - Reporting a freeze by hand

    /// For when the window looks stuck but the app is alive (the watchdog only sees a stuck
    /// main thread): a picture of the window, what's on screen, the main thread, and a sample.
    func reportFreeze() {
        guard !reportingFreeze else { return }
        reportingFreeze = true
        let crumbs = breadcrumbsSnapshot()
        var screen: [String] = []
        var windowID: CGWindowID?
        if let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) {
            windowID = CGWindowID(window.windowNumber)
            screen.append("Window: \(window.title) \(Int(window.frame.width))×\(Int(window.frame.height)), key: \(window.isKeyWindow), visible: \(window.isVisible), occluded: \(!window.occlusionState.contains(.visible))")
            screen.append("Sheet: \(window.attachedSheet.map { "\($0)" } ?? "none"); modal: \(NSApp.modalWindow.map { "\($0.title)" } ?? "none")")
        } else {
            screen.append("No visible window.")
        }
        // Waiting for sample on the main actor would sample the reporter's own wait,
        // hiding the state we need to investigate and freezing the app for three seconds.
        let sampling = Task.detached(priority: .utility) { Self.sampleSelf() }
        Task {
            defer { reportingFreeze = false }
            if let windowID, #available(macOS 14.4, *) {
                do {
                    let picture = try await Self.captureWindow(windowID)
                    screen.append("Picture of the window: \(picture.path)")
                } catch {
                    screen.append("Window capture failed: \(error.localizedDescription)")
                }
            } else {
                screen.append("Window capture unavailable (requires macOS 14.4 or later and a visible window).")
            }
            let sample = await sampling.value
            let text = """
            You reported a freeze (⌃⌥⌘D). The app handled the command; the sample below records what its threads did afterward.

            ## On screen
            \(screen.joined(separator: "\n"))

            ## What it was doing (breadcrumbs, newest last)
            \(crumbs.isEmpty ? "None recorded." : crumbs)

            ## macOS sample (3 seconds)
            \(sample.isEmpty ? "Couldn't sample." : sample)
            """
            save("freeze", title: "Freeze reported by you", text: text)
            notify("Freeze report saved", body: "In Settings → Diagnostics.")
        }
    }

    @ObservationIgnored private var reportingFreeze = false

    /// Captures our own composited window without requesting access to other apps.
    /// cacheDisplay(in:to:) misses SwiftUI/WebKit layers and can produce a blank image
    /// even when the window is healthy.
    @available(macOS 14.4, *)
    private static func captureWindow(_ id: CGWindowID) async throws -> URL {
        let content = try await SCShareableContent.currentProcess
        guard let window = content.windows.first(where: { $0.windowID == id }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(window.frame.width))
        configuration.height = max(1, Int(window.frame.height))
        configuration.ignoreShadowsSingleWindow = true
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration)
        let picture = folder.appendingPathComponent("\(stamp()) window.png")
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try png.write(to: picture)
        return picture
    }

    private func breadcrumbsSnapshot() -> String { Breadcrumbs.shared.text }

    nonisolated private static func stamp() -> String {
        ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
    }

    /// Runs `sample` on this process from a helper thread (it pauses us briefly).
    nonisolated private static func sampleSelf() -> String {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("chatterbox-freeze-\(UUID().uuidString).txt")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        process.arguments = [String(ProcessInfo.processInfo.processIdentifier), "3", "-mayDie", "-file", file.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        process.waitUntilExit()
        defer { try? FileManager.default.removeItem(at: file) }
        return String(((try? String(contentsOf: file, encoding: .utf8)) ?? "").prefix(120_000))
    }

    // MARK: - Reports

    func save(_ kind: String, title: String, text: String) {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = Self.folder.appendingPathComponent("\(stamp) \(kind).txt")
        let header = "# \(title)\n\(Date().formatted(date: .complete, time: .standard)) · Chatterbox \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")\n\n"
        try? (header + text).write(to: url, atomically: true, encoding: .utf8)
        // Keep the newest 30.
        let all = ((try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "txt" && $0.lastPathComponent != "breadcrumbs.txt" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in all.dropFirst(30) { try? FileManager.default.removeItem(at: old) }
        reload()
    }

    func reload() {
        let files = ((try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: [.creationDateKey])) ?? [])
            .filter { $0.pathExtension == "txt" && $0.lastPathComponent != "breadcrumbs.txt" }
        reports = files.map { url in
            let firstLine = (try? String(contentsOf: url, encoding: .utf8))?.split(separator: "\n").first.map { String($0.dropFirst(2)) } ?? url.lastPathComponent
            let date = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return Report(url: url, date: date, title: firstLine)
        }.sorted { $0.date > $1.date }
    }

    fileprivate func notify(_ title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// Called by the watchdog once the main thread answers again.
    fileprivate func recordHang(seconds: Double, stacks: String, sample: String, breadcrumbs: String) {
        let text = """
        The main thread didn't respond for \(String(format: "%.1f", seconds)) seconds, so the window froze. Below: where the main thread was stuck, read while it was stuck, and what happened just before.

        ## Where it was stuck
        \(stacks.isEmpty ? "Couldn't read the main thread's stack." : stacks)

        ## What it was doing (breadcrumbs, newest last)
        \(breadcrumbs.isEmpty ? "None recorded." : breadcrumbs)
        \(sample.isEmpty ? "" : "\n## macOS sample (taken during the hang)\n" + sample)
        """
        save("hang", title: "Not responding for \(Int(seconds.rounded()))s", text: text)
        if seconds >= 5 { notify("Chatterbox stopped responding for \(Int(seconds.rounded())) seconds", body: "A report is saved in Settings → Diagnostics.") }
    }
}

/// The last 40 events, also mirrored to disk so a report after a crash has them.
private final class Breadcrumbs: @unchecked Sendable {
    static let shared = Breadcrumbs()
    private let lock = NSLock()
    private var events: [String] = []
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    func add(_ event: String) {
        lock.lock()
        events.append(formatter.string(from: Date()) + "  " + event)
        if events.count > 40 { events.removeFirst(events.count - 40) }
        let text = events.joined(separator: "\n")
        lock.unlock()
        let url = Diagnostics.folder.appendingPathComponent("breadcrumbs.txt")
        DispatchQueue.global(qos: .utility).async { try? text.write(to: url, atomically: true, encoding: .utf8) }
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return events.joined(separator: "\n")
    }
}

/// Pings the main thread from a background thread. Uses uptime, which stops while the Mac
/// sleeps, so waking up isn't mistaken for a hang. While the main thread is stuck, it reads
/// the main thread's call stack every half second (pausing it for a moment each time), and,
/// for a long hang, also runs macOS's `sample`.
private final class Watchdog: @unchecked Sendable {
    private let queue = DispatchQueue(label: "chatterbox.watchdog", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private let lock = NSLock()
    private var lastBeat = ProcessInfo.processInfo.systemUptime
    private var waiting = false
    /// Launch is busy for a while; silence only counts once the main thread has answered once.
    private var heardFirstBeat = false
    private var hangStart: Double?
    private var stacks: [[UInt]] = []
    private var sample = ""
    private var sampling = false
    /// After a report, a short rest so one hang isn't reported twice.
    private var quietUntil = 0.0
    private let mainThread: thread_t
    private static let threshold = 2.0

    init() { mainThread = mach_thread_self() }   // Made on the main thread.

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 0.5)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    func stop() { timer?.cancel() }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let silent = now - lastBeat
        let alreadyWaiting = waiting
        let ready = heardFirstBeat
        if !alreadyWaiting { waiting = true }
        lock.unlock()
        if !alreadyWaiting {
            DispatchQueue.main.async { [weak self] in self?.beat() }
        }
        guard ready, silent > Self.threshold, now > quietUntil else { return }
        if hangStart == nil { hangStart = now - silent }
        if stacks.count < 30 { stacks.append(Self.backtrace(of: mainThread)) }
        // Long hang: macOS's own sample too, on its own thread (it takes a few seconds).
        if silent > 8, !sampling, sample.isEmpty {
            sampling = true
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let text = Self.takeSample()
                self?.queue.async { self?.sample = text; self?.sampling = false }
            }
        }
    }

    private func beat() {
        let now = ProcessInfo.processInfo.systemUptime
        Self.touchHeartbeat()
        lock.lock()
        lastBeat = now
        waiting = false
        let first = !heardFirstBeat
        heardFirstBeat = true
        lock.unlock()
        if first { Breadcrumbs.shared.add("Launched; main thread responsive") }
        queue.async { [weak self] in
            guard let self, let start = self.hangStart else { return }
            let seconds = now - start
            let summary = Self.describe(self.stacks)
            let sample = self.sample
            self.hangStart = nil
            self.stacks = []
            self.sample = ""
            self.quietUntil = ProcessInfo.processInfo.systemUptime + 5
            let crumbs = Breadcrumbs.shared.text
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    Diagnostics.shared.recordHang(seconds: seconds, stacks: summary, sample: sample, breadcrumbs: crumbs)
                }
            }
        }
    }

    private static let heartbeatPath = Diagnostics.heartbeat.path
    private static var heartbeatMade = false

    /// Sets the heartbeat file's time to now (one cheap system call).
    private static func touchHeartbeat() {
        if !heartbeatMade {
            FileManager.default.createFile(atPath: heartbeatPath, contents: nil)
            heartbeatMade = true
        }
        utimes(heartbeatPath, nil)
    }

    // MARK: - Reading the main thread's stack

    /// Return addresses up the main thread's stack, by walking its frame pointers. Nothing is
    /// allocated while it's paused (it might hold the allocator's lock).
    private static func backtrace(of thread: thread_t) -> [UInt] {
        let capacity = 200
        let buffer = UnsafeMutablePointer<UInt>.allocate(capacity: capacity)
        defer { buffer.deallocate() }
        var count = 0
        guard thread_suspend(thread) == KERN_SUCCESS else { return [] }
        var state = arm_thread_state64_t()
        var stateCount = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &state) {
            $0.withMemoryRebound(to: natural_t.self, capacity: Int(stateCount)) {
                thread_get_state(thread, ARM_THREAD_STATE64, $0, &stateCount)
            }
        }
        if result == KERN_SUCCESS {
            buffer[count] = UInt(state.__pc); count += 1
            buffer[count] = UInt(state.__lr); count += 1
            var frame = UInt(state.__fp)
            var pair: (UInt, UInt) = (0, 0)
            while frame != 0, frame % 8 == 0, count < capacity {
                var read: vm_size_t = 0
                let ok = withUnsafeMutablePointer(to: &pair) { pointer in
                    vm_read_overwrite(mach_task_self_, vm_address_t(frame), vm_size_t(MemoryLayout<(UInt, UInt)>.size),
                                      vm_address_t(UInt(bitPattern: pointer)), &read)
                }
                guard ok == KERN_SUCCESS, pair.1 != 0 else { break }
                buffer[count] = pair.1; count += 1
                guard pair.0 > frame else { break }   // The stack grows down; a caller's frame is higher.
                frame = pair.0
            }
        }
        thread_resume(thread)
        // Strip pointer-authentication bits from system code's return addresses.
        return (0..<count).map { buffer[$0] & 0x0000_000F_FFFF_FFFF }
    }

    /// The stacks as readable text: the stack seen most often, symbolized, plus how often.
    private static func describe(_ stacks: [[UInt]]) -> String {
        let nonEmpty = stacks.filter { !$0.isEmpty }
        guard !nonEmpty.isEmpty else { return "" }
        var counts: [[UInt]: Int] = [:]
        for stack in nonEmpty { counts[stack, default: 0] += 1 }
        let ranked = counts.sorted { $0.value > $1.value }
        var lines = ["Main thread, read \(nonEmpty.count) times while stuck (innermost call first)."]
        for (index, entry) in ranked.prefix(3).enumerated() {
            lines.append("")
            lines.append("### Stack \(index + 1), seen \(entry.value) of \(nonEmpty.count) times")
            lines += entry.key.prefix(60).map(symbol)
        }
        return lines.joined(separator: "\n")
    }

    private static func symbol(_ address: UInt) -> String {
        var info = Dl_info()
        guard dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0 else { return String(format: "0x%lx", address) }
        let image = info.dli_fname.map { (String(cString: $0) as NSString).lastPathComponent } ?? "?"
        guard let name = info.dli_sname.map({ String(cString: $0) }) else { return String(format: "%@  0x%lx", image, address) }
        let offset = info.dli_saddr.map { address - UInt(bitPattern: $0) } ?? 0
        return "\(image)  \(demangle(name)) + \(offset)"
    }

    private typealias Demangle = @convention(c) (UnsafePointer<CChar>?, Int, UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<Int>?, UInt32) -> UnsafeMutablePointer<CChar>?
    private static let swiftDemangle: Demangle? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swift_demangle").map { unsafeBitCast($0, to: Demangle.self) }

    private static func demangle(_ name: String) -> String {
        guard let swiftDemangle, name.hasPrefix("$s") || name.hasPrefix("_$s") else { return name }
        return name.withCString { pointer in
            guard let result = swiftDemangle(pointer, strlen(pointer), nil, nil, 0) else { return name }
            defer { free(result) }
            return String(cString: result)
        }
    }

    private static func takeSample() -> String {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("chatterbox-hang-\(UUID().uuidString).txt")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        process.arguments = [String(ProcessInfo.processInfo.processIdentifier), "3", "-mayDie", "-file", file.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        process.waitUntilExit()
        defer { try? FileManager.default.removeItem(at: file) }
        return String(((try? String(contentsOf: file, encoding: .utf8)) ?? "").prefix(120_000))
    }
}
