#if GOLEM_APP
import AVFoundation
import OSLog
import Security
import SwiftUI

/// Golem reads his replies aloud: with an ElevenLabs voice when you've added an API key on this
/// phone, otherwise (or if ElevenLabs fails) with the phone's own voice.
///
/// The key stays in this phone's Keychain and goes only to ElevenLabs. Reply text is sent to
/// ElevenLabs to be spoken, a sentence or two at a time while the reply is still being written, the
/// next ones fetched while one plays.
@MainActor
@Observable
final class GolemVoice: NSObject {
    static let shared = GolemVoice()

    struct Voice: Decodable, Identifiable, Hashable {
        var voice_id: String
        var name: String
        var id: String { voice_id }
    }

    /// The reply being read, if any.
    private(set) var speakingID: UUID?
    private(set) var problem: String?
    private(set) var voices: [Voice] = []
    private(set) var hasKey = false

    var autoRead: Bool {
        get { access(keyPath: \.autoRead); return AppPreferences.defaults.bool(forKey: "golemVoiceAutoRead") }
        set { withMutation(keyPath: \.autoRead) { AppPreferences.defaults.set(newValue, forKey: "golemVoiceAutoRead") } }
    }
    /// After reading a reply aloud, listen for yours and send it when you pause.
    var listensAfter: Bool {
        get { access(keyPath: \.listensAfter); return AppPreferences.defaults.object(forKey: "golemVoiceListensAfter") as? Bool ?? true }
        set { withMutation(keyPath: \.listensAfter) { AppPreferences.defaults.set(newValue, forKey: "golemVoiceListensAfter") } }
    }
    var voiceID: String {
        get { access(keyPath: \.voiceID); return AppPreferences.defaults.string(forKey: "golemVoiceID") ?? Self.defaultVoice }
        set { withMutation(keyPath: \.voiceID) { AppPreferences.defaults.set(newValue, forKey: "golemVoiceID") } }
    }

    /// ElevenLabs' example voice, until you pick one.
    static let defaultVoice = "JBFqnCBsd6RMkjVDRZzb"
    /// ElevenLabs requests in flight at once, and how far ahead of the segment playing they run.
    private static let maxInFlight = 2
    private static let lookahead = 2
    private static let log = Logger(subsystem: "com.shelbyklein.Golem", category: "Voice")

    // The reply being read. Everything here is reset by `teardown()`.
    @ObservationIgnored private var current: UUID?
    @ObservationIgnored private var epoch = 0                 // bumped on teardown; stale fetch callbacks check it
    @ObservationIgnored private var halted = false            // stop() was called for `current`
    @ObservationIgnored private var done = false              // `current` was read to the end
    @ObservationIgnored private var turnEnded = false         // final text received
    @ObservationIgnored private var segmenter = SpeechSegmenter()
    @ObservationIgnored private var segments: [String] = []
    @ObservationIgnored private var thenBlock: (() -> Void)?
    @ObservationIgnored private var apiKey: String?

    // ElevenLabs pipeline: fetch up to two ahead, play strictly in order.
    @ObservationIgnored private var playIndex = 0             // the segment playing, or next to play
    @ObservationIgnored private var nextFetch = 0
    @ObservationIgnored private var fetching: [Int: Task<Void, Never>] = [:]
    @ObservationIgnored private var fetched: [Int: Result<Data, Error>] = [:]
    @ObservationIgnored private var player: AVAudioPlayer?

