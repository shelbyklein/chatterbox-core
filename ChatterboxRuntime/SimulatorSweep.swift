import Foundation

/// Which booted iOS simulators nothing is using any more. Test runs (this project's and
/// others') leave devices booted for days (one sat booted for nine days; three together held
/// 40 GB and 600 processes), so the background service looks every ten minutes and shuts down
/// the ones that have been idle for half an hour (ChatterboxDaemon/SimulatorSweeper.swift).
/// This is the decision alone, with what it needs handed in, so it can be tested without a
/// simulator: never a deletion, only shutdowns.
struct SimulatorSweep: Equatable {
    struct Device: Equatable, Hashable {
        var udid: String
        var name: String
    }
    enum Action: Equatable { case shutDown, keep }
    struct Decision: Equatable {
        var device: Device
        var action: Action
        var reason: String
    }

    /// How long a booted device must go unused before it's shut down.
    var idleAfter: TimeInterval = 30 * 60
    /// When each booted device was first seen unused, by UDID. Using it again clears it; so does
    /// a shutdown, or the device no longer being booted.
    private(set) var firstSeenIdle: [String: Date] = [:]

    /// Decides for every booted device.
    /// - processArguments: the command lines of every running process (`ps -axo args=`); one
    ///   naming the device's UDID (xcodebuild's -destination, simctl, a test's own tools) is
    ///   using it.
    /// - simulatorAppPaths: files Simulator.app has open (`lsof -p`): a path under
    ///   `Devices/<UDID>/` means that device is open in a Simulator window.
    /// - registered: devices a Chatterbox test script has on record as in use
    ///   (~/Library/Caches/Chatterbox/simulators/<udid>, from scripts/lib/test-hygiene.sh).
    mutating func evaluate(booted: [Device], processArguments: [String], simulatorAppPaths: [String],
                           registered: Set<String>, now: Date) -> [Decision] {
        let bootedIDs = Set(booted.map(\.udid))
        firstSeenIdle = firstSeenIdle.filter { bootedIDs.contains($0.key) }
        var decisions: [Decision] = []
        for device in booted {
            let udid = device.udid
            func keep(_ reason: String) { firstSeenIdle[udid] = nil; decisions.append(Decision(device: device, action: .keep, reason: reason)) }
            if registered.contains(udid) { keep("a Chatterbox test run has it on record as in use"); continue }
            if processArguments.contains(where: { $0.localizedCaseInsensitiveContains(udid) }) { keep("a running process names it"); continue }
            if simulatorAppPaths.contains(where: { $0.range(of: "/Devices/\(udid)/", options: .caseInsensitive) != nil }) { keep("open in Simulator.app"); continue }
            let since = firstSeenIdle[udid] ?? now
            firstSeenIdle[udid] = since
            let idle = now.timeIntervalSince(since)
            if idle >= idleAfter {
                firstSeenIdle[udid] = nil
                decisions.append(Decision(device: device, action: .shutDown, reason: "booted but nothing has used it for \(Self.minutes(idle)); shut down to free its memory and processes"))
            } else {
                decisions.append(Decision(device: device, action: .keep, reason: "unused for \(Self.minutes(idle)), under the \(Self.minutes(idleAfter)) idle time"))
            }
        }
        return decisions
    }

    /// Whether this is the installed service, which may act for the whole Mac: no data folder
    /// given, or the flavor's own (the LaunchAgents pass it). A test's service runs on a folder
    /// under /tmp and must never touch the Mac's simulators.
    static func isInstalledService(dataDir: String?, ownDataDirectory: String) -> Bool {
        guard let dataDir, !dataDir.isEmpty else { return true }
        func normalized(_ path: String) -> String {
            URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        }
        return normalized(dataDir) == normalized(ownDataDirectory)
    }

    /// How long a device must sit unused before it's shut down, by the Mac's pressure level
    /// (MacPressure): half an hour normally, 5 minutes while the Mac is busy, and no wait at all
    /// while it's overloaded (a device a running build or test names, a Simulator window has
    /// open, or a test run has on record is still kept).
    static func idleAfter(pressure level: String) -> TimeInterval {
        switch level {
        case "overloaded": return 0
        case "busy": return 5 * 60
        default: return 30 * 60
        }
    }

    static func minutes(_ interval: TimeInterval) -> String {
        let minutes = Int(interval / 60)
        return minutes == 1 ? "1 min" : "\(minutes) min"
    }

    /// `xcrun simctl list devices booted -j`: the booted devices in every runtime.
    static func devices(fromSimctlJSON data: Data) -> [Device] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let runtimes = root["devices"] as? [String: [[String: Any]]] else { return [] }
        return runtimes.values.flatMap { list in
            list.compactMap { entry -> Device? in
                guard let udid = entry["udid"] as? String, (entry["state"] as? String ?? "Booted") == "Booted" else { return nil }
                return Device(udid: udid, name: entry["name"] as? String ?? udid)
            }
        }.sorted { $0.name < $1.name }
    }
}
