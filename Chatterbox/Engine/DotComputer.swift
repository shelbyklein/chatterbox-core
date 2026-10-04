#if !CHATTERBOX_HEADLESS
import AppKit
#endif
import Foundation
import Observation

/// Dot's own computer: a small Linux desktop with Chromium, run with Docker on this Mac.
/// Dot browses it through Playwright's tool server; you watch it, and can take over, in a
/// live view. It's separate from your Mac: it can't see your files. Both of its ports are
/// published on 127.0.0.1 only, and its browser profile (logins) is kept in a Docker volume.
@MainActor
@Observable
final class DotComputer {
    static let shared = DotComputer()

    enum State: Equatable {
        case checking
        /// Docker isn't installed.
        case noDocker
        /// Docker is here, but the computer hasn't been built yet.
        case notSetUp
        case building
        case stopped
        case starting
        case running
        case failed(String)
    }

    private(set) var state: State = .checking
    /// The latest line from building or starting, shown while it works.
    private(set) var progress = ""

    static let image = "chatterbox-dot-computer"
    static let container = "chatterbox-dot"
    static let volume = "chatterbox-dot-profile"
    static let viewPort = 47_331
    static let toolsPort = 47_332

    var viewURL: URL { URL(string: "http://127.0.0.1:\(Self.viewPort)/vnc.html?autoconnect=1&resize=scale&reconnect=1&reconnect_delay=1000")! }
    var toolsURL: String { "http://127.0.0.1:\(Self.toolsPort)/mcp" }
    var isRunning: Bool { state == .running }

    /// The state in one word, for Dot's tools.
    var stateName: String {
        switch state {
        case .checking: "checking"
        case .noDocker: "no_docker"
        case .notSetUp: "not_set_up"
        case .building: "setting_up"
        case .stopped: "stopped"
        case .starting: "starting"
        case .running: "running"
        case .failed: "failed"
        }
    }

    /// What's happening, or what went wrong.
    var stateDetail: String {
        if case .failed(let reason) = state { return reason }
        return progress
    }

    static var docker: String? {
        ["/usr/local/bin/docker", "/opt/homebrew/bin/docker", "/Applications/Docker.app/Contents/Resources/bin/docker"]
            .first(where: FileManager.default.isExecutableFile(atPath:))
    }

    /// Looks at what's there: Docker, the image, and whether the computer is running.
    func refresh() async {
        guard let docker = Self.docker else { state = .noDocker; return }
        guard await daemonUp(docker) else {
            // Docker Desktop isn't open; that's fine until the computer is wanted.
            if state == .checking { state = await imageExists(docker, assumeIfUnknown: true) ? .stopped : .notSetUp }
            return
        }
        guard await imageExists(docker) else { state = .notSetUp; return }
        let running = await Git.run(docker, ["inspect", "-f", "{{.State.Running}}", Self.container])
        state = running.out.trimmingCharacters(in: .whitespacesAndNewlines) == "true" ? .running : .stopped
    }

    /// Builds the computer from the Dockerfile bundled with Chatterbox (about 2.4 GB,
    /// mostly Chromium and its libraries), then starts it.
    func setUp() async {
        guard let docker = Self.docker else { state = .noDocker; return }
        guard let folder = Bundle.main.url(forResource: "DotComputer", withExtension: nil) else {
            state = .failed("The computer's setup files are missing from Chatterbox.")
            return
        }
        state = .building
        progress = "Starting Docker\u{2026}"
        guard await ensureDaemon(docker) else { state = .failed("Docker didn't start. Open Docker Desktop and try again."); return }
        progress = "Downloading Linux and Chromium, and building (a few minutes the first time)\u{2026}"
        let build = await Git.run(docker, ["build", "-t", Self.image, folder.path])
        guard build.status == 0 else {
            state = .failed("Building didn't work: " + String((build.err.isEmpty ? build.out : build.err).suffix(300)))
            return
        }
        await start()
    }

    /// The image Chatterbox ships (its LABEL chatterbox.computer.version). An older image
    /// is rebuilt on the next start; the browser profile (sign-ins) is a volume and is kept.
    static let imageVersion = "2"