    // The phone's voice: used without a key, and for a failed segment and the rest.
    @ObservationIgnored private var localMode = false
    @ObservationIgnored private var localQueued = 0           // segments handed to the synthesizer
    @ObservationIgnored private var localPending: [ObjectIdentifier: AVSpeechUtterance] = [:]
    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
        hasKey = Self.readKey() != nil
    }

    // MARK: - Speaking

    func toggle(_ id: UUID, text: String) {
        if speakingID == id { stop() } else { speak(id, text: text) }
    }

    /// Reads a whole reply. `then` runs only if it was read to the end, not when it's stopped.
    func speak(_ id: UUID, text: String, then: (() -> Void)? = nil) {
        begin(id)   // an explicit request restarts, even after stop() or a finished read
        update(reply: id, text: text, final: true, then: then)
    }

    /// Reads a reply while it is still being written: `text` is the reply's full text so far and
    /// `final` is true once its turn ended. A new `id` replaces whatever was being read; the same
    /// `id` continues, and sentences already queued are never read again. `then` (the latest one
    /// given) runs only if the reply was read to the end after `final`, never after `stop()`.
    /// After `stop()`, updates for that reply are ignored until a different `id` arrives.
    func update(reply id: UUID, text: String, final isFinal: Bool, then: (() -> Void)? = nil) {
        if id != current { begin(id) }
        guard !halted, !done else { return }
        if let then { thenBlock = then }
        if isFinal { turnEnded = true }
        let ready = segmenter.feed(text, final: isFinal)
        if !ready.isEmpty {
            if segments.isEmpty { activate() }
            segments += ready
            Self.log.notice("Reply segments queued: \(self.segments.count)")
        }
        advance()
    }

    /// Cancels fetches, playback and the queue. `then` isn't called.
    func stop() {
        halted = true
        teardown()
    }

    private func begin(_ id: UUID) {
        teardown()
        current = id
        halted = false
        done = false
        problem = nil
        apiKey = Self.readKey()
        speakingID = id
    }

    /// Tears down everything in flight and forgets the reply's progress.
    private func teardown() {
        epoch += 1
        fetching.values.forEach { $0.cancel() }
        fetching = [:]
        fetched = [:]
        player?.delegate = nil
        player?.stop()
        player = nil
        let hadPending = !localPending.isEmpty
        localPending = [:]   // before stopping, so the delegate's didCancel finds nothing
        if hadPending || synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        segmenter = SpeechSegmenter()
        segments = []
        thenBlock = nil
        turnEnded = false
        playIndex = 0
        nextFetch = 0
        localMode = false
        localQueued = 0
        speakingID = nil
        deactivate()
    }

    // MARK: - Pipeline

    /// Moves the reply along: starts fetches, starts the next segment when nothing is playing, and
    /// finishes once the last one has been read. Called after every event.
    private func advance() {
        guard !halted, !done else { return }
        if !localMode, apiKey == nil, !segments.isEmpty { localMode = true; localQueued = playIndex }
        if localMode {
            speakLocally()
        } else if let key = apiKey {
            prefetch(key: key)
            if player == nil { playNext() }
        }
        let drained = segments.isEmpty
            || (localMode ? localQueued == segments.count && localPending.isEmpty
                          : playIndex == segments.count && player == nil)
        if turnEnded, drained, !done, !halted { finish() }
    }

    private func finish() {
        done = true
        let completion = segments.isEmpty ? nil : thenBlock   // nothing was said: nothing to follow up on
        thenBlock = nil
        Self.log.notice("Reply finished (\(self.segments.count) segments)")
        speakingID = nil
        deactivate()
        completion?()
    }

    private func prefetch(key: String) {
        while fetching.count < Self.maxInFlight, nextFetch < segments.count, nextFetch <= playIndex + Self.lookahead {
            let index = nextFetch, text = segments[index], epoch = self.epoch, voice = voiceID
            nextFetch += 1
            fetching[index] = Task { [weak self] in
                let result: Result<Data, Error>
                do { result = .success(try await Self.fetch(text, key: key, voice: voice)) } catch { result = .failure(error) }
                guard let self, !Task.isCancelled, self.epoch == epoch else { return }
                self.fetching[index] = nil
                self.fetched[index] = result
                self.advance()
            }
        }
    }

    /// Plays the next segment once its audio has arrived; a failure switches to the phone's voice.
    private func playNext() {
        guard playIndex < segments.count, let result = fetched[playIndex] else { return }
        fetched[playIndex] = nil
        do {
            let player = try AVAudioPlayer(data: try result.get())
            player.delegate = self
            self.player = player
            guard player.play() else { throw VoiceError("Playback didn't start.") }
        } catch {
            player?.delegate = nil
            player = nil
            problem = "ElevenLabs: \(error.localizedDescription) Using the phone's voice."
            Self.log.notice("ElevenLabs failed on segment \(self.playIndex + 1); using the phone's voice")
            fetching.values.forEach { $0.cancel() }
            fetching = [:]
            fetched = [:]
            localMode = true
            localQueued = playIndex
            advance()
        }
    }

    private func speakLocally() {
        while localQueued < segments.count {
            let utterance = AVSpeechUtterance(string: segments[localQueued])
            utterance.voice = Self.phoneVoice
            localPending[ObjectIdentifier(utterance)] = utterance
            localQueued += 1
            synthesizer.speak(utterance)
        }
    }

    fileprivate func playerFinished(_ finished: AVAudioPlayer) {
        guard let player, player === finished else { return }
        self.player = nil
        playIndex += 1
        advance()
    }

    fileprivate func utteranceFinished(_ utterance: AVSpeechUtterance) {
        guard localPending.removeValue(forKey: ObjectIdentifier(utterance)) != nil else { return }
        advance()
    }

    private static var phoneVoice: AVSpeechSynthesisVoice? {
        AVSpeechSynthesisVoice(language: Locale.current.identifier.replacingOccurrences(of: "_", with: "-"))
            ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    @ObservationIgnored private var holdsSession = false

    private func activate() {
        guard !holdsSession else { return }
        holdsSession = true
        GolemAudioSession.shared.beginPlayback()
    }

    private func deactivate() {
        guard holdsSession else { return }
        holdsSession = false
        GolemAudioSession.shared.endPlayback()
    }

    // MARK: - ElevenLabs

    private static func fetch(_ text: String, key: String, voice: String) async throws -> Data {
        var components = URLComponents(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voice)")!
        components.queryItems = [URLQueryItem(name: "output_format", value: "mp3_44100_128")]
        var request = URLRequest(url: components.url!, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        request.httpBody = try ElevenLabsSpeechSettings.payload(text: text, speed: ElevenLabsSpeechSettings.speed())
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response, data)
        return data
    }

    /// Your voices, to pick from in Settings.
    func loadVoices() async {
        guard let key = Self.readKey() else { voices = []; return }
        var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v2/voices?page_size=100")!, timeoutInterval: 20)
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        struct Page: Decodable { var voices: [Voice] }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            try Self.check(response, data)
            voices = try JSONDecoder().decode(Page.self, from: data).voices.sorted { $0.name < $1.name }
            if !voices.contains(where: { $0.voice_id == voiceID }), let first = voices.first { voiceID = first.voice_id }
            problem = nil
        } catch {
            problem = "Couldn't load your ElevenLabs voices: \(error.localizedDescription)"
        }
    }

    private static func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw VoiceError("No response from ElevenLabs.") }
        guard http.statusCode == 200 else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]).flatMap { json -> String? in
                if let detail = json["detail"] as? [String: Any] { return detail["message"] as? String }
                return json["detail"] as? String
            }
            switch http.statusCode {
            case 401: throw VoiceError("The API key wasn't accepted.")
            case 429: throw VoiceError("Rate or quota limit reached.")
            default: throw VoiceError(detail ?? "Request failed (\(http.statusCode)).")
            }
        }
    }

    struct VoiceError: LocalizedError {
        var message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    // MARK: - The key, in this phone's Keychain

    private static let service = "com.shelbyklein.Golem.elevenlabs"

    func saveKey(_ value: String) {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: Self.service, kSecAttrAccount: "api-key"]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData] = Data(key.utf8)
        item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        hasKey = SecItemAdd(item as CFDictionary, nil) == errSecSuccess
        Task { await loadVoices() }
    }

    func removeKey() {
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: Self.service, kSecAttrAccount: "api-key"] as CFDictionary)
        hasKey = false
        voices = []
    }

    private static func readKey() -> String? {
        var value: CFTypeRef?
        let status = SecItemCopyMatching([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: "api-key",
                                          kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne] as CFDictionary, &value)
        guard status == errSecSuccess, let data = value as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - What gets said

    /// A reply as it should sound: no markdown marks, code blocks or full URLs and paths, capped
    /// at 5000 characters (see SpeechSegments, which also does the streaming cleaning).
    static func spoken(_ text: String) -> String { SpeechSegments.spoken(text) }
}

