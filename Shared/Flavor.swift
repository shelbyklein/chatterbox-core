import Foundation

/// Which copy of Chatterbox this is: the real one, or Chatterbox Dev, which runs beside it with
/// its own app, service, host, data, ports and phone app (plans/dev-environment.md).
///
/// Chosen when it's built: the `Dev` configuration compiles every target with `CHATTERBOX_DEV`
/// and writes `ChatterboxFlavor` = dev into the apps' Info.plist. The service and host are
/// built in the same configuration as the app that carries them, so all three agree; command-
/// line builds (tests) are real unless they pass `-D CHATTERBOX_DEV`. Everything that differs
/// between the two copies is named here; the real values are exactly the ones used before Dev
/// existed (tests/flavor checks them).
enum Flavor: String, Sendable {
    case real, dev

    static let current: Flavor = {
        #if CHATTERBOX_DEV
        return .dev
        #else
        return .real
        #endif
    }()

    /// What the running bundle's Info.plist says, when it has one (the service doesn't).
    static var bundleFlavor: Flavor? {
        (Bundle.main.object(forInfoDictionaryKey: "ChatterboxFlavor") as? String).flatMap(Flavor.init(rawValue:))
    }

    var isDev: Bool { self == .dev }

    // MARK: Names and signing identities

    static let teamID = "9F3MKVW9C5"
    /// The app's name: its bundle, window title, notifications and data folder.
    var appName: String { isDev ? "Chatterbox Dev" : "Chatterbox" }
    var appBundleID: String { isDev ? "com.shelbyklein.Chatterbox.dev" : "com.shelbyklein.Chatterbox" }
    var hostBundleID: String { appBundleID + ".Host" }
    var daemonBundleID: String { appBundleID + ".Daemon" }
    var mobileBundleID: String { isDev ? "com.shelbyklein.Chatterbox.mobile.dev" : "com.shelbyklein.Chatterbox.mobile" }
    /// The service's executable (its process name, which scripts look for).
    var daemonName: String { isDev ? "chatterboxd-dev" : "chatterboxd" }
    /// The service's LaunchAgent.
    var serviceLabel: String { isDev ? "com.shelbyklein.chatterboxd.dev" : "com.shelbyklein.chatterboxd" }
    /// Prefix of every Keychain item's service name (secrets, APNs key, phone tokens).
    var keychainPrefix: String { appBundleID }
    var urlScheme: String { isDev ? "chatterbox-dev" : "chatterbox" }
    /// Shared with the iPhone widget. Dev has no widget, so no group.
    var appGroup: String? { isDev ? nil : "group.com.shelbyklein.Chatterbox" }

    // MARK: Folders

    private static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }
    /// Application Support/Chatterbox (Dev: Application Support/Chatterbox Dev). CHATTERBOX_DATA_DIR,
    /// where it's honored, takes precedence.
    var dataDirectory: URL { Self.applicationSupport.appendingPathComponent(appName, isDirectory: true) }
    var hostDirectory: URL { dataDirectory.appendingPathComponent("Host", isDirectory: true) }
    /// ~/Chatterbox (Dev: ~/Chatterbox Dev): Studios and the PC's file copies.
    var homeFolder: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent(appName, isDirectory: true)
    }
    var studiosDirectory: URL { homeFolder.appendingPathComponent("Studios", isDirectory: true) }
    var pcMirrorDirectory: URL { homeFolder.appendingPathComponent("PC", isDirectory: true) }

    // MARK: Preferences

    /// The service's preferences. The real one uses its own standard domain ("chatterboxd");
    /// Dev's is a suite of its own, so its pairings and pins never mix with the real ones.
    var servicePreferencesSuite: String? { isDev ? "com.shelbyklein.chatterboxd.dev" : nil }

    // MARK: Network

    /// The phone API, and its Bonjour type. Dev advertises its own type, so the real phone app
    /// never sees it and the Dev phone app sees only Dev.
    var companionPort: UInt16 { isDev ? 47_421 : 47_321 }
    var bonjourType: String { isDev ? "_chatterbox-dev._tcp" : "_chatterbox._tcp" }
    /// Claude's connector, on loopback. Only the real one has a public tunnel.
    var connectorPort: UInt16 { isDev ? 47_431 : 47_331 }
    var connectorPublicURL: String { isDev ? "http://127.0.0.1:47431" : "https://chatterbox-mcp.shelbyklein.com" }
    /// Shelby-PC: the Mac end of the Ollama tunnel, and the PC ports tunnelled back to the proxy
    /// (one for Codex, a range of 500 for Claude chats). Dev's are 1000 higher.
    var pcTunnelPort: Int { isDev ? 48_340 : 47_340 }
    var pcCodexPort: Int { isDev ? 48_390 : 47_390 }
    var pcClaudeBasePort: Int { isDev ? 48_400 : 47_400 }

    // MARK: Diagnostics

    var signpostSubsystem: String { appBundleID }
    /// A crash report (Library/Logs/DiagnosticReports) from one of this copy's processes, by
    /// file name ("Chatterbox-2026-…ips", "ChatterboxHost-…", "Chatterbox Dev-…").
    func ownsCrashReport(named name: String) -> Bool {
        guard name.hasPrefix("Chatterbox") else { return false }
        return name.hasPrefix(Flavor.dev.appName) == isDev
    }
}
