import AVFoundation
import CoreMedia
import os
import Speech

/// One utterance's recognizer: the conversation's microphone buffers go in, transcript updates come out.
protocol UtteranceRecognizer: AnyObject, Sendable {
    /// Called from the audio thread with each microphone buffer.
    func append(_ buffer: AVAudioPCMBuffer)
    /// Stops listening and releases the recognizer. No more callbacks after this.
    func cancel()
}

/// A recognition engine for a whole conversation. Each utterance gets its own fresh analyzer, so one
/// turn's words can't leak into the next; the microphone and audio engine keep running underneath.
protocol ConversationRecognitionEngine: AnyObject {
    /// `onText` gets the utterance's whole transcript each time it changes (volatile or final words).
    /// `onEnd` is called once if the recognizer stops by itself (`failed` if it errored).
    func openUtterance(onText: @escaping @Sendable (String) -> Void,
                       onEnd: @escaping @Sendable (_ failed: Bool) -> Void) -> any UtteranceRecognizer
}

/// iOS 26's SpeechAnalyzer with a DictationTranscriber (the engine behind keyboard dictation).
/// `make` returns nil, with the reason logged (no transcript text), when it can't be used:
/// before iOS 26, an unsupported locale, assets that aren't installed and can't be installed within 12 s.
enum SpeechAnalyzerEngine {
    static func make(locale: Locale = .current) async -> (any ConversationRecognitionEngine)? {
        guard #available(iOS 26.0, *) else { return nil }
        return await Engine26.make(locale: locale)
    }
}

@available(iOS 26.0, *)
private final class Engine26: ConversationRecognitionEngine {
    private let locale: Locale
    private let format: AVAudioFormat
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Golem", category: "SpeechAnalyzer")

    private init(locale: Locale, format: AVAudioFormat) {
        self.locale = locale
        self.format = format
    }

    static func make(locale requested: Locale) async -> Engine26? {
        guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: requested) else {
            log.notice("Locale not supported by SpeechAnalyzer")
            return nil
        }
        let probe = makeTranscriber(locale)
        switch await AssetInventory.status(forModules: [probe]) {
        case .unsupported:
            log.notice("SpeechAnalyzer assets unsupported")
            return nil
        case .installed:
            break
        case .supported, .downloading:
            guard await install([probe]) else { return nil }
        @unknown default:
            return nil
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [probe]) else {
            log.notice("SpeechAnalyzer has no audio format")
            return nil
        }
        return Engine26(locale: locale, format: format)
    }

    static func makeTranscriber(_ locale: Locale) -> DictationTranscriber {
        DictationTranscriber(locale: locale, contentHints: [], transcriptionOptions: [.punctuation],
                             reportingOptions: [.volatileResults], attributeOptions: [])
    }

    /// Downloads the language assets, giving up (the download carries on in the background) after a timeout.
    private static func install(_ modules: [any SpeechModule]) async -> Bool {
        do {
            guard let request = try await AssetInventory.assetInstallationRequest(supporting: modules) else {
                return await AssetInventory.status(forModules: modules) == .installed
            }
            log.notice("Installing SpeechAnalyzer assets")
            let outcome = await withTaskGroup(of: Bool.self) { group in
                group.addTask { (try? await request.downloadAndInstall()) != nil }
                group.addTask { try? await Task.sleep(for: .seconds(12)); return false }
                let first = await group.next() ?? false
                group.cancelAll()
                return first
            }
            if !outcome { log.notice("SpeechAnalyzer assets not ready") }
            return outcome
        } catch {
            log.error("SpeechAnalyzer asset install failed: \(error.localizedDescription)")
            return false
        }
    }

    func openUtterance(onText: @escaping @Sendable (String) -> Void,
                       onEnd: @escaping @Sendable (Bool) -> Void) -> any UtteranceRecognizer {
        Utterance26(locale: locale, format: format, onText: onText, onEnd: onEnd)
    }
}

@available(iOS 26.0, *)
private final class Utterance26: UtteranceRecognizer, @unchecked Sendable {
    private let format: AVAudioFormat
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private var cancelled = false
    private var analyzer: SpeechAnalyzer?
    private var tasks: [Task<Void, Never>] = []

    init(locale: Locale, format: AVAudioFormat,
         onText: @escaping @Sendable (String) -> Void, onEnd: @escaping @Sendable (Bool) -> Void) {
        self.format = format
        // The stream buffers whatever the microphone delivers while the analyzer is still starting.
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .unbounded)
        self.continuation = continuation
        let transcriber = Engine26.makeTranscriber(locale)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer

        let results = Task { [weak self] in
            var transcript = UtteranceTranscript()
            do {
                for try await result in transcriber.results {
                    if Task.isCancelled { return }
                    let range = result.range
                    let changed = transcript.apply(String(result.text.characters), isFinal: result.isFinal,
                                                   start: range.start.seconds, end: range.end.seconds)
                    if changed { onText(transcript.text) }
                }
                if !Task.isCancelled, self?.isCancelled == false { onEnd(false) }
            } catch {
                if !Task.isCancelled, self?.isCancelled == false { onEnd(true) }
            }
        }
        let start = Task { [weak self] in
            do {
                try await analyzer.start(inputSequence: stream)
            } catch {
                if !Task.isCancelled, self?.isCancelled == false { onEnd(true) }
            }
        }
        tasks = [results, start]
    }

    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled, let converted = convert(buffer) else { return }
        continuation.yield(AnalyzerInput(buffer: converted))
    }

    /// Converts to the analyzer's format when the microphone's differs. Called with the lock held.
    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        if converter == nil || sourceFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
            sourceFormat = buffer.format
        }
        guard let converter else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied { inputStatus.pointee = .noDataNow; return nil }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil, output.frameLength > 0 else { return nil }
        return output
    }

    func cancel() {
        lock.lock()
        if cancelled { lock.unlock(); return }
        cancelled = true
        continuation.finish()
        let analyzer = self.analyzer
        self.analyzer = nil
        let running = tasks
        tasks = []
        lock.unlock()
        running.forEach { $0.cancel() }
        if let analyzer { Task { await analyzer.cancelAndFinishNow() } }
    }
}
