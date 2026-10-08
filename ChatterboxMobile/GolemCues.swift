#if GOLEM_APP
import AVFoundation

/// Plays Golem's conversation cues (Settings → Voice → Sound cues): a soft rising chime when it's
/// your turn to talk, a tick when your words are sent, a falling chime when he starts thinking.
@MainActor enum GolemCues {
    static let key = "golemSoundCues"
    static var enabled: Bool { AppPreferences.defaults.object(forKey: key) as? Bool ?? true }

    private static var playing: [AVAudioPlayer] = []
    /// Cues asked for together play one after another ("sent", then "thinking"), not on top of each other.
    private static var busyUntil = Date.distantPast
    private static var clips: [GolemCueTones.Cue: Data] = [:]

    static func play(_ cue: GolemCueTones.Cue) {
        guard enabled else { return }
        let data = clips[cue] ?? GolemCueTones.wav(cue)
        clips[cue] = data
        guard let player = try? AVAudioPlayer(data: data) else { return }
        player.volume = 0.5
        let length = GolemCueTones.duration(cue)
        let delay = max(0, busyUntil.timeIntervalSinceNow)
        busyUntil = Date().addingTimeInterval(delay + length + 0.12)
        // Keeps the audio session up for the cue, even if the microphone stops right after (one message).
        GolemAudioSession.shared.beginPlayback()
        playing.append(player)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { player.play() }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + length + 0.15) {
            playing.removeAll { $0 === player }
            GolemAudioSession.shared.endPlayback()
        }
    }
}
#endif
