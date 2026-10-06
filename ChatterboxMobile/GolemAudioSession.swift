import AVFoundation

/// The one owner of the app's audio session, so speaking and listening can share it instead of
/// each setting its own category and shutting the other off. Playback and capture are counted;
/// the session deactivates only when neither is in use.
@MainActor
final class GolemAudioSession {
    static let shared = GolemAudioSession()

    private(set) var playing = 0
    private(set) var capturing = 0

    /// Output goes to headphones (wired or Bluetooth), so the speaker can't echo into the mic.
    var headphonesConnected: Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains {
            [.headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE].contains($0.portType)
        }
    }

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
        do { try configure(throwing: true) } catch { capturing = max(0, capturing - 1); throw error }
    }

    func endCapture() {
        capturing = max(0, capturing - 1)
        settle()
    }

    private func configure() { try? configure(throwing: false) }

    /// Today's behavior, one role at a time: playback for speech, recording for dictation.
    private func configure(throwing: Bool) throws {
        let session = AVAudioSession.sharedInstance()
        if capturing > 0 {
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        } else {
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        }
        try session.setActive(true, options: capturing > 0 ? .notifyOthersOnDeactivation : [])
    }

    private func settle() {
        if playing == 0, capturing == 0 {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } else {
            configure()
        }
    }
}
