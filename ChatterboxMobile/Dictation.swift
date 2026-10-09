import AVFoundation
import Observation
import os
import Speech
import SwiftUI

/// Voice to text for the message box: listens, and writes what you say into the draft as
/// you speak. It recognizes on the device when it can, so the audio stays on the phone.
///
/// Besides the one-shot `start`, it has a conversation mode: the microphone and audio session stay
/// up across several utterances (so Golem can be talked over while it speaks) and each utterance
/// gets its own recognition request on the running engine.
@MainActor
@Observable
final class Dictation {
    static let pauseKey = "golemTalkPause"
    static let pauseRange = 0.5...3.0
    static let defaultPause = 1.0
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Golem", category: "Dictation")

    private(set) var isListening = false
    /// Why it couldn't start, if it couldn't.
    private(set) var problem: String?
    /// The engine and audio session are held across utterances (see `startConversation`).
    private(set) var conversationActive = false
    /// How many words of two letters or more count as talking over Golem: 1 with headphones, 2 on
    /// the speaker (where Golem's own voice can leak into the microphone). Set when a conversation
    /// starts and when the route changes.
    var bargeInMinimumWords = 2

    /// How long a pause ends your turn, in seconds. Kept in the app's preferences, within `pauseRange`.
    var pause: TimeInterval {
        get {
            let stored = AppPreferences.defaults.object(forKey: Self.pauseKey) as? Double ?? Self.defaultPause
            return min(max(stored, Self.pauseRange.lowerBound), Self.pauseRange.upperBound)
        }
        set {
            AppPreferences.defaults.set(min(max(newValue, Self.pauseRange.lowerBound), Self.pauseRange.upperBound), forKey: Self.pauseKey)
        }
    }

    @ObservationIgnored private var engine = AVAudioEngine()
    @ObservationIgnored private var requestBox = RecognitionRequestBox()
    @ObservationIgnored private var conversation: Conversation?
    @ObservationIgnored private var sessionObserver: UUID?
    @ObservationIgnored private var configurationObserver: NSObjectProtocol?
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    /// The conversation's SpeechAnalyzer engine (iOS 26); nil when it uses SFSpeechRecognizer.
    @ObservationIgnored private var analyzerEngine: (any ConversationRecognitionEngine)?
    @ObservationIgnored private var utteranceRecognizer: (any UtteranceRecognizer)?
    @ObservationIgnored private let recognizer = SFSpeechRecognizer()
    /// Hands-free: called once with what was said when you pause (empty if you said nothing).
    @ObservationIgnored private var onPause: ((String) -> Void)?
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var heard = ""
    @ObservationIgnored private var lastHeard = Date()
    @ObservationIgnored private var holdsSession = false

