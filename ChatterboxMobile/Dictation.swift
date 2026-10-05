import AVFoundation
import Observation
import Speech

/// Voice to text for the message box: listens, and writes what you say into the draft as
/// you speak. It recognizes on the device when it can, so the audio stays on the phone.
@MainActor
@Observable
final class Dictation {
    private(set) var isListening = false
    /// Why it couldn't start, if it couldn't.
    private(set) var problem: String?

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private let recognizer = SFSpeechRecognizer()
    /// Hands-free: called once with what was said when you pause (empty if you said nothing).
    @ObservationIgnored private var onPause: ((String) -> Void)?
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var heard = ""
    @ObservationIgnored private var lastHeard = Date()

    /// Starts listening. `onText` gets the whole transcription so far, each time it changes.
    /// With `onPause`, it stops by itself: once you've spoken and then paused for `pause`
    /// seconds, or after `giveUp` seconds of silence, and hands `onPause` what it heard.
    func start(pause: TimeInterval = 1.5, giveUp: TimeInterval = 8,
               onPause: ((String) -> Void)? = nil, onText: @escaping (String) -> Void) async {
        stop()
        let captureGeneration = generation
        problem = nil
        let permitted = await Self.permitted()
        guard captureGeneration == generation, !Task.isCancelled else { return }
        guard permitted else {
            #if GOLEM_APP
            problem = "Golem needs the microphone and speech recognition. Allow them in Settings → Golem."
            #else
            problem = "Chatterbox needs the microphone and speech recognition. Allow them in Settings → Chatterbox."
            #endif
            return
        }
        guard let recognizer, recognizer.isAvailable else {
            problem = "Speech recognition isn't available right now."
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

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

    /// Stops listening. A hands-free listen stopped this way sends nothing.
    func stop() {
        generation = UUID()
        onPause = nil
        watchdog?.cancel()
        watchdog = nil
        guard isListening || request != nil else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.finish()
        request = nil
        task = nil
        isListening = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
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
