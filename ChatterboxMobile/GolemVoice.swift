#if GOLEM_APP
import AVFoundation
import Security
import SwiftUI

/// Golem reads his replies aloud: with an ElevenLabs voice when you've added an API key on this
/// phone, otherwise (or if ElevenLabs fails) with the phone's own voice.
///
/// The key stays in this phone's Keychain and goes only to ElevenLabs. Reply text is sent to
/// ElevenLabs to be spoken, a paragraph or so at a time, the next fetched while one plays.
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
    var voiceID: String {
        get { access(keyPath: \.voiceID); return AppPreferences.defaults.string(forKey: "golemVoiceID") ?? Self.defaultVoice }
        set { withMutation(keyPath: \.voiceID) { AppPreferences.defaults.set(newValue, forKey: "golemVoiceID") } }
    }

    /// ElevenLabs' example voice, until you pick one.
    static let defaultVoice = "JBFqnCBsd6RMkjVDRZzb"
    private static let model = "eleven_flash_v2_5"
    /// Long replies are read up to here, then "the rest is in the chat".
    private static let spokenLimit = 5000

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private var finished: CheckedContinuation<Void, Never>?

    override init() {
        super.init()
        synthesizer.delegate = self
        hasKey = Self.readKey() != nil
    }

    // MARK: - Speaking

    func toggle(_ id: UUID, text: String) {
        if speakingID == id { stop() } else { speak(id, text: text) }
    }

    func speak(_ id: UUID, text: String) {
        stop()
        let spoken = Self.spoken(text)
        guard !spoken.isEmpty else { return }
        speakingID = id
        problem = nil
        task = Task { [weak self] in
            await self?.read(spoken)
            guard let self, self.speakingID == id else { return }
            self.speakingID = nil
            self.deactivate()
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        player?.stop()
        player = nil
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        resumeFinished()
        if speakingID != nil { speakingID = nil; deactivate() }
    }

    private func read(_ text: String) async {
        activate()
        let chunks = Self.chunks(text)
        guard let key = Self.readKey() else { await speakLocally(text); return }
        var next: Task<Data, Error>? = Task { try await Self.fetch(chunks[0], key: key, voice: voiceID) }
        var index = 0
        do {
            while let pending = next, !Task.isCancelled {
                let data = try await pending.value
                let following = index + 1
                let voice = voiceID
                next = following < chunks.count ? Task { try await Self.fetch(chunks[following], key: key, voice: voice) } : nil
                try await play(data)
                index += 1
            }
        } catch {
            next?.cancel()
            guard !Task.isCancelled else { return }
            problem = "ElevenLabs: \(error.localizedDescription) Using the phone's voice."
            await speakLocally(chunks[index...].joined(separator: "\n\n"))
        }
    }

    private func play(_ data: Data) async throws {
        let player = try AVAudioPlayer(data: data)
        player.delegate = self
        self.player = player
        await withCheckedContinuation { continuation in
            finished = continuation
            if !player.play() { resumeFinished() }
        }
    }

    private func speakLocally(_ text: String) async {
        guard !Task.isCancelled else { return }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: Locale.current.identifier.replacingOccurrences(of: "_", with: "-"))
            ?? AVSpeechSynthesisVoice(language: "en-US")
        await withCheckedContinuation { continuation in
            finished = continuation
            synthesizer.speak(utterance)
        }
    }

    private func resumeFinished() {
        let continuation = finished
        finished = nil
        continuation?.resume()
    }

    private func activate() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    private func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
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
        request.httpBody = try JSONSerialization.data(withJSONObject: ["text": text, "model_id": model])
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

    /// A reply as it should sound: no markdown marks, code blocks or full URLs and paths.
    static func spoken(_ text: String) -> String {
        var s = text
        func replace(_ pattern: String, _ template: String, _ options: NSRegularExpression.Options = []) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return }
            s = regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
        }
        replace("```[\\s\\S]*?```", " (code in the chat) ")
        replace("`([^`]+)`", "$1")
        replace("!\\[[^\\]]*\\]\\([^)]*\\)", "")                   // images
        replace("\\[([^\\]]+)\\]\\([^)]*\\)", "$1")                // links → their text
        replace("https?://\\S+", "a link")
        replace("(?<![\\w.])(?:~|/[\\w.-]+)(?:/[\\w .-]+)+/([\\w.-]+)", "$1")   // paths → file name
        replace("^\\s*\\|?\\s*:?-{3,}.*$", "", .anchorsMatchLines)  // table rules
        replace("\\|", ", ")
        replace("^#{1,6}\\s*", "", .anchorsMatchLines)
        replace("^\\s*[-*+]\\s+", "", .anchorsMatchLines)
        replace("(\\*\\*|__|\\*|_)(\\S[^*_]*?\\S|\\S)\\1", "$2")
        replace("[ \\t]+", " ")
        replace("\\n{3,}", "\n\n")
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count > spokenLimit {
            let cut = s.prefix(spokenLimit)
            let end = cut.lastIndex(where: { ".!?".contains($0) }) ?? cut.endIndex
            s = String(s[..<end]) + ". The rest is in the chat."
        }
        return s
    }

    /// Paragraphs gathered into pieces of up to about 900 characters.
    static func chunks(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for paragraph in text.components(separatedBy: "\n\n") where !paragraph.isEmpty {
            if current.count + paragraph.count > 900, !current.isEmpty { result.append(current); current = "" }
            current += (current.isEmpty ? "" : "\n\n") + paragraph
        }
        if !current.isEmpty { result.append(current) }
        return result.isEmpty ? [text] : result
    }
}

extension GolemVoice: AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.resumeFinished() }
    }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in self.resumeFinished() }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.resumeFinished() }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.resumeFinished() }
    }
}

/// Settings → Voice: the ElevenLabs key, the voice, and reading new replies aloud.
struct GolemVoiceSettings: View {
    private var voice: GolemVoice { .shared }
    @State private var keyEntry = ""

    var body: some View {
        Section {
            Toggle("Read new replies aloud", isOn: Binding(get: { voice.autoRead }, set: { voice.autoRead = $0 }))
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
            Text(voice.hasKey
                 ? "Replies are spoken with ElevenLabs: their text is sent to ElevenLabs and uses your plan's credits. The key stays on this iPhone."
                 : "Without a key, Golem uses this iPhone's own voice. Add an ElevenLabs API key for a natural voice; a key limited to text to speech, with a credit limit, is enough.")
        }
        .task(id: voice.hasKey) { if voice.hasKey && voice.voices.isEmpty { await voice.loadVoices() } }
    }

    private static let testID = UUID(uuidString: "00000000-0000-0000-0000-00000000E1E1")!
}
#endif