    /// Starts listening. `onText` gets the whole transcription so far, each time it changes.
    /// With `onPause`, it stops by itself: once you've spoken and then paused for `pause`
    /// seconds, or after `giveUp` seconds of silence, and hands `onPause` what it heard.
    func start(pause: TimeInterval = 1.5, giveUp: TimeInterval = 8,
               onPause: ((String) -> Void)? = nil, onText: @escaping (String) -> Void) async {
        stop()
        let captureGeneration = generation
        guard await prepare(captureGeneration), let recognizer else { return }
        do {
            try GolemAudioSession.shared.beginCapture()
            holdsSession = true

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.addsPunctuation = true
            if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
            self.request = request

            let input = engine.inputNode
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
                request.append(buffer)
            }
            engine.prepare()
            try engine.start()
            isListening = true
            heard = ""
            lastHeard = Date()
            self.onPause = onPause
            if onPause != nil {
                watchdog = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(250))
                        guard let self, self.generation == captureGeneration, self.isListening, !Task.isCancelled else { return }
                        let quiet = Date().timeIntervalSince(self.lastHeard)
                        if quiet >= (self.heard.isEmpty ? giveUp : pause) { self.finishHandsFree(); return }
                    }
                }
            }

            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let done = error != nil || result?.isFinal == true
                Task { @MainActor in
                    guard let self, self.generation == captureGeneration, self.isListening else { return }
                    if let text, text != self.heard {
                        self.heard = text
                        self.lastHeard = Date()
                        onText(text)
                    }
                    if done { if self.onPause != nil { self.finishHandsFree() } else { self.stop() } }
                }
            }
        } catch {
            problem = "Couldn't start listening: \(error.localizedDescription)"
            stop()
        }
    }

    /// Hands-free listening is over: stop, then pass on what was heard.
    private func finishHandsFree() {
        let handler = onPause, text = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        stop()
        handler?(text)
    }

    /// Stops listening. A hands-free listen stopped this way sends nothing. Also ends a conversation.
    func stop() {
        generation = UUID()
        onPause = nil
        watchdog?.cancel()
        watchdog = nil
        let wasConversation = conversationActive
        if wasConversation {
            conversationActive = false
            conversation = nil
            requestBox.clear()
            utteranceRecognizer?.cancel()
            utteranceRecognizer = nil
            analyzerEngine = nil
            if let sessionObserver { GolemAudioSession.shared.removeObserver(sessionObserver) }
            sessionObserver = nil
            if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
            configurationObserver = nil
        }
        guard isListening || request != nil else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        if wasConversation { task?.cancel() } else { task?.finish() }
        request = nil
        task = nil
        isListening = false
        // A conversation may have turned voice processing on for its engine; the next listen gets a plain one.
        if wasConversation { engine = AVAudioEngine() }
        if holdsSession { holdsSession = false; GolemAudioSession.shared.endCapture() }
    }

    // MARK: Conversation

    /// One utterance's worth of state while a conversation runs.
    private struct Conversation {
        var giveUp: TimeInterval
        var onSpeechDetected: () -> Void
        var onUtterance: (String) -> Void
        var onText: (String) -> Void
        var utterance = UUID()
        var state: UtterancePause
        /// When the current recognition request was opened (empty ones are replaced after about 50 s).
        var requestOpened = Date()
        /// The utterance was handed over; waiting for `nextUtterance()`.
        var awaitingNext = false
        /// Requests in a row that ended at once with nothing heard.
        var quickFailures = 0
        /// Hold to talk: the button is down, so a pause doesn't end the turn; letting go does.
        var holding = false
        /// Let go: the last words are still arriving before the turn is handed over.
        var releasing = false
        /// Words from requests that ended while the button was still down.
        var carry = ""
        /// Everything said this turn.
        var spoken: String { [carry, state.text].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: " ") }
    }

    /// Starts a conversation: permissions, the audio session and one running microphone, then the
    /// first utterance. The microphone stays on until `stop()`, so you can talk over Golem while it
    /// speaks. Each utterance ends when you pause (`onUtterance` gets the words) or, if nothing is
    /// heard for `giveUp` seconds, with "". `onSpeechDetected` fires once per utterance, at the first
    /// words that count as talking over. After `onUtterance`, call `nextUtterance()` to listen again.
    /// Returns false, with `problem` set, if it couldn't start.
    func startConversation(giveUp: TimeInterval, holding: Bool = false,
                           onSpeechDetected: @escaping () -> Void,
                           onUtterance: @escaping (String) -> Void,
                           onText: @escaping (String) -> Void) async -> Bool {
        stop()
        let captureGeneration = generation
        guard await prepare(captureGeneration), recognizer != nil else { return false }
        // iOS 26's SpeechAnalyzer when it can run (assets installed); otherwise the older recognizer.
        let analyzer = await SpeechAnalyzerEngine.make()
        guard captureGeneration == generation, !Task.isCancelled else { return false }
        do {
            try GolemAudioSession.shared.beginCapture()
            holdsSession = true
            analyzerEngine = analyzer
            let headphones = GolemAudioSession.shared.headphonesConnected
            bargeInMinimumWords = headphones ? 1 : 2

            engine = AVAudioEngine()
            if !headphones {
                // On the speaker, cancel Golem's own voice out of the microphone.
                do { try engine.inputNode.setVoiceProcessingEnabled(true) } catch {
                    Self.log.error("Echo cancellation unavailable: \(error.localizedDescription)")
                }
            }
            let box = RecognitionRequestBox()
            requestBox = box
            engine.inputNode.removeTap(onBus: 0)
            engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil, block: Self.tap(box))
            engine.prepare()
            try engine.start()
            isListening = true
            Self.log.notice("Microphone started")
            Self.log.notice("Recognition engine: \(analyzer == nil ? "SFSpeechRecognizer" : "SpeechAnalyzer")")

            let now = Date()
            conversation = Conversation(giveUp: giveUp, onSpeechDetected: onSpeechDetected, onUtterance: onUtterance, onText: onText,
                                        state: UtterancePause(pause: pause, giveUp: giveUp, minimumWords: bargeInMinimumWords, opened: now),
                                        requestOpened: now, holding: holding)
            conversationActive = true
            sessionObserver = GolemAudioSession.shared.addObserver(
                interrupted: { [weak self] in self?.fail("Listening was interrupted.") },
                routeChanged: { [weak self] in
                    guard let self, self.conversationActive else { return }
                    self.bargeInMinimumWords = GolemAudioSession.shared.headphonesConnected ? 1 : 2
                })
            configurationObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.restartEngine() }
            }
            openRequest(newUtterance: true)
            watchdog = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard let self, self.generation == captureGeneration, self.conversationActive, !Task.isCancelled else { return }
                    self.tick()
                }
            }
            return true
        } catch {
            problem = "Couldn't start listening: \(error.localizedDescription)"
            stop()
            return false
        }
    }

    /// Listens for the next utterance on the running microphone (after `onUtterance`).
    func nextUtterance() {
        guard conversationActive else { return }
        openRequest(newUtterance: true)
    }

    /// Hold to talk, button down: listen on the running microphone until `endHold()`. Pauses don't end the turn.
    func beginHold() {
        guard conversationActive, var conversation else { return }
        conversation.holding = true
        conversation.releasing = false
        conversation.carry = ""
        self.conversation = conversation
        openRequest(newUtterance: true)
    }

    /// Hold to talk, button up: after a moment for the last words to arrive, hand over everything
    /// said (`onUtterance`, "" if nothing). The microphone stays on for the next press.
    func endHold(grace: TimeInterval = 0.35) {
        guard var conversation, conversation.holding, !conversation.releasing else { return }
        conversation.releasing = true
        self.conversation = conversation
        let id = conversation.utterance
        DispatchQueue.main.asyncAfter(deadline: .now() + grace) { [weak self] in
            guard let self, var current = self.conversation, current.utterance == id, current.releasing, !current.awaitingNext else { return }
            current.holding = false
            current.releasing = false
            self.conversation = current
            let words = current.spoken
            self.deliver(words.isEmpty ? .silent : .send(words))
        }
    }

    /// Drops the words heard so far and listens afresh, keeping the microphone running.
    func cancelUtterance() {
        guard conversationActive else { return }
        openRequest(newUtterance: true)
    }

    /// Opens a recognition request on the running engine. A new utterance starts its timers over;
    /// a replacement for an ended or long-empty request keeps them.
    private func openRequest(newUtterance: Bool) {
        guard var conversation, analyzerEngine != nil || recognizer != nil else { return }
        request?.endAudio()
        task?.cancel()
        utteranceRecognizer?.cancel()
        utteranceRecognizer = nil
        request = nil
        task = nil
        let id = UUID()
        conversation.utterance = id
        conversation.requestOpened = Date()
        conversation.awaitingNext = false
        if newUtterance {
            conversation.state = UtterancePause(pause: pause, giveUp: conversation.giveUp, minimumWords: bargeInMinimumWords)
            conversation.quickFailures = 0
        }
        self.conversation = conversation
        if let analyzerEngine {
            let recognizer = analyzerEngine.openUtterance(
                onText: { [weak self] text in
                    Task { @MainActor in self?.recognized(id, text: text, final: false, failed: false) }
                },
                onEnd: { [weak self] failed in
                    Task { @MainActor in self?.analyzerEnded(id, failed: failed) }
                })
            utteranceRecognizer = recognizer
            requestBox.set(recognizer)
            return
        }
        guard let recognizer else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        self.request = request
        requestBox.set(request)
        task = Self.recognize(recognizer, request) { [weak self] text, final, failed in
            Task { @MainActor in self?.recognized(id, text: text, final: final, failed: failed) }
        }
    }

    /// The analyzer for this utterance stopped by itself. If it had words, hand them over; if it
    /// failed with none, carry on with SFSpeechRecognizer for the rest of the conversation.
    private func analyzerEnded(_ id: UUID, failed: Bool) {
        guard var conversation, conversation.utterance == id, !conversation.awaitingNext, analyzerEngine != nil else { return }
        let words = conversation.spoken
        // Button still down: keep what was said and listen on.
        if conversation.holding, !conversation.releasing, !conversation.state.text.isEmpty {
            conversation.carry = words
            self.conversation = conversation
            openRequest(newUtterance: true)
            return
        }
        if !words.isEmpty { deliver(.send(words)); return }
        guard failed || Date().timeIntervalSince(conversation.requestOpened) < 2 else {
            openRequest(newUtterance: false)
            return
        }
        guard recognizer != nil else { fail("Speech recognition isn't available right now."); return }
        Self.log.notice("Recognition engine fell back: SFSpeechRecognizer")
        analyzerEngine = nil
        openRequest(newUtterance: false)
    }

    private func recognized(_ id: UUID, text: String?, final: Bool, failed: Bool) {
        guard var conversation, conversation.utterance == id, !conversation.awaitingNext else { return }
        if let text, text != conversation.state.text {
            let bargedIn = conversation.state.heard(text, at: Date())
            self.conversation = conversation
            Self.log.notice("Transcription updated: \(text.count) characters")
            conversation.onText(conversation.spoken)
            if bargedIn { conversation.onSpeechDetected() }
            // The callbacks may have ended or restarted the conversation.
            guard let current = self.conversation, current.utterance == id, !current.awaitingNext else { return }
            conversation = current
        }
        guard final || failed else { return }
        // The request ended by itself: hand over what it heard, or replace it if it heard nothing.
        let words = conversation.spoken
        // Button still down: keep what was said and listen on.
        if conversation.holding, !conversation.releasing, !conversation.state.text.isEmpty {
            conversation.carry = words
            self.conversation = conversation
            openRequest(newUtterance: true)
            return
        }
        if !words.isEmpty { deliver(.send(words)); return }
        if Date().timeIntervalSince(conversation.requestOpened) < 2 { conversation.quickFailures += 1 } else { conversation.quickFailures = 0 }
        if conversation.quickFailures >= 3 {
            fail("Speech recognition isn't available right now.")
            return
        }
        let failures = conversation.quickFailures
        self.conversation = conversation
        openRequest(newUtterance: false)
        self.conversation?.quickFailures = failures
    }

    /// Every 100 ms: is the utterance over, or has an empty request run long enough to be replaced?
    private func tick() {
        guard let conversation, !conversation.awaitingNext else { return }
        let now = Date()
        // Hold to talk: the button decides when the turn ends, not pauses or silence.
        if conversation.holding {
            if analyzerEngine == nil, conversation.state.shouldRotate(openedAt: conversation.requestOpened, now: now) { openRequest(newUtterance: false) }
            return
        }
        if let outcome = conversation.state.due(at: now) {
            deliver(outcome)
        } else if analyzerEngine == nil, conversation.state.shouldRotate(openedAt: conversation.requestOpened, now: now) {
            openRequest(newUtterance: false)
        }
    }

    /// The utterance is over: stop feeding it audio, then hand it on. The microphone keeps running.
    private func deliver(_ outcome: UtterancePause.Outcome) {
        guard var conversation, !conversation.awaitingNext else { return }
        conversation.awaitingNext = true
        let handler = conversation.onUtterance
        self.conversation = conversation
        requestBox.clear()
        request?.endAudio()
        task?.cancel()
        utteranceRecognizer?.cancel()
        utteranceRecognizer = nil
        request = nil
        task = nil
        switch outcome {
        case .send(let words): handler(words)
        case .silent: handler("")
        }
    }

    /// The conversation can't go on: say why and end it. `onUtterance("")` tells the owner it's over.
    private func fail(_ message: String) {
        guard let handler = conversation?.onUtterance else { return }
        problem = message
        stop()
        handler("")
    }

    /// The route changed under the engine (it stops itself): start it again.
    private func restartEngine() {
        guard conversationActive else { return }
        if engine.isRunning { return }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            fail("Couldn't start listening: \(error.localizedDescription)")
        }
    }

    /// The tap runs on the audio thread, so it is built outside the main actor and only touches the box.
    nonisolated private static func tap(_ box: RecognitionRequestBox) -> AVAudioNodeTapBlock {
        { buffer, _ in box.append(buffer) }
    }

    nonisolated private static func recognize(_ recognizer: SFSpeechRecognizer, _ request: SFSpeechAudioBufferRecognitionRequest,
                                              report: @escaping @Sendable (String?, Bool, Bool) -> Void) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            report(result?.bestTranscription.formattedString, result?.isFinal == true, error != nil)
        }
    }

    /// Permissions and recognizer, with today's messages. False (with `problem` set) if listening can't start,
    /// or if it was stopped while asking.
    private func prepare(_ captureGeneration: UUID) async -> Bool {
        problem = nil
        let permitted = await Self.permitted()
        guard captureGeneration == generation, !Task.isCancelled else { return false }
        guard permitted else {
            #if GOLEM_APP
            problem = "Golem needs the microphone and speech recognition. Allow them in Settings → Golem."
            #else
            problem = "Chatterbox needs the microphone and speech recognition. Allow them in Settings → Chatterbox."
            #endif
            return false
        }
        guard let recognizer, recognizer.isAvailable else {
            problem = "Speech recognition isn't available right now."
            return false
        }
        return true
    }

    /// Asks once for the microphone and speech recognition.
    private static func permitted() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }
}

