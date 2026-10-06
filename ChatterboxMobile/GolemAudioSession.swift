import AVFoundation
import os

/// The one owner of the app's audio session, so speaking and listening can share it instead of
/// each setting its own category and shutting the other off. Playback and capture are counted;
/// the session deactivates only when neither is in use.
///
/// Playback alone is `.playback` / `.spokenAudio`. Once capture begins the session becomes
/// `.playAndRecord` / `.default` with A2DP (never HFP, so AirPods keep full-quality output) and the
/// phone's built-in microphone as the input, and stays that way until both counts reach zero, so
/// speech that is already playing isn't interrupted by a category change.
@MainActor
final class GolemAudioSession {
    static let shared = GolemAudioSession()

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Golem", category: "AudioSession")

    private(set) var playing = 0
    private(set) var capturing = 0
    /// Capture has begun and not both counts have reached zero: stay in `.playAndRecord`.
    private var recordLatched = false

    /// Who wants to hear about interruptions and route changes (each Dictation, while it holds capture).
    struct Observer {
        var interrupted: () -> Void = {}
        var routeChanged: () -> Void = {}
    }
    private var observers: [UUID: Observer] = [:]

    private init() {
        let center = NotificationCenter.default
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            Task { @MainActor in self?.interruption(type) }
        }
        center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.routeChanged() }
        }
    }

    /// Output goes to headphones (wired or Bluetooth), so the speaker can't echo into the mic.
    var headphonesConnected: Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains {
            [.headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE].contains($0.portType)
        }
    }

    /// Calls `interrupted` when the system interrupts the session (a call, Siri, an alarm) while
    /// something is capturing, and `routeChanged` after a route change. Returns a token for `removeObserver`.
    func addObserver(interrupted: @escaping () -> Void, routeChanged: @escaping () -> Void = {}) -> UUID {
        let id = UUID()
        observers[id] = Observer(interrupted: interrupted, routeChanged: routeChanged)
        return id
    }

    func removeObserver(_ id: UUID) { observers[id] = nil }

    /// Before playing speech.
    func beginPlayback() {
        playing += 1
        configure()
    }

    func endPlayback() {
        playing = max(0, playing - 1)
        settle()
    }

    /// Before the microphone starts. Throws when the session can't be set up for recording.
    func beginCapture() throws {
        capturing += 1
        recordLatched = true
        do { try configure(throwing: true) } catch {
            capturing = max(0, capturing - 1)
            settle()
            throw error
        }
    }

    func endCapture() {
        capturing = max(0, capturing - 1)
        settle()
    }

    private func configure() { try? configure(throwing: false) }

    private func configure(throwing: Bool) throws {
        let session = AVAudioSession.sharedInstance()
        if recordLatched {
            let options: AVAudioSession.CategoryOptions = [.allowBluetoothA2DP, .defaultToSpeaker, .duckOthers]
            // Only change the category when it differs, so a second holder doesn't disturb audio that is playing.
            if session.category != .playAndRecord || session.mode != .default || session.categoryOptions != options {
                try session.setCategory(.playAndRecord, mode: .default, options: options)
            }
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            preferBuiltInMicrophone()
        } else {
            if session.category != .playback || session.mode != .spokenAudio {
                try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            }
            try session.setActive(true)
        }
    }

    /// With AirPods connected the system may pick their (HFP) microphone; the phone's own mic keeps their output at full quality.
    private func preferBuiltInMicrophone() {
        let session = AVAudioSession.sharedInstance()
        guard session.currentRoute.inputs.first?.portType != .builtInMic,
              let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) else { return }
        do { try session.setPreferredInput(builtIn) } catch {
            Self.log.error("Couldn't prefer the built-in microphone: \(error.localizedDescription)")
        }
    }

    private func settle() {
        if playing == 0, capturing == 0 {
            recordLatched = false
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } else {
            configure()
        }
    }

    private func routeChanged() {
        guard playing + capturing > 0 else { return }
        if recordLatched { preferBuiltInMicrophone() }
        for observer in Array(observers.values) { observer.routeChanged() }
    }

    private func interruption(_ type: AVAudioSession.InterruptionType?) {
        switch type {
        case .began:
            Self.log.notice("Audio session interrupted")
            if capturing > 0 { for observer in Array(observers.values) { observer.interrupted() } }
        case .ended:
            // Whoever is still playing gets the session back; capture was ended by its owner.
            if playing + capturing > 0 { configure() }
        default:
            break
        }
    }
}
