import Foundation

/// How hard the Mac is working, as the background service sees it (ChatterboxDaemon/
/// PressureMonitor.swift reads it every 10 s). On 2026-11-04/05 parallel work-thread builds,
/// simulator test suites and stale simulators took this 16-core, 64 GB Mac to load averages of
/// 120 and then ~700, with swap and ~27 GB compressed memory; replies and the phone connection
/// suffered. So Chatterbox holds its own work back before that point instead of cleaning up
/// after: at Busy builds go one at a time, idle simulators go sooner and new work threads wait to
/// start; at Overloaded new builds wait, unused simulators go at once and work threads don't
/// start their next turn.
///
/// This is the decision alone, with the readings handed in, so it can be tested with recorded
/// readings (tests/pressure). Foundation only.
enum MacPressure {
    enum Level: String, Codable, Comparable, CaseIterable {
        case ok, busy, overloaded
        var rank: Int { switch self { case .ok: 0; case .busy: 1; case .overloaded: 2 } }
        static func < (a: Level, b: Level) -> Bool { a.rank < b.rank }
        /// "Mac OK", "Mac busy", "Mac overloaded".
        var label: String { switch self { case .ok: "Mac OK"; case .busy: "Mac busy"; case .overloaded: "Mac overloaded" } }
    }

    /// The kernel's memory pressure (kern.memorystatus_vm_pressure_level 1, 2, 4).
    enum Memory: String, Codable, Comparable {
        case normal, warning, critical
        var rank: Int { switch self { case .normal: 0; case .warning: 1; case .critical: 2 } }
        static func < (a: Memory, b: Memory) -> Bool { a.rank < b.rank }
    }

    /// ProcessInfo.thermalState.
    enum Thermal: String, Codable, Comparable {
        case nominal, fair, serious, critical
        var rank: Int { switch self { case .nominal: 0; case .fair: 1; case .serious: 2; case .critical: 3 } }
        static func < (a: Thermal, b: Thermal) -> Bool { a.rank < b.rank }
    }

    /// One look at the Mac.
    struct Readings: Codable, Equatable {
        var memory: Memory = .normal
        /// Swap in use (vm.swapusage), bytes.
        var swapUsed: Int64 = 0
        /// Memory held compressed, bytes, for showing only.
        var compressed: Int64? = nil
        var load1: Double = 0
        var load5: Double = 0
        var load15: Double = 0
        var cores: Int = 16
        var thermal: Thermal = .nominal
    }

    /// When each level starts and ends. Preferences (Settings → Background service), with these
    /// defaults; the keys are `pressure.<name>` (see `init(preferences:)`).
    struct Thresholds: Codable, Equatable {
        /// Busy: the 1-minute load above this many times the cores, for `busyLoadFor`.
        var busyLoad: Double = 1.5
        var busyLoadFor: TimeInterval = 120
        /// Overloaded: above this many times the cores, for `overloadedLoadFor`.
        var overloadedLoad: Double = 3
        var overloadedLoadFor: TimeInterval = 60
        /// Overloaded: swap in use grew by this much within `swapGrowthWindow`.
        var swapGrowth: Int64 = 1 << 30
        var swapGrowthWindow: TimeInterval = 300
        /// A level steps down only once the lower one's conditions have held this long.
        var stepDownAfter: TimeInterval = 180

        static let defaults = Thresholds()
        static let keys = ["pressure.busyLoad", "pressure.busyLoadSeconds", "pressure.overloadedLoad", "pressure.overloadedLoadSeconds",
                           "pressure.swapGrowthGB", "pressure.swapGrowthMinutes", "pressure.stepDownMinutes"]

        init() {}
        /// From the preferences (`lookup` answers a key's value), defaults for anything unset or
        /// out of range.
        init(preferences lookup: (String) -> Any?) {
            func number(_ key: String) -> Double? {
                switch lookup(key) {
                case let value as Double: return value
                case let value as Int: return Double(value)
                case let value as NSNumber: return value.doubleValue
                case let value as String: return Double(value)
                default: return nil
                }
            }
            func positive(_ key: String) -> Double? { number(key).flatMap { $0 > 0 && $0.isFinite ? $0 : nil } }
            if let x = positive("pressure.busyLoad") { busyLoad = x }
            if let x = positive("pressure.busyLoadSeconds") { busyLoadFor = x }
            if let x = positive("pressure.overloadedLoad") { overloadedLoad = max(x, busyLoad) }
            if let x = positive("pressure.overloadedLoadSeconds") { overloadedLoadFor = x }
            if let x = positive("pressure.swapGrowthGB") { swapGrowth = Int64(x * Double(1 << 30)) }
            if let x = positive("pressure.swapGrowthMinutes") { swapGrowthWindow = x * 60 }
            if let x = positive("pressure.stepDownMinutes") { stepDownAfter = x * 60 }
        }
    }

    /// A level change, with why.
    struct Change: Equatable {
        var from: Level
        var to: Level
        var reasons: [String]
    }