/// Carries a non-Sendable delegate argument to the main actor. The object is only compared, never
/// touched off the main actor, and holding it keeps its identity from being reused meanwhile.
private struct Handoff<T>: @unchecked Sendable { let value: T }

extension GolemVoice: AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let box = Handoff(value: player)
        Task { @MainActor in self.playerFinished(box.value) }
    }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let box = Handoff(value: player)
        Task { @MainActor in self.playerFinished(box.value) }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let box = Handoff(value: utterance)
        Task { @MainActor in self.utteranceFinished(box.value) }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let box = Handoff(value: utterance)
        Task { @MainActor in self.utteranceFinished(box.value) }
    }
}

/// Settings → Voice: the ElevenLabs key, the voice, and reading new replies aloud.
struct GolemVoiceSettings: View {
    private var voice: GolemVoice { .shared }
    @State private var keyEntry = ""

    var body: some View {
        Section {
            Toggle("Read new replies aloud", isOn: Binding(get: { voice.autoRead }, set: { voice.autoRead = $0 }))
            if voice.autoRead {
                Toggle("Then listen for my reply", isOn: Binding(get: { voice.listensAfter }, set: { voice.listensAfter = $0 }))
            }
            DictationPauseControl()
            ElevenLabsSpeedControl()
            if voice.hasKey {
                if voice.voices.isEmpty {
                    LabeledContent("Voice", value: "Loading\u{2026}")
                } else {
                    Picker("Voice", selection: Binding(get: { voice.voiceID }, set: { voice.voiceID = $0 })) {
                        ForEach(voice.voices) { Text($0.name).tag($0.voice_id) }
                    }
                }
                Button("Remove ElevenLabs Key", role: .destructive) { voice.removeKey() }
            } else {
                SecureField("ElevenLabs API key", text: $keyEntry)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("Save Key") { voice.saveKey(keyEntry); keyEntry = "" }
                    .disabled(keyEntry.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Button(voice.speakingID == Self.testID ? "Stop" : "Test Voice") {
                voice.toggle(Self.testID, text: "Hi, it's Golem. This is how I'll sound when I read my replies to you.")
            }
            if let problem = voice.problem { Text(problem).font(.caption).foregroundStyle(.orange) }
        } header: {
            Text("Voice")
        } footer: {
            Text((voice.autoRead && voice.listensAfter ? "Golem reads each reply as it arrives and always finishes unless you tap stop or mute; then he listens, and what you say sends when you pause. With headphones, the iPhone's microphone hears you, so keep it nearby. Stay quiet to end the conversation. " : "") + (voice.hasKey
                 ? "Replies are spoken with ElevenLabs: their text is sent to ElevenLabs and uses your plan's credits. The key stays on this iPhone."
                 : "Without a key, Golem uses this iPhone's own voice. Add an ElevenLabs API key for a natural voice; a key limited to text to speech, with a credit limit, is enough."))
        }
        .task(id: voice.hasKey) { if voice.hasKey && voice.voices.isEmpty { await voice.loadVoices() } }
    }

    private static let testID = UUID(uuidString: "00000000-0000-0000-0000-00000000E1E1")!
}
#endif