    /// The one folder the computer shares with the Mac: its browser's downloads.
    nonisolated static var downloadsFolder: URL {
        let base: URL
        if let dir = ProcessInfo.processInfo.environment["CHATTERBOX_DATA_DIR"], !dir.isEmpty {
            base = URL(fileURLWithPath: dir)
        } else {
            base = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Chatterbox")
        }
        let folder = base.appendingPathComponent("Computer/Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    func start() async {
        guard let docker = Self.docker else { state = .noDocker; return }
        state = .starting
        progress = "Starting Docker\u{2026}"
        guard await ensureDaemon(docker) else { state = .failed("Docker didn't start. Open Docker Desktop and try again."); return }
        guard await imageExists(docker) else { state = .notSetUp; return }
        // An older computer: rebuild its image (quick; most layers are cached) and replace
        // the container. The profile volume, and so every sign-in, is kept.
        let label = await Git.run(docker, ["image", "inspect", Self.image, "--format", "{{index .Config.Labels \"chatterbox.computer.version\"}}"])
        var replace = label.out.trimmingCharacters(in: .whitespacesAndNewlines) != Self.imageVersion
        if replace, let folder = Bundle.main.url(forResource: "DotComputer", withExtension: nil) {
            progress = "Updating the computer (a minute)\u{2026}"
            let build = await Git.run(docker, ["build", "-t", Self.image, folder.path])
            guard build.status == 0 else { state = .failed("Updating didn't work: " + String((build.err.isEmpty ? build.out : build.err).suffix(300))); return }
        }
        let mounts = await Git.run(docker, ["inspect", "-f", "{{range .Mounts}}{{.Destination}} {{end}}", Self.container])
        if mounts.status == 0, !mounts.out.contains("/home/dot/Downloads") { replace = true }
        if replace { _ = await Git.run(docker, ["rm", "-f", Self.container]) }
        progress = "Starting the computer\u{2026}"
        let started = replace ? Git.Output(status: 1, out: "", err: "") : await Git.run(docker, ["start", Self.container])
        if started.status != 0 {
            let run = await Git.run(docker, [
                "run", "-d", "--name", Self.container,
                "-p", "127.0.0.1:\(Self.viewPort):6080", "-p", "127.0.0.1:\(Self.toolsPort):8931",
                "-v", "\(Self.volume):/home/dot/profile",
                // Only this folder of the Mac's: what the browser downloads.
                "-v", "\(Self.downloadsFolder.path):/home/dot/Downloads",
                "--shm-size=1g",
                // Your Mac's time zone, so times on pages match yours.
                "-e", "TZ=\(TimeZone.current.identifier)", Self.image,
            ])
            guard run.status == 0 else { state = .failed("Couldn't start it: " + String(run.err.suffix(300))); return }
        }
        // Ready once the browser tool server answers.
        for _ in 0..<40 {
            if await toolsAnswer() {
                state = .running
                progress = ""
                await PreviewRelays.shared.applyToComputer()
                return
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        state = .failed("The computer started but its browser didn't come up.")
    }

    /// Runs the in-computer forwarder for a preview port (idempotent: a second one can't bind).
    func forward(port: Int) async {
        guard isRunning, let docker = Self.docker else { return }
        _ = await Git.run(docker, ["exec", "-d", Self.container, "chatterbox-forward", String(port)])
    }

    /// Stops the in-computer forwarder for a port.
    func unforward(port: Int) async {
        guard isRunning, let docker = Self.docker else { return }
        _ = await Git.run(docker, ["exec", Self.container, "pkill", "-f", "chatterbox-forward \(port)$"])
    }

    func stop() async {
        guard let docker = Self.docker else { return }
        _ = await Git.run(docker, ["stop", "-t", "3", Self.container])
        state = .stopped
    }

    // MARK: - Helpers

    private func daemonUp(_ docker: String) async -> Bool {
        await Git.run(docker, ["info", "--format", "{{.ServerVersion}}"]).status == 0
    }

    /// Opens Docker Desktop if it isn't running, and waits up to a minute and a half for it.
    private func ensureDaemon(_ docker: String) async -> Bool {
        if await daemonUp(docker) { return true }
        #if !CHATTERBOX_HEADLESS
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.docker.docker") {
            _ = try? await NSWorkspace.shared.openApplication(at: app, configuration: {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = false
                return configuration
            }())
        }
        #endif
        for _ in 0..<45 {
            try? await Task.sleep(for: .seconds(2))
            if await daemonUp(docker) { return true }
        }
        return false
    }

    private func imageExists(_ docker: String, assumeIfUnknown: Bool = false) async -> Bool {
        let result = await Git.run(docker, ["image", "inspect", Self.image, "--format", "{{.Id}}"])
        if result.status == 0 { return true }
        return assumeIfUnknown && result.err.localizedCaseInsensitiveContains("daemon")
    }

    private func toolsAnswer() async -> Bool {
        var request = URLRequest(url: URL(string: toolsURL)!)
        request.timeoutInterval = 2
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse) != nil
    }
}