    /// The level, from one reading after another (every ~10 s). Up as soon as a condition
    /// holds (the load ones once sustained); down one step or two only once the lower level's
    /// conditions have held for `stepDownAfter`, so it doesn't flap.
    struct Evaluator {
        var thresholds: Thresholds
        private(set) var level: Level = .ok
        /// Since when it's been at this level.
        private(set) var since: Date?
        /// What put it at this level (or, at OK, nothing).
        private(set) var reasons: [String] = []
        private(set) var last: Readings?
        /// Recent swap readings, for growth.
        private var swap: [(at: Date, used: Int64)] = []
        /// Since when the load has been above each threshold, continuously.
        private var busyLoadSince: Date?
        private var overloadedLoadSince: Date?
        /// Since when the conditions for at most Busy, and for OK, have held continuously.
        private var calmForBusySince: Date?
        private var calmForOKSince: Date?

        init(thresholds: Thresholds = .defaults) { self.thresholds = thresholds }

        /// Swap growth within the window: now against the least in it.
        var swapGrowth: Int64 {
            guard let now = swap.last else { return 0 }
            return max(0, now.used - (swap.map(\.used).min() ?? now.used))
        }

        /// Takes a reading; answers the change, if the level changed.
        @discardableResult
        mutating func update(_ r: Readings, now: Date) -> Change? {
            last = r
            let t = thresholds
            let cores = Double(max(1, r.cores))
            swap.append((now, r.swapUsed))
            swap.removeAll { now.timeIntervalSince($0.at) > t.swapGrowthWindow }
            let growth = swapGrowth

            busyLoadSince = r.load1 > t.busyLoad * cores ? (busyLoadSince ?? now) : nil
            overloadedLoadSince = r.load1 > t.overloadedLoad * cores ? (overloadedLoadSince ?? now) : nil
            func held(_ since: Date?, _ seconds: TimeInterval) -> Bool { since.map { now.timeIntervalSince($0) >= seconds } ?? false }

            // What each level's conditions say now.
            var overloaded: [String] = []
            if r.memory == .critical { overloaded.append("memory pressure critical") }
            if growth >= t.swapGrowth { overloaded.append("swap grew \(Self.gigabytes(growth)) in \(Self.minutes(t.swapGrowthWindow))") }
            if held(overloadedLoadSince, t.overloadedLoadFor) {
                overloaded.append("load \(Self.load(r.load1)) on \(r.cores) cores (over \(Self.factor(t.overloadedLoad))) for \(Self.minutes(now.timeIntervalSince(overloadedLoadSince!)))")
            }
            if r.thermal == .critical { overloaded.append("thermal state critical") }
            var busy: [String] = []
            if r.memory == .warning { busy.append("memory pressure warning") }
            if held(busyLoadSince, t.busyLoadFor) {
                busy.append("load \(Self.load(r.load1)) on \(r.cores) cores (over \(Self.factor(t.busyLoad))) for \(Self.minutes(now.timeIntervalSince(busyLoadSince!)))")
            }
            if r.thermal == .serious { busy.append("thermal state serious") }

            // The calm side, instantly: at most Busy, and OK.
            let atMostBusy = r.memory != .critical && growth < t.swapGrowth && r.load1 <= t.overloadedLoad * cores && r.thermal != .critical
            let atMostOK = atMostBusy && r.memory == .normal && r.load1 < t.busyLoad * cores && r.thermal < .serious
            calmForBusySince = atMostBusy ? (calmForBusySince ?? now) : nil
            calmForOKSince = atMostOK ? (calmForOKSince ?? now) : nil

            let previous = level
            if !overloaded.isEmpty {
                if level != .overloaded { move(to: .overloaded, now: now) }
                reasons = overloaded
            } else if !busy.isEmpty && level < .busy {
                move(to: .busy, now: now)
                reasons = busy
            } else if level > .ok && held(calmForOKSince, t.stepDownAfter) {
                move(to: .ok, now: now)
                reasons = ["calm for \(Self.minutes(now.timeIntervalSince(calmForOKSince!)))"]
            } else if level == .overloaded && held(calmForBusySince, t.stepDownAfter) {
                move(to: .busy, now: now)
                reasons = busy.isEmpty ? ["no longer overloaded for \(Self.minutes(now.timeIntervalSince(calmForBusySince!)))"] : busy
            } else if level == .busy && !busy.isEmpty {
                reasons = busy
            }
            if since == nil { since = now }
            return previous == level ? nil : Change(from: previous, to: level, reasons: reasons)
        }

        private mutating func move(to new: Level, now: Date) {
            level = new
            since = now
        }

        /// One line: the level's reasons, or the readings at OK.
        var summary: String {
            guard level != .ok, !reasons.isEmpty else { return last.map(Self.readingsLine) ?? "No readings yet" }
            return reasons.joined(separator: "; ")
        }