/// Hands microphone buffers from the audio thread to whichever recognizer is current (none between utterances).
private final class RecognitionRequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognizer: (any UtteranceRecognizer)?

    func clear() {
        lock.lock(); defer { lock.unlock() }
        request = nil
        recognizer = nil
    }

    func set(_ request: SFSpeechAudioBufferRecognitionRequest) {
        lock.lock(); defer { lock.unlock() }
        self.request = request
        recognizer = nil
    }

    func set(_ recognizer: any UtteranceRecognizer) {
        lock.lock(); defer { lock.unlock() }
        self.recognizer = recognizer
        request = nil
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        request?.append(buffer)
        recognizer?.append(buffer)
    }
}

/// "Send after a pause of 1.0 s" — how long a pause ends your turn when talking with Golem.
struct DictationPauseControl: View {
    @AppStorage(Dictation.pauseKey, store: AppPreferences.defaults) private var stored = Dictation.defaultPause

    private var pause: Double { min(max(stored, Dictation.pauseRange.lowerBound), Dictation.pauseRange.upperBound) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Send after a pause of")
                Spacer()
                Text(String(format: "%.1f s", pause)).foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(
                value: Binding(get: { pause }, set: { stored = min(max(($0 * 10).rounded() / 10, Dictation.pauseRange.lowerBound), Dictation.pauseRange.upperBound) }),
                in: Dictation.pauseRange,
                step: 0.1
            ) {
                Text("Send after a pause of")
            }
            .accessibilityValue(String(format: "%.1f seconds", pause))
            Text("Sends sooner after a finished sentence.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