        static func readingsLine(_ r: Readings) -> String {
            "load \(load(r.load1)) on \(r.cores) cores, memory \(r.memory.rawValue), swap \(gigabytes(r.swapUsed)), thermal \(r.thermal.rawValue)"
        }
        static func gigabytes(_ bytes: Int64) -> String { String(format: "%.1f GB", Double(bytes) / Double(1 << 30)) }
        static func load(_ value: Double) -> String { value >= 10 ? String(Int(value.rounded())) : String(format: "%.1f", value) }
        static func factor(_ value: Double) -> String { value == value.rounded() ? "\(Int(value))\u{00D7}" : String(format: "%.1f\u{00D7}", value) }
        static func minutes(_ interval: TimeInterval) -> String {
            if interval < 60 { return "\(Int(interval)) s" }
            let minutes = Int((interval / 60).rounded(.down))
            return minutes == 1 ? "1 min" : "\(minutes) min"
        }
    }

    /// The level the service last worked out, for the rest of it (work threads ask before they
    /// start a turn: ChatSession+Pressure; agents get their build caps from it). OK where
    /// nothing monitors (the app, tests). Set on the main thread only.
    nonisolated(unsafe) static var current: Level = .ok
    /// Whether work threads are held back at all (Settings → Background service, "Hold back
    /// work threads when the Mac is under pressure"; preference "pressureHoldsWork", on by default).
    nonisolated(unsafe) static var holdsWork = true

    // MARK: - Agents' builds

    /// How many jobs a build an agent runs may use: half the cores at OK, a quarter under
    /// pressure (at least 1).
    static func buildJobs(level: Level, cores: Int) -> Int {
        max(1, level == .ok ? cores / 2 : cores / 4)
    }

    /// Build parallelism caps for an agent's environment (and so every shell and build it runs):
    /// CMake (which passes it to ninja: ninja itself reads no variable and defaults to cores + 2),
    /// make, Cargo. xcodebuild's -jobs comes from scripts/lib/build-lock.sh. A value already
    /// set is kept.
    static func agentBuildEnvironment(level: Level, cores: Int) -> [String: String] {
        let jobs = String(buildJobs(level: level, cores: cores))
        return ["CMAKE_BUILD_PARALLEL_LEVEL": jobs, "MAKEFLAGS": "-j\(jobs)", "CARGO_BUILD_JOBS": jobs]
    }

    /// One row of the process table (`ps -axo pid=,ppid=,nice=,comm=`).
    struct ProcessRow: Equatable {
        var pid: Int32
        var ppid: Int32
        var nice: Int32
        /// The executable's name (comm's last path component).
        var name: String
    }

    /// Compilers, linkers and build drivers an agent's build runs.
    static let buildTools: Set<String> = ["clang", "clang++", "cc", "c++", "gcc", "g++", "ld", "ld64", "ld-prime", "lld", "swift-frontend", "swiftc",
                                          "swift-build", "swift-driver", "swift", "ninja", "make", "gmake", "cmake", "cargo", "rustc", "node",
                                          "xcodebuild", "ibtool", "actool", "go", "javac", "java", "gradle", "esbuild", "tsc", "bun", "deno"]
    /// The process agents run under: everything a Chatterbox agent starts descends from one.
    static let hostName = "ChatterboxHost"
    /// How nice an agent's builds are made while the Mac is under pressure.
    static let buildNice: Int32 = 15

    /// While the Mac is busy or overloaded: the build processes descending from a Chatterbox
    /// host that aren't yet as nice as `buildNice`. Only lowered in priority, never stopped;
    /// nothing outside a host's tree is ever named.
    static func reniceTargets(_ table: [ProcessRow], level: Level) -> [Int32] {
        guard level != .ok else { return [] }
        let byPID = Dictionary(table.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var underHost: [Int32: Bool] = [:]
        func descends(_ pid: Int32) -> Bool {
            if let known = underHost[pid] { return known }
            var chain: [Int32] = []
            var current = byPID[pid]?.ppid
            var found = false
            while let p = current, p > 1, chain.count < 64 {
                if let known = underHost[p] { found = known; break }
                chain.append(p)
                guard let row = byPID[p] else { break }
                if row.name == hostName { found = true; break }
                current = row.ppid
            }
            for p in chain { underHost[p] = found || (byPID[p]?.name == hostName) }
            underHost[pid] = found
            return found
        }
        return table.filter { buildTools.contains($0.name) && $0.nice < buildNice && $0.name != hostName && descends($0.pid) }.map(\.pid)
    }

    /// `ps -axo pid=,ppid=,nice=,comm=` as rows.
    static func processRows(fromPS output: String) -> [ProcessRow] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard fields.count == 4, let pid = Int32(fields[0]), let ppid = Int32(fields[1]), let nice = Int32(fields[2]) else { return nil }
            let command = String(fields[3]).trimmingCharacters(in: .whitespaces)
            return ProcessRow(pid: pid, ppid: ppid, nice: nice, name: (command as NSString).lastPathComponent)
        }
    }
}
